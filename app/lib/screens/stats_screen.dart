import 'package:flutter/material.dart';
import '../models/stats.dart';
import '../models/app_theme.dart';
import '../services/stats_service.dart';

class StatsScreen extends StatefulWidget {
  final int themeIndex;
  const StatsScreen({super.key, required this.themeIndex});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  OverallStats? _stats;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final s = await StatsService.getOverall();
      setState(() { _stats = s; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.presets[widget.themeIndex];
    final accentColor = theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(title: const Text('阅读统计')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('加载失败: $_error'),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _load, child: const Text('重试')),
                ]))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildOverviewCards(accentColor),
                      const SizedBox(height: 16),
                      _buildTrendChart(accentColor),
                      const SizedBox(height: 16),
                      _buildHotNotes(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildOverviewCards(Color accentColor) {
    if (_stats == null) return const SizedBox();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.5,
      children: [
        _statCard('📝', '总笔记', '${_stats!.totalNotes}', accentColor),
        _statCard('🏷️', '总标签', '${_stats!.totalTags}', accentColor),
        _statCard('📖', '总阅读', '${_stats!.totalReads}', accentColor),
        _statCard('⏱️', '阅读时长', '${(_stats!.totalReadTime / 3600).toStringAsFixed(1)}h', accentColor),
      ],
    );
  }

  Widget _statCard(String emoji, String label, String value, Color accentColor) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: accentColor)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendChart(Color accentColor) {
    if (_stats == null || _stats!.dailyTrend.isEmpty) return const SizedBox();
    final data = _stats!.dailyTrend;
    final maxCount = data.map((d) => (d['count'] as num).toInt()).fold(0, (a, b) => a > b ? a : b);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最近 30 天阅读趋势', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: accentColor)),
            const SizedBox(height: 16),
            SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: data.map((d) {
                  final count = (d['count'] as num).toInt();
                  final height = maxCount > 0 ? (count / maxCount * 100).toDouble() : 0.0;
                  final date = d['date'].toString();
                  return Expanded(
                    child: Tooltip(
                      message: '$date: $count 次',
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        height: height,
                        decoration: BoxDecoration(
                          color: accentColor,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHotNotes() {
    if (_stats == null || _stats!.hotNotes.isEmpty) return const SizedBox();
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🔥 热门笔记 Top 10', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.presets[widget.themeIndex].colorScheme.primary)),
            const SizedBox(height: 12),
            ...List.generate(
              _stats!.hotNotes.length,
              (i) {
                final note = _stats!.hotNotes[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.orange,
                    child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  title: Text(note['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Chip(label: Text('${note['reads'] ?? 0} 次')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
