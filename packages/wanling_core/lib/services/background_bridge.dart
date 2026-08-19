/// bg-service IPC 桥接:core 层不依赖 flutter_background_service(移动专属),
/// 壳在启动时注入实现。null = 无后台服务(桌面/测试),调用为 no-op。
typedef ServiceIpc = void Function(String method, [Map<String, dynamic>? args]);

ServiceIpc? backgroundServiceIpc;

/// core 内统一的 bg-service IPC 入口。
void notifyService(String method, [Map<String, dynamic>? args]) =>
    backgroundServiceIpc?.call(method, args);
