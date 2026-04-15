import 'package:flutter/material.dart';
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
import 'services/background_service.dart';

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

/// Overlay display modes
enum OverlayMode { compact, expanded, callerIdBadge }

class CallOverlayWidget extends StatefulWidget {
  const CallOverlayWidget({super.key});

  @override
  State<CallOverlayWidget> createState() => _CallOverlayWidgetState();
}

class _CallOverlayWidgetState extends State<CallOverlayWidget>
    with SingleTickerProviderStateMixin {
  // ── Constants ──
  static const double _bubbleSize = 72;
  static const int _bubbleSizeInt = 130;

  // ── State ──
  OverlayMode _mode = OverlayMode.compact;
  double riskScore = 0.0;
  double emaRisk = 0.0;
  String callerNumber = 'Detecting...';
  bool isRealAnalysis = false;
  bool isRecording = false;
  bool voiceSwitched = false;
  bool identityMatch = false;
  int voiceSwitchCount = 0;
  String pitchAnalysis = 'Normal';
  String frequencyVariance = 'Stable';
  bool _isBlocked = false;

  // ── Animation ──
  late AnimationController _pulseController;
  StreamSubscription? _overlaySub;

  // ── Caller-ID auto-dismiss ──
  Timer? _callerIdTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onDataReceived);
  }

  void _onDataReceived(dynamic data) {
    if (data == null || data is! Map) return;

    // ── CallService sent a "close" signal → self-close ──
    if (data['type'] == 'close') {
      FlutterOverlayWindow.closeOverlay();
      return;
    }

    if (!mounted) return;

    final wasBlocked = _isBlocked;

    setState(() {
      riskScore = (data['risk'] as num?)?.toDouble() ?? 0.0;
      emaRisk = (data['emaRisk'] as num?)?.toDouble() ?? riskScore;
      callerNumber = data['number'] ?? 'Unknown';
      isRealAnalysis = data['isReal'] ?? false;
      isRecording = data['isRecording'] ?? false;
      voiceSwitched = data['voiceSwitched'] ?? false;
      identityMatch = data['identityMatch'] ?? false;
      voiceSwitchCount = data['voiceSwitchCount'] ?? 0;
      pitchAnalysis = data['pitchAnalysis'] ?? 'Stable';
      frequencyVariance = data['frequencyVariance'] ?? 'Normal';
      _isBlocked = data['type'] == 'blocked';
    });

    // ── Switch to Caller-ID badge for blocked numbers ──
    if (_isBlocked && !wasBlocked && _mode == OverlayMode.compact) {
      _showCallerIdBadge();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _overlaySub?.cancel();
    _callerIdTimer?.cancel();
    super.dispose();
  }

  // ──────────────────────────────────────────────
  // Mode transitions — use EXPLICIT pixel positioning (MIUI/POCO fix)
  // ──────────────────────────────────────────────

  Future<void> _expandOverlay() async {
    final physicalSize = PlatformDispatcher.instance.displays.first.size;
    final pixelRatio =
        PlatformDispatcher.instance.displays.first.devicePixelRatio;
    final screen = physicalSize / pixelRatio;

    final int panelW = (screen.width * 0.88).clamp(300, 360).toInt();
    final int panelH = (screen.height * 0.60).clamp(380, 480).toInt();

    // 1. Resize overlay window to panel dimensions
    await FlutterOverlayWindow.resizeOverlay(panelW, panelH, false);
    await Future.delayed(const Duration(milliseconds: 80));

    // 2. Move to exact center of screen
    final double cx = (screen.width - panelW) / 2;
    final double cy = (screen.height - panelH) / 2;
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(cx, cy));

    if (mounted) setState(() => _mode = OverlayMode.expanded);
  }

  Future<void> _collapseOverlay() async {
    final physicalSize = PlatformDispatcher.instance.displays.first.size;
    final pixelRatio =
        PlatformDispatcher.instance.displays.first.devicePixelRatio;
    final screen = physicalSize / pixelRatio;

    // 1. Resize back to bubble
    await FlutterOverlayWindow.resizeOverlay(
      _bubbleSizeInt,
      _bubbleSizeInt,
      true,
    );
    await Future.delayed(const Duration(milliseconds: 80));

    // 2. Move to right edge, vertically centered
    final double rx = screen.width - _bubbleSizeInt - 12;
    final double ry = screen.height * 0.4;
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(rx, ry));

    if (mounted) setState(() => _mode = OverlayMode.compact);
  }

  Future<void> _showCallerIdBadge() async {
    final physicalSize = PlatformDispatcher.instance.displays.first.size;
    final pixelRatio =
        PlatformDispatcher.instance.displays.first.devicePixelRatio;
    final screen = physicalSize / pixelRatio;

    await FlutterOverlayWindow.resizeOverlay(320, 100, false);
    await Future.delayed(const Duration(milliseconds: 80));

    // Center horizontally, near top
    final double cx = (screen.width - 320) / 2;
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(cx, 60));

    if (mounted) setState(() => _mode = OverlayMode.callerIdBadge);

    _callerIdTimer?.cancel();
    _callerIdTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) _collapseOverlay();
    });
  }

  Future<void> _sendOverlayAction(String action) async {
    await FlutterOverlayWindow.shareData({'action': action});
  }

  // ──────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool isDanger = emaRisk > 0.6 || voiceSwitched || identityMatch;
    final Color themeColor = isDanger
        ? const Color(0xFFE74C3C)
        : const Color(0xFFD4A843);

    return Material(
      color: Colors.transparent,
      child: switch (_mode) {
        OverlayMode.compact => _buildCompactBubble(themeColor, isDanger),
        OverlayMode.expanded => _buildExpandedPanel(themeColor, isDanger),
        OverlayMode.callerIdBadge => _buildCallerIdBadge(themeColor),
      },
    );
  }

  // ──────────────────────────────────────────────
  // 1. COMPACT BUBBLE (72 px draggable circle)
  // ──────────────────────────────────────────────

  Widget _buildCompactBubble(Color themeColor, bool isDanger) {
    return Center(
      child: SizedBox(
        width: _bubbleSize,
        height: _bubbleSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _expandOverlay();
          },
          child: ScaleTransition(
            scale: Tween<double>(begin: 1.0, end: 1.08).animate(
              CurvedAnimation(
                parent: _pulseController,
                curve: Curves.easeInOut,
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [themeColor, themeColor.withValues(alpha: 0.75)],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.9),
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: themeColor.withValues(alpha: 0.45),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    offset: const Offset(0, 4),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      identityMatch
                          ? Icons.person_off_rounded
                          : (isDanger
                                ? Icons.security_rounded
                                : Icons.shield_rounded),
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      identityMatch ? 'MATCH' : '${(emaRisk * 100).toInt()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // 2. EXPANDED PANEL — fills the overlay window (already positioned at center)
  // ──────────────────────────────────────────────

  Widget _buildExpandedPanel(Color themeColor, bool isDanger) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: themeColor.withValues(alpha: 0.25),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: themeColor.withValues(alpha: 0.18),
            blurRadius: 30,
            spreadRadius: 4,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // ── HEADER ──
          _buildHeader(themeColor, isDanger),

          // ── BODY ──
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Column(
                children: [
                  Text(
                    callerNumber,
                    style: const TextStyle(
                      color: Color(0xFF1A1A1A),
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (identityMatch) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.5),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.gavel_rounded,
                            color: Colors.white,
                            size: 14,
                          ),
                          SizedBox(width: 6),
                          Text(
                            "KNOWN SCAMMER",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    identityMatch
                        ? "FINGERPRINT DATABASE MATCH"
                        : (isRealAnalysis
                              ? "REAL-TIME ENGINE LIVE"
                              : "PREDICTIVE SCANNING"),
                    style: TextStyle(
                      color: identityMatch
                          ? Colors.redAccent
                          : (isRealAnalysis
                                ? const Color(0xFF2ECC71)
                                : const Color(0xFF999999)),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Risk gauges
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _gauge("SEGMENT", (riskScore * 100).toInt(), themeColor),
                      _gauge(
                        "EMA AVG",
                        (emaRisk * 100).toInt(),
                        themeColor,
                        isLarge: true,
                      ),
                      _gauge("ACCURACY", 98, const Color(0xFFD4A843)),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Detail rows
                  _detailRow(
                    Icons.record_voice_over_rounded,
                    "Voice Switches",
                    "$voiceSwitchCount Detected",
                    highlight: voiceSwitched,
                  ),
                  _detailRow(
                    Icons.waves_rounded,
                    "Pitch Stability",
                    pitchAnalysis,
                  ),
                  _detailRow(
                    Icons.graphic_eq_rounded,
                    "Freq Variance",
                    frequencyVariance,
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),

          // ── FOOTER ACTIONS ──
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F6F0),
              border: Border(
                top: BorderSide(color: themeColor.withValues(alpha: 0.12)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _actionBtn(
                    onTap: () => _sendOverlayAction('toggle_record'),
                    icon: isRecording
                        ? Icons.stop_circle
                        : Icons.fiber_manual_record,
                    label: isRecording ? "STOP" : "RECORD",
                    color: isRecording ? Colors.red : const Color(0xFFD4A843),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _actionBtn(
                    onTap: () => _sendOverlayAction('report_scam'),
                    icon: Icons.gavel_rounded,
                    label: "REPORT",
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(Color themeColor, bool isDanger) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [themeColor.withValues(alpha: 0.14), const Color(0xFFF8F6F2)],
        ),
      ),
      child: Row(
        children: [
          Icon(
            isDanger ? Icons.warning_rounded : Icons.shield_sharp,
            color: themeColor,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isDanger ? "THREAT DETECTED" : "VOXSHIELD SECURE",
              style: TextStyle(
                color: themeColor,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
          // ── Collapse button (shield icon) ──
          GestureDetector(
            onTap: _collapseOverlay,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: themeColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.close_fullscreen_rounded,
                color: themeColor,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  // 3. CALLER-ID BADGE (Truecaller-style banner for blocked numbers)
  // ──────────────────────────────────────────────

  Widget _buildCallerIdBadge(Color themeColor) {
    return GestureDetector(
      onTap: _collapseOverlay,
      child: Container(
        width: 310,
        height: 90,
        margin: const EdgeInsets.only(top: 40),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.red.withValues(alpha: 0.6),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.red.withValues(alpha: 0.25),
              blurRadius: 20,
              spreadRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            // Left icon
            Container(
              width: 60,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                ),
              ),
              child: Center(
                child: Icon(
                  identityMatch
                      ? Icons.person_off_rounded
                      : Icons.block_rounded,
                  color: Colors.red,
                  size: 28,
                ),
              ),
            ),
            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "⚠️ BLOCKED SCAMMER",
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      callerNumber,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Risk: ${(emaRisk * 100).toInt()}% • Tap to dismiss",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Shared UI Components
  // ──────────────────────────────────────────────

  Widget _gauge(String label, int value, Color color, {bool isLarge = false}) {
    final size = isLarge ? 76.0 : 56.0;
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: value / 100,
                strokeWidth: isLarge ? 5 : 3,
                backgroundColor: color.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            Text(
              "$value%",
              style: TextStyle(
                color: const Color(0xFF1A1A1A),
                fontSize: isLarge ? 17 : 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF999999),
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _detailRow(
    IconData icon,
    String label,
    String value, {
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: highlight
                  ? Colors.red.withValues(alpha: 0.1)
                  : const Color(0xFFF5EFE4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: highlight ? Colors.red : const Color(0xFF8A8A8A),
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(color: Color(0xFF4A4A4A), fontSize: 13),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.red : const Color(0xFF1A1A1A),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn({
    required VoidCallback onTap,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 17),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Background Service for persistent call listening
  await initializeBackgroundService();

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
            builder: (_) => widget.nextRequireAuth
                ? const AuthView()
                : const PremiumDashboard(),
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
                        color: const Color(
                          0xFFD4A843,
                        ).withValues(alpha: 0.8 * value),
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
                        valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFFD4A843).withValues(alpha: value),
                        ),
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

class PremiumDashboardState extends State<PremiumDashboard>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _holdController;
  late AnimationController _navAnimationController;
  late Animation<double> _navSlideAnimation;

  bool _isNavRevealed = false;
  int _currentNavIndex = 0;

  // Profile & Services
  final DatabaseService _db = DatabaseService();
  final CallService _callService = CallService();
  UserProfile _profile = UserProfile(
    name: 'Admin User',
    email: 'admin@intercept.ai',
  );

  // Key for refreshing history
  final GlobalKey<HistoryViewState> _historyKey = GlobalKey<HistoryViewState>();

  // Permissions
  bool _permissionsRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _holdController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _holdController.addListener(() {
      setState(() {});
      if (_holdController.value == 1.0 && !_isNavRevealed) {
        _triggerNavReveal();
      }
    });

    _navAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _navSlideAnimation = Tween<double>(begin: 300, end: 0).animate(
      CurvedAnimation(
        parent: _navAnimationController,
        curve: Curves.easeOutExpo,
      ),
    );

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
      debugPrint(
        '[Dashboard] App Resumed: Restarting call guard safety check...',
      );
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
                  child: AnimatedPadding(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    padding: EdgeInsets.only(bottom: _isNavRevealed ? 96 : 134),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: _buildCurrentView(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // BOTTOM NAV
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  AnimatedOpacity(
                    opacity: _isNavRevealed ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: _isNavRevealed,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildTooltipPopover(),
                          _buildShieldButton(),
                        ],
                      ),
                    ),
                  ),
                  if (_isNavRevealed) _buildCurvedNav(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentView() {
    switch (_currentNavIndex) {
      case 0:
        return ScannerView(key: const ValueKey('scanner_tab'));
      case 1:
        return HistoryView(key: _historyKey);
      case 2:
        return const AnalyticsView(key: ValueKey('analytics_tab'));
      case 3:
        return ProfileView(
          key: const ValueKey('profile_tab'),
          onProfileUpdated: updateProfile,
        );
      default:
        return ScannerView(key: const ValueKey('scanner_tab_default'));
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
            child: const Icon(
              Icons.graphic_eq_rounded,
              color: Color(0xFFB8860B),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileAvatar() {
    final imagePath = _profile.imagePath;
    if (imagePath != null &&
        imagePath.isNotEmpty &&
        File(imagePath).existsSync()) {
      return Container(
        width: 36,
        height: 36,
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
        onTapUp: (_) {
          if (_holdController.value < 1.0) _holdController.reverse();
        },
        onTapCancel: () {
          if (_holdController.value < 1.0) _holdController.reverse();
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(
                      0xFFD4A843,
                    ).withValues(alpha: 0.3 + (progress * 0.5)),
                    blurRadius: 30,
                    spreadRadius: 8,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 90,
              height: 90,
              child: CircularProgressIndicator(
                value: progress > 0 ? progress : null,
                strokeWidth: 3,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFFB8860B),
                ),
                backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.2),
              ),
            ),
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFFD4A843), Color(0xFFB8860B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.7),
                  width: 1.5,
                ),
              ),
              child: const Icon(
                Icons.shield_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- TOOLTIP POPOVER ----
  Widget _buildTooltipPopover() {
    const goldColor = Color(0xFFD4A843);
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Triangle tail
        Positioned(
          bottom: -4,
          child: Transform.rotate(
            angle: 3.14159 / 4,
            child: Container(width: 12, height: 12, color: goldColor),
          ),
        ),
        // Message box
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: goldColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Text(
            "Press to Hold",
            style: TextStyle(
              color: Color(0xFF1A1A1A),
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
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
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFD4A843).withValues(alpha: 0.1),
                        blurRadius: 20,
                        offset: const Offset(0, -5),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.only(
                    top: 12,
                    bottom: bottomPadding > 0 ? bottomPadding : 8,
                  ),
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
      },
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
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? 14 : 10,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withValues(alpha: 0.12)
              : Colors.transparent,
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
      permissions: [
        Permission.phone,
      ], // Implicitly includes READ_CALL_LOG on modern Android builds
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
      description:
          "Simply allow access to background and incoming notifications.",
      permissions: [Permission.notification, Permission.systemAlertWindow],
    ),
    _PermissionItem(
      icon: Icons.battery_charging_full_rounded,
      title: "Background Engine",
      description:
          "Allow app to run in the background (Ignore Battery Optimization) so the Guardian never sleeps.",
      permissions: [Permission.ignoreBatteryOptimizations],
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
    Map<Permission, PermissionStatus> statuses = await item.permissions
        .request();

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
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _permissions.length,
                (i) => Container(
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
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Icon Background transition
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: isGranted
                    ? const Color(0xFFD4A843)
                    : const Color(0xFFF9F9F9),
                shape: BoxShape.circle,
                boxShadow: isGranted
                    ? [
                        BoxShadow(
                          color: const Color(0xFFD4A843).withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ]
                    : [],
              ),
              child: Icon(
                isGranted ? Icons.check_circle_outline_rounded : item.icon,
                color: isGranted ? Colors.white : const Color(0xFFB8860B),
                size: 44,
              ),
            ),
            const SizedBox(height: 24),

            // Title
            Text(
              item.title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              item.description,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),

            // Allow button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _requestCurrent,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isGranted
                      ? const Color(0xFFB8860B)
                      : const Color(0xFF1A1A1A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  isGranted ? "Next Step" : "Grant Access",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Skip
            if (!isGranted)
              TextButton(
                onPressed: _skipCurrent,
                child: Text(
                  isLast ? "Done" : "Skip",
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                  ),
                ),
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
