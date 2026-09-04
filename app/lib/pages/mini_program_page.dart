// 小程序 WebView 容器页。
// origin 隔离:每小程序独立虚拟域名 https://<appid>.<user_id>.mini.wanling.local
// (host 含账号段,隔离多账号 storage),静态文件由 shouldInterceptRequest 从
// 本地包目录读取,/api/ 路径经宿主带登录态代理;token 不进 JS,
// JS 侧经 window.wanling.request → JSBridge → ApiService.proxyRequest。
// 模板: templates/flutter-page.dart.tmpl(controller 分离/const+key/loading+error UI)。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import 'package:app/services/mini_program_bridge.dart';
import 'package:app/services/mini_program_permission_flow.dart';
import 'package:app/widgets/mini_program_conversation_picker.dart';
import 'package:app/widgets/avatar.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart'
    show apiProvider, authProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/local_message_store_provider.dart'
    show localMessageStoreProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/mini_program_service.dart';
import 'package:wanling_core/services/secure_storage.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/snackbar.dart';

import '../widgets/feedback/app_dialog.dart';

/// 注入 window.wanling:request/close/getChatContext/shareToChat/openPage/
/// getProfile 六桥 + storage 云数据桥(七方法 + 事件监听),底层走
/// flutter_inappwebview callHandler。
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
  },
  getProfile: function() {
    return window.flutter_inappwebview
        .callHandler('wanlingGetProfile')
        .then(function(r) {
          if (r && r.ok) return r.data;
          throw new Error((r && r.error) || 'getProfile failed');
        });
  }
};

