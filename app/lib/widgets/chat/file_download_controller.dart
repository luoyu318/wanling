import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../rendering/message_content_renderer.dart' show FileDownloadSnapshot;
import '../../services/file_download_service.dart'
    show DownloadProgress, FileDownloadService;
import '../../utils/snackbar.dart' show showAppSnackBar, SnackBarType;
import 'download_confirm_sheet.dart' show DownloadConfirmSheet;

/// [FileDownloadController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性(mock 本对象即可单测)。
@immutable
class FileDownloadContext {
  /// showAppSnackBar / showModalBottomSheet。
  final BuildContext Function() getContext;

  /// 进度/完成/取消时 setState。
  final void Function(VoidCallback) onSetState;

  /// 流回调里替代 widget.mounted。
  final bool Function() isMounted;

  /// 下载服务(已含 baseUrl + token)。
  final FileDownloadService downloadService;

  const FileDownloadContext({
    required this.getContext,
    required this.onSetState,
    required this.isMounted,
    required this.downloadService,
  });
}

/// 文件下载的状态 + 行为控制器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的文件下载相关字段(_downloadProgress / _downloaded /
/// _downloadSubs)和 7 个方法(buildSnapshots / onFileTap / cancelDownload /
/// showDownloadSheet / startDownload / openLocalFile / dispose)。
/// chat_page 在 initState 创建,dispose 释放。
///
/// 跨职责字段(实际下载服务实例)通过 [FileDownloadContext.downloadService] 注入。
class FileDownloadController {
  final FileDownloadContext _ctx;

  FileDownloadController(this._ctx);

  /// fileId → 当前下载进度 (0.0-1.0)。null(key 缺失)表示不在下载中。
  /// 由 startDownload 维护,itemBuilder 构造 fileDownloadSnapshots 时读。
  final Map<String, double> _downloadProgress = {};

  /// fileId → true 表示已下载完成。FileCard 显示「已下载」状态 + 点击直接打开。
  final Set<String> _downloaded = {};

  /// 下载流订阅(用于 dispose 时取消,防止 setState after dispose)。
  final Map<String, StreamSubscription<DownloadProgress>> _downloadSubs = {};

  /// 构造当前下载状态快照表。每次 itemBuilder 触发时调用,
  /// 传入 MessageRow → MessageBubble → FileContentRenderer,决定 FileCard 渲染态。
  /// 仅在有进行中/已完成下载时构造非空 map,避免无文件消息场景的内存开销。
  /// 两个 map 都空时返 null(itemBuilder 跳过重建)。
  Map<String, FileDownloadSnapshot>? buildSnapshots() {
    if (_downloadProgress.isEmpty && _downloaded.isEmpty) return null;
    final map = <String, FileDownloadSnapshot>{};
    for (final entry in _downloadProgress.entries) {
      map[entry.key] = FileDownloadSnapshot(state: 1, progress: entry.value);
    }
    for (final fileId in _downloaded) {
      // 已下载优先级高于进行中(理论上不会同时存在,但取最新态)
      map[fileId] = const FileDownloadSnapshot(state: 2);
    }
    return map;
  }

  /// 文件点击统一入口:按当前状态分支决定行为。
  /// - 已下载:打开本地文件
  /// - 下载中:取消下载
  /// - 未下载:弹底部确认 sheet
  void onFileTap(
    String fileId,
    String filename,
    String mimeType,
    int fileSize,
  ) {
    if (_downloaded.contains(fileId)) {
      openLocalFile(fileId);
    } else if (_downloadProgress.containsKey(fileId)) {
      cancelDownload(fileId);
    } else {
      showDownloadSheet(fileId, filename, mimeType, fileSize);
    }
  }

  /// 取消进行中的下载。
  Future<void> cancelDownload(String fileId) async {
    await _downloadSubs[fileId]?.cancel();
    _downloadSubs.remove(fileId);
    _ctx.onSetState(() {
      _downloadProgress.remove(fileId);
    });
    await _ctx.downloadService.cancel(fileId);
  }

  /// 弹底部下载确认 sheet。展示文件名/大小/类型图标,提供「下载」「取消」入口。
  /// sheet 内容用 [DownloadConfirmSheet] widget(Task 3.1)。
  void showDownloadSheet(
    String fileId,
    String filename,
    String mimeType,
    int fileSize,
  ) {
    showModalBottomSheet(
      context: _ctx.getContext(),
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => DownloadConfirmSheet(
        filename: filename,
        mimeType: mimeType,
        fileSize: fileSize,
        onConfirm: () {
          Navigator.pop(ctx);
          startDownload(fileId, filename, mimeType, fileSize);
        },
      ),
    );
  }

  /// 启动下载:立即 setState 进 downloading 态,订阅进度流。
  /// 完成自动调 openLocalFile;失败弹 SnackBar;取消静默清理进度。
  void startDownload(
    String fileId,
    String filename,
    String mimeType,
    int fileSize,
  ) {
    // 立即更新 UI 进入 downloading 态(progress=0),让 FileCard 切换为「下载中」+ 取消按钮。
    _ctx.onSetState(() {
      _downloadProgress[fileId] = 0;
    });

    // 取消旧订阅(理论上不会发生,但防御性清理)
    _downloadSubs[fileId]?.cancel();

    final sub = _ctx.downloadService
        .downloadWithProgress(fileId)
        .listen(
          (progress) {
            if (!_ctx.isMounted()) return;
            if (progress.done) {
              _ctx.onSetState(() {
                _downloadProgress.remove(fileId);
                _downloaded.add(fileId);
              });
              _downloadSubs.remove(fileId);
              openLocalFile(fileId);
            } else if (progress.error != null) {
              _ctx.onSetState(() {
                _downloadProgress.remove(fileId);
              });
              _downloadSubs.remove(fileId);
              showAppSnackBar(
                _ctx.getContext(),
                '下载失败: ${progress.error}',
                type: SnackBarType.error,
              );
            } else {
              _ctx.onSetState(() {
                _downloadProgress[fileId] = progress.fraction;
              });
            }
          },
          onDone: () {
            _downloadSubs.remove(fileId);
            // 流结束但未标记 done/未清进度(罕见,比如取消路径),兜底清理。
            if (_downloadProgress.containsKey(fileId) &&
                !_downloaded.contains(fileId) &&
                _ctx.isMounted()) {
              _ctx.onSetState(() {
                _downloadProgress.remove(fileId);
              });
            }
          },
          onError: (e) {
            _downloadSubs.remove(fileId);
            if (!_ctx.isMounted()) return;
            _ctx.onSetState(() {
              _downloadProgress.remove(fileId);
            });
            showAppSnackBar(_ctx.getContext(), '下载失败: $e', type: SnackBarType.error);
          },
        );
    _downloadSubs[fileId] = sub;
  }

  /// 打开已下载文件。无本地路径(罕见,磁盘被清)→ SnackBar 提示。
  Future<void> openLocalFile(String fileId) async {
    final path = await _ctx.downloadService.getLocalPath(fileId);
    if (path == null) {
      if (_ctx.isMounted()) {
        showAppSnackBar(_ctx.getContext(), '文件未找到', type: SnackBarType.error);
      }
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && _ctx.isMounted()) {
      showAppSnackBar(
        _ctx.getContext(),
        '无法打开: ${result.message}',
        type: SnackBarType.error,
      );
    }
  }

  /// 取消所有流订阅(chat_page dispose 时调)。
  void dispose() {
    for (final sub in _downloadSubs.values) {
      sub.cancel();
    }
    _downloadSubs.clear();
  }
}
