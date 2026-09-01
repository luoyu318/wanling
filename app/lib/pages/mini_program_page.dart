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
import 'package:app/services/mini_program_permission_flow.dart';
import 'package:app/widgets/mini_program_conversation_picker.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/local_message_store_provider.dart'
    show localMessageStoreProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/mini_program_service.dart';
import 'package:wanling_core/services/secure_storage.dart';

import '../widgets/feedback/app_dialog.dart';

/// 注入 window.wanling:request/close/getChatContext/shareToChat 四个桥,
/// 底层走 flutter_inappwebview callHandler。
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
  },
  getChatContext: function() {
    return window.flutter_inappwebview
        .callHandler('wanlingGetChatContext')
        .then(function(r) {
          if (r && r.ok) return r.data;
          throw new Error((r && r.error) || 'getChatContext failed');
        });
  },
  shareToChat: function(payload) {
    return window.flutter_inappwebview
        .callHandler('wanlingShareToChat', payload || {})
        .then(function(r) {
          if (r && r.ok) return r.data;
          throw new Error((r && r.error) || 'shareToChat failed');
        });
  },
  openPage: function(opts) {
    return window.flutter_inappwebview
        .callHandler('wanlingOpenPage', opts || {})
        .then(function(r) {
          if (r && r.ok) return r.data;
          throw new Error((r && r.error) || 'openPage failed');
        });
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

  /// 从聊天卡片打开时的来源会话(getChatContext 返回 conversation_id)。
  final String? conversationId;

  /// 卡片跳转携带的 launch 参数(已解码的 params JSON 字符串)。
  /// 透传到入口 URL query,H5 用 URLSearchParams 自取,不进 bridge。
  final String? launchParams;
  const MiniProgramPage(
      {super.key, required this.appid, this.conversationId, this.launchParams});

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
      final service = MiniProgramService(
        baseUrl: ref.read(apiProvider).baseUrl,
        token: token,
        store: ref.read(localMessageStoreProvider).valueOrNull,
      );
      var dir = await service.installedDir(info.appid, info.version);
      dir ??= await service.install(info);
      _pkgRoot = dir.path;
      _entryPath = p.join(_pkgRoot!, info.entry);

      final effective = await _ensurePermissions(info);
      _bridge = MiniProgramBridge(
        permissions: effective,
        proxy: (path, method, body) =>
            ref.read(apiProvider).proxyRequest(path, method: method, body: body),
        onClose: () => context.pop(),
        onChatContext: () => widget.conversationId,
        onShare: (payload) => _shareToChat(info, payload),
        onOpenPage: (route) => _openHostPage(route),
      );
      await _controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri(_entryUrl(info).toString())),
      );
    } catch (e) {
      debugPrint('[mini-program] 启动失败: $e');
      if (mounted) setState(() => _error = '小程序启动失败: $e');
    } finally {
      _starting = false;
    }
  }

  /// chat 权限授权流程:KVS 读已授权集 → 未决项逐个弹窗 → 持久化增量授权。
  /// 拒绝项不进 granted(有效权限集不含 → bridge 持续拒绝);
  /// 非 chat 权限不弹窗(不涉及用户会话数据)。返回有效权限集。
  /// 编排逻辑抽在 runPermissionFlow(可注入可测),此处仅接线弹窗与 KVS 落库。
  Future<Set<String>> _ensurePermissions(MiniProgramInfo info) async {
    final declared = info.permissions.toSet();
    final uid = await TokenVault.getUserId() ?? '';
    final store = ref.read(localMessageStoreProvider).valueOrNull;
    final granted = await store?.getMpPerms(uid, info.appid) ?? <String>{};
    return runPermissionFlow(
      declared: declared,
      granted: granted,
      askUser: (perm) async => mounted && await _showPermDialog(info, perm),
      persist: (g) async {
        await store?.putMpPerms(uid, info.appid, g);
      },
    );
  }

  static const _permDesc = {
    'wanling.chat.read': '读取当前会话 ID（用于关联你正在看的会话）',
    'wanling.chat.share': '向你选择的好友/群聊分享小程序卡片',
    'wanling.nav': '跳转到万灵 APP 内页面（小程序可拉起宿主页）',
  };

  /// 权限申请确认框。返回 true=允许;拒绝/点遮罩均视为拒绝。
  Future<bool> _showPermDialog(MiniProgramInfo info, String perm) async {
    var allowed = false;
    await showAppDialog(
      context: context,
      title: '权限申请',
      content: Text('${info.name} 申请以下权限：\n${_permDesc[perm] ?? perm}'),
      confirmText: '允许',
      cancelText: '拒绝',
      onConfirm: () => allowed = true,
    );
    return allowed;
  }

  /// 入口 URL:虚拟 origin + entry。卡片跳转携带的 conv/launch 透传到 query
  /// (Uri 自动 percent-encode,H5 URLSearchParams 解码往返无损)。
  Uri _entryUrl(MiniProgramInfo info) {
    final query = <String, String>{
      if (widget.conversationId != null) 'conv': widget.conversationId!,
      if (widget.launchParams != null && widget.launchParams!.isNotEmpty)
        'launch': widget.launchParams!,
    };
    return Uri(
      scheme: 'https',
      host: _virtualHost,
      path: info.entry,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// shareToChat:弹会话选择器 → 以 mini_program_card 发消息。
  /// 返回 null=用户取消(bridge 转 cancelled)。
  Future<Map<String, dynamic>?> _shareToChat(
      MiniProgramInfo info, Map<String, dynamic> payload) async {
    if (info.status != 'published') {
      throw StateError('仅公开小程序可分享到会话');
    }
    final convId =
        await showMiniProgramConversationPicker(context: context, ref: ref);
    if (convId == null) return null;
    final result = await ref.read(apiProvider).sendMessage(convId, {
      'msg_type': 'mini_program_card',
      'data': {
        'appid': info.appid,
        'title': (payload['title'] as String?) ?? info.name,
        'params': payload['params'],
      },
    });
    return {'message_id': result.messageId};
  }

  /// openPage 消费:按 bridge 白名单校验后的 route 描述跳宿主页面。
  /// 小程序页保留在栈上,宿主页返回键即回到小程序(导航栈天然支持)。
  void _openHostPage(Map<String, dynamic> route) {
    switch (route['route'] as String?) {
      case 'home':
        context.pop(); // 小程序页出栈,回到宿主主页(消息页)
      case 'miniPrograms':
        context.push('/mini-programs');
      case 'agentDetail':
        final agentId = route['agent_id'] as String?;
        if (agentId != null && agentId.isNotEmpty) {
          context.push('/agent/$agentId');
        }
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
              allowFileAccess: false,
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
              controller.addJavaScriptHandler(
                handlerName: 'wanlingGetChatContext',
                callback: (args) async =>
                    await _bridge?.handle('wanlingGetChatContext', args),
              );
              controller.addJavaScriptHandler(
                handlerName: 'wanlingShareToChat',
                callback: (args) async =>
                    await _bridge?.handle('wanlingShareToChat', args),
              );
              controller.addJavaScriptHandler(
                handlerName: 'wanlingOpenPage',
                callback: (args) async =>
                    await _bridge?.handle('wanlingOpenPage', args),
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