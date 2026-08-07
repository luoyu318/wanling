/// 时长格式化(对齐 opencode TUI util/locale.ts 的 Locale.duration)。
/// 输入毫秒,输出:
/// - < 1000ms        → `22ms`
/// - < 60000         → `1.6s`
/// - < 3600000       → `1m 30s`
/// - < 86400000      → `1h 30m`
/// - 更长            → `1d 2h`
String formatDurationMs(int input) {
  if (input < 1000) {
    return '${input}ms';
  }
  if (input < 60000) {
    return '${(input / 1000).toStringAsFixed(1)}s';
  }
  if (input < 3600000) {
    final minutes = input ~/ 60000;
    final seconds = (input % 60000) ~/ 1000;
    return '${minutes}m ${seconds}s';
  }
  if (input < 86400000) {
    final hours = input ~/ 3600000;
    final minutes = (input % 3600000) ~/ 60000;
    return '${hours}h ${minutes}m';
  }
  final days = input ~/ 86400000;
  final hours = (input % 86400000) ~/ 3600000;
  return '${days}d ${hours}h';
}
