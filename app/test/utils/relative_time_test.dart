import 'package:app/utils/relative_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 7, 23, 12, 0);

  test('刚刚: < 1 分钟', () {
    expect(formatRelativeTime(now.subtract(const Duration(seconds: 30)), now: now), '刚刚');
  });

  test('分钟前: >= 1 分钟 < 1 小时', () {
    expect(formatRelativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5分钟前');
    expect(formatRelativeTime(now.subtract(const Duration(minutes: 59)), now: now), '59分钟前');
  });

  test('小时前: >= 1 小时 < 1 天', () {
    expect(formatRelativeTime(now.subtract(const Duration(hours: 3)), now: now), '3小时前');
    expect(formatRelativeTime(now.subtract(const Duration(hours: 23)), now: now), '23小时前');
  });

  test('天前: >= 1 天 < 7 天', () {
    expect(formatRelativeTime(now.subtract(const Duration(days: 1)), now: now), '1天前');
    expect(formatRelativeTime(now.subtract(const Duration(days: 6)), now: now), '6天前');
  });

  test('日期: >= 7 天', () {
    expect(formatRelativeTime(now.subtract(const Duration(days: 8)), now: now), '7月15日');
    expect(formatRelativeTime(now.subtract(const Duration(days: 30)), now: now), '6月23日');
  });

  test('UTC 输入自动转本地', () {
    final utc = DateTime.utc(2026, 7, 23, 4, 0);
    expect(formatRelativeTime(utc, now: now), isA<String>());
  });
}
