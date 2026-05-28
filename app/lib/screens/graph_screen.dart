import 'dart:math';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

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
                    : InteractiveViewer(
                        minScale: 0.3,
                        maxScale: 3.0,
                        child: CustomPaint(
                          size: const Size(2000, 2000),
                          painter: GraphPainter(
                            nodes: _nodes,
                            edges: _edges,
                            primaryColor: colorScheme.primary,
                            textColor: colorScheme.onSurface,
                            surfaceColor: colorScheme.surface,
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class GraphPainter extends CustomPainter {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Color primaryColor;
  final Color textColor;
  final Color surfaceColor;

  GraphPainter({
    required this.nodes,
    required this.edges,
    required this.primaryColor,
    required this.textColor,
    required this.surfaceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final nodePositions = <int, Offset>{};
    final nodeRadius = 24.0;
    final padding = 60.0;

    // Calculate center and radius based on node count
    final center = Offset(size.width / 2, size.height / 2);
    final minDim = size.width < size.height ? size.width : size.height;
    final radius = (minDim / 2 - padding - nodeRadius).clamp(80.0, 400.0);

    // Layout nodes in a proper circle
    for (var i = 0; i < nodes.length; i++) {
      final angle = (2 * 3.14159 * i) / nodes.length - 3.14159 / 2;
      nodePositions[nodes[i]['id']] = Offset(
        center.dx + radius * cos(angle),
        center.dy + radius * sin(angle),
      );
    }

    // Draw edges
    final edgePaint = Paint()
      ..color = primaryColor.withOpacity(0.2)
      ..strokeWidth = 1.5;

    for (final edge in edges) {
      final from = nodePositions[edge['from']];
      final to = nodePositions[edge['to']];
      if (from != null && to != null) {
        canvas.drawLine(from, to, edgePaint);
      }
    }

    // Draw nodes
    for (final node in nodes) {
      final pos = nodePositions[node['id']];
      if (pos == null) continue;

      // Node circle
      final nodePaint = Paint()
        ..color = primaryColor.withOpacity(0.15)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, nodeRadius, nodePaint);

      final borderPaint = Paint()
        ..color = primaryColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(pos, nodeRadius, borderPaint);

      // Node label
      final title = node['title'] ?? '';
      final textPainter = TextPainter(
        text: TextSpan(
          text: title.length > 6 ? '${title.substring(0, 6)}...' : title,
          style: TextStyle(
            color: textColor,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(pos.dx - textPainter.width / 2, pos.dy + nodeRadius + 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
