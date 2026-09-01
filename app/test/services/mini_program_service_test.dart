import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/services/mini_program_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';

Uint8List buildZip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = Uint8List.fromList(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// 测试内 ed25519 helper:与实现同用 cryptography 包,向量自足不依赖 server。
/// 固定 seed 保证用例可复现。
final Ed25519 _ed25519 = Ed25519();

Future<(SimpleKeyPair, String)> _newKeyPair() async {
  final pair = await _ed25519
      .newKeyPairFromSeed(Uint8List.fromList(List.filled(32, 0x07)));
  final pub = await pair.extractPublicKey();
  return (pair, _hex(pub.bytes));
}

Future<String> _signHex(SimpleKeyPair pair, Uint8List data) async {
  final sig = await _ed25519.sign(data, keyPair: pair);
  return _hex(sig.bytes);
}

/// 返回原始 zip 字节(不经 JSON 编码,保二进制完整)。
class _RawPackageAdapter implements HttpClientAdapter {
  _RawPackageAdapter(this.bytes);
  final Uint8List bytes;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromBytes(bytes, 200);
}

/// 按 path 分流:signing-key 返 envelope JSON,package 返原始 zip。
/// 记录全部请求路径供断言。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.zipBytes, this.pubHex);
  final Uint8List zipBytes;
  final String pubHex;
  final List<String> paths = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.toString());
    if (options.uri.path.contains('signing-key')) {
      return ResponseBody.fromString(
        jsonEncode({'ok': true, 'data': {'public_key': pubHex}}),
        200,
        headers: const {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(zipBytes, 200);
  }
}

/// 内存 KVS fake:其余方法全部 noop。
class _FakeStore extends NoopLocalMessageStore {
  _FakeStore([this.pub]);
  String? pub;
  var putCount = 0;

  @override
  Future<String?> getMpSigningPubKey() async => pub;

  @override
  Future<void> putMpSigningPubKey(String pubHex) async {
    pub = pubHex;
    putCount++;
  }
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

MiniProgramInfo _mp(String sha, {String? signature}) => MiniProgramInfo(
      id: 'mp1',
      appid: 'app.test',
      ownerId: 'u1',
      name: 't',
      version: 1,
      status: 'published',
      sha256: sha,
      size: 0,
      signature: signature,
    );

void main() {
  group('isSafeEntryName', () {
    test('拒绝绝对路径/穿越/反斜杠', () {
      expect(MiniProgramService.isSafeEntryName('/etc/passwd'), isFalse);
      expect(MiniProgramService.isSafeEntryName('../evil.js'), isFalse);
      expect(MiniProgramService.isSafeEntryName('a\\b.js'), isFalse);
      expect(MiniProgramService.isSafeEntryName('js/app.js'), isTrue);
      expect(MiniProgramService.isSafeEntryName('index.html'), isTrue);
    });
  });

  group('verifySha256', () {
    test('匹配通过,不匹配抛异常', () {
      final bytes = Uint8List.fromList('hello'.codeUnits);
      // sha256('hello') = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
      MiniProgramService.verifySha256(bytes,
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
      expect(
        () => MiniProgramService.verifySha256(bytes, 'deadbeef'),
        throwsA(anything),
      );
    });
  });

  group('extractPackage', () {
    test('解压到目标目录,目录结构保留', () async {
      final dir = await Directory.systemTemp.createTemp('mp_extract_test');
      addTearDown(() => dir.delete(recursive: true));
      final zip = buildZip({
        'index.html': '<html></html>'.codeUnits,
        'js/app.js': 'console.log(1)'.codeUnits,
      });
      await MiniProgramService.extractPackage(zip, dir);
      expect(File('${dir.path}/index.html').existsSync(), isTrue);
      expect(File('${dir.path}/js/app.js').existsSync(), isTrue);
    });

    test('包内路径穿越条目直接抛异常,不落盘', () async {
      final dir = await Directory.systemTemp.createTemp('mp_extract_test');
      addTearDown(() => dir.delete(recursive: true));
      final zip = buildZip({
        'index.html': 'x'.codeUnits,
        '../evil.js': 'x'.codeUnits,
      });
      expect(
        () => MiniProgramService.extractPackage(zip, dir),
        throwsA(anything),
      );
    });
  });

  group('verifyEd25519', () {
    test('正确签名通过/篡改失败/坏 hex 返 false', () async {
      final data = Uint8List.fromList('pkg-bytes'.codeUnits);
      final (pair, pubHex) = await _newKeyPair();
      final sigHex = await _signHex(pair, data);

      expect(
        await MiniProgramService.verifyEd25519(
            data: data, pubHex: pubHex, sigHex: sigHex),
        isTrue,
      );

      final tampered = Uint8List.fromList(data)..[0] ^= 0xFF;
      expect(
        await MiniProgramService.verifyEd25519(
            data: tampered, pubHex: pubHex, sigHex: sigHex),
        isFalse,
      );

      expect(
        await MiniProgramService.verifyEd25519(
            data: data, pubHex: 'zz', sigHex: sigHex),
        isFalse,
      );
    });

    test('公钥/签名长度不符返 false,不抛', () async {
      final data = Uint8List.fromList('pkg-bytes'.codeUnits);
      final (_, pubHex) = await _newKeyPair();
      expect(
        await MiniProgramService.verifyEd25519(
            data: data, pubHex: pubHex, sigHex: 'aa'),
        isFalse,
      );
    });
  });

  group('install 验签集成', () {
    late Directory docsDir;

    setUp(() async {
      docsDir = await Directory.systemTemp.createTemp('mp_install_test');
      addTearDown(() => docsDir.delete(recursive: true));
      PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    });

    test('有效签名(store 缓存命中)→ 安装成功,不触 signing-key API', () async {
      final zip = buildZip({'index.html': 'x'.codeUnits});
      final (pair, pubHex) = await _newKeyPair();
      final sigHex = await _signHex(pair, zip);

      final adapter = _RoutingAdapter(zip, pubHex);
      final dio = Dio()..httpClientAdapter = adapter;
      final service = MiniProgramService(
        baseUrl: 'http://test',
        token: 't',
        store: _FakeStore(pubHex),
        dio: dio,
      );
      final dir = await service
          .install(_mp(crypto.sha256.convert(zip).toString(), signature: sigHex));

      expect(File('${dir.path}/index.html').existsSync(), isTrue);
      expect(
        adapter.paths.where((p) => p.contains('signing-key')),
        isEmpty,
      );
    });

    test('篡改签名 → StateError,安装失败(重拉同钥二次失败)', () async {
      final zip = buildZip({'index.html': 'x'.codeUnits});
      final (pair, pubHex) = await _newKeyPair();
      final sigHex = await _signHex(pair, zip);
      final tampered = Uint8List.fromList(zip)..[0] ^= 0xFF;

      final service = MiniProgramService(
        baseUrl: 'http://test',
        token: 't',
        store: _FakeStore(pubHex),
        dio: Dio()..httpClientAdapter = _RoutingAdapter(tampered, pubHex),
      );
      await expectLater(
        service.install(
            _mp(crypto.sha256.convert(tampered).toString(), signature: sigHex)),
        throwsA(isA<StateError>()),
      );
    });

    test('signature null → 过渡期放行,安装成功', () async {
      final zip = buildZip({'index.html': 'x'.codeUnits});
      final service = MiniProgramService(
        baseUrl: 'http://test',
        token: 't',
        store: _FakeStore(),
        dio: Dio()..httpClientAdapter = _RawPackageAdapter(zip),
      );
      final dir = await service
          .install(_mp(crypto.sha256.convert(zip).toString()));
      expect(File('${dir.path}/index.html').existsSync(), isTrue);
    });

    test('轮换自愈:缓存钥与包签名不匹配 → 绕缓存重拉一次后成功', () async {
      final zip = buildZip({'index.html': 'x'.codeUnits});
      // 包用钥 A 签,store 缓存的是钥 B → 首验必失败,重拉后用 A 通过
      final (oldPair, oldPubHex) = await _newKeyPair();
      final newPair = await _ed25519
          .newKeyPairFromSeed(Uint8List.fromList(List.filled(32, 0x08)));
      final newPubHex = _hex((await newPair.extractPublicKey()).bytes);
      final sigHex = await _signHex(oldPair, zip);

      final adapter = _RoutingAdapter(zip, oldPubHex);
      final service = MiniProgramService(
        baseUrl: 'http://test',
        token: 't',
        store: _FakeStore(newPubHex),
        dio: Dio()..httpClientAdapter = adapter,
      );

      final dir = await service
          .install(_mp(crypto.sha256.convert(zip).toString(), signature: sigHex));
      expect(File('${dir.path}/index.html').existsSync(), isTrue);
      // 首次缓存命中,自愈重拉 = signing-key 恰好请求一次
      expect(
        adapter.paths.where((p) => p.contains('signing-key')).length,
        1,
      );
    });

    test('fetchSigningPublicKey:store 为 null 时直拉 API 并返 envelope 公钥', () async {
      final (_, pubHex) = await _newKeyPair();
      final adapter = _RoutingAdapter(buildZip({}), pubHex);
      final service = MiniProgramService(
        baseUrl: 'http://test',
        token: 't',
        dio: Dio()..httpClientAdapter = adapter,
      );
      expect(await service.fetchSigningPublicKey(), pubHex);
    });
  });
}