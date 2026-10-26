import 'package:flutter/material.dart';

/// Opens at most one route for a chat in each Navigator.
///
/// Repeated taps on search results, notifications, or chat-list rows focus the
/// existing route instead of stacking duplicate chat screens. Keeping the map
/// in an Expando ties its lifetime to the Navigator and avoids retaining a
/// logged-out user's route tree.
class ChatNavigation {
  ChatNavigation._();

  static final Expando<Map<String, Route<void>>> _routes =
      Expando<Map<String, Route<void>>>('chat routes');

  static Future<void> open(
    BuildContext context, {
    required String chatId,
    required WidgetBuilder builder,
  }) =>
      openOnNavigator(
        Navigator.of(context),
        chatId: chatId,
        builder: builder,
      );

  static Future<void> openOnNavigator(
    NavigatorState navigator, {
    required String chatId,
    required WidgetBuilder builder,
  }) async {
    final routes = _routes[navigator] ??= <String, Route<void>>{};
    final existing = routes[chatId];
    if (existing != null && existing.isActive) {
      navigator.popUntil((route) => identical(route, existing) || route.isFirst);
      return;
    }
    if (existing != null) routes.remove(chatId);

    final route = MaterialPageRoute<void>(
      settings: RouteSettings(name: '/chat/$chatId'),
      builder: builder,
    );
    routes[chatId] = route;
    try {
      await navigator.push<void>(route);
    } finally {
      if (identical(routes[chatId], route)) routes.remove(chatId);
    }
  }
}
