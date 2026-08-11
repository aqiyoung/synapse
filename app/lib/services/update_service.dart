import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_core.dart';

/// synapse 的仓库配置. 没有 meta 分支, 所以关掉 jsDelivr 兜底.
const AppUpdateConfig kUpdateConfig = AppUpdateConfig(
  owner: 'aqiyoung',
  repo: 'synapse',
  useMetaFallback: false,
);

/// 「启动时自动检查更新」开关的持久化键（默认开启）.
/// 对齐 sanyelive 的 version_checker.auto_check_update /
/// FeiNiuMusic 的 autoCheckUpdateOnLaunch.
const String kAutoCheckUpdateKey = 'update_service.auto_check_update';

class UpdateInfo {
  final String latestVersion;
  final String? releaseNotes;
  final String? publishedAt;

  /// 带前导 v 的 tag, 如 "v0.3.8"; 服务器代理没给时回落 "v$latestVersion".
  final String tagName;

  /// 该版本 Release 页面地址 (跳转用).
  final String releaseUrl;

  /// GitHub 资产里的 APK 直链 (arm64-v8a 优先), 服务器代理路径下为 null.
  final String? apkDownloadUrl;

  /// release 正文首行标了 **P0** / **critical** → 建议强制升级.
  final bool isCritical;

  UpdateInfo({
    required this.latestVersion,
    this.releaseNotes,
    this.publishedAt,
    String? tag,
    String? url,
    this.apkDownloadUrl,
    this.isCritical = false,
  })  : tagName = tag ?? 'v$latestVersion',
        releaseUrl = url ?? kUpdateConfig.releaseTagUrl(tag ?? 'v$latestVersion');
}

