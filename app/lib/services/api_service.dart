import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';

class ApiService {
  static String baseUrl = '';
  static String _token = '';

  static bool get isConfigured => baseUrl.isNotEmpty;

  static Future<void> setServer(String url) async {
    baseUrl = url.endsWith('/api') ? url : '$url/api';
  }

  static void setToken(String token) {
    _token = token;
  }

  /// 设置首选模型 (持久化到 SharedPreferences, 供下次启动参考)
  /// 注意: 实际切换模型需要重启 OpenClaw gateway
  static Future<void> setModel(String model) async {
    // 通过后端代理尝试 (如果后端有 /api/config/model 端点)
    try {
      final r = await http.post(
        Uri.parse('$baseUrl/config/model'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: json.encode({'model': model}),
      );
      // 200 = 成功, 404 = 后端没配此端点 (可接受)
      if (r.statusCode == 200) return;
    } catch (_) {}
    // 后端没配 /api/config/model — 仅本地持久化, 下次重启后需手动改 openclaw.json
  }

  static Map<String, String> get headers => {
        'Content-Type': 'application/json',
        if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  // 获取笔记列表
  // summary: 列表只展示元数据，content 不需要 → 节省 ~80% 响应体积
  static const String _listFields =
      'id,slug,title,summary,tags,created_at,source_created_at,updated_at,is_pinned,folder_id';

  static Future<List<Note>> getNotes(
      {String? tag, String? search, int limit = 200, int skip = 0}) async {
    // 限制 200 是后端 list_notes 允许的最大值（api.py le=200）；超过需后端加 cursor 分页
    var url =
        '$baseUrl/notes?limit=$limit&skip=$skip&fields=${Uri.encodeQueryComponent(_listFields)}';
    if (tag != null && tag.isNotEmpty) {
      url += '&tag=${Uri.encodeQueryComponent(tag)}';
    }
    if (search != null && search.isNotEmpty) {
      url += '&search=${Uri.encodeQueryComponent(search)}';
    }

    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final notes =
          (data['notes'] as List).map((n) => Note.fromJson(n)).toList();
      return notes;
    }
    throw Exception('获取笔记失败');
  }

  // 获取笔记详情（需要完整 content）
  static Future<Note> getNoteFull(int id) async {
    final response =
        await http.get(Uri.parse('$baseUrl/notes/$id'), headers: headers);
    if (response.statusCode == 200) {
      return Note.fromJson(json.decode(response.body));
    }
    throw Exception('获取笔记详情失败');
  }

  // 缓存失效
  static Future<void> invalidateTags() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tagsKey);
    await prefs.remove(_tagsTsKey);
  }

  // 更新笔记
  static Future<bool> updateNote(int id,
      {String? title, String? content, List<String>? tags}) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (content != null) body['content'] = content;
    if (tags != null) body['tags'] = tags;

    final response = await http.put(
      Uri.parse('$baseUrl/notes/$id'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      // tags 参数变化会改标签表，使缓存过期
      if (tags != null) await invalidateTags();
      return true;
    }
    return false;
  }

  // 切换置顶状态
  static Future<bool> togglePin(int noteId) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/notes/$noteId/pin'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body)['is_pinned'] ?? false;
    }
    throw Exception('置顶操作失败');
  }

  // 获取笔记关联
  static Future<Relations> getRelations(int id) async {
    final response = await http.get(
      Uri.parse('$baseUrl/notes/$id/relations'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return Relations.fromJson(json.decode(response.body));
    }
    return Relations();
  }

  // 获取所有标签
  // 性能优化：SharedPreferences 缓存 5 分钟，避免频繁请求不变的标签列表
  static const _tagsKey = 'cached_tags';
  static const _tagsTsKey = 'cached_tags_ts';
  static const _tagsTtlMs = 5 * 60 * 1000;

  static Future<List<Tag>> getTags({bool force = false}) async {
    if (!force) {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_tagsTsKey) ?? 0;
      final raw = prefs.getString(_tagsKey);
      if (raw != null &&
          raw.isNotEmpty &&
          DateTime.now().millisecondsSinceEpoch - ts < _tagsTtlMs) {
        try {
          final list = json.decode(raw) as List;
          return list.map((t) => Tag.fromJson(t)).toList();
        } catch (_) {
          // 缓存解析失败，刷新
        }
      }
    }

    final response =
        await http.get(Uri.parse('$baseUrl/tags'), headers: headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final tags = (data as List).map((t) => Tag.fromJson(t)).toList();
      // 写入缓存
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tagsKey, json.encode(data));
      await prefs.setInt(_tagsTsKey, DateTime.now().millisecondsSinceEpoch);
      return tags;
    }
    return [];
  }

  // 搜索笔记
  static Future<List<Note>> searchNotes(String query) async {
    return getNotes(search: query);
  }

  // 获取图谱数据
  static Future<Map<String, dynamic>> getGraph() async {
    final response =
        await http.get(Uri.parse('$baseUrl/graph'), headers: headers);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    return {'nodes': [], 'edges': []};
  }

  // 获取 lint 数据
  static Future<Map<String, dynamic>> getLint() async {
    final response = await http.post(
      Uri.parse('$baseUrl/ai/lint'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    return {'issues': [], 'stats': {}};
  }

  // 删除笔记（管理员功能）
  static Future<bool> deleteNote(int id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/notes/$id'),
      headers: headers,
    );
    return response.statusCode == 200;
  }

  // ── 健康检查修复 API ──

  /// 清除所有断链（从笔记内容中移除 [[不存在的标题]]）
  static Future<Map<String, dynamic>> fixBrokenLinks() async {
    final response = await http.post(
      Uri.parse('$baseUrl/lint/fix/broken-links'),
      headers: headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('清除断链失败');
  }

  /// 清除所有孤立笔记（删除无任何关联的笔记）
  static Future<Map<String, dynamic>> fixOrphans() async {
    final response = await http.post(
      Uri.parse('$baseUrl/lint/fix/orphans'),
      headers: headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('清除孤立笔记失败');
  }

  /// 分析图谱中的问题边（自环、重复边、stale 边）
  static Future<Map<String, dynamic>> analyzeGraph() async {
    final response = await http.post(
      Uri.parse('$baseUrl/graph/analyze'),
      headers: headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('分析图谱失败');
  }

  /// 统一修复入口，根据 type 调用对应修复方法
  static Future<Map<String, dynamic>> fixLint(String type) async {
    switch (type) {
      case 'broken_link':
        return fixBrokenLinks();
      case 'orphan':
        return fixOrphans();
      case 'no_tags':
        return fixNoTags();
      case 'prune':
        return analyzeGraph();
      default:
        throw Exception('未知修复类型: $type');
    }
  }

  /// 给无标签笔记添加默认标签
  static Future<Map<String, dynamic>> fixNoTags() async {
    final response = await http.post(
      Uri.parse('$baseUrl/lint/fix/no-tags'),
      headers: headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('添加标签失败');
  }

  /// 自动关联孤立笔记
  static Future<Map<String, dynamic>> linkOrphans() async {
    final response = await http.post(
      Uri.parse('$baseUrl/lint/fix/link-orphans'),
      headers: headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('自动关联失败');
  }

  /// 验证管理员密码（服务端校验）
  static Future<bool> verifyAdmin(String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/admin/verify'),
        headers: headers,
        body: json.encode({'password': password}),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body)['ok'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// AI 对话（RAG）
  static Future<Map<String, dynamic>> chat(String question,
      {int limit = 5}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/ai/chat'),
      headers: headers,
      body: json.encode({'question': question, 'limit': limit}),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      // 确保 references 中包含 summary 字段
      if (data['references'] != null) {
        data['references'] = (data['references'] as List)
            .map((r) => {
                  'id': r['id'],
                  'title': r['title'] ?? '',
                  'summary': r['summary'] ?? '',
                })
            .toList();
      }
      return data;
    }
    throw Exception('AI 对话失败: ${response.statusCode}');
  }

  // ── 对话历史 ──

  static const _chatHistoryKey = 'chat_history';
  static const _chatHistoryMax = 20;

  /// 保存一条对话记录
  static Future<void> saveChatHistory({
    required String question,
    required String answer,
    required List<Map<String, dynamic>> references,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await loadChatHistory();
    list.insert(0, {
      'question': question,
      'answer': answer,
      'references': references,
      'timestamp': DateTime.now().toIso8601String(),
    });
    // 只保留最近 N 条
    while (list.length > _chatHistoryMax) {
      list.removeLast();
    }
    await prefs.setString(_chatHistoryKey, json.encode(list));
  }

  /// 加载所有对话历史
  static Future<List<Map<String, dynamic>>> loadChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_chatHistoryKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = json.decode(raw) as List;
    return decoded.cast<Map<String, dynamic>>();
  }

  /// 清空对话历史
  static Future<void> clearChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_chatHistoryKey);
  }
}
