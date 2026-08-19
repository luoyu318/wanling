import 'dart:async';

import 'package:wanling_core/services/file_download_service.dart'
    show DownloadProgress, FileDownloadService;
import 'package:app/widgets/chat/file_download_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [FileDownloadService]:把 downloadWithProgress / cancel / getLocalPath
/// 桩成可控的测试入口,避免真实 HTTP / OpenFilex / path_provider。
///
/// - [controllers]:每个 fileId 一个 [StreamController],测试用 [emit] 推事件。
/// - [cancelledFileIds]:记录 cancel 调用。
/// - [localPathReturn]:getLocalPath 返回值(null → 触发「文件未找到」分支,
///   避免触发 OpenFilex 插件调用)。
class _FakeFileDownloadService extends FileDownloadService {
  _FakeFileDownloadService() : super(baseUrl: 'http://test.invalid', token: 't');

  final Map<String, StreamController<DownloadProgress>> controllers = {};
  final List<String> cancelledFileIds = [];
  final List<String> getLocalPathCalls = [];
  String? localPathReturn;

  @override
  Stream<DownloadProgress> downloadWithProgress(String fileId) {
    // sync: true 让事件在 add 时同步投递,测试中 emit 后立即可见,无需 pump。
    return controllers
        .putIfAbsent(
          fileId,
          () => StreamController<DownloadProgress>(sync: true),
        )
        .stream;
  }

  @override
  Future<void> cancel(String fileId) async {
    cancelledFileIds.add(fileId);
  }

  @override
  Future<String?> getLocalPath(String fileId) async {
    getLocalPathCalls.add(fileId);
    return localPathReturn;
  }

  /// 向 fileId 的流推一个事件。
  void emit(String fileId, DownloadProgress p) {
    controllers[fileId]?.add(p);
  }

  /// 关闭 fileId 的流(触发 onDone)。
  void closeStream(String fileId) {
    controllers[fileId]?.close();
  }

  /// 测试 teardown 用:关闭所有控制器,避免 lingering stream warning。
  void disposeAll() {
    for (final c in controllers.values) {
      if (!c.isClosed) c.close();
    }
    controllers.clear();
  }
}

/// 构造一个最小可用的 [FileDownloadContext],所有回调默认 no-op 或返 stub。
/// 测试用 `overrides` 替换需要的字段。
FileDownloadContext _buildContext({
  required _FakeFileDownloadService service,
  BuildContext Function()? getContext,
  void Function(VoidCallback)? onSetState,
  bool Function()? isMounted,
}) {
  return FileDownloadContext(
    getContext: getContext ?? (() => throw UnimplementedError()),
    onSetState: onSetState ?? ((cb) => cb()),
    isMounted: isMounted ?? (() => true),
    downloadService: service,
  );
}

/// 在 MaterialApp + Scaffold 里捕获 [BuildContext],供需要 Overlay 的用例用。
Future<void> _pumpHarness(
  WidgetTester tester,
  void Function(BuildContext ctx) onReady,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            onReady(ctx);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
}

