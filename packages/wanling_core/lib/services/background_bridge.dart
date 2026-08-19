/// bg-service IPC 桥接:core 层不依赖移动专属前台服务插件,
/// 壳在启动时注入实现。null = 无后台服务(桌面/测试),调用为 no-op。
typedef ServiceIpc = void Function(String method, [Map<String, dynamic>? args]);

ServiceIpc? backgroundServiceIpc;

/// bg-service → 主 isolate 事件流桥接(壳注入移动专属前台服务插件的事件流)。
/// null = 无后台服务(桌面/测试),订阅跳过。
Stream<dynamic>? Function(String method)? backgroundServiceOn;

/// core 内统一的 bg-service IPC 入口。
void notifyService(String method, [Map<String, dynamic>? args]) =>
    backgroundServiceIpc?.call(method, args);
