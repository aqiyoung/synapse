import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

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
      final uri = Uri.parse(
          'https://api.github.com/repos/aqiyoung/synapse/releases/latest');
      final resp = await http.get(uri, headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'Synapse',
      });
      if (resp.statusCode != 200) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String? ?? '';
      final latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;

      final currentVersion = await _getCurrentVersion();

      if (!_isNewer(latestVersion, currentVersion)) return;

      final downloadUrl =
          'https://github.com/aqiyoung/synapse/releases/download/$tagName/synapse-v$latestVersion.apk';

      String? releaseNotes;
      final body = data['body'] as String?;
      if (body != null && body.isNotEmpty) {
        releaseNotes = body.length > 500 ? '${body.substring(0, 500)}...' : body;
      }

      _cachedUpdate = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        releaseNotes: releaseNotes,
      );
    } catch (_) {
    } finally {
      _checked = true;
    }
  }

  Future<void> openDownload() async {
    final url = 'https://github.com/aqiyoung/synapse/releases/latest';
    try {
      await Process.run('am', [
        'start',
        '-a', 'android.intent.action.VIEW',
        '-d', url,
      ]);
    } catch (_) {
      // fallback: try Process with different args
      try {
        await Process.run('xdg-open', [url]);
      } catch (_) {}
    }
  }

  Future<void> openReleasePage() async {
    await openDownload();
  }
}
