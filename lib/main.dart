import 'package:flutter/material.dart';
import 'editor/editor_screen.dart';
import 'services/editor_recovery.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.recoveryStore});
  final EditorRecoveryStore? recoveryStore;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Luma Studio · 사진 편집기',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7865E9),
        surface: const Color(0xFFFCFCFE),
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F6F9),
      fontFamily: 'Segoe UI',
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 13, color: Color(0xFF343640)),
        bodySmall: TextStyle(fontSize: 11, color: Color(0xFF90939F)),
      ),
      dividerColor: const Color(0xFFE9EAF0),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: const Color(0xFF747785)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF7865E9),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF5F6FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        activeTrackColor: Color(0xFF8875EC),
        inactiveTrackColor: Color(0xFFECE9F8),
        thumbColor: Color(0xFF7865E9),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 15),
      ),
    ),
    home: EditorScreen(recoveryStore: recoveryStore),
  );
}
