import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/shared/browser_hint.dart';

void main() {
  test('in a browser, a server that seems down may only not allow the page', () {
    expect(corsHint(web: false), isEmpty, reason: 'the apps ignore CORS');
    expect(
      corsHint(web: true, page: 'https://soliton.example.com'),
      contains('SOLITON_CORS_ORIGINS=https://soliton.example.com'),
    );
  });
}
