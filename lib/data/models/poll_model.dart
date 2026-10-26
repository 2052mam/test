import 'package:equatable/equatable.dart';

import '../../core/utils/api_datetime.dart';

/// One answer option of a poll / quiz (Telegram parity).
class PollOptionModel extends Equatable {
  const PollOptionModel({
    required this.id,
    required this.text,
    this.position = 0,
    this.voterCount = 0,
    this.percent = 0,
    this.chosen = false,
    this.isCorrect,
    this.voters = const [],
  });

  final String id;
  final String text;
  final int position;
  final int voterCount;
  final int percent;
  final bool chosen;

  /// Quiz only, and only once the viewer answered or the quiz closed.
  final bool? isCorrect;

  /// Non-anonymous polls expose a short preview of who voted.
  final List<PollVoterModel> voters;

  factory PollOptionModel.fromJson(Map<String, dynamic> json) =>
      PollOptionModel(
        id: json['id'] as String,
        text: json['text'] as String? ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        voterCount: (json['voter_count'] as num?)?.toInt() ?? 0,
        percent: (json['percent'] as num?)?.toInt() ?? 0,
        chosen: json['chosen'] as bool? ?? false,
        isCorrect: json['is_correct'] as bool?,
        voters: (json['voters'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PollVoterModel.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'position': position,
        'voter_count': voterCount,
        'percent': percent,
        'chosen': chosen,
        'is_correct': isCorrect,
        'voters': voters.map((v) => v.toJson()).toList(),
      };

  @override
  List<Object?> get props =>
      [id, text, position, voterCount, percent, chosen, isCorrect, voters];
}

class PollVoterModel extends Equatable {
  const PollVoterModel({required this.id, required this.displayName, this.avatarUrl});

  final String id;
  final String displayName;
  final String? avatarUrl;

  factory PollVoterModel.fromJson(Map<String, dynamic> json) => PollVoterModel(
        id: json['id'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        avatarUrl: json['avatar_url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'display_name': displayName,
        'avatar_url': avatarUrl,
      };

  @override
  List<Object?> get props => [id, displayName, avatarUrl];
}

/// A Telegram-style poll or quiz attached to a message.
class PollModel extends Equatable {
  const PollModel({
    required this.id,
    required this.question,
    required this.options,
    this.pollType = 'regular',
    this.isAnonymous = true,
    this.allowsMultipleAnswers = false,
    this.explanation,
    this.isClosed = false,
    this.closeAt,
    this.totalVoters = 0,
    this.hasVoted = false,
    this.myOptionIds = const [],
    this.correctOptionId,
    this.isCorrect,
    this.canClose = false,
  });

  final String id;
  final String question;
  final List<PollOptionModel> options;
  final String pollType; // regular | quiz
  final bool isAnonymous;
  final bool allowsMultipleAnswers;
  final String? explanation;
  final bool isClosed;
  final DateTime? closeAt;
  final int totalVoters;
  final bool hasVoted;
  final List<String> myOptionIds;
  final String? correctOptionId;
  final bool? isCorrect;
  final bool canClose;

  bool get isQuiz => pollType == 'quiz';

  /// Results are visible once the viewer answered, or the poll is closed.
  /// A regular poll always shows the running tally, exactly like Telegram.
  bool get showsResults => isClosed || hasVoted || !isQuiz;

  /// A quiz answer is final; a regular poll can be retracted while it is open.
  bool get canRetract => !isQuiz && !isClosed && hasVoted;

  factory PollModel.fromJson(Map<String, dynamic> json) => PollModel(
        id: json['id'] as String,
        question: json['question'] as String? ?? '',
        options: (json['options'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PollOptionModel.fromJson)
            .toList(),
        pollType: json['poll_type'] as String? ??
            ((json['is_quiz'] as bool? ?? false) ? 'quiz' : 'regular'),
        isAnonymous: json['is_anonymous'] as bool? ?? true,
        allowsMultipleAnswers: json['allows_multiple_answers'] as bool? ?? false,
        explanation: json['explanation'] as String?,
        isClosed: json['is_closed'] as bool? ?? false,
        closeAt: parseApiDateTime(json['close_at'] as String?),
        totalVoters: (json['total_voters'] as num?)?.toInt() ?? 0,
        hasVoted: json['has_voted'] as bool? ?? false,
        myOptionIds: (json['my_option_ids'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        correctOptionId: json['correct_option_id'] as String?,
        isCorrect: json['is_correct'] as bool?,
        canClose: json['can_close'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'options': options.map((o) => o.toJson()).toList(),
        'poll_type': pollType,
        'is_anonymous': isAnonymous,
        'allows_multiple_answers': allowsMultipleAnswers,
        'explanation': explanation,
        'is_closed': isClosed,
        'close_at': closeAt?.toUtc().toIso8601String(),
        'total_voters': totalVoters,
        'has_voted': hasVoted,
        'my_option_ids': myOptionIds,
        'correct_option_id': correctOptionId,
        'is_correct': isCorrect,
        'can_close': canClose,
      };

  @override
  List<Object?> get props => [
        id,
        question,
        options,
        pollType,
        isAnonymous,
        allowsMultipleAnswers,
        explanation,
        isClosed,
        closeAt,
        totalVoters,
        hasVoted,
        myOptionIds,
        correctOptionId,
        isCorrect,
        canClose,
      ];
}
