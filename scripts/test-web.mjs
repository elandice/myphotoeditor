import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const candidates = [process.env.CHROME_BIN, process.env.CHROME_PATH,
  process.platform === 'win32' && 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  process.platform === 'darwin' && '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'].filter(Boolean);
const chrome = candidates.find(candidate => fs.existsSync(candidate));
if (!chrome) throw new Error('Set CHROME_BIN to a Chrome or Chromium executable.');

const server = http.createServer((request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    const target = path.resolve(root, '.' + decodeURIComponent(url.pathname));
    const relative = path.relative(root, target);
    if (relative.startsWith('..') || path.isAbsolute(relative) || !fs.statSync(target).isFile()) {
      response.writeHead(404).end(); return;
    }
    const types = {'.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm'};
    response.writeHead(200, {'Content-Type': types[path.extname(target)] || 'application/octet-stream'});
    fs.createReadStream(target).pipe(response);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
const tests = ['webgl_blend_test.html', 'web_pixel_worker_test.html', 'web_recovery_test.html'];
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'luma-web-test-'));
let browser, socket, exited;
let failed = false;
try {
  browser = spawn(chrome, ['--headless', '--use-angle=swiftshader',
    '--enable-unsafe-swiftshader', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank'], {windowsHide: true});
  exited = new Promise(resolve => browser.once('exit', resolve));
  const endpoint = await new Promise((resolve, reject) => {
    let stderr = '';
    const timeout = setTimeout(() => reject(new Error('Chrome did not start DevTools.')), 15000);
    browser.stderr.on('data', data => {
      stderr += data;
      const match = stderr.match(/DevTools listening on (ws:\/\/\S+)/);
      if (match) { clearTimeout(timeout); resolve(match[1]); }
    });
    browser.once('error', error => { clearTimeout(timeout); reject(error); });
    browser.once('exit', code => { clearTimeout(timeout); reject(new Error(`Chrome exited (${code}): ${stderr.slice(-3000)}`)); });
  });
  socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('DevTools handshake timed out.')), 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, {once: true});
    socket.addEventListener('error', error => { clearTimeout(timeout); reject(error); }, {once: true});
  });
  let nextId = 0;
  const pending = new Map();
  const rejectPending = () => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timeout); entry.reject(new Error('DevTools connection closed.'));
    }
    pending.clear();
  };
  socket.addEventListener('close', rejectPending);
  socket.addEventListener('error', rejectPending);
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const entry = pending.get(message.id);
    pending.delete(message.id); clearTimeout(entry.timeout);
    if (message.error) entry.reject(new Error(message.error.message));
    else entry.resolve(message.result);
  });
  const command = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++nextId;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 5000);
    pending.set(id, {resolve, reject, timeout});
    socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
  });
  for (const test of tests) {
    const {targetId} = await command('Target.createTarget', {url: 'about:blank'});
    const {sessionId} = await command('Target.attachToTarget', {targetId, flatten: true});
    let testFailed = false;
    try {
      await command('Page.navigate', {url: `http://127.0.0.1:${address.port}/test/${test}`}, sessionId);
      const deadline = Date.now() + 30000;
      let state;
      do {
        await new Promise(resolve => setTimeout(resolve, 150));
        const evaluation = await command('Runtime.evaluate', {
          expression: '({result:document.body?.dataset.result,text:document.querySelector("#results")?.textContent})',
          returnByValue: true,
        }, sessionId);
        state = evaluation.result?.value;
      } while (!state?.result && Date.now() < deadline);
      if (state?.result !== 'pass') throw new Error(`${test}: ${state?.text || 'Timed out'}`);
      console.log(`${test}: ${state.text}`);
    } catch (error) { testFailed = true; throw error; }
    finally {
      try { await command('Target.closeTarget', {targetId}); }
      catch (error) { if (!testFailed) throw error; }
    }
  }
  socket.send(JSON.stringify({id: ++nextId, method: 'Browser.close'}));
  await Promise.race([exited, new Promise(resolve => setTimeout(resolve, 4000))]);
} catch (error) { failed = true; throw error; }
finally {
  socket?.close();
  if (browser?.exitCode === null) browser.kill();
  if (exited) await Promise.race([exited, new Promise(resolve => setTimeout(resolve, 4000))]);
  await new Promise(resolve => server.close(resolve));
  if (!path.resolve(profile).startsWith(path.resolve(os.tmpdir()) + path.sep) ||
      !path.basename(profile).startsWith('luma-web-test-')) throw new Error('Unexpected test profile path.');
  try { fs.rmSync(profile, {recursive: true, force: true, maxRetries: 8, retryDelay: 250}); }
  catch (error) { if (!failed) throw error; }
}
