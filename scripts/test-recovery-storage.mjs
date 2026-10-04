import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

// Drive the shipped storage bridge with IndexedDB events and a virtual clock.
// Real browser tests cover persistence; these tests cover failure ordering.
const source = readFileSync(new URL('../web/editor_recovery.js', import.meta.url), 'utf8');
const flush = async () => {
  for (let index = 0; index < 24; index++) await Promise.resolve();
};

class Clock {
  now = 0;
  nextId = 0;
  timers = new Map();

  set(callback, delay = 0) {
    const id = ++this.nextId;
    this.timers.set(id, {at: this.now + delay, callback});
    return id;
  }

  clear(id) { this.timers.delete(id); }

  async advance(milliseconds) {
    const deadline = this.now + milliseconds;
    await flush();
    while (true) {
      const next = [...this.timers.entries()]
        .filter(([, timer]) => timer.at <= deadline)
        .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      this.now = next[1].at;
      this.timers.delete(next[0]);
      next[1].callback();
      await flush();
    }
    this.now = deadline;
    await flush();
  }
}

const clone = value => value instanceof Uint8Array ? new Uint8Array(value) : value;

function fixture() {
  const clock = new Clock();
  const stored = new Map();
  const opens = [];
  const transactions = [];
  const databases = [];
  const events = [];

  function database() {
    const db = {
      closeCount: 0,
      createObjectStore(name) {
        assert.equal(name, 'drafts');
        events.push('upgrade');
      },
      close() { this.closeCount++; events.push('close'); },
      transaction(name, mode) {
        assert.equal(name, 'drafts');
        assert(['readonly', 'readwrite'].includes(mode));
        const request = {
          state: 'pending',
          value: undefined,
          failure: null,
          get result() {
            assert.equal(this.state, 'done', 'IDB request.result requires completion');
            return this.value;
          },
          get error() {
            assert.equal(this.state, 'done', 'IDB request.error requires completion');
            return this.failure;
          },
        };
        const transaction = {
          error: null,
          abortCount: 0,
          operation: null,
          state: 'active',
          objectStore(storeName) {
            assert.equal(storeName, 'drafts');
            const operation = (type, key, value) => {
              if (type !== 'get') assert.equal(mode, 'readwrite');
              assert.equal(this.operation, null, 'One request per transaction');
              this.operation = {type, key, value: clone(value)};
              events.push(type);
              return request;
            };
            return {
              get: key => operation('get', key),
              put: (value, key) => operation('put', key, value),
              delete: key => operation('delete', key),
            };
          },
          complete() {
            assert.equal(this.state, 'active');
            this.state = 'done';
            const {type, key, value} = this.operation;
            if (type === 'put') stored.set(key, clone(value));
            if (type === 'delete') stored.delete(key);
            request.value = type === 'get' ? clone(stored.get(key)) : type === 'put' ? key : undefined;
            request.state = 'done';
            events.push(`complete:${type}`);
            this.oncomplete?.();
          },
          fail(error) {
            assert.equal(this.state, 'active');
            this.state = 'done';
            this.error = error;
            request.failure = error;
            request.state = 'done';
            events.push('error');
            this.onerror?.();
            this.onabort?.();
          },
          abort() {
            this.abortCount++;
            assert.equal(this.state, 'active');
            this.state = 'aborting';
            // IndexedDB abort events arrive after abort() returns. The bridge's
            // timeout error must win over this later AbortError.
            clock.set(() => {
              this.state = 'done';
              request.state = 'done';
              request.failure = new Error('AbortError');
              this.error = request.failure;
              this.onabort?.();
            });
          },
        };
        transactions.push(transaction);
        return transaction;
      },
    };
    databases.push(db);
    return db;
  }

  const sandbox = {
    Promise,
    Uint8Array,
    indexedDB: {
      open(name, version) {
        assert.equal(name, 'luma-studio-recovery');
        assert.equal(version, 1);
        const request = {result: undefined, error: null};
        opens.push(request);
        events.push('open');
        return request;
      },
    },
    setTimeout: (callback, delay) => clock.set(callback, delay),
    clearTimeout: id => clock.clear(id),
    addEventListener() {},
    removeEventListener() {},
  };
  vm.runInNewContext(source, sandbox, {filename: 'web/editor_recovery.js'});
  return {
    api: sandbox.lumaRecovery, clock, stored, opens, transactions, databases, events,
    async succeedOpen(index = opens.length - 1, upgrade = false) {
      const request = opens[index];
      assert(request, `Open request ${index} exists`);
      request.result = database();
      if (upgrade) request.onupgradeneeded?.();
      request.onsuccess?.();
      await flush();
      return request.result;
    },
    async complete(index = transactions.length - 1) {
      transactions[index].complete();
      await flush();
    },
    assertIdle() {
      assert.equal(clock.timers.size, 0, 'Storage must release its timeout handles');
      for (const db of databases) assert.equal(db.closeCount, 1, 'Each connection closes exactly once');
    },
  };
}

