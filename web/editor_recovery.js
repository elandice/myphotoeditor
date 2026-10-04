(() => {
  'use strict';
  let dirty = false;
  let tail = Promise.resolve();
  const serial = action => {
    const next = tail.then(action);
    tail = next.catch(() => {});
    return next;
  };
  const guard = event => {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = '';
  };
  const open = () => new Promise((resolve, reject) => {
    const request = indexedDB.open('luma-studio-recovery', 1);
    let settled = false;
    const fail = error => {
      if (settled) return;
      settled = true; clearTimeout(timeout); reject(error);
    };
    const timeout = setTimeout(() => fail(new Error('Recovery storage timed out.')), 5000);
    request.onupgradeneeded = () => request.result.createObjectStore('drafts');
    request.onsuccess = () => {
      if (settled) { request.result.close(); return; }
      settled = true; clearTimeout(timeout); resolve(request.result);
    };
    request.onerror = () => fail(request.error);
    request.onblocked = () => fail(new Error('Recovery storage is blocked.'));
  });
  async function transact(mode, action) {
    const db = await open();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = db.transaction('drafts', mode);
        const request = action(transaction.objectStore('drafts'));
        const timeout = setTimeout(() => {
          try { transaction.abort(); } catch (_) {}
          reject(new Error('Recovery transaction timed out.'));
        }, 5000);
        transaction.oncomplete = () => { clearTimeout(timeout); resolve(request.result ?? null); };
        transaction.onabort = () => { clearTimeout(timeout); reject(transaction.error || request.error); };
        transaction.onerror = () => { clearTimeout(timeout); reject(transaction.error || request.error); };
      });
    } finally { db.close(); }
  }
  globalThis.lumaRecovery = {
    read: () => serial(() => transact('readonly', store => store.get('project'))),
    write: project => {
      if (!(project instanceof Uint8Array) || !project.length || project.length > 128 * 1024 * 1024) {
        return Promise.reject(new Error('Invalid recovery project size.'));
      }
      const copy = new Uint8Array(project);
      return serial(() => transact('readwrite', store => store.put(copy, 'project')));
    },
    clear: () => serial(() => transact('readwrite', store => store.delete('project'))),
    setDirty: value => {
      if (dirty === Boolean(value)) return;
      dirty = Boolean(value);
      if (dirty) addEventListener('beforeunload', guard);
      else removeEventListener('beforeunload', guard);
    },
  };
})();
