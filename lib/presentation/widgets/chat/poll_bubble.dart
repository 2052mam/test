import 'package:flutter/material.dart';

import '../../../data/models/poll_model.dart';

/// Telegram-style poll / quiz card rendered inside a message bubble.
/// Redesigned with fluid progress animations, rounded option cards,
/// and clear visual hierarchy.
class PollBubble extends StatelessWidget {
  const PollBubble({
    super.key,
    required this.poll,
    required this.isMine,
    required this.foreground,
    this.onVote,
    this.onRetract,
    this.onClose,
    this.onShowVoters,
    this.busy = false,
  });

  final PollModel poll;
  final bool isMine;
  final Color foreground;

  /// Called with the tapped option id.
  final ValueChanged<String>? onVote;
  final VoidCallback? onRetract;
  final VoidCallback? onClose;
  final VoidCallback? onShowVoters;
  final bool busy;

  String _subtitle(bool isFa) {
    if (poll.isClosed) {
      return poll.isQuiz
          ? (isFa ? 'آزمون بسته شد' : 'Quiz closed')
          : (isFa ? 'نظرسنجی بسته شد' : 'Poll closed');
    }
    if (poll.isQuiz) return isFa ? 'آزمون' : 'Quiz';
    if (poll.allowsMultipleAnswers) {
      return poll.isAnonymous
          ? (isFa ? 'نظرسنجی ناشناس · چند گزینه‌ای' : 'Anonymous · multiple answers')
          : (isFa ? 'نظرسنجی عمومی · چند گزینه‌ای' : 'Public · multiple answers');
    }
    return poll.isAnonymous
        ? (isFa ? 'نظرسنجی ناشناس' : 'Anonymous poll')
        : (isFa ? 'نظرسنجی عمومی' : 'Public poll');
  }

  String _votesLabel(bool isFa) {
    if (poll.totalVoters == 0) {
      return poll.isQuiz
          ? (isFa ? 'هنوز کسی پاسخ نداده' : 'No answers yet')
          : (isFa ? 'هنوز کسی رأی نداده' : 'No votes yet');
    }
    return poll.isQuiz
        ? (isFa ? '${poll.totalVoters} پاسخ' : '${poll.totalVoters} answers')
        : (isFa ? '${poll.totalVoters} رأی' : '${poll.totalVoters} votes');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final accent = isMine ? Colors.white : theme.colorScheme.primary;
    final muted = foreground.withValues(alpha: 0.72);
    final showResults = poll.showsResults;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  poll.question,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    height: 1.32,
                  ),
                ),
              ),
              if (poll.isQuiz)
                Container(
                  margin: const EdgeInsetsDirectional.only(start: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isFa ? 'آزمون' : 'Quiz',
                    style: const TextStyle(
                      color: Color(0xFF8B5CF6),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            _subtitle(isFa),
            style: TextStyle(color: muted, fontSize: 11.5),
          ),
          const SizedBox(height: 12),
          for (final option in poll.options)
            _PollOptionRow(
              key: ValueKey('poll-option-${option.id}'),
              option: option,
              poll: poll,
              accent: accent,
              foreground: foreground,
              showResults: showResults,
              enabled: !busy && !poll.isClosed && onVote != null,
              isFa: isFa,
              onTap: () => onVote?.call(option.id),
            ),
          const SizedBox(height: 6),
          if (poll.isQuiz && poll.hasVoted && poll.explanation?.isNotEmpty == true)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_rounded, size: 16, color: Color(0xFFF59E0B)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      poll.explanation!,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              if (busy)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
                )
              else
                Text(
                  _votesLabel(isFa),
                  style: TextStyle(color: muted, fontSize: 11.5, fontWeight: FontWeight.w500),
                ),
              const Spacer(),
              if (!poll.isAnonymous && poll.totalVoters > 0 && onShowVoters != null)
                _PollAction(
                  key: const ValueKey('poll-voters'),
                  label: isFa ? 'رأی‌دهندگان' : 'Voters',
                  color: accent,
                  onTap: busy ? null : onShowVoters,
                ),
              if (poll.canRetract && onRetract != null)
                _PollAction(
                  key: const ValueKey('poll-retract'),
                  label: isFa ? 'حذف رأی' : 'Retract vote',
                  color: accent,
                  onTap: busy ? null : onRetract,
                ),
              if (poll.canClose && onClose != null)
                _PollAction(
                  key: const ValueKey('poll-close'),
                  label: isFa ? 'بستن' : 'Close',
                  color: accent,
                  onTap: busy ? null : onClose,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PollOptionRow extends StatelessWidget {
  const _PollOptionRow({
    super.key,
    required this.option,
    required this.poll,
    required this.accent,
    required this.foreground,
    required this.showResults,
    required this.enabled,
    required this.isFa,
    required this.onTap,
  });

  final PollOptionModel option;
  final PollModel poll;
  final Color accent;
  final Color foreground;
  final bool showResults;
  final bool enabled;
  final bool isFa;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final correct = option.isCorrect == true;
    final wrongChoice = poll.isQuiz && option.chosen && option.isCorrect == false;
    final barColor = correct
        ? const Color(0xFF10B981)
        : wrongChoice
            ? const Color(0xFFEF4444)
            : accent;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: option.chosen
                ? barColor.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _Marker(
                    chosen: option.chosen,
                    correct: correct,
                    wrong: wrongChoice,
                    multiple: poll.allowsMultipleAnswers,
                    color: barColor,
                    foreground: foreground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      option.text,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14.5,
                        fontWeight:
                            option.chosen ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (showResults)
                    Text(
                      '${option.percent}${isFa ? '٪' : '%'}',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.85),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              if (showResults) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (option.percent / 100).clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: foreground.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({
    required this.chosen,
    required this.correct,
    required this.wrong,
    required this.multiple,
    required this.color,
    required this.foreground,
  });

  final bool chosen;
  final bool correct;
  final bool wrong;
  final bool multiple;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    if (correct) {
      return Icon(Icons.check_circle_rounded, size: 20, color: color);
    }
    if (wrong) {
      return Icon(Icons.cancel_rounded, size: 20, color: color);
    }
    if (chosen) {
      return Icon(
        multiple ? Icons.check_box_rounded : Icons.radio_button_checked_rounded,
        size: 20,
        color: color,
      );
    }
    return Icon(
      multiple ? Icons.check_box_outline_blank_rounded : Icons.radio_button_unchecked_rounded,
      size: 20,
      color: foreground.withValues(alpha: 0.55),
    );
  }
}

class _PollAction extends StatelessWidget {
  const _PollAction({super.key, required this.label, required this.color, this.onTap});

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              color: onTap == null ? color.withValues(alpha: 0.5) : color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
