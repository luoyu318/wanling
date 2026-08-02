import 'package:app/pages/scan_pair_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractPairTicketId', () {
    test('WLPAIR: 前缀正确提取 ticket_id', () {
      expect(
        extractPairTicketId('WLPAIR:abcdef1234567890'),
        'abcdef1234567890',
      );
    });

    test('无前缀返回 null', () {
      expect(extractPairTicketId('https://example.com/foo'), isNull);
    });

    test('纯文本返回 null', () {
      expect(extractPairTicketId('hello world'), isNull);
    });

    test('空字符串返回 null', () {
      expect(extractPairTicketId(''), isNull);
    });

    test('只有前缀无内容返回 null', () {
      expect(extractPairTicketId('WLPAIR:'), isNull);
    });
  });
}
