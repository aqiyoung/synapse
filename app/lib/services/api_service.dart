import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/note.dart';

class ApiService {
  static String baseUrl = '';

  static bool get isConfigured => baseUrl.isNotEmpty;

  static Future<void> setServer(String url) async {
    baseUrl = url.endsWith('/api') ? url : '$url/api';
  }

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
      };

  // 获取笔记列表
  static Future<List<Note>> getNotes({String? tag, String? search}) async {
    var url = '$baseUrl/notes?limit=200';
    if (tag != null && tag.isNotEmpty) url += '&tag=${Uri.encodeQueryComponent(tag)}';
    if (search != null && search.isNotEmpty) url += '&search=${Uri.encodeQueryComponent(search)}';

    final response = await http.get(Uri.parse(url), headers: _headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final notes = (data['notes'] as List)
          .map((n) => Note.fromJson(n))
          .toList();
      return notes;
    }
    throw Exception('获取笔记失败');
  }

  // 获取单个笔记
  static Future<Note> getNote(int id) async {
    final response =
        await http.get(Uri.parse('$baseUrl/notes/$id'), headers: _headers);
    if (response.statusCode == 200) {
      return Note.fromJson(json.decode(response.body));
    }
    throw Exception('获取笔记详情失败');
  }

  // 更新笔记
  static Future<bool> updateNote(int id, {String? title, String? content, List<String>? tags}) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (content != null) body['content'] = content;
    if (tags != null) body['tags'] = tags;

    final response = await http.put(
      Uri.parse('$baseUrl/notes/$id'),
      headers: _headers,
      body: json.encode(body),
    );
    return response.statusCode == 200;
  }

  // 获取笔记关联
  static Future<Relations> getRelations(int id) async {
    final response = await http.get(
      Uri.parse('$baseUrl/notes/$id/relations'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      return Relations.fromJson(json.decode(response.body));
    }
    return Relations();
  }

  // 获取所有标签
  static Future<List<Tag>> getTags() async {
    final response =
        await http.get(Uri.parse('$baseUrl/tags'), headers: _headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data as List).map((t) => Tag.fromJson(t)).toList();
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
        await http.get(Uri.parse('$baseUrl/graph'), headers: _headers);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    return {'nodes': [], 'edges': []};
  }

  // 获取 lint 数据
  static Future<Map<String, dynamic>> getLint() async {
    final response = await http.post(
      Uri.parse('$baseUrl/ai/lint'),
      headers: _headers,
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
      headers: _headers,
    );
    return response.statusCode == 200;
  }

  // ── 健康检查修复 API ──

  /// 清除所有断链（从笔记内容中移除 [[不存在的标题]]）
  static Future<Map<String, dynamic>> fixBrokenLinks() async {
    final response = await http.post(
      Uri.parse('$baseUrl/lint/fix/broken-links'),
      headers: _headers,
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
      headers: _headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('清除孤立笔记失败');
  }

  /// 清除图谱中的垃圾边（自环、重复边）
  static Future<Map<String, dynamic>> pruneGraph() async {
    final response = await http.post(
      Uri.parse('$baseUrl/graph/prune'),
      headers: _headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('清理图谱失败');
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
        return pruneGraph();
      default:
        throw Exception('未知修复类型: $type');
    }
  }

  /// 给无标签笔记添加默认标签
  static Future<Map<String, dynamic>> fixNoTags() async {
    final response = await http.post(
      Uri.parse('$baseUrl/lint/fix/no-tags'),
      headers: _headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('添加标签失败');
  }
}
