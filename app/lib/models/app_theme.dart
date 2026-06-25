import 'package:flutter/material.dart';

class AppTheme {
  final String name;
  final String emoji;
  final Color lightPrimary;
  final Color darkPrimary;
  final Color lightBg;
  final Color lightSurface;
  final Color darkBg;
  final Color darkSurface;

  const AppTheme({
    required this.name,
    required this.emoji,
    required this.lightPrimary,
    required this.darkPrimary,
    required this.lightBg,
    required this.lightSurface,
    required this.darkBg,
    required this.darkSurface,
  });

  static const List<AppTheme> presets = [
    AppTheme(
      name: '暖橙',
      emoji: '🔥',
      lightPrimary: Color(0xFFc96442),
      darkPrimary: Color(0xFFd4785a),
      lightBg: Color(0xFFf5f4ed),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF141413),
      darkSurface: Color(0xFF1c1c1a),
    ),
    AppTheme(
      name: '森林绿',
      emoji: '🌲',
      lightPrimary: Color(0xFF2d6a4f),
      darkPrimary: Color(0xFF52b788),
      lightBg: Color(0xFFf0f4f0),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF0d1b12),
      darkSurface: Color(0xFF162319),
    ),
    AppTheme(
      name: '靛蓝',
      emoji: '🌊',
      lightPrimary: Color(0xFF3949ab),
      darkPrimary: Color(0xFF7986cb),
      lightBg: Color(0xFFeef0f8),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF0d1025),
      darkSurface: Color(0xFF161a35),
    ),
    AppTheme(
      name: '紫罗兰',
      emoji: '💜',
      lightPrimary: Color(0xFF7b1fa2),
      darkPrimary: Color(0xFFba68c8),
      lightBg: Color(0xFFf5eef8),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF1a0d20),
      darkSurface: Color(0xFF251630),
    ),
    AppTheme(
      name: '樱花粉',
      emoji: '🌸',
      lightPrimary: Color(0xFFc2185b),
      darkPrimary: Color(0xFFf06292),
      lightBg: Color(0xFFfdf0f3),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF200d14),
      darkSurface: Color(0xFF301620),
    ),
    AppTheme(
      name: '深海蓝',
      emoji: '🧊',
      lightPrimary: Color(0xFF0277bd),
      darkPrimary: Color(0xFF4fc3f7),
      lightBg: Color(0xFFedf5fa),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF0a1520),
      darkSurface: Color(0xFF132230),
    ),
    AppTheme(
      name: '琥珀',
      emoji: '🍯',
      lightPrimary: Color(0xFFef6c00),
      darkPrimary: Color(0xFFffb74d),
      lightBg: Color(0xFFfdf6ed),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF1a1208),
      darkSurface: Color(0xFF2a1e10),
    ),
    AppTheme(
      name: '石墨灰',
      emoji: '🪨',
      lightPrimary: Color(0xFF546e7a),
      darkPrimary: Color(0xFF90a4ae),
      lightBg: Color(0xFFF2F3F5),
      lightSurface: Color(0xFFFFFFFF),
      darkBg: Color(0xFF121416),
      darkSurface: Color(0xFF1c1e20),
    ),
  ];


  ColorScheme get colorScheme => ColorScheme(
    brightness: Brightness.light,
    primary: lightPrimary,
    secondary: lightPrimary.withValues(alpha:0.7),
    surface: lightSurface,
    error: const Color(0xFFB00020),
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: const Color(0xFF1C1B1F),
    onError: Colors.white,
  );
}
