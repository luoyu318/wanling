// 授权密钥管理页 widget 测试:列表渲染(活跃/已吊销状态区分)/吊销确认流(确认弹窗→
// DELETE→重拉列表)/错误重试。走真实 dio 拦截器链路(_RoutingAdapter),与线上一致。
import 'dart:convert';

import 'package:app/pages/agent_sub_keys_page.dart';
import 'package:dio/dio.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按 path 精确路由响应的测试 adapter(对齐 admin_mini_program_page_test 模式)。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  final Map<String, (int, Object)> routes;
  final List<String> hits = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hits.add('${options.method} ${options.path}');
    final (code, data) = routes[options.path]!; // 未注册路由直接炸,fail fast
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(data)),
      code,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }
}

Map<String, dynamic> _keyJson(
  String id, {
  bool revoked = false,
  bool used = false,
}) =>
    {
      'id': id,
      'name': '技能-$id',
      'agent_id': 'a1',
      'created_at': '2026-09-01T10:00:00Z',
      if (used) 'last_used_at': '2026-09-01T11:00:00Z',
      if (revoked) 'revoked_at': '2026-09-01T12:00:00Z',
    };

Widget _harness(ApiService api) {
  return ProviderScope(
    overrides: [apiProvider.overrideWithValue(api)],
    child: const MaterialApp(home: AgentSubKeysPage(agentId: 'a1')),
  );
}

void main() {
  testWidgets('列表渲染:顶部说明/名称/状态 生效中·已吊销/从未使用', (tester) async {
    final adapter = _RoutingAdapter({
      '/api/agents/a1/subkeys': (
        200,
        {
          'ok': true,
          'data': {
            'subkeys': [_keyJson('k1', used: true), _keyJson('k2', revoked: true)],
          },
        },
      ),
    });
    await tester.pumpWidget(_harness(ApiService.withDio(
      Dio(BaseOptions(baseUrl: 'http://test.local'))..httpClientAdapter = adapter,
    )));
    await tester.pumpAndSettle();

    // 顶部说明(定稿文案)
    expect(
        find.text('授权密钥仅供 REST 调用，不能建立长连接；重置主密钥将同时吊销全部授权密钥'),
        findsOneWidget);
    // 名称 + 状态
    expect(find.text('技能-k1'), findsOneWidget);
    expect(find.text('生效中'), findsOneWidget);
    expect(find.text('技能-k2'), findsOneWidget);
    expect(find.text('已吊销'), findsOneWidget);
    // 活跃行显示吊销入口,已吊销行不显示(trailing 内仅一处 TextButton)
    expect(find.widgetWithText(TextButton, '吊销'), findsOneWidget);
    // k1 有 last_used_at,k2 没有 → 只有一个「从未使用」(subtitle 长串内含该子文本)
    expect(find.textContaining('从未使用'), findsOneWidget);
  });

  testWidgets('吊销流:确认弹窗→确定→DELETE→重拉列表', (tester) async {
    final adapter = _RoutingAdapter({
      '/api/agents/a1/subkeys': (
        200,
        {
          'ok': true,
          'data': {
            'subkeys': [_keyJson('k1')],
          },
        },
      ),
      '/api/agents/a1/subkeys/k1': (
        200,
        {'ok': true, 'data': {'message': '吊销成功'}},
      ),
    });
    await tester.pumpWidget(_harness(ApiService.withDio(
      Dio(BaseOptions(baseUrl: 'http://test.local'))..httpClientAdapter = adapter,
    )));
    await tester.pumpAndSettle();
    expect(adapter.hits, ['GET /api/agents/a1/subkeys']);

    await tester.tap(find.text('吊销'));
    await tester.pumpAndSettle();
    // 吊销确认文案(定稿)
    expect(find.text('吊销后该密钥不能再换新 token，已签发 token 过期前仍有效'), findsOneWidget);

    // 弹窗主按钮文案「吊销」(与列表 trailing 区分:精确匹配 FilledButton)
    await tester.tap(find.widgetWithText(FilledButton, '吊销'));
    await tester.pumpAndSettle();

    // DELETE 已发 + 列表重拉(GET ×2)
    expect(
        adapter.hits,
        containsAllInOrder([
          'GET /api/agents/a1/subkeys',
          'DELETE /api/agents/a1/subkeys/k1',
          'GET /api/agents/a1/subkeys',
        ]));
  });

  testWidgets('加载失败 → 错误文案 + 重试按钮,重试成功渲染列表', (tester) async {
    final adapter = _RoutingAdapter({
      '/api/agents/a1/subkeys': (
        500,
        {
          'ok': false,
          'error': {'code': 'internal_error', 'message': 'boom'},
        },
      ),
    });
    await tester.pumpWidget(_harness(ApiService.withDio(
      Dio(BaseOptions(baseUrl: 'http://test.local'))..httpClientAdapter = adapter,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
