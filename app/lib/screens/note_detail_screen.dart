import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';
import '../services/api_service.dart';
import '../services/ai_service.dart';

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
  bool _aiEnabled = true;

  @override
  void initState() {
    super.initState();
    _checkAdmin();
    _loadNote();
    _loadRelations();
    _loadAiEnabled();
  }

  Future<void> _loadAiEnabled() async {
    final enabled = await AiService.isEnabled();
    if (mounted) {
      setState(() {
        _aiEnabled = enabled;
      });
    }
  }

  Future<void> _checkAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isAdmin = prefs.getBool('admin_logged_in') ?? false;
    });
  }

  Future<void> _loadRelations() async {
    try {
      final relations = await ApiService.getRelations(widget.noteId);
      if (!mounted) return;
      setState(() {
        _relations = relations;
      });
    } catch (_) {
      // 关联加载失败不阻塞主流程
    }
  }

  Future<void> _loadNote() async {
    setState(() => _loading = true);
    try {
      final note = await ApiService.getNoteFull(widget.noteId);
      setState(() {
        _note = note;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载失败: $e')),
      );
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

  Future<void> _togglePin() async {
    if (_note == null) return;
    try {
      final isPinned = await ApiService.togglePin(widget.noteId);
      if (!mounted) return;
      setState(() {
        _note = _note!.copyWith(isPinned: isPinned);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isPinned ? '已置顶' : '已取消置顶'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: $e')),
      );
    }
  }

  Future<void> _deleteNote() async {
    Navigator.pop(context); // 关闭对话框
    try {
      final success = await ApiService.deleteNote(widget.noteId);
      if (!mounted) return;
      if (success) {
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
      if (!mounted) return;
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
            if (_aiEnabled)
              IconButton(
                icon: const Icon(Icons.auto_awesome),
                onPressed: _note != null ? _showAiSummarize : null,
                tooltip: 'AI 摘要',
              ),
            IconButton(
              icon: Icon(
                _note?.isPinned == true
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
              ),
              onPressed: _note != null ? _togglePin : null,
              tooltip: _note?.isPinned == true ? '取消置顶' : '置顶',
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
                      color: colorScheme.primary.withValues(alpha: 0.1),
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
                    color: colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                )
              else if (_note!.createdAt != null)
                Text(
                  '撰写 ${_formatDate(_note!.createdAt!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              if (_note!.sourceCreatedAt != null &&
                  _note!.createdAt != null &&
                  _note!.sourceCreatedAt!
                          .difference(_note!.createdAt!)
                          .inSeconds
                          .abs() >
                      1)
                Text(
                  '入库 ${_formatDate(_note!.createdAt!)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
              if (_note!.updatedAt != null &&
                  _note!.createdAt != null &&
                  _note!.updatedAt!.difference(_note!.createdAt!).inSeconds > 0)
                Text(
                  '修改于 ${_formatDate(_note!.updatedAt!)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Divider(color: colorScheme.outline.withValues(alpha: 0.1)),
          const SizedBox(height: 24),
          // Content - split into markdown segments and code blocks
          _buildMixedContent(colorScheme),
          // 关联笔记（恢复 776e360 删除的模块）
          if (_hasRelations()) ...[
            const SizedBox(height: 32),
            _buildRelationsSection(colorScheme),
          ],
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  bool _hasRelations() {
    if (_relations == null) return false;
    return _relations!.outgoing.isNotEmpty || _relations!.incoming.isNotEmpty;
  }

  Widget _buildRelationsSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.link, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              '关联笔记',
              style: TextStyle(
                fontFamily: 'MiSans',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_relations!.outgoing.isNotEmpty) ...[
          _buildRelationGroup(
            label: '本文引用',
            icon: Icons.arrow_outward,
            notes: _relations!.outgoing,
            colorScheme: colorScheme,
          ),
          const SizedBox(height: 12),
        ],
        if (_relations!.incoming.isNotEmpty)
          _buildRelationGroup(
            label: '被引用',
            icon: Icons.subdirectory_arrow_right,
            notes: _relations!.incoming,
            colorScheme: colorScheme,
          ),
      ],
    );
  }

  Widget _buildRelationGroup({
    required String label,
    required IconData icon,
    required List<Map<String, dynamic>> notes,
    required ColorScheme colorScheme,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Icon(icon,
                  size: 12,
                  color: colorScheme.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 4),
              Text(
                '$label · ${notes.length}',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
        ...notes.map((n) => _buildRelationTile(n, colorScheme)),
      ],
    );
  }

  Widget _buildRelationTile(
      Map<String, dynamic> note, ColorScheme colorScheme) {
    final id = note['id'] as int?;
    final title = (note['title'] as String?) ?? '未命名';
    if (id == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => NoteDetailScreen(noteId: id),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colorScheme.outline.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.article_outlined,
                size: 16,
                color: colorScheme.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface,
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: colorScheme.onSurface.withValues(alpha: 0.3),
              ),
            ],
          ),
        ),
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
                        color: colorScheme.outline.withValues(alpha: 0.1),
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
                color: colorScheme.outline.withValues(alpha: 0.15),
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
          color: colorScheme.outline.withValues(alpha: 0.1),
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
                  color: colorScheme.outline.withValues(alpha: 0.1),
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
                      color: colorScheme.onSurface.withValues(alpha: 0.5),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_outlined,
                          size: 14,
                          color: colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '复制',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurface.withValues(alpha: 0.5),
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

  void _showAiSummarize() async {
    if (_note == null) return;
    final noteId = _note!.id;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) =>
          _AiSummarySheet(noteId: noteId, noteTitle: _note!.title),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}月${date.day}日 ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

/// AI 摘要底部弹窗
/// 流式展示后端 /api/ai/summarize/{noteId} 返回的 token
class _AiSummarySheet extends StatefulWidget {
  final int noteId;
  final String noteTitle;

  const _AiSummarySheet({required this.noteId, required this.noteTitle});

  @override
  State<_AiSummarySheet> createState() => _AiSummarySheetState();
}

class _AiSummarySheetState extends State<_AiSummarySheet> {
  final StringBuffer _buffer = StringBuffer();
  bool _loading = true;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await AiService.summarize(
      noteId: widget.noteId,
      onChunk: (chunk) {
        if (!mounted) return;
        setState(() {
          _buffer.write(chunk);
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _done = true;
        });
      },
      onError: (err) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = err;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // drag handle
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // title
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome,
                        color: colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'AI 摘要',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (_loading)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                        iconSize: 20,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  widget.noteTitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Divider(
                  height: 1, color: colorScheme.outline.withValues(alpha: 0.1)),
              // body
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  child: _error != null
                      ? _buildError(colorScheme)
                      : _buildContent(colorScheme),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    if (_buffer.isEmpty && _loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              '正在生成摘要...',
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          _buffer.toString(),
          style: TextStyle(
            fontSize: 14,
            height: 1.7,
            color: colorScheme.onSurface,
            fontFamily: 'MiSans',
          ),
        ),
        if (_loading) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '生成中...',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ],
        if (_done) ...[
          const SizedBox(height: 12),
          Text(
            '✨ AI 摘要完成',
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.primary.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildError(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.orange, size: 48),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _buffer.clear();
                _loading = true;
                _done = false;
                _error = null;
              });
              _start();
            },
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
