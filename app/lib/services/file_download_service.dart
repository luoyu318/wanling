import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// 单次下载进度事件。
class DownloadProgress {
  final String fileId;
  final int received;
  final int total;
  final bool done;
  final String? error;

  const DownloadProgress({
    required this.fileId,
    required this.received,
    required this.total,
    this.done = false,
    this.error,
  });

  /// 0.0 - 1.0，total 为 0 时返回 0 避免除零。
  double get fraction => total > 0 ? received / total : 0;
}

/// 文件下载管理器。
/// - 下载到 app persistent 目录 (getApplicationDocumentsDirectory/downloads)
/// - 进度通过 Stream 暴露给 FileCard 订阅
/// - 支持取消（按 fileId）
/// - getLocalPath 返回本地路径（已下载）或 null
class FileDownloadService {
  final String baseUrl;
  final String token;
  final Dio _dio;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, String> _localPaths = {};

  FileDownloadService({required this.baseUrl, required this.token})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          headers: {'Authorization': 'Bearer $token'},
        ));

  Future<String> _downloadDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final dl = Directory('${dir.path}/downloads');
    if (!await dl.exists()) await dl.create(recursive: true);
    return dl.path;
  }

  /// 带进度回调的下载。返回 Stream 让 UI 订阅进度更新。
  /// 完成时发 done=true 事件后关闭流。
  /// 取消时静默关闭流（不发 error，调用方据 stream 是否完成判断）。
  Stream<DownloadProgress> downloadWithProgress(String fileId) {
    // 防御性 fileId 校验：避免恶意 file_id (如 ../etc/passwd) 拼路径写文件。
    // server UUID 是 [0-9a-f-]+ 格式，正则覆盖 UUID + 极少数历史路径，余者一律拒绝。
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(fileId)) {
      final controller = StreamController<DownloadProgress>();
      controller.add(DownloadProgress(
        fileId: fileId,
        received: 0,
        total: 1,
        error: 'invalid fileId format',
      ));
      controller.close();
      return controller.stream;
    }

    final cancelToken = CancelToken();
    _cancelTokens[fileId] = cancelToken;
    final controller = StreamController<DownloadProgress>();

    () async {
      try {
        final dir = await _downloadDir();
        final path = '$dir/$fileId';
        await _dio.download(
          '/api/files/$fileId',
          path,
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            controller.add(DownloadProgress(
              fileId: fileId,
              received: received,
              total: total,
            ));
          },
        );
        _localPaths[fileId] = path;
        controller.add(DownloadProgress(
          fileId: fileId, received: 1, total: 1, done: true));
        await controller.close();
      } on DioException catch (e) {
        if (!CancelToken.isCancel(e)) {
          controller.add(DownloadProgress(
            fileId: fileId,
            received: 0,
            total: 1,
            error: e.message ?? e.toString(),
          ));
        }
        await controller.close();
      } catch (e) {
        controller.add(DownloadProgress(
          fileId: fileId, received: 0, total: 1, error: e.toString()));
        await controller.close();
      }
    }();

    return controller.stream;
  }

  /// 取消下载。
  Future<void> cancel(String fileId) async {
    _cancelTokens[fileId]?.cancel();
    _cancelTokens.remove(fileId);
  }

  /// 已下载则返回本地路径，否则 null。
  /// 同时检查内存 cache 和磁盘文件。
  Future<String?> getLocalPath(String fileId) async {
    if (_localPaths.containsKey(fileId)) return _localPaths[fileId];
    try {
      final dir = await _downloadDir();
      final path = '$dir/$fileId';
      if (await File(path).exists()) {
        _localPaths[fileId] = path;
        return path;
      }
    } catch (_) {
      // path_provider 在测试环境可能失败，静默返回 null
    }
    return null;
  }

  /// 删除本地已下载文件。
  Future<void> deleteLocal(String fileId) async {
    _localPaths.remove(fileId);
    try {
      final dir = await _downloadDir();
      await File('$dir/$fileId').delete();
    } catch (_) {}
  }
}
