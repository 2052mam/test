import 'package:flutter/material.dart';
import '../../../core/utils/media_utils.dart';
import '../../../data/services/music_player_service.dart';
import '../../screens/music/music_player_screen.dart';

/// Telegram-like collapsed mini player shown above the bottom navigation
/// and at the bottom of chat screens while music plays.
/// Redesigned with glassmorphic floating capsule styling, glowing accents,
/// and smooth playhead indicator.
class MiniMusicPlayer extends StatelessWidget {
  const MiniMusicPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MusicPlayerState>(
      stream: MusicPlayerService().stream,
      initialData: MusicPlayerService().state,
      builder: (context, snap) {
        final st = snap.data ?? MusicPlayerService().state;
        final track = st.current;
        if (track == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final primary = theme.colorScheme.primary;

        final progress = st.duration.inMilliseconds > 0
            ? (st.position.inMilliseconds / st.duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;

        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MusicPlayerScreen()),
          ),
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2C3A) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
              border: Border.all(
                color: isDark
                    ? const Color(0xFF27384A)
                    : primary.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    child: Row(
                      children: [
                        // Animated music artwork avatar
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                primary,
                                const Color(0xFF00ACC1),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withValues(alpha: 0.3),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.music_note_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                track.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                  letterSpacing: -0.1,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track.artist.isNotEmpty
                                    ? '${track.artist} • ${formatMediaDuration(st.position)} / ${formatMediaDuration(st.duration)}'
                                    : '${formatMediaDuration(st.position)} / ${formatMediaDuration(st.duration)}',
                                style: TextStyle(
                                  color: theme.textTheme.bodySmall?.color,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w400,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textDirection: TextDirection.ltr,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            st.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 26,
                          ),
                          color: primary,
                          onPressed: () => MusicPlayerService().toggle(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded, size: 24),
                          color: theme.textTheme.bodySmall?.color,
                          onPressed: st.queue.length > 1 ? () => MusicPlayerService().next() : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 20),
                          color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                          onPressed: () => MusicPlayerService().close(),
                        ),
                      ],
                    ),
                  ),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 2.5,
                    backgroundColor: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : const Color(0xFFE2E8F0),
                    valueColor: AlwaysStoppedAnimation<Color>(primary),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
