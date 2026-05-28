import 'package:flutter/material.dart';
import '../models/note.dart';
import '../services/api_service.dart';
import 'note_detail_screen.dart';
import 'graph_screen.dart';
import 'lint_screen.dart';
import 'settings_screen.dart';
import '../widgets/tag_chip.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;

  const HomeScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  List<Note> _notes = [];
  List<Tag> _tags = [];
  String _selectedTag = '';
  String _searchQuery = '';
  bool _loading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!ApiService.isConfigured) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final notes = await ApiService.getNotes(
        tag: _selectedTag.isEmpty ? null : _selectedTag,
        search: _searchQuery.isEmpty ? null : _searchQuery,
      );
      final tags = await ApiService.getTags();
      setState(() {
        _notes = notes;
        _tags = tags;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        final msg = e.toString().contains('SocketException')
            ? '无法连接服务器，请检查网络或在设置中修改服务器地址'
            : '加载失败: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(
              label: '设置',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ),
        );
      }
    }
  }

  void _onTagSelected(String tag) {
    setState(() {
      _selectedTag = tag == _selectedTag ? '' : tag;
    });
    _loadData();
  }

  void _onSearch(String query) {
    setState(() => _searchQuery = query);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildNoteList(colorScheme),
          const GraphScreen(),
          const LintScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primary.withOpacity(0.12),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined,
                color: colorScheme.onSurface.withOpacity(0.6)),
            selectedIcon: Icon(Icons.library_books, color: colorScheme.primary),
            label: '知识库',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined,
                color: colorScheme.onSurface.withOpacity(0.6)),
            selectedIcon: Icon(Icons.hub, color: colorScheme.primary),
            label: '图谱',
          ),
          NavigationDestination(
            icon: Icon(Icons.health_and_safety_outlined,
                color: colorScheme.onSurface.withOpacity(0.6)),
            selectedIcon:
                Icon(Icons.health_and_safety, color: colorScheme.primary),
            label: '检查',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: widget.onToggleTheme,
        backgroundColor: colorScheme.surface,
        child: Icon(
          widget.isDark ? Icons.light_mode : Icons.dark_mode,
          color: colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildNoteList(ColorScheme colorScheme) {
    return SafeArea(
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            color: colorScheme.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '知识库',
                      style: TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_notes.length} 篇',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                      },
                      child: Icon(
                        Icons.settings_outlined,
                        size: 20,
                        color: colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Search
                TextField(
                  controller: _searchController,
                  onSubmitted: _onSearch,
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
                      borderSide: BorderSide(color: colorScheme.outline.withOpacity(0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colorScheme.outline.withOpacity(0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colorScheme.primary),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
          // Tags
          if (_tags.isNotEmpty)
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: colorScheme.surface,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TagChip(
                      label: '全部',
                      selected: _selectedTag.isEmpty,
                      count: _notes.length,
                      onTap: () => _onTagSelected(''),
                    ),
                  ),
                  ..._tags.take(10).map((tag) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TagChip(
                          label: tag.name,
                          selected: _selectedTag == tag.name,
                          count: tag.noteCount,
                          onTap: () => _onTagSelected(tag.name),
                        ),
                      )),
                ],
              ),
            ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.1)),
          // Note list
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(color: colorScheme.primary))
                : _notes.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              ApiService.isConfigured ? '暂无笔记' : '请先配置服务器',
                              style: TextStyle(
                                color: colorScheme.onSurface.withOpacity(0.4),
                              ),
                            ),
                            if (!ApiService.isConfigured) ...[
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const SettingsScreen()),
                                ).then((_) => _loadData()),
                                child: const Text('前往设置'),
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _notes.length,
                        itemBuilder: (context, index) =>
                            _buildNoteItem(_notes[index], colorScheme),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteItem(Note note, ColorScheme colorScheme) {
    final timeAgo = _formatTimeAgo(note.updatedAt);

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoteDetailScreen(noteId: note.id),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
            if (note.summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                note.summary,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface.withOpacity(0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                if (note.tags.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      note.tags.first,
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  timeAgo,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime? dateTime) {
    if (dateTime == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return '${dateTime.month}月${dateTime.day}日';
  }
}
