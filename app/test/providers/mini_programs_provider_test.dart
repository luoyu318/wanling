// mini_programs_provider_test.dart
//
// 验证 miniProgramsProvider:
//   - 成功路径:mock 返回服务端原始 envelope,getMiniPrograms 经拦截器剥壳后
//     按裸 list 解析(与 Task 7 修复后的 envelope 语义测试一致,钉住"不再
//     二次解 envelope"的回归)。
//   - 失败路径:ok=false 抛 ApiException,provider 兜底空列表,不炸 UI。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_service.dart';

import '../helpers/mock_adapter.dart';

void main() {
  ApiService buildApi(Object envelope) {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = MockHttpClientAdapter(200, envelope);
    return ApiService.withDio(dio);
  }

  test('成功路径:原始 envelope 剥壳后返回 server 列表', () async {
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(
          buildApi({
            'ok': true,
            'data': [
              {
                'id': 'id-1',
                'appid': 'a',
                'owner_id': 'o',
                'name': 'A',
                'version': 1,
                'status': 'published',
                'sha256': 'x',
                'size': 1,
              },
            ],
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    final list = await container.read(miniProgramsProvider.future);
    expect(list, hasLength(1));
    expect(list.first.appid, 'a');
  });

  test('失败路径:ok=false 抛 ApiException 兜底空列表不抛异常', () async {
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(
          buildApi({
            'ok': false,
            'error': {'code': 'internal_error', 'message': 'boom'},
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    final list = await container.read(miniProgramsProvider.future);
    expect(list, isEmpty);
  });
}
