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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('加载失败: $e')),
          ),
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
              fontFamily: 'Georgia',
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
              if (_note!.updatedAt != null)
                Text(
                  '更新于 ${_formatDate(_note!.updatedAt!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.5),
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
            Text(
              '关联笔记',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withOpacity(0.5),
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ..._relations!.outgoing.map((r) => _buildRelationChip(
                      r['title'] ?? '',
                      colorScheme,
                      onTap: () => _navigateToNote(r['id']),
                    )),
                ..._relations!.incoming.map((r) => _buildRelationChip(
                      r['title'] ?? '',
                      colorScheme,
                      isIncoming: true,
                      onTap: () => _navigateToNote(r['id']),
                    )),
              ],
            ),
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
      // Add markdown segment
      if (parts[i].trim().isNotEmpty) {
        children.add(
          SelectionArea(
            child: MarkdownBody(
              data: parts[i],
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  fontSize: 15,
                  height: 1.75,
                  color: colorScheme.onSurface,
                ),
                h2: TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                ),
                h3: TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                ),
                code: TextStyle(
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
