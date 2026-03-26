import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'dart:io';
import 'dart:async';

// Import our separated Screen components 
import 'screens/scanner_view.dart';
import 'screens/history_view.dart';
import 'screens/models_view.dart';
import 'screens/profile_view.dart';
import 'screens/auth_view.dart';
import 'services/database_service.dart';
import 'services/call_service.dart';
import 'models/user_profile.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

// ---- OVERLAY ENTRY POINT ----
// ---- OVERLAY ENTRY POINT ----
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CallOverlayWidget(),
    ),
  );
}

class CallOverlayWidget extends StatefulWidget {
  const CallOverlayWidget({super.key});

  @override
  State<CallOverlayWidget> createState() => _CallOverlayWidgetState();
}

class _CallOverlayWidgetState extends State<CallOverlayWidget> with SingleTickerProviderStateMixin {
  bool isExpanded = false;
  double riskScore = 0.0;
  String callerNumber = 'Detecting...';
    bool isRealAnalysis = false;
    bool isRecording = false;
    bool showRecord = true;
    late AnimationController _pulseController;
    StreamSubscription? _overlaySub;

    @override
    void initState() {
      super.initState();
      _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
      
      // Listen for data from CallService
      _overlaySub = FlutterOverlayWindow.overlayListener.listen((data) {
        if (data != null && data is Map) {
          if (mounted) {
            setState(() {
              riskScore = (data['risk'] as num?)?.toDouble() ?? 0.0;
              callerNumber = data['number'] ?? 'Unknown';
              isRealAnalysis = data['isReal'] ?? false;
              isRecording = data['isRecording'] ?? false;
              showRecord = data['showRecord'] ?? true;
            });
          }
        }
      });
    }

  @override
  void dispose() {
    _pulseController.dispose();
    _overlaySub?.cancel();
    super.dispose();
  }

  void _toggleSize() async {
    if (isExpanded) {
      // Small state
      await FlutterOverlayWindow.resizeOverlay(160, 160, true);
    } else {
      // Large state - increased height to fit all blockchain & reporting actions
      await FlutterOverlayWindow.resizeOverlay(280, 450, true);
    }
    setState(() => isExpanded = !isExpanded);
  }

