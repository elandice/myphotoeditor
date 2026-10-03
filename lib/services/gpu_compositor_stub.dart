import 'dart:ui' as ui;

import 'gpu_layer.dart';

/// Native Flutter uses its Canvas/Impeller/Skia blend pipeline instead.
bool get supportsWebGl => false;

Future<ui.Image?> compositeWebGl({
  required int width,
  required int height,
  required List<GpuLayer> layers,
}) async => null;
