import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/services/media_download_service.dart';

/// Point 5 + Point 6: one place that turns a save attempt into an honest,
/// correctly-localised message.
///
/// Two bugs are fixed here at once:
///  * the app used to claim "saved" even when nothing was written, and
///  * every one of those messages was hardcoded Persian, so English users saw
///    Persian toasts.
class SaveFeedback {
  const SaveFeedback._();

  static bool _isFa(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'fa';

  /// Confirms a successful save, naming the album the file went to.
  static void success(
    BuildContext context, {
    required String fileName,
    String? album,
  }) {
    if (!context.mounted) return;
    final isFa = _isFa(context);
    final where = album ?? (isFa ? 'گالری' : 'Gallery');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isFa
              ? 'در $where ذخیره شد ($fileName)'
              : 'Saved to $where ($fileName)',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Reports a failed save. Permission problems get an "Open settings" action
  /// because the user cannot fix those from inside the app.
  static void failure(BuildContext context, Object error) {
    if (!context.mounted) return;
    final isFa = _isFa(context);
    final messenger = ScaffoldMessenger.of(context);

    if (error is MediaSaveException && error.isPermissionProblem) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.needsSettings
                ? (isFa
                    ? 'دسترسی ذخیره‌سازی رد شده است. آن را از تنظیمات برنامه روشن کنید.'
                    : 'Storage access is blocked. Enable it in app settings.')
                : (isFa
                    ? 'برای ذخیره، اجازه دسترسی به حافظه لازم است.'
                    : 'Storage permission is required to save.'),
          ),
          action: SnackBarAction(
            label: isFa ? 'تنظیمات' : 'Settings',
            onPressed: openAppSettings,
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    final detail = error is MediaSaveException ? error.details : '$error';
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          isFa
              ? 'ذخیره انجام نشد${detail == null ? '' : ': $detail'}'
              : 'Could not save${detail == null ? '' : ': $detail'}',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
