// 小程序 WebView 容器页。
// origin 隔离:每小程序独立虚拟域名 https://<appid>.mini.wanling.local,
// 静态文件由 shouldInterceptRequest 从本地包目录读取;token 不进 JS,
// JS 侧经 window.wanling.request → JSBridge → ApiService.proxyRequest。
// 模板: templates/flutter-page.dart.tmpl(controller 分离/const+key/loading+error UI)。
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import 'package:app/services/mini_program_bridge.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/mini_program_service.dart';
import 'package:wanling_core/services/secure_storage.dart';

/// 注入 window.wanling:request/close 两个桥,底层走 flutter_inappwebview callHandler。
const _jsBridgeBootstrap = """
window.wanling = {
  request: function(opts) {
    return window.flutter_inappwebview
        .callHandler('wanlingRequest', opts)
        .then(function(r) {
          if (r && r.ok) return r.data;
          throw new Error((r && r.error) || 'request failed');
        });
  },
  close: function() {
    return window.flutter_inappwebview.callHandler('wanlingClose');
  }
};
""";

/// 将虚拟域 URL path 解析为包内本地文件;越出包根(含 `../` 越界)返回 null。
/// zip-slip 第二层防护(第一层在安装解压时)。[pkgRoot] 为包根目录
/// (install/installedDir 返回值),虚拟域 `/` 与包根一一对应。
String? resolveLocalFile(String pkgRoot, String requestPath) {
  final relClean = <String>[];
  for (final seg in requestPath.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (relClean.isEmpty) return null;
      relClean.removeLast();
      continue;
    }
    relClean.add(seg);
  }
  final filePath = p.normalize(p.join(pkgRoot, p.joinAll(relClean)));
  // 包根目录本身放行(命中目录由调用方走 404),其余越出即拒绝
  if (filePath != pkgRoot && !p.isWithin(pkgRoot, filePath)) {
    return null;
  }
  return filePath;
}

/// 扩展名 → MIME,未命中回退 octet-stream。
String _mimeOf(String path) {
  const map = {
    '.html': 'text/html',
    '.js': 'application/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.webp': 'image/webp',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
  };
  return map[p.extension(path).toLowerCase()] ?? 'application/octet-stream';
}

class MiniProgramPage extends ConsumerStatefulWidget {
  final String appid;
  const MiniProgramPage({super.key, required this.appid});

  @override
  ConsumerState<MiniProgramPage> createState() => _MiniProgramPageState();
}

class _MiniProgramPageState extends ConsumerState<MiniProgramPage> {
  InAppWebViewController? _controller;
  MiniProgramBridge? _bridge;
  String? _pkgRoot;
  String? _entryPath;
  bool _starting = false;
  String? _error;

  String get _virtualHost => '${widget.appid}.mini.wanling.local';

  MiniProgramInfo? _findInfo(List<MiniProgramInfo> list) {
    for (final m in list) {
      if (m.appid == widget.appid) return m;
    }
    return null;
  }

  /// 只加载一次:onWebViewCreated 后 bridge/handler 已注册完成,直接 loadUrl。
  /// token 现取(TokenVault),未装/版本旧 → 安装/静默更新。
  Future<void> _start(MiniProgramInfo info) async {
    if (_starting) return;
    _starting = true;
    try {
      final token = await TokenVault.getAccessToken();
      if (token == null) throw StateError('未登录');
      final service =
          MiniProgramService(baseUrl: ref.read(apiProvider).baseUrl, token: token);
      var dir = await service.installedDir(info.appid, info.version);
      dir ??= await service.install(info);
      _pkgRoot = dir.path;
      _entryPath = p.join(_pkgRoot!, info.entry);

      _bridge = MiniProgramBridge(
        permissions: info.permissions.toSet(),
        proxy: (path, method, body) =>
            ref.read(apiProvider).proxyRequest(path, method: method, body: body),
        onClose: () => context.pop(),
      );
      await _controller?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri('https://$_virtualHost/${info.entry}'),
        ),
      );
    } catch (e) {
      debugPrint('[mini-program] 启动失败: $e');
      if (mounted) setState(() => _error = '小程序启动失败: $e');
    } finally {
      _starting = false;
    }
  }

  /// 文本响应(403 越界 / 404 缺失)。statusCode 需同时带 headers + reasonPhrase(平台约定)。
  WebResourceResponse _plainResponse(String text, int statusCode) {
    return WebResourceResponse(
      contentType: 'text/plain',
      contentEncoding: 'utf-8',
      statusCode: statusCode,
      reasonPhrase: statusCode == 404 ? 'Not Found' : 'Forbidden',
      headers: const <String, String>{},
      data: Uint8List.fromList(text.codeUnits),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(miniProgramsProvider);
    final info = _findInfo(listAsync.valueOrNull ?? []);
    return Scaffold(
      appBar: AppBar(
        title: Text(info?.name ?? '小程序'),
        leading: BackButton(onPressed: () => context.pop()),
      ),
      body: listAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (_) {
          if (_error != null) {
            return _ErrorView(message: _error!, onBack: () => context.pop());
          }
          if (info == null) {
            return Center(child: Text('小程序 ${widget.appid} 不存在或已下架'));
          }
          if (info.status == 'disabled') {
            return const Center(child: Text('该小程序已被管理员停用'));
          }
          return InAppWebView(
            initialSettings: InAppWebViewSettings(
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              useHybridComposition: true,
            ),
            initialUserScripts: UnmodifiableListView([
              UserScript(
                source: _jsBridgeBootstrap,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
            ]),
            onWebViewCreated: (controller) {
              _controller = controller;
              controller.addJavaScriptHandler(
                handlerName: 'wanlingRequest',
                callback: (args) async =>
                    await _bridge?.handle('wanlingRequest', args),
              );
              controller.addJavaScriptHandler(
                handlerName: 'wanlingClose',
                callback: (args) async =>
                    await _bridge?.handle('wanlingClose', args),
              );
              unawaited(_start(info));
            },
            shouldOverrideUrlLoading: (controller, action) async {
              // 只允许本小程序虚拟 origin 内导航,外链一律拦截
              final uri = action.request.url;
              if (uri != null && uri.host == _virtualHost) {
                return NavigationActionPolicy.ALLOW;
              }
              return NavigationActionPolicy.CANCEL;
            },
            shouldInterceptRequest: (controller, request) async {
              // 仅拦截本 appid 虚拟 origin,其余交给 WebView 原生处理
              if (request.url.host != _virtualHost ||
                  _pkgRoot == null ||
                  _entryPath == null) {
                return null;
              }
              final filePath = resolveLocalFile(_pkgRoot!, request.url.path);
              // 越出包根(zip-slip 第二层防护) → 403
              if (filePath == null) {
                return _plainResponse('forbidden', 403);
              }
              final file = File(filePath);
              // isFile 同时覆盖存在性 + 非目录(命中目录/缺失 → 404)
              if (!await FileSystemEntity.isFile(filePath)) {
                return _plainResponse('not found', 404);
              }
              return WebResourceResponse(
                contentType: _mimeOf(filePath),
                data: await file.readAsBytes(),
              );
            },
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onBack;
  const _ErrorView({required this.message, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onBack, child: const Text('返回')),
          ],
        ),
      ),
    );
  }
}