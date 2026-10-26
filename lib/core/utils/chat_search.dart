import '../../data/models/chat_model.dart';

/// Chat-list search (Item 4).
///
/// The previous list only matched what happened to be rendered, so groups and
/// channels were routinely "missing" for people who belong to many of them.
/// Matching now covers every chat the user is a member of — group and channel
/// titles, @usernames, the other person's name/@id in a private chat, and the
/// last message snippet — and is diacritic/Arabic-Persian tolerant so that
/// "کارگروه" finds "كارگروه" too.
String normalizeSearchText(String value) {
  const arabicToPersian = {
    'ي': 'ی',
    'ك': 'ک',
    'ۀ': 'ه',
    'ة': 'ه',
    'أ': 'ا',
    'إ': 'ا',
    'آ': 'ا',
    'ؤ': 'و',
    'ئ': 'ی',
  };
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    // Strip Arabic diacritics, ZWNJ and tatweel: they are invisible noise.
    if (rune >= 0x064B && rune <= 0x0652) continue;
    if (rune == 0x0640 || rune == 0x200C || rune == 0x200F || rune == 0x200E) {
      continue;
    }
    buffer.write(arabicToPersian[char] ?? char);
  }
  // Persian/Arabic-Indic digits normalize to ASCII so "گروه ۲" matches "گروه 2".
  var result = buffer.toString();
  const digits = {
    '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4',
    '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
    '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4',
    '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
  };
  digits.forEach((from, to) => result = result.replaceAll(from, to));
  return result.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// True when [chat] matches the already normalized [query].
bool chatMatchesQuery(ChatModel chat, String normalizedQuery) {
  if (normalizedQuery.isEmpty) return true;
  final haystack = <String?>[
    chat.displayTitle,
    chat.title,
    chat.username,
    chat.otherUser?.displayName,
    chat.otherUser?.username,
    chat.lastMessage?.content,
  ];
  for (final candidate in haystack) {
    if (candidate == null || candidate.isEmpty) continue;
    if (normalizeSearchText(candidate).contains(normalizedQuery)) return true;
  }
  return false;
}

/// Filter a chat list, keeping the caller's ordering (pinned first, etc.).
List<ChatModel> filterChats(List<ChatModel> chats, String query) {
  final normalized = normalizeSearchText(query);
  if (normalized.isEmpty) return chats;
  return chats.where((chat) => chatMatchesQuery(chat, normalized)).toList();
}
