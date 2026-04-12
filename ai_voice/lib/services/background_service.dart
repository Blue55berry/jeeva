import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'call_service.dart';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // Configure notifications for the foreground service
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'voxshield_background',
    'VoxShield Background Guard',
    description: 'This channel is used for continuous background AI protection.',
    importance: Importance.max, // Set to max to keep service high priority
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'voxshield_background',
      initialNotificationTitle: 'VoxShield AI Active',
      initialNotificationContent: 'Continuous call monitoring is protecting you.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // Initialize Flutter bindings for background execution
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  // Instantiate CallService natively in this Isolate
  final callService = CallService();
  
  // Start the actual phone state listener from the background
  try {
    callService.startListening();
    debugPrint("[BackgroundService] Call Service listener registered successfully in the background isolate.");
  } catch (e) {
    debugPrint("[BackgroundService] Error starting Call Service: $e");
  }

  // Handle service events (like stop requested from UI)
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService(); // Force foreground immediately
    
    // Periodic "I am alive" pulse for aggressive OS skins (Xiaomi/Oppo)
    // Low frequency (30 min) keeps it professional without battery drain
    Timer.periodic(const Duration(minutes: 30), (timer) async {
       if (await service.isForegroundService()) {
         service.setForegroundNotificationInfo(
           title: "VoxShield AI Active",
           content: "Your AI Guardian is protecting calls.",
         );
       }
    });

    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }
  
  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}
