import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

typedef NotificationActionCallback = void Function(String action);

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  NotificationActionCallback? onActionReceived;
  bool _initialized = false;

  Future<void> init({NotificationActionCallback? onAction}) async {
    if (_initialized) return;
    onActionReceived = onAction;

    // Initialize native android notification
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    
    // Initialize native ios notification
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint('[Notifications] User tapped: ${response.id}, action: ${response.actionId}');
        if (response.actionId != null) {
          onActionReceived?.call(response.actionId!);
        } else if (response.payload == 'open_dashboard') {
          // Dashboard normally opens by default on Android
        }
      },
    );

    _initialized = true;
    debugPrint('[Notifications] Initialized');
  }

  Future<void> showThreatAlert({
    required String title,
    required String body,
    required String threatLevel,
  }) async {
    await init();

    // Customization based on threat level
    String channelId = 'voxshield_alerts';
    String channelName = 'VoxShield Threat Alerts';

    // Different priority based on level
    Importance importance = Importance.high;
    Priority priority = Priority.high;
    
    if (threatLevel == 'CRITICAL') {
      importance = Importance.max;
      priority = Priority.max;
    }

    AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: importance,
      priority: priority,
      ticker: 'VoxShield Alert',
      color: threatLevel == 'CRITICAL' ? const Color(0xFFE74C3C) : const Color(0xFFD4A843),
      enableVibration: true,
      playSound: true,
      styleInformation: BigTextStyleInformation(body),
    );

    const DarwinNotificationDetails iOSPlatformChannelSpecifics = DarwinNotificationDetails();

    NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: iOSPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecond, // unique ID
      title,
      body,
      platformChannelSpecifics,
      payload: 'threat_alert',
    );
  }

  Future<void> showRecordingNotification({required bool isRecording}) async {
    await init();

    if (!isRecording) {
      await flutterLocalNotificationsPlugin.cancel(999); // Specific ID for recording
      return;
    }

    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'voxshield_recording',
      'Active Recording',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true, // Cannot be swiped away while recording
      autoCancel: false,
      icon: '@mipmap/ic_launcher',
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      999, // Static ID for the ongoing recording
      'VoxShield AI',
      'Actively analyzing call audio...',
      platformChannelSpecifics,
    );
  }

  Future<void> showInterceptorStarted({required String number}) async {
    await init();
    
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'voxshield_system',
      'VoxShield Status',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFFB8860B),
      fullScreenIntent: true,
      actions: [
        AndroidNotificationAction('show_overlay', 'Show Live Guard', showsUserInterface: true),
        AndroidNotificationAction('view_history', 'View History'),
      ],
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      101, // unique ID
      '🛡️ AI Interceptor Active',
      'Call with $number is being monitored. Click for details.',
      platformChannelSpecifics,
      payload: 'open_dashboard',
    );
  }

  Future<void> showPersistentGuardNotification() async {
    await init();
    
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'voxshield_guard',
      'AI Guard Protection',
      channelDescription: 'Ongoing call monitoring status',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      color: Color(0xFFD4A843),
      icon: '@mipmap/ic_launcher',
      showWhen: true,
      fullScreenIntent: true, // Key for stability on Chinese OS skins
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      888, // Constant ID for the guard
      'VoxShield Guard Active',
      'Monitoring for AI Voice threats in real-time.',
      platformChannelSpecifics,
      payload: 'open_dashboard',
    );
  }
}
