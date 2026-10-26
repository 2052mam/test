import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/core/theme/chat_design.dart';

void main() {
  test('message width stays proportional on phones and capped on wide screens', () {
    expect(ChatDesign.messageMaxWidth(390), closeTo(319.8, 0.01));
    expect(ChatDesign.messageMaxWidth(900), closeTo(900 / ChatDesign.goldenRatio, 0.01));
    expect(ChatDesign.messageMaxWidth(1600), 720);
  });
}
