import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';
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

  @override
  void initState() {
    super.initState();
    _loadNote();
    _loadRelations();
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
              icon: const Icon(Icons.share_outlined),
              onPressed: _note != null ? _shareLink : null,
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

  String _formatDate(DateTime date) {
    return '${date.month}月${date.day}日 ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

