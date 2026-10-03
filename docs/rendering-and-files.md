# Rendering and platform files

The editor's canonical image data lives in Flutter offscreen images. On the web,
`gpu_compositor.dart` selects the `dart:js_interop` bridge and `web/editor_blend.js`.
Native desktop and mobile builds select a stub so the engine's Flutter Canvas
blend modes can use the platform's graphics backend.

## Browser shader pipeline

The engine rasterizes each visible layer's transform and color adjustment to a
document-sized image, then reads `ImageByteFormat.rawStraightRgba`. The compositor
uploads these bytes to a WebGL texture. It runs normal, multiply, screen, overlay,
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

`test/webgl_blend_test.html` can be opened in a WebGL-enabled browser to run actual
GPU pixel comparisons. It checks all eight modes at four opacities, transparent
edges, vertical orientation, repeated calls, and invalid buffers. The tests also
run in headless Chrome with SwiftShader (`--headless --use-angle=swiftshader
--enable-unsafe-swiftshader --dump-dom file:///.../test/webgl_blend_test.html`).
Look for `body data-result="pass"`.

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
