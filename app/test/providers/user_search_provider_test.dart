import 'package:app/models/user_summary.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/user_search_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;

  setUp(() {
    api = MockApi();
    registerFallbackValue('');
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('初始 state 为空', () {
    final container = makeContainer();
    final state = container.read(userSearchProvider);
    expect(state.query, '');
    expect(state.results, isEmpty);
    expect(state.loading, isFalse);
  });

  test('updateQuery 标记 loading=true 但 500ms 内不调 server', () {
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    notifier.updateQuery('ali');
    expect(container.read(userSearchProvider).loading, isTrue);
    expect(container.read(userSearchProvider).query, 'ali');
    // 500ms 内还没调 server（mocktail 没注册 searchUsers，调用会抛）
    verifyNever(() => api.searchUsers(any()));
  });

  test('updateQuery 空 query 立即清空 results 不调 server', () async {
    when(() => api.searchUsers('ali')).thenAnswer((_) async => [
          {'username': 'alice', 'nickname': '', 'avatar_url': ''},
        ]);
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    // 先填充 results
    notifier.updateQuery('ali');
    await Future.delayed(const Duration(milliseconds: 600));
    expect(container.read(userSearchProvider).results.length, 1);

    // 清空
    notifier.updateQuery('');
    expect(container.read(userSearchProvider).query, '');
    expect(container.read(userSearchProvider).results, isEmpty);
    expect(container.read(userSearchProvider).loading, isFalse);
  });

  test('防抖 500ms 后才调 server', () async {
    when(() => api.searchUsers('bob')).thenAnswer((_) async => [
          {'username': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
        ]);
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    notifier.updateQuery('bob');

    // 200ms 后还没调
    await Future.delayed(const Duration(milliseconds: 200));
    verifyNever(() => api.searchUsers(any()));

    // 总共 600ms 后才调
    await Future.delayed(const Duration(milliseconds: 400));
    verify(() => api.searchUsers('bob')).called(1);
    expect(container.read(userSearchProvider).loading, isFalse);
    expect(container.read(userSearchProvider).results.length, 1);
    expect(container.read(userSearchProvider).results.first.username, 'bob');
    expect(container.read(userSearchProvider).results.first.nickname, 'Bob');
  });

  test('500ms 内连续输入取消上一次 timer（只发最后一次）', () async {
    when(() => api.searchUsers('carol')).thenAnswer((_) async => []);
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    notifier.updateQuery('a');
    await Future.delayed(const Duration(milliseconds: 200));
    notifier.updateQuery('ab');
    await Future.delayed(const Duration(milliseconds: 200));
    notifier.updateQuery('carol');
    await Future.delayed(const Duration(milliseconds: 600));

    // 只有最后一次 'carol' 被搜索
    verify(() => api.searchUsers('carol')).called(1);
    verifyNever(() => api.searchUsers('a'));
    verifyNever(() => api.searchUsers('ab'));
  });

  test('searchUsers 抛异常时 loading 置 false 不写 results', () async {
    when(() => api.searchUsers('err'))
        .thenThrow(Exception('network error'));
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    notifier.updateQuery('err');
    await Future.delayed(const Duration(milliseconds: 600));

    final state = container.read(userSearchProvider);
    expect(state.loading, isFalse);
    expect(state.results, isEmpty);
  });

  test('testFlush 跳过 500ms 防抖立即搜索', () async {
    when(() => api.searchUsers('test')).thenAnswer((_) async => [
          {'username': 'testuser', 'nickname': '', 'avatar_url': ''},
        ]);
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    notifier.updateQuery('test');
    // 不等 500ms，直接 flush
    await notifier.testFlush();

    final state = container.read(userSearchProvider);
    expect(state.loading, isFalse);
    expect(state.results.length, 1);
    expect(state.results.first.username, 'testuser');
  });

  test('解析多个结果', () async {
    when(() => api.searchUsers('user')).thenAnswer((_) async => [
          {'username': 'user1', 'nickname': 'User One', 'avatar_url': ''},
          {'username': 'user2', 'nickname': '', 'avatar_url': ''},
          {'username': 'user3', 'nickname': 'User Three', 'avatar_url': ''},
        ]);
    final container = makeContainer();
    final notifier = container.read(userSearchProvider.notifier);

    notifier.updateQuery('user');
    await notifier.testFlush();

    final results = container.read(userSearchProvider).results;
    expect(results.length, 3);
    expect(results[0].username, 'user1');
    expect(results[0].displayName, 'User One');
    expect(results[1].displayName, 'user2'); // 无 nickname 回退 username
    expect(results[2].nickname, 'User Three');
  });

  test('UserSummary.fromJson 兼容缺失 nickname', () {
    final u = UserSummary.fromJson({
      'username': 'alice',
      // nickname 缺失
    });
    expect(u.username, 'alice');
    expect(u.nickname, 'alice'); // 回退到 username
    expect(u.displayName, 'alice');
  });
}
