/* Keep large CPU pixel operations off Flutter's browser event loop. */
(() => {
  'use strict';
  const scriptUrl = document.currentScript?.src;
  const workerUrl = new URL('editor_pixel_worker.js', scriptUrl || document.baseURI);
  const pending = new Map();
  let worker;
  let nextId = 0;

  function stop(error) {
    worker?.terminate();
    worker = undefined;
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    pending.clear();
  }

  function start() {
    if (worker) return worker;
    const value = new Worker(workerUrl);
    value.onmessage = event => {
      const {id, result, error} = event.data;
      const request = pending.get(id);
      if (!request) return;
      clearTimeout(request.timer);
      pending.delete(id);
      if (error) request.reject(new Error(error));
      else request.resolve(result);
    };
    value.onerror = () => stop(new Error('Pixel Worker could not run.'));
    value.onmessageerror = () => stop(new Error('Pixel Worker response was invalid.'));
    worker = value;
    return value;
  }

  function run(operation, args) {
    return new Promise((resolve, reject) => {
      let value;
      try {
        value = start();
      } catch (error) {
        reject(error);
        return;
      }
      const id = nextId++;
      // Transfer a copy: do not detach Flutter's original pixels needed by the
      // fallback when a Worker is unavailable or fails during processing.
      const pixels = new Uint8Array(args.pixels);
      const timer = setTimeout(() => stop(new Error('Pixel Worker timed out.')), 60000);
      pending.set(id, {resolve, reject, timer});
      try {
        value.postMessage({id, operation, args: {...args, pixels}}, [pixels.buffer]);
      } catch (error) {
        clearTimeout(timer);
        pending.delete(id);
        reject(error);
      }
    });
  }

  window.lumaPixels = Object.freeze({
    filter: args => run('filter', args),
    region: args => run('region', args),
  });
})();
