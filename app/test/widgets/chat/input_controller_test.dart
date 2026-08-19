import 'dart:io';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/providers/chat_provider.dart' show ChatNotifier;
import 'package:wanling_core/services/api_service.dart';
import 'package:app/widgets/chat/input_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 构造最小可用 [InputContext]：getContext 默认抛，ref/getNotifier/isMounted
/// 默认返安全值，测试用 overrides 替换需要的字段。
InputContext _buildContext({
  BuildContext Function()? getContext,
  WidgetRef? ref,
  ({String convId, String? agentId})? chatKey,
  bool Function()? isMounted,
  ChatNotifier Function()? getNotifier,
}) {
  return InputContext(
    getContext: getContext ?? (() => throw UnimplementedError()),
    ref: ref ?? _DummyRef(),
    chatKey: chatKey ?? (convId: 'c1', agentId: null),
    isMounted: isMounted ?? (() => true),
    getNotifier: getNotifier ?? (() => _NoopNotifier()),
  );
}

/// 占位 [WidgetRef]：测试中不触发 ref.read 时使用，noSuchMethod 默认抛错。
class _DummyRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可编程 [WidgetRef]：按返回类型分发 read。
/// - ApiService → 预设 fake
/// 其他调用走 noSuchMethod 抛错（测试若误触达会立刻暴露）。
class _StubRef implements WidgetRef {
  _StubRef({ApiService? api}) : _api = api;
  final ApiService? _api;

  @override
  T read<T>(ProviderListenable<T> provider) {
    if (T == ApiService) return (_api ?? _ThrowingApi()) as T;
    throw UnimplementedError('Unexpected read for type $T');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录 sendText / sendFile 调用参数，其他走 noSuchMethod。
class _RecordingNotifier implements ChatNotifier {
  String? sentText;
  int sendTextCalls = 0;

  String? sentFileId;
  MsgType? sentMsgType;
  String? sentFilename;
  String? sentMimeType;
  int? sentFileSize;
  int sendFileCalls = 0;

  @override
  Future<void> sendText(String text) async {
    sentText = text;
    sendTextCalls++;
  }

  @override
  Future<void> sendFile(
    String fileId,
    MsgType msgType, {
    String? filename,
    String? mimeType,
    int? fileSize,
  }) async {
    sentFileId = fileId;
    sentMsgType = msgType;
    sentFilename = filename;
    sentMimeType = mimeType;
    sentFileSize = fileSize;
    sendFileCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 永不调用的占位 notifier（断言「不应触达」时挂到 _buildContext 默认值）。
class _NoopNotifier implements ChatNotifier {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可配置 [ApiService]：uploadFile 返预设值或抛预设异常。
class _FakeApi implements ApiService {
  _FakeApi({this.uploadResult, this.uploadError});
  final String? uploadResult;
  final Object? uploadError;
  int uploadCalls = 0;
  List<String> uploadedPaths = [];
  List<String?> uploadedConvIds = [];

  @override
  Future<String> uploadFile(String filePath, {String? convId}) async {
    uploadCalls++;
    uploadedPaths.add(filePath);
    uploadedConvIds.add(convId);
    if (uploadError != null) throw uploadError!;
    return uploadResult!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// uploadFile 被调时抛 [UnimplementedError]（断言「不应被调用」）。
class _ThrowingApi implements ApiService {
  @override
  Future<String> uploadFile(String filePath, {String? convId}) {
    throw UnimplementedError('uploadFile should not be called');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可编程 [AssetEntity]：只覆盖 file getter，其他走 noSuchMethod。
///
/// 注意：FakeAsync zone（testWidgets 默认）会拦截真实 IO，所以 fileFuture
/// 必须是已完成的 Future（Future.value），不能走 await IO。
/// uploadFile 由 _FakeApi mock，不真实读盘，所以 File 不需存在。
class _FakeAssetEntity implements AssetEntity {
  _FakeAssetEntity({this.fileFuture});
  final Future<File?>? fileFuture;

  @override
  Future<File?> get file => fileFuture ?? Future.value(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// pump 一个最小 MaterialApp 拿 BuildContext（snackbar 测试需要 Overlay）。
Future<BuildContext> _pumpMinimalContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  group('send', () {
    test('空文本 → no-op（不调 notifier.sendText）', () {
      final notifier = _RecordingNotifier();
      final ctrl = InputController(
        _buildContext(getNotifier: () => notifier),
      );
      ctrl.send('');
      expect(notifier.sendTextCalls, 0, reason: '空串不应触发 sendText');
    });

    test('有文本 → 调 notifier.sendText(text)', () {
      final notifier = _RecordingNotifier();
      final ctrl = InputController(
        _buildContext(getNotifier: () => notifier),
      );
      ctrl.send('hello');
      expect(notifier.sendTextCalls, 1);
      expect(notifier.sentText, 'hello');
    });
  });

  group('uploadAndSendAsset', () {
    test('asset.file == null → 不调 api/notifier（snackbar 校验见另一用例）',
        () async {
      final api = _FakeApi(uploadResult: 'fid');
      final notifier = _RecordingNotifier();
      // isMounted=false 避免 file=null 路径触发 snackbar 需要 BuildContext。
      final ctrl = InputController(_buildContext(
        ref: _StubRef(api: api),
        getNotifier: () => notifier,
        isMounted: () => false,
      ));
      await ctrl.uploadAndSendAsset(_FakeAssetEntity(), MsgType.image);

      expect(api.uploadCalls, 0, reason: 'file=null 不应调 uploadFile');
      expect(notifier.sendFileCalls, 0, reason: 'file=null 不应调 sendFile');
    });

    test('成功 → api.uploadFile + notifier.sendFile(fileId, msgType)',
        () async {
      final api = _FakeApi(uploadResult: 'fid-123');
      final notifier = _RecordingNotifier();

      final ctrl = InputController(_buildContext(
        ref: _StubRef(api: api),
        getNotifier: () => notifier,
        chatKey: (convId: 'conv-9', agentId: null),
      ));
      await ctrl.uploadAndSendAsset(
        _FakeAssetEntity(fileFuture: Future.value(File('/tmp/any.png'))),
        MsgType.image,
      );

      expect(api.uploadCalls, 1);
      expect(api.uploadedPaths, ['/tmp/any.png']);
      expect(api.uploadedConvIds, ['conv-9']);
      expect(notifier.sendFileCalls, 1);
      expect(notifier.sentFileId, 'fid-123');
      expect(notifier.sentMsgType, MsgType.image);
    });

    testWidgets('上传失败 → snackbar 显示用户可读消息', (tester) async {
      final api = _FakeApi(uploadError: Exception('network down'));
      final notifier = _RecordingNotifier();
      final ctx = await _pumpMinimalContext(tester);

      final ctrl = InputController(_buildContext(
        getContext: () => ctx,
        ref: _StubRef(api: api),
        getNotifier: () => notifier,
      ));
      await ctrl.uploadAndSendAsset(
        _FakeAssetEntity(fileFuture: Future.value(File('/tmp/any.png'))),
        MsgType.image,
      );
      await tester.pump();

      expect(api.uploadCalls, 1);
      expect(notifier.sendFileCalls, 0, reason: '上传失败不应调 sendFile');
      // extractDioErrorMessage 对非 DioException 走 fallback「操作失败」
      expect(find.textContaining('操作失败'), findsOneWidget);
    });

    testWidgets('上传失败 + !isMounted → 不弹 snackbar', (tester) async {
      final api = _FakeApi(uploadError: Exception('boom'));
      final notifier = _RecordingNotifier();
      final ctx = await _pumpMinimalContext(tester);

      final ctrl = InputController(_buildContext(
        getContext: () => ctx,
        ref: _StubRef(api: api),
        getNotifier: () => notifier,
        isMounted: () => false,
      ));
      await ctrl.uploadAndSendAsset(
        _FakeAssetEntity(fileFuture: Future.value(File('/tmp/any.png'))),
        MsgType.image,
      );
      await tester.pump();

      expect(notifier.sendFileCalls, 0);
      expect(find.textContaining('操作失败'), findsNothing,
          reason: '已卸载时不应弹 snackbar');
    });

    testWidgets('asset.file == null → snackbar「无法读取文件」', (tester) async {
      final api = _FakeApi(uploadResult: 'fid');
      final notifier = _RecordingNotifier();
      final ctx = await _pumpMinimalContext(tester);

      final ctrl = InputController(_buildContext(
        getContext: () => ctx,
        ref: _StubRef(api: api),
        getNotifier: () => notifier,
      ));
      await ctrl.uploadAndSendAsset(_FakeAssetEntity(), MsgType.image);
      await tester.pump();

      expect(find.text('无法读取文件'), findsOneWidget);
    });
  });
}
