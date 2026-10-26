import 'package:flutter/material.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/utils/media_utils.dart';

/// Authenticated relative media URLs with Telegram-style vibrant multi-gradient
/// initial/icon fallback on failure.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.title,
    this.url,
    this.token,
    this.radius = 20,
    this.foreground,
    this.background,
    this.fallbackIcon,
  });

  final String title;
  final String? url;
  final String? token;
  final double radius;
  final Color? foreground;
  final Color? background;
  final IconData? fallbackIcon;

  // Telegram-style 7 vibrant avatar gradient sets
  static const List<List<Color>> _avatarGradients = [
    [Color(0xFFFF512F), Color(0xFFDD2476)], // Crimson Sunset
    [Color(0xFFE94057), Color(0xFF8A2387)], // Berry Violet
    [Color(0xFF4776E6), Color(0xFF8E54E9)], // Royal Indigo
    [Color(0xFF00B4DB), Color(0xFF0083B0)], // Oceanic Cyan
    [Color(0xFF11998E), Color(0xFF38EF7D)], // Mint Emerald
    [Color(0xFFF7971E), Color(0xFFFFD200)], // Amber Gold
    [Color(0xFFFC466B), Color(0xFF3F5EFB)], // Electric Aurora
  ];

  List<Color> _gradientForTitle(String text) {
    if (text.isEmpty) return _avatarGradients[0];
    final code = text.codeUnits.fold<int>(0, (prev, elem) => prev + elem);
    return _avatarGradients[code % _avatarGradients.length];
  }

  @override
  Widget build(BuildContext context) {
    final fullUrl = resolveMediaUrl(null, existingUrl: url);
    final uri = Uri.tryParse(fullUrl);
    final base = Uri.parse(ApiConstants.baseUrl);
    final hasImage =
        uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        ['http', 'https'].contains(uri.scheme);
    final headers =
        token != null && hasImage && uri != null && uri.origin == base.origin
        ? {'Authorization': 'Bearer $token'}
        : null;

    final color = foreground ?? Colors.white;
    final gradient = _gradientForTitle(title);
    final initial = title.trim().isEmpty
        ? '?'
        : title.trim().characters.first.toUpperCase();

    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: (hasImage || background != null)
            ? null
            : LinearGradient(
                colors: gradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        color: background,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: Colors.transparent,
        foregroundColor: color,
        foregroundImage: hasImage
            ? NetworkImage(fullUrl, headers: headers)
            : null,
        onForegroundImageError: hasImage ? (_, __) {} : null,
        child: fallbackIcon != null
            ? Icon(fallbackIcon, size: radius * 1.05, color: color)
            : Text(
                initial,
                style: TextStyle(
                  fontSize: radius * 0.82,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
      ),
    );
  }
}
