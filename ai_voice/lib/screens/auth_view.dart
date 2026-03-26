import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:ai_voice/main.dart';

class AuthView extends StatefulWidget {
  const AuthView({super.key});

  @override
  State<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends State<AuthView> {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _isAuthenticating = false;
  String _authMessage = "Tap to unlock system";
  String _authType = "";

  @override
  void initState() {
    super.initState();
    _detectBiometricType();
    _authenticate();
  }

  Future<void> _detectBiometricType() async {
    try {
      final bool canAuthenticateWithBiometrics = await _auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await _auth.isDeviceSupported();
      
      if (!canAuthenticate) {
        setState(() => _authType = "Security Code (PIN/Pattern)");
        return;
      }

      List<BiometricType> availableBiometrics = await _auth.getAvailableBiometrics();
      
      if (availableBiometrics.contains(BiometricType.face)) {
        setState(() => _authType = "Face Unlock / ID");
      } else if (availableBiometrics.contains(BiometricType.fingerprint)) {
        setState(() => _authType = "Fingerprint Scan");
      } else if (availableBiometrics.contains(BiometricType.iris)) {
        setState(() => _authType = "Iris Scan");
      } else if (availableBiometrics.contains(BiometricType.strong) || availableBiometrics.contains(BiometricType.weak)) {
        setState(() => _authType = "Biometric Lock");
      } else {
        setState(() => _authType = "System Lock (PIN / Pattern)");
      }
    } catch (e) {
      setState(() => _authType = "System Lock");
    }
  }

  Future<void> _authenticate() async {
    bool authenticated = false;
    try {
      setState(() {
        _isAuthenticating = true;
        _authMessage = "Verifying Identity...";
      });

      authenticated = await _auth.authenticate(
        localizedReason: 'Please authenticate to access AI Core',
        options: const AuthenticationOptions(
          useErrorDialogs: true,
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (e) {
      setState(() {
        _authMessage = "Authentication Error";
      });
    }

    if (mounted) {
      setState(() {
        _isAuthenticating = false;
        if (authenticated) {
          _authMessage = "Access Granted";
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (context) => const PremiumDashboard()),
            );
          });
        } else {
          _authMessage = "Access Denied. Try Again.";
        }
      });
    }
  }

  IconData _getAuthIcon() {
    if (_authType.contains("Face")) return Icons.face_unlock_rounded;
    if (_authType.contains("Fingerprint")) return Icons.fingerprint;
    return Icons.security_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
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
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4A843).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _isAuthenticating 
                            ? const Color(0xFFD4A843).withValues(alpha: 0.3) 
                            : Colors.transparent,
                        blurRadius: 40,
                        spreadRadius: 10,
                      )
                    ],
                    border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.3)),
                  ),
                  child: Icon(_getAuthIcon(), size: 80, color: const Color(0xFFB8860B)),
                ),
                const SizedBox(height: 16),
                const Text("VoxShield AI Security", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                const SizedBox(height: 8),
                Text(_authMessage, style: const TextStyle(color: Color(0xFF888888), fontSize: 16)),
                if (_authType.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text("Using: $_authType", style: const TextStyle(color: Color(0xFFB8860B), fontSize: 13, fontWeight: FontWeight.w500)),
                ],
                const SizedBox(height: 60),
                GestureDetector(
                  onTap: _isAuthenticating ? null : _authenticate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFD4A843), Color(0xFFB8860B)]),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(color: const Color(0xFFD4A843).withValues(alpha: 0.3), blurRadius: 15, offset: const Offset(0, 5))
                      ],
                    ),
                    child: _isAuthenticating
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text("Unlock Now", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