class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  /// 三仓共用的更新引擎 (sanyelive / FeiNiuMusic / synapse).
  static final AppUpdateCore core = AppUpdateCore(kUpdateConfig);

  UpdateInfo? _cachedUpdate;
  bool _checked = false;
  bool _checking = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  String? _errorMessage;
  String _channel = 'stable';
  bool _autoCheckOnLaunch = true;

  // Getters
  UpdateInfo? get cached => _cachedUpdate;
  bool get hasUpdate => _cachedUpdate != null;
  bool get checking => _checking;
  bool get checked => _checked;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;
  String? get errorMessage => _errorMessage;
  String get channel => _channel;

  /// 「启动时自动检查更新」开关（默认开启）.
  bool get autoCheckOnLaunch => _autoCheckOnLaunch;

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

  /// 加载「启动时自动检查更新」开关（缺省 = 开启）.
  Future<void> loadAutoCheck() async {
    final prefs = await SharedPreferences.getInstance();
    _autoCheckOnLaunch = prefs.getBool(kAutoCheckUpdateKey) ?? true;
  }

  /// 设置「启动时自动检查更新」开关并持久化.
  Future<void> setAutoCheckOnLaunch(bool value) async {
    _autoCheckOnLaunch = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAutoCheckUpdateKey, value);
    _notifyListeners();
  }

  /// 启动 / 进页面时的自动检查入口.
  ///
  /// 用户关掉开关后直接跳过，不发任何请求、不弹窗；
  /// 设置页里手动点「检查更新」走 [check]，不受开关影响。
  /// 语义与 sanyelive / FeiNiuMusic 保持一致。
  Future<void> checkOnLaunch() async {
    await loadAutoCheck();
    if (!_autoCheckOnLaunch) return;
    await check();
  }

  // Status change callback
  VoidCallback? onStatusChange;

  /// package:http 版的引擎适配器 —— 引擎只要状态码 + 原始 body.
  static Future<AppUpdateHttpResponse> _fetch(
    String url,
    Map<String, String> headers,
  ) async {
    final resp = await http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 15));
    return AppUpdateHttpResponse(
      resp.statusCode,
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
  }

  Future<String> _getCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  /// synapse 自己的版本比较 —— 比引擎的 [AppUpdateCore.compareVersions] 多一层
  /// beta 语义: `-beta.N` 之间按 N 比, 且 beta ↔ stable 互不打扰.
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
    final lBetaNum =
        lBetaMatch != null ? int.parse(lBetaMatch.group(1)!) : null;
    final cBetaNum =
        cBetaMatch != null ? int.parse(cBetaMatch.group(1)!) : null;

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

  /// 检查更新.
  ///
  /// 数据源顺序:
  ///   1. 自建服务器代理 `/api/update/check` (配置了 server 才走, 局域网最快);
  ///   2. [AppUpdateCore] —— GitHub API, 依次 gh-proxy.com 代理 → 直连.
  /// 全部失败时置 [errorMessage], 绝不误报"已是最新".
  Future<void> check() async {
    if (_checking) return;

    _checking = true;
    _errorMessage = null;
    _notifyListeners();

    if (_channel.isEmpty) await loadChannel();

    try {
      UpdateInfo? candidate;

      // 方式1：通过服务器代理检查
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server') ?? '';
      if (server.isNotEmpty) {
        try {
          var base = server;
          if (base.endsWith('/')) base = base.substring(0, base.length - 1);
          if (base.endsWith('/api')) base = base.substring(0, base.length - 4);

          final uri = Uri.parse('$base/api/update/check?channel=$_channel');
          final resp = await http
              .get(
                uri,
                headers: {
                  'Accept': 'application/json',
                  'User-Agent': 'Synapse',
                },
              )
              .timeout(const Duration(seconds: 10));

          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            var version = (data['latest_version'] as String? ?? '').trim();
            if (version.startsWith('v')) version = version.substring(1);
            if (version.isNotEmpty) {
              final notes = data['release_notes'] as String? ?? '';
              candidate = UpdateInfo(
                latestVersion: version,
                releaseNotes: notes,
                publishedAt: data['published_at'] as String?,
                isCritical: AppUpdateCore.isCritical(notes),
              );
            }
          }
        } catch (e) {
          debugPrint('Server update check failed, trying GitHub directly: $e');
        }
      }

      // 方式2：统一引擎查 GitHub（代理链 → 直连）
      if (candidate == null) {
        final current = await _getCurrentVersion();
        final result = await core.check(_fetch, current, channel: _channel);
        if (result == null) {
          _checking = false;
          _errorMessage = '无法检查更新，请检查网络';
          _notifyListeners();
          return;
        }
        candidate = UpdateInfo(
          latestVersion: result.latestVersion,
          releaseNotes: result.releaseNotes,
          tag: result.tagName,
          url: result.releaseUrl,
          apkDownloadUrl: result.apkDownloadUrl,
          isCritical: result.isCritical,
        );
      }

      final currentVersion = await _getCurrentVersion();
      _checked = true;
      if (!_isNewer(candidate.latestVersion, currentVersion)) {
        _cachedUpdate = null;
        _checking = false;
        _notifyListeners();
        return;
      }

      _cachedUpdate = candidate;
      _checking = false;
    } catch (e) {
      _checking = false;
      _errorMessage = '检查更新失败: $e';
      debugPrint('Update check failed: $e');
    }
    _notifyListeners();
  }

  /// 获取GitHub下载链接（Release 页面）
  String getGitHubDownloadUrl() =>
      _cachedUpdate?.releaseUrl ?? kUpdateConfig.releasePageUrl;

  /// 跳转发布页: GitHub App 优先 → 系统浏览器 → 复制链接.
  Future<OpenReleaseResult> openReleasePage(BuildContext context) =>
      core.openRelease(context, getGitHubDownloadUrl());

  /// 用 gh-proxy 包一层的下载地址, 给直连 GitHub 打不开的用户.
  String proxyDownloadUrl() => core.proxyUrl(getGitHubDownloadUrl());

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
      final filePath =
          '${dir.path}/synapse-v${_cachedUpdate!.latestVersion}.apk';
      final file = File(filePath);

      // 构建下载 URL：优先服务器代理，其次 GitHub 资产（走 gh-proxy 兜底）
      String downloadUrl = '';
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server') ?? '';

      if (server.isNotEmpty) {
        var base = server;
        if (base.endsWith('/')) base = base.substring(0, base.length - 1);
        if (base.endsWith('/api')) base = base.substring(0, base.length - 4);
        downloadUrl = '$base/api/update/download?channel=$_channel';
      } else {
        final asset = _cachedUpdate!.apkDownloadUrl;
        if (asset == null || asset.isEmpty) {
          throw Exception('该版本没有可直接下载的 APK，请前往 Release 页面');
        }
        downloadUrl = core.proxyUrl(asset);
      }

      // 流式下载
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(downloadUrl));
        request.headers['User-Agent'] = 'Synapse';
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));

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
