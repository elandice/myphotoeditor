# Rendering and platform files

The editor's canonical image data lives in Flutter offscreen images. On the web,
`gpu_compositor.dart` selects the `dart:js_interop` bridge and `web/editor_blend.js`.
Native desktop and mobile builds select a stub so the engine's Flutter Canvas
blend modes can use the platform's graphics backend.

## Browser shader pipeline

The engine pins visible source images with shared image handles, then processes
one layer at a time: rasterize its transform and color adjustment, read
`ImageByteFormat.rawStraightRgba`, upload it, and release the temporary raster
before starting the next layer. A composition session reuses its three textures
and two framebuffer objects across all layers. Temporary layer rasters and RGBA
readbacks therefore no longer grow with layer count. Source images and the final
composite still occupy memory. The compositor runs normal, multiply, screen, overlay,
darken, lighten, difference, or additive blending in a GLSL fragment shader. Two
framebuffer textures alternate between the previous result and next output; no
pass samples the texture it is writing.

For standard modes, straight-alpha blend color B uses source-over compositing:

```
alpha = sourceAlpha + backdropAlpha * (1 - sourceAlpha)
premultipliedColor = sourceAlpha * (1 - backdropAlpha) * sourceColor
                  + sourceAlpha * backdropAlpha * B(backdropColor, sourceColor)
                  + (1 - sourceAlpha) * backdropAlpha * backdropColor
```

Layer opacity multiplies source alpha. Add uses saturating premultiplied sums to
match Flutter `BlendMode.plus`. The shader retains straight RGB between passes;
the Dart bridge premultiplies the readback once for `decodeImageFromPixels`.
Transparent black is returned for zero-alpha pixels. Byte-array upload and
readback use the same row order. Framebuffers and temporary textures are released
after each composition.

The browser shader path is used for settled previews and PNG export. The Canvas
path supplies immediate stroke previews. Missing WebGL, context loss, failed
shader compilation, unsupported image dimensions, and framebuffer allocation
failures return `null`, preserving the Canvas fallback.

The viewport retains the document and draws selection ants, tool previews,
handles, and cursors in a separate repaint boundary. A dedicated paint revision
changes for image edits, stroke samples, transforms, and accepted GPU results.
Selection animation, hover, and ordinary tool settings do not recomposite the
document. Zoom, pan, layout changes, and content edits still repaint it.

GPU composition still requires pixel readback and upload; it is not a pipeline
that keeps all intermediate data on the GPU. `readPixels` and the final Dart
premultiplication are synchronous browser work. Resource-count improvements do
not establish a frame-time or total-process-memory guarantee.

`test/webgl_blend_test.html` can be opened in a WebGL-enabled browser to run actual
GPU pixel comparisons. It checks all eight modes at four opacities, transparent
edges, vertical orientation, streamed and interleaved sessions, repeated calls,
and invalid buffers. `node scripts/test-web.mjs` runs the browser tests through a
local HTTP server in headless Chrome with SwiftShader. Set `CHROME_BIN` when
Chrome is outside the usual installation paths. Look for
`body data-result="pass"` when opening a test page manually.

## CPU pixel work

`web/editor_pixels.js` transfers a copy of input bytes to a real Web Worker in
`web/editor_pixel_worker.js`. Seven CPU filters and connected-region scanning
run off the browser's UI event loop, and the worker transfers output buffers
back. Gaussian blur continues to use Flutter's image filter. The input copy
keeps original pixels attached and usable if the worker rejects a request.
Worker creation, CSP restrictions, processing errors, and a 60-second timeout
return to the Dart implementation. Native Dart uses `compute` in an isolate;
the web fallback runs `compute` on the UI event loop and can pause interaction
on large documents. Image readback and region-to-path construction also remain
on the Flutter side.

`node scripts/test-pixel-worker.mjs` compares worker kernels byte-for-byte with
the current native Dart functions, covering every CPU filter, transparent and
partially transparent pixels, percentile contrast, and connected regions. Set
`DART_BIN` to the Dart executable if it is not available on PATH. The real Worker
browser test additionally verifies transport, rejected requests, reuse after an
error, preservation of input buffers, and browser timers during computation.
`test/editor_rendering_test.dart` verifies that overlay-only changes retain the
document paint while content edits, stroke samples, and zoom still repaint it.

## Import and export

`EditorFiles` uses `file_picker` 10.3.x. Import requests one supported raster
image with bytes. The Flutter image decoder validates the chosen data. Export
passes PNG bytes into the system save dialog on desktop and mobile. Cancellation
and successful writes have separate return values; plugin failures propagate to
the UI. The browser initiates a download and reports `downloadStarted`, because
browsers do not expose the final save path or confirm that the user kept the file.

macOS debug and release entitlements include user-selected read/write access.
Mobile uses the system document picker, without broad storage permissions. Native
platform build toolchains and app signing remain required for release packaging.
On Windows, Flutter plugins need symlink support (Windows Developer Mode or an
appropriately configured developer environment).

File service checks: `flutter test --no-pub test/editor_files_test.dart`.

## References

- [Khronos WebGL specification: textures, framebuffer objects, pixel storage and readback](https://registry.khronos.org/webgl/specs/latest/1.0/)
- [W3C Compositing and Blending: general formula and blend functions](https://www.w3.org/TR/compositing-1/)
- [file_picker package and platform support](https://pub.dev/packages/file_picker/versions/10.3.10)
