import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/stats.dart';
import 'api_service.dart';

class StatsService {
  static Future<OverallStats> getOverall() async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/stats'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return OverallStats.fromJson(json.decode(r.body));
    }
    throw Exception('获取统计失败');
  }

  static Future<ReadingStats> getNoteStats(int noteId) async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/stats/note/$noteId'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return ReadingStats.fromJson(json.decode(r.body));
    }
    return ReadingStats(noteId: noteId);
  }

  static Future<void> recordRead(int noteId) async {
    await http.post(Uri.parse('${ApiService.baseUrl}/stats/note/$noteId/read'), headers: ApiService._headers);
  }
}
