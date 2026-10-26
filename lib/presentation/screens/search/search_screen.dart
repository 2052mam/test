import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';

import '../../../data/models/search_history_model.dart';
import '../../../data/models/user_model.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/chat_navigation.dart';
import '../../../data/services/storage_service.dart';
import '../../widgets/chat/chat_avatar.dart';
import '../../widgets/chat/chat_labels.dart';
import '../../providers/locale_provider.dart';
import '../chat/chat_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  List<UserModel> _users = [];
  List<Map<String, dynamic>> _channels = [];
  List<SearchHistoryItem> _history = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  bool get _hasQuery => _ctrl.text.trim().length >= 2;

  Future<void> _loadHistory() async {
    try {
      final res = await ApiService().get('/users/search-history');
      if (!mounted) return;
      setState(() => _history = SearchHistoryItem.listFrom(res));
    } catch (_) {}
  }

  Future<void> _remember({
    String? query,
    String? userId,
    String? chatId,
  }) async {
    try {
      await ApiService().post('/users/search-history', {
        if (query != null && query.isNotEmpty) 'query': query,
        if (userId != null) 'user_id': userId,
        if (chatId != null) 'chat_id': chatId,
      });
      await _loadHistory();
    } catch (_) {}
  }

  Future<void> _removeHistory(SearchHistoryItem item) async {
    setState(() => _history = [..._history]..remove(item));
    try {
      await ApiService().post('/users/search-history/${item.id}/delete', {});
    } catch (_) {}
    await _loadHistory();
  }

  Future<void> _clearHistory() async {
    setState(() => _history = []);
    try {
      await ApiService().post('/users/search-history/clear', {});
    } catch (_) {}
    await _loadHistory();
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      setState(() {
        _users = [];
        _channels = [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiService().get(
        '/users/search',
        query: {'q': q.trim()},
      );
      final list = (res['users'] as List? ?? [])
          .map((e) => UserModel.fromJson(e as Map<String, dynamic>))
          .toList();
      final chans = (res['chats'] as List? ?? [])
          .map((e) => e as Map<String, dynamic>)
          .toList();
      if (!mounted) return;
      setState(() {
        _users = list;
        _channels = chans;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _startChat(UserModel user, {bool remember = true}) async {
    try {
      final res = await ApiService().post('/chats/private', {
        'user_id': user.id,
      });
      if (remember) {
        unawaited(_remember(query: _ctrl.text.trim(), userId: user.id));
      }
      if (!mounted) return;
      unawaited(ChatNavigation.open(
        context,
        chatId: res['chat_id'] as String,
        builder: (_) => ChatScreen(
          chatId: res['chat_id'] as String,
          title: user.displayName,
          chatType: 'private',
          otherUser: user,
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _joinChannel(Map<String, dynamic> ch) async {
    try {
      final chatId = ch['id'] as String;
      final title = ch['title'] as String? ?? '';
      final chatType = ch['chat_type'] as String? ?? 'channel';
      if (ch['is_member'] != true) {
        await ApiService().post('/chats/$chatId/add-member', {
          'user_id': (await ApiService().get('/users/me'))['id'],
        });
      }
      await _remember(query: _ctrl.text.trim(), chatId: chatId);
      if (!mounted) return;
      unawaited(ChatNavigation.open(
        context,
        chatId: chatId,
        builder: (_) =>
            ChatScreen(chatId: chatId, title: title, chatType: chatType),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openHistoryItem(SearchHistoryItem item) async {
    final user = item.user;
    if (user != null) {
      await _startChat(user, remember: false);
      unawaited(_remember(query: item.query, userId: user.id));
      return;
    }
    final chat = item.chat;
    if (chat != null) {
      await _joinChannel({
        'id': chat.id,
        'title': chat.title,
        'username': chat.username,
        'chat_type': chat.chatType,
        'is_member': true,
      });
      return;
    }
    final query = item.query;
    if (query != null && query.isNotEmpty) {
      _ctrl.text = query;
      _ctrl.selection = TextSelection.collapsed(offset: query.length);
      await _search(query);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isFa = ref.watch(localeProvider).languageCode == 'fa';
    final labels = ChatLabels.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final showHistory = !_hasQuery && _history.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(isFa ? 'جستجو' : 'Search', style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: TextField(
                controller: _ctrl,
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                ),
                onChanged: (q) {
                  setState(() {});
                  _search(q);
                },
                onSubmitted: (q) {
                  if (q.trim().length >= 2) _remember(query: q.trim());
                },
                decoration: InputDecoration(
                  hintText: isFa
                      ? 'جستجو کاربر یا کانال...'
                      : 'Search user or channel...',
                  hintStyle: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8),
                  ),
                  prefixIcon: Icon(Icons.search_rounded, color: primary),
                  suffixIcon: _ctrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _ctrl.clear();
                            _search('');
                            setState(() {});
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            if (_loading)
              LinearProgressIndicator(
                minHeight: 2.5,
                backgroundColor: primary.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(primary),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  if (showHistory) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              labels.recentSearches,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('clear-search-history'),
                            onPressed: _clearHistory,
                            child: Text(labels.clearAll, style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                    ..._history.map(
                      (item) => ListTile(
                        key: ValueKey('history-${item.id}'),
                        leading: item.user != null
                            ? ChatAvatar(
                                title: item.user!.displayName,
                                url: item.user!.showProfilePhoto
                                    ? item.user!.avatarUrl
                                    : null,
                                token: StorageService.getToken(),
                                radius: 22,
                              )
                            : Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: primary.withValues(alpha: 0.12),
                                ),
                                child: Icon(
                                  item.chat != null
                                      ? Icons.campaign_rounded
                                      : Icons.history_rounded,
                                  color: primary,
                                  size: 22,
                                ),
                              ),
                        title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: item.subtitle == null
                            ? null
                            : Text(item.subtitle!),
                        trailing: IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () => _removeHistory(item),
                        ),
                        onTap: () => _openHistoryItem(item),
                      ),
                    ),
                    Divider(color: theme.dividerColor.withValues(alpha: 0.35), height: 20),
                  ],
                  if (_users.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        isFa ? 'کاربران' : 'Users',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                    ..._users.map(
                      (u) => ListTile(
                        leading: ChatAvatar(
                          title: u.displayName,
                          url: u.avatarUrl,
                          token: StorageService.getToken(),
                          radius: 24,
                        ),
                        title: Text(u.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(u.handle, style: TextStyle(color: theme.textTheme.bodySmall?.color)),
                        trailing: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.chat_bubble_outline_rounded, color: primary, size: 18),
                        ),
                        onTap: () => _startChat(u),
                      ),
                    ),
                  ],
                  if (_channels.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        isFa ? 'گروه‌ها و کانال‌ها' : 'Groups & Channels',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                    ..._channels.map(
                      (ch) => ListTile(
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: ch['chat_type'] == 'group'
                                  ? [Colors.blueGrey.shade400, Colors.blueGrey.shade700]
                                  : [primary, const Color(0xFF00ACC1)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Icon(
                            ch['chat_type'] == 'group'
                                ? Icons.groups_rounded
                                : Icons.campaign_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        title: Text(ch['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: ch['username'] != null
                            ? Text('@${ch['username']}')
                            : null,
                        trailing: ch['is_member'] == true
                            ? const Icon(Icons.arrow_forward_ios_rounded, size: 16)
                            : Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: primary,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  isFa ? 'عضو شدن' : 'Join',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                        onTap: () => _joinChannel(ch),
                      ),
                    ),
                  ],
                  if (_users.isEmpty &&
                      _channels.isEmpty &&
                      !_loading &&
                      !showHistory)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: primary.withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.search_rounded, size: 48, color: primary),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              isFa
                                  ? 'حداقل ۲ کاراکتر وارد کنید'
                                  : 'Enter at least 2 characters',
                              style: TextStyle(
                                color: theme.textTheme.bodyMedium?.color,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
