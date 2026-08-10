import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// 液态玻璃容器（iOS 26 / iOS 18 Liquid Glass 风格）
///
/// 实现原理（3 层叠）：
///   1. BackdropFilter 高斯模糊（模拟玻璃透光）
///   2. 半透明 tint（玻璃染色，让背景颜色透出来但有玻璃感）
///   3. 顶部高光渐变（模拟光线折射，1px 亮线）
///
/// 性能建议：
///   - sigma <= 30 流畅（小米15 / 骁龙8 Gen3 跑 sigma=40 也没问题）
///   - 低端机（骁龙7系以下）建议 sigma <= 15
class GlassContainer extends StatelessWidget {
  /// 子组件
  final Widget child;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 自定义形状（优先级高于 borderRadius）
  final ShapeBorder? shape;

  /// 模糊半径（默认 20）。值越大越模糊，越吃 GPU
  final double blur;

  /// tint 颜色（玻璃染色）。默认根据主题自动选
  final Color? tint;

  /// tint 不透明度（0-1）。默认 0.3
  final double tintOpacity;

  /// 边缘高光强度（0-1）。0 = 不画高光
  final double highlightStrength;

  /// 边框颜色（默认根据主题）
  final Color? borderColor;

  /// 边框宽度
  final double borderWidth;

  /// 内边距
  final EdgeInsetsGeometry? padding;

  /// 外边距
  final EdgeInsetsGeometry? margin;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.shape,
    this.blur = 20,
    this.tint,
    this.tintOpacity = 0.3,
    this.highlightStrength = 0.6,
    this.borderColor,
    this.borderWidth = 1.0,
    this.padding,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 默认 tint：暗色主题用白色，亮色主题用白色（带较高 alpha）
    // iOS 26 的做法是：亮色用半透明白，暗色用半透明白+一点灰
    final effectiveTint =
        tint ??
        (isDark
            ? const Color(0xFF1c1c1e).withValues(alpha: 0.3) // 暗色：深灰玻璃
            : const Color(0xFFFFFFFF).withValues(alpha: 0.5)); // 亮色：白玻璃

    final effectiveBorder =
        borderColor ??
        (isDark
            ? const Color(0xFFFFFFFF).withValues(alpha: 0.12) // 暗色：白色细线
            : const Color(0xFF000000).withValues(alpha: 0.08)); // 亮色：黑色细线

    // 形状（borderRadius 或 shape）
    final effectiveShape =
        shape ??
        RoundedRectangleBorder(
          borderRadius: borderRadius ?? BorderRadius.circular(20),
        );

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: ClipPath.shape(
        shape: effectiveShape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            painter: _GlassPainter(
              shape: effectiveShape,
              tint: effectiveTint,
              tintOpacity: tintOpacity,
              borderColor: effectiveBorder,
              borderWidth: borderWidth,
              highlightStrength: highlightStrength,
              isDark: isDark,
            ),
            child:
                padding != null
                    ? Padding(padding: padding!, child: child)
                    : child,
          ),
        ),
      ),
    );
  }
}

/// 自定义绘制：tint 底色 + 边框 + 顶部高光渐变
class _GlassPainter extends CustomPainter {
  final ShapeBorder shape;
  final Color tint;
  final double tintOpacity;
  final Color borderColor;
  final double borderWidth;
  final double highlightStrength;
  final bool isDark;

  _GlassPainter({
    required this.shape,
    required this.tint,
    required this.tintOpacity,
    required this.borderColor,
    required this.borderWidth,
    required this.highlightStrength,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 取出形状的 path（加 1px inset 以避免 borderWidth 2px 边突到 ClipPath 外）
    final path = shape.getOuterPath(Offset.zero & size);

    // 1. 底色 tint
    final fillPaint = Paint()..color = tint.withValues(alpha: tintOpacity);
    canvas.drawPath(path, fillPaint);

    // 2. 顶部高光渐变（模拟光线折射）
    if (highlightStrength > 0) {
      // 用形状的 path.getBounds() 作为 shader 范围，
      // 这样渐变在边角处也是沿着形状的。
      final shaderRect = path.getBounds();
      final highlightPaint =
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.25 * highlightStrength),
                Colors.transparent,
              ],
              stops: const [0.0, 0.5],
            ).createShader(shaderRect);
      canvas.drawPath(path, highlightPaint);
    }

    // 3. 边框（1px 描边）
    if (borderWidth > 0) {
      final borderPaint =
          Paint()
            ..color = borderColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = borderWidth;
      canvas.drawPath(path, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GlassPainter old) {
    return old.tint != tint ||
        old.tintOpacity != tintOpacity ||
        old.borderColor != borderColor ||
        old.borderWidth != borderWidth ||
        old.highlightStrength != highlightStrength ||
        old.isDark != isDark;
  }
}
