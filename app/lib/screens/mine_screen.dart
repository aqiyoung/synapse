import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_service.dart';
import 'settings_screen.dart';
import 'lint_screen.dart';

class MineScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;
  final int themeIndex;
  final ValueChanged<int> onThemeChanged;

  const MineScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
    required this.themeIndex,
    required this.onThemeChanged,
  });

  @override
  State<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends State<MineScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _autoCheckUpdate();
  }

  Future<void> _autoCheckUpdate() async {
    await UpdateService().check();
    if (mounted && UpdateService().hasUpdate) {
      setState(() {});
      _showUpdateDialog(Theme.of(context).colorScheme);
    }
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surface,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 16, 16, 16),
        children: [
          // 头部 - 版本信息（无边框）
          Column(
            children: [
              // Logo
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      colorScheme.primary,
                      colorScheme.primary.withOpacity(0.7),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: colorScheme.primary.withOpacity(0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.psychology,
                  size: 36,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Synapse',
                style: TextStyle(
                  fontFamily: 'MiSans',
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              // Slogan
              Text(
                '记录思考，连接知识',
                style: TextStyle(
                  fontSize: 15,
                  color: colorScheme.onSurface.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '让每一个想法都有归处',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 16),
              // 版本号
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'v$_version',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 功能入口
          Row(
            children: [
              Expanded(
                child: _buildQuickAction(
                  colorScheme,
                  icon: Icons.health_and_safety_outlined,
                  label: '健康检查',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LintScreen()),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildQuickAction(
                  colorScheme,
                  icon: Icons.system_update_outlined,
                  label: '检查更新',
                  onTap: () async {
                    await UpdateService().check();
                    if (!mounted) return;
                    setState(() {});
                    if (UpdateService().hasUpdate) {
                      _showUpdateDialog(colorScheme);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已是最新版本')),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildQuickAction(
                  colorScheme,
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        onToggleTheme: widget.onToggleTheme,
                        isDark: widget.isDark,
                        themeIndex: widget.themeIndex,
                        onThemeChanged: widget.onThemeChanged,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 关于信息
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withOpacity(0.3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '关于 Synapse',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildInfoRow(
                  colorScheme,
                  icon: Icons.code_rounded,
                  label: '技术栈',
                  value: 'Flutter + FastAPI + SQLite',
                ),
                _buildInfoRow(
                  colorScheme,
                  icon: Icons.auto_awesome_rounded,
                  label: 'AI 能力',
                  value: '自动标签 · 自动关联 · 智能问答',
                ),
                _buildInfoRow(
                  colorScheme,
                  icon: Icons.storage_rounded,
                  label: '数据存储',
                  value: '本地优先，隐私可控',
                ),
                _buildInfoRow(
                  colorScheme,
                  icon: Icons.link_rounded,
                  label: '开源地址',
                  value: 'github.com/aqiyoung/synapse',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 底部
          Center(
            child: Text(
              '用心记录，用知识连接未来',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withOpacity(0.4),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildQuickAction(
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: colorScheme.surfaceContainerHighest.withOpacity(0.4),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(icon, size: 24, color: colorScheme.primary),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurface.withOpacity(0.8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showUpdateDialog(ColorScheme colorScheme) {
    final info = UpdateService().cached!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.system_update, color: colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            Text('v${info.latestVersion}', style: const TextStyle(fontSize: 18)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (info.releaseNotes != null && info.releaseNotes!.isNotEmpty) ...[
                Text(
                  '更新内容',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  info.releaseNotes!,
                  style: TextStyle(fontSize: 14, height: 1.6, color: colorScheme.onSurface),
                ),
              ] else
                Text(
                  '发现新版本，是否前往下载？',
                  style: TextStyle(fontSize: 14, color: colorScheme.onSurface),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: colorScheme.onSurface.withOpacity(0.6))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              UpdateService().downloadUpdate();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }
}
