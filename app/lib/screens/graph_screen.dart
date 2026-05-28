import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../services/api_service.dart';
import 'note_detail_screen.dart';

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  List<Map<String, dynamic>> _nodes = [];
  List<Map<String, dynamic>> _edges = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadGraph();
  }

  Future<void> _loadGraph() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getGraph();
      setState(() {
        _nodes = List<Map<String, dynamic>>.from(data['nodes'] ?? []);
        _edges = List<Map<String, dynamic>>.from(data['edges'] ?? []);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        final msg = e.toString().contains('SocketException')
            ? '无法连接服务器，请检查网络或在设置中修改服务器地址'
            : '加载图谱失败';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            color: colorScheme.surface,
            child: Row(
              children: [
                Text(
                  '知识图谱',
                  style: TextStyle(
                    fontFamily: 'Georgia',
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_nodes.length} 节点 · ${_edges.length} 连接',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.1)),
          Expanded(
            child: _loading
                ? Center(
                    child:
                        CircularProgressIndicator(color: colorScheme.primary))
                : _nodes.isEmpty
                    ? Center(
                        child: Text(
                          '暂无图谱数据',
                          style: TextStyle(
                            color: colorScheme.onSurface.withOpacity(0.4),
                          ),
                        ),
                      )
                    : _GraphWidget(
                        nodes: _nodes,
                        edges: _edges,
                        isDark: Theme.of(context).brightness ==
                            Brightness.dark,
                        onNodeTap: (nodeId) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => NoteDetailScreen(noteId: nodeId),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// Internal node representation with physics state
class _GraphNode {
  final int id;
  final String title;
  final List<String> tags;
  Color color;
  double x, y;
  double vx, vy;
  int degree;

  _GraphNode({
    required this.id,
    required this.title,
    required this.tags,
    required this.color,
    required this.x,
    required this.y,
    this.vx = 0,
    this.vy = 0,
    this.degree = 0,
  });

  double get radius => 3 + (degree / 1.0).clamp(0, 1) * 13;
}

class _GraphWidget extends StatefulWidget {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final bool isDark;
  final Function(int) onNodeTap;

  const _GraphWidget({
    required this.nodes,
    required this.edges,
    required this.isDark,
    required this.onNodeTap,
  });

  @override
  State<_GraphWidget> createState() => _GraphWidgetState();
}

class _GraphWidgetState extends State<_GraphWidget>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late List<_GraphNode> _graphNodes;
  late Map<int, _GraphNode> _nodeMap;
  late List<_Edge> _graphEdges;
  Offset _pan = Offset.zero;
  double _scale = 1.0;
  _GraphNode? _dragNode;
  _GraphNode? _hoveredNode;
  Offset _panStart = Offset.zero;
  Offset _lastFocal = Offset.zero;
  bool _needsPaint = true;

  // Default tag color palette (fallback when tag has no color)
  static const _defaultColors = [
    Color(0xFFc96442), // terracotta
    Color(0xFF4a9e8a), // teal
    Color(0xFF8b6bbf), // purple
    Color(0xFFd4a843), // gold
    Color(0xFF5b8abf), // blue
    Color(0xFFbf6b8a), // pink
    Color(0xFF6bbf4a), // green
    Color(0xFFbf8a5b), // brown
  ];

  @override
  void initState() {
    super.initState();
    _initGraph();
    _ticker = Ticker(_onTick)..start();
  }

  @override
  void didUpdateWidget(_GraphWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes != widget.nodes) {
      _initGraph();
    }
  }

  void _initGraph() {
    _graphNodes = [];
    _nodeMap = {};
    _graphEdges = [];

    // Build tag color map
    final tagColorMap = <String, Color>{};
    final allTags = <String>{};
    for (final n in widget.nodes) {
      final tags = (n['tags'] as List?)?.cast<String>() ?? [];
      if (tags.isNotEmpty) allTags.add(tags.first);
    }
    var colorIdx = 0;
    for (final tag in allTags) {
      tagColorMap[tag] = _defaultColors[colorIdx % _defaultColors.length];
      colorIdx++;
    }

    // Create nodes in a circle
    final cx = 0.0, cy = 0.0, r = 200.0;
    for (var i = 0; i < widget.nodes.length; i++) {
      final n = widget.nodes[i];
      final tags = (n['tags'] as List?)?.cast<String>() ?? [];
      final firstTag = tags.isNotEmpty ? tags.first : null;
      final color = firstTag != null
          ? (tagColorMap[firstTag] ?? const Color(0xFF8d9e8a))
          : const Color(0xFF8d9e8a);
      final angle = (2 * pi * i) / widget.nodes.length;
      final node = _GraphNode(
        id: n['id'],
        title: n['title'] ?? '无标题',
        tags: tags,
        color: color,
        x: cx + r * cos(angle),
        y: cy + r * sin(angle),
      );
      _graphNodes.add(node);
      _nodeMap[node.id] = node;
    }

    // Create edges and compute degree
    for (final e in widget.edges) {
      final srcId = e['source'] ?? e['from'];
      final tgtId = e['target'] ?? e['to'];
      final src = _nodeMap[srcId];
      final tgt = _nodeMap[tgtId];
      if (src != null && tgt != null) {
        _graphEdges.add(_Edge(src, tgt));
        src.degree++;
        tgt.degree++;
      }
    }

    _needsPaint = true;
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    _tick();
    if (_needsPaint) {
      setState(() {
        _needsPaint = false;
      });
    }
  }

  void _tick() {
    if (_graphNodes.isEmpty) return;
    const alpha = 0.25;
    final w = context.size?.width ?? 400.0;
    final h = context.size?.height ?? 600.0;

    // Damping
    for (final n in _graphNodes) {
      n.vx *= 0.9;
      n.vy *= 0.9;
    }

    // Node repulsion
    for (var i = 0; i < _graphNodes.length; i++) {
      for (var j = i + 1; j < _graphNodes.length; j++) {
        final a = _graphNodes[i], b = _graphNodes[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist < 180 && dist > 0) {
          final f = (180 - dist) * 0.04 * alpha;
          a.vx += dx / dist * f;
          a.vy += dy / dist * f;
          b.vx -= dx / dist * f;
          b.vy -= dy / dist * f;
        }
      }
    }

    // Edge springs
    for (final e in _graphEdges) {
      final dx = e.b.x - e.a.x, dy = e.b.y - e.a.y;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist > 0) {
        final f = (dist - 100) * 0.006 * alpha;
        e.a.vx += dx / dist * f;
        e.a.vy += dy / dist * f;
        e.b.vx -= dx / dist * f;
        e.b.vy -= dy / dist * f;
      }
    }

    // Center gravity
    for (final n in _graphNodes) {
      n.vx += (0 - n.x) * 0.0005 * alpha;
      n.vy += (0 - n.y) * 0.0005 * alpha;
    }

    // Apply velocity (skip dragged node)
    for (final n in _graphNodes) {
      if (n == _dragNode) continue;
      n.x += n.vx;
      n.y += n.vy;
    }

    _needsPaint = true;
  }

  _GraphNode? _findNode(Offset screenPos, Size widgetSize) {
    // Convert screen to graph space
    final gp =
        (screenPos - Offset(widgetSize.width / 2, widgetSize.height / 2) -
                _pan) /
            _scale;
    for (final n in _graphNodes) {
      final dx = gp.dx - n.x, dy = gp.dy - n.y;
      if (dx * dx + dy * dy < (n.radius + 8) * (n.radius + 8)) {
        return n;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        onScaleStart: (details) {
          _lastFocal = details.focalPoint;
          _dragNode = _findNode(details.focalPoint, widgetSize);
          if (_dragNode != null) {
            _hoveredNode = _dragNode;
          } else {
            _panStart = details.focalPoint - _pan;
          }
        },
        onScaleUpdate: (details) {
          setState(() {
            if (_dragNode != null) {
              final delta = (details.focalPoint - _lastFocal) / _scale;
              _dragNode!.x += delta.dx;
              _dragNode!.y += delta.dy;
              _dragNode!.vx = 0;
              _dragNode!.vy = 0;
            } else {
              _pan = details.focalPoint - _panStart;
              if (details.scale != 1.0) {
                _scale = (_scale * details.scale).clamp(0.3, 3.0);
              }
            }
            _lastFocal = details.focalPoint;
          });
        },
        onScaleEnd: (details) {
          if (_dragNode != null) {
            // Check if it was a tap (not a drag)
            final node = _dragNode!;
            _dragNode = null;
            // Single pointer = potential tap
            if (details.pointerCount == 1) {
              widget.onNodeTap(node.id);
            }
          }
          _dragNode = null;
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _GraphPainter(
            nodes: _graphNodes,
            edges: _graphEdges,
            nodeMap: _nodeMap,
            pan: _pan,
            scale: _scale,
            hoveredNode: _hoveredNode,
            isDark: widget.isDark,
            widgetSize: widgetSize,
          ),
        ),
      );
    });
  }
}

class _Edge {
  final _GraphNode a, b;
  _Edge(this.a, this.b);
}

class _GraphPainter extends CustomPainter {
  final List<_GraphNode> nodes;
  final List<_Edge> edges;
  final Map<int, _GraphNode> nodeMap;
  final Offset pan;
  final double scale;
  final _GraphNode? hoveredNode;
  final bool isDark;
  final Size widgetSize;

  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.nodeMap,
    required this.pan,
    required this.scale,
    required this.hoveredNode,
    required this.isDark,
    required this.widgetSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final bg = isDark ? const Color(0xFF141413) : const Color(0xFFf5f4ed);
    final fg = isDark ? const Color(0xFFe4ece0) : const Color(0xFF141413);

    // Background
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = bg);

    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.scale(scale);

    // Grid
    _drawGrid(canvas, size, fg);

    // Edges
    for (final e in edges) {
      final isHov = hoveredNode != null &&
          (hoveredNode!.id == e.a.id || hoveredNode!.id == e.b.id);
      final edgePaint = Paint()
        ..color = fg.withOpacity(isHov ? 0.35 : 0.12)
        ..strokeWidth = isHov ? 1.8 : 1.0;
      canvas.drawLine(Offset(e.a.x, e.a.y), Offset(e.b.x, e.b.y), edgePaint);
    }

    // Compute max degree for normalization
    final maxDeg =
        nodes.fold<int>(0, (m, n) => n.degree > m ? n.degree : m).toDouble();
    if (maxDeg == 0) return;

    // Nodes
    for (final n in nodes) {
      final isHov = hoveredNode?.id == n.id;
      final normalizedDeg = n.degree / maxDeg;
      final r = isHov ? 6.0 : (3.0 + normalizedDeg * 13.0);

      // Glow for hovered or high-degree nodes
      if (isHov || n.degree >= 4) {
        final glowR = r + (isHov ? 16.0 : 10.0);
        final glowAlpha = isHov ? 0.25 : 0.12;
        final grad = ui.Gradient.radial(
          Offset(n.x, n.y),
          glowR,
          [
            n.color.withOpacity(glowAlpha),
            n.color.withOpacity(0.0),
          ],
        );
        canvas.drawCircle(Offset(n.x, n.y), glowR, Paint()..shader = grad);
      }

      // Ring for degree >= 3
      if (n.degree >= 3 && !isHov) {
        canvas.drawCircle(
          Offset(n.x, n.y),
          r + 2,
          Paint()
            ..color = n.color.withOpacity(0.3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }

      // Node fill
      canvas.drawCircle(
        Offset(n.x, n.y),
        r,
        Paint()..color = isHov ? fg : n.color,
      );

      // Highlight dot for larger nodes
      if (r >= 6) {
        canvas.drawCircle(
          Offset(n.x - r * 0.25, n.y - r * 0.25),
          r * 0.35,
          Paint()..color = Colors.white.withOpacity(0.15),
        );
      }

      // Label for hovered or high-degree nodes
      if (isHov || n.degree >= 5) {
        final fontSize = max(10.0, min(13.0, 9.0 + normalizedDeg * 4.0));
        final label =
            n.title.length > 20 ? '${n.title.substring(0, 20)}...' : n.title;
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: isHov ? FontWeight.w600 : FontWeight.w500,
              color: fg.withOpacity(isHov ? 1.0 : 0.5 + normalizedDeg * 0.4),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(n.x - tp.width / 2, n.y + r + 10));
      }
    }

    canvas.restore();

    // Tag legend (outside graph transform)
    _drawTagLegend(canvas, size, fg);
  }

  void _drawGrid(Canvas canvas, Size size, Color fg) {
    const gridSize = 60.0;
    // Calculate visible range in graph space
    final left = (-size.width / 2 - pan.dx) / scale;
    final top = (-size.height / 2 - pan.dy) / scale;
    final right = (size.width / 2 - pan.dx) / scale;
    final bottom = (size.height / 2 - pan.dy) / scale;

    final startX = (left / gridSize).floor() * gridSize;
    final startY = (top / gridSize).floor() * gridSize;

    final gridPaint = Paint()
      ..color = fg.withOpacity(0.06)
      ..strokeWidth = 0.5;

    for (var x = startX; x <= right; x += gridSize) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), gridPaint);
    }
    for (var y = startY; y <= bottom; y += gridSize) {
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }
  }

  void _drawTagLegend(Canvas canvas, Size size, Color fg) {
    final usedTags = <String, Color>{};
    for (final n in nodes) {
      if (n.tags.isNotEmpty) {
        usedTags.putIfAbsent(n.tags.first, () => n.color);
      }
    }
    if (usedTags.length <= 1) return;

    final entries = usedTags.entries.toList();
    const pad = 10.0;
    const lh = 18.0;
    const titleH = 16.0;

    final maxW = entries
        .map((e) => e.key.length * 7.0)
        .reduce((a, b) => a > b ? a : b);
    final boxW = pad * 2 + 10 + maxW;
    final boxH = pad * 2 + titleH + entries.length * lh;
    final bx = size.width - boxW - 12;
    final by = size.height - boxH - 12;

    // Box background
    final bgRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, by, boxW, boxH), const Radius.circular(6));
    canvas.drawRRect(
        bgRect,
        Paint()
          ..color = (isDark
              ? const Color(0xFF1c1c1a)
              : Colors.white)
              .withOpacity(0.95));
    canvas.drawRRect(
        bgRect,
        Paint()
          ..color = fg.withOpacity(0.08)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    // Title
    final titleTp = TextPainter(
      text: TextSpan(
        text: 'TAGS',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: fg.withOpacity(0.4),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titleTp.paint(canvas, Offset(bx + pad, by + pad + 4));

    // Tag entries
    for (var i = 0; i < entries.length; i++) {
      final iy = by + titleH + pad + i * lh + 4;
      canvas.drawCircle(Offset(bx + pad + 4, iy), 3,
          Paint()..color = entries[i].value);
      final tagTp = TextPainter(
        text: TextSpan(
          text: entries[i].key,
          style: TextStyle(
            fontSize: 11,
            color: fg.withOpacity(0.6),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tagTp.paint(canvas, Offset(bx + pad + 12, iy - 5));
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) => true;
}
