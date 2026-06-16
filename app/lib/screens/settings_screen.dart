import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/api_service.dart';
import '../services/update_service.dart';
import '../services/notification_service.dart';
import '../services/ai_service.dart';
import 'notifications_screen.dart';
import '../models/app_theme.dart';
import '../widgets/glass_container.dart';

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
  bool _notificationsEnabled = true;
  int _unreadCount = 0;
  bool _aiEnabled = true;
  String _aiModel = '';

  bool get _isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _loadServer();
    _checkLoginState();
    _loadVersion();
    _loadUpdateChannel();
    _loadNotificationState();
    _loadAiState();
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

  Future<void> _loadNotificationState() async {
    final enabled = await NotificationService.isEnabled();
    final count = await NotificationService.getUnreadCount();
    if (mounted) {
      setState(() {
        _notificationsEnabled = enabled;
        _unreadCount = count;
      });
    }
  }

  Future<void> _loadAiState() async {
    final enabled = await AiService.isEnabled();
    // 后台异步查 LLM 状态, 不阻塞 UI
    unawaited(_refreshAiServerStatus());
    if (mounted) {
      setState(() {
        _aiEnabled = enabled;
      });
    }
  }

  Future<void> _refreshAiServerStatus() async {
    await AiService.checkServerStatus();
    if (mounted) {
      setState(() {
        _aiModel = AiService.model;
      });
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
    UpdateService().onStatusChange = () {
      if (mounted) setState(() {});
    };
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
            child: Text('稍后', style: TextStyle(color: colorScheme.onSurface.withOpacity(0.6))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final url = UpdateService().getGitHubDownloadUrl();
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            },
            child: const Text('GitHub下载'),
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
            child: const Text('直接更新'),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateSection(ColorScheme colorScheme) {
    final updateService = UpdateService();
    return GlassContainer(
      borderRadius: BorderRadius.circular(16),
      blur: 20,
      tintOpacity: 0.3,
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.data?.version ?? '...';
              return ListTile(
                leading: Icon(Icons.info_outline, color: colorScheme.primary, size: 20),
                title: const Text('当前版本'),
                trailing: Text('v$version', style: TextStyle(color: colorScheme.onSurface.withOpacity(0.6), fontSize: 14)),
              );
            },
          ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.1)),
          if (updateService.downloading) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: updateService.downloadProgress > 0 ? updateService.downloadProgress : null,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        updateService.downloadProgress > 0
                            ? '下载中... ${(updateService.downloadProgress * 100).toInt()}%'
                            : '准备下载...',
                        style: TextStyle(fontSize: 14, color: colorScheme.onSurface),
                      ),
                    ],
                  ),
                  if (updateService.downloadProgress > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: updateService.downloadProgress,
                      backgroundColor: colorScheme.outline.withOpacity(0.1),
                      color: colorScheme.primary,
                    ),
                  ],
                ],
              ),
            ),
          ] else if (updateService.hasUpdate) ...[
            ListTile(
              leading: Icon(Icons.download, color: colorScheme.primary, size: 20),
              title: Text('发现新版本 v${updateService.cached!.latestVersion}',
                style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w500)),
              trailing: Icon(Icons.chevron_right, color: colorScheme.onSurface.withOpacity(0.3)),
              onTap: () => _showUpdateDialog(context, colorScheme),
            ),
          ] else ...[
            ListTile(
              leading: updateService.checking
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.primary))
                  : Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
              title: Text(
                updateService.checking ? '检查中...' : '已是最新版本',
                style: TextStyle(color: colorScheme.onSurface.withOpacity(0.7)),
              ),
              trailing: TextButton(
                onPressed: updateService.checking ? null : () async {
                  await _checkUpdate();
                },
                child: const Text('检查更新'),
              ),
            ),
          ],
          if (updateService.errorMessage != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                updateService.errorMessage!,
                style: TextStyle(fontSize: 12, color: Colors.red.withOpacity(0.8)),
              ),
            ),
          ],
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

    // 确保状态栏样式正确
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      isDark
          ? const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
    );

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: isDark
            ? const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
              )
            : const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 外观 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '外观',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                // 深色模式开关
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _isDark ? Icons.dark_mode : Icons.light_mode,
                        color: colorScheme.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '深色模式',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            _isDark ? '当前：深色模式' : '当前：浅色模式',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _isDark,
                      onChanged: (_) => widget.onToggleTheme(),
                      activeColor: colorScheme.primary,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── 主题风格 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '主题风格',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                _buildThemeGrid(colorScheme),
              ],
            ),
          ),

          // ── 通知设置 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '通知',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.notifications_outlined,
                        color: colorScheme.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '推送通知',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            '接收系统通知和更新提醒',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _notificationsEnabled,
                      onChanged: (v) async {
                        await NotificationService.setEnabled(v);
                        setState(() => _notificationsEnabled = v);
                      },
                      activeColor: colorScheme.primary,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => NotificationsScreen(themeIndex: widget.themeIndex)));
                    _loadNotificationState();
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.notifications_active,
                            color: colorScheme.primary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            '通知中心',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (_unreadCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$_unreadCount',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right,
                          color: colorScheme.onSurface.withOpacity(0.3),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── AI 功能 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'AI',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (AiService.llmEnabled)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _aiModel.isNotEmpty ? _aiModel : '已连接',
                          style: const TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.w600),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '未配置',
                          style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        color: colorScheme.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '启用 AI 摘要',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            AiService.llmEnabled
                                ? '笔记详情页可使用 AI 一键摘要'
                                : '后端未配置 LLM，开启后暂不可用',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _aiEnabled,
                      onChanged: (v) async {
                        await AiService.setEnabled(v);
                        setState(() => _aiEnabled = v);
                        if (v) {
                          // 打开时立即查一次 server status
                          _refreshAiServerStatus();
                        }
                      },
                      activeColor: colorScheme.primary,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── 更新通道 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '更新通道',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _buildChannelOption(
                        colorScheme,
                        title: '稳定版',
                        subtitle: '推荐，经过充分测试',
                        value: 'stable',
                        icon: Icons.shield_outlined,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildChannelOption(
                        colorScheme,
                        title: '测试版',
                        subtitle: '抢先体验新功能',
                        value: 'beta',
                        icon: Icons.science_outlined,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── 检查更新 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '应用更新',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                _buildUpdateSection(colorScheme),
              ],
            ),
          ),

          // ── 服务器配置 ──
          GlassContainer(
            margin: const EdgeInsets.only(bottom: 16),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.4,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '服务器',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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
                      borderRadius: BorderRadius.circular(12),
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
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(_saved ? '已保存 ✓' : '保存'),
                  ),
                ),
              ],
            ),
          ),

          // 管理员区域（隐藏，点击三次版本号显示）
          if (_showAdminLogin) ...[
            GlassContainer(
              margin: const EdgeInsets.only(bottom: 16),
              borderRadius: BorderRadius.circular(20),
              blur: 24,
              tintOpacity: 0.4,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '管理员',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
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
              ),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildChannelOption(
    ColorScheme colorScheme, {
    required String title,
    required String subtitle,
    required String value,
    required IconData icon,
  }) {
    final selected = _updateChannel == value;
    return GestureDetector(
      onTap: () => _setUpdateChannel(value),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withOpacity(0.15)
              : colorScheme.surfaceContainerHighest.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? Border.all(color: colorScheme.primary, width: 2)
              : Border.all(color: colorScheme.outline.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: selected ? colorScheme.primary : colorScheme.onSurface.withOpacity(0.5),
              size: 24,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? colorScheme.primary : colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 10,
                color: colorScheme.onSurface.withOpacity(0.5),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
