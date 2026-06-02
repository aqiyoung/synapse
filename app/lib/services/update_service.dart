import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String? releaseNotes;

  UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    this.releaseNotes,
  });
}

class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  UpdateInfo? _cachedUpdate;
  bool _checked = false;

  UpdateInfo? get cached => _cachedUpdate;
  bool get hasUpdate => _cachedUpdate != null;

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

  Future<void> check() async {
    try {
      // 从服务器代理检查版本（避免 APP 直连 GitHub）
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server') ?? '';
      if (server.isEmpty) return;

      var base = server;
      if (base.endsWith('/')) base = base.substring(0, base.length - 1);
      if (base.endsWith('/api')) base = base.substring(0, base.length - 4);

      final uri = Uri.parse('$base/api/update/check');
      final resp = await http.get(uri, headers: {
        'Accept': 'application/json',
        'User-Agent': 'Synapse',
      });
      if (resp.statusCode != 200) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final latestVersion = data['latest_version'] as String? ?? '';
      if (latestVersion.isEmpty) return;

      final currentVersion = await _getCurrentVersion();
      if (!_isNewer(latestVersion, currentVersion)) return;

      // 使用服务器代理下载链接（不直连 GitHub）
      final downloadUrl = '$base/api/update/download';

      _cachedUpdate = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        releaseNotes: data['release_notes'] as String?,
      );
    } catch (_) {
    } finally {
      _checked = true;
    }
  }

  Future<void> openDownload() async {
    if (_cachedUpdate == null) return;
    try {
      // 通过服务器代理下载，APP 不需要直连 GitHub
      await Process.run('am', [
        'start', '-a', 'android.intent.action.VIEW',
        '-d', _cachedUpdate!.downloadUrl,
      ]);
    } catch (_) {}
  }
}
