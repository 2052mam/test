import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/models/message_model.dart';
import 'package:secure_messenger/data/models/poll_model.dart';

Map<String, dynamic> pollJson({
  bool quiz = false,
  bool closed = false,
  bool voted = false,
}) => {
  'id': 'poll-1',
  'question': 'Best editor?',
  'poll_type': quiz ? 'quiz' : 'regular',
  'is_anonymous': true,
  'allows_multiple_answers': false,
  'is_closed': closed,
  'total_voters': voted ? 1 : 0,
  'has_voted': voted,
  'my_option_ids': voted ? ['o1'] : <String>[],
  'correct_option_id': quiz && voted ? 'o2' : null,
  'is_correct': quiz && voted ? false : null,
  'can_close': true,
  'options': [
    {'id': 'o1', 'text': 'Vim', 'voter_count': voted ? 1 : 0, 'percent': voted ? 100 : 0, 'chosen': voted},
    {'id': 'o2', 'text': 'Emacs', 'voter_count': 0, 'percent': 0, 'chosen': false},
  ],
};

void main() {
  test('Parses a regular poll and always shows its running tally', () {
    final poll = PollModel.fromJson(pollJson());
    expect(poll.question, 'Best editor?');
    expect(poll.options.map((o) => o.text), ['Vim', 'Emacs']);
    expect(poll.isQuiz, isFalse);
    expect(poll.showsResults, isTrue);
    expect(poll.canRetract, isFalse);
  });

  test('A voted regular poll can be retracted, a quiz cannot', () {
    expect(PollModel.fromJson(pollJson(voted: true)).canRetract, isTrue);
    expect(PollModel.fromJson(pollJson(quiz: true, voted: true)).canRetract, isFalse);
  });

  test('Quiz results stay hidden until the viewer answers', () {
    final unanswered = PollModel.fromJson(pollJson(quiz: true));
    expect(unanswered.showsResults, isFalse);
    expect(unanswered.correctOptionId, isNull);

    final answered = PollModel.fromJson(pollJson(quiz: true, voted: true));
    expect(answered.showsResults, isTrue);
    expect(answered.correctOptionId, 'o2');
    expect(answered.isCorrect, isFalse);
  });

  test('A closed quiz reveals results even without answering', () {
    final closed = PollModel.fromJson(pollJson(quiz: true, closed: true));
    expect(closed.showsResults, isTrue);
    expect(closed.canRetract, isFalse);
  });

  test('A poll message carries its poll payload', () {
    final message = MessageModel.fromJson({
      'id': 'm1',
      'chat_id': 'chat',
      'sender_id': 'alice',
      'message_type': 'poll',
      'content': 'Best editor?',
      'created_at': '2026-09-07T12:00:00',
      'poll_id': 'poll-1',
      'poll': pollJson(),
    });
    expect(message.isPoll, isTrue);
    expect(message.pollId, 'poll-1');
    expect(message.poll!.options.length, 2);
  });

  test('A message without a poll payload is not a poll', () {
    final message = MessageModel.fromJson({
      'id': 'm2',
      'chat_id': 'chat',
      'sender_id': 'alice',
      'message_type': 'text',
      'content': 'hello',
      'created_at': '2026-09-07T12:00:00',
    });
    expect(message.isPoll, isFalse);
    expect(message.poll, isNull);
  });

  test('copyWith replaces the poll while keeping the rest of the message', () {
    final message = MessageModel.fromJson({
      'id': 'm1',
      'chat_id': 'chat',
      'sender_id': 'alice',
      'message_type': 'poll',
      'content': 'Best editor?',
      'created_at': '2026-09-07T12:00:00',
      'poll_id': 'poll-1',
      'poll': pollJson(),
    });
    final voted = message.copyWith(poll: PollModel.fromJson(pollJson(voted: true)));
    expect(voted.poll!.hasVoted, isTrue);
    expect(voted.id, message.id);
    expect(voted.content, message.content);
  });
}
