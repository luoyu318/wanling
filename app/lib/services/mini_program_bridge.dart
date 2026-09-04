import 'package:flutter/foundation.dart';

/// 小程序 JSBridge 门禁(纯逻辑,WebView 无关,可单测)。
/// 安全基线:
/// - token 不进 JS:所有万灵 API 调用经 proxy 原生代理
/// - 权限 fail fast:manifest 未声明对应权限直接拒绝,不静默降级
/// - 路径白名单:仅放行 /api/ 前缀,归一化后复检,防 /api/../xxx 绕过
class MiniProgramBridge {
  final Set<String> permissions;
  final Future<Object?> Function(String path, String method, Object? body)
      proxy;
  final VoidCallback? onClose;

  /// 取当前会话 id;null=当前未接入会话上下文。由容器页注入(bridge 不感知 KVS)。
  final String? Function()? onChatContext;

  /// 分享到会话;返回 null=用户取消。由容器页注入(bridge 不感知 KVS)。
  final Future<Object?> Function(Map<String, dynamic> payload)? onShare;

  /// 跳转宿主页面(bridge 白名单校验后的 route 描述,容器页负责导航)。
  final void Function(Map<String, dynamic> route)? onOpenPage;

  /// —— wanlingGetProfile(调用式授权,不进 manifest 声明体系)宿主注入 ——
  /// openid 按(当前用户×appid)在 server 惰性生成;appid 由宿主持有注入,
  /// JS 不可传参,防枚举。null=宿主未接身份上下文,-32091 不适用。
  final String? appid;

  /// 展示资料快照(容器页取 AuthState.user;昵称头像在会话内本就可见)。
  final String? nickname;
  final String? avatarUrl;

  /// KVS 'wanling.profile' 授权痕读/写,由容器页注入(bridge 不感知 KVS)。
  final Future<bool> Function()? isProfileGranted;
  final Future<void> Function()? persistProfileGrant;

  /// profile 授权弹窗;null 视作拒绝(防御未接线场景)。
  final Future<bool> Function()? requestProfilePermission;

  /// 云数据订阅接线(容器页传 WS 实现桥接;null 时 subscribe 返回错误)
  final void Function(String appid, List<String> colls)? onMpSubscribe;

  /// 云数据退订接线(容器页传 WS 实现;未接线时 no-op,unsubscribe 仍 ok)
  final Future<void> Function()? onMpUnsubscribe;

  MiniProgramBridge({
    required this.permissions,
    required this.proxy,
    this.onClose,
    this.onChatContext,
    this.onShare,
    this.onOpenPage,
    this.appid,
    this.nickname,
    this.avatarUrl,
    this.isProfileGranted,
    this.persistProfileGrant,
    this.requestProfilePermission,
    this.onMpSubscribe,
    this.onMpUnsubscribe,
  });

  /// JSBridge 分发唯一出口:先经 [_dispatch] 跑各 case 原逻辑,回传 JS 前把
  /// envelope 的 error 字段规范化为 String([normalizeBridgeError]),JS 侧
  /// `new Error(r.error)` 永远拿到可读字符串,无需判型。
  Future<Object?> handle(String handlerName, List<dynamic> args) async {
    final result = await _dispatch(handlerName, args);
    if (result is Map && result['error'] != null) {
      final normalized = Map<String, dynamic>.from(result);
      normalized['error'] = normalizeBridgeError(normalized['error']);
      return normalized;
    }
    return result;
  }

