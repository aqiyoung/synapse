import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            Theme.of(context).brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
      ),
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_note?.title ?? '笔记详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () {},
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
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
          // Content
          MarkdownBody(
            data: _note!.content,
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
