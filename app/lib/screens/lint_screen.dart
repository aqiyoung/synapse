import 'package:flutter/material.dart';
import '../services/api_service.dart';

class LintScreen extends StatefulWidget {
  const LintScreen({super.key});

  @override
  State<LintScreen> createState() => _LintScreenState();
}

class _LintScreenState extends State<LintScreen> {
  Map<String, dynamic>? _lintData;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLint();
  }

  Future<void> _loadLint() async {
    if (!ApiService.isConfigured) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final data = await ApiService.getLint();
      setState(() {
        _lintData = data;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        final msg = e.toString().contains('SocketException')
            ? '无法连接服务器，请检查网络或在设置中修改服务器地址'
            : '加载检查数据失败';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
          Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 16, 20, 12),
            color: colorScheme.surface,
            child: Row(
              children: [
                Text(
                  '健康检查',
                  style: TextStyle(
                    fontFamily: 'Georgia',
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.refresh,
                      color: colorScheme.onSurface.withOpacity(0.5)),
                  onPressed: _loadLint,
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
                : _lintData == null
                    ? Center(
                        child: Text(
                          ApiService.isConfigured ? '加载失败' : '请先在设置中配置服务器',
                          style: TextStyle(
                            color: colorScheme.onSurface.withOpacity(0.4),
                          ),
                        ),
                      )
                    : _buildContent(colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    final stats = _lintData!['stats'] ?? {};
    final issues = _lintData!['issues'] ?? [];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Stats grid
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.8,
          children: [
            _buildStatCard('笔记总数', '${stats['total_notes'] ?? 0}',
                Icons.library_books, colorScheme),
            _buildStatCard(
                '链接密度',
                '${((stats['link_density'] ?? 0) * 100).toInt()}%',
                Icons.link,
                colorScheme),
            _buildStatCard(
                '孤立笔记',
                '${stats['orphan_count'] ?? 0}',
                Icons.warning_amber,
                colorScheme,
                isWarning: (stats['orphan_count'] ?? 0) > 0),
            _buildStatCard(
                '断链',
                '${stats['broken_link_count'] ?? 0}',
                Icons.link_off,
                colorScheme,
                isError: (stats['broken_link_count'] ?? 0) > 0),
          ],
        ),
        const SizedBox(height: 24),
        // Issues
        if (issues.isNotEmpty) ...[
          Text(
            '发现的问题',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ...issues.map((issue) => _buildIssueCard(issue, colorScheme)),
        ] else ...[
          Center(
            child: Column(
              children: [
                const SizedBox(height: 40),
                Icon(Icons.check_circle_outline,
                    size: 48, color: Colors.green),
                const SizedBox(height: 12),
                Text(
                  '一切正常',
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    ColorScheme colorScheme, {
    bool isWarning = false,
    bool isError = false,
  }) {
    Color valueColor = colorScheme.onSurface;
    if (isError) valueColor = Colors.red;
    if (isWarning) valueColor = Colors.orange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colorScheme.primary),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  color: valueColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIssueCard(Map<String, dynamic> issue, ColorScheme colorScheme) {
    final type = issue['type'] ?? '';
    final message = issue['message'] ?? '';
    final severity = issue['severity'] ?? 'info';

    Color severityColor;
    IconData severityIcon;
    switch (severity) {
      case 'error':
        severityColor = Colors.red;
        severityIcon = Icons.error_outline;
        break;
      case 'warning':
        severityColor = Colors.orange;
        severityIcon = Icons.warning_amber;
        break;
      default:
        severityColor = Colors.blue;
        severityIcon = Icons.info_outline;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(severityIcon, size: 18, color: severityColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (issue['notes'] != null) ...[
            const SizedBox(height: 8),
            ...(issue['notes'] as List).take(5).map((n) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '• ${n['title'] ?? ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                )),
          ],
          if (issue['links'] != null) ...[
            const SizedBox(height: 8),
            ...(issue['links'] as List).take(5).map((l) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '• ${l['from']} → ${l['to']}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}
