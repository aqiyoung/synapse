import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_service.dart';
import 'settings_screen.dart';
import 'lint_screen.dart';

class MineScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;

  const MineScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
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
          // 头部 - 版本信息
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outline.withOpacity(0.1),
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.person_outline,
                  size: 48,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'Synapse',
                  style: TextStyle(
                    fontFamily: 'MiSans',
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'v$_version',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'AI 驱动的个人知识管理',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 更新检查
          _buildUpdateSection(colorScheme),
          const SizedBox(height: 12),

          // 健康检查入口
          _buildSection(
            colorScheme,
            title: '知识库健康',
            icon: Icons.health_and_safety_outlined,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LintScreen()),
              );
            },
          ),
          const SizedBox(height: 12),

          // 设置入口
          _buildSection(
            colorScheme,
            title: '设置',
            icon: Icons.settings_outlined,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    onToggleTheme: widget.onToggleTheme,
                    isDark: widget.isDark,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // 关于信息
          Container(
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
                Text(
                  '关于',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(colorScheme, '技术栈', 'Flutter + FastAPI + SQLite'),
                _buildInfoRow(colorScheme, 'AI 能力', '自动标签 · 自动关联 · 自动质检'),
                _buildInfoRow(colorScheme, '开源地址', 'github.com/aqiyoung/synapse'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
    ColorScheme colorScheme, {
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outline.withOpacity(0.1),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colorScheme.primary),
            const SizedBox(width: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.arrow_forward_ios,
              size: 14,
              color: colorScheme.onSurface.withOpacity(0.3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateSection(ColorScheme colorScheme) {
    final hasUpdate = UpdateService().hasUpdate;

    return InkWell(
      onTap: () async {
        if (hasUpdate) {
          _showUpdateDialog(colorScheme);
        } else {
          await UpdateService().check();
          if (mounted) {
            setState(() {});
            if (UpdateService().hasUpdate) {
              _showUpdateDialog(colorScheme);
            }
          }
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outline.withOpacity(0.1),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.system_update_outlined,
              size: 20,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasUpdate
                        ? '新版本 ${UpdateService().cached!.latestVersion} 可用'
                        : '检查更新',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    hasUpdate ? '点击查看更新内容' : '自动检查新版本',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
            if (hasUpdate)
              Icon(Icons.arrow_forward_ios, size: 14, color: colorScheme.primary)
            else
              Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(ColorScheme colorScheme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withOpacity(0.8),
              ),
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
