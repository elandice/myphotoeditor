import assert from 'node:assert/strict';
import {existsSync, mkdtempSync, readFileSync, rmSync, rmdirSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import vm from 'node:vm';

// Compare the shipped JS kernels with the actual native Dart implementation,
// rather than maintaining a second mathematical oracle in this test.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const effects = readFileSync(join(root, 'lib/editor/editor_effects.dart'), 'utf8');
const operations = readFileSync(join(root, 'lib/editor/editor_operations.dart'), 'utf8');
const filters = effects.slice(effects.indexOf('Uint8List _filterPixels('));
const regions = operations.slice(operations.indexOf('List<int> _connectedColorRegion('));
assert(filters.startsWith('Uint8List _filterPixels('), 'Dart filter oracle must be present');
assert(regions.startsWith('List<int> _connectedColorRegion('), 'Dart region oracle must be present');
const cases = [];
const pixels = Array.from({length: 6 * 5 * 4}, (_, i) => (i * 47 + 13) % 256);
for (let p = 0; p < 30; p++) pixels[p * 4 + 3] = [0, 1, 80, 128, 255][p % 5];
for (const [filter, amounts] of [
  ['invert', [1]], ['grayscale', [1]], ['sepia', [1]], ['sharpen', [0, .7, 3]],
  ['posterize', [2, 6, 32]], ['threshold', [0, .5, 1]], ['autoContrast', [1]],
]) {
  for (const amount of amounts) cases.push({operation: 'filter', args: {pixels, width: 6, height: 5, filter, amount}});
}
for (const sample of [new Array(16).fill(0), [50, 50, 50, 255, 50, 50, 50, 255, 50, 50, 50, 255, 50, 50, 50, 255]]) {
  cases.push({operation: 'filter', args: {pixels: sample, width: 2, height: 2, filter: 'autoContrast', amount: 1}});
}
const histogram = Array.from({length: 17 * 9 * 4}, (_, i) => i % 4 === 3 ? 255 : Math.floor(i / 4) % 256);
cases.push({operation: 'filter', args: {pixels: histogram, width: 17, height: 9, filter: 'autoContrast', amount: 1}});
for (const tolerance of [0, .12, 1]) {
  cases.push({operation: 'region', args: {pixels, width: 6, height: 5, x: 2, y: 2, tolerance}});
}
const separated = [];
for (let y = 0; y < 5; y++) for (let x = 0; x < 7; x++) separated.push(...(x === 3 ? [0, 0, 0, 255] : [255, 255, 255, 255]));
cases.push({operation: 'region', args: {pixels: separated, width: 7, height: 5, x: 1, y: 1, tolerance: 0}});
const transparent = pixels.map((value, i) => i % 4 === 3 ? 0 : value);
cases.push({operation: 'region', args: {pixels: transparent, width: 6, height: 5, x: 0, y: 0, tolerance: 0}});

const temporary = mkdtempSync(join(tmpdir(), 'luma-pixel-oracle-'));
try {
  const runner = join(temporary, 'oracle.dart');
  writeFileSync(runner, `import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
${filters}
${regions}
Future<void> main() async {
  final cases = jsonDecode(await stdin.transform(utf8.decoder).join()) as List;
  final results = <List<int>>[];
  for (final item in cases) {
    final args = Map<String, Object>.from(item['args'] as Map);
    args['pixels'] = Uint8List.fromList((args['pixels'] as List).cast<int>());
    for (final name in ['amount', 'tolerance']) {
      if (args[name] != null) args[name] = (args[name] as num).toDouble();
    }
    results.add(item['operation'] == 'filter' ? _filterPixels(args) : _connectedColorRegion(args));
  }
  stdout.write(jsonEncode(results));
}`);
  const installedDart = 'C:/flutter/flutter/bin/cache/dart-sdk/bin/dart.exe';
  const dart = process.env.DART_BIN || process.argv[2] || (existsSync(installedDart) ? installedDart : 'dart');
  const result = spawnSync(dart, [runner], {input: JSON.stringify(cases), encoding: 'utf8', timeout: 60000});
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  const expected = JSON.parse(result.stdout);
  let response;
  const self = {postMessage: value => {response = value;}};
  vm.runInNewContext(readFileSync(join(root, 'web/editor_pixel_worker.js'), 'utf8'), {
    self, Uint8Array, Uint32Array, Int32Array, Math, Number, Error,
  });
  for (let i = 0; i < cases.length; i++) {
    const item = cases[i];
    self.onmessage({data: {id: i, operation: item.operation, args: {...item.args, pixels: new Uint8Array(item.args.pixels)}}});
    assert.equal(response.error, undefined, response.error);
    assert.deepEqual(Array.from(response.result), expected[i], `${item.operation}/${item.args.filter || item.args.tolerance}`);
  }
  console.log(`PASS: ${cases.length} Worker kernel cases match native Dart byte-for-byte (all 7 CPU filters, alpha edges, percentile contrast and connected regions).`);
} finally {
  rmSync(join(temporary, 'oracle.dart'), {force: true});
  rmdirSync(temporary);
}
