import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _serverController = TextEditingController();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _loadServer();
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _loadServer() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server') ?? '';
    setState(() {
      _serverController.text = server;
    });
  }

  Future<void> _saveServer() async {
    final server = _serverController.text.trim();
    if (server.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server', server);
    await ApiService.setServer(server);

    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '服务器配置',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serverController,
            decoration: InputDecoration(
              hintText: 'https://your-server.com',
              labelText: '服务器地址',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saveServer,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(_saved ? '已保存' : '保存'),
            ),
          ),
          const SizedBox(height: 32),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 16),
          Text(
            '关于',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: Icon(Icons.info_outline, color: colorScheme.primary),
            title: const Text('版本'),
            subtitle: const Text('2.0.4'),
            contentPadding: EdgeInsets.zero,
          ),
          ListTile(
            leading: Icon(Icons.code, color: colorScheme.primary),
            title: const Text('技术栈'),
            subtitle: const Text('Flutter + FastAPI + SQLite'),
            contentPadding: EdgeInsets.zero,
          ),
          ListTile(
            leading: Icon(Icons.smart_toy_outlined, color: colorScheme.primary),
            title: const Text('AI 驱动'),
            subtitle: const Text('自动标签 · 自动关联 · 自动质检'),
            contentPadding: EdgeInsets.zero,
          ),
          ListTile(
            leading: Icon(Icons.language, color: colorScheme.primary),
            title: const Text('开源'),
            subtitle: const Text('github.com/aqiyoung/synapse'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outline.withOpacity(0.1),
              ),
            ),
            child: Text(
              'Synapse 是一个 AI 驱动的个人知识管理系统。你只管写内容，剩下的全交给 AI —— 自动标签、自动整理、自动质检、自动关联。后台脚本持续运行，无需人工干预。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
