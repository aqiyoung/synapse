import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
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
  bool _downloading = false;
  double _downloadProgress = 0;
  String? _errorMessage;
  String _channel = 'stable';

  // Getters
  UpdateInfo? get cached => _cachedUpdate;
  bool get hasUpdate => _cachedUpdate != null;
  bool get checking => _checking;
  bool get checked => _checked;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;
  String? get errorMessage => _errorMessage;
  String get channel => _channel;

  /// 设置更新通道（stable / beta）
  Future<void> setChannel(String channel) async {
    if (channel != 'stable' && channel != 'beta') return;
    _channel = channel;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update_channel', channel);
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
    var l = latest.startsWith('v') ? latest.substring(1) : latest;
    var c = current.startsWith('v') ? current.substring(1) : current;
    l = l.split('+')[0];
    c = c.split('+')[0];

    List<int> parseVersion(String ver) {
      final cleanVer = ver.split('-')[0];
      return cleanVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    }

    final lVer = parseVersion(l);
    final cVer = parseVersion(c);

    for (int i = 0; i < 3; i++) {
      final lv = i < lVer.length ? lVer[i] : 0;
      final cv = i < cVer.length ? cVer[i] : 0;
      if (lv != cv) return lv > cv;
    }

    final lBetaMatch = RegExp(r'-beta\.(\d+)').firstMatch(l);
    final cBetaMatch = RegExp(r'-beta\.(\d+)').firstMatch(c);
    final lBetaNum = lBetaMatch != null ? int.parse(lBetaMatch.group(1)!) : null;
    final cBetaNum = cBetaMatch != null ? int.parse(cBetaMatch.group(1)!) : null;

    // 同类型版本比较（都是beta或都是stable）
    if (lBetaNum != null && cBetaNum != null) {
      return lBetaNum > cBetaNum;
    }

    // 当前是beta，latest是stable -> 不提示更新（beta用户不想降级到stable）
    if (lBetaNum == null && cBetaNum != null) {
      return false;
    }

    // 当前是stable，latest是beta -> 不提示更新（stable用户不想升级到beta）
    if (lBetaNum != null && cBetaNum == null) {
      return false;
    }

    return false;
  }

  /// 检查更新
  Future<void> check() async {
    if (_checking) return;

    _checking = true;
    _errorMessage = null;
    _notifyListeners();

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
            uri = Uri.parse('https://api.github.com/repos/aqiyoung/synapse/releases');
          } else {
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

      if (latestVersion.startsWith('v')) {
        latestVersion = latestVersion.substring(1);
      }

      final currentVersion = await _getCurrentVersion();
      if (!_isNewer(latestVersion, currentVersion)) {
        _checking = false;
        _notifyListeners();
        return;
      }

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

  /// 获取GitHub下载链接
  String getGitHubDownloadUrl() {
    final version = _cachedUpdate?.latestVersion ?? '';
    if (version.isEmpty) return 'https://github.com/aqiyoung/synapse/releases';
    return 'https://github.com/aqiyoung/synapse/releases/tag/v$version';
  }

  /// 下载更新并安装
  Future<void> downloadUpdate() async {
    if (_cachedUpdate == null || _downloading) return;
    if (_channel.isEmpty) await loadChannel();

    _downloading = true;
    _downloadProgress = 0;
    _errorMessage = null;
    _notifyListeners();

    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/synapse-v${_cachedUpdate!.latestVersion}.apk';
      final file = File(filePath);

      // 构建下载 URL：优先服务器代理，备选 GitHub 直连
      String downloadUrl = '';
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server') ?? '';

      if (server.isNotEmpty) {
        var base = server;
        if (base.endsWith('/')) base = base.substring(0, base.length - 1);
        if (base.endsWith('/api')) base = base.substring(0, base.length - 4);
        downloadUrl = '$base/api/update/download?channel=$_channel';
      }

      // 流式下载
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(downloadUrl));
        request.headers['User-Agent'] = 'Synapse';
        final response = await client.send(request).timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          throw Exception('服务器返回 ${response.statusCode}');
        }

        final contentLength = response.contentLength ?? 0;
        int downloaded = 0;
        final sink = file.openWrite();

        await response.stream.forEach((chunk) {
          sink.add(chunk);
          downloaded += chunk.length;
          if (contentLength > 0) {
            _downloadProgress = downloaded / contentLength;
            _notifyListeners();
          }
        });

        await sink.flush();
        await sink.close();
      } finally {
        client.close();
      }

      _downloading = false;
      _downloadProgress = 1.0;
      _notifyListeners();

      // 打开系统安装器
      final result = await OpenFile.open(filePath);
      if (result.type != ResultType.done) {
        _errorMessage = '无法打开 APK: ${result.message}';
        _notifyListeners();
      }
    } catch (e) {
      _downloading = false;
      _downloadProgress = 0;
      _errorMessage = '下载失败: $e';
      debugPrint('Download failed: $e');
      _notifyListeners();
    }
  }

  void _notifyListeners() {
    onStatusChange?.call();
  }
}
