import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String? releaseNotes;
  final String? publishedAt;

  UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    this.releaseNotes,
    this.publishedAt,
  });
}

enum UpdateStatus {
  idle,
  checking,
  downloading,
  downloaded,
  error,
}

class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  UpdateInfo? _cachedUpdate;
  bool _checked = false;
  UpdateStatus _status = UpdateStatus.idle;
  double _downloadProgress = 0.0;
  String? _errorMessage;
  String? _downloadedFilePath;

  // Getters
  UpdateInfo? get cached => _cachedUpdate;
  bool get hasUpdate => _cachedUpdate != null;
  UpdateStatus get status => _status;
  double get downloadProgress => _downloadProgress;
  String? get errorMessage => _errorMessage;
  String? get downloadedFilePath => _downloadedFilePath;

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
    if (_status == UpdateStatus.checking) return;

    _status = UpdateStatus.checking;
    _errorMessage = null;
    _notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server') ?? '';
      if (server.isEmpty) {
        _status = UpdateStatus.idle;
        _notifyListeners();
        return;
      }

      var base = server;
      if (base.endsWith('/')) base = base.substring(0, base.length - 1);
      if (base.endsWith('/api')) base = base.substring(0, base.length - 4);

      final uri = Uri.parse('$base/api/update/check');
      final resp = await http.get(uri, headers: {
        'Accept': 'application/json',
        'User-Agent': 'Synapse',
      }).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        _status = UpdateStatus.idle;
        _notifyListeners();
        return;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final latestVersion = data['latest_version'] as String? ?? '';
      if (latestVersion.isEmpty) {
        _status = UpdateStatus.idle;
        _notifyListeners();
        return;
      }

      final currentVersion = await _getCurrentVersion();
      if (!_isNewer(latestVersion, currentVersion)) {
        _status = UpdateStatus.idle;
        _notifyListeners();
        return;
      }

      // 有新版本
      final downloadUrl = '$base/api/update/download';
      _cachedUpdate = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        releaseNotes: data['release_notes'] as String?,
        publishedAt: data['published_at'] as String?,
      );

      _status = UpdateStatus.idle;
      _checked = true;
    } catch (e) {
      _status = UpdateStatus.idle;
      debugPrint('Update check failed: $e');
    }
    _notifyListeners();
  }

  /// 下载 APK
  Future<void> download() async {
    if (_cachedUpdate == null) return;
    if (_status == UpdateStatus.downloading) return;

    // 如果已经下载过，直接安装
    if (_downloadedFilePath != null && File(_downloadedFilePath!).existsSync()) {
      await install();
      return;
    }

    _status = UpdateStatus.downloading;
    _downloadProgress = 0.0;
    _errorMessage = null;
    _notifyListeners();

    try {
      // 获取下载目录
      final dir = await getTemporaryDirectory();
      final fileName = 'synapse-v${_cachedUpdate!.latestVersion}.apk';
      final filePath = '${dir.path}/$fileName';
      final file = File(filePath);

      // 如果文件已存在，直接安装
      if (await file.exists()) {
        _downloadedFilePath = filePath;
        _status = UpdateStatus.downloaded;
        _notifyListeners();
        await install();
        return;
      }

      // 下载文件
      final request = http.Request('GET', Uri.parse(_cachedUpdate!.downloadUrl));
      request.headers['User-Agent'] = 'Synapse';

      final response = await http.Client().send(request);
      if (response.statusCode != 200) {
        throw Exception('下载失败: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      final sink = file.openWrite();
      int received = 0;

      await response.stream.listen(
        (chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            _downloadProgress = received / contentLength;
            _notifyListeners();
          }
        },
        onDone: () async {
          await sink.close();
          _downloadedFilePath = filePath;
          _status = UpdateStatus.downloaded;
          _downloadProgress = 1.0;
          _notifyListeners();
          // 下载完成，自动安装
          await install();
        },
        onError: (e) async {
          await sink.close();
          // 删除不完整的文件
          if (await file.exists()) {
            await file.delete();
          }
          _status = UpdateStatus.error;
          _errorMessage = '下载失败: $e';
          _notifyListeners();
        },
        cancelOnError: true,
      ).asFuture<void>();
    } catch (e) {
      _status = UpdateStatus.error;
      _errorMessage = '下载失败: $e';
      _notifyListeners();
    }
  }

  /// 安装 APK
  Future<void> install() async {
    if (_downloadedFilePath == null) return;

    final file = File(_downloadedFilePath!);
    if (!await file.exists()) {
      _errorMessage = '安装文件不存在';
      _status = UpdateStatus.error;
      _notifyListeners();
      return;
    }

    try {
      // 使用 open_file 打开 APK
      final result = await OpenFile.open(_downloadedFilePath!);
      if (result.type != ResultType.done) {
        // 如果 open_file 失败，尝试用 url_launcher
        final uri = Uri.file(_downloadedFilePath!);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        } else {
          throw Exception('无法打开安装文件');
        }
      }
    } catch (e) {
      _errorMessage = '安装失败: $e';
      _status = UpdateStatus.error;
      _notifyListeners();
    }
  }

  /// 打开下载页面（备用方案）
  Future<void> openDownloadPage() async {
    if (_cachedUpdate == null) return;
    try {
      // 构建 GitHub Release 页面 URL
      final uri = Uri.parse(
        'https://github.com/aqiyoung/synapse/releases/tag/v${_cachedUpdate!.latestVersion}'
      );
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  /// 清除下载缓存
  Future<void> clearCache() async {
    if (_downloadedFilePath != null) {
      final file = File(_downloadedFilePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _downloadedFilePath = null;
    _downloadProgress = 0.0;
    _status = UpdateStatus.idle;
    _notifyListeners();
  }

  void _notifyListeners() {
    onStatusChange?.call();
  }
}
