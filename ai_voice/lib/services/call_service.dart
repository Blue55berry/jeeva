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

import '../models/call_record.dart';
import '../services/database_service.dart';
import '../services/blockchain_service.dart';
import '../services/threat_registry_service.dart';
import '../services/notification_service.dart';

class CallService {
  static const int _compactOverlaySize = 130;
  Timer? _watchdogTimer;

  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  final DatabaseService _db = DatabaseService();
  final BlockchainService _blockchain = BlockchainService();
  final ThreatRegistryService _threatRegistry = ThreatRegistryService();
  final NotificationService _notifications = NotificationService();
  
  StreamSubscription? _phoneStateSubscription;
  StreamSubscription? _overlayMessageSubscription;
  VoidCallback? onCallEnded;
  
  // Audio Recording for real-time analysis
  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _recordingPath;
  bool _isRecording = false;
  bool _isRealAnalysis = false;
  String? _latestAnalysisSummary;

  // ── Session Tracking (new real-time backend) ──────────────────────────
  String? _currentSessionId;           // server-side session ID
  int _voiceSwitchCount = 0;           // mid-call voice switches detected
  double _emaRisk = 0.0;               // exponential moving average risk from server
  
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
    _overlayMessageSubscription ??= FlutterOverlayWindow.overlayListener.listen(
      (data) async {
        if (data is! Map) return;
        final dynamic action = data['action'];
        if (action == 'toggle_record') {
          await toggleManualRecording();
        } else if (action == 'report_scam') {
          String? evidence;
          if (_isManualRecording ||
              (_recordingPath != null && File(_recordingPath!).existsSync())) {
            evidence = _recordingPath;
          }

          currentRiskScore.value = 1.0;
          _latestAnalysisSummary ??= 'Reported as scam during live call.';
          await _db.reportScam(
            _currentNumber,
            currentRiskScore.value,
            evidencePath: evidence,
          );
          await _uploadReportToBackend(
            _currentNumber,
            currentRiskScore.value,
            evidence,
          );
          await _sendDataToOverlay(_currentNumber, 1.0, 'blocked');
        }
      },
    );
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
            if (_isInCall) {
              _handleCallEnded();
            } else {
              Future.delayed(const Duration(milliseconds: 800), () {
                if (_overlayActive) {
                  _closeOverlay();
                }
              });
            }
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
       currentRiskScore.value = 1.0;
       await _activateOverlay(_currentNumber, 1.0, 'blocked');
       return;
    }
    
    // Non-blocked calls proceed with notifications if needed
    _notifications.showInterceptorStarted(number: _currentContactName ?? number);
    
    // REDUNDANCY LAYER 2: Delayed Launch (helps on MIUI/POCO)
    await Future.delayed(const Duration(milliseconds: 700));
    bool stillMissing = !await _isOverlayActive();
    if (stillMissing && _isInCall) {
       await _activateOverlay(number, currentRiskScore.value, 'incoming');
    }
  }

  void _handleCallStarted(String number) async {
    debugPrint('[CallService] 📞 CALL STARTED: $number');
    
    // Resolve contact name if possible
    _currentContactName = await _resolveContactName(number);
    
    // Start backend session tracking
    await _startCallSession(number);
    
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
       currentRiskScore.value = 1.0;
       await _activateOverlay(_currentNumber, 1.0, 'blocked');
       if (!_isManualRecording) {
         debugPrint('[CallService] 🛡️ Auto-recording blocked known scammer for evidence...');
         await toggleManualRecording();
       }
       return;
    }
    
    // Begin Dynamic Real-Time Analysis Loop
    _runContinuousAnalysis();
    
    // 🛡️ NEW: OVERLAY WATCHDOG
    // On some devices (MIUI/POCO), the overlay might fail to launch or be killed by the system.
    // This watchdog ensures it stays visible throughout the call.
    // Cancel previous watchdog if any
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
       if (!_isInCall) {
         timer.cancel();
         _watchdogTimer = null;
         return;
       }
       
       bool isActive = await _isOverlayActive();
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

  /// Returns the cleaned-up backend URL with proper http/https prefix.
  String _buildBackendUrl(String raw) {
    String url = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (!url.startsWith('http')) {
      if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}').hasMatch(url) ||
          url.contains('localhost')) {
        url = 'http://$url';
      } else {
        url = 'https://$url';
      }
    }
    return url;
  }

  /// Start a server-side call session when the call begins.
  Future<void> _startCallSession(String phoneNumber) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backendUrl = _buildBackendUrl(
          prefs.getString('backend_url') ?? 'http://127.0.0.1:8000');

      final response = await http.post(
        Uri.parse('$backendUrl/session/start'),
        headers: {
          'x-api-key': 'voxshield_live_secure_v1',
          'Content-Type': 'application/json',
        },
        body: json.encode({'phone_number': phoneNumber}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _currentSessionId = data['session_id'] as String?;
        debugPrint('[CallService] ✅ Session started: $_currentSessionId');
      }
    } catch (e) {
      debugPrint('[CallService] ⚠️ Could not start session (offline?): $e');
      _currentSessionId = null;
    }
  }

  /// End the server-side session when the call ends.
  Future<Map<String, dynamic>?> _endCallSession() async {
    if (_currentSessionId == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final backendUrl = _buildBackendUrl(
          prefs.getString('backend_url') ?? 'http://127.0.0.1:8000');

      final response = await http.post(
        Uri.parse('$backendUrl/session/$_currentSessionId/end'),
        headers: {'x-api-key': 'voxshield_live_secure_v1'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('[CallService] 🔚 Session ended: $_currentSessionId | verdict=${data['final_verdict']}');
        return data;
      }
    } catch (e) {
      debugPrint('[CallService] ⚠️ Could not end session: $e');
    }
    return null;
  }

  Future<void> _analyzeAudioFile(String filePath) async {
    debugPrint('[CallService] Analyzing recording: $filePath');
    try {
      final prefs = await SharedPreferences.getInstance();
      final backendUrl = _buildBackendUrl(
          prefs.getString('backend_url') ?? 'http://127.0.0.1:8000');

      // ── Use session-based endpoint if we have a session, otherwise fall back ──
      final endpoint = _currentSessionId != null
          ? '$backendUrl/session/$_currentSessionId/analyze'
          : '$backendUrl/analyze/';

      var request = http.MultipartRequest('POST', Uri.parse(endpoint));
      request.headers['x-api-key'] = 'voxshield_live_secure_v1';
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      var response = await request.send().timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final respStr = await response.stream.bytesToString();
        final data = json.decode(respStr);

        if (data['success'] == true) {
          // Prefer EMA risk (session-aware rolling average) over raw segment risk
          double risk = (data['ema_risk'] as num?)?.toDouble()
              ?? (data['risk_score'] as num?)?.toDouble()
              ?? 0.0;
          String summary = data['summary'] ?? 'No detail provided.';
          bool voiceSwitched = data['voice_switched'] ?? false;
          _voiceSwitchCount = data['voice_switch_count'] ?? _voiceSwitchCount;
          _emaRisk = risk;

          currentRiskScore.value = risk;
          _isRealAnalysis = true;

          // Build overlay status string
          String status = 'analyzed';
          if (voiceSwitched) status = 'voice_switched';

          final identityMatch = data['identity_match'] == true;

          // Update overlay with enriched real-time result
          await _sendDataToOverlayEnriched(
            _currentNumber, risk, status,
            voiceSwitched: voiceSwitched,
            voiceSwitchCount: _voiceSwitchCount,
            pitchAnalysis: data['pitch_analysis'] ?? '',
            frequencyVariance: data['frequency_variance'] ?? '',
            identityMatch: identityMatch,
          );

          _latestAnalysisSummary = summary;

          // Voice-switch is a critical scam indicator
          if (voiceSwitched || risk > 0.6) {
            final db = await _db.getRawDatabase();
            if (db != null) {
              await _threatRegistry.reportThreat(
                db: db,
                phoneNumber: _currentNumber,
                riskScore: risk,
                threatType: voiceSwitched ? 'voice_clone' : 'deepfake',
                notes: voiceSwitched
                    ? 'Mid-call voice switch detected (scammer handoff)'
                    : 'Detected live on call',
              );

              // 🛡️ INSTANT CLOUD SYNC: Update Cyber Crime Site during the call
              await _db.reportScam(
                _currentNumber,
                risk,
                evidencePath: filePath,
              );
            }
            String alertTitle = voiceSwitched
                ? '🔄 VOICE SWITCH DETECTED'
                : '🚨 DEEPFAKE DETECTED';
            String alertBody = voiceSwitched
                ? 'Mid-call speaker change detected — possible AI handoff scam! ($_voiceSwitchCount switch${_voiceSwitchCount > 1 ? 'es' : ''})'
                : 'Active call exhibits AI generation probability (${(risk * 100).toInt()}%).';
            await _notifications.showThreatAlert(
              title: alertTitle,
              body: alertBody,
              threatLevel: (risk > 0.8 || voiceSwitched) ? 'CRITICAL' : 'HIGH',
            );
          }

          // Silent auto-recording on critical risk
          if (risk > 0.8 && !_isManualRecording) {
            debugPrint('[CallService] 🛡️ CRITICAL THREAT: Starting silent evidence recording...');
            await toggleManualRecording();
          }

          debugPrint('[CallService] EMA Risk: $risk | Voice Switches: $_voiceSwitchCount');
        }
      } else {
        throw Exception('Backend returned status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[CallService] Analysis failed (offline fallback): $e');
      _isRealAnalysis = false;
      if (currentRiskScore.value == 0.0) {
        currentRiskScore.value = (Random().nextDouble() * 0.3);
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
      final path = await _audioRecorder.stop();
      debugPrint('[CallService] 📁 Recording saved to: $path');
      _isManualRecording = false;
    } else {
      if (await _audioRecorder.hasPermission()) {
        debugPrint('[CallService] 🎙️ Starting full call manual recording...');
        final Directory appDir = await getApplicationDocumentsDirectory();
        final folder = Directory('${appDir.path}/recordings');
        if (!folder.existsSync()) folder.createSync();
        
        _recordingPath = '${folder.path}/call_${_currentNumber}_${DateTime.now().millisecondsSinceEpoch}.wav';
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav, 
            sampleRate: 16000, // Better for AI analysis
            numChannels: 1,
            bitRate: 128000
          ),
          path: _recordingPath!,
        );
        _isManualRecording = true;
        debugPrint('[CallService] ⏺️ Recording active at: $_recordingPath');
      }
    }
    _syncOverlayState();
  }

  /// Upload the report and audio evidence to the remote backend
  Future<void> _uploadReportToBackend(String number, double risk, String? audioPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final baseUrl = prefs.getString('backend_url');
      if (baseUrl == null) return;

      var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/blockchain/report/'));
      request.headers['x-api-key'] = 'voxshield_live_secure_v1';
      
      request.fields['phone_hash'] = _blockchain.hashPhoneNumber(number);
      request.fields['phone_display'] = number;
      request.fields['verdict'] = risk > 0.6 ? 'ai_scam' : 'suspicious';
      request.fields['threat_level'] = risk > 0.8 ? 'CRITICAL' : 'HIGH';
      request.fields['risk_score'] = risk.toString();

      if (audioPath != null && File(audioPath).existsSync()) {
        request.files.add(await http.MultipartFile.fromPath('file', audioPath));
        debugPrint('[CallService] ☁️ Uploading audio evidence: $audioPath');
      }

      var response = await request.send();
      if (response.statusCode == 200) {
        debugPrint('[CallService] ✅ Successfully posted to Global Blockchain Registry');
      } else {
        debugPrint('[CallService] ❌ Failed to post report: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[CallService] Global reporting error: $e');
    }
  }

  Future<void> _activateOverlay(String number, double risk, String type) async {
    try {
      final bool isGranted = await FlutterOverlayWindow.isPermissionGranted();
      if (!isGranted) {
        debugPrint('[CallService] Overlay permission missing, requesting access again.');
        await FlutterOverlayWindow.requestPermission();
        return;
      }

      final bool wasActive = await _isOverlayActive();
      if (wasActive) {
        // Already active — just send data update
        _overlayActive = true;
        showOverlay.value = true;
        await _sendDataToOverlay(number, risk, type);
        return;
      }

      debugPrint('[CallService] Attempting to launch AI Guard Overlay for $number...');
      
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
            width: _compactOverlaySize,
            height: _compactOverlaySize,
          );

          await Future.delayed(const Duration(milliseconds: 400));
          success = await _isOverlayActive();
          if (success) {
            debugPrint('[CallService] Overlay show success on attempt ${i + 1}');
            break;
          }
        } catch (e) {
          debugPrint('[CallService] Overlay show failed on attempt ${i + 1}: $e');
        }

        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      _overlayActive = success;
      showOverlay.value = success;

      if (!success) {
        debugPrint('[CallService] Failed to activate overlay after all retries.');
        return;
      }
      
      await _sendDataToOverlay(number, risk, type);
    } catch (e) {
      _overlayActive = false;
      showOverlay.value = false;
      debugPrint('[CallService] Overlay activation error: $e');
    }
  }

  Future<void> _sendDataToOverlay(String number, double risk, String type) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await Future.delayed(Duration(milliseconds: 300 + (attempt * 400)));
        final bool isActive = await _isOverlayActive();
        if (isActive) {
          await FlutterOverlayWindow.shareData({
            'type': type,
            'number': number,
            'risk': risk,
            'emaRisk': _emaRisk,
            'isReal': _isRealAnalysis,
            'isRecording': _isRecording,
            'showRecord': true,
            'voiceSwitchCount': _voiceSwitchCount,
          });
          return;
        }
      } catch (e) {
        // ignore
      }
    }
  }

  /// Extended overlay push that includes pitch/frequency/voice-switch data.
  Future<void> _sendDataToOverlayEnriched(
    String number,
    double risk,
    String type, {
    bool voiceSwitched = false,
    int voiceSwitchCount = 0,
    String pitchAnalysis = '',
    String frequencyVariance = '',
    bool identityMatch = false,
  }) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await Future.delayed(Duration(milliseconds: 300 + (attempt * 400)));
        final bool isActive = await _isOverlayActive();
        if (isActive) {
          await FlutterOverlayWindow.shareData({
            'type': type,
            'number': number,
            'risk': risk,
            'emaRisk': _emaRisk,
            'isReal': _isRealAnalysis,
            'isRecording': _isRecording,
            'showRecord': true,
            'voiceSwitched': voiceSwitched,
            'voiceSwitchCount': voiceSwitchCount,
            'pitchAnalysis': pitchAnalysis,
            'frequencyVariance': frequencyVariance,
            'identityMatch': identityMatch,
          });
          return;
        }
      } catch (e) {
        // ignore
      }
    }
  }

  Future<void> _closeOverlay() async {
    // Cancel watchdog timer immediately
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    
    try {
      final bool isActive = await _isOverlayActive();
      if (!isActive) {
        _overlayActive = false;
        showOverlay.value = false;
        return;
      }

      // Send 'close' signal so the overlay widget self-dismisses cleanly
      try {
        await FlutterOverlayWindow.shareData({'type': 'close'});
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}

      // Force close the overlay window
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          await FlutterOverlayWindow.closeOverlay();
          await Future.delayed(const Duration(milliseconds: 150));
          if (!await _isOverlayActive()) break;
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[CallService] Overlay close error: $e');
    }
    _overlayActive = false;
    showOverlay.value = false;
  }

  bool _isEndingSession = false;

  void _handleCallEnded() async {
    if (!_isInCall || _isEndingSession) return;
    _isEndingSession = true;
    final bool shouldPersistRecord = _callStartTime != null;
    _isInCall = false; // Mark inactive immediately to stop analysis loops
    
    // Cancel watchdog immediately
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    
    debugPrint('[CallService] 🔚 Handling call ended event...');
    
    // Stop recording and analysis ASAP
    if (_isRecording) {
      await _audioRecorder.stop();
      _isRecording = false;
      _notifications.showRecordingNotification(isRecording: false);
    }

    // End backend session tracking if active
    await _endCallSession();
    
    await _closeOverlay();
    
    // Calculate precise call type
    String finalType = _callDirection;
    if (_callDirection == 'incoming' && !_callWasAnswered) {
      finalType = 'missed';
    } else if (finalType.isEmpty) {
      finalType = 'missed';
    }
    
    if (shouldPersistRecord) {
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
        analysisSummary: _latestAnalysisSummary,
      ));
      
      // Auto-submit Cyber Crime Evidence for known/blocked scammers without delay
      if (risk >= 0.8 && _callWasAnswered) {
         debugPrint('[CallService] 🚨 Auto-submitting Cyber Crime Evidence...');
         await _db.reportScam(
           _currentNumber, 
           risk, 
           evidencePath: _recordingPath,
         );
      }
      
      onCallEnded?.call();
    }
    
    // Reset State
    _currentNumber = '';
    _callStartTime = null;
    _callDirection = '';
    _callWasAnswered = false;
    _isRealAnalysis = false;
    _latestAnalysisSummary = null;
    _currentSessionId = null;
    _voiceSwitchCount = 0;
    _emaRisk = 0.0;
    currentRiskScore.value = 0.0;
    _isEndingSession = false;
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
    _overlayMessageSubscription?.cancel();
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

  Future<bool> _isOverlayActive() async {
    try {
      return await FlutterOverlayWindow.isActive();
    } catch (e) {
      debugPrint('[CallService] Overlay active-state check failed: $e');
      return false;
    }
  }
}

