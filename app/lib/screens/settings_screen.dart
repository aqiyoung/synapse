import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/api_service.dart';
import '../services/update_service.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;

  const SettingsScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
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

  static const String _adminPassword = 'synapse2026';

  bool get _isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _loadServer();
    _checkLoginState();
    _loadVersion();
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
              UpdateService().openDownloadPage();
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
    if (_passwordController.text == _adminPassword) {
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
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 16),
          // ── 关于 ──
          Text(
            '关于',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: Icon(Icons.info_outline, color: colorScheme.primary),
            title: const Text('版本'),
            subtitle: Text(_currentVersion),
            contentPadding: EdgeInsets.zero,
            onTap: _onVersionTap,
          ),
          ListTile(
            leading: Icon(Icons.code, color: colorScheme.primary),
            title: const Text('技术栈'),
            subtitle: const Text('Flutter + FastAPI + SQLite'),
            contentPadding: EdgeInsets.zero,
          ),
          ListTile(
            leading: Icon(Icons.smart_toy_outlined, color: colorScheme.primary),
            title: const Text('AI 驱动'),
            subtitle: const Text('自动标签 · 自动关联 · 自动质检'),
            contentPadding: EdgeInsets.zero,
          ),
          ListTile(
            leading: Icon(Icons.language, color: colorScheme.primary),
            title: const Text('开源'),
            subtitle: const Text('github.com/aqiyoung/synapse'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outline.withOpacity(0.1),
              ),
            ),
            child: Text(
              'Synapse 是一个 AI 驱动的个人知识管理系统。你只管写内容，剩下的全交给 AI —— 自动标签、自动整理、自动质检、自动关联。后台脚本持续运行，无需人工干预。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 16),
          // ── 更新 ──
          Text(
            '更新',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: Icon(Icons.system_update_outlined, color: colorScheme.primary),
            title: Text(
              UpdateService().hasUpdate
                  ? '新版本 ${UpdateService().cached!.latestVersion} 可用'
                  : '检查更新',
            ),
            subtitle: Text(
              UpdateService().hasUpdate
                  ? '点击查看更新内容'
                  : '自动检查 GitHub 发布',
            ),
            trailing: UpdateService().hasUpdate
                ? Icon(Icons.arrow_forward_ios, size: 16, color: colorScheme.primary)
                : Icon(Icons.check_circle_outline, color: Colors.green),
            contentPadding: EdgeInsets.zero,
            onTap: () async {
              if (UpdateService().hasUpdate) {
                _showUpdateDialog(context, colorScheme);
              } else {
                _checkUpdate();
              }
            },
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
