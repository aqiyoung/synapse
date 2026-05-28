import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/note.dart';

class ApiService {
  // 生产环境地址（可通过设置修改）
  static String baseUrl = 'https://wiki.threel.site/api';

  static Future<void> setServer(String url) async {
    baseUrl = url.endsWith('/api') ? url : '$url/api';
  }

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
      };

  // 获取笔记列表
  static Future<List<Note>> getNotes({String? tag, String? search}) async {
    var url = '$baseUrl/notes?limit=200';
    if (tag != null && tag.isNotEmpty) url += '&tag=$tag';
    if (search != null && search.isNotEmpty) url += '&search=$search';

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
}
