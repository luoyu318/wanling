import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/notification_payload.dart';

/// 通知渠道 ID 常量。
class _Channels {
  /// 消息通知渠道：HIGH 优先级，弹横幅 + 声音 + 震动
  static const messages = 'wanling_messages';

  /// 前台服务常驻标志：LOW 优先级，无声音
  static const service = 'wanling_service';
}

/// 通知点击回调类型。调用方实现后注入。
typedef OnNotificationTap = void Function(NotificationPayload payload);

/// flutter_local_notifications 单例封装。
/// 全局单例（不通过 Riverpod 注入），方便 service isolate 内直接调。
class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  /// 点击回调。由 main.dart 在初始化时设置。
  OnNotificationTap? onTap;

  /// 冷启动时拉起 APP 的 payload（用户从通知点开 APP）。
  /// 由 main.dart 在初始化时通过 [consumeLaunchPayload] 读取。
  NotificationPayload? _launchPayload;

  /// 初始化插件 + channel + 点击监听。
  /// 必须在 main() 里 runApp 前调一次。
  Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onTap,
    );

    // 创建两个 channel（Android 8+ 强制）
    if (Platform.isAndroid) {
      await _createAndroidChannels();
    }

    // 检查冷启动 payload
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      _launchPayload = NotificationPayload.fromJsonString(
        launchDetails!.notificationResponse?.payload,
      );
    }
  }

  Future<void> _createAndroidChannels() async {
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // 消息通知：HIGH 优先级弹横幅
    const messagesChannel = AndroidNotificationChannel(
      _Channels.messages,
      '消息通知',
      description: '收到 agent 发来的新消息时通知',
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
    );

    // 服务常驻：LOW 优先级
    const serviceChannel = AndroidNotificationChannel(
      _Channels.service,
      '后台服务',
      description: 'APP 在后台运行时显示常驻通知',
      importance: Importance.low,
      showBadge: false,
    );

    await androidPlugin?.createNotificationChannel(messagesChannel);
    await androidPlugin?.createNotificationChannel(serviceChannel);
  }

  /// 申请通知权限（Android 13+）。返回是否已授权。
  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await androidPlugin?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// 弹一条新消息通知。
  /// [payload] 含 convId/agentId/agentName，点击时用于路由跳转。
  Future<void> showMessageNotification({
    required NotificationPayload payload,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _Channels.messages,
      '消息通知',
      channelDescription: '收到 agent 发来的新消息时通知',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      styleInformation: DefaultStyleInformation(true, true),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    // notification id 用 convId.hashCode 保证同一会话覆盖更新（不堆叠）
    final id = payload.convId.hashCode;
    await _plugin.show(
      id,
      payload.agentName,
      body,
      details,
      payload: payload.toJsonString(),
    );
  }

  /// 取冷启动 payload（用户从通知拉起 APP 时携带的会话信息）。
  /// 取一次后清空，避免重复跳转。
  NotificationPayload? consumeLaunchPayload() {
    final p = _launchPayload;
    _launchPayload = null;
    return p;
  }

  void _onTap(NotificationResponse response) {
    final payload = NotificationPayload.fromJsonString(response.payload);
    if (payload != null) {
      onTap?.call(payload);
    }
  }
}
