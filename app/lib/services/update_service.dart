import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String latestVersion;
  final String? releaseNotes;
  final String? publishedAt;

  UpdateInfo({
    required this.latestVersion,
    this.releaseNotes,
    this.publishedAt,
  });
}

class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  UpdateInfo? _cachedUpdate;
  bool _checked = false;
  bool _checking = false;
  String? _errorMessage;
  String _channel = 'stable';

  // Getters
  UpdateInfo? get cached => _cachedUpdate;
  bool get hasUpdate => _cachedUpdate != null;
  bool get checking => _checking;
  bool get checked => _checked;
  String? get errorMessage => _errorMessage;
  String get channel => _channel;

  /// 设置更新通道（stable / beta）
  Future<void> setChannel(String channel) async {
    if (channel != 'stable' && channel != 'beta') return;
    _channel = channel;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update_channel', channel);
    // 通道切换后清除缓存，下次检查时重新请求
    _cachedUpdate = null;
    _checked = false;
    _notifyListeners();
  }

  /// 加载保存的通道设置
  Future<void> loadChannel() async {
    final prefs = await SharedPreferences.getInstance();
    _channel = prefs.getString('update_channel') ?? 'stable';
  }

  // Status change callback
  VoidCallback? onStatusChange;

  Future<String> _getCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  bool _isNewer(String latest, String current) {
    // 移除可能的 v 前缀
    var l = latest.startsWith('v') ? latest.substring(1) : latest;
    var c = current.startsWith('v') ? current.substring(1) : current;

    // 移除构建号（+后面的部分）
    l = l.split('+')[0];
    c = c.split('+')[0];

    // 解析主版本号（处理 beta 后缀）
    List<int> parseVersion(String ver) {
      // 移除 -beta, -alpha 等后缀
      final cleanVer = ver.split('-')[0];
      return cleanVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    }

    final lVer = parseVersion(l);
    final cVer = parseVersion(c);

    // 比较主版本号
    for (int i = 0; i < 3; i++) {
      final lv = i < lVer.length ? lVer[i] : 0;
      final cv = i < cVer.length ? cVer[i] : 0;
      if (lv != cv) return lv > cv;
    }

    // 主版本号相同时，比较 beta 版本号
    final lBetaMatch = RegExp(r'-beta\.(\d+)').firstMatch(l);
    final cBetaMatch = RegExp(r'-beta\.(\d+)').firstMatch(c);
    
    if (lBetaMatch != null && cBetaMatch != null) {
      // 都是 beta 版，比较 beta 版本号
      final lBetaNum = int.parse(lBetaMatch.group(1)!);
      final cBetaNum = int.parse(cBetaMatch.group(1)!);
      return lBetaNum > cBetaNum;
    } else if (lBetaMatch != null) {
      // latest 是 beta，current 不是 → beta 视为更新
      return true;
    } else if (cBetaMatch != null) {
      // current 是 beta，latest 不是 → stable 视为更新
      return true;
    }

    return false;
  }

  /// 检查更新
  Future<void> check() async {
    if (_checking) return;

    _checking = true;
    _errorMessage = null;
    _notifyListeners();

    // 确保通道设置已加载
    if (_channel.isEmpty) await loadChannel();

    try {
      Map<String, dynamic>? data;

      // 方式1：通过服务器代理检查
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server') ?? '';
      if (server.isNotEmpty) {
        try {
          var base = server;
          if (base.endsWith('/')) base = base.substring(0, base.length - 1);
          if (base.endsWith('/api')) base = base.substring(0, base.length - 4);

          final uri = Uri.parse('$base/api/update/check?channel=$_channel');
          final resp = await http.get(uri, headers: {
            'Accept': 'application/json',
            'User-Agent': 'Synapse',
          }).timeout(const Duration(seconds: 10));

          if (resp.statusCode == 200) {
            data = jsonDecode(resp.body) as Map<String, dynamic>;
          }
        } catch (e) {
          debugPrint('Server update check failed, trying GitHub directly: $e');
        }
      }

      // 方式2：直接访问 GitHub API（备选）
      if (data == null) {
        try {
          Uri uri;
          if (_channel == 'beta') {
            // beta 通道：获取所有 release，找最新的 pre-release
            uri = Uri.parse('https://api.github.com/repos/aqiyoung/synapse/releases');
          } else {
            // 稳定通道：获取 latest release
            uri = Uri.parse('https://api.github.com/repos/aqiyoung/synapse/releases/latest');
          }

          final resp = await http.get(uri, headers: {
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'Synapse',
          }).timeout(const Duration(seconds: 15));

          if (resp.statusCode == 200) {
            final body = jsonDecode(resp.body);
            Map<String, dynamic>? release;

            if (_channel == 'beta') {
              // 从 releases 列表中找最新的 pre-release
              final releases = body as List<dynamic>;
              for (final r in releases) {
                if (r['prerelease'] == true) {
                  release = r as Map<String, dynamic>;
                  break;
                }
              }
            } else {
              release = body as Map<String, dynamic>;
            }

            if (release != null) {
              final tag = release['tag_name'] as String? ?? '';
              data = {
                'latest_version': tag.replaceFirst('v', ''),
                'release_notes': release['body'] ?? '',
                'published_at': release['published_at'] ?? '',
              };
            }
          }
        } catch (e) {
          debugPrint('GitHub API update check failed: $e');
        }
      }

      if (data == null) {
        _checking = false;
        _errorMessage = '无法检查更新';
        _notifyListeners();
        return;
      }

      var latestVersion = data['latest_version'] as String? ?? '';
      if (latestVersion.isEmpty) {
        _checking = false;
        _notifyListeners();
        return;
      }

      // 移除 v 前缀
      if (latestVersion.startsWith('v')) {
        latestVersion = latestVersion.substring(1);
      }

      final currentVersion = await _getCurrentVersion();
      if (!_isNewer(latestVersion, currentVersion)) {
        _checking = false;
        _notifyListeners();
        return;
      }

      // 有新版本
      _cachedUpdate = UpdateInfo(
        latestVersion: latestVersion,
        releaseNotes: data['release_notes'] as String?,
        publishedAt: data['published_at'] as String?,
      );

      _checked = true;
      _checking = false;
    } catch (e) {
      _checking = false;
      _errorMessage = '检查更新失败: $e';
      debugPrint('Update check failed: $e');
    }
    _notifyListeners();
  }

  /// 下载更新（在浏览器中打开）
  Future<void> downloadUpdate() async {
    if (_cachedUpdate == null) return;

    // 确保通道设置已加载
    if (_channel.isEmpty) await loadChannel();

    // 优先从服务器下载
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server') ?? '';
    if (server.isNotEmpty) {
      try {
        var base = server;
        if (base.endsWith('/')) base = base.substring(0, base.length - 1);
        if (base.endsWith('/api')) base = base.substring(0, base.length - 4);

        final uri = Uri.parse('$base/api/update/download?channel=$_channel');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
          return;
        }
      } catch (e) {
        debugPrint('Server download failed, trying GitHub: $e');
      }
    }

    // 备选：从 GitHub 下载
    try {
      final uri = Uri.parse(
        'https://github.com/aqiyoung/synapse/releases/download/v${_cachedUpdate!.latestVersion}/synapse-v${_cachedUpdate!.latestVersion}.apk',
      );
      // 直接尝试打开，不用 canLaunchUrl 检查（某些 Android 版本兼容性问题）
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('GitHub download failed: $e');
      _errorMessage = '无法打开下载页面: $e';
      _notifyListeners();
    }
  }

  void _notifyListeners() {
    onStatusChange?.call();
  }
}
