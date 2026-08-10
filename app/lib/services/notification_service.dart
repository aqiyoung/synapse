import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

class AppNotification {
  final int id;
  final String title;
  final String body;
  final String type;
  final bool isRead;
  final String? actionUrl;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.title,
    this.body = '',
    this.type = 'system',
    this.isRead = false,
    this.actionUrl,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] ?? 0,
        title: json['title'] ?? '',
        body: json['body'] ?? '',
        type: json['type'] ?? 'system',
        isRead: json['is_read'] ?? false,
        actionUrl: json['action_url'],
        createdAt:
            json['created_at'] != null
                ? DateTime.tryParse(json['created_at']) ?? DateTime.now()
                : DateTime.now(),
      );
}

class NotificationService {
  static const _enabledKey = 'notifications_enabled';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  static Future<List<AppNotification>> getNotifications({
    bool unreadOnly = false,
  }) async {
    var url = '${ApiService.baseUrl}/notifications?limit=50';
    if (unreadOnly) url += '&unread_only=true';
    final r = await http.get(Uri.parse(url), headers: ApiService.headers);
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List)
          .map((e) => AppNotification.fromJson(e))
          .toList();
    }
    return [];
  }

  static Future<int> getUnreadCount() async {
    final r = await http.get(
      Uri.parse('${ApiService.baseUrl}/notifications/unread-count'),
      headers: ApiService.headers,
    );
    if (r.statusCode == 200) {
      return json.decode(r.body)['count'] ?? 0;
    }
    return 0;
  }

  static Future<void> markRead(int id) async {
    await http.post(
      Uri.parse('${ApiService.baseUrl}/notifications/$id/read'),
      headers: ApiService.headers,
    );
  }

  static Future<void> markAllRead() async {
    await http.post(
      Uri.parse('${ApiService.baseUrl}/notifications/read-all'),
      headers: ApiService.headers,
    );
  }

  static Future<void> deleteNotification(int id) async {
    await http.delete(
      Uri.parse('${ApiService.baseUrl}/notifications/$id'),
      headers: ApiService.headers,
    );
  }
}
