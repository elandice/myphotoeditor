import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum EditorTool {
  brush,
  eraser,
  hand,
  marquee,
  transform,
  text,
  ellipticalMarquee,
  lasso,
  magicWand,
  eyedropper,
  fill,
  gradient,
  rectangle,
  ellipse,
  cloneStamp,
}

enum EditorSelectionKind { rectangle, ellipse, lasso, magicWand, inverted }

/// An immutable layer. Images are shared by history states and owned by the
/// controller, so consumers must never dispose [image].
class EditorLayer {
  const EditorLayer({
    required this.id,
    required this.name,
    required this.image,
    this.visible = true,
    this.locked = false,
    this.opacity = 1,
    this.blendMode = ui.BlendMode.srcOver,
    this.offset = Offset.zero,
    this.rotation = 0,
    this.scale = 1,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.text,
    this.fontSize = 84,
    this.fontFamily = 'sans-serif',
    this.color = const Color(0xff7865e9),
    this.textPosition = Offset.zero,
    this.mask,
    this.maskEnabled = true,
  });

  final String id;
  final String name;
  final ui.Image image;
  final bool visible;
  final bool locked;
  final double opacity;
  final ui.BlendMode blendMode;
  final Offset offset;
  final double rotation;
  final double scale;
  final double brightness;
  final double contrast;
  final double saturation;
  final String? text;
  final double fontSize;
  final String fontFamily;
  final Color color;
  final Offset textPosition;
  final ui.Image? mask;
  final bool maskEnabled;

  bool get isText => text != null;

  EditorLayer copyWith({
    String? id,
    String? name,
    ui.Image? image,
    bool? visible,
    bool? locked,
    double? opacity,
    ui.BlendMode? blendMode,
    Offset? offset,
    double? rotation,
    double? scale,
    double? brightness,
    double? contrast,
    double? saturation,
    String? text,
    bool clearText = false,
    double? fontSize,
    String? fontFamily,
    Color? color,
    Offset? textPosition,
    ui.Image? mask,
    bool clearMask = false,
    bool? maskEnabled,
  }) => EditorLayer(
    id: id ?? this.id,
    name: name ?? this.name,
    image: image ?? this.image,
    visible: visible ?? this.visible,
    locked: locked ?? this.locked,
    opacity: opacity ?? this.opacity,
    blendMode: blendMode ?? this.blendMode,
    offset: offset ?? this.offset,
    rotation: rotation ?? this.rotation,
    scale: scale ?? this.scale,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    text: clearText ? null : text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    fontFamily: fontFamily ?? this.fontFamily,
    color: color ?? this.color,
    textPosition: textPosition ?? this.textPosition,
    mask: clearMask ? null : mask ?? this.mask,
    maskEnabled: maskEnabled ?? this.maskEnabled,
  );
}
