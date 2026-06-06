import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../services/api_service.dart';
import 'note_detail_screen.dart';
import 'graph_screen.dart';
import 'lint_screen.dart';
import 'settings_screen.dart';
import 'mine_screen.dart';
import 'chat_screen.dart';
import '../widgets/tag_chip.dart';
import '../services/update_service.dart';

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
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _loadData();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    await UpdateService().check();
    if (mounted && UpdateService().hasUpdate) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
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
                  MaterialPageRoute(builder: (_) => SettingsScreen(
                    onToggleTheme: widget.onToggleTheme,
                    isDark: widget.isDark,
                  ))),
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

  bool get _isChinese {
    final locale = ui.PlatformDispatcher.instance.locale;
    return locale.languageCode == 'zh';
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
          const ChatScreen(),
          MineScreen(
            onToggleTheme: widget.onToggleTheme,
            isDark: widget.isDark,
          ),
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
            label: _isChinese ? '笔记' : 'Notes',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined,
                color: colorScheme.onSurface.withOpacity(0.6)),
            selectedIcon: Icon(Icons.hub, color: colorScheme.primary),
            label: _isChinese ? '图谱' : 'Graph',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline,
                color: colorScheme.onSurface.withOpacity(0.6)),
            selectedIcon: Icon(Icons.chat_bubble, color: colorScheme.primary),
            label: _isChinese ? 'AI' : 'AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline,
                color: colorScheme.onSurface.withOpacity(0.6)),
            selectedIcon: Icon(Icons.person, color: colorScheme.primary),
            label: _isChinese ? '我的' : 'Mine',
          ),
        ],
      ),
      floatingActionButton: null,
    );
  }

  Widget _buildNoteList(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          // Header (padding includes status bar height)
          Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 16, 20, 12),
            color: colorScheme.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Synapse',
                      style: TextStyle(
                        fontFamily: 'MiSans',
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
                  ],
                ),
                const SizedBox(height: 12),
                // Search
                TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    _searchDebounce?.cancel();
                    _searchDebounce = Timer(
                      const Duration(milliseconds: 300),
                      () => _onSearch(value),
                    );
                  },
                  decoration: InputDecoration(
                    hintText: '搜索笔记...',
                    hintStyle: TextStyle(
                      color: colorScheme.onSurface.withOpacity(0.4),
                    ),
                    prefixIcon: Icon(Icons.search,
                        color: colorScheme.onSurface.withOpacity(0.4)),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear,
                                color: colorScheme.onSurface.withOpacity(0.4)),
                            onPressed: () {
                              _searchController.clear();
                              _onSearch('');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest,
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
                  ..._tags.take(5).map((tag) => Padding(
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
          // Update banner
          if (UpdateService().hasUpdate)
            _buildUpdateBanner(colorScheme),
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
                                    builder: (_) => SettingsScreen(
                                      onToggleTheme: widget.onToggleTheme,
                                      isDark: widget.isDark,
                                    ),
                                  ),
                                ).then((_) => _loadData()),
                                child: const Text('前往设置'),
                              ),
                            ],
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _notes.length,
                          itemBuilder: (context, index) =>
                              _buildNoteItem(_notes[index], colorScheme),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateBanner(ColorScheme colorScheme) {
    final update = UpdateService();
    final info = update.cached!;

    return GestureDetector(
      onTap: () => _showUpdateDialog(colorScheme),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorScheme.primary.withOpacity(0.1),
              colorScheme.primary.withOpacity(0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.primary.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.system_update, size: 20, color: colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '新版本 v${info.latestVersion} 可用',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  if (info.releaseNotes != null && info.releaseNotes!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        info.releaseNotes!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }

  void _showUpdateDialog(ColorScheme colorScheme) {
    final info = UpdateService().cached!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.system_update, color: colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            Text('v${info.latestVersion}', style: const TextStyle(fontSize: 18)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (info.releaseNotes != null && info.releaseNotes!.isNotEmpty) ...[
                Text(
                  '更新内容',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  info.releaseNotes!,
                  style: TextStyle(fontSize: 14, height: 1.6, color: colorScheme.onSurface),
                ),
              ] else
                Text(
                  '发现新版本，是否前往下载？',
                  style: TextStyle(fontSize: 14, color: colorScheme.onSurface),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: colorScheme.onSurface.withOpacity(0.6))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              UpdateService().downloadUpdate();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteItem(Note note, ColorScheme colorScheme) {
    final timeAgo = _formatTimeAgo(note.sourceCreatedAt ?? note.createdAt);

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
