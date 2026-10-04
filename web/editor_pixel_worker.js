/* Pure pixel kernels. Native Dart implementations are their test oracle. */
'use strict';

const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

function filterPixels({pixels: input, width, height, filter, amount}) {
  const output = new Uint8Array(input.length);
  let low = 255, high = 0;
  if (filter === 'autoContrast') {
    const histogram = new Uint32Array(256);
    let count = 0;
    for (let i = 0; i < input.length; i += 4) {
      if (input[i + 3] === 0) continue;
      histogram[Math.round(.2126 * input[i] + .7152 * input[i + 1] + .0722 * input[i + 2])]++;
      count++;
    }
    const clip = Math.floor(count * .01);
    let sum = 0;
    for (let i = 0; i < 256; i++) {
      sum += histogram[i];
      if (sum > clip) { low = i; break; }
    }
    sum = 0;
    for (let i = 255; i >= 0; i--) {
      sum += histogram[i];
      if (sum > clip) { high = i; break; }
    }
  }
  for (let i = 0; i < input.length; i += 4) {
    const r = input[i], g = input[i + 1], b = input[i + 2];
    let rr = r, gg = g, bb = b;
    if (filter === 'invert') {
      rr = 255 - r; gg = 255 - g; bb = 255 - b;
    } else if (filter === 'grayscale') {
      rr = gg = bb = .2126 * r + .7152 * g + .0722 * b;
    } else if (filter === 'sepia') {
      rr = .393 * r + .769 * g + .189 * b;
      gg = .349 * r + .686 * g + .168 * b;
      bb = .272 * r + .534 * g + .131 * b;
    } else if (filter === 'posterize') {
      const levels = clamp(Math.round(amount), 2, 32) - 1;
      rr = Math.round(r / 255 * levels) * 255 / levels;
      gg = Math.round(g / 255 * levels) * 255 / levels;
      bb = Math.round(b / 255 * levels) * 255 / levels;
    } else if (filter === 'threshold') {
      rr = gg = bb = (.2126 * r + .7152 * g + .0722 * b) >= clamp(amount, 0, 1) * 255 ? 255 : 0;
    } else if (filter === 'autoContrast' && high > low) {
      rr = (r - low) * 255 / (high - low);
      gg = (g - low) * 255 / (high - low);
      bb = (b - low) * 255 / (high - low);
    } else if (filter === 'sharpen') {
      const pixel = i / 4, x = pixel % width, y = Math.floor(pixel / width);
      const strength = clamp(amount, 0, 3);
      const neighbors = [
        y * width + Math.max(0, x - 1),
        y * width + Math.min(width - 1, x + 1),
        Math.max(0, y - 1) * width + x,
        Math.min(height - 1, y + 1) * width + x,
      ];
      function sharpen(channel) {
        const center = input[i + channel];
        let sum = 0;
        for (const p of neighbors) {
          sum += input[p * 4 + 3] === 0 ? center : input[p * 4 + channel];
        }
        return center * (1 + 4 * strength) - sum * strength;
      }
      rr = sharpen(0); gg = sharpen(1); bb = sharpen(2);
    }
    const alpha = input[i + 3];
    output[i] = Math.round(clamp(rr, 0, 255) * alpha / 255);
    output[i + 1] = Math.round(clamp(gg, 0, 255) * alpha / 255);
    output[i + 2] = Math.round(clamp(bb, 0, 255) * alpha / 255);
    output[i + 3] = alpha;
  }
  return output;
}

function connectedRegion({pixels: data, width, height, x: sx, y: sy, tolerance}) {
  if (!Number.isInteger(sx) || !Number.isInteger(sy) || sx < 0 || sy < 0 || sx >= width || sy >= height)
    throw new Error('Region seed is outside the document.');
  const seed = (sy * width + sx) * 4;
  const visited = new Uint8Array(width * height);
  const stack = [sy * width + sx], spans = [];
  const limit = clamp(tolerance, 0, 1) * 255;
  function match(x, y) {
    if (x < 0 || y < 0 || x >= width || y >= height || visited[y * width + x]) return false;
    const i = (y * width + x) * 4;
    if (Math.abs(data[i + 3] - data[seed + 3]) > limit) return false;
    if (data[i + 3] === 0 && data[seed + 3] === 0) return true;
    return Math.max(Math.abs(data[i] - data[seed]), Math.abs(data[i + 1] - data[seed + 1]),
      Math.abs(data[i + 2] - data[seed + 2])) <= limit;
  }
  while (stack.length) {
    const p = stack.pop(), y = Math.floor(p / width), x = p % width;
    if (!match(x, y)) continue;
    let left = x, right = x;
    while (match(left - 1, y)) left--;
    while (match(right + 1, y)) right++;
    visited.fill(1, y * width + left, y * width + right + 1);
    spans.push(left, y, right - left + 1);
    for (const ny of [y - 1, y + 1]) {
      if (ny < 0 || ny >= height) continue;
      let inside = false;
      for (let px = left; px <= right; px++) {
        const next = match(px, ny);
        if (next && !inside) stack.push(ny * width + px);
        inside = next;
      }
    }
  }
  return new Int32Array(spans);
}

self.onmessage = event => {
  const {id, operation, args} = event.data;
  try {
    if (!Number.isInteger(args.width) || !Number.isInteger(args.height) || args.width < 1 || args.height < 1
      || args.width > 4096 || args.height > 4096 || !(args.pixels instanceof Uint8Array)
      || args.pixels.length !== args.width * args.height * 4)
      throw new Error('Pixel Worker input is invalid.');
    const result = operation === 'filter' ? filterPixels(args)
      : operation === 'region' ? connectedRegion(args)
      : (() => { throw new Error('Unknown pixel operation.'); })();
    self.postMessage({id, result}, [result.buffer]);
  } catch (error) {
    self.postMessage({id, error: String(error.message || error)});
  }
};