  @override
  Widget build(BuildContext context) {
    bool isDanger = riskScore > 0.6;
    Color themeColor = isDanger ? const Color(0xFFE74C3C) : const Color(0xFFD4A843);

    return Material(
      color: Colors.transparent,
      child: Center(
        child: GestureDetector(
          onTap: _toggleSize,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            reverseDuration: const Duration(milliseconds: 400),
            layoutBuilder: (child, children) => Stack(children: [if (child != null) child]),
            transitionBuilder: (child, anim) {
              final scale = Tween<double>(begin: 0.8, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack));
              final fade = CurvedAnimation(parent: anim, curve: Curves.easeIn);
              return FadeTransition(opacity: fade, child: ScaleTransition(scale: scale, child: child));
            },
            child: isExpanded
                ? Container(
                    key: const ValueKey('expanded'),
                    width: 250,
                    margin: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: themeColor.withValues(alpha: 0.3), width: 1.5),
                      boxShadow: [
                         BoxShadow(color: themeColor.withValues(alpha: 0.1), blurRadius: 25, spreadRadius: 5),
                         BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 10))
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Header section
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                color: themeColor.withValues(alpha: 0.08),
                                child: Row(
                                  children: [
                                    Icon(riskScore >= 1.0 ? Icons.gavel_rounded : (isDanger ? Icons.warning_amber_rounded : Icons.shield_outlined), color: riskScore >= 1.0 ? Colors.red : themeColor, size: 20),
                                    const SizedBox(width: 10),
                                    Expanded(child: Text(riskScore >= 1.0 ? "CYBER CRIME BLOCKED" : "VOX SHIELD ACTIVE", style: TextStyle(letterSpacing: 1.2, fontSize: 10, fontWeight: FontWeight.w900, color: riskScore >= 1.0 ? Colors.red : themeColor))),
                                    GestureDetector(
                                      onTap: () => FlutterOverlayWindow.closeOverlay(),
                                      child: Icon(Icons.power_settings_new_rounded, color: Colors.grey.shade400, size: 18),
                                    ),
                                  ],
                                ),
                              ),
                              
                              Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  children: [
                                    Text(callerNumber, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                                    const SizedBox(height: 15),
                                    
                                    // Risk Score Ring
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        SizedBox(
                                          width: 80, height: 80,
                                          child: CircularProgressIndicator(
                                            value: riskScore,
                                            strokeWidth: 6,
                                            backgroundColor: themeColor.withValues(alpha: 0.1),
                                            valueColor: AlwaysStoppedAnimation<Color>(themeColor),
                                            strokeCap: StrokeCap.round,
                                          ),
                                        ),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text("${(riskScore * 100).toInt()}%", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: themeColor)),
                                            const Text("RISK", style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey)),
                                          ],
                                        ),
                                      ],
                                    ),
                                    
                                    const SizedBox(height: 15),
                                    Text(isDanger ? "⚠️ AI VOICE DETECTED" : "✅ HUMAN VERIFIED", style: TextStyle(color: themeColor, fontSize: 12, fontWeight: FontWeight.w800)),
                                    const SizedBox(height: 15),
                                    
                                    // Analysis Pills & Record Action
                                    Row(
                                      children: [
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: () => const MethodChannel('voxshield/overlay_messenger').invokeMethod('toggle_record'),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(vertical: 12),
                                              decoration: BoxDecoration(
                                                color: isRecording ? Colors.red.withValues(alpha: 0.15) : const Color(0xFFD4A843).withValues(alpha: 0.1),
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(color: isRecording ? Colors.red.withValues(alpha: 0.3) : const Color(0xFFD4A843).withValues(alpha: 0.2)),
                                              ),
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(isRecording ? Icons.stop_circle_rounded : Icons.fiber_manual_record_rounded, color: isRecording ? Colors.red : const Color(0xFFB8860B), size: 18),
                                                  const SizedBox(width: 8),
                                                  Text(isRecording ? "STOP RECORD" : "START RECORD", style: TextStyle(fontSize: 10, color: isRecording ? Colors.red : const Color(0xFF1A1A1A), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    // Blockchain Reporting Action
                                    Row(
                                      children: [
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: () => const MethodChannel('voxshield/overlay_messenger').invokeMethod('report_scam'),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(vertical: 12),
                                              decoration: BoxDecoration(
                                                color: Colors.orange.withValues(alpha: 0.1),
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                                              ),
                                              child: const Row(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(Icons.gavel_rounded, color: Colors.orange, size: 18),
                                                  SizedBox(width: 8),
                                                  Text("REPORT TO CYBER CRIME", style: TextStyle(fontSize: 10, color: Color(0xFF1A1A1A), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Container(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        color: isRealAnalysis ? const Color(0xFF2ECC71).withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(isRealAnalysis ? "REAL-TIME ENGINE ACTIVE" : "PREDICITVE ANALYSIS", style: TextStyle(fontSize: 9, color: isRealAnalysis ? const Color(0xFF27AE60) : Colors.grey.shade600, fontWeight: FontWeight.w900)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                : Container(
                    key: const ValueKey('compact'),
                    width: 70, height: 70,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: themeColor.withValues(alpha: 0.4), blurRadius: 15, spreadRadius: 0),
                          BoxShadow(color: Colors.black.withValues(alpha: 0.15), offset: const Offset(0, 4), blurRadius: 6),
                        ],
                    ),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 1.0, end: 1.1).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut)),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [themeColor, Color.fromARGB(255, (themeColor.r * 255).toInt() + 30, (themeColor.g * 255).toInt() + 30, (themeColor.b * 255).toInt())],
                          ),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 3),
                        ),
                        child: Center(
                          child: Icon(isDanger ? Icons.security_update_warning_rounded : Icons.shield_rounded, color: Colors.white, size: 34),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Check if biometric lock is enabled
  final db = DatabaseService();
  bool biometricEnabled = await db.isBiometricEnabled();
  
  runApp(PremiumShieldApp(requireAuth: biometricEnabled));
}

class PremiumShieldApp extends StatelessWidget {
  final bool requireAuth;
  const PremiumShieldApp({super.key, this.requireAuth = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoxShield AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8F6F2),
        fontFamily: 'Roboto',
      ),
      home: VoxSplashView(nextRequireAuth: requireAuth),
    );
  }
}

class VoxSplashView extends StatefulWidget {
  final bool nextRequireAuth;
  const VoxSplashView({super.key, required this.nextRequireAuth});

  @override
  State<VoxSplashView> createState() => _VoxSplashViewState();
}

class _VoxSplashViewState extends State<VoxSplashView> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => widget.nextRequireAuth ? const AuthView() : const PremiumDashboard(),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOutExpo,
          builder: (context, value, child) {
            return Opacity(
              opacity: value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.8 + (0.2 * value),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "VoxShield AI",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "PREMIUM INTERCEPTOR",
                      style: TextStyle(
                        color: const Color(0xFFD4A843).withValues(alpha: 0.8 * value),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6,
                      ),
                    ),
                    const SizedBox(height: 40),
                    // Adding a subtle elegant loader under the text
                    SizedBox(
                      width: 120,
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFFD4A843).withValues(alpha: value)),
                        minHeight: 2,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class PremiumDashboard extends StatefulWidget {
  const PremiumDashboard({super.key});

  @override
  State<PremiumDashboard> createState() => PremiumDashboardState();
}

class PremiumDashboardState extends State<PremiumDashboard> with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _holdController;
  late AnimationController _navAnimationController;
  late Animation<double> _navSlideAnimation;

  bool _isNavRevealed = false;
  int _currentNavIndex = 0;

  // Profile & Services
  final DatabaseService _db = DatabaseService();
  final CallService _callService = CallService();
  UserProfile _profile = UserProfile(name: 'Admin User', email: 'admin@intercept.ai');
  
  // Key for refreshing history
  final GlobalKey<HistoryViewState> _historyKey = GlobalKey<HistoryViewState>();

  // Permissions
  bool _permissionsRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _holdController = AnimationController(vsync: this, duration: const Duration(seconds: 2));

    _holdController.addListener(() {
      setState(() {}); 
      if (_holdController.value == 1.0 && !_isNavRevealed) {
        _triggerNavReveal();
      }
    });

    _navAnimationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _navSlideAnimation = Tween<double>(begin: 300, end: 0).animate(CurvedAnimation(parent: _navAnimationController, curve: Curves.easeOutExpo));

    _loadProfile();
    
    // Request permissions after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestAllPermissions();
    });
  }

  Future<void> _requestAllPermissions() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;

    final prefs = await SharedPreferences.getInstance();
    bool firstLaunch = prefs.getBool('first_launch') ?? true;

    if (!firstLaunch) {
      _initCallService();
      return;
    }

    // Show permission dialog
    if (mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _PermissionDialog(
          onComplete: () async {
            Navigator.of(ctx).pop();
            await prefs.setBool('first_launch', false);
            _initCallService();
          },
        ),
      );
    }
  }

  Future<void> _loadProfile() async {
    final profile = await _db.getUserProfile();
    if (mounted) {
      setState(() => _profile = profile);
    }
  }

  void _initCallService() async {
    // Ensure overlay permission is granted before listening for calls
    await _callService.ensureOverlayPermission();
    _callService.startListening();
    
    // When a call ends, refresh history
    _callService.onCallEnded = () {
      if (mounted) {
        _historyKey.currentState?.refreshHistory();
        setState(() {});
      }
    };
  }

  void updateProfile(UserProfile profile) {
    setState(() => _profile = profile);
  }

  void _triggerNavReveal() {
    setState(() => _isNavRevealed = true);
    _navAnimationController.forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[Dashboard] App Resumed: Restarting call guard safety check...');
      _callService.startListening();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdController.dispose();
    _navAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient - White & Gold
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFFFFDF8), Color(0xFFF5F0E8)],
                ),
              ),
            ),
          ),
          
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildHeader(),
                const SizedBox(height: 8),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: _buildCurrentView(),
                  ),
                ),
              ],
            ),
          ),

          // BOTTOM NAV
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                AnimatedOpacity(
                  opacity: _isNavRevealed ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: _isNavRevealed,
                    child: _buildShieldButton(),
                  ),
                ),
                if (_isNavRevealed)
                  _buildCurvedNav(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentView() {
    switch (_currentNavIndex) {
      case 0: return ScannerView(key: const ValueKey('scanner_tab'));
      case 1: return HistoryView(key: _historyKey);
      case 2: return const AnalyticsView(key: ValueKey('analytics_tab'));
      case 3: return ProfileView(key: const ValueKey('profile_tab'), onProfileUpdated: updateProfile);
      default: return ScannerView(key: const ValueKey('scanner_tab_default'));
    }
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () => setState(() => _currentNavIndex = 3),
            child: _buildProfileAvatar(),
          ),
          
          // Center Section: Logo + Name
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [

              const Text(
                "VoxShield AI",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ],
          ),

          // Right side: Active Wave Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFD4A843).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFFB8860B), size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileAvatar() {
    final imagePath = _profile.imagePath;
    if (imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync()) {
      return Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFD4A843), width: 2),
          image: DecorationImage(
            image: FileImage(File(imagePath)),
            fit: BoxFit.cover,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFD4A843).withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.security, color: Color(0xFFB8860B), size: 20),
    );
  }

  // ---- SHIELD BUTTON ----
  Widget _buildShieldButton() {
    double progress = _holdController.value;
    return Container(
      height: 100,
      alignment: Alignment.center,
      child: GestureDetector(
        onTapDown: (_) => _holdController.forward(),
        onTapUp: (_) { if (_holdController.value < 1.0) _holdController.reverse(); },
        onTapCancel: () { if (_holdController.value < 1.0) _holdController.reverse(); },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(width: 90, height: 90, decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFFD4A843).withValues(alpha: 0.3 + (progress * 0.5)), blurRadius: 30, spreadRadius: 8)])),
            SizedBox(width: 90, height: 90, child: CircularProgressIndicator(value: progress > 0 ? progress : null, strokeWidth: 3, valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFB8860B)), backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.2))),
            Container(
              width: 70, height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [Color(0xFFD4A843), Color(0xFFB8860B)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                border: Border.all(color: Colors.white.withValues(alpha: 0.7), width: 1.5),
              ),
              child: const Icon(Icons.shield_rounded, color: Colors.white, size: 32),
            )
          ],
        ),
      ),
    );
  }

  // ---- BOTTOM NAVIGATION ----
  Widget _buildCurvedNav() {
    double screenWidth = MediaQuery.of(context).size.width;
    double bottomPadding = MediaQuery.of(context).padding.bottom;

    return AnimatedBuilder(
      animation: _navAnimationController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _navSlideAnimation.value),
          child: CustomPaint(
            foregroundPainter: NavCurvePainter(),
            child: ClipPath(
              clipper: NavCurveClipper(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  height: 70 + bottomPadding,
                  width: screenWidth,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.95),
                    boxShadow: [BoxShadow(color: const Color(0xFFD4A843).withValues(alpha: 0.1), blurRadius: 20, offset: const Offset(0, -5))],
                  ),
                  padding: EdgeInsets.only(top: 12, bottom: bottomPadding > 0 ? bottomPadding : 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildNavIcon(0, Icons.grid_view_rounded, "Dashboard"),
                      _buildNavIcon(1, Icons.history_edu_rounded, "Calls"),
                      _buildNavIcon(2, Icons.bar_chart_rounded, "Analytics"),
                      _buildNavIcon(3, Icons.person_outline, "Profile"),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    );
  }

  Widget _buildNavIcon(int index, IconData iconData, String label) {
    bool isSelected = _currentNavIndex == index;
    Color activeColor = const Color(0xFFB8860B);
    Color inactiveColor = const Color(0xFF999999);
    Color color = isSelected ? activeColor : inactiveColor;
    return GestureDetector(
      onTap: () {
        setState(() => _currentNavIndex = index);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(horizontal: isSelected ? 14 : 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconData, color: color, size: 24),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: isSelected ? null : 0,
                child: Padding(
                  padding: EdgeInsets.only(left: isSelected ? 6.0 : 0.0),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- PERMISSION DIALOG ----
class _PermissionDialog extends StatefulWidget {
  final VoidCallback onComplete;
  const _PermissionDialog({required this.onComplete});

  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<_PermissionDialog> {
  int _currentStep = 0;
  final List<_PermissionItem> _permissions = [
    _PermissionItem(
      icon: Icons.phone_android_rounded,
      title: "Phone Call Access",
      description: "Required to track incoming calls and intercept AI voices.",
      permissions: [Permission.phone], // Implicitly includes READ_CALL_LOG on modern Android builds
    ),
    _PermissionItem(
      icon: Icons.mic_none_rounded,
      title: "AI Voice Listener",
      description: "Required to analyze call audio for deepfake detection.",
      permissions: [Permission.microphone],
    ),
    _PermissionItem(
      icon: Icons.folder_open_rounded,
      title: "Storage Access",
      description: "Required to save identified scam evidence and recordings.",
      permissions: [Permission.storage, Permission.photos],
    ),
    _PermissionItem(
      icon: Icons.contact_page_rounded,
      title: "Contact Recovery",
      description: "Identify family & friends by name in your history logs.",
      permissions: [Permission.contacts],
    ),
    _PermissionItem(
      icon: Icons.bolt_rounded,
      title: "Background Alerts",
      description: "Simply allow access to background and incoming notifications.",
      permissions: [Permission.notification, Permission.systemAlertWindow],
    ),
  ];

  List<bool> _granted = [];

  @override
  void initState() {
    super.initState();
    _granted = List.filled(_permissions.length, false);
    _checkExistingPermissions();
  }

  Future<void> _checkExistingPermissions() async {
    for (int i = 0; i < _permissions.length; i++) {
      bool allGranted = true;
      for (var perm in _permissions[i].permissions) {
        if (!await perm.isGranted) {
          allGranted = false;
          break;
        }
      }
      _granted[i] = allGranted;
    }
    if (mounted) setState(() {});
  }

  Future<void> _requestCurrent() async {
    final item = _permissions[_currentStep];
    Map<Permission, PermissionStatus> statuses = await item.permissions.request();
    
    bool allGranted = statuses.values.every((s) => s.isGranted);
    setState(() {
      _granted[_currentStep] = allGranted;
    });

    // Move to next step
    if (_currentStep < _permissions.length - 1) {
      setState(() => _currentStep++);
    } else {
      widget.onComplete();
    }
  }

  void _skipCurrent() {
    if (_currentStep < _permissions.length - 1) {
      setState(() => _currentStep++);
    } else {
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _permissions[_currentStep];
    bool isLast = _currentStep == _permissions.length - 1;
    bool isGranted = _granted[_currentStep];
    
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: isGranted ? const Color(0xFFD4A843) : Colors.transparent, 
            width: 2
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_permissions.length, (i) => Container(
                width: i == _currentStep ? 20 : 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: i == _currentStep 
                    ? const Color(0xFFD4A843) 
                    : _granted[i] 
                      ? const Color(0xFFD4A843) 
                      : const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(10),
                ),
              )),
            ),
            const SizedBox(height: 32),
            
            // Icon Background transition
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: isGranted ? const Color(0xFFD4A843) : const Color(0xFFF9F9F9),
                shape: BoxShape.circle,
                boxShadow: isGranted ? [
                  BoxShadow(color: const Color(0xFFD4A843).withValues(alpha: 0.3), blurRadius: 20, spreadRadius: 2)
                ] : [],
              ),
              child: Icon(
                isGranted ? Icons.check_circle_outline_rounded : item.icon, 
                color: isGranted ? Colors.white : const Color(0xFFB8860B), 
                size: 44
              ),
            ),
            const SizedBox(height: 24),
            
            // Title
            Text(item.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
            const SizedBox(height: 12),
            Text(item.description, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.5)),
            const SizedBox(height: 40),

            // Allow button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _requestCurrent,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isGranted ? const Color(0xFFB8860B) : const Color(0xFF1A1A1A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                child: Text(isGranted ? "Next Step" : "Grant Access", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            const SizedBox(height: 12),
            
            // Skip
            if (!isGranted)
              TextButton(
                onPressed: _skipCurrent,
                child: Text(isLast ? "Done" : "Skip", style: const TextStyle(color: Color(0xFF999999), fontSize: 14, fontWeight: FontWeight.normal)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PermissionItem {
  final IconData icon;
  final String title;
  final String description;
  final List<Permission> permissions;
  
  _PermissionItem({
    required this.icon, 
    required this.title, 
    required this.description, 
    required this.permissions,
  });
}

class NavCurveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    Path path = Path();
    path.moveTo(0, 16);
    path.quadraticBezierTo(size.width / 2, 0, size.width, 16);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }
  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

class NavCurvePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    Path path = Path();
    path.moveTo(0, 16);
    path.quadraticBezierTo(size.width / 2, 0, size.width, 16);
    Paint paint = Paint()
      ..color = const Color(0xFFD4A843).withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
