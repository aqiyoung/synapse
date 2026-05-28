import 'dart:math';
import 'package:flutter/material.dart';
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
                        primaryColor: colorScheme.primary,
                        textColor: colorScheme.onSurface,
                        surfaceColor: colorScheme.surface,
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

class _GraphWidget extends StatefulWidget {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Color primaryColor;
  final Color textColor;
  final Color surfaceColor;
  final Function(int) onNodeTap;

  const _GraphWidget({
    required this.nodes,
    required this.edges,
    required this.primaryColor,
    required this.textColor,
    required this.surfaceColor,
    required this.onNodeTap,
  });

  @override
  State<_GraphWidget> createState() => _GraphWidgetState();
}

class _GraphWidgetState extends State<_GraphWidget> {
  late Map<int, Offset> _nodePositions;
  Offset _offset = Offset.zero;
  double _scale = 1.0;
  Offset _panStart = Offset.zero;
  int? _dragNodeId;
  Offset _dragStartPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _nodePositions = {};
    _layoutNodes();
  }

  @override
  void didUpdateWidget(_GraphWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes != widget.nodes) {
      _layoutNodes();
    }
  }

  void _layoutNodes() {
    if (widget.nodes.isEmpty) return;

    final nodeRadius = 24.0;
    final padding = 40.0;

    // Calculate canvas size based on node count
    final canvasSize = max(800.0, widget.nodes.length * 15.0);
    final center = Offset(canvasSize / 2, canvasSize / 2);
    final radius = (canvasSize / 2 - padding - nodeRadius).clamp(100.0, 400.0);

    // Layout in concentric circles
    if (widget.nodes.length <= 15) {
      // Single circle
      for (var i = 0; i < widget.nodes.length; i++) {
        final angle = (2 * pi * i) / widget.nodes.length - pi / 2;
        _nodePositions[widget.nodes[i]['id']] = Offset(
          center.dx + radius * cos(angle),
          center.dy + radius * sin(angle),
        );
      }
    } else {
      // Multiple concentric circles
      final innerCount = (widget.nodes.length * 0.25).round().clamp(5, 12);
      final outerCount = widget.nodes.length - innerCount;
      final innerRadius = radius * 0.35;
      final outerRadius = radius;

      // Inner circle
      for (var i = 0; i < innerCount; i++) {
        final angle = (2 * pi * i) / innerCount - pi / 2;
        _nodePositions[widget.nodes[i]['id']] = Offset(
          center.dx + innerRadius * cos(angle),
          center.dy + innerRadius * sin(angle),
        );
      }

      // Outer circle
      for (var i = 0; i < outerCount; i++) {
        final angle = (2 * pi * i) / outerCount - pi / 2;
        _nodePositions[widget.nodes[innerCount + i]['id']] = Offset(
          center.dx + outerRadius * cos(angle),
          center.dy + outerRadius * sin(angle),
        );
      }
    }
  }

  int? _getNodeAtPosition(Offset pos) {
    final nodeRadius = 24.0;
    for (final node in widget.nodes) {
      final nodePos = _nodePositions[node['id']];
      if (nodePos == null) continue;
      final distance = (pos - nodePos).distance;
      if (distance <= nodeRadius * 1.5) {
        return node['id'];
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (details) {
        _panStart = details.focalPoint;
        _dragNodeId = _getNodeAtPosition(
          (details.focalPoint - _offset) / _scale,
        );
        if (_dragNodeId != null) {
          _dragStartPos = _nodePositions[_dragNodeId!]!;
        }
      },
      onScaleUpdate: (details) {
        setState(() {
          if (_dragNodeId != null) {
            // Drag node
            final delta = (details.focalPoint - _panStart) / _scale;
            _nodePositions[_dragNodeId!] = _dragStartPos + delta;
          } else {
            // Pan canvas
            _offset += details.focalPoint - _panStart;
            _panStart = details.focalPoint;
            if (details.scale != 1.0) {
              _scale = (_scale * details.scale).clamp(0.3, 3.0);
            }
          }
        });
      },
      onScaleEnd: (details) {
        if (_dragNodeId != null) {
          final distance =
              (_nodePositions[_dragNodeId!]! - _dragStartPos).distance;
          if (distance < 5) {
            // Tap
            widget.onNodeTap(_dragNodeId!);
          }
        }
        _dragNodeId = null;
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _GraphPainter(
          nodes: widget.nodes,
          edges: widget.edges,
          nodePositions: _nodePositions,
          primaryColor: widget.primaryColor,
          textColor: widget.textColor,
          offset: _offset,
          scale: _scale,
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Map<int, Offset> nodePositions;
  final Color primaryColor;
  final Color textColor;
  final Offset offset;
  final double scale;

  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.nodePositions,
    required this.primaryColor,
    required this.textColor,
    required this.offset,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final nodeRadius = 24.0;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    // Center the graph
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    canvas.translate(centerX, centerY);

    // Draw edges
    final edgePaint = Paint()
      ..color = primaryColor.withOpacity(0.15)
      ..strokeWidth = 1.5;

    for (final edge in edges) {
      final fromId = edge['source'] ?? edge['from'];
      final toId = edge['target'] ?? edge['to'];
      final from = nodePositions[fromId];
      final to = nodePositions[toId];
      if (from != null && to != null) {
        canvas.drawLine(from, to, edgePaint);
      }
    }

    // Draw nodes
    for (final node in nodes) {
      final pos = nodePositions[node['id']];
      if (pos == null) continue;

      // Node circle shadow
      final shadowPaint = Paint()
        ..color = primaryColor.withOpacity(0.1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(pos + const Offset(2, 2), nodeRadius, shadowPaint);

      // Node circle fill
      final nodePaint = Paint()
        ..color = primaryColor.withOpacity(0.12)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, nodeRadius, nodePaint);

      // Node circle border
      final borderPaint = Paint()
        ..color = primaryColor.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(pos, nodeRadius, borderPaint);

      // Node label
      final title = node['title'] ?? '';
      final displayTitle =
          title.length > 6 ? '${title.substring(0, 6)}..' : title;
      final textPainter = TextPainter(
        text: TextSpan(
          text: displayTitle,
          style: TextStyle(
            color: textColor.withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );
      textPainter.layout(maxWidth: nodeRadius * 2.5);
      textPainter.paint(
        canvas,
        Offset(pos.dx - textPainter.width / 2, pos.dy + nodeRadius + 6),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
