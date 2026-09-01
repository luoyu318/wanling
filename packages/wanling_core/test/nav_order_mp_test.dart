import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/providers/nav_order_provider.dart';

void main() {
  group('mp 槽 id helper', () {
    test('navMpRef/isMpNavId/navMpAppidOf 往返一致', () {
      final id = navMpRef('showcase');
      expect(isMpNavId(id), isTrue);
      expect(navMpAppidOf(id), 'showcase');
      expect(isMpNavId('conv:abc'), isFalse);
      expect(navMpAppidOf('msg'), isNull);
    });
    test('mp 槽不在固定项集合(可 unpin)', () {
      expect(kNavFixedIds.contains(navMpRef('showcase')), isFalse);
    });
  });
}
