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

  // Getters
  UpdateInfo? get cached => _cachedUpdate;
  bool get hasUpdate => _cachedUpdate != null;
  bool get checking => _checking;
  bool get checked => _checked;
  String? get errorMessage => _errorMessage;

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
    final lp = latest.split('+');
    final cp = current.split('+');
    final lVer = lp[0].split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final cVer = cp[0].split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final l = i < lVer.length ? lVer[i] : 0;
      final c = i < cVer.length ? cVer[i] : 0;
      if (l != c) return l > c;
    }
    if (lp.length > 1 && cp.length > 1) {
      return (int.tryParse(lp[1]) ?? 0) > (int.tryParse(cp[1]) ?? 0);
    }
    return false;
  }

  /// 检查更新
  Future<void> check() async {
    if (_checking) return;

    _checking = true;
    _errorMessage = null;
    _notifyListeners();

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

          final uri = Uri.parse('$base/api/update/check');
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
          final uri = Uri.parse('https://api.github.com/repos/aqiyoung/synapse/releases/latest');
          final resp = await http.get(uri, headers: {
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'Synapse',
          }).timeout(const Duration(seconds: 15));

          if (resp.statusCode == 200) {
            final githubData = jsonDecode(resp.body) as Map<String, dynamic>;
            final tag = githubData['tag_name'] as String? ?? '';
            data = {
              'latest_version': tag.replaceFirst('v', ''),
              'release_notes': githubData['body'] ?? '',
              'published_at': githubData['published_at'] ?? '',
            };
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

      final latestVersion = data['latest_version'] as String? ?? '';
      if (latestVersion.isEmpty) {
        _checking = false;
        _notifyListeners();
        return;
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

  /// 跳转到 GitHub Release 页面下载
  Future<void> openDownloadPage() async {
    if (_cachedUpdate == null) return;
    try {
      final uri = Uri.parse(
        'https://github.com/aqiyoung/synapse/releases/tag/v${_cachedUpdate!.latestVersion}',
      );
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _errorMessage = '无法打开下载页面: $e';
      _notifyListeners();
    }
  }

  void _notifyListeners() {
    onStatusChange?.call();
  }
}
