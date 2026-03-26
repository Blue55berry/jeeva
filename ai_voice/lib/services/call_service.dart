import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:phone_state/phone_state.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:record/record.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import '../models/call_record.dart';
import '../services/database_service.dart';
import '../services/blockchain_service.dart';
import '../services/threat_registry_service.dart';
import '../services/notification_service.dart';

class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal() {
    // Listen for commands from the Overlay
    const MethodChannel('voxshield/overlay_messenger').setMethodCallHandler((call) async {
       if (call.method == 'toggle_record') {
         await toggleManualRecording();
       } else if (call.method == 'report_scam') {
         debugPrint('[CallService] ⚖️ Reporting number to Cyber Crime Registry: $_currentNumber');
         await _db.reportScam(_currentNumber, currentRiskScore.value, evidencePath: _recordingPath);
         // Force update overlay to show blocked state
         await _sendDataToOverlay(_currentNumber, 1.0, 'blocked');
       }
    });
  }

  final DatabaseService _db = DatabaseService();
  final BlockchainService _blockchain = BlockchainService();
  final ThreatRegistryService _threatRegistry = ThreatRegistryService();
  final NotificationService _notifications = NotificationService();
  
  StreamSubscription? _phoneStateSubscription;
  VoidCallback? onCallEnded;
  
  // Audio Recording for real-time analysis
  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _recordingPath;
  bool _isRecording = false;
  bool _isRealAnalysis = false;
  
  // Call State Tracking
  bool _isInCall = false;
  bool _overlayActive = false;
  bool _showOverlayOnCallPreference = true;
  bool _isManualRecording = false; // User-triggered full call recording
  String _currentNumber = '';
  DateTime? _callStartTime;
  String _callDirection = ''; // 'incoming', 'outgoing'
  String? _currentContactName;
  bool _callWasAnswered = false;

  final ValueNotifier<bool> showOverlay = ValueNotifier(false);
  final ValueNotifier<double> currentRiskScore = ValueNotifier(0.0);
  final ValueNotifier<String> callerNumber = ValueNotifier('');

  Future<bool> requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.phone, // READ_PHONE_STATE
      Permission.microphone,
      Permission.storage,
      Permission.notification,
      Permission.contacts,
      // Permission.ignoreBatteryOptimizations, // Helps background performance
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  Future<void> ensureOverlayPermission() async {
    try {
      final bool isGranted = await FlutterOverlayWindow.isPermissionGranted();
      if (!isGranted) {
        await FlutterOverlayWindow.requestPermission();
      }
    } catch (e) {
      debugPrint('Overlay permission error: $e');
    }
  }

  void startListening() async {
    _phoneStateSubscription?.cancel();
    await _notifications.init(onAction: (action) {
      if (action == 'show_overlay') {
        showManualOverlay();
      }
    });
    debugPrint('[CallService] Starting phone state listener...');
    
    // 🛡️ PERSISTENT SERVICE: Show an ongoing notification to prevent MIUI from killing the listener
    _notifications.showPersistentGuardNotification();
    
    _phoneStateSubscription = PhoneState.stream.listen(
      (event) {
        debugPrint('[CallService] Phone event: ${event.status}, number: ${event.number}');
        String number = event.number ?? 'Unknown';
        if (number.isEmpty) number = 'Unknown';
        
        switch (event.status) {
          case PhoneStateStatus.CALL_INCOMING:
            _handleIncomingCall(number);
            break;
          case PhoneStateStatus.CALL_STARTED:
            _handleCallStarted(number);
            break;
          case PhoneStateStatus.CALL_ENDED:
            _handleCallEnded();
            break;
          case PhoneStateStatus.NOTHING:
            // Small delay to prevent flickering
            Future.delayed(const Duration(seconds: 1), () {
               if (!_isInCall && _overlayActive) _closeOverlay();
            });
            break;
        }
      },
      onError: (error) {
        debugPrint('[CallService] Phone state stream error: $error');
      },
    );
  }

  void _handleIncomingCall(String number) async {
    debugPrint('[CallService] Incoming call: $number');
    _isInCall = true;
    _currentNumber = number;
    _callDirection = 'incoming';
    _callWasAnswered = false;
    _callStartTime = DateTime.now();
    callerNumber.value = number;
    
    debugPrint('[CallService] 📞 INCOMING CALL DETECTED: $number');
    
    // Always enable overlay for incoming calls as per latest request
    _showOverlayOnCallPreference = true;
    
    // REDUNDANCY LAYER 1: Immediate Launch
    await _activateOverlay(number, currentRiskScore.value, 'incoming');
    
    // 🛡️ BLOCKCHAIN CHECK: Known Scam Detection
    final securityInfo = await _db.checkNumberSecurity(_currentNumber);
    if (securityInfo != null && securityInfo['is_blocked'] == 1) {
       debugPrint('[CallService] 🛑 BLOCKCHAIN: Known scammer detected! $_currentNumber');
       currentRiskScore.value = 1.0;
       await _activateOverlay(_currentNumber, 1.0, 'blocked');
       return;
    }
    
    // Non-blocked calls proceed with notifications if needed
    _notifications.showInterceptorStarted(number: _currentContactName ?? number);
    
    // REDUNDANCY LAYER 2: Delayed Launch (helps on MIUI/POCO)
    await Future.delayed(const Duration(milliseconds: 700));
    bool stillMissing = !await FlutterOverlayWindow.isActive();
    if (stillMissing && _isInCall) {
       await _activateOverlay(number, currentRiskScore.value, 'incoming');
    }
  }

  void _handleCallStarted(String number) async {
    debugPrint('[CallService] 📞 CALL STARTED: $number');
    
    // Resolve contact name if possible
    _currentContactName = await _resolveContactName(number);
    
    // Notification disabled at user request
    // _notifications.showInterceptorStarted(number: _currentContactName ?? number);
    
    _isInCall = true;
    _currentNumber = number.isNotEmpty ? number : _currentNumber;
    _callWasAnswered = true;
    
    if (_callDirection.isEmpty) {
      _callDirection = 'outgoing'; // Started without incoming -> outgoing
    }
    
    _callStartTime ??= DateTime.now();
    callerNumber.value = _currentNumber;
    
    if (!_overlayActive) {
      _showOverlayOnCallPreference = true;
      
      if (_showOverlayOnCallPreference) {
        await _activateOverlay(_currentNumber, currentRiskScore.value, 'started');
      }
    } else {
      await _sendDataToOverlay(_currentNumber, currentRiskScore.value, 'started');
    }
    
    // 🛡️ BLOCKCHAIN CHECK: Known Scam Detection
    final securityInfo = await _db.checkNumberSecurity(_currentNumber);
    if (securityInfo != null && securityInfo['is_blocked'] == 1) {
       debugPrint('[CallService] 🛑 BLOCKCHAIN: Known scammer detected! $_currentNumber');
       currentRiskScore.value = 1.0;
       await _activateOverlay(_currentNumber, 1.0, 'blocked');
       return;
    }
    
    // Begin Dynamic Real-Time Analysis Loop
    _runContinuousAnalysis();
    
    // 🛡️ NEW: OVERLAY WATCHDOG
    // On some devices (MIUI/POCO), the overlay might fail to launch or be killed by the system.
    // This watchdog ensures it stays visible throughout the call.
    Timer.periodic(const Duration(seconds: 5), (timer) async {
       if (!_isInCall) {
         timer.cancel();
         return;
       }
       
       bool isActive = await FlutterOverlayWindow.isActive();
       if (!isActive && _isInCall) {
         debugPrint('[CallService] 🔄 Watchdog: Overlay missing during active call. Re-activating...');
         await _activateOverlay(_currentNumber, currentRiskScore.value, _callDirection);
       }
    });
  }

  // Helper to sync state to overlay immediately
  void _syncOverlayState() {
     if (_overlayActive) {
        _sendDataToOverlay(_currentNumber, currentRiskScore.value, _callDirection);
     }
  }

  Future<void> _runContinuousAnalysis() async {
    while (_isInCall) {
      try {
        if (!await _audioRecorder.hasPermission()) break;
        
        final Directory tempDir = await getTemporaryDirectory();
        _recordingPath = '${tempDir.path}/live_call_${DateTime.now().millisecondsSinceEpoch}.wav';
        
        try {
          // 🛡️ CRITICAL FIX: Handle mic lock on MIUI/POCO
          debugPrint('[CallService] 🎙️ Attempting to access microphone for analysis...');
          await _audioRecorder.start(
            const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
            path: _recordingPath!,
          );
          _isRecording = true;
          _syncOverlayState();
        } catch (e) {
          debugPrint('[CallService] ⚠️ MIC LOCKED by system dialer. Waiting for access...');
          _isRecording = false;
          _syncOverlayState();
          await Future.delayed(const Duration(seconds: 10)); // Long wait if mic is busy
          continue;
        }
        
        // Take a 7-second sample to detect masking/AI
        await Future.delayed(const Duration(seconds: 7));
        
        if (!_isInCall) {
          await _audioRecorder.stop();
          break;
        }

        final path = await _audioRecorder.stop();
        _isRecording = false;
        _syncOverlayState();
        
        if (path != null) {
          await _analyzeAudioFile(path);
        }
      } catch (e) {
        debugPrint('[CallService] Analysis loop error: $e');
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    _isRecording = false;
    _syncOverlayState();
  }

  Future<void> _analyzeAudioFile(String filePath) async {
    debugPrint('[CallService] Analyzing recording: $filePath');
    try {
      final prefs = await SharedPreferences.getInstance();
      String backendUrl = prefs.getString('backend_url') ?? 'http://127.0.0.1:8000';
      backendUrl = backendUrl.trim().replaceAll(RegExp(r'/+$'), ''); // Remove trailing slashes
      
      if (!backendUrl.startsWith('http')) {
        // Use http for IPs, localhost, or simple hostnames. https for everything else.
        if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}').hasMatch(backendUrl) || backendUrl.contains('localhost')) {
          backendUrl = 'http://$backendUrl';
        } else {
          backendUrl = 'https://$backendUrl';
        }
      }
      
      var uri = Uri.parse('$backendUrl/analyze/');
      var request = http.MultipartRequest('POST', uri);
      request.headers['x-api-key'] = 'voxshield_live_secure_v1';
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      var response = await request.send().timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final respStr = await response.stream.bytesToString();
        final data = json.decode(respStr);
        
        if (data['success'] == true) {
          double risk = data['risk_score'] ?? 0.0;
          String summary = data['summary'] ?? 'No detail provided.';
          currentRiskScore.value = risk;
          _isRealAnalysis = true;
          
          // Update overlay with real AI result
          await _sendDataToOverlay(_currentNumber, risk, 'analyzed');
          
          await _db.insertCallRecord(CallRecord(
            phoneNumber: _currentNumber,
            contactName: _currentContactName,
            callType: _callDirection,
            result: risk > 0.5 ? 'ai_blocked' : 'human_verified',
            riskScore: risk,
            timestamp: DateTime.now().toIso8601String(),
            recordingPath: filePath,
            isRealAnalysis: true,
            analysisSummary: summary,
          ));
          
          // Threat Registry logic
          if (risk > 0.6) {
            final db = await _db.getRawDatabase();
            if (db != null) {
              await _threatRegistry.reportThreat(
                db: db,
                phoneNumber: _currentNumber,
                riskScore: risk,
                threatType: 'deepfake',
                notes: 'Detected live on call',
              );
            }
            // Send Alert Notification
            await _notifications.showThreatAlert(
              title: '🚨 DEEPFAKE DETECTED',
              body: 'Active call exhibits high AI generation probability (${(risk*100).toInt()}%).',
              threatLevel: risk > 0.8 ? 'CRITICAL' : 'HIGH',
            );
          }
          
          // --- 🛡️ NEW: SILENT AUTO-RECORDING ---
          if (risk > 0.8 && !_isManualRecording) {
             debugPrint('[CallService] 🛡️ THREAT CRITICAL: Triggering Silent Evidence Recording...');
             // Automatically start a full-call manual recording session
             await toggleManualRecording(); 
          }
          
          debugPrint('[CallService] AI Backend Score: $risk');
        }
      } else {
        throw Exception("Backend failed with status: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint('[CallService] Analysis failed, simulating offline risk: $e');
      // If server is offline, simulate result or use Threat Registry backup
      _isRealAnalysis = false;
      if (currentRiskScore.value == 0.0) {
        currentRiskScore.value = (Random().nextDouble() * 0.4); // Bias to safe if unknown
        await _sendDataToOverlay(_currentNumber, currentRiskScore.value, 'analyzed');
      }
    }
  }

  Future<void> showManualOverlay() async {
    if (_isInCall && _currentNumber.isNotEmpty) {
      await _activateOverlay(_currentNumber, currentRiskScore.value, _callDirection);
    }
  }

  // Handle Recording Command from Overlay
  Future<void> toggleManualRecording() async {
    if (_isManualRecording) {
      debugPrint('[CallService] ⏹️ Stopping manual recording...');
      await _audioRecorder.stop();
      _isManualRecording = false;
    } else {
      if (await _audioRecorder.hasPermission()) {
        debugPrint('[CallService] 🎙️ Starting full call manual recording...');
        final Directory appDir = await getApplicationDocumentsDirectory();
        _recordingPath = '${appDir.path}/call_recording_${_currentNumber}_${DateTime.now().millisecondsSinceEpoch}.wav';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 44100, numChannels: 1),
          path: _recordingPath!,
        );
        _isManualRecording = true;
      }
    }
    _syncOverlayState();
  }

  Future<void> _activateOverlay(String number, double risk, String type) async {
    try {
      final bool isGranted = await FlutterOverlayWindow.isPermissionGranted();
      if (!isGranted) {
        debugPrint('[CallService] ⚠️ Cannot show overlay - Permission missing!');
        return;
      }

      // 1. Force close any existing zombie overlay
      await FlutterOverlayWindow.closeOverlay();
      await Future.delayed(const Duration(milliseconds: 200));

      // 2. Show Fresh Overlay with Retry logic
      debugPrint('[CallService] 🛡️ Attempting to launch AI Guard Overlay for $number...');
      
      bool success = false;
      for (int i = 0; i < 3; i++) {
        try {
          await FlutterOverlayWindow.showOverlay(
            enableDrag: true,
            overlayTitle: 'VoxShield AI',
            overlayContent: 'AI Call Protection Active',
            flag: OverlayFlag.defaultFlag,
            alignment: OverlayAlignment.centerRight,
            visibility: NotificationVisibility.visibilityPublic,
            positionGravity: PositionGravity.right,
            width: 300, 
            height: 500,
          );
          success = true;
          debugPrint('[CallService] ✅ Overlay Show SUCCESS (Attempt ${i+1})');
          break;
        } catch (e) {
          debugPrint('[CallService] ❌ Overlay Show FAILED (Attempt ${i+1}): $e');
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      
      if (!success) {
        debugPrint('[CallService] 🚨 CRITICAL: Failed to show overlay after all attempts.');
      }
      
      _overlayActive = true;
      showOverlay.value = true;
      await _sendDataToOverlay(number, risk, type);
    } catch (e) {
      debugPrint('[CallService] Overlay activation error: $e');
    }
  }

  Future<void> _sendDataToOverlay(String number, double risk, String type) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await Future.delayed(Duration(milliseconds: 300 + (attempt * 400)));
        final bool isActive = await FlutterOverlayWindow.isActive();
        if (isActive) {
          await FlutterOverlayWindow.shareData({
            'type': type,
            'number': number,
            'risk': risk,
            'isReal': _isRealAnalysis,
            'isRecording': _isRecording, // Added recording status for UI indicator
          });
          return;
        }
      } catch (e) {
        // ignore
      }
    }
  }

  Future<void> _closeOverlay() async {
    try {
      final bool isActive = await FlutterOverlayWindow.isActive();
      if (isActive) await FlutterOverlayWindow.closeOverlay();
    } catch (e) {
      debugPrint('[Call सर्विस] Overlay close error: $e');
    }
    _overlayActive = false;
    showOverlay.value = false;
  }

  void _handleCallEnded() async {
    debugPrint('[CallService] Call ended');
    
    if (_isRecording) {
      await _audioRecorder.stop();
      _isRecording = false;
      _notifications.showRecordingNotification(isRecording: false);
    }
    
    await _closeOverlay();
    
    // Calculate precise call type
    String finalType = _callDirection;
    if (_callDirection == 'incoming' && !_callWasAnswered) {
      finalType = 'missed';
    } else if (finalType.isEmpty) {
      finalType = 'missed';
    }
    
    if (_isInCall && _callStartTime != null) {
      int duration = DateTime.now().difference(_callStartTime!).inSeconds;
      double risk = currentRiskScore.value;
      String result = risk > 0.6 ? 'ai_blocked' : 'human_verified';
      
      // Blockchain Verification Ledger Logging
      String blockHash = '';
      final db = await _db.getRawDatabase();
      if (db != null) {
         final blockInfo = await _blockchain.addBlock(
           db: db,
           phoneNumber: _currentNumber.isEmpty ? 'Unknown' : _currentNumber,
           riskScore: risk,
           verdict: result,
           modelVersion: _isRealAnalysis ? 'Wav2Vec2-V2' : 'SimLocal-V1',
         );
         blockHash = blockInfo['block_hash'] ?? '';
      }

      // Save to database
      await _db.insertCallRecord(CallRecord(
        phoneNumber: _currentNumber.isNotEmpty ? _currentNumber : 'Unknown',
        contactName: _currentContactName,
        callType: finalType,
        result: result,
        riskScore: risk,
        timestamp: DateTime.now().toIso8601String(),
        duration: duration,
        recordingPath: _recordingPath,
        blockHash: blockHash,
        aiModelUsed: _isRealAnalysis ? 'Wav2Vec2' : 'simulated',
        isRealAnalysis: _isRealAnalysis,
      ));
      
      onCallEnded?.call();
    }
    
    // Reset State
    _isInCall = false;
    _currentNumber = '';
    _callStartTime = null;
    _callDirection = '';
    _callWasAnswered = false;
    _isRealAnalysis = false;
    currentRiskScore.value = 0.0;
  }

  // Add demo record
  Future<void> addDemoRecord() async {
    Random rng = Random();
    double risk = (rng.nextDouble() * 100).roundToDouble() / 100;
    String result = risk > 0.5 ? 'ai_blocked' : 'human_verified';
    String phone = '+1 (555) ${100 + rng.nextInt(900)}-${1000 + rng.nextInt(9000)}';
    
    String blockHash = '';
    final db = await _db.getRawDatabase();
    if (db != null) {
      final blockInfo = await _blockchain.addBlock(
        db: db,
        phoneNumber: phone,
        riskScore: risk,
        verdict: result,
        modelVersion: 'Demo-Gen-V1',
      );
      blockHash = blockInfo['block_hash'] ?? '';
    }
    
    await _db.insertCallRecord(CallRecord(
      phoneNumber: phone,
      callType: ['incoming', 'outgoing', 'missed'][rng.nextInt(3)],
      result: result,
      riskScore: risk,
      timestamp: DateTime.now().subtract(Duration(minutes: rng.nextInt(120))).toIso8601String(),
      duration: rng.nextInt(300),
      blockHash: blockHash,
    ));
    onCallEnded?.call();
  }

  void dispose() {
    _phoneStateSubscription?.cancel();
    _audioRecorder.dispose();
    showOverlay.dispose();
    currentRiskScore.dispose();
    callerNumber.dispose();
  }

  Future<String?> _resolveContactName(String number) async {
    if (number == 'Unknown' || number.isEmpty) return null;
    try {
      final bool hasPermission = await FlutterContacts.requestPermission(readonly: true);
      if (hasPermission) {
        final List<Contact> contacts = await FlutterContacts.getContacts(withProperties: true);
        final normalizedTarget = number.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
        for (var contact in contacts) {
          for (var phone in contact.phones) {
            final normalizedPhone = phone.number.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
            if (normalizedPhone.contains(normalizedTarget) || normalizedTarget.contains(normalizedPhone)) {
              return contact.displayName;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[CallService] Contact lookup error: $e');
    }
    return null;
  }
}
