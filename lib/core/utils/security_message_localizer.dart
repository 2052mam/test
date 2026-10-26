/// Translates only known server-authored Security Support message templates.
/// Dynamic values (codes, device names, IP addresses, and timestamps) are left
/// intact, and this helper must only be used for the Security Support chat.
class SecurityMessageLocalizer {
  SecurityMessageLocalizer._();

  static String localize(String text, {required bool isFa}) {
    if (isFa || text.isEmpty) return text;

    const replacements = <String, String>{
      '🔐 کد ورود شما:': '🔐 Your sign-in code:',
      '⚠️ ورود جدید به حساب شما': '⚠️ New sign-in to your account',
      'رویداد امنیتی در حساب شما': 'Security event on your account',
      'درخواست کد ورود به حساب شما': 'Sign-in code requested for your account',
      'کد ورود برای حساب شما درخواست شد': 'A sign-in code was requested for your account',
      'دستگاه درخواست‌کننده:': 'Requesting device:',
      'دستگاه:': 'Device:',
      'IP:': 'IP:',
      'زمان:': 'Time:',
      'اگر این شما نبودید، فوراً رمز عبور خود را تغییر دهید و دستگاه‌های ناشناس را از بخش مدیریت دستگاه‌ها حذف کنید.':
          'If this was not you, change your password immediately and remove unknown devices in Device Management.',
      'اگر شما نبودید، فوراً تأیید دو مرحله‌ای را فعال کنید.':
          'If this was not you, enable two-step verification immediately.',
      'و از بخش «دستگاه‌ها و نشست‌ها» دستگاه‌های ناشناس را حذف کنید.':
          'and remove unknown devices from Devices & Sessions.',
      'این کد برای ورود به حساب شما درخواست شده است و فقط چند دقیقه اعتبار دارد.':
          'This code was requested to sign in to your account and is valid for only a few minutes.',
      '⚠️ اگر شما این درخواست را نداده‌اید، این کد را با هیچ‌کس در میان نگذارید':
          '⚠️ If you did not request this, do not share the code with anyone',
      'یک دستگاه از حساب شما حذف شد': 'A device was removed from your account',
      'دستگاه حذف شد': 'Device removed',
      'از حساب شما خارج شد.': 'was signed out of your account.',
      'دستگاه اصلی حساب تغییر کرد': 'Your account primary device changed',
      'دستگاه اصلی به': 'The primary device was changed to',
      'تأیید دو مرحله‌ای فعال شد': 'Two-step verification enabled',
      'تأیید دو مرحله‌ای روی حساب شما فعال شد.':
          'Two-step verification was enabled for your account.',
      'تأیید دو مرحله‌ای غیرفعال شد': 'Two-step verification disabled',
      'اگر شما این کار را نکرده‌اید، فوراً حساب خود را بررسی کنید.':
          'If you did not do this, review your account immediately.',
      'رمز آرشیو تغییر کرد': 'Archive lock password changed',
      'رمز قفل چت‌های آرشیوشده روی حساب شما تنظیم/تغییر کرد.':
          'The password for your archived chats was set or changed.',
    };

    var result = text;
    for (final entry in replacements.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }
}
