import 'package:flutter/material.dart';
import '../services/notification_service.dart';
import '../models/app_theme.dart';

class NotificationsScreen extends StatefulWidget {
  final int themeIndex;
  const NotificationsScreen({super.key, required this.themeIndex});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _notifications = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await NotificationService.getNotifications();
    setState(() {
      _notifications = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.presets[widget.themeIndex];
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知中心'),
        actions: [
          TextButton(
            onPressed: () async {
              await NotificationService.markAllRead();
              _load();
            },
            child: const Text('全部已读', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _notifications.isEmpty
              ? const Center(child: Text('暂无通知'))
              : RefreshIndicator(
                onRefresh: _load,
                child: ListView.builder(
                  itemCount: _notifications.length,
                  itemBuilder: (ctx, i) {
                    final n = _notifications[i];
                    return Dismissible(
                      key: Key('notif_${n.id}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) async {
                        await NotificationService.deleteNotification(n.id);
                        _load();
                      },
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              n.isRead
                                  ? Colors.grey
                                  : theme.colorScheme.primary,
                          child: Icon(
                            n.isRead ? Icons.check : Icons.notifications,
                            color: Colors.white,
                          ),
                        ),
                        title: Text(
                          n.title,
                          style: TextStyle(
                            fontWeight:
                                n.isRead ? FontWeight.normal : FontWeight.bold,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (n.body.isNotEmpty)
                              Text(
                                n.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            Text(
                              '${n.createdAt.month}/${n.createdAt.day} ${n.createdAt.hour}:${n.createdAt.minute.toString().padLeft(2, '0')}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                        onTap: () async {
                          if (!n.isRead) {
                            await NotificationService.markRead(n.id);
                            _load();
                          }
                        },
                      ),
                    );
                  },
                ),
              ),
    );
  }
}
