import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';
import '../services/api_service.dart';

class NoteDetailScreen extends StatefulWidget {
  final int noteId;

  const NoteDetailScreen({super.key, required this.noteId});

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  Note? _note;
  Relations? _relations;
  bool _loading = true;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _checkAdmin();
    _loadNote();
  }

  Future<void> _checkAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isAdmin = prefs.getBool('admin_logged_in') ?? false;
    });
  }

  Future<void> _loadNote() async {
    setState(() => _loading = true);
    try {
      final note = await ApiService.getNote(widget.noteId);
      final relations = await ApiService.getRelations(widget.noteId);
      setState(() {
        _note = note;
        _relations = relations;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  String get _noteUrl {
    final base = ApiService.baseUrl.replaceAll('/api', '');
    final slug = _note?.slug ?? widget.noteId.toString();
    return '$base/#/note/$slug';
  }

  Future<void> _shareLink() async {
    if (_note == null) return;
    await Share.share(
      '${_note!.title}\n$_noteUrl',
      subject: _note!.title,
    );
  }

  void _showLinkDialog() async {
    // 先获取所有笔记列表
    try {
      final allNotes = await ApiService.getNotes();
      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _LinkNoteSheet(
          notes: allNotes,
          currentNoteId: widget.noteId,
          onLink: (targetNote) => _linkToNote(targetNote),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载笔记列表失败: $e')),
        );
      }
    }
  }

  Future<void> _linkToNote(Note targetNote) async {
    if (_note == null) return;

    final linkText = '[[${targetNote.title}]]';
    final newContent = '${_note!.content}\n\n$linkText';

    try {
      final success = await ApiService.updateNote(
        widget.noteId,
        content: newContent,
      );

      if (success && mounted) {
        setState(() {
          _note = Note(
            id: _note!.id,
            slug: _note!.slug,
            title: _note!.title,
            content: newContent,
            summary: _note!.summary,
            tags: _note!.tags,
            createdAt: _note!.createdAt,
            sourceCreatedAt: _note!.sourceCreatedAt,
            updatedAt: _note!.updatedAt,
          );
        });

        // 刷新关联数据
        final relations = await ApiService.getRelations(widget.noteId);
        if (mounted) {
          setState(() => _relations = relations);
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已关联到「${targetNote.title}」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('关联失败: $e')),
        );
      }
    }
  }

  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定要删除「${_note?.title}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: _deleteNote,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteNote() async {
    Navigator.pop(context); // 关闭对话框
    try {
      final success = await ApiService.deleteNote(widget.noteId);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除成功')),
        );
        Navigator.pop(context); // 返回列表
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surface,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: colorScheme.surface,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(_note?.title ?? '笔记详情'),
          actions: [
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: _note != null ? _showLinkDialog : null,
              tooltip: '关联到...',
            ),
            IconButton(
              icon: const Icon(Icons.share_outlined),
              onPressed: _note != null ? _shareLink : null,
            ),
            if (_isAdmin)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: _note != null ? _showDeleteDialog : null,
              ),
          ],
        ),
        body: _loading
            ? Center(
                child: CircularProgressIndicator(color: colorScheme.primary))
            : _note == null
                ? const Center(child: Text('笔记不存在'))
                : _buildContent(colorScheme),
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    final topPadding = MediaQuery.of(context).padding.top + kToolbarHeight;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            _note!.title,
            style: TextStyle(
              fontFamily: 'MiSans',
              fontSize: 24,
              fontWeight: FontWeight.w500,
              height: 1.35,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          // Meta
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._note!.tags.map((tag) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.primary,
                      ),
                    ),
                  )),
              if (_note!.sourceCreatedAt != null)
                Text(
                  '撰写 ${_formatDate(_note!.sourceCreatedAt!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                )
              else if (_note!.createdAt != null)
                Text(
                  '撰写 ${_formatDate(_note!.createdAt!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              if (_note!.sourceCreatedAt != null && _note!.createdAt != null &&
                  _note!.sourceCreatedAt!.difference(_note!.createdAt!).inSeconds.abs() > 1)
                Text(
                  '入库 ${_formatDate(_note!.createdAt!)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withOpacity(0.35),
                  ),
                ),
              if (_note!.updatedAt != null && _note!.createdAt != null &&
                  _note!.updatedAt!.difference(_note!.createdAt!).inSeconds > 0)
                Text(
                  '修改于 ${_formatDate(_note!.updatedAt!)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withOpacity(0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withOpacity(0.1)),
          const SizedBox(height: 24),
          // Content - split into markdown segments and code blocks
          _buildMixedContent(colorScheme),
          // Relations
          if (_relations != null &&
              (_relations!.outgoing.isNotEmpty ||
                  _relations!.incoming.isNotEmpty)) ...[
            const SizedBox(height: 32),
            Divider(color: colorScheme.outline.withOpacity(0.1)),
            const SizedBox(height: 16),
            if (_relations!.outgoing.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    '↗ 引用',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withOpacity(0.5),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_relations!.outgoing.length}',
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _relations!.outgoing.map((r) => _buildRelationChip(
                  r['title'] ?? '',
                  colorScheme,
                  onTap: () => _navigateToNote(r['id']),
                )).toList(),
              ),
            ],
            if (_relations!.incoming.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '↙ 被引用',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withOpacity(0.5),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_relations!.incoming.length}',
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _relations!.incoming.map((r) => _buildRelationChip(
                  r['title'] ?? '',
                  colorScheme,
                  isIncoming: true,
                  onTap: () => _navigateToNote(r['id']),
                )).toList(),
              ),
            ],
          ],
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  /// Split note content by code blocks and render each segment.
  /// Even indices = markdown text, odd indices = code blocks.
  Widget _buildMixedContent(ColorScheme colorScheme) {
    final content = _note!.content.replaceAllMapped(
      RegExp(r'\[\[(.+?)\]\]'),
      (m) => m.group(1) ?? '',
    );

    // Split by code blocks: ```lang\n...code...\n```
    final parts = content.split(RegExp(r'```\w*\n[\s\S]*?\n```'));
    final codeBlocks = RegExp(r'```(\w*)\n([\s\S]*?)\n```')
        .allMatches(content)
        .map((m) => {'lang': m.group(1) ?? '', 'code': m.group(2) ?? ''})
        .toList();

    final children = <Widget>[];
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].trim().isNotEmpty) {
        // Split by --- (thematic break) and render each part separately
        // to avoid flutter_markdown misinterpreting --- as bold
        final mdSegments = parts[i].split(RegExp(r'^---\s*$', multiLine: true));
        for (var si = 0; si < mdSegments.length; si++) {
          if (mdSegments[si].trim().isNotEmpty) {
            children.add(
              SelectionArea(
                child: MarkdownBody(
                  data: mdSegments[si],
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                      fontFamily: 'MiSans',
                      fontSize: 15,
                      height: 1.75,
                      color: colorScheme.onSurface,
                    ),
                    h2: TextStyle(
                      fontFamily: 'MiSans',
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                    h3: TextStyle(
                      fontFamily: 'MiSans',
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                    code: TextStyle(
                      fontFamily: 'monospace',
                      backgroundColor: colorScheme.surface,
                      color: colorScheme.primary,
                      fontSize: 13,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: colorScheme.outline.withOpacity(0.1),
                      ),
                    ),
                    blockquoteDecoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                    blockquotePadding:
                        const EdgeInsets.only(left: 16, top: 8, bottom: 8),
                  ),
                ),
              ),
            );
          }
          // Insert a divider between segments (not after the last one)
          if (si < mdSegments.length - 1) {
            children.add(Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Divider(
                height: 1,
                color: colorScheme.outline.withOpacity(0.15),
              ),
            ));
          }
        }
      }
      // Add code block
      if (i < codeBlocks.length) {
        children.add(_buildCodeBlock(
          codeBlocks[i]['lang']!,
          codeBlocks[i]['code']!,
          colorScheme,
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildCodeBlock(String lang, String code, ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with lang label and copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outline.withOpacity(0.1),
                ),
              ),
            ),
            child: Row(
              children: [
                if (lang.isNotEmpty)
                  Text(
                    lang,
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onSurface.withOpacity(0.5),
                      letterSpacing: 0.5,
                    ),
                  ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('代码已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_outlined,
                          size: 14,
                          color: colorScheme.onSurface.withOpacity(0.5),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '复制',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurface.withOpacity(0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Code content
          SelectionArea(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              child: Text(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.6,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelationChip(
    String title,
    ColorScheme colorScheme, {
    bool isIncoming = false,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: colorScheme.outline.withOpacity(0.1),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isIncoming ? Icons.arrow_back : Icons.arrow_forward,
              size: 14,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToNote(int? noteId) {
    if (noteId == null) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => NoteDetailScreen(noteId: noteId),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}月${date.day}日 ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class _LinkNoteSheet extends StatefulWidget {
  final List<Note> notes;
  final int currentNoteId;
  final Function(Note) onLink;

  const _LinkNoteSheet({
    required this.notes,
    required this.currentNoteId,
    required this.onLink,
  });

  @override
  State<_LinkNoteSheet> createState() => _LinkNoteSheetState();
}

class _LinkNoteSheetState extends State<_LinkNoteSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<Note> _filteredNotes = [];

  @override
  void initState() {
    super.initState();
    _filteredNotes = widget.notes
        .where((n) => n.id != widget.currentNoteId)
        .toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterNotes(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredNotes = widget.notes
            .where((n) => n.id != widget.currentNoteId)
            .toList();
      } else {
        _filteredNotes = widget.notes
            .where((n) =>
                n.id != widget.currentNoteId &&
                (n.title.toLowerCase().contains(query.toLowerCase()) ||
                 n.summary.toLowerCase().contains(query.toLowerCase())))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 拖拽指示器
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.outline.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.link, color: colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  '关联笔记',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                  color: colorScheme.onSurface.withOpacity(0.5),
                ),
              ],
            ),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              onChanged: _filterNotes,
              decoration: InputDecoration(
                hintText: '搜索笔记...',
                hintStyle: TextStyle(
                  color: colorScheme.onSurface.withOpacity(0.4),
                ),
                prefixIcon: Icon(Icons.search,
                    color: colorScheme.onSurface.withOpacity(0.4)),
                filled: true,
                fillColor: colorScheme.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 笔记列表
          Expanded(
            child: _filteredNotes.isEmpty
                ? Center(
                    child: Text(
                      '没有可关联的笔记',
                      style: TextStyle(
                        color: colorScheme.onSurface.withOpacity(0.4),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredNotes.length,
                    itemBuilder: (context, index) {
                      final note = _filteredNotes[index];
                      return InkWell(
                        onTap: () {
                          Navigator.pop(context);
                          widget.onLink(note);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          margin: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      note.title,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: colorScheme.onSurface,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (note.summary.isNotEmpty)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(top: 2),
                                        child: Text(
                                          note.summary,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colorScheme.onSurface
                                                .withOpacity(0.5),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios,
                                size: 14,
                                color:
                                    colorScheme.onSurface.withOpacity(0.3),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(height: bottomPadding),
        ],
      ),
    );
  }
}
