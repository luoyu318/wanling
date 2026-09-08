import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:app/services/mini_program_motion.dart';

void main() {
  test('start 后按 hz 节流推送拼包帧;stop 后停推', () async {
    final accel = StreamController<AccelerometerEvent>.broadcast();
    final userAccel = StreamController<UserAccelerometerEvent>.broadcast();
    final gyro = StreamController<GyroscopeEvent>.broadcast();
    final src = MiniProgramMotionSource(
      accel: accel.stream,
      userAccel: userAccel.stream,
      gyro: gyro.stream,
    );
    final frames = <Map<String, dynamic>>[];
    src.start(10, frames.add);

    // 传感器未出帧前不推空帧
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames, isEmpty);

    accel.add(AccelerometerEvent(0, 0, 9.8, DateTime.now()));
    userAccel.add(UserAccelerometerEvent(1, 0, 0, DateTime.now()));
    gyro.add(GyroscopeEvent(0.1, 0.2, 0.3, DateTime.now()));
    await pumpEventQueue(); // 三流 latest 就绪(微任务排空)
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames, hasLength(1));
    expect(frames.first['accel'], {'x': 0.0, 'y': 0.0, 'z': 9.8});
    expect(frames.first['userAccel'], {'x': 1.0, 'y': 0.0, 'z': 0.0});
    expect(frames.first['gyro'], {'x': 0.1, 'y': 0.2, 'z': 0.3});

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames, hasLength(2)); // 持续推送

    src.stop();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames, hasLength(2)); // stop 后不再推

    await accel.close();
    await userAccel.close();
    await gyro.close();
  });

  test('pause 停推 resume 恢复;重复 start 幂等替换并取最新帧', () async {
    final accel = StreamController<AccelerometerEvent>.broadcast();
    final userAccel = StreamController<UserAccelerometerEvent>.broadcast();
    final gyro = StreamController<GyroscopeEvent>.broadcast();
    final src = MiniProgramMotionSource(
      accel: accel.stream,
      userAccel: userAccel.stream,
      gyro: gyro.stream,
    );
    final frames = <Map<String, dynamic>>[];
    src.start(10, frames.add);
    accel.add(AccelerometerEvent(0, 0, 9.8, DateTime.now()));
    await pumpEventQueue();

    src.pause();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames, isEmpty); // 暂停期间不推

    src.resume();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames, hasLength(1)); // 恢复即续推

    // 重复 start:停旧起新,帧流向新目标且取 stop 清空后的最新帧
    final frames2 = <Map<String, dynamic>>[];
    src.start(10, frames2.add);
    accel.add(AccelerometerEvent(1, 0, 0, DateTime.now()));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(frames2, hasLength(1));
    expect(frames2.first['accel'], {'x': 1.0, 'y': 0.0, 'z': 0.0});
    expect(frames, hasLength(1)); // 旧目标不再收

    src.stop();
    await accel.close();
    await userAccel.close();
    await gyro.close();
  });
}
