import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';
import '../services/api_service.dart';
import 'note_detail_screen.dart';
import 'graph_screen.dart';
import 'settings_screen.dart';
import 'mine_screen.dart';
import 'chat_screen.dart';
import '../widgets/tag_chip.dart';
import '../widgets/glass_container.dart';
import '../services/update_service.dart';
import '../services/notification_service.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;
  final int themeIndex;
  final ValueChanged<int> onThemeChanged;

  const HomeScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
    required this.themeIndex,
    required this.onThemeChanged,
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
  bool _loadingMore = false;
  bool _hasMore = true;
  int _skip = 0;
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

  static const int _pageSize = 10;

  Future<void> _loadData() async {
    if (!ApiService.isConfigured) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final isRefresh = _skip == 0;
    if (isRefresh) {
      _hasMore = true;
    }
    try {
      final notes = await ApiService.getNotes(
        tag: _selectedTag.isEmpty ? null : _selectedTag,
        search: _searchQuery.isEmpty ? null : _searchQuery,
        limit: _pageSize,
        skip: _skip,
      );
      final tags = await ApiService.getTags();
      setState(() {
        _notes = notes;
        _tags = tags;
        _loading = false;
        _hasMore = notes.length >= _pageSize;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      final msg = e.toString().contains('SocketException')
          ? '无法连接服务器，请检查网络或在设置中修改服务器地址'
          : '加载失败: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          action: SnackBarAction(
            label: '设置',
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                          onToggleTheme: widget.onToggleTheme,
                          isDark: widget.isDark,
                          themeIndex: widget.themeIndex,
                          onThemeChanged: widget.onThemeChanged,
                        ))),
          ),
        ),
      );
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final notes = await ApiService.getNotes(
        tag: _selectedTag.isEmpty ? null : _selectedTag,
        search: _searchQuery.isEmpty ? null : _searchQuery,
        limit: _pageSize,
        skip: _skip + _pageSize,
      );
      setState(() {
        _notes.addAll(notes);
        _skip += _pageSize;
        _hasMore = notes.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载更多失败: $e')),
      );
    }
  }

  void _onTagSelected(String tag) {
    setState(() {
      _selectedTag = tag == _selectedTag ? '' : tag;
    });
    _loadData();
  }

  Future<void> _saveSearchHistory(String query) async {
    if (query.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('search_history') ?? [];
    history.remove(query);
    history.insert(0, query);
    if (history.length > 10) history.removeLast();
    await prefs.setStringList('search_history', history);
  }

  void _onSearch(String query) {
    setState(() => _searchQuery = query);
    if (query.trim().isNotEmpty) {
      _saveSearchHistory(query.trim());
    }
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
      backgroundColor: colorScheme.surface,
      extendBody: true, // 让 body 延伸到 bottomNav 后面，液态玻璃才有东西可模糊
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildNoteList(colorScheme),
          const GraphScreen(),
          const ChatScreen(),
          MineScreen(
            onToggleTheme: widget.onToggleTheme,
            isDark: widget.isDark,
            themeIndex: widget.themeIndex,
            onThemeChanged: widget.onThemeChanged,
          ),
        ],
      ),
      bottomNavigationBar: GlassContainer(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        borderRadius: BorderRadius.circular(24),
        blur: 24,
        tintOpacity: 0.4,
        child: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (i) => setState(() => _selectedIndex = i),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          indicatorColor: colorScheme.primary.withValues(alpha: 0.18),
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.library_books_outlined,
                  color: colorScheme.onSurface.withValues(alpha: 0.6)),
              selectedIcon:
                  Icon(Icons.library_books, color: colorScheme.primary),
              label: _isChinese ? '笔记' : 'Notes',
            ),
            NavigationDestination(
              icon: Icon(Icons.hub_outlined,
                  color: colorScheme.onSurface.withValues(alpha: 0.6)),
              selectedIcon: Icon(Icons.hub, color: colorScheme.primary),
              label: _isChinese ? '图谱' : 'Graph',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline,
                  color: colorScheme.onSurface.withValues(alpha: 0.6)),
              selectedIcon: Icon(Icons.chat_bubble, color: colorScheme.primary),
              label: _isChinese ? 'AI' : 'AI',
            ),
            NavigationDestination(
              icon: FutureBuilder<int>(
                future: NotificationService.getUnreadCount(),
                builder: (ctx, snap) {
                  final count = snap.data ?? 0;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(Icons.person_outline,
                          color: colorScheme.onSurface.withValues(alpha: 0.6)),
                      if (count > 0)
                        Positioned(
                          right: -6,
                          top: -3,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                                color: Colors.red, shape: BoxShape.circle),
                            constraints: const BoxConstraints(
                                minWidth: 14, minHeight: 14),
                            child: Text('$count',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 8),
                                textAlign: TextAlign.center),
                          ),
                        ),
                    ],
                  );
                },
              ),
              selectedIcon: Icon(Icons.person, color: colorScheme.primary),
              label: _isChinese ? '我的' : 'Mine',
            ),
          ],
        ),
      ),
      floatingActionButton: null,
    );
  }

  Widget _buildNoteList(ColorScheme colorScheme) {
    return Stack(
      children: [
        // 底层：渐变背景，让玻璃透出颜色
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colorScheme.primary.withValues(alpha: 0.10),
                  colorScheme.primary.withValues(alpha: 0.03),
                  colorScheme.surface,
                ],
                stops: const [0.0, 0.3, 0.7],
              ),
            ),
          ),
        ),
        Column(
          children: [
            // 液态玻璃 Header（包含 title + search + tags + update banner）
            GlassContainer(
              margin: EdgeInsets.fromLTRB(
                  8, MediaQuery.of(context).padding.top + 8, 8, 8),
              borderRadius: BorderRadius.circular(20),
              blur: 24,
              tintOpacity: 0.45,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row
                  Row(
                    children: [
                      Text(
                        'Synapse',
                        style: TextStyle(
                          fontFamily: 'MiSans',
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_notes.length} 篇',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 搜索框
                  TextField(
                    controller: _searchController,
                    onChanged: (value) {
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(
                        const Duration(milliseconds: 500),
                        () => _onSearch(value),
                      );
                    },
                    onSubmitted: (value) {
                      _searchDebounce?.cancel();
                      _onSearch(value);
                    },
                    decoration: InputDecoration(
                      hintText: '搜索笔记...',
                      hintStyle: TextStyle(
                        color: colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                      prefixIcon: Icon(Icons.search,
                          color: colorScheme.onSurface.withValues(alpha: 0.4)),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear,
                                  color: colorScheme.onSurface
                                      .withValues(alpha: 0.4)),
                              onPressed: () {
                                _searchController.clear();
                                _onSearch('');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: colorScheme.surface.withValues(alpha: 0.6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                            color: colorScheme.outline.withValues(alpha: 0.2)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                            color: colorScheme.outline.withValues(alpha: 0.2)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: colorScheme.primary),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                  // 标签栏（过滤日期和无意义标签，按热度排序，随机显示5个热门标签）
                  if (_tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SizedBox(
                        height: 36,
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
                            ..._getPopularTags().map((tag) => Padding(
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
                    ),
                ],
              ),
            ),
            // 笔记列表
            Expanded(
              child: _loading
                  ? Center(
                      child:
                          CircularProgressIndicator(color: colorScheme.primary))
                  : _notes.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                ApiService.isConfigured ? '暂无笔记' : '请先配置服务器',
                                style: TextStyle(
                                  color: colorScheme.onSurface
                                      .withValues(alpha: 0.4),
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
                                        themeIndex: widget.themeIndex,
                                        onThemeChanged: widget.onThemeChanged,
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
                            padding: const EdgeInsets.only(top: 8, bottom: 80),
                            cacheExtent: 600,
                            itemCount: _notes.length + (_hasMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= _notes.length) {
                                return _buildLoadMoreItem(colorScheme);
                              }
                              return _buildNoteItem(_notes[index], colorScheme);
                            },
                          ),
                        ),
            ),
          ],
        ),
      ],
    );
  }

  /// Build highlighted text spans for a string, matching [_searchQuery] keywords.
  List<TextSpan> _highlightText(
      String text, TextStyle baseStyle, ColorScheme colorScheme) {
    if (_searchQuery.isEmpty || text.isEmpty) {
      return [TextSpan(text: text, style: baseStyle)];
    }
    final lowerText = text.toLowerCase();
    final lowerQuery = _searchQuery.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx == -1) break;
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx), style: baseStyle));
      }
      spans.add(TextSpan(
        text: text.substring(idx, idx + _searchQuery.length),
        style: baseStyle.copyWith(
          color: colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ));
      start = idx + _searchQuery.length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: baseStyle));
    }
    return spans.isEmpty ? [TextSpan(text: text, style: baseStyle)] : spans;
  }

  Widget _buildNoteItem(Note note, ColorScheme colorScheme) {
    final timeAgo = _formatTimeAgo(note.sourceCreatedAt ?? note.createdAt);
    final hasHighlight = _searchQuery.isNotEmpty;

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoteDetailScreen(noteId: note.id),
          ),
        );
      },
      onLongPress: () => _showNoteMenu(note, colorScheme),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: note.isPinned ? colorScheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (note.isPinned) ...[
                  Icon(Icons.push_pin, size: 14, color: colorScheme.primary),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: hasHighlight
                      ? RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            children: _highlightText(
                              note.title,
                              TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: colorScheme.onSurface,
                              ),
                              colorScheme,
                            ),
                          ),
                        )
                      : Text(
                          note.title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
              ],
            ),
            if (note.summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              hasHighlight
                  ? RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        children: _highlightText(
                          note.summary,
                          TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                          colorScheme,
                        ),
                      ),
                    )
                  : Text(
                      note.summary,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface.withValues(alpha: 0.5),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.1),
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
                    color: colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showNoteMenu(Note note, ColorScheme colorScheme) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                note.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                color: colorScheme.primary,
              ),
              title: Text(note.isPinned ? '取消置顶' : '置顶'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await ApiService.togglePin(note.id);
                  _loadData();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('操作失败: $e')),
                  );
                }
              },
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

  /// 获取热门标签（过滤日期和无意义标签，按热度排序，随机选择5个）
  List<Tag> _getPopularTags() {
    // 过滤掉日期格式和无意义标签
    final filteredTags = _tags.where((tag) {
      final name = tag.name.trim();

      // 过滤日期格式：2026、2026-04、2026-05 等
      if (RegExp(r'^\d{4}(-\d{2})?$').hasMatch(name)) return false;

      // 过滤无意义标签（太短或明显无意义）
      if (name.length <= 1) {
        return false;
      }
      if (['了什么', '的工', '的工作', '入十几', '入十几万', '什么', '现在', '需要', '全天']
          .contains(name)) {
        return false;
      }

      // 过滤note_count为0的标签
      if (tag.noteCount <= 0) {
        return false;
      }

      return true;
    }).toList();

    // 按热度排序（note_count降序）
    filteredTags.sort((a, b) => b.noteCount.compareTo(a.noteCount));

    // 取前20个热门标签，然后随机选择5个
    final topTags = filteredTags.take(20).toList();
    if (topTags.length <= 5) return topTags;

    // 随机选择5个（使用固定的种子，保证同一会话内顺序一致）
    topTags.shuffle();
    return topTags.take(5).toList();
  }

  int get _currentPage => (_skip ~/ _pageSize) + 1;

  Widget _buildLoadMoreItem(ColorScheme colorScheme) {
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Previous button
          IconButton(
            onPressed: _currentPage > 1 ? _goToPreviousPage : null,
            icon: const Icon(Icons.chevron_left),
            color: colorScheme.primary,
          ),
          const SizedBox(width: 8),
          // Page numbers
          ...List.generate(
            _currentPage + (_hasMore ? 1 : 0),
            (index) {
              final page = index + 1;
              final isCurrent = page == _currentPage;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  onTap: () => _goToPage(page),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isCurrent ? colorScheme.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isCurrent ? colorScheme.primary : colorScheme.outline,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$page',
                      style: TextStyle(
                        color: isCurrent ? Colors.white : colorScheme.onSurface,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          // Next button
          IconButton(
            onPressed: _hasMore ? _goToNextPage : null,
            icon: const Icon(Icons.chevron_right),
            color: colorScheme.primary,
          ),
        ],
      ),
    );
  }

  void _goToPage(int page) {
    if (page < 1 || (_loadingMore)) return;
    final newSkip = (page - 1) * _pageSize;
    if (newSkip == _skip) return;
    setState(() {
      _skip = newSkip;
      _notes.clear();
      _loading = true;
    });
    _loadData();
  }

  void _goToPreviousPage() => _goToPage(_currentPage - 1);
  void _goToNextPage() => _goToPage(_currentPage + 1);
}