  Future<Object?> _dispatch(String handlerName, List<dynamic> args) async {
    try {
      switch (handlerName) {
        case 'wanlingRequest':
          if (!permissions.contains('wanling.api')) {
            return {'ok': false, 'error': 'permission denied: wanling.api'};
          }
          final opts = (args.isNotEmpty ? args.first : null) as Map?;
          final path = opts?['path'] as String? ?? '';
          if (!path.startsWith('/api/')) {
            return {'ok': false, 'error': '仅允许 /api/ 前缀路径'};
          }
          final normalized = _normalizeApiPath(path);
          if (normalized == null || !normalized.startsWith('/api/')) {
            return {'ok': false, 'error': '路径归一化后越出 /api/ 白名单'};
          }
          // 收紧身份/管理端点(归一路径部分精确/前缀匹配,query 不参与判定):
          // /api/users/me 是 server 真实身份端点,拿全局 user_id,小程序应走
          // per-app 的 wanlingGetProfile;/api/me 为防御性拦截(server 当前无此
          // 路由,防未来新增别名漏拦);/api/admin/* 是宿主管理面,不在小程序信任边界内;
          // /api/mini-programs/openid 的 appid 必须由宿主持有注入,直调可自传
          // appid 使多个小程序共谋用同一 tracker 跨包关联用户。
          final qIdx = normalized.indexOf('?');
          final pathOnly =
              qIdx >= 0 ? normalized.substring(0, qIdx) : normalized;
          // 折叠尾斜杠后再判定:dio 默认跟随重定向,Gin 对带尾斜杠变体返 301
          // → 无尾斜杠路径,Authorization 随行,精确匹配会被绕过。
          // 根路径 / 不折叠成空串。
          // 折叠前先百分号解码归一:dio 原样发送 %2F,Go URL.Path 解码为 '/',
          // Gin 对带尾斜杠变体返 301,Authorization 随行,精确匹配被绕过;
          // 顺序必须先解码再折叠,否则 /api/users/me%2F 折叠正则不命中。
          // 非法编码(如 %zz)Uri.decodeComponent 抛 FormatException,fail-safe
          // 用原值继续判定(畸形路径交由 server 404/400 兜底,不让 bridge 崩)。
          String decodedPath;
          try {
            decodedPath = Uri.decodeComponent(pathOnly);
          } on FormatException {
            decodedPath = pathOnly;
          }
          final foldedPath = decodedPath.replaceAll(RegExp(r'/+$'), '');
          final checkPath = foldedPath.isEmpty ? '/' : foldedPath;
          if (checkPath == '/api/me' ||
              checkPath == '/api/users/me' ||
              checkPath == '/api/mini-programs/openid' ||
              checkPath == '/api/admin' ||
              checkPath.startsWith('/api/admin/')) {
            return {
              'ok': false,
              'error': {
                'code': -32091,
                'message': '身份信息请使用 wanlingGetProfile',
              },
            };
          }
          final method = opts?['method'] as String? ?? 'GET';
          final body = opts?['body'];
          final data = await proxy(normalized, method, body);
          return {'ok': true, 'data': data};
        case 'wanlingGetProfile':
          // 调用式授权:门禁只有 KVS 授权痕 + 运行时弹窗,无 manifest 权限。
          // appid 缺失先于授权判定(fail fast,不让用户为不可交付的请求弹窗)。
          if (appid == null || appid!.isEmpty) {
            return {
              'ok': false,
              'error': {
                'code': -32091,
                'message': '当前环境不支持获取身份信息',
              },
            };
          }
          final profileGranted = await isProfileGranted?.call() ?? false;
          if (!profileGranted) {
            // null 回调视作拒绝;拒绝不落痕,下次调用重弹(对齐 M2 拒绝语义)
            final allowed = await requestProfilePermission?.call() ?? false;
            if (!allowed) {
              return {
                'ok': false,
                'error': {'code': -32090, 'message': '用户未授权'},
              };
            }
            await persistProfileGrant?.call();
          }
          // openid 经宿主 proxy 通道(带登录态,token 不进 JS);端点失败走外层
          // catch 返错误,不静默、不缓存失败结果(下次授权痕命中后直接重试)。
          // 注意:此处为 bridge 内部直调 proxy,不经 handle('wanlingRequest')
          // 分发,故不受 wanlingRequest 对 openid 端点的拦截自锁;appid 由
          // 宿主持有,JS 无法经此通道注入。
          final profileRes = await proxy(
            '/api/mini-programs/openid?appid=${Uri.encodeComponent(appid!)}',
            'GET',
            null,
          );
          final openid = (profileRes as Map?)?['openid'] as String?;
          if (openid == null || openid.isEmpty) {
            throw StateError('openid 端点返回数据异常');
          }
          return {
            'ok': true,
            'data': {
              'openid': openid,
              'nickname': nickname,
              'avatarUrl': avatarUrl,
            },
          };
        case 'wanlingClose':
          onClose?.call();
          return null;
        case 'wanlingGetChatContext':
          if (!permissions.contains('wanling.chat.read')) {
            return {'ok': false, 'error': 'permission denied: wanling.chat.read'};
          }
          final convId = onChatContext?.call();
          return {
            'ok': true,
            'data': convId == null ? null : {'conversation_id': convId},
          };
        case 'wanlingShareToChat':
          if (!permissions.contains('wanling.chat.share')) {
            return {'ok': false, 'error': 'permission denied: wanling.chat.share'};
          }
          if (onShare == null) {
            return {'ok': false, 'error': 'share unavailable'};
          }
          final payload =
              (args.isNotEmpty ? args.first : null) as Map<String, dynamic>? ??
                  {};
          final shareData = await onShare!(payload);
          if (shareData == null) return {'ok': false, 'error': 'cancelled'};
          return {'ok': true, 'data': shareData};
        case 'wanlingOpenPage':
          if (!permissions.contains('wanling.nav')) {
            return {'ok': false, 'error': 'permission denied: wanling.nav'};
          }
          final opts =
              (args.isNotEmpty ? args.first : null) as Map<String, dynamic>? ??
                  {};
          final page = opts['page'] as String? ?? '';
          final params =
              (opts['params'] as Map?)?.cast<String, dynamic>() ?? const {};
          switch (page) {
            case 'home':
              final route = {'route': 'home'};
              onOpenPage?.call(route);
              return {'ok': true, 'data': route};
            case 'miniPrograms':
              final route = {'route': 'miniPrograms'};
              onOpenPage?.call(route);
              return {'ok': true, 'data': route};
            case 'agentDetail':
              final agentId = params['agentId'] as String?;
              if (agentId == null ||
                  !_agentIdPattern.hasMatch(agentId)) {
                return {'ok': false, 'error': 'agentId 需为合法 UUID'};
              }
              final route = {'route': 'agentDetail', 'agent_id': agentId};
              onOpenPage?.call(route);
              return {'ok': true, 'data': route};
            default:
              return {'ok': false, 'error': '未知页面: $page'};
          }
        case 'wanlingStorageGet':
        case 'wanlingStorageSet':
        case 'wanlingStorageRemove':
        case 'wanlingStorageItems':
        case 'wanlingStorageQuota':
        case 'wanlingStorageSubscribe':
        case 'wanlingStorageUnsubscribe':
          // 显式 await:return 异步调用不加 await 时,完成等待发生在
          // try 动态作用域之外,proxy 抛出的异常会绕过外层 catch 逃逸
          return await _dispatchStorage(handlerName, args);
        default:
          return {'ok': false, 'error': 'unknown method: $handlerName'};
      }
    } catch (e) {
      // 仅把错误转成 JS 可读 envelope,不吞栈(原生日志由调用方记)
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// 小程序云数据 wanlingStorage* 方法族(七 case 统一入口):
  /// - wanling.storage 权限门禁([_storageAllowed]),声明缺失全拒
  /// - key/coll 客户端预校验(与 server 正则一致),不符不触 proxy
  /// - get/set/remove/items/quota 经既有 proxy 调 /api/mini-program-storage,
  ///   server 4xx 抛 ApiException → 外层 catch 转 envelope
  ///   ('version conflict'/'quota exceeded' 文案在 server message 内,JS 可按子串分流)
  /// - subscribe/unsubscribe 经容器页注入回调接 WS,bridge 不感知连接层
  Future<Object?> _dispatchStorage(String handlerName, List<dynamic> args) async {
    final denied = _storageAllowed();
    if (denied != null) return denied;
    // unsubscribe 纯本地退订不依赖 appid;其余 case 拼 URL/回调都需宿主注入 appid,
    // 缺失属容器页接线缺陷,复用 'storage unavailable' 防御性拒绝(fail fast)
    if (handlerName != 'wanlingStorageUnsubscribe' &&
        (appid == null || appid!.isEmpty)) {
      return {'ok': false, 'error': 'storage unavailable'};
    }
    final opts = (args.isNotEmpty ? args.first : null) as Map? ?? const {};
    if (handlerName == 'wanlingStorageSubscribe') {
      // 未接线(宿主无 WS 桥接)→ 显式错误,不静默降级
      if (onMpSubscribe == null) {
        return {'ok': false, 'error': 'storage unavailable'};
      }
      final colls =
          ((opts['colls'] as List?) ?? const []).whereType<String>().toList();
      onMpSubscribe!(appid!, colls);
      return {'ok': true};
    }
    if (handlerName == 'wanlingStorageUnsubscribe') {
      await onMpUnsubscribe?.call();
      return {'ok': true};
    }
    if (handlerName == 'wanlingStorageQuota') {
      return {
        'ok': true,
        'data': await proxy(
            '/api/mini-program-storage/$appid/quota', 'GET', null),
      };
    }
    // get/set/remove 单条访问需 key(items 列举无 key 维度);不符不触 proxy
    if (handlerName != 'wanlingStorageItems') {
      final key = opts['key'] as String?;
      if (key == null || !_storageKeyPattern.hasMatch(key)) {
        return {'ok': false, 'error': 'invalid key'};
      }
    }
    // coll 缺省 'default';非空须匹配白名单(与 server 校验一致)
    final collRaw = opts['coll'] as String? ?? '';
    if (collRaw.isNotEmpty && !_storageCollPattern.hasMatch(collRaw)) {
      return {'ok': false, 'error': 'invalid coll'};
    }
    final coll = collRaw.isEmpty ? 'default' : collRaw;
    final base = '/api/mini-program-storage/$appid/entries';
    switch (handlerName) {
      case 'wanlingStorageGet':
        return {
          'ok': true,
          'data': await proxy(
              '$base/${Uri.encodeComponent(opts['key'] as String)}?coll=$coll',
              'GET',
              null),
        };
      case 'wanlingStorageSet':
        // body {value, expected_version}:expectedVersion 传时才带(乐观锁)
        final body = <String, dynamic>{'value': opts['value']};
        final ev = opts['expectedVersion'];
        if (ev != null) body['expected_version'] = ev;
        return {
          'ok': true,
          'data': await proxy(
              '$base/${Uri.encodeComponent(opts['key'] as String)}?coll=$coll',
              'PUT',
              body),
        };
      case 'wanlingStorageRemove':
        // server DELETE 的乐观锁走 query 参数(非 body)
        final ev = opts['expectedVersion'];
        final path = ev == null
            ? '$base/${Uri.encodeComponent(opts['key'] as String)}?coll=$coll'
            : '$base/${Uri.encodeComponent(opts['key'] as String)}?coll=$coll&expected_version=$ev';
        return {'ok': true, 'data': await proxy(path, 'DELETE', null)};
      case 'wanlingStorageItems':
        // limit 钳 1..500:<1 视作缺省 100,>500 截到 500(与 server 校验对齐)
        final raw = (opts['limit'] as num?)?.toInt();
        final limit = (raw == null || raw < 1) ? 100 : (raw > 500 ? 500 : raw);
        var path = '$base?coll=$coll&limit=$limit';
        final prefix = opts['prefix'] as String?;
        if (prefix != null && prefix.isNotEmpty) {
          path += '&prefix=${Uri.encodeComponent(prefix)}';
        }
        final cursor = opts['cursor'] as String?;
        if (cursor != null && cursor.isNotEmpty) {
          path += '&cursor=${Uri.encodeComponent(cursor)}';
        }
        // 透传 server 形状(next 游标在 X-Next-Cursor 头,由 proxy 接线层处理)
        return {'ok': true, 'data': await proxy(path, 'GET', null)};
      default:
        return {'ok': false, 'error': 'unknown method: $handlerName'};
    }
  }

  /// 云数据权限门禁:manifest 未声明 wanling.storage → 全拒(fail fast)。
  Map<String, dynamic>? _storageAllowed() {
    if (!permissions.contains('wanling.storage')) {
      return {'ok': false, 'error': 'permission denied: wanling.storage'};
    }
    return null;
  }

  /// 归一化待请求路径:剥离 query/fragment,对路径段做 URI 解码 + 点段清理
  /// (Uri.parse 解析时即解码 %2e 并消解 . / ..),再拼回原始 query。
  /// 返回 null 表示无法解析(拒绝)。
  static String? _normalizeApiPath(String path) {
    final qIdx = path.indexOf('?');
    final fIdx = path.indexOf('#');
    var cut = path.length;
    if (qIdx >= 0 && qIdx < cut) cut = qIdx;
    if (fIdx >= 0 && fIdx < cut) cut = fIdx;
    final rawPath = path.substring(0, cut);
    final query = qIdx >= 0 && qIdx < path.length ? path.substring(qIdx) : '';
    try {
      final normalized = Uri.parse(rawPath).normalizePath().path;
      return query.isEmpty ? normalized : '$normalized$query';
    } on FormatException {
      return null;
    }
  }
}

/// handle 出口错误规范化(公开顶层函数便于单测):error 恒为 String。
/// - 语义性拒绝对象 `{code, message}` → `"<code> <message>"`(code 原值已带负号,
///   如 `-32090 用户未授权`,code 语义保留在字符串前缀,JS 侧可按前缀分流)
/// - 带 code 无 message → `"<code>"`;仅 message → message
/// - String 原样(如 `permission denied: ...`/传输异常描述)
/// - 其余类型 toString 兜底,规范化路径自身不抛异常
String normalizeBridgeError(dynamic error) {
  if (error is String) return error;
  if (error is Map) {
    final code = error['code'];
    final message = error['message'];
    final sb = StringBuffer();
    if (code != null) sb.write(code);
    if (message is String && message.isNotEmpty) {
      if (sb.isNotEmpty) sb.write(' ');
      sb.write(message);
    }
    final text = sb.toString();
    return text.isEmpty ? '未知错误' : text;
  }
  return error?.toString() ?? '未知错误';
}

/// openPage 白名单:agentDetail 的 agentId 参数校验(UUID,与 server 侧 id 类型一致)。
final _agentIdPattern =
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// 云数据 key/coll 白名单(与 server storageKeyRe/coll 校验一致,客户端预校验)。
final _storageKeyPattern = RegExp(r'^[A-Za-z0-9_.:@-]{1,128}$');
final _storageCollPattern = RegExp(r'^[a-z0-9_-]{1,32}$');

/// 需用户弹窗授权的权限:chat 类(涉及用户会话数据)与 nav(涉及宿主页面跳转)。
/// 其余(如 wanling.api)不涉及用户数据,声明即生效。
bool requiresConsent(String perm) =>
    perm.startsWith('wanling.chat.') || perm == 'wanling.nav';

/// 有效权限 = manifest 声明集与用户授权集的交集规则:
/// - 不需授权的权限(如 `wanling.api`)直接生效
/// - 需授权权限(`wanling.chat.*` / `wanling.nav`)须在容器页算好的 granted
///   授权集中才生效
/// granted 中未 declared 的权限一律不生效(只收窄,不放大)。
Set<String> effectivePermissions(Set<String> declared, Set<String> granted) {
  return declared
      .where((p) => !requiresConsent(p) || granted.contains(p))
      .toSet();
}