void main() {
  group('buildSnapshots', () {
    test('空状态 → 返回 null', () {
      final service = _FakeFileDownloadService();
      final ctrl = FileDownloadController(_buildContext(service: service));
      expect(ctrl.buildSnapshots(), isNull);
    });

    test('有进行中下载 → map 含 fileId,state=1 + progress', () {
      final service = _FakeFileDownloadService();
      final ctrl = FileDownloadController(_buildContext(service: service));
      // startDownload 立即把 _downloadProgress[fileId] 设为 0
      ctrl.startDownload('f1', 'name.pdf', 'application/pdf', 100);
      // 推一个进度事件
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 50, total: 100),
      );
      final snap = ctrl.buildSnapshots();
      expect(snap, isNotNull);
      expect(snap!['f1']?.state, 1);
      expect(snap['f1']?.progress, 0.5);
      service.disposeAll();
    });

    testWidgets('有已下载 → map 含 fileId,state=2', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      ctrl.startDownload('f1', 'name.pdf', 'application/pdf', 100);
      // 推 done 事件:done 分支会调 openLocalFile(异步),getLocalPath 返 null
      // → 触发 showAppSnackBar,需要 BuildContext + Material。
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 100, total: 100, done: true),
      );
      await tester.pumpAndSettle();
      final snap = ctrl.buildSnapshots();
      expect(snap, isNotNull);
      expect(snap!['f1']?.state, 2);
      // done 触发 openLocalFile → getLocalPath 被调
      expect(service.getLocalPathCalls, contains('f1'));
      service.disposeAll();
    });

    testWidgets('进度 + 已下载(f1 下载中,f2 已下载)→ 两 entry 共存', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      // f1: 下载中(progress=0.5)
      ctrl.startDownload('f1', 'a.pdf', 'application/pdf', 100);
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 50, total: 100),
      );
      // f2: 已下载(done)
      ctrl.startDownload('f2', 'b.pdf', 'application/pdf', 100);
      service.emit(
        'f2',
        const DownloadProgress(fileId: 'f2', received: 100, total: 100, done: true),
      );
      await tester.pumpAndSettle();
      final snap = ctrl.buildSnapshots();
      expect(snap, isNotNull);
      expect(snap!['f1']?.state, 1);
      expect(snap['f1']?.progress, 0.5);
      expect(snap['f2']?.state, 2);
      service.disposeAll();
    });
  });

  group('onFileTap', () {
    testWidgets('已下载 → 调 openLocalFile(验证 getLocalPath 调用)', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      // 先把 f1 标记为已下载
      ctrl.startDownload('f1', 'name.pdf', 'application/pdf', 100);
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 100, total: 100, done: true),
      );
      await tester.pumpAndSettle();
      service.getLocalPathCalls.clear();

      // 点击已下载文件 → openLocalFile
      ctrl.onFileTap('f1', 'name.pdf', 'application/pdf', 100);
      await tester.pumpAndSettle();
      expect(service.getLocalPathCalls, contains('f1'));
      service.disposeAll();
    });

    testWidgets('下载中 → 调 cancelDownload(验证 service.cancel)', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      // f1 进入下载中
      ctrl.startDownload('f1', 'name.pdf', 'application/pdf', 100);
      // 点击下载中文件 → cancelDownload(onFileTap 里 fire-and-forget)
      ctrl.onFileTap('f1', 'name.pdf', 'application/pdf', 100);
      // onFileTap 不 await cancelDownload,testWidgets 的 FakeAsync 会拦住
      // sub.cancel() 的 timer;用 runAsync 走真实事件循环让 detached Future 跑完。
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
      expect(service.cancelledFileIds, contains('f1'));
      // cancelDownload 清掉 _downloadProgress → buildSnapshots 返 null
      expect(ctrl.buildSnapshots(), isNull);
      service.disposeAll();
    });

    testWidgets('未下载 → 弹 DownloadConfirmSheet', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      ctrl.onFileTap('f1', 'report.pdf', 'application/pdf', 2048);
      await tester.pumpAndSettle();
      // DownloadConfirmSheet 里有「下载」「取消」两个 ListTile
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      service.disposeAll();
    });
  });

  group('cancelDownload', () {
    test('取消订阅 + onSetState 触发 + service.cancel 调用', () async {
      final service = _FakeFileDownloadService();
      var setStateCalls = 0;
      final ctrl = FileDownloadController(_buildContext(
        service: service,
        onSetState: (cb) {
          setStateCalls++;
          cb();
        },
      ));
      ctrl.startDownload('f1', 'n', 'm', 10);
      final setStateBefore = setStateCalls;
      await ctrl.cancelDownload('f1');
      // cancelDownload 内部 onSetState 一次(清 _downloadProgress)
      expect(setStateCalls, setStateBefore + 1);
      expect(service.cancelledFileIds, contains('f1'));
      expect(ctrl.buildSnapshots(), isNull);
      service.disposeAll();
    });
  });

  group('startDownload', () {
    testWidgets('done 事件 → 进度清 + downloaded.add + openLocalFile',
        (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      ctrl.startDownload('f1', 'name.pdf', 'application/pdf', 100);
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 100, total: 100, done: true),
      );
      await tester.pumpAndSettle();
      final snap = ctrl.buildSnapshots();
      expect(snap, isNotNull);
      expect(snap!['f1']?.state, 2); // 已下载
      expect(service.getLocalPathCalls, contains('f1'));
      service.disposeAll();
    });

    testWidgets('error 事件 → 进度清 + SnackBar', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      ctrl.startDownload('f1', 'name.pdf', 'application/pdf', 100);
      service.emit(
        'f1',
        const DownloadProgress(
          fileId: 'f1',
          received: 0,
          total: 1,
          error: 'network down',
        ),
      );
      await tester.pumpAndSettle();
      // error 分支清进度
      final snap = ctrl.buildSnapshots();
      expect(snap, isNull);
      // SnackBar 文本包含错误信息
      expect(find.textContaining('下载失败'), findsOneWidget);
      service.disposeAll();
    });

    test('progress 事件 → _downloadProgress 更新', () {
      final service = _FakeFileDownloadService();
      final ctrl = FileDownloadController(_buildContext(service: service));
      ctrl.startDownload('f1', 'n', 'm', 100);
      // 初始 progress=0
      expect(ctrl.buildSnapshots()?['f1']?.progress, 0);
      // 推 30%
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 30, total: 100),
      );
      expect(ctrl.buildSnapshots()?['f1']?.progress, 0.3);
      // 推 70%
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 70, total: 100),
      );
      expect(ctrl.buildSnapshots()?['f1']?.progress, 0.7);
      service.disposeAll();
    });

    test('isMounted 返 false 时,流事件被忽略(不做任何 setState)', () {
      final service = _FakeFileDownloadService();
      var mounted = true;
      var setStateCalls = 0;
      final ctrl = FileDownloadController(_buildContext(
        service: service,
        isMounted: () => mounted,
        onSetState: (cb) {
          setStateCalls++;
          cb();
        },
      ));
      ctrl.startDownload('f1', 'n', 'm', 100);
      final countBefore = setStateCalls;
      // 模拟 widget unmount
      mounted = false;
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 50, total: 100),
      );
      expect(setStateCalls, countBefore,
          reason: 'unmount 后 progress 事件不应触发 setState');
      // done 事件也不应触发
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 100, total: 100, done: true),
      );
      expect(setStateCalls, countBefore, reason: 'unmount 后 done 也不触发');
      service.disposeAll();
    });
  });

  group('dispose', () {
    test('取消所有订阅(后续 stream 事件不触发 setState)', () async {
      final service = _FakeFileDownloadService();
      var setStateCalls = 0;
      final ctrl = FileDownloadController(_buildContext(
        service: service,
        onSetState: (cb) {
          setStateCalls++;
          cb();
        },
      ));
      ctrl.startDownload('f1', 'n', 'm', 10);
      final countBefore = setStateCalls;
      ctrl.dispose();
      // dispose 后推事件 → 监听器应已取消,不触发 setState
      service.emit(
        'f1',
        const DownloadProgress(fileId: 'f1', received: 50, total: 100),
      );
      await Future<void>.delayed(Duration.zero);
      expect(setStateCalls, countBefore,
          reason: 'dispose 后流事件不应再触发 setState');
      service.disposeAll();
    });

    test('无活动订阅时调用安全(不抛)', () {
      final service = _FakeFileDownloadService();
      final ctrl = FileDownloadController(_buildContext(service: service));
      ctrl.dispose();
      // 不抛即通过
      expect(ctrl.buildSnapshots(), isNull);
    });
  });

  group('showDownloadSheet', () {
    testWidgets('确认回调触发 startDownload(进入下载态)', (tester) async {
      final service = _FakeFileDownloadService();
      late FileDownloadController ctrl;
      await _pumpHarness(tester, (ctx) {
        ctrl = FileDownloadController(_buildContext(
          service: service,
          getContext: () => ctx,
        ));
      });
      ctrl.showDownloadSheet('f1', 'report.pdf', 'application/pdf', 1024);
      await tester.pumpAndSettle();
      // 点「下载」ListTile
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      // 确认进入下载态(progress=0)
      final snap = ctrl.buildSnapshots();
      expect(snap, isNotNull);
      expect(snap!['f1']?.state, 1);
      expect(snap['f1']?.progress, 0);
      service.disposeAll();
    });
  });
}
