import 'package:flutter/foundation.dart';

/// Debug-only 日志:仅在 debug 模式输出,release 模式编译期完全消除。
///
/// **为什么不用 [debugPrint]**:
/// Flutter 自带 `debugPrint` 默认实现 `debugPrintThrottled` 最终会调用
/// `print`(见 SDK `foundation/print.dart:105`),**release 模式也会输出到
/// logcat**。SDK 文档(`foundation/print.dart:37`)明确指出:
/// "The debugPrint function logs to console even in release mode."
///
/// 本函数用 [kDebugMode] 守卫,它是 `const bool.fromEnvironment('dart.vm.product')`
/// 取反的编译期常量。release build 中 `if (kDebugMode)` 分支是死代码,
/// 被 Dart tree shaker 完全移除——连字符串插值的分配都不会发生。
///
/// 用法与 [debugPrint] 完全一致(签名兼容,可直接替换):
/// ```dart
/// debugLog('[bg-service] connected, uid=$uid');
/// debugLog('long trace', wrapWidth: 1024);
/// ```
void debugLog(String? message, {int? wrapWidth}) {
  if (kDebugMode) {
    debugPrint(message, wrapWidth: wrapWidth);
  }
}
