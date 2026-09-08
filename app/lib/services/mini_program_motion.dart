import 'dart:async';

// sensors_plus 仅在 pubspec 的 dependency_overrides 声明(压 wechat_camera_picker
// 间接拉入的 7.x),lint 误报非直接依赖,此处行级豁免
import 'package:sensors_plus/sensors_plus.dart'; // ignore: depend_on_referenced_packages

/// 设备运动订阅源:封装加速度计/去重力加速度/陀螺仪三流订阅 + 按 hz 节流
/// 拼包推送。桥(wanlingDeviceMotionStart/Stop)经容器页委托到此,本类不感知
/// WebView。三流时间戳不对齐,取各自最新帧拼包(体感场景可接受)。
/// 生命周期:start 幂等替换(停旧起新);pause/resume 停推/续推(订阅保留);
/// stop 全部释放。默认构造取 sensors_plus 全局流,测试注入 fake 流。
class MiniProgramMotionSource {
  MiniProgramMotionSource({
    Stream<AccelerometerEvent>? accel,
    Stream<UserAccelerometerEvent>? userAccel,
    Stream<GyroscopeEvent>? gyro,
  })  : _accelStream = accel ??
            accelerometerEventStream(samplingPeriod: _sampling),
        _userAccelStream = userAccel ??
            userAccelerometerEventStream(samplingPeriod: _sampling),
        _gyroStream = gyro ?? gyroscopeEventStream(samplingPeriod: _sampling);

  // 采样 50Hz:推送上限 30Hz 的最细粒度,更低推送频率由节流定时器裁剪
  static const _sampling = Duration(milliseconds: 20);

  final Stream<AccelerometerEvent> _accelStream;
  final Stream<UserAccelerometerEvent> _userAccelStream;
  final Stream<GyroscopeEvent> _gyroStream;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<UserAccelerometerEvent>? _userAccelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _timer;
  bool _paused = false;
  void Function(Map<String, dynamic> frame)? _onFrame;

  // 三流各自最新帧(null=尚未出帧)
  Map<String, dynamic>? _accel;
  Map<String, dynamic>? _userAccel;
  Map<String, dynamic>? _gyro;

  /// 幂等替换订阅:已订阅中则先完全停止再按新 hz 重起。
  void start(int hz, void Function(Map<String, dynamic> frame) onFrame) {
    stop();
    _onFrame = onFrame;
    _accelSub = _accelStream.listen((e) => _accel = _vec(e.x, e.y, e.z));
    _userAccelSub =
        _userAccelStream.listen((e) => _userAccel = _vec(e.x, e.y, e.z));
    _gyroSub = _gyroStream.listen((e) => _gyro = _vec(e.x, e.y, e.z));
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ hz), (_) => _tick());
  }

  /// 全部释放(cancel 流订阅 + 停节流器 + 清帧缓存),幂等。
  void stop() {
    unawaited(_accelSub?.cancel());
    unawaited(_userAccelSub?.cancel());
    unawaited(_gyroSub?.cancel());
    _accelSub = null;
    _userAccelSub = null;
    _gyroSub = null;
    _timer?.cancel();
    _timer = null;
    _accel = null;
    _userAccel = null;
    _gyro = null;
    _paused = false;
  }

  /// APP 切后台:停推送,订阅与帧缓存保留,resume 即续推。
  void pause() => _paused = true;

  /// 回前台恢复推送。
  void resume() => _paused = false;

  void _tick() {
    if (_paused) return;
    final onFrame = _onFrame;
    if (onFrame == null) return;
    // 三流均未出帧不推空帧
    if (_accel == null && _userAccel == null && _gyro == null) return;
    onFrame({
      if (_accel != null) 'accel': _accel,
      if (_userAccel != null) 'userAccel': _userAccel,
      if (_gyro != null) 'gyro': _gyro,
    });
  }

  Map<String, dynamic> _vec(double x, double y, double z) =>
      {'x': x, 'y': y, 'z': z};
}
