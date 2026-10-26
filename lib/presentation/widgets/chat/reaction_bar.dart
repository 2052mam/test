import 'package:flutter/material.dart';
import '../../../data/models/reaction_model.dart';

class ReactionBar extends StatelessWidget {
  final List<ReactionModel> reactions;
  final bool isMine;
  final ValueChanged<String>? onReactionTap;
  final VoidCallback? onAddReaction;

  const ReactionBar({
    super.key,
    required this.reactions,
    this.isMine = false,
    this.onReactionTap,
    this.onAddReaction,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 5,
        runSpacing: 5,
        children: [
          ...reactions.map((r) => GestureDetector(
                onTap: () => onReactionTap?.call(r.emoji),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: isMine
                        ? (r.me
                            ? Colors.white.withValues(alpha: 0.32)
                            : Colors.white.withValues(alpha: 0.18))
                        : (r.me
                            ? (isDark
                                ? const Color(0xFF2563EB).withValues(alpha: 0.4)
                                : const Color(0xFFE0F2FE))
                            : (isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : const Color(0xFFF1F5F9))),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isMine
                          ? (r.me ? Colors.white : Colors.white24)
                          : (r.me
                              ? (isDark ? const Color(0xFF60A5FA) : const Color(0xFF0284C7))
                              : (isDark ? Colors.transparent : const Color(0xFFE2E8F0))),
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(r.emoji, style: const TextStyle(fontSize: 13.5)),
                      const SizedBox(width: 4),
                      Text(
                        '${r.count}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isMine
                              ? Colors.white
                              : (r.me
                                  ? (isDark ? const Color(0xFF93C5FD) : const Color(0xFF0369A1))
                                  : (isDark ? Colors.white70 : const Color(0xFF0F172A))),
                          fontWeight: (r.me || isMine) ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              )),
          if (onAddReaction != null)
            GestureDetector(
              onTap: onAddReaction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                decoration: BoxDecoration(
                  color: isMine
                      ? Colors.white.withValues(alpha: 0.18)
                      : (isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : const Color(0xFFF1F5F9)),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isMine
                        ? Colors.white24
                        : (isDark ? Colors.transparent : const Color(0xFFE2E8F0)),
                  ),
                ),
                child: Icon(
                  Icons.add_reaction_outlined,
                  size: 16,
                  color: isMine
                      ? Colors.white70
                      : (isDark ? Colors.white60 : const Color(0xFF64748B)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class QuickReactionSheet extends StatelessWidget {
  const QuickReactionSheet({super.key});

  static const quickEmojis = [
    '❤️', '👍', '🔥', '😂', '😮', '😢',
    '🙏', '👏', '🎉', '🤔', '🥰', '😍',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            ...quickEmojis.map((e) => InkWell(
                  onTap: () => Navigator.pop(context, e),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: 58,
                    height: 58,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF242F3D)
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.05),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 29)),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
