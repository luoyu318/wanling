import 'dart:math';

/// 指数退避重连策略：base * 2^n + ±25% jitter，上限 max。
///
/// 服务端恢复时打散客户端避免重连风暴；网络抖动时减少高频耗电。
/// 调用方在连接成功（如 WS hello 到达）时 reset()，失败累积时反复 next()。
class ReconnectBackoff {
  int _attempt = 0;

  static const int _baseMs = 1000;
  static const int _maxMs = 30000;

  final Random _random;

  ReconnectBackoff({Random? random}) : _random = random ?? Random();

  /// 返回下次重连应等待的时长。每次调用让 attempt+1（指数增长）。
  /// jitter 区间为 [exp*0.75, exp*1.25]（±25% 对称），仅上界受 _maxMs 硬封顶。
  /// attempt=0 时区间为 [750ms, 1250ms]；exp 达 _maxMs 后直接返 _maxMs（不再 jitter，
  /// 避免饱和后分布偏斜到 30000 处出现概率尖峰）。
  Duration next() {
    final exp = (_baseMs * (1 << _attempt)).clamp(_baseMs, _maxMs);
    final ms = exp >= _maxMs
        ? _maxMs
        : (exp * (0.75 + _random.nextDouble() * 0.5))
            .round()
            .clamp(0, _maxMs);
    _attempt = (_attempt + 1).clamp(0, 30);
    return Duration(milliseconds: ms);
  }

  /// 连接成功后重置 attempt，让下次失败从 base 开始。
  void reset() => _attempt = 0;
}
