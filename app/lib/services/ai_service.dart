// AI 服务 — Synapse 知识库 AI 摘要功能
//
// 功能:
// 1. 持久化"AI 开关" (SharedPreferences key: ai_enabled, 默认 true)
// 2. 调用后端 /api/ai/summarize/{note_id} 流式获取摘要
// 3. 状态查询 /api/ai/status
//
// 后端尊重 X-AI-Enabled header:
// - 开关关: header 缺失 / false → 403 "AI 功能未开启"
// - 开关开: header true → SSE 流
//
// 老板 6/16 拍板加功能 + 开关。
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

class AiService {
  static const _enabledKey = 'ai_enabled';

  /// 读取 App 端 AI 开关 (默认 true, 用户开了后默认开)
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  /// 持久化 AI 开关
  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  /// 后端 LLM 是否配置 (LLM_API_KEY 是否有)
  static bool? _llmEnabled;
  static String _model = '';

  static bool get llmEnabled => _llmEnabled ?? false;
  static String get model => _model;

  /// 查询后端 LLM 状态
  static Future<bool> checkServerStatus() async {
    try {
      final r = await http
          .get(Uri.parse('${ApiService.baseUrl}/ai/status'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final data = json.decode(r.body) as Map<String, dynamic>;
        _llmEnabled = data['llm_enabled'] == true;
        _model = data['model'] ?? '';
        return _llmEnabled ?? false;
      }
    } catch (_) {}
    return false;
  }

  /// 流式 AI 摘要笔记
  ///
  /// [onChunk]: 每段 token 触发
  /// 抛出异常时: 后端 403/503 等错误直接回调 onError
  static Future<void> summarize({
    required int noteId,
    required void Function(String chunk) onChunk,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    final enabled = await isEnabled();
    if (!enabled) {
      onError('AI 功能未开启，请先在设置里打开 AI 开关');
      return;
    }

    try {
      final client = http.Client();
      final req = http.Request(
        'POST',
        Uri.parse('${ApiService.baseUrl}/ai/summarize/$noteId'),
      );
      req.headers['X-AI-Enabled'] = 'true';
      req.headers['Accept'] = 'text/event-stream';
      req.headers['Cache-Control'] = 'no-cache';

      final response = await client.send(req);
      if (response.statusCode != 200) {
        String errBody = '';
        try {
          errBody = await response.stream.bytesToString();
        } catch (_) {}
        onError('摘要失败 (${response.statusCode}): $errBody');
        return;
      }

      // 流式按行解析 SSE
      final lineStream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        if (line.startsWith('data: ')) {
          final payload = line.substring(6).trim();
          if (payload.isEmpty || payload == '[DONE]') continue;
          if (payload.startsWith('[ERROR]')) {
            onError(payload.substring(7).trim());
            return;
          }
          onChunk(payload);
        }
      }
      onDone();
    } catch (e) {
      onError('网络错误: $e');
    }
  }
}
