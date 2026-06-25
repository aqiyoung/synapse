import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import 'note_detail_screen.dart';
import '../widgets/glass_container.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _messages = <_ChatMessage>[];
  bool _isLoading = false;
  late AnimationController _typingController;

  // 快捷问题
  static const _quickQuestions = [
    {'icon': '📝', 'label': '最近更新的笔记', 'query': '最近更新的 5 篇笔记是什么？'},
    {'icon': '📊', 'label': '总结本周笔记', 'query': '帮我总结本周新增的笔记内容'},
    {'icon': '🏷️', 'label': '标签分布统计', 'query': '我的笔记标签分布是怎样的？'},
    {'icon': '💡', 'label': '知识梳理建议', 'query': '根据我的笔记内容，有什么知识梳理建议？'},
  ];

  @override
  void initState() {
    super.initState();
    _typingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _typingController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _send({String? presetQuery}) async {
    final text = presetQuery ?? _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    HapticFeedback.lightImpact();

    setState(() {
      _messages.add(_ChatMessage(role: 'user', content: text));
      _isLoading = true;
    });
    _typingController.repeat();
    _controller.clear();
    _focusNode.unfocus();
    _scrollToBottom();

    try {
      final result = await ApiService.chat(text);
      final answer = result['answer'] as String? ?? '无回答';
      final refs = (result['references'] as List?)
              ?.map((r) => _Reference(
                    id: r['id'] as int,
                    title: r['title'] as String? ?? '',
                    summary: r['summary'] as String? ?? '',
                  ))
              .toList() ??
          [];

      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          role: 'assistant',
          content: answer,
          references: refs,
        ));
      });

      await ApiService.saveChatHistory(
        question: text,
        answer: answer,
        references: refs
            .map((r) => {'id': r.id, 'title': r.title, 'summary': r.summary})
            .toList(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          role: 'assistant',
          content: '抱歉，请求失败了：$e',
          isError: true,
        ));
      });
    } finally {
      if (!mounted) return;
      _typingController.stop();
      setState(() => _isLoading = false);
      _scrollToBottom();
    }
  }

  // ── 历史记录 ──

  Future<void> _showHistory() async {
    HapticFeedback.selectionClick();
    final history = await ApiService.loadChatHistory();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.7,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // 拖拽指示条
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 标题栏
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha:0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.history_rounded,
                          size: 20, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Text('对话历史',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        )),
                    const Spacer(),
                    if (history.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('清空'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: ctx,
                            builder: (dCtx) => AlertDialog(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16)),
                              title: const Text('清空对话历史'),
                              content: const Text('确定要清空所有对话历史吗？此操作不可撤销。'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dCtx, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(dCtx, true),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: theme.colorScheme.error,
                                  ),
                                  child: const Text('清空'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await ApiService.clearChatHistory();
                            if (ctx.mounted) Navigator.pop(ctx);
                          }
                        },
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 列表
              Expanded(
                child: history.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.history_rounded,
                                size: 56,
                                color: theme.colorScheme.outlineVariant),
                            const SizedBox(height: 16),
                            Text('暂无对话历史',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                )),
                            const SizedBox(height: 4),
                            Text('开始对话后会自动保存',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                )),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        itemCount: history.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final item = history[i];
                          final question = item['question'] as String? ?? '';
                          final answer = item['answer'] as String? ?? '';
                          final ts = item['timestamp'] as String? ?? '';
                          final refs = (item['references'] as List?)
                                  ?.cast<Map<String, dynamic>>() ??
                              [];

                          return Material(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha:0.5),
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                Navigator.pop(ctx);
                                _loadHistoryItem(question, answer, refs);
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary
                                                .withValues(alpha:0.1),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Icon(Icons.chat_rounded,
                                              size: 14,
                                              color:
                                                  theme.colorScheme.primary),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            question,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme
                                                .textTheme.bodyMedium
                                                ?.copyWith(
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          _formatTimestamp(ts),
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: theme.colorScheme.outline,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      answer,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant,
                                        height: 1.4,
                                      ),
                                    ),
                                    if (refs.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Icon(Icons.attachment_rounded,
                                              size: 14,
                                              color:
                                                  theme.colorScheme.outline),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${refs.length} 篇参考笔记',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                              color: theme.colorScheme.outline,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _loadHistoryItem(
      String question, String answer, List<Map<String, dynamic>> refs) {
    setState(() {
      _messages
        ..clear()
        ..add(_ChatMessage(role: 'user', content: question))
        ..add(_ChatMessage(
          role: 'assistant',
          content: answer,
          references: refs
              .map((r) => _Reference(
                    id: r['id'] as int? ?? 0,
                    title: r['title'] as String? ?? '',
                    summary: r['summary'] as String? ?? '',
                  ))
              .toList(),
        ));
    });
    _scrollToBottom();
  }

  String _formatTimestamp(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return '刚刚';
      if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
      if (diff.inDays < 1) return '${diff.inHours}小时前';
      if (diff.inDays < 7) return '${diff.inDays}天前';
      return '${dt.month}/${dt.day}';
    } catch (_) {
      return iso;
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // 液态玻璃 Header
          GlassContainer(
            margin: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 8, 8, 8),
            borderRadius: BorderRadius.circular(20),
            blur: 24,
            tintOpacity: 0.45,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        colorScheme.primary,
                        colorScheme.primary.withValues(alpha:0.7),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.auto_awesome_rounded,
                      size: 20, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI 知识助手',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          )),
                      Text('基于你的知识库',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.outline,
                            fontSize: 11,
                          )),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.history_rounded,
                      color: colorScheme.onSurface.withValues(alpha:0.7)),
                  onPressed: _showHistory,
                  tooltip: '对话历史',
                ),
                if (_messages.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.add_comment_outlined,
                        color: colorScheme.onSurface.withValues(alpha:0.7)),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      setState(() => _messages.clear());
                    },
                    tooltip: '新对话',
                  ),
              ],
            ),
          ),
          // Messages
          Expanded(
            child: _messages.isEmpty
                ? _buildWelcomeView(colorScheme, theme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 20),
                    itemCount: _messages.length + (_isLoading ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _messages.length) {
                        return _buildLoadingIndicator(colorScheme, theme);
                      }
                      return _buildMessageBubble(
                          _messages[i], colorScheme, theme);
                    },
                  ),
          ),
          // Input
          _buildInputBar(colorScheme, theme),
        ],
      ),
    );
  }

  // ── 欢迎页 ──

  Widget _buildWelcomeView(ColorScheme colorScheme, ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          // Logo - 更简洁的设计
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha:0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.auto_awesome_rounded,
                size: 32, color: colorScheme.primary),
          ),
          const SizedBox(height: 20),
          Text(
            '知识助手',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '基于你的知识库，智能回答问题',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          // 快捷问题 - 更紧凑的布局
          ...List.generate(_quickQuestions.length, (i) {
            final q = _quickQuestions[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: colorScheme.surfaceContainerHighest.withValues(alpha:0.4),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _send(presetQuery: q['query']),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Text(q['icon']!, style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            q['label']!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Icon(Icons.arrow_forward_ios_rounded,
                            size: 14, color: colorScheme.outline.withValues(alpha:0.5)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ── 加载动画 ──

  Widget _buildLoadingIndicator(ColorScheme colorScheme, ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha:0.7),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _typingController,
              builder: (context, child) {
                return Row(
                  children: List.generate(3, (i) {
                    final delay = i * 0.33;
                    final rawValue = _typingController.value - delay;
                    final value = (rawValue % 1.0 + 1.0) % 1.0;
                    final opacity = value < 0.5 ? (value * 2) : (2 - value * 2);
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: colorScheme.primary
                            .withValues(alpha:0.3 + opacity.clamp(0.0, 1.0) * 0.7),
                        shape: BoxShape.circle,
                      ),
                    );
                  }),
                );
              },
            ),
            const SizedBox(width: 10),
            Text(
              '思考中',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 消息气泡 ──

  Widget _buildMessageBubble(
      _ChatMessage msg, ColorScheme colorScheme, ThemeData theme) {
    final isUser = msg.role == 'user';

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // 消息主体
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: msg.isError
                    ? colorScheme.errorContainer
                    : isUser
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest
                            .withValues(alpha:0.7),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isUser ? 18 : 4),
                  topRight: Radius.circular(isUser ? 4 : 18),
                  bottomLeft: const Radius.circular(18),
                  bottomRight: const Radius.circular(18),
                ),
                boxShadow: isUser
                    ? [
                        BoxShadow(
                          color: colorScheme.primary.withValues(alpha:0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: SelectableText(
                msg.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: msg.isError
                      ? colorScheme.onErrorContainer
                      : isUser
                          ? colorScheme.onPrimary
                          : colorScheme.onSurface,
                  height: 1.6,
                ),
              ),
            ),
            // 引用笔记
            if (msg.references.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...msg.references.map((ref) => _buildReferenceCard(
                    ref, colorScheme, theme)),
            ],
          ],
        ),
      ),
    );
  }

  // ── 引用笔记卡片 ──

  Widget _buildReferenceCard(
      _Reference ref, ColorScheme colorScheme, ThemeData theme) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoteDetailScreen(noteId: ref.id),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha:0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.primary.withValues(alpha:0.15),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.description_outlined,
                  size: 16, color: colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ref.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (ref.summary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      ref.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.open_in_new_rounded,
                size: 14, color: colorScheme.primary.withValues(alpha:0.6)),
          ],
        ),
      ),
    );
  }

  // ── 输入栏 ──

  Widget _buildInputBar(ColorScheme colorScheme, ThemeData theme) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: colorScheme.outline.withValues(alpha:0.05),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 100),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: '问我关于知识库的问题...',
                  hintStyle: TextStyle(
                    color: colorScheme.onSurface.withValues(alpha:0.4),
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.4,
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: _isLoading || _controller.text.trim().isEmpty
                  ? null
                  : LinearGradient(
                      colors: [
                        colorScheme.primary,
                        colorScheme.primary.withValues(alpha:0.8),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              color: _isLoading || _controller.text.trim().isEmpty
                  ? colorScheme.surfaceContainerHighest
                  : null,
              borderRadius: BorderRadius.circular(20),
            ),
            child: IconButton(
              onPressed: _isLoading ? null : () => _send(),
              icon: Icon(
                Icons.arrow_upward_rounded,
                color: _isLoading || _controller.text.trim().isEmpty
                    ? colorScheme.onSurface.withValues(alpha:0.3)
                    : Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 数据模型 ──

class _ChatMessage {
  final String role;
  final String content;
  final List<_Reference> references;
  final bool isError;

  _ChatMessage({
    required this.role,
    required this.content,
    this.references = const [],
    this.isError = false,
  });
}

class _Reference {
  final int id;
  final String title;
  final String summary;

  _Reference({
    required this.id,
    required this.title,
    this.summary = '',
  });
}
