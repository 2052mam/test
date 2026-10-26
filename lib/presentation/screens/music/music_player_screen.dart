import 'package:flutter/material.dart';
import '../../../core/utils/app_locale.dart';
import '../../../core/utils/media_utils.dart';
import '../../../data/services/music_player_service.dart';

/// Telegram-like full music player: artwork, title/artist, seek bar,
/// play/pause/next/prev, speed, repeat, shuffle, queue list.
/// Redesigned with glowing vinyl artwork, glassmorphic controls, and fluid queue.
class MusicPlayerScreen extends StatelessWidget {
  const MusicPlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocale.pick('پخش‌کننده موسیقی', 'Music player'), style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          StreamBuilder<MusicPlayerState>(
            stream: MusicPlayerService().stream,
            initialData: MusicPlayerService().state,
            builder: (context, snap) {
              return IconButton(
                tooltip: AppLocale.pick('بستن پخش', 'Close player'),
                icon: const Icon(Icons.close_rounded),
                onPressed: () async {
                  await MusicPlayerService().close();
                  if (context.mounted) Navigator.pop(context);
                },
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<MusicPlayerState>(
          stream: MusicPlayerService().stream,
          initialData: MusicPlayerService().state,
          builder: (context, snap) {
            final st = snap.data ?? MusicPlayerService().state;
            final track = st.current;
            if (track == null) {
              return Center(
                child: Text(AppLocale.pick('چیزی در حال پخش نیست', 'Nothing is playing'), style: const TextStyle(fontSize: 16)),
              );
            }
            final progress = st.duration.inMilliseconds > 0
                ? st.position.inMilliseconds / st.duration.inMilliseconds
                : 0.0;

            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              children: [
                const SizedBox(height: 10),
                // Glowing vinyl turntable artwork
                Center(
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: isDark
                            ? [const Color(0xFF1E3A5F), const Color(0xFF0F172A)]
                            : [const Color(0xFF2AABEE), const Color(0xFF1D70B8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.35),
                          blurRadius: 24,
                          spreadRadius: 2,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Vinyl concentric grooves
                        Container(
                          width: 170,
                          height: 170,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                              width: 1.5,
                            ),
                          ),
                        ),
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.2),
                              width: 1.5,
                            ),
                          ),
                        ),
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.9),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: Icon(Icons.music_note_rounded, size: 32, color: primary),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  track.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  track.artist,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: theme.textTheme.bodySmall?.color,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 22),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    activeTrackColor: primary,
                    inactiveTrackColor: primary.withValues(alpha: 0.16),
                    thumbColor: primary,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  ),
                  child: Slider(
                    value: progress.clamp(0.0, 1.0),
                    onChanged: (v) {
                      final ms = (v * st.duration.inMilliseconds).round();
                      MusicPlayerService().seek(Duration(milliseconds: ms));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatMediaDuration(st.position),
                        style: TextStyle(fontSize: 12, color: theme.textTheme.bodySmall?.color),
                        textDirection: TextDirection.ltr,
                      ),
                      Text(
                        formatMediaDuration(st.duration),
                        style: TextStyle(fontSize: 12, color: theme.textTheme.bodySmall?.color),
                        textDirection: TextDirection.ltr,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Playback main controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: AppLocale.pick('تکرار', 'Repeat'),
                      icon: Icon(
                        st.repeatMode == 2 ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                        color: st.repeatMode == 0 ? Colors.grey : primary,
                        size: 24,
                      ),
                      onPressed: () => MusicPlayerService().cycleRepeat(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: AppLocale.pick('۱۰ ثانیه عقب', 'Back 10 seconds'),
                      icon: const Icon(Icons.replay_10_rounded, size: 30),
                      onPressed: () => MusicPlayerService().seekBackward(),
                    ),
                    const SizedBox(width: 12),
                    // Large circular play button with gradient
                    Container(
                      width: 64,
                      height: 64,
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
                            color: primary.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: IconButton(
                        iconSize: 34,
                        color: Colors.white,
                        icon: st.loading
                            ? const SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                              )
                            : Icon(st.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        onPressed: () => MusicPlayerService().toggle(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: AppLocale.pick('۱۰ ثانیه جلو', 'Forward 10 seconds'),
                      icon: const Icon(Icons.forward_10_rounded, size: 30),
                      onPressed: () => MusicPlayerService().seekForward(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: AppLocale.pick('تصادفی', 'Shuffle'),
                      icon: Icon(
                        Icons.shuffle_rounded,
                        color: st.shuffle ? primary : Colors.grey,
                        size: 24,
                      ),
                      onPressed: () => MusicPlayerService().toggleShuffle(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: AppLocale.pick('قبلی', 'Previous'),
                      icon: const Icon(Icons.skip_previous_rounded, size: 30),
                      onPressed: st.queue.length > 1 ? () => MusicPlayerService().previous() : null,
                    ),
                    const SizedBox(width: 16),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => MusicPlayerService().cycleSpeed(),
                      child: Text('${st.speed}x', style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      tooltip: AppLocale.pick('بعدی', 'Next'),
                      icon: const Icon(Icons.skip_next_rounded, size: 30),
                      onPressed: st.queue.length > 1 ? () => MusicPlayerService().next() : null,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.queue_music_rounded, color: primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      AppLocale.pick('صف پخش (${st.queue.length})', 'Play queue (${st.queue.length})'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...List.generate(st.queue.length, (i) {
                  final t = st.queue[i];
                  final selected = i == st.index;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: selected
                          ? primary.withValues(alpha: isDark ? 0.2 : 0.1)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      leading: Icon(
                        selected ? Icons.play_circle_filled_rounded : Icons.music_note_rounded,
                        color: selected ? primary : Colors.grey,
                        size: 26,
                      ),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? primary : null,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        t.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => MusicPlayerService().playQueue(st.queue, startIndex: i),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}
