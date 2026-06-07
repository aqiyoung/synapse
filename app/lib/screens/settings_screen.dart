import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/api_service.dart';
import '../services/update_service.dart';
import '../models/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;
  final int themeIndex;
  final ValueChanged<int> onThemeChanged;

  const SettingsScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
    required this.themeIndex,
    required this.onThemeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _serverController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _saved = false;
  bool _showAdminLogin = false;
  bool _isLoggedIn = false;
  int _versionTapCount = 0;
  String _currentVersion = '';
  String _updateChannel = 'stable';

  // 管理员密码已改为服务端校验，不再硬编码在客户端

  bool get _isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _loadServer();
    _checkLoginState();
    _loadVersion();
    _loadUpdateChannel();
  }

  Future<void> _loadVersion() async {
    final v = await _getCurrentVersion();
    if (mounted) setState(() => _currentVersion = v);
  }

  Future<String> _getCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '2.2.4';
    }
  }

  Future<void> _loadUpdateChannel() async {
    await UpdateService().loadChannel();
    if (mounted) {
      setState(() {
        _updateChannel = UpdateService().channel;
      });
    }
  }

  Future<void> _setUpdateChannel(String channel) async {
    await UpdateService().setChannel(channel);
    if (mounted) {
      setState(() {
        _updateChannel = channel;
      });
    }
  }

  Future<void> _checkUpdate() async {
    await UpdateService().check();
    if (mounted) setState(() {});
  }

  void _showUpdateDialog(BuildContext context, ColorScheme colorScheme) {
    final info = UpdateService().cached!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.system_update, color: colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            Text('v${info.latestVersion}', style: TextStyle(fontSize: 18)),
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

  @override
  void dispose() {
    _serverController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadServer() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server') ?? '';
    setState(() {
      _serverController.text = server;
    });
  }

  Future<void> _checkLoginState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isLoggedIn = prefs.getBool('admin_logged_in') ?? false;
    });
  }

  Future<void> _saveServer() async {
    final server = _serverController.text.trim();
    if (server.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server', server);
    await ApiService.setServer(server);

    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  void _onVersionTap() {
    setState(() {
      _versionTapCount++;
      if (_versionTapCount >= 3) {
        _showAdminLogin = !_showAdminLogin;
        _versionTapCount = 0;
      }
    });
  }

  void _showLoginDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('管理员登录'),
        content: TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: InputDecoration(
            hintText: '请输入管理员密码',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onSubmitted: (_) => _login(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: _login,
            child: const Text('登录'),
          ),
        ],
      ),
    );
  }

  Future<void> _login() async {
    final ok = await ApiService.verifyAdmin(_passwordController.text);
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('admin_logged_in', true);
      setState(() => _isLoggedIn = true);
      _passwordController.clear();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登录成功')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码错误')),
      );
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('admin_logged_in', false);
    setState(() => _isLoggedIn = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出登录')),
    );
  }

  Widget _buildThemeGrid(ColorScheme colorScheme) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.75,
      ),
      itemCount: AppTheme.presets.length,
      itemBuilder: (context, index) {
        final preset = AppTheme.presets[index];
        final selected = index == widget.themeIndex;
        final displayColor = widget.isDark ? preset.darkPrimary : preset.lightPrimary;

        return GestureDetector(
          onTap: () {
            widget.onThemeChanged(index);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: displayColor,
                  borderRadius: BorderRadius.circular(16),
                  border: selected
                      ? Border.all(color: colorScheme.onSurface, width: 2.5)
                      : null,
                  boxShadow: [
                    BoxShadow(
                      color: displayColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: selected
                    ? const Icon(Icons.check, color: Colors.white, size: 24)
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                preset.name,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? colorScheme.onSurface
                      : colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── 外观 ──
          Text(
            '外观',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: Icon(
              _isDark ? Icons.dark_mode : Icons.light_mode,
              color: colorScheme.primary,
            ),
            title: const Text('深色模式'),
            subtitle: Text(_isDark ? '当前：深色' : '当前：浅色'),
            trailing: Switch(
              value: _isDark,
              onChanged: (_) => widget.onToggleTheme(),
              activeColor: colorScheme.primary,
            ),
            contentPadding: EdgeInsets.zero,
            onTap: widget.onToggleTheme,
          ),
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 16),
          // ── 主题风格 ──
          Text(
            '主题风格',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          _buildThemeGrid(colorScheme),
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 16),
          // ── 更新通道 ──
          Text(
            '更新通道',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outline.withOpacity(0.2)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('稳定版'),
                  subtitle: Text(
                    '推荐，经过充分测试',
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurface.withOpacity(0.5)),
                  ),
                  value: 'stable',
                  groupValue: _updateChannel,
                  onChanged: (v) => _setUpdateChannel(v!),
                  activeColor: colorScheme.primary,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                Divider(height: 1, color: colorScheme.outline.withOpacity(0.1)),
                RadioListTile<String>(
                  title: const Text('测试版'),
                  subtitle: Text(
                    '抢先体验新功能，可能不稳定',
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurface.withOpacity(0.5)),
                  ),
                  value: 'beta',
                  groupValue: _updateChannel,
                  onChanged: (v) => _setUpdateChannel(v!),
                  activeColor: colorScheme.primary,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 16),
          // ── 服务器配置 ──
          Text(
            '服务器',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serverController,
            decoration: InputDecoration(
              hintText: 'https://your-server.com',
              labelText: '服务器地址',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saveServer,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(_saved ? '已保存 ✓' : '保存'),
            ),
          ),
          // 管理员区域（隐藏，点击三次版本号显示）
          if (_showAdminLogin) ...[
            const SizedBox(height: 24),
            Divider(color: colorScheme.outline.withOpacity(0.1)),
            const SizedBox(height: 16),
            if (_isLoggedIn)
              ListTile(
                leading: Icon(Icons.admin_panel_settings, color: colorScheme.primary),
                title: const Text('管理员'),
                subtitle: const Text('已登录 · 可删除笔记'),
                trailing: TextButton(
                  onPressed: _logout,
                  child: const Text('退出'),
                ),
                contentPadding: EdgeInsets.zero,
              )
            else
              ListTile(
                leading: Icon(Icons.lock_outline, color: colorScheme.onSurface.withOpacity(0.5)),
                title: const Text('管理员登录'),
                subtitle: const Text('登录后可删除笔记'),
                onTap: _showLoginDialog,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ],
      ),
    );
  }
}
