import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:wanling_core/models/mini_program_info.dart';

/// 小程序本地包管理:下载(带登录态)→ sha256 校验 → 解压到
/// documents/miniprograms/<appid>/<version>/(原子替换),打开时静默更新。
/// 纯函数(校验/解压)做成 static,便于无平台通道单测。
class MiniProgramService {
  final String baseUrl;
  final String token;
  final Dio _dio;

  MiniProgramService({required this.baseUrl, required this.token})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          headers: {'Authorization': 'Bearer $token'},
          // dio 5.x 无 maxResponseSize,包大小由 server 端 MaxBytesReader 兜底
          receiveTimeout: const Duration(minutes: 2),
        ));

  /// zip 条目名安全校验:拒绝绝对路径、.. 穿越、反斜杠。
  static bool isSafeEntryName(String name) {
    if (name.startsWith('/') || name.startsWith(r'\')) return false;
    if (name.contains(r'\')) return false;
    if (name.contains('..')) return false;
    return true;
  }

  /// sha256 校验,不匹配抛 StateException(fail fast,严禁跳过安装)。
  static void verifySha256(Uint8List bytes, String expected) {
    final actual = crypto.sha256.convert(bytes).toString();
    if (actual != expected) {
      throw StateError('sha256 不匹配: 期望 $expected 实际 $actual');
    }
  }

  /// 解压到 destDir(必须已存在)。任一条目名不安全即整包失败。
  static Future<Directory> extractPackage(
    Uint8List bytes,
    Directory destDir,
  ) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      if (!isSafeEntryName(file.name)) {
        throw StateError('包内存在非法路径: ${file.name}');
      }
    }
    for (final file in archive) {
      final target = p.normalize(p.join(destDir.path, file.name));
      if (!p.isWithin(destDir.path, target)) {
        throw StateError('解压路径越界: ${file.name}');
      }
      if (file.isFile) {
        final f = File(target);
        await f.create(recursive: true);
        await f.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(target).create(recursive: true);
      }
    }
    return destDir;
  }

  Future<Directory> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'miniprograms'));
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  /// 安装/更新:下载 → sha256 → 解压到 .tmp → 原子换目录 → 清理旧版本。
  Future<Directory> install(MiniProgramInfo mp) async {
    final res = await _dio.get<List<int>>(
      '/api/mini-programs/${mp.id}/package',
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(res.data!);
    verifySha256(bytes, mp.sha256);

    final root = await _rootDir();
    final appDir = Directory(p.join(root.path, mp.appid));
    final tmp = Directory(p.join(root.path, '${mp.appid}.tmp'));
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
    await tmp.create(recursive: true);
    await extractPackage(bytes, tmp);

    final dest = Directory(p.join(appDir.path, '${mp.version}'));
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await appDir.create(recursive: true);
    await tmp.rename(dest.path);

    // 清理旧版本目录
    await for (final e in appDir.list()) {
      if (e is Directory && p.basename(e.path) != '${mp.version}') {
        await e.delete(recursive: true);
      }
    }
    return dest;
  }

  /// 本地已装版本目录;未安装返回 null。
  Future<Directory?> installedDir(String appid, int version) async {
    final root = await _rootDir();
    final dir = Directory(p.join(root.path, appid, '$version'));
    return await dir.exists() ? dir : null;
  }

  /// 卸载:删除本地包目录(APP 侧同时清 WebView storage)。
  Future<void> removeLocal(String appid) async {
    final root = await _rootDir();
    final dir = Directory(p.join(root.path, appid));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}