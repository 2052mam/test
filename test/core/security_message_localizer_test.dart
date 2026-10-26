import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/core/utils/security_message_localizer.dart';

void main() {
  test('translates security code templates and preserves the code and metadata', () {
    const source =
        '🔐 کد ورود شما: 483921\n\n'
        'این کد برای ورود به حساب شما درخواست شده است و فقط چند دقیقه اعتبار دارد.\n'
        'دستگاه درخواست‌کننده: Pixel 8\nIP: 203.0.113.8';

    final result = SecurityMessageLocalizer.localize(source, isFa: false);

    expect(result, contains('Your sign-in code: 483921'));
    expect(result, contains('Requesting device: Pixel 8'));
    expect(result, contains('IP: 203.0.113.8'));
    expect(result, contains('valid for only a few minutes'));
  });

  test('leaves Persian security text unchanged in Persian mode', () {
    const source = '🔐 کد ورود شما: 123456';
    expect(
      SecurityMessageLocalizer.localize(source, isFa: true),
      source,
    );
  });

  test('does not translate ordinary message content', () {
    const userMessage = 'این پیام معمولی کاربر است';
    expect(
      SecurityMessageLocalizer.localize(userMessage, isFa: false),
      userMessage,
    );
  });
}