// —— 云数据桥(window.wanling.storage):七方法 + 事件监听 ——
// IIFE 包裹:call 辅助函数不泄漏到页面全局作用域。
(function() {
  // callHandler promise 化包装(envelope 剥壳对齐上方各方法)
  function call(handler, opts) {
    return window.flutter_inappwebview
        .callHandler(handler, opts || {})
        .then(function(r) {
          if (r && r.ok) return r.data;
          throw new Error((r && r.error) || 'storage call failed');
        });
  }
  // 事件消费语义(控制器裁决):事件按到达序应用;version 仅用于丢弃比本地
  // 旧的 set 事件;delete 事件的 version 是被删行旧值(非递增),不做 version
  // 去重。小程序侧缓存合并示例:
  //   var hit = myCache[ev.coll + '/' + ev.key];
  //   if (!ev.deleted && hit && hit.version >= ev.version) return; // 旧 set 丢弃
  //   myCache[ev.coll + '/' + ev.key] = ev; // delete 事件也按到达序直接应用
  window.wanling._mpListeners = [];
  window.wanling.storage = {
    get: function(o) { return call('wanlingStorageGet', o); },
    set: function(o) { return call('wanlingStorageSet', o); },
    remove: function(o) { return call('wanlingStorageRemove', o); },
    items: function(o) { return call('wanlingStorageItems', o || {}); },
    quota: function() { return call('wanlingStorageQuota', {}); },
    subscribe: function(colls) { return call('wanlingStorageSubscribe', {colls: colls}); },
    unsubscribe: function() { return call('wanlingStorageUnsubscribe', {}); },
    on: function(cb) {
      window.wanling._mpListeners.push(cb);
      return function() { // off:移除该监听器
        var i = window.wanling._mpListeners.indexOf(cb);
        if (i >= 0) window.wanling._mpListeners.splice(i, 1);
      };
    }
  };
  // 由原生 evaluateJavascript 调:遍历监听器分发事件
  // (slice 拷贝防回调内 on/off 增删正在遍历的数组;单回调异常不阻断其余)
  window.wanling._emitMpStorageEvent = function(ev) {
    window.wanling._mpListeners.slice().forEach(function(cb) {
      try { cb(ev); } catch (e) {}
    });
  };
})();
""";

/// 测试可见别名:bootstrap 源码包含性断言用(库私有 const 单测不可见)。
@visibleForTesting
const String jsBridgeBootstrapSource = _jsBridgeBootstrap;

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

/// 小程序虚拟 host:appid + 账号段,origin 级隔离多账号 storage
/// (同设备多账号打开同一小程序,localStorage/IndexedDB 互不可见)。
String virtualHostFor(String appid, String uid) =>
    '$appid.$uid.mini.wanling.local';

/// MP_DATA_UPDATE 事件过滤(公开顶层纯函数便于单测,对齐 resolveLocalFile 模式):
/// d.appid 与当前小程序不匹配返回 null(他包事件不进本 WebView);
/// 匹配则把整个 payload 序列化为 json 字符串,供 evaluateJavascript 调
/// `window.wanling._emitMpStorageEvent(<json>)`。畸形帧(d 缺失/非对象)
/// 一律返回 null 丢弃,不转发进 WebView。
String? mpEventFilter(WSMessage msg, String appid) {
  final d = msg.d;
  if (d is! Map) return null;
  if (d['appid'] != appid) return null;
  return jsonEncode(d);
}

/// 文本响应(403 越界 / 404 缺失 / 405 非 GET / 502 代理失败)。statusCode 需
/// 同时带 headers + reasonPhrase(平台约定)。
WebResourceResponse _plainTextResponse(
    String text, int statusCode, String reasonPhrase) {
  return WebResourceResponse(
    contentType: 'text/plain',
    contentEncoding: 'utf-8',
    statusCode: statusCode,
    reasonPhrase: reasonPhrase,
    headers: const <String, String>{},
    data: Uint8List.fromList(text.codeUnits),
  );
}

/// 虚拟域 /api/ 资源代理(公开顶层函数便于单测):小程序内相对路径引用的宿主
/// 资源(如身份卡头像 /api/files/...)解析到虚拟域,WebView 无原生站点可回源,
/// 改由宿主 ApiService(同登录态)GET baseUrl + 归一化路径,把响应字节与
/// Content-Type 包成 WebResourceResponse;上游失败 502,非 GET 405。
/// 返回 null 表示非 /api/ 路径,交还本地包文件逻辑。
/// 归一化仅防路径混淆(点段折叠):代理目标固定为 baseUrl + path,非开放代理,
/// 归一化后越出 /api/ 即 403 拒绝(fail fast,对齐 bridge 路径白名单语义)。
Future<WebResourceResponse?> proxyApiResource(
  ApiService api,
  Uri uri, {
  String method = 'GET',
}) async {
  if (!uri.path.startsWith('/api/')) return null;
  if (method != 'GET') {
    return _plainTextResponse('method not allowed', 405, 'Method Not Allowed');
  }
  String normalized;
  try {
    normalized = Uri.parse(uri.path).normalizePath().path;
  } on FormatException {
    return _plainTextResponse('forbidden', 403, 'Forbidden');
  }
  if (!normalized.startsWith('/api/')) {
    return _plainTextResponse('forbidden', 403, 'Forbidden');
  }
  try {
    final res = await api.dio.get<List<int>>(
      normalized,
      queryParameters: uri.queryParameters.isEmpty
          ? null
          : Map<String, dynamic>.from(uri.queryParameters),
      options: Options(responseType: ResponseType.bytes),
    );
    return WebResourceResponse(
      contentType:
          res.headers.value(Headers.contentTypeHeader) ?? 'application/octet-stream',
      data: Uint8List.fromList(res.data ?? const []),
    );
  } catch (_) {
    // 对 WebView 必须返回响应而非抛异常;上游任何失败统一 502 网关错误
    return _plainTextResponse('bad gateway', 502, 'Bad Gateway');
  }
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

/// profile 授权弹窗(wanlingGetProfile 首次调用时经 bridge 回调触发,
/// 调用式授权,不在 M2 启动弹序列)。返回 true=允许;拒绝/点遮罩均视为拒绝。
Future<bool> showProfileConsentDialog(BuildContext context) async {
  var allowed = false;
  await showAppDialog(
    context: context,
    title: '身份信息授权',
    content: const Text('将向该小程序提供你的昵称、头像与用户标识'),
    confirmText: '允许',
    cancelText: '拒绝',
    onConfirm: () => allowed = true,
  );
  return allowed;
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
  /// wanlingGetProfile 调用式授权的 KVS 授权痕键(复用 mp_perm 集合语义,
  /// 随 deleteMpPerms 卸载清理)。
  static const _profilePermKey = 'wanling.profile';

  InAppWebViewController? _controller;
  MiniProgramBridge? _bridge;
  String? _pkgRoot;
  String? _entryPath;
  bool _starting = false;
  String? _error;

  /// document.title 同步(onTitleChanged),null=未收到回调时显示 manifest.name。
  String? _title;

  /// WebView 是否有后退历史(hash/history 导航也计入)。
  /// 驱动两处 UI:default 形态入口页隐藏返回键;系统返回键决定 goBack 还是退出。
  bool _canGoBack = false;

  /// goBack 异步竞态防抖:一次系统返回事件只消费一次。
  bool _popping = false;

  /// 当前登录 user_id(_start 快照),进虚拟 host 账号段隔离多账号 storage。
  String? _uid;

  /// WS 服务快照(_start 缓存,dispose 退订用;对齐 chat_page 缓存实例模式,
  /// dispose 内不碰 ref)。
  WebSocketService? _ws;

  /// 云数据推送流订阅(MP_DATA_UPDATE → mpEventFilter → evaluateJavascript)。
  StreamSubscription<WSMessage>? _mpEventSub;

  String get _virtualHost => virtualHostFor(widget.appid, _uid!);

  /// 刷新 _canGoBack(onUpdateVisitedHistory 回调,含 hash 同文档导航)。
  Future<void> _syncCanGoBack() async {
    final can = await _controller?.canGoBack() ?? false;
    if (mounted && can != _canGoBack) setState(() => _canGoBack = can);
  }

  /// 系统返回键语义:WebView 内有历史 → 回小程序上一页(history 路由);
  /// 已在入口页 → 退出小程序回 APP。
  Future<void> _handleBack() async {
    if (_popping) return;
    _popping = true;
    try {
      final controller = _controller;
      if (controller != null && await controller.canGoBack()) {
        await controller.goBack();
        return;
      }
      if (mounted) context.pop();
    } finally {
      _popping = false;
    }
  }

  /// 退出小程序(胶囊 ◉ / 更多菜单关项目):直接出栈,不消费 WebView 历史。
  void _close() {
    if (mounted) context.pop();
  }

  /// 胶囊「更多」菜单抽屉:信息头(图标+名称) + 方形圆角功能瓦片(刷新/分享,
  /// 图标在上文字在下) + 细线分隔 + 底部整行「关闭」(仅收起抽屉;
  /// 关闭小程序走胶囊 ◉,不再放抽屉里)。
  Future<void> _showMoreSheet(MiniProgramInfo info) async {
    final canShare = info.permissions.contains('wanling.chat.share');
    final iconUrl =
        info.iconUrlFor(ref.read(apiProvider).baseUrl);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFF7F7F7),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // —— 信息头:小程序图标 + 名称 ——
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              child: Row(
                children: [
                  Avatar(
                    name: info.name,
                    url: iconUrl.isEmpty ? null : iconUrl,
                    size: 44,
                    radius: 10,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      info.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // —— 功能瓦片区:方形圆角图标 + 底部文字 ——
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Row(
                children: [
                  _MoreSheetTile(
                    icon: Icons.refresh,
                    iconColor: const Color(0xFF07C160),
                    label: '刷新',
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _controller?.reload();
                    },
                  ),
                  const SizedBox(width: 14),
                  _MoreSheetTile(
                    icon: Icons.ios_share,
                    iconColor: const Color(0xFF5B8BF7),
                    label: '分享到会话',
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _shareFromCapsule(info, canShare);
                    },
                  ),
                ],
              ),
            ),
            // —— 细线分隔 ——
            const Divider(height: 1, thickness: 0.5, color: Color(0xFFE4E4E4)),
            // —— 底部整行「关闭」:仅收起抽屉 ——
            SizedBox(
              width: double.infinity,
              height: 52,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white,
                  shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero),
                  foregroundColor: const Color(0xFF333333),
                  textStyle: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500),
                ),
                onPressed: () => Navigator.of(sheetCtx).pop(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 胶囊入口的分享:与 bridge shareToChat 同规则(仅公开+已声明 share 权限)。
  Future<void> _shareFromCapsule(MiniProgramInfo info, bool canShare) async {
    try {
      if (!canShare) {
        throw StateError('该小程序未申请分享权限(wanling.chat.share)');
      }
      await _shareToChat(info, {'title': info.name});
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          '$e'.replaceFirst(RegExp(r'^(Bad state|StateError): '), ''),
          type: SnackBarType.error,
        );
      }
    }
  }

  /// #RRGGBB → Color;非法值(null,server 已 fail fast,防御旧数据)回退主题色。
  Color? _parseColor(String? hex) {
    if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

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
      // 账号段快照:虚拟 origin 含 uid,隔离多账号 storage。该页未登录不可达,fail fast。
      final currentUid = ref.read(authProvider).user?.id;
      if (currentUid == null) throw StateError('未登录');
      _uid = currentUid;
      final service = MiniProgramService(
        baseUrl: ref.read(apiProvider).baseUrl,
        token: token,
        store: ref.read(localMessageStoreProvider).valueOrNull,
      );
      var dir = await service.installedDir(info.appid, info.version);
      if (dir == null) {
        dir = await service.install(info);
        // 新装/静默更新后刷新小程序数据,栈下列表页返回即见新版本
        ref.invalidate(miniProgramsProvider);
      }
      _pkgRoot = dir.path;
      _entryPath = p.join(_pkgRoot!, info.entry);

      final effective = await _ensurePermissions(info);
      final uid = await TokenVault.getUserId() ?? '';
      final store = ref.read(localMessageStoreProvider).valueOrNull;
      final user = ref.read(authProvider).user;
      // 云数据订阅接线依赖的 WS 实例(bridge 回调闭包捕获;dispose 退订复用)
      final ws = ref.read(wsProvider);
      _ws = ws;
      _bridge = MiniProgramBridge(
        permissions: effective,
        proxy: (path, method, body) =>
            ref.read(apiProvider).proxyRequest(path, method: method, body: body),
        onClose: () => context.pop(),
        onChatContext: () => widget.conversationId,
        onShare: (payload) => _shareToChat(info, payload),
        onOpenPage: (route) => _openHostPage(route),
        // wanlingGetProfile(调用式授权):appid 宿主注入防 JS 枚举,
        // 昵称头像取当前登录用户快照,KVS 授权痕读写 + 弹窗均由容器页接线。
        appid: info.appid,
        nickname: user?.displayName,
        avatarUrl: user?.avatarUrl,
        isProfileGranted: () async =>
            (await store?.getMpPerms(uid, info.appid) ?? <String>{})
                .contains(_profilePermKey),
        requestProfilePermission: () async =>
            mounted && await showProfileConsentDialog(context),
        persistProfileGrant: () async {
          final granted =
              await store?.getMpPerms(uid, info.appid) ?? <String>{};
          await store?.putMpPerms(uid, info.appid, {...granted, _profilePermKey});
        },
        // 云数据订阅接线:bridge 权限门禁(wanling.storage)通过后回调,
        // 容器页接 WS;appid 为 bridge 持有的宿主注入值,JS 不可传参
        onMpSubscribe: (mpAppid, colls) => ws.sendMpSubscribe(mpAppid, colls),
        onMpUnsubscribe: () async => ws.sendMpUnsubscribe(),
      );
      // 云数据推送:订阅 MP_DATA_UPDATE 流,过滤本 appid 后转发进 WebView
      // (JS 侧按到达序应用,version 语义见 bootstrap 注释)。
      // cancel 返回 Future,async 上下文内需显式丢弃(_starting 守卫下仅跑一次)
      unawaited(_mpEventSub?.cancel());
      _mpEventSub = ws.mpStorageUpdates.listen((m) {
        final json = mpEventFilter(m, info.appid);
        if (json == null) return;
        final controller = _controller;
        if (!mounted || controller == null) return;
        // 页面正在销毁/重载时注入可能失败,best-effort 吞掉不阻断后续事件
        unawaited(controller
            .evaluateJavascript(
                source: 'window.wanling._emitMpStorageEvent($json)')
            .catchError((_) {}));
      });
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

  @override
  void dispose() {
    // 云数据退订闭环:best-effort 发 op=16(连接断开时 send 对 null channel
    // no-op 不抛异常),再取消流订阅防泄漏。
    _ws?.sendMpUnsubscribe();
    _mpEventSub?.cancel();
    super.dispose();
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
        'icon': info.icon,
      },
    });
    if (!mounted) return null;
    showAppSnackBar(context, '已分享到会话', type: SnackBarType.success);
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

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(miniProgramsProvider);
    final info = _findInfo(listAsync.valueOrNull ?? []);
    final nav = info?.navigationBar;
    final navBg = _parseColor(nav?.backgroundColor);
    final navFg = _parseColor(nav?.foregroundColor);
    final capsule = _CapsuleButton(
      foregroundColor: navFg,
      onMore: () => _showMoreSheet(info!),
      onClose: _close,
    );
    final isCustom = nav?.isCustom ?? false;
    final appBar = isCustom
        ? null
        : AppBar(
            title: Text(_title ?? info?.name ?? '小程序'),
            // 入口页(无历史)隐藏返回键,退出入口交给胶囊(主流小程序平台语义)
            automaticallyImplyLeading: false,
            leading: _canGoBack ? BackButton(onPressed: _handleBack) : null,
            centerTitle: true,
            backgroundColor: navBg,
            foregroundColor: navFg,
            // info 未就绪(loading)时不放胶囊,防 _showMoreSheet 空引用
            actions: [if (info != null) capsule],
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: appBar,
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
            final webView = InAppWebView(
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
              onTitleChanged: (controller, title) {
                if (mounted) setState(() => _title = title);
              },
              onUpdateVisitedHistory: (controller, url, isMainFrame) {
                // hash 同文档导航也会回调,驱动返回键显隐
                unawaited(_syncCanGoBack());
              },
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
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingGetProfile',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingGetProfile', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageGet',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageGet', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageSet',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageSet', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageRemove',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageRemove', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageItems',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageItems', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageQuota',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageQuota', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageSubscribe',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageSubscribe', args),
                );
                controller.addJavaScriptHandler(
                  handlerName: 'wanlingStorageUnsubscribe',
                  callback: (args) async =>
                      await _bridge?.handle('wanlingStorageUnsubscribe', args),
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
                // 虚拟域 /api/ 资源(头像等宿主资源相对路径引用)→ 宿主带登录态
                // 代理回源,不经本地包文件;null 交还本地包文件逻辑
                final proxied = await proxyApiResource(
                  ref.read(apiProvider),
                  request.url,
                  method: request.method ?? 'GET',
                );
                if (proxied != null) return proxied;
                final filePath = resolveLocalFile(_pkgRoot!, request.url.path);
                // 越出包根(zip-slip 第二层防护) → 403
                if (filePath == null) {
                  return _plainTextResponse('forbidden', 403, 'Forbidden');
                }
                final file = File(filePath);
                // isFile 同时覆盖存在性 + 非目录(命中目录/缺失 → 404)
                if (!await FileSystemEntity.isFile(filePath)) {
                  return _plainTextResponse('not found', 404, 'Not Found');
                }
                return WebResourceResponse(
                  contentType: _mimeOf(filePath),
                  data: await file.readAsBytes(),
                );
              },
            );
            // custom 形态:无 AppBar 全屏,WebView 仍避让状态栏(小程序免处理 inset);
            // 胶囊悬浮右上角(小程序自绘头部须预留,见协议文档)
            return isCustom
                ? SafeArea(
                    child: Stack(
                      children: [
                        Positioned.fill(child: webView),
                        Positioned(top: 6, right: 12, child: capsule),
                      ],
                    ),
                  )
                : webView;
          },
        ),
      ),
    );
  }
}

/// 右上角胶囊(主流小程序平台语义):更多 ●●● | 关闭 ◉。
/// default 形态驻留 AppBar actions;custom 形态悬浮 WebView 右上角。
class _CapsuleButton extends StatelessWidget {
  final VoidCallback onMore;
  final VoidCallback onClose;
  final Color? foregroundColor;

  const _CapsuleButton({
    required this.onMore,
    required this.onClose,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foregroundColor ?? Colors.black87;
    // 双样式(参照主流小程序平台实拍):深色 fg(白色 AppBar)→白色实底+1px 边框+深色前景;
    // 浅色 fg(彩色 AppBar,如红/蓝)→白色 0.6 不透明底+无边框+黑色前景(白点在浅底上不可读)
    final lightFg = fg.computeLuminance() > 0.5;
    final contentColor = lightFg ? Colors.black87 : fg;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        // 透底程度对齐主流小程序平台实拍(彩色 AppBar 上可见底色透出,粉白/浅蓝白)
        color: lightFg ? Colors.white.withValues(alpha: .38) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: lightFg
            ? null
            : Border.all(color: Colors.black.withValues(alpha: .2), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onMore,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in const [4.0, 4.0, 4.0])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: CircleAvatar(
                          radius: d / 2, backgroundColor: contentColor),
                    ),
                ],
              ),
            ),
          ),
          Container(
              width: 1,
              height: 18,
              color: contentColor.withValues(alpha: .15)),
          InkWell(
            onTap: onClose,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child:
                  Icon(Icons.radio_button_checked, size: 20, color: contentColor),
            ),
          ),
        ],
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
/// 「更多」抽屉功能瓦片:方形圆角图标 + 底部文字(主流 IM 小程序菜单样式)。
class _MoreSheetTile extends StatelessWidget {
  const _MoreSheetTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 26, color: iconColor),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF333333)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
