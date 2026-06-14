import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/folder.dart';
import '../models/note.dart';
import 'api_service.dart';

class FolderService {
  static Future<List<Folder>> getFolders() async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/folders'), headers: ApiService.headers);
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((e) => Folder.fromJson(e)).toList();
    }
    return [];
  }

  static Future<Folder?> createFolder({required String name, String icon = 'folder', String color = '#c96442', int? parentId}) async {
    final r = await http.post(Uri.parse('${ApiService.baseUrl}/folders'),
      headers: ApiService.headers,
      body: json.encode({'name': name, 'icon': icon, 'color': color, 'parent_id': parentId}),
    );
    if (r.statusCode == 200) return Folder.fromJson(json.decode(r.body));
    return null;
  }

  static Future<bool> updateFolder(int id, {String? name, String? icon, String? color, int? parentId, int? sortOrder}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (icon != null) body['icon'] = icon;
    if (color != null) body['color'] = color;
    if (parentId != null) body['parent_id'] = parentId;
    if (sortOrder != null) body['sort_order'] = sortOrder;
    final r = await http.put(Uri.parse('${ApiService.baseUrl}/folders/$id'),
      headers: ApiService.headers,
      body: json.encode(body),
    );
    return r.statusCode == 200;
  }

  static Future<bool> deleteFolder(int id) async {
    final r = await http.delete(Uri.parse('${ApiService.baseUrl}/folders/$id'), headers: ApiService.headers);
    return r.statusCode == 200;
  }

  static Future<List<Note>> getFolderNotes(int folderId) async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/folders/$folderId/notes'), headers: ApiService.headers);
    if (r.statusCode == 200) {
      final data = json.decode(r.body);
      return (data['notes'] as List).map((n) => Note.fromJson(n)).toList();
    }
    return [];
  }

  static Future<bool> setNoteFolder(int noteId, int? folderId) async {
    final r = await http.put(Uri.parse('${ApiService.baseUrl}/notes/$noteId/folder'),
      headers: ApiService.headers,
      body: json.encode({'folder_id': folderId}),
    );
    return r.statusCode == 200;
  }
}
