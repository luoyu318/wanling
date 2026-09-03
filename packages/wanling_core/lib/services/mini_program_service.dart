import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/services/local_message_store_abstract.dart';

/// 小程序本地包管理:下载(带登录态)→ sha256 校验 → ed25519 验签 → 解压到
/// documents/miniprograms/<appid>/<version>/(原子替换),打开时静默更新。
/// 纯函数(校验/解压)做成 static,便于无平台通道单测。
class MiniProgramService {
  final String baseUrl;
  final String token;
  final Dio _dio;

  /// 签名公钥 KVS 缓存,null = 跳过缓存直拉 API。
  final LocalMessageStore? _store;

  static final Ed25519 _ed25519 = Ed25519();

  MiniProgramService({
    required this.baseUrl,
    required this.token,
    LocalMessageStore? store,
    // 测试注入:默认自建;注入后不走登录态 header,由调用方接管
    Dio? dio,
  })  : _store = store,
        _dio = dio ??
            Dio(BaseOptions(
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

  /// ed25519 验签:server 下发裸 32 字节公钥 hex + 裸 64 字节签名 hex。
  /// 任何输入异常(hex 非法/长度不符/验签抛错)一律返 false 不抛——
  /// 验签失败是安全决策结果而非程序异常,调用方据 bool 分流。
  static Future<bool> verifyEd25519({
    required Uint8List data,
    required String pubHex,
    required String sigHex,
  }) async {
    try {
      final pub = _tryHexDecode(pubHex);
      final sig = _tryHexDecode(sigHex);
      if (pub == null || sig == null) return false;
      if (pub.length != 32 || sig.length != 64) return false;
      final signature = Signature(
        sig,
        publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519),
      );
      return await _ed25519.verify(data, signature: signature);
    } catch (_) {
      return false;
    }
  }

  static List<int>? _tryHexDecode(String hex) {
    if (hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final hi = _hexVal(hex.codeUnitAt(i * 2));
      final lo = _hexVal(hex.codeUnitAt(i * 2 + 1));
      if (hi < 0 || lo < 0) return null;
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10; // A-F
    return -1;
  }

  /// 验签公钥:store 缓存命中直接返回;未命中(或 store 为 null)拉 API 并写缓存。
  /// [forceRefresh] 绕过缓存强制重拉(公钥轮换自愈用)。
  /// API 失败抛出(fail fast),由调用方决定降级。
  Future<String> fetchSigningPublicKey({bool forceRefresh = false}) async {
    if (!forceRefresh && _store != null) {
      final cached = await _store.getMpSigningPubKey();
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final res =
        await _dio.get<Map<String, dynamic>>('/api/mini-programs/signing-key');
    // 本 service 的 dio 不经 ApiService 拦截器,手动剥 envelope {ok, data}
    final data = res.data?['data'];
    final pub = data is Map<String, dynamic> ? data['public_key'] : null;
    if (pub is! String || pub.isEmpty) {
      throw StateError('signing-key 响应缺少 public_key');
    }
    await _store?.putMpSigningPubKey(pub);
    return pub;
  }

  /// 包签名校验:存在必验 / 缺失放行(过渡策略,旧包无 signature 字段)。
  /// 首验走缓存且失败 → 绕缓存重拉一次公钥再验(公钥轮换自愈);两次都失败才抛。
  Future<void> _verifySignature(Uint8List bytes, MiniProgramInfo mp) async {
    final sig = mp.signature;
    if (sig == null || sig.isEmpty) {
      debugPrint('[mini_program] 包无签名,过渡期放行: ${mp.appid}');
      return;
    }
    final cached = await _store?.getMpSigningPubKey();
    final usedCache = cached != null && cached.isNotEmpty;
    final pub = usedCache ? cached : await fetchSigningPublicKey();
    if (await verifyEd25519(data: bytes, pubHex: pub, sigHex: sig)) return;
    if (usedCache) {
      final fresh = await fetchSigningPublicKey(forceRefresh: true);
      if (await verifyEd25519(data: bytes, pubHex: fresh, sigHex: sig)) return;
    }
    throw StateError('签名验证失败');
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

  /// 安装/更新:下载 → sha256 → ed25519 验签 → 解压到 .tmp → 原子换目录 → 清理旧版本。
  Future<Directory> install(MiniProgramInfo mp) async {
    final res = await _dio.get<List<int>>(
      '/api/mini-programs/${mp.id}/package',
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(res.data!);
    verifySha256(bytes, mp.sha256);
    await _verifySignature(bytes, mp);

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

  /// 直传 zip 文件建/换私有小程序(POST /api/mini-programs multipart)。
  Future<void> uploadPackage(String filePath) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath,
          filename: p.basename(filePath)),
    });
    await _dio.post('/api/mini-programs', data: form);
  }

  /// 删除自己的私有小程序(server 端;非 owner/private 会 4xx fail fast)。
  Future<void> deleteRemote(String id) async {
    await _dio.delete('/api/mini-programs/$id');
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