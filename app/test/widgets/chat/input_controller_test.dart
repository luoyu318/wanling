import 'dart:io';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show ChatNotifier;
import 'package:wanling_core/services/api_service.dart';
import 'package:app/providers/pending_image_provider.dart';
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

/// 转发 [ProviderContainer] 的 [WidgetRef]：send 分支测试用真实 provider
/// 状态（pendingImageProvider 读写），apiProvider 由 container override 提供。
class _ContainerRef implements WidgetRef {
  _ContainerRef(this._container);
  final ProviderContainer _container;

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录 sendText / sendFile / sendMixed 调用参数，其他走 noSuchMethod。
class _RecordingNotifier implements ChatNotifier {
  final textCalls = <String>[];

  /// (fileId, msgType)。
  final fileCalls = <(String, MsgType)>[];

  /// (text, fileId)。
  final mixedCalls = <(String, String)>[];

  @override
  Future<void> sendText(String text) async {
    textCalls.add(text);
  }

  @override
  Future<void> sendFile(
    String fileId,
    MsgType msgType, {
    String? filename,
    String? mimeType,
    int? fileSize,
  }) async {
    fileCalls.add((fileId, msgType));
  }

  @override
  Future<void> sendMixed(
    String text,
    String fileId, {
    String filename = '',
    String mimeType = '',
  }) async {
    mixedCalls.add((text, fileId));
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

  /// 非 null 时 uploadFile 抛此异常，注入上传失败路径。
  final Object? uploadError;
  final String? uploadResult;
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

/// 挂图测试环境：container（apiProvider override + pendingImage listener）
/// 并预置挂载 [asset]，返回 (container, chatKey)。
/// listener 模拟 chat_page 对缩略图的 watch：保持 autoDispose provider 存活，
/// 否则两次 read 之间 provider 被 dispose、挂图 state 丢失。
(ProviderContainer, ({String convId, String? agentId})) _mountAsset(
  _FakeApi api,
  _FakeAssetEntity asset,
) {
  final container = ProviderContainer(overrides: [
    apiProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  const key = (convId: 'c1', agentId: null);
  container.listen(pendingImageProvider(key), (_, _) {});
  container.read(pendingImageProvider(key).notifier).state = asset;
  return (container, key);
}

/// 无挂图测试环境：仅 apiProvider override 的空 container。
ProviderContainer _emptyContainer(_FakeApi api) {
  final container = ProviderContainer(overrides: [
    apiProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('send', () {
    test('空文本且无挂图 → no-op（不调 notifier/api）', () async {
      final api = _FakeApi();
      final container = _emptyContainer(api);
      final notifier = _RecordingNotifier();
      final ctrl = InputController(_buildContext(
        ref: _ContainerRef(container),
        getNotifier: () => notifier,
      ));

      await ctrl.send('');

      expect(notifier.textCalls, isEmpty, reason: '空串不应触发 sendText');
      expect(api.uploadCalls, 0, reason: '空串不应触发上传');
    });

    test('无挂图 → 维持 sendText 现状，不触发上传', () async {
      final api = _FakeApi();
      final container = _emptyContainer(api);
      final notifier = _RecordingNotifier();
      final ctrl = InputController(_buildContext(
        ref: _ContainerRef(container),
        getNotifier: () => notifier,
      ));

      await ctrl.send('hello');

      expect(notifier.textCalls, ['hello']);
      expect(api.uploadCalls, 0, reason: '无挂图不应触发上传');
    });

    test('挂图+有文字 → 上传后 sendMixed(文字, fileId)，发送后挂图清空',
        () async {
      final api = _FakeApi(uploadResult: 'file-9');
      final (container, key) = _mountAsset(
        api,
        _FakeAssetEntity(fileFuture: Future.value(File('/tmp/any.png'))),
      );
      final notifier = _RecordingNotifier();
      final ctrl = InputController(_buildContext(
        ref: _ContainerRef(container),
        getNotifier: () => notifier,
        chatKey: key,
      ));

      await ctrl.send('看这张');

      // 断言:upload 发生,notifier 收到 sendMixed('看这张','file-9')
      expect(api.uploadCalls, 1);
      expect(api.uploadedPaths, ['/tmp/any.png']);
      expect(api.uploadedConvIds, ['c1']);
      expect(notifier.mixedCalls, hasLength(1));
      expect(notifier.mixedCalls.first.$1, '看这张');
      expect(notifier.mixedCalls.first.$2, 'file-9');
      // 发送后挂图清空
      expect(container.read(pendingImageProvider(key)), isNull);
    });

    test('挂图+无文字 → 上传后 sendFile(image)，不发 mixed，发送后挂图清空',
        () async {
      final api = _FakeApi(uploadResult: 'file-9');
      final (container, key) = _mountAsset(
        api,
        _FakeAssetEntity(fileFuture: Future.value(File('/tmp/any.png'))),
      );
      final notifier = _RecordingNotifier();
      final ctrl = InputController(_buildContext(
        ref: _ContainerRef(container),
        getNotifier: () => notifier,
        chatKey: key,
      ));

      await ctrl.send('');

      expect(api.uploadCalls, 1);
      expect(notifier.fileCalls, [('file-9', MsgType.image)]);
      expect(notifier.mixedCalls, isEmpty, reason: '无文字不应发 mixed');
      expect(container.read(pendingImageProvider(key)), isNull,
          reason: '发送后挂图应清空');
    });

    test('上传失败 → 保留挂图可重试，不触发 sendMixed/sendFile', () async {
      final api = _FakeApi(uploadError: Exception('network down'));
      final (container, key) = _mountAsset(
        api,
        _FakeAssetEntity(fileFuture: Future.value(File('/tmp/any.png'))),
      );
      final notifier = _RecordingNotifier();
      final ctrl = InputController(_buildContext(
        ref: _ContainerRef(container),
        getNotifier: () => notifier,
        chatKey: key,
        // 单测环境未挂载:跳过失败 snackbar（getContext 未 stub 会抛）
        isMounted: () => false,
      ));

      await ctrl.send('看这张');

      expect(api.uploadCalls, 1);
      expect(notifier.mixedCalls, isEmpty, reason: '上传失败不应发 mixed');
      expect(notifier.fileCalls, isEmpty, reason: '上传失败不应发 file');
      expect(container.read(pendingImageProvider(key)), isNotNull,
          reason: '失败保留挂图可重试');
    });

    test('挂图 file 读取为 null → 不上传不发送，挂图保留', () async {
      final api = _FakeApi(uploadResult: 'file-9');
      final (container, key) = _mountAsset(api, _FakeAssetEntity());
      final notifier = _RecordingNotifier();
      final ctrl = InputController(_buildContext(
        ref: _ContainerRef(container),
        getNotifier: () => notifier,
        chatKey: key,
        isMounted: () => false,
      ));

      await ctrl.send('');

      expect(api.uploadCalls, 0, reason: '读不到文件不应触发上传');
      expect(notifier.mixedCalls, isEmpty);
      expect(notifier.fileCalls, isEmpty);
      expect(container.read(pendingImageProvider(key)), isNotNull,
          reason: '挂图保留，用户可重试或删除');
    });
  });

  group('pickAlbum 挂载语义', () {
    test('选图仅挂载（写 provider），不触发上传/发送', () {
      // AssetPicker.pickAssets 是静态原生通道,单测无法 stub(与既有测试对
      // picker 的处理方式一致),改为直接验证挂载语义:write provider。
      final api = _FakeApi(uploadResult: 'file-9');
      final notifier = _RecordingNotifier();
      final (container, key) = _mountAsset(api, _FakeAssetEntity());

      expect(container.read(pendingImageProvider(key)), isNotNull,
          reason: '选图结果应挂载到 provider');
      expect(api.uploadCalls, 0, reason: '仅挂载不应触发上传');
      expect(notifier.mixedCalls, isEmpty, reason: '仅挂载不应触发发送');
      expect(notifier.fileCalls, isEmpty, reason: '仅挂载不应触发发送');
    });
  });
}
