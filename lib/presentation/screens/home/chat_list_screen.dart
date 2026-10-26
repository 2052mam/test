import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import '../chat/create_channel_screen.dart';

import 'main_shell.dart';
import 'archived_chats_screen.dart';
import 'folder_editor_screen.dart';

import '../../providers/chat_list_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../../data/models/chat_folder_model.dart';
import '../../../core/utils/chat_search.dart';
import '../../../core/utils/app_locale.dart';
import '../../../core/utils/security_message_localizer.dart';
import '../../../data/models/chat_model.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/chat_navigation.dart';
import '../chat/chat_screen.dart';
import '../settings/device_management_screen.dart';
import '../../widgets/chat/chat_labels.dart';
import '../../widgets/chat/chat_list_actions.dart';
import '../../widgets/chat/chat_list_tile.dart';
import '../../widgets/chat/sponsored_banner.dart';
import '../../widgets/stories/story_bar.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  /// null = the "All" folder, [_personalFolderId] = the built in personal
  /// folder, anything else is a custom folder id.
  String? _selectedFolderId;

  static const String _personalFolderId = '__personal__';

  /// In-list search (Item 4). Empty means the normal folder view.
  final TextEditingController _searchCtrl = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  ChatFolderModel? _selectedFolder(List<ChatFolderModel> folders) {
    final id = _selectedFolderId;
    if (id == null || id == _personalFolderId) return null;
    for (final folder in folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  List<ChatModel> _visibleChats(
    List<ChatModel> chats,
    List<ChatFolderModel> folders, {
    List<ChatModel> archived = const [],
  }) {
    if (_query.trim().isNotEmpty) {
      final pool = <ChatModel>[...chats];
      final seen = pool.map((chat) => chat.id).toSet();
      for (final chat in archived) {
        if (seen.add(chat.id)) pool.add(chat);
      }
      return filterChats(pool, _query);
    }
    final id = _selectedFolderId;
    if (id == null) return chats;
    if (id == _personalFolderId) {
      return chats.where((c) => c.isPersonal).toList();
    }
    final folder = _selectedFolder(folders);
    if (folder == null) return chats;
    final pool = folder.includeArchived ? [...chats, ...archived] : chats;
    return pool.where(folder.contains).toList();
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatListProvider);
    final foldersAsync = ref.watch(chatFoldersProvider);
    final folders = foldersAsync.valueOrNull ?? const <ChatFolderModel>[];
    final locale = ref.watch(localeProvider);
    final isFa = locale.languageCode == 'fa';
    final labels = ChatLabels.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_selectedFolderId != null &&
        _selectedFolderId != _personalFolderId &&
        foldersAsync.hasValue &&
        !folders.any((f) => f.id == _selectedFolderId)) {
      _selectedFolderId = null;
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0.5,
        title: _searching
            ? TextField(
                key: const ValueKey('chat-list-search-field'),
                controller: _searchCtrl,
                autofocus: true,
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  hintText: isFa
                      ? 'جستجو در چت‌ها، گروه‌ها و کانال‌ها...'
                      : 'Search chats, groups and channels...',
                  hintStyle: TextStyle(
                    color: isDark ? Colors.white60 : const Color(0xFF94A3B8),
                    fontSize: 15,
                  ),
                ),
              )
            : Text(
                isFa ? 'پیام‌رسان' : 'Messenger',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 21),
              ),
        actions: [
          IconButton(
            key: const ValueKey('chat-list-search'),
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
            onPressed: _toggleSearch,
            tooltip: isFa ? 'جستجو' : 'Search',
          ),
          if (!_searching)
            IconButton(
              key: const ValueKey('global-search'),
              icon: const Icon(Icons.travel_explore_rounded),
              onPressed: () {
                ref.read(shellIndexProvider.notifier).state = 1;
              },
              tooltip: isFa ? 'جستجوی سراسری' : 'Global search',
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (v) => _onMenu(v, isFa),
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'saved',
                child: Row(
                  children: [
                    const Icon(Icons.bookmark_outline_rounded, size: 20),
                    const SizedBox(width: 12),
                    Text(isFa ? 'پیام‌های ذخیره‌شده' : 'Saved Messages'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'group',
                child: Row(
                  children: [
                    const Icon(Icons.group_outlined, size: 20),
                    const SizedBox(width: 12),
                    Text(isFa ? 'گروه جدید' : 'New Group'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'channel',
                child: Row(
                  children: [
                    const Icon(Icons.campaign_outlined, size: 20),
                    const SizedBox(width: 12),
                    Text(isFa ? 'کانال جدید' : 'New Channel'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'folder',
                child: Row(
                  children: [
                    const Icon(Icons.create_new_folder_outlined, size: 20),
                    const SizedBox(width: 12),
                    Text(labels.newFolder),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'archive',
                child: Row(
                  children: [
                    const Icon(Icons.archive_outlined, size: 20),
                    const SizedBox(width: 12),
                    Text(labels.archivedChats),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'support',
                child: Row(
                  children: [
                    const Icon(Icons.support_agent_rounded, size: 20),
                    const SizedBox(width: 12),
                    Text(isFa ? 'پشتیبانی' : 'Support'),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: _searching
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Container(
                  color: isDark ? const Color(0xFF17212B) : Colors.white,
                  child: _FolderBar(
                    folders: folders,
                    selectedId: _selectedFolderId,
                    personalId: _personalFolderId,
                    onSelected: (id) => setState(() => _selectedFolderId = id),
                    onEdit: _openFolderEditor,
                    onCreate: () => _openFolderEditor(null),
                  ),
                ),
              ),
      ),
      body: SafeArea(
        child: chatsAsync.when(
          data: (data) {
            final folder = _selectedFolder(folders);
            final searching = _query.trim().isNotEmpty;
            final archived = (folder?.includeArchived == true || searching)
                ? (ref.watch(archivedChatListProvider).valueOrNull?.chats ??
                      const <ChatModel>[])
                : const <ChatModel>[];
            final chats = _visibleChats(
              data.chats,
              folders,
              archived: archived,
            );
            final showArchiveRow =
                !searching && _selectedFolderId == null && data.hasArchive;
            if (chats.isEmpty && !showArchiveRow) {
              return _EmptyState(
                isFa: isFa,
                inFolder: _selectedFolderId != null,
                searching: searching,
              );
            }
            final itemCount = chats.length + (showArchiveRow ? 1 : 0);
            return Column(
              children: [
                if (!searching) const _SecurityAlertBanner(),
                if (!searching) const StoryBar(),
                if (!searching && _selectedFolderId == null)
                  const _SponsoredStrip(),
                Expanded(
                  child: RefreshIndicator(
                    color: theme.colorScheme.primary,
                    onRefresh: () => ref.read(chatListProvider.notifier).refresh(),
                    child: ListView.separated(
                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                      itemCount: itemCount,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        indent: 78,
                        color: theme.dividerColor.withValues(alpha: 0.35),
                      ),
                      itemBuilder: (context, index) {
                        if (showArchiveRow && index == 0) {
                          return _ArchiveRow(
                            state: data,
                            labels: labels,
                            onTap: _openArchive,
                          );
                        }
                        final chat = chats[index - (showArchiveRow ? 1 : 0)];
                        return ChatListTile(
                          key: ValueKey(chat.id),
                          chat: chat,
                          isFa: isFa,
                          onTap: () => _openChat(chat),
                          onLongPress: () =>
                              showChatContextMenu(context, ref, chat),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
          loading: () => _ChatListShimmer(isDark: isDark),
          error: (e, _) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.error_outline_rounded, color: Colors.red, size: 40),
                ),
                const SizedBox(height: 16),
                Text(
                  isFa ? 'خطا در بارگذاری' : 'Failed to load',
                  style: const TextStyle(color: Colors.red, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  onPressed: () =>
                      ref.read(chatListProvider.notifier).refresh(),
                  label: Text(isFa ? 'تلاش مجدد' : 'Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openChat(ChatModel chat) {
    unawaited(ChatNavigation.open(
      context,
      chatId: chat.id,
      builder: (_) => ChatScreen(
        chatId: chat.id,
        title: chat.displayTitle,
        chatType: chat.chatType,
        otherUser: chat.otherUser,
        avatarUrl: chat.avatarUrl,
      ),
    ));
  }

  Future<void> _openArchive() async {
    await openArchivedChats(context, ref);
    if (!mounted) return;
    ref.read(chatListProvider.notifier).refresh();
  }

  Future<void> _openFolderEditor(ChatFolderModel? folder) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => FolderEditorScreen(folder: folder)),
    );
    if (!mounted) return;
    if (saved == true) {
      await ref.read(chatFoldersProvider.notifier).load();
    }
  }

  Future<void> _onMenu(String value, bool isFa) async {
    try {
      if (value == 'saved') {
        final res = await ApiService().post('/chats/saved', {});
        if (!mounted) return;
        unawaited(ChatNavigation.open(
          context,
          chatId: res['chat_id'] as String,
          builder: (_) => ChatScreen(
            chatId: res['chat_id'] as String,
            title: isFa ? 'پیام‌های ذخیره‌شده' : 'Saved Messages',
            chatType: 'saved',
          ),
        ));
      } else if (value == 'support') {
        final res = await ApiService().post('/chats/support', {});
        if (!mounted) return;
        unawaited(ChatNavigation.open(
          context,
          chatId: res['chat_id'] as String,
          builder: (_) => ChatScreen(
            chatId: res['chat_id'] as String,
            title: isFa ? 'پشتیبانی' : 'Support',
            chatType: 'support',
          ),
        ));
      } else if (value == 'group') {
        await _createGroupDialog(isFa);
      } else if (value == 'channel') {
        await _createChannelDialog(isFa);
      } else if (value == 'folder') {
        await _openFolderEditor(null);
        return;
      } else if (value == 'archive') {
        await _openArchive();
        return;
      }
      ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _createGroupDialog(bool isFa) async {
    final titleCtrl = TextEditingController();
    final List<String> selectedIds = [];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFa ? 'گروه جدید' : 'New Group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: isFa ? 'نام گروه' : 'Group name',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isFa ? 'لغو' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isFa ? 'ایجاد' : 'Create'),
          ),
        ],
      ),
    );
    if (ok == true && titleCtrl.text.trim().isNotEmpty) {
      final res = await ApiService().post('/chats/group', {
        'title': titleCtrl.text.trim(),
        'member_ids': selectedIds,
      });
      if (!mounted) return;
      unawaited(ChatNavigation.open(
        context,
        chatId: res['chat_id'] as String,
        builder: (_) => ChatScreen(
          chatId: res['chat_id'] as String,
          title: titleCtrl.text.trim(),
          chatType: 'group',
        ),
      ));
    }
  }

  Future<void> _createChannelDialog(bool isFa) async {
    final session = ref.read(authenticatedSessionProvider);
    final created = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => CreateChannelScreen(api: session.api)),
    );
    if (!mounted || created == null) return;
    ref.read(chatListProvider.notifier).refresh();
    await ChatNavigation.open(
      context,
      chatId: created['chat_id'] as String,
      builder: (_) => ChatScreen(
        chatId: created['chat_id'] as String,
        title: created['title'] as String,
        chatType: 'channel',
      ),
    );
  }
}

/// Shimmer skeleton loading state for Telegram-like fluid perception
class _ChatListShimmer extends StatelessWidget {
  final bool isDark;
  const _ChatListShimmer({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final base = isDark ? const Color(0xFF1E2C3A) : const Color(0xFFE2E8F0);
    final highlight = isDark ? const Color(0xFF27384A) : const Color(0xFFF1F5F9);

    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: highlight,
      child: ListView.separated(
        itemCount: 8,
        padding: const EdgeInsets.symmetric(vertical: 8),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 140,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Container(
                width: 36,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal folder strip: All | Personal | custom folders | +
class _FolderBar extends StatelessWidget {
  const _FolderBar({
    required this.folders,
    required this.selectedId,
    required this.personalId,
    required this.onSelected,
    required this.onEdit,
    required this.onCreate,
  });

  final List<ChatFolderModel> folders;
  final String? selectedId;
  final String personalId;
  final ValueChanged<String?> onSelected;
  final ValueChanged<ChatFolderModel> onEdit;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final labels = ChatLabels.of(context);
    final theme = Theme.of(context);
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.35),
            width: 0.8,
          ),
        ),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          _chip(context, labels.folderAll, null),
          _chip(context, labels.folderPersonal, personalId),
          for (final folder in folders)
            _chip(context, folder.name, folder.id, folder: folder),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: IconButton(
              key: const ValueKey('folder-add'),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              tooltip: labels.newFolder,
              icon: const Icon(Icons.add_rounded),
              onPressed: onCreate,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String label,
    String? id, {
    ChatFolderModel? folder,
  }) {
    final selected = selectedId == id;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: GestureDetector(
        onLongPress: folder == null ? null : () => onEdit(folder),
        child: ChoiceChip(
          label: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? (isDark ? const Color(0xFF64B5F6) : primary)
                  : theme.textTheme.bodyMedium?.color,
            ),
          ),
          selected: selected,
          onSelected: (_) => onSelected(id),
          selectedColor: isDark
              ? primary.withValues(alpha: 0.22)
              : primary.withValues(alpha: 0.12),
          side: BorderSide(
            color: selected
                ? primary.withValues(alpha: 0.6)
                : theme.dividerColor.withValues(alpha: 0.35),
            width: selected ? 1.2 : 0.8,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({
    required this.state,
    required this.labels,
    required this.onTap,
  });

  final ChatListState state;
  final ChatLabels labels;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const ValueKey('archive-row'),
      onTap: onTap,
      leading: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [
              Colors.blueGrey.shade400,
              Colors.blueGrey.shade600,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Icon(
          state.hasArchivePin ? Icons.lock_outline_rounded : Icons.archive_outlined,
          color: Colors.white,
          size: 24,
        ),
      ),
      title: Text(
        labels.archivedChats,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
      subtitle: Text('${state.archivedTotal}'),
      trailing: state.archivedUnread > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                state.archivedUnread > 99 ? '99+' : '${state.archivedUnread}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _SecurityAlertBanner extends ConsumerStatefulWidget {
  const _SecurityAlertBanner();

  @override
  ConsumerState<_SecurityAlertBanner> createState() =>
      _SecurityAlertBannerState();
}

class _SecurityAlertBannerState extends ConsumerState<_SecurityAlertBanner> {
  static const Duration _pollInterval = Duration(seconds: 20);

  Map<String, dynamic>? _alert;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(_pollInterval, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final api = ref.read(authenticatedSessionProvider).api;
      final response = await api.get('/security/alerts',
          query: {'unread': '1', 'limit': '1'});
      if (!mounted) return;
      final alerts = response['alerts'] as List? ?? const [];
      setState(() {
        _alert = alerts.isEmpty
            ? null
            : Map<String, dynamic>.from(alerts.first as Map);
      });
    } catch (_) {}
  }

  Future<void> _dismiss() async {
    final alert = _alert;
    if (alert == null || _busy) return;
    setState(() {
      _busy = true;
      _alert = null;
    });
    try {
      final api = ref.read(authenticatedSessionProvider).api;
      await api.post('/security/alerts/${alert['id']}/dismiss', {});
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openDevices() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DeviceManagementScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alert = _alert;
    if (alert == null) return const SizedBox.shrink();

    final critical = alert['severity'] == 'critical';
    final accent = critical ? Colors.red : Colors.orange;
    final rawTitle = (alert['title'] as String?)?.trim();
    final rawBody = (alert['body'] as String?)?.trim();
    final title = rawTitle == null
        ? (AppLocale.isFa ? 'هشدار امنیتی حساب' : 'Account security alert')
        : SecurityMessageLocalizer.localize(rawTitle, isFa: AppLocale.isFa);
    final body = rawBody == null
        ? null
        : SecurityMessageLocalizer.localize(rawBody, isFa: AppLocale.isFa);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      key: const ValueKey('security-alert-banner'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _openDevices,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    critical ? Icons.gpp_maybe : Icons.security,
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title?.isNotEmpty == true
                            ? title!
                            : AppLocale.pick('رویداد امنیتی در حساب شما', 'Account security alert'),
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? accent.shade200 : accent.shade900,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (body?.isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          body!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        AppLocale.pick('برای مدیریت دستگاه‌ها ضربه بزنید', 'Tap to manage devices'),
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: isDark ? accent.shade300 : accent.shade700),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: AppLocale.pick('بستن', 'Dismiss'),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: _busy ? null : _dismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SponsoredStrip extends StatefulWidget {
  const _SponsoredStrip();
  @override
  State<_SponsoredStrip> createState() => _SponsoredStripState();
}

class _SponsoredStripState extends State<_SponsoredStrip> {
  List<ChatModel> _channels = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiService().get('/chats/sponsored');
      if (!mounted) return;
      final list = (res['channels'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatModel.fromJson)
          .toList();
      setState(() => _channels = list);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => SponsoredBanner(channels: _channels);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.isFa,
    required this.inFolder,
    this.searching = false,
  });

  final bool isFa;
  final bool inFolder;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final labels = ChatLabels.of(context);
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              searching
                  ? Icons.search_off_rounded
                  : inFolder
                      ? Icons.folder_open_rounded
                      : Icons.chat_bubble_outline_rounded,
              size: 56,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            searching
                ? (isFa ? 'چتی پیدا نشد' : 'No chats found')
                : inFolder
                    ? labels.folderEmpty
                    : (isFa ? 'هنوز گفتگویی ندارید' : 'No conversations yet'),
            style: TextStyle(
              color: theme.textTheme.titleLarge?.color,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              searching
                  ? (isFa
                        ? 'جستجوی سراسری را برای یافتن کاربر یا کانال جدید امتحان کنید'
                        : 'Try global search to find new users or channels')
                  : isFa
                      ? 'از تب جستجو کاربر پیدا کنید'
                      : 'Find users from the Search tab',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textTheme.bodySmall?.color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