function watch(promise) {
  const state = {status: 'pending'};
  state.done = promise.then(value => {
    state.status = 'fulfilled'; state.value = value;
  }, error => {
    state.status = 'rejected'; state.error = error;
  });
  return state;
}

async function rejected(state, pattern) {
  await state.done;
  assert.equal(state.status, 'rejected');
  assert.match(String(state.error?.message || state.error), pattern);
}

const tests = [
  ['blocked open rejects and closes a connection that succeeds later', async () => {
    const f = fixture();
    const read = watch(f.api.read());
    await flush();
    f.opens[0].onblocked();
    await rejected(read, /blocked/);
    await f.succeedOpen(0);
    assert.equal(f.transactions.length, 0, 'Late success must not start a transaction');
    f.assertIdle();
  }],
  ['open timeout is bounded and late success closes its connection', async () => {
    const f = fixture();
    const read = watch(f.api.read());
    await f.clock.advance(4999);
    assert.equal(read.status, 'pending');
    await f.clock.advance(1);
    await rejected(read, /storage timed out/);
    await f.succeedOpen(0);
    assert.equal(f.transactions.length, 0);
    f.assertIdle();
  }],
  ['open errors do not poison the next queued operation', async () => {
    const f = fixture();
    f.stored.set('project', new Uint8Array([9]));
    const failed = watch(f.api.read());
    const retry = watch(f.api.read());
    await flush();
    assert.equal(f.opens.length, 1);
    f.opens[0].error = new Error('Unavailable storage');
    f.opens[0].onerror();
    await rejected(failed, /Unavailable storage/);
    await flush();
    assert.equal(f.opens.length, 2);
    await f.succeedOpen(1, true);
    await f.complete();
    await retry.done;
    assert.equal(retry.status, 'fulfilled');
    assert.deepEqual(Array.from(retry.value), [9]);
    f.assertIdle();
  }],
  ['transaction timeout aborts, closes and lets the queue continue', async () => {
    const f = fixture();
    f.stored.set('project', new Uint8Array([9]));
    const failed = watch(f.api.write(new Uint8Array([1])));
    const retry = watch(f.api.read());
    await flush();
    await f.succeedOpen(0);
    await f.clock.advance(5000);
    await rejected(failed, /transaction timed out/);
    assert.equal(f.transactions[0].abortCount, 1);
    assert.deepEqual(Array.from(f.stored.get('project')), [9], 'Timed-out write cannot commit');
    assert.equal(f.opens.length, 2);
    await f.succeedOpen(1);
    await f.complete(1);
    await retry.done;
    assert.deepEqual(Array.from(retry.value), [9]);
    f.assertIdle();
  }],
  ['write then clear then write commits in invocation order', async () => {
    const f = fixture();
    const input = new Uint8Array([1, 2]);
    const first = watch(f.api.write(input));
    const clear = watch(f.api.clear());
    const last = watch(f.api.write(new Uint8Array([7, 8])));
    input[0] = 99;
    await flush();
    assert.equal(f.opens.length, 1, 'Queued operations must not open concurrently');
    await f.succeedOpen(0);
    await f.complete(0);
    assert.deepEqual(Array.from(f.stored.get('project')), [1, 2], 'Input is captured at write invocation');
    assert.equal(f.opens.length, 2);
    await f.succeedOpen(1);
    assert.equal(f.transactions[1].operation.type, 'delete');
    await f.complete(1);
    assert.equal(f.stored.has('project'), false);
    assert.equal(f.opens.length, 3);
    await f.succeedOpen(2);
    await f.complete(2);
    await Promise.all([first.done, clear.done, last.done]);
    assert.deepEqual([first.status, clear.status, last.status], ['fulfilled', 'fulfilled', 'fulfilled']);
    assert.deepEqual(Array.from(f.stored.get('project')), [7, 8]);
    assert.deepEqual(f.events.filter(event => event.startsWith('complete:')), ['complete:put', 'complete:delete', 'complete:put']);
    f.assertIdle();
  }],
  ['transaction error preserves the draft and later clear and write succeed', async () => {
    const f = fixture();
    f.stored.set('project', new Uint8Array([9]));
    const failed = watch(f.api.write(new Uint8Array([1])));
    const clear = watch(f.api.clear());
    const retry = watch(f.api.write(new Uint8Array([7])));
    await flush();
    await f.succeedOpen(0);
    f.transactions[0].fail(new Error('QuotaExceededError'));
    await rejected(failed, /QuotaExceededError/);
    assert.deepEqual(Array.from(f.stored.get('project')), [9]);
    await flush();
    assert.equal(f.opens.length, 2);
    await f.succeedOpen(1);
    await f.complete(1);
    await f.succeedOpen(2);
    await f.complete(2);
    await Promise.all([clear.done, retry.done]);
    assert.equal(clear.status, 'fulfilled');
    assert.equal(retry.status, 'fulfilled');
    assert.deepEqual(Array.from(f.stored.get('project')), [7]);
    f.assertIdle();
  }],
];

for (const [name, body] of tests) {
  await body();
  console.log(`PASS: ${name}`);
}
console.log(`PASS: ${tests.length} recovery storage failure and ordering scenarios.`);
