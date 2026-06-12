import 'package:flutter/material.dart';
import '../models/folder.dart';
import '../models/app_theme.dart';
import 'note_detail_screen.dart';
import '../services/folder_service.dart';

class FoldersScreen extends StatefulWidget {
  final int themeIndex;
  const FoldersScreen({super.key, required this.themeIndex});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  List<Folder> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final folders = await FolderService.getFolders();
    setState(() { _folders = folders; _loading = false; });
  }

  void _showCreateDialog() {
    final nameCtrl = TextEditingController();
    String selectedColor = '#c96442';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建分类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '分类名称'),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  '#c96442', '#4CAF50', '#2196F3', '#9C27B0', '#FF9800', '#607D8B'
                ].map((c) => GestureDetector(
                  onTap: () => setDialogState(() => selectedColor = c),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(int.parse(c.substring(1), radix: 16) + 0xFF000000),
                    child: selectedColor == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                  ),
                )).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () async {
              if (nameCtrl.text.isNotEmpty) {
                await FolderService.createFolder(name: nameCtrl.text, color: selectedColor);
                if (ctx.mounted) Navigator.pop(ctx);
                _load();
              }
            }, child: const Text('创建')),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(Folder folder) {
    final nameCtrl = TextEditingController(text: folder.name);
    String selectedColor = folder.color;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑分类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '分类名称'),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  '#c96442', '#4CAF50', '#2196F3', '#9C27B0', '#FF9800', '#607D8B'
                ].map((c) => GestureDetector(
                  onTap: () => setDialogState(() => selectedColor = c),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(int.parse(c.substring(1), radix: 16) + 0xFF000000),
                    child: selectedColor == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                  ),
                )).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () async {
              if (nameCtrl.text.isNotEmpty) {
                await FolderService.updateFolder(folder.id, name: nameCtrl.text, color: selectedColor);
                if (ctx.mounted) Navigator.pop(ctx);
                _load();
              }
            }, child: const Text('保存')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.presets[widget.themeIndex];
    return Scaffold(
      appBar: AppBar(title: const Text('分类管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _folders.isEmpty
              ? const Center(child: Text('暂无分类，点击 + 创建'))
              : ListView.builder(
                  itemCount: _folders.length,
                  itemBuilder: (ctx, i) {
                    final f = _folders[i];
                    final color = Color(int.parse(f.color.substring(1), radix: 16) + 0xFF000000);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: color,
                        child: const Icon(Icons.folder, color: Colors.white),
                      ),
                      title: Text(f.name),
                      subtitle: Text('${f.noteCount} 篇笔记'),
                      trailing: PopupMenuButton(
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑')),
                          const PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                        onSelected: (v) async {
                          if (v == 'edit') _showEditDialog(f);
                          if (v == 'delete') {
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (_) => AlertDialog(
                                title: const Text('确认删除'),
                                content: Text('删除分类 "${f.name}"？笔记将移到未分类。'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(_, false), child: const Text('取消')),
                                  TextButton(onPressed: () => Navigator.pop(_, true), child: const Text('删除')),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await FolderService.deleteFolder(f.id);
                              _load();
                            }
                          }
                        },
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FolderNotesScreen(folder: f, themeIndex: widget.themeIndex),
                          ),
                        );
                        _load();
                      },
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}


class FolderNotesScreen extends StatefulWidget {
  final Folder folder;
  final int themeIndex;
  const FolderNotesScreen({super.key, required this.folder, required this.themeIndex});
  @override
  State<FolderNotesScreen> createState() => _FolderNotesScreenState();
}

class _FolderNotesScreenState extends State<FolderNotesScreen> {
  List<Note> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final notes = await FolderService.getFolderNotes(widget.folder.id);
    if (mounted) {
      setState(() { _notes = notes; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.presets[widget.themeIndex];
    final color = Color(int.parse(widget.folder.color.substring(1), radix: 16) + 0xFF000000);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(radius: 12, backgroundColor: color, child: const Icon(Icons.folder, size: 14, color: Colors.white)),
            const SizedBox(width: 8),
            Text(widget.folder.name),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? const Center(child: Text('暂无笔记'))
              : ListView.builder(
                  itemCount: _notes.length,
                  itemBuilder: (ctx, i) {
                    final n = _notes[i];
                    return ListTile(
                      title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(n.summary ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => NoteDetailScreen(noteId: n.id),
                          ),
                        );
                        _load();
                      },
                    );
                  },
                ),
    );
  }
}

