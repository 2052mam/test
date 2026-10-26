import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/core/utils/app_locale.dart';

void main() {
  test('English is the first-launch default and language selection remains reversible', () {
    expect(AppLocale.isFa, isFalse);
    expect(AppLocale.pick('فارسی', 'English'), 'English');

    AppLocale.set('fa');
    expect(AppLocale.isFa, isTrue);
    expect(AppLocale.pick('فارسی', 'English'), 'فارسی');

    AppLocale.set('en');
    expect(AppLocale.isFa, isFalse);
    expect(AppLocale.pick('فارسی', 'English'), 'English');
  });
}
