import 'package:wanling_core/utils/diff_merge.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item {
  final String id;
  final int value;
  _Item(this.id, this.value);
}

void main() {
  group('diffMerge', () {
    test('fresh 全新增(local 空)', () {
      final fresh = [_Item('a', 1), _Item('b', 2)];
      final merged = diffMerge<_Item>(
        localList: const [],
        freshList: fresh,
        idOf: (i) => i.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      expect(merged.length, 2);
      expect(merged[0].id, 'a');
      expect(merged[1].id, 'b');
    });

    test('fresh 全删除(local 有但 fresh 没,keepLocal=false 删)', () {
      final local = [_Item('a', 1)];
      final merged = diffMerge<_Item>(
        localList: local,
        freshList: const [],
        idOf: (i) => i.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      expect(merged, isEmpty);
    });

    test('keepLocal=true 时本地多余项保留', () {
      final local = [_Item('a', 1), _Item('b', 2)];
      final fresh = [_Item('a', 10)];
      final merged = diffMerge<_Item>(
        localList: local,
        freshList: fresh,
        idOf: (i) => i.id,
        mergeItem: (local, f) => f,
        keepLocal: (local) => local.id == 'b',  // b 强制保留
      );
      expect(merged.length, 2);
      expect(merged.where((i) => i.id == 'a').first.value, 10);
      expect(merged.where((i) => i.id == 'b').first.value, 2);  // 保留本地
    });

    test('字段级 merge: 走 mergeItem 函数', () {
      final local = [_Item('a', 100)];
      final fresh = [_Item('a', 1)];
      final merged = diffMerge<_Item>(
        localList: local,
        freshList: fresh,
        idOf: (i) => i.id,
        mergeItem: (local, f) => _Item(f.id, local.value + f.value),  // 求和
        keepLocal: (_) => false,
      );
      expect(merged.first.value, 101);
    });

    test('混合场景:新增 + 删除 + 字段 merge 同时发生', () {
      final local = [_Item('a', 1), _Item('b', 2), _Item('c', 3)];
      final fresh = [_Item('a', 10), _Item('d', 4)];  // a 更新, b/c 删, d 新增
      final merged = diffMerge<_Item>(
        localList: local,
        freshList: fresh,
        idOf: (i) => i.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      expect(merged.length, 2);  // a + d
      expect(merged.where((i) => i.id == 'a').first.value, 10);
      expect(merged.where((i) => i.id == 'd').first.value, 4);
    });

    test('fresh 有重复 id 时只保留首次', () {
      final fresh = [_Item('a', 1), _Item('a', 99), _Item('b', 2)];
      final merged = diffMerge<_Item>(
        localList: const [],
        freshList: fresh,
        idOf: (i) => i.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      expect(merged.length, 2);
      expect(merged.where((i) => i.id == 'a').single.value, 1); // 首次
      expect(merged.where((i) => i.id == 'b').single.value, 2);
    });

    test('local 有重复 id 且 keepLocal=true 时只保留首次', () {
      final local = [_Item('x', 1), _Item('x', 99)]; // 重复
      final merged = diffMerge<_Item>(
        localList: local,
        freshList: const [],
        idOf: (i) => i.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => true,
      );
      expect(merged.length, 1);
      expect(merged.single.id, 'x');
      expect(merged.single.value, 1); // 首次
    });
  });
}
