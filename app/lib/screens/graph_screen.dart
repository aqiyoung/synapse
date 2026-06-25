import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../services/api_service.dart';
import 'note_detail_screen.dart';
import '../widgets/glass_container.dart';

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
    if (!ApiService.isConfigured) {
      setState(() => _loading = false);
      return;
    }
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

    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          // 液态玻璃 Header
          GlassContainer(
            margin: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 8, 8, 8),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.45,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Text(
                  '知识图谱',
                  style: TextStyle(
                    fontFamily: 'MiSans',
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
                    color: colorScheme.onSurface.withValues(alpha:0.5),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colorScheme.outline.withValues(alpha:0.1)),
          Expanded(
            child: _loading
                ? Center(
                    child:
                        CircularProgressIndicator(color: colorScheme.primary))
                : _nodes.isEmpty
                    ? Center(
                        child: Text(
                          ApiService.isConfigured ? '暂无图谱数据' : '请先在设置中配置服务器',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(alpha:0.4),
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
    with TickerProviderStateMixin {
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
  Timer? _resumeTimer;

  static const _defaultColors = [
    Color(0xFFc96442),
    Color(0xFF4a9e8a),
    Color(0xFF8b6bbf),
    Color(0xFFd4a843),
    Color(0xFF5b8abf),
    Color(0xFFbf6b8a),
    Color(0xFF6bbf4a),
    Color(0xFFbf8a5b),
  ];

  @override
  void initState() {
    super.initState();
    _graphNodes = [];
    _nodeMap = {};
    _graphEdges = [];
    _initGraph();
    _ticker = createTicker((_) {
      if (_graphNodes.isEmpty) return;
      _simulate();
      setState(() {});
      // 检测平衡态：总动能低于阈值时停止 ticker，节省电量
      double totalEnergy = 0;
      for (final n in _graphNodes) {
        totalEnergy += n.vx * n.vx + n.vy * n.vy;
      }
      if (totalEnergy < 0.01 && _dragNode == null) {
        _ticker.stop();
      }
    });
    _ticker.start();
  }

  @override
  void didUpdateWidget(_GraphWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes != widget.nodes) {
      _initGraph();
      _ensureTickerRunning();
    }
  }

  void _ensureTickerRunning() {
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _initGraph() {
    _graphNodes = [];
    _nodeMap = {};
    _graphEdges = [];

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

    for (var i = 0; i < widget.nodes.length; i++) {
      final n = widget.nodes[i];
      final tags = (n['tags'] as List?)?.cast<String>() ?? [];
      final firstTag = tags.isNotEmpty ? tags.first : null;
      final color = firstTag != null
          ? (tagColorMap[firstTag] ?? const Color(0xFF8d9e8a))
          : const Color(0xFF8d9e8a);
      final angle = (2 * pi * i) / widget.nodes.length;
      final r = 200.0;
      final node = _GraphNode(
        id: n['id'],
        title: n['title'] ?? '无标题',
        tags: tags,
        color: color,
        x: r * cos(angle),
        y: r * sin(angle),
      );
      _graphNodes.add(node);
      _nodeMap[node.id] = node;
    }

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
  }

  void _simulate() {
    const alpha = 0.3;

    // Damping
    for (final n in _graphNodes) {
      n.vx *= 0.85;
      n.vy *= 0.85;
    }

    // Node repulsion
    for (var i = 0; i < _graphNodes.length; i++) {
      for (var j = i + 1; j < _graphNodes.length; j++) {
        final a = _graphNodes[i], b = _graphNodes[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        final distSq = dx * dx + dy * dy;
        final dist = sqrt(distSq);
        if (dist < 200 && dist > 0.1) {
          final f = (200 - dist) * 0.05 * alpha;
          final fx = dx / dist * f;
          final fy = dy / dist * f;
          a.vx += fx;
          a.vy += fy;
          b.vx -= fx;
          b.vy -= fy;
        }
      }
    }

    // Edge springs
    for (final e in _graphEdges) {
      final dx = e.b.x - e.a.x, dy = e.b.y - e.a.y;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist > 0.1) {
        final f = (dist - 120) * 0.008 * alpha;
        final fx = dx / dist * f;
        final fy = dy / dist * f;
        e.a.vx += fx;
        e.a.vy += fy;
        e.b.vx -= fx;
        e.b.vy -= fy;
      }
    }

    // Center gravity
    for (final n in _graphNodes) {
      n.vx += (0 - n.x) * 0.001 * alpha;
      n.vy += (0 - n.y) * 0.001 * alpha;
    }

    // Apply velocity
    for (final n in _graphNodes) {
      if (n == _dragNode) continue;
      n.x += n.vx;
      n.y += n.vy;
    }
  }

  _GraphNode? _findNode(Offset screenPos, Size widgetSize) {
    final gp =
        (screenPos - Offset(widgetSize.width / 2, widgetSize.height / 2) -
                _pan) /
            _scale;
    for (final n in _graphNodes) {
      final dx = gp.dx - n.x, dy = gp.dy - n.y;
      final hitR = max(n.radius + 8, 15.0);
      if (dx * dx + dy * dy < hitR * hitR) return n;
    }
    return null;
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        children: [
          GestureDetector(
        onTap: () {
          if (_dragNode != null) {
            widget.onNodeTap(_dragNode!.id);
            _dragNode = null;
          }
        },
        onTapDown: (details) {
          _dragNode = _findNode(details.localPosition, widgetSize);
          if (_dragNode != null) {
            _hoveredNode = _dragNode;
          }
        },
        onTapCancel: () {
          _dragNode = null;
        },
        onScaleStart: (details) {
          _resumeTimer?.cancel();
          _ensureTickerRunning();
          _lastFocal = details.focalPoint;
          _panStart = details.focalPoint - _pan;
        },
        onScaleUpdate: (details) {
          setState(() {
            if (_dragNode != null && details.pointerCount == 1) {
              final delta = (details.focalPoint - _lastFocal) / _scale;
              _dragNode!.x += delta.dx;
              _dragNode!.y += delta.dy;
              _dragNode!.vx = 0;
              _dragNode!.vy = 0;
            } else {
              _dragNode = null;
              _pan = details.focalPoint - _panStart;
              if (details.scale != 1.0) {
                _scale = (_scale * details.scale).clamp(0.3, 3.0);
              }
            }
            _lastFocal = details.focalPoint;
          });
        },
        onScaleEnd: (details) {
          _dragNode = null;
          _resumeTimer?.cancel();
          // 立即恢复 ticker，不再延迟
          _ensureTickerRunning();
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _GraphPainter(
            nodes: _graphNodes,
            edges: _graphEdges,
            pan: _pan,
            scale: _scale,
            hoveredNode: _hoveredNode,
            isDark: widget.isDark,
          ),
        ),
      ),
          // 标签图例（HTML 层，支持滚动）
          _buildTagLegend(),
        ],
      );
    });
  }

  Widget _buildTagLegend() {
    final usedTags = <String, Color>{};
    for (final n in _graphNodes) {
      if (n.tags.isNotEmpty) usedTags.putIfAbsent(n.tags.first, () => n.color);
    }
    if (usedTags.length <= 1) return const SizedBox.shrink();

    final entries = usedTags.entries.toList();
    final isDark = widget.isDark;

    return Positioned(
      top: 12,
      right: 12,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 200),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1c1c1a).withValues(alpha:0.95) : Colors.white.withValues(alpha:0.95),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha:0.08),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'TAGS',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: (isDark ? Colors.white : Colors.black).withValues(alpha:0.4),
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: e.value,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          e.key,
                          style: TextStyle(
                            fontSize: 11,
                            color: (isDark ? Colors.white : Colors.black).withValues(alpha:0.6),
                          ),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Edge {
  final _GraphNode a, b;
  _Edge(this.a, this.b);
}

class _GraphPainter extends CustomPainter {
  final List<_GraphNode> nodes;
  final List<_Edge> edges;
  final Offset pan;
  final double scale;
  final _GraphNode? hoveredNode;
  final bool isDark;

  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.pan,
    required this.scale,
    required this.hoveredNode,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final bg = isDark ? const Color(0xFF141413) : const Color(0xFFf5f4ed);
    final fg = isDark ? const Color(0xFFe4ece0) : const Color(0xFF141413);

    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = bg);

    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.scale(scale);

    _drawGrid(canvas, size, fg);

    // Edges
    for (final e in edges) {
      final isHov = hoveredNode != null &&
          (hoveredNode!.id == e.a.id || hoveredNode!.id == e.b.id);
      final edgePaint = Paint()
        ..color = fg.withValues(alpha:isHov ? 0.35 : 0.12)
        ..strokeWidth = isHov ? 1.8 : 1.0;
      canvas.drawLine(Offset(e.a.x, e.a.y), Offset(e.b.x, e.b.y), edgePaint);
    }

    final maxDeg =
        nodes.fold<int>(0, (m, n) => n.degree > m ? n.degree : m).toDouble();
    if (maxDeg == 0) return;

    // Nodes
    for (final n in nodes) {
      final isHov = hoveredNode?.id == n.id;
      final normalizedDeg = n.degree / maxDeg;
      final r = isHov ? 6.0 : (3.0 + normalizedDeg * 13.0);

      // Glow
      if (isHov || n.degree >= 4) {
        final glowR = r + (isHov ? 16.0 : 10.0);
        final glowAlpha = isHov ? 0.25 : 0.12;
        final grad = ui.Gradient.radial(
          Offset(n.x, n.y),
          glowR,
          [n.color.withValues(alpha:glowAlpha), n.color.withValues(alpha:0.0)],
        );
        canvas.drawCircle(Offset(n.x, n.y), glowR, Paint()..shader = grad);
      }

      // Ring
      if (n.degree >= 3 && !isHov) {
        canvas.drawCircle(
            Offset(n.x, n.y),
            r + 2,
            Paint()
              ..color = n.color.withValues(alpha:0.3)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
      }

      // Fill
      canvas.drawCircle(
          Offset(n.x, n.y), r, Paint()..color = isHov ? fg : n.color);

      // Highlight
      if (r >= 6) {
        canvas.drawCircle(
            Offset(n.x - r * 0.25, n.y - r * 0.25),
            r * 0.35,
            Paint()..color = Colors.white.withValues(alpha:0.15));
      }

      // Label
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
              color: fg.withValues(alpha:isHov ? 1.0 : 0.5 + normalizedDeg * 0.4),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(n.x - tp.width / 2, n.y + r + 10));
      }
    }

    canvas.restore();
    // 标签图例已移至 HTML 层，支持滚动
  }

  void _drawGrid(Canvas canvas, Size size, Color fg) {
    const gridSize = 60.0;
    final left = (-size.width / 2 - pan.dx) / scale;
    final top = (-size.height / 2 - pan.dy) / scale;
    final right = (size.width / 2 - pan.dx) / scale;
    final bottom = (size.height / 2 - pan.dy) / scale;

    final startX = (left / gridSize).floor() * gridSize;
    final startY = (top / gridSize).floor() * gridSize;

    final gridPaint = Paint()
      ..color = fg.withValues(alpha:0.06)
      ..strokeWidth = 0.5;

    for (var x = startX; x <= right; x += gridSize) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), gridPaint);
    }
    for (var y = startY; y <= bottom; y += gridSize) {
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) => true;
}
