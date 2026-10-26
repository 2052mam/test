import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/core/utils/chat_search.dart';
import 'package:secure_messenger/data/models/chat_model.dart';
import 'package:secure_messenger/data/models/user_model.dart';

ChatModel chat({
  required String id,
  String chatType = 'group',
  String? title,
  String? username,
  UserModel? otherUser,
  String? lastMessage,
}) => ChatModel(
  id: id,
  chatType: chatType,
  title: title,
  username: username,
  otherUser: otherUser,
  lastMessage: lastMessage == null
      ? null
      : LastMessageModel(content: lastMessage, messageType: 'text'),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final chats = [
    chat(id: 'g1', title: 'Flutter Developers', username: 'flutterdev'),
    chat(id: 'g2', title: 'گروه برنامه‌نویسان'),
    chat(id: 'c1', chatType: 'channel', title: 'اخبار فناوری'),
    chat(
      id: 'p1',
      chatType: 'private',
      otherUser: const UserModel(
        id: 'bob',
        email: 'bob@example.test',
        username: 'bobby',
        displayName: 'Bob Smith',
      ),
    ),
    chat(id: 'g3', title: 'Design Team', lastMessage: 'new mockups are ready'),
  ];

  List<String> ids(String query) =>
      filterChats(chats, query).map((c) => c.id).toList();

  test('An empty query keeps the whole list', () {
    expect(filterChats(chats, '   ').length, chats.length);
  });

  test('Groups and channels are found by title, not just private chats', () {
    expect(ids('flutter'), ['g1']);
    expect(ids('اخبار'), ['c1']);
    expect(ids('برنامه'), ['g2']);
  });

  test('Chats are found by @username', () {
    expect(ids('flutterdev'), ['g1']);
    expect(ids('bobby'), ['p1']);
  });

  test('Private chats match the other person display name', () {
    expect(ids('bob smith'), ['p1']);
  });

  test('The last message snippet is searchable like in Telegram', () {
    expect(ids('mockups'), ['g3']);
  });

  test('Arabic/Persian letter and digit variants match each other', () {
    final list = [chat(id: 'k', title: 'كارگروه ۲')];
    expect(filterChats(list, 'کارگروه').single.id, 'k');
    expect(filterChats(list, 'کارگروه 2').single.id, 'k');
  });

  test('Diacritics and zero width joiners never break a match', () {
    final list = [chat(id: 'z', title: 'برنامه‌نویسی')];
    expect(filterChats(list, 'برنامه نویسی').isEmpty, isTrue);
    expect(filterChats(list, 'برنامهنویسی').single.id, 'z');
  });

  test('Search is case insensitive and matches partial words', () {
    expect(ids('DEVELOP'), ['g1']);
    expect(ids('team'), ['g3']);
  });

  test('A query that matches nothing returns an empty list', () {
    expect(ids('nonexistent-chat'), isEmpty);
  });
}
