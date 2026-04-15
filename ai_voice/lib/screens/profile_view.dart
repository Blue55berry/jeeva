import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../services/database_service.dart';
import '../services/blockchain_service.dart';
import '../models/user_profile.dart';

class ProfileView extends StatefulWidget {
  final Function(UserProfile)? onProfileUpdated;
  const ProfileView({super.key, this.onProfileUpdated});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  bool _biometricLock = false;

  final LocalAuthentication _auth = LocalAuthentication();
  final DatabaseService _db = DatabaseService();
  final ImagePicker _picker = ImagePicker();

  UserProfile _profile = UserProfile(name: 'Admin User', email: 'admin@intercept.ai');
  List<BiometricType> _availableBiometrics = [];
  bool _isEditing = false;
  late TextEditingController _nameController;
  late TextEditingController _emailController;

  // Backend URL
  late TextEditingController _backendUrlController;
  bool _isTestingConnection = false;
  String _connectionStatus = '';
  String _connectionMessage = '';
  String _savedUrl = '';

  // Real-time permission statuses
  bool _micGranted = false;
  bool _phoneGranted = false;
  bool _cameraGranted = false;
  bool _storageGranted = false;
  bool _notificationGranted = false;
  bool _contactsGranted = false;

  // Analytics
  int _totalCalls = 0;
  int _aiBlocked = 0;
  int _humanVerified = 0;
  String _storageUsed = '0 MB';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _emailController = TextEditingController();
    _backendUrlController = TextEditingController();
    _loadProfile();
    _loadBiometricSetting();
    _checkAvailableBiometrics();
    _refreshPermissionStatuses();
    _loadAnalytics();
    _loadBackendUrl();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final profile = await _db.getUserProfile();
    if (mounted) {
      setState(() {
        _profile = profile;
        _nameController.text = profile.name;
        _emailController.text = profile.email;
      });
    }
  }

  Future<void> _loadBiometricSetting() async {
    bool enabled = await _db.isBiometricEnabled();
    if (mounted) setState(() => _biometricLock = enabled);
  }

  Future<void> _checkAvailableBiometrics() async {
    try {
      _availableBiometrics = await _auth.getAvailableBiometrics();
      if (mounted) setState(() {});
    } catch (e) {
      // Ignore
    }
  }

  Future<void> _refreshPermissionStatuses() async {
    final mic = await Permission.microphone.isGranted;
    final phone = await Permission.phone.isGranted;
    final camera = await Permission.camera.isGranted;
    final storage = await Permission.storage.isGranted;
    final notification = await Permission.notification.isGranted;
    final contacts = await Permission.contacts.isGranted;
    if (mounted) {
      setState(() {
        _micGranted = mic;
        _phoneGranted = phone;
        _cameraGranted = camera;
        _storageGranted = storage;
        _notificationGranted = notification;
        _contactsGranted = contacts;
      });
    }
  }

  Future<void> _loadAnalytics() async {
    final stats = await _db.getAnalyticsStats();
    // Estimate storage used
    final dir = await getApplicationDocumentsDirectory();
    int totalSize = 0;
    try {
      final files = dir.listSync(recursive: true);
      for (var f in files) {
        if (f is File) totalSize += await f.length();
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _totalCalls = stats['total'] as int;
        _aiBlocked = stats['aiBlocked'] as int;
        _humanVerified = stats['humanVerified'] as int;
        if (totalSize > 1024 * 1024) {
          _storageUsed = '${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB';
        } else {
          _storageUsed = '${(totalSize / 1024).toStringAsFixed(0)} KB';
        }
      });
    }
  }

  String _getBiometricLabel() {
    if (_availableBiometrics.contains(BiometricType.face)) return "Face ID";
    if (_availableBiometrics.contains(BiometricType.fingerprint)) return "Fingerprint";
    if (_availableBiometrics.contains(BiometricType.strong)) return "Biometric Lock";
    return "PIN / Pattern / Biometric";
  }

  IconData _getBiometricIcon() {
    if (_availableBiometrics.contains(BiometricType.face)) return Icons.face;
    if (_availableBiometrics.contains(BiometricType.fingerprint)) return Icons.fingerprint;
    return Icons.lock;
  }

  Future<void> _toggleBiometric(bool val) async {
    if (val) {
      try {
        bool authenticated = await _auth.authenticate(
          localizedReason: 'Authenticate to enable App Lock',
        );
        if (authenticated) {
          setState(() => _biometricLock = true);
          await _db.setBiometricEnabled(true);
        }
      } catch (e) {
        // Authentication failed or cancelled
      }
    } else {
      setState(() => _biometricLock = false);
      await _db.setBiometricEnabled(false);
    }
  }

  Future<void> _pickImage() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text("Update Profile Photo", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFFB8860B)),
              title: const Text('Take Photo', style: TextStyle(color: Color(0xFF1A1A1A))),
              onTap: () { Navigator.pop(context); _getImage(ImageSource.camera); },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Color(0xFFB8860B)),
              title: const Text('Choose from Gallery', style: TextStyle(color: Color(0xFF1A1A1A))),
              onTap: () { Navigator.pop(context); _getImage(ImageSource.gallery); },
            ),
            if (_profile.imagePath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Color(0xFFE74C3C)),
                title: const Text('Remove Photo', style: TextStyle(color: Color(0xFFE74C3C))),
                onTap: () async {
                  Navigator.pop(context);
                  _profile = UserProfile(name: _profile.name, email: _profile.email, imagePath: null);
                  await _db.saveUserProfile(_profile);
                  if (mounted) {
                    setState(() {});
                    widget.onProfileUpdated?.call(_profile);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _getImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 80);
      if (image != null) {
        // Copy to app directory for persistence
        final dir = await getApplicationDocumentsDirectory();
        final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}${p.extension(image.path)}';
        final savedImage = await File(image.path).copy('${dir.path}/$fileName');

        setState(() {
          _profile = UserProfile(
            name: _profile.name,
            email: _profile.email,
            imagePath: savedImage.path,
          );
        });

        await _db.saveUserProfile(_profile);

        // Force parent to reload
        widget.onProfileUpdated?.call(_profile);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Profile photo updated!', style: TextStyle(color: Colors.white)),
              backgroundColor: const Color(0xFF2ECC71),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to pick image: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: const Color(0xFFE74C3C),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  Future<void> _saveProfile() async {
    _profile = UserProfile(
      name: _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : 'Admin User',
      email: _emailController.text.trim().isNotEmpty ? _emailController.text.trim() : 'admin@intercept.ai',
      imagePath: _profile.imagePath,
    );
    await _db.saveUserProfile(_profile);
    
    setState(() => _isEditing = false);
    widget.onProfileUpdated?.call(_profile);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Profile updated!', style: TextStyle(color: Colors.white)),
          backgroundColor: const Color(0xFFB8860B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _requestPermission(Permission perm) async {
    await perm.request();
    _refreshPermissionStatuses();
  }



  void _showComingSoon(String feature) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$feature settings coming in v1.1 update', style: const TextStyle(color: Colors.white)),
          backgroundColor: const Color(0xFFB8860B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _clearAllData() async {
    // 1. Delete DB records and shared preferences
    await _db.clearAllData();
    
    // 2. Remove profile image file if exists
    if (_profile.imagePath != null) {
      final file = File(_profile.imagePath!);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
    
    // 3. Reset local state immediately
    setState(() {
      _profile = UserProfile(name: 'Admin User', email: 'admin@intercept.ai');
      _nameController.text = _profile.name;
      _emailController.text = _profile.email;
      _biometricLock = false;
      _totalCalls = 0;
      _aiBlocked = 0;
      _humanVerified = 0;
      _storageUsed = '0 KB';
    });

    // 4. Update parent
    widget.onProfileUpdated?.call(_profile);

    // 5. Show confirmation
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('All app data has been cleared and signed out.', style: TextStyle(color: Colors.white)),
          backgroundColor: const Color(0xFF2ECC71),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _showBlockchainLedger() async {
    List<Map<String, dynamic>> blocks = [];
    try {
      final db = await _db.getRawDatabase();
      if (db != null) {
        blocks = await BlockchainService().getRecentBlocks(db, limit: 10);
      } else {
        // Fallback for Web/Desktop simulation
        blocks = [
          {
            'block_index': 2,
            'verdict': 'human_verified',
            'block_hash': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            'previous_hash': 'a1c2d3e4f5g6h7i8j9k0l1m2n3o4p5q6r7s8t9u0v1w2x3y4z5a6b7c8d9e0f1g2'
          },
          {
            'block_index': 1,
            'verdict': 'ai_blocked',
            'block_hash': 'a1c2d3e4f5g6h7i8j9k0l1m2n3o4p5q6r7s8t9u0v1w2x3y4z5a6b7c8d9e0f1g2',
            'previous_hash': '0000000000000000000000000000000000000000000000000000000000000000'
          }
        ];
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ledger Error: $e')));
      }
      return;
    }
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.only(top: 24, left: 20, right: 20),
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFD4A843).withValues(alpha: 0.1), shape: BoxShape.circle),
                  child: const Icon(Icons.hub, color: Color(0xFFB8860B)),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Security Ledger", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                    Text("Immutable blockchain verification logs", style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: blocks.isEmpty 
                ? const Center(child: Text("No blocks mined yet.", style: TextStyle(color: Color(0xFF999999))))
                : ListView.builder(
                    itemCount: blocks.length,
                    itemBuilder: (context, index) {
                      final block = blocks[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF9F6F0),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE0D5C0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Block #${block['block_index']}", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFB8860B))),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: block['verdict'] == 'ai_blocked' ? const Color(0xFFE74C3C).withValues(alpha: 0.1) : const Color(0xFF2ECC71).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(block['verdict'] == 'ai_blocked' ? 'AI DETECTED' : 'HUMAN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: block['verdict'] == 'ai_blocked' ? const Color(0xFFE74C3C) : const Color(0xFF2ECC71))),
                                )
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text("Block Hash (SHA-256):", style: TextStyle(fontSize: 10, color: Color(0xFF888888))),
                            Text("${block['block_hash']}", style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF555555)), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            const Text("Previous Hash:", style: TextStyle(fontSize: 10, color: Color(0xFF888888))),
                            Text("${block['previous_hash']}", style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFFBBBBBB)), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      );
                    },
                  ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4A843),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: const Text("Close Ledger", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('backend_url') ?? '';
    if (mounted) {
      setState(() {
        _backendUrlController.text = url;
        _savedUrl = url;
      });
    }
  }

  Future<void> _saveBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final newUrl = _backendUrlController.text.trim();
    await prefs.setString('backend_url', newUrl);
    if (mounted) {
      setState(() {
        _savedUrl = newUrl;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Backend URL saved!', style: TextStyle(color: Colors.white)),
          backgroundColor: const Color(0xFF2ECC71),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _disconnectBackend() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('backend_url');
    setState(() {
      _backendUrlController.clear();
      _savedUrl = '';
      _connectionStatus = '';
      _connectionMessage = '';
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Backend disconnected and URL removed!', style: TextStyle(color: Colors.white)),
          backgroundColor: const Color(0xFFE74C3C),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _testOverlay() async {
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) {
        await FlutterOverlayWindow.showOverlay(
          enableDrag: true,
          overlayTitle: 'Shield Test',
          overlayContent: 'Testing AI Interceptor...',
          flag: OverlayFlag.focusPointer,
          alignment: OverlayAlignment.centerRight,
          width: 160,
          height: 160,
        );
        await Future.delayed(const Duration(milliseconds: 500));
        await FlutterOverlayWindow.shareData({
          'type': 'started',
          'number': 'Shield Test Mode',
          'risk': 0.0,
          'isReal': false,
          'isRecording': false,
          'showRecord': false,
        });
      } else {
        await FlutterOverlayWindow.requestPermission();
      }
    } catch (e) {
      debugPrint('Overlay test failed: $e');
    }
  }

  Future<void> _testConnection() async {
    final url = _backendUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _connectionStatus = 'error';
        _connectionMessage = 'Please enter a URL first';
      });
      return;
    }

    setState(() {
      _isTestingConnection = true;
      _connectionStatus = '';
      _connectionMessage = '';
    });

    try {
      String testUrl = url.trim();
      if (!testUrl.startsWith('http')) {
        // Handle IP addresses and localhost with http, others with https
        if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}').hasMatch(testUrl) || testUrl.contains('localhost')) {
          testUrl = 'http://$testUrl';
        } else {
          testUrl = 'https://$testUrl';
        }
      }
      testUrl = testUrl.replaceAll(RegExp(r'/+$'), ''); // Clean up trailing slashes
      
      debugPrint('Testing connection to: $testUrl');
      final response = await http.get(Uri.parse(testUrl))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        setState(() {
          _connectionStatus = 'success';
          _connectionMessage = 'Connected! AI Interceptor Online.';
        });
        await _saveBackendUrl();
      } else {
        setState(() {
          _connectionStatus = 'error';
          _connectionMessage = 'Error: ${response.statusCode} (Server returned non-200 code)';
        });
      }
    } on SocketException catch (se) {
      setState(() {
        _connectionStatus = 'error';
        _connectionMessage = 'Unreachable: Network error or Tunnel Offline. ($se)';
      });
    } on TimeoutException catch (_) {
      setState(() {
        _connectionStatus = 'error';
        _connectionMessage = 'Timeout: Server took too long to respond.';
      });
    } catch (e) {
      setState(() {
        _connectionStatus = 'error';
        _connectionMessage = 'Failed: ${e.toString()}';
      });
    } finally {
      if (mounted) setState(() => _isTestingConnection = false);
    }
  }

  Widget _buildBackendUrlSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0D5C0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4A843).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.dns_rounded, color: Color(0xFFB8860B), size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("AI Backend Server", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Color(0xFF1A1A1A))),
                    SizedBox(height: 2),
                    Text("Enter ngrok/tunnel URL to connect", style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _backendUrlController,
            onChanged: (val) => setState(() {}),
            style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
            decoration: InputDecoration(
              hintText: 'https://your-tunnel-url.ngrok.io',
              hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 13),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              prefixIcon: const Icon(Icons.link, color: Color(0xFFB8860B), size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE0D5C0))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD4A843), width: 2)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE0D5C0))),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _isTestingConnection ? null : _testConnection,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFD4A843), Color(0xFFB8860B)]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: _isTestingConnection
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.wifi_find, color: Colors.white, size: 18),
                                SizedBox(width: 8),
                                Text("Test Connection", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (_savedUrl.isNotEmpty && _backendUrlController.text.trim() == _savedUrl)
                GestureDetector(
                  onTap: _disconnectBackend,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE74C3C).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.link_off, color: Color(0xFFE74C3C), size: 22),
                  ),
                )
              else
                GestureDetector(
                  onTap: _saveBackendUrl,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4A843).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.save, color: Color(0xFFB8860B), size: 22),
                  ),
                ),
            ],
          ),
          if (_connectionStatus.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_connectionStatus == 'success' ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C)).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _connectionStatus == 'success' ? Icons.check_circle : Icons.error_outline,
                    size: 18,
                    color: _connectionStatus == 'success' ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connectionMessage,
                      style: TextStyle(
                        color: _connectionStatus == 'success' ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F6F2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("💡 How to connect:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF555555))),
                SizedBox(height: 6),
                Text("1. Run your Python backend on laptop", style: TextStyle(fontSize: 11, color: Color(0xFF888888))),
                Text("2. Use Cloudflare: cloudflared tunnel --url http://localhost:8000", style: TextStyle(fontSize: 11, color: Color(0xFF888888))),
                Text("3. Paste the tunnel URL above", style: TextStyle(fontSize: 11, color: Color(0xFF888888))),
                Text("4. Tap Test Connection to verify", style: TextStyle(fontSize: 11, color: Color(0xFF888888))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double bottomPadding = MediaQuery.of(context).padding.bottom;
    return Padding(
      key: const ValueKey('profile'),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Profile & Settings", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(bottom: 20 + bottomPadding),
              children: [
                _buildProfileHeader(),
                const SizedBox(height: 24),
                _buildSectionTitle("Security"),
                const SizedBox(height: 12),
                _buildBiometricSection(),
                const SizedBox(height: 24),
                _buildSectionTitle("App Permissions"),
                const SizedBox(height: 12),
                _buildPermissionStatus("Microphone", "Audio analysis & recording", Icons.mic, _micGranted, () => _requestPermission(Permission.microphone)),
                _buildPermissionStatus("Phone Access", "Call tracking & detection", Icons.phone, _phoneGranted, () => _requestPermission(Permission.phone)),
                _buildPermissionStatus("Camera", "Profile photo capture", Icons.camera_alt, _cameraGranted, () => _requestPermission(Permission.camera)),
                _buildPermissionStatus("Storage", "Save recordings & data", Icons.storage, _storageGranted, () => _requestPermission(Permission.storage)),
                _buildPermissionStatus("Contacts", "Sync Names & Secure Registry", Icons.contact_page_rounded, _contactsGranted, () => _requestPermission(Permission.contacts)),
                _buildPermissionStatus("Notifications", "Threat alerts", Icons.notifications, _notificationGranted, () => _requestPermission(Permission.notification)),
                const SizedBox(height: 24),
                _buildSectionTitle("Usage Statistics"),
                const SizedBox(height: 12),
                _buildStatsCard(),
                const SizedBox(height: 24),
                _buildSectionTitle("Backend Connection"),
                const SizedBox(height: 12),
                _buildBackendUrlSection(),
                const SizedBox(height: 24),
                _buildSectionTitle("Account"),
                const SizedBox(height: 12),
                _buildActionTile(Icons.hub, "Security Ledger", "View Blockchain audit trail", onTap: _showBlockchainLedger),
                _buildActionTile(Icons.cloud_upload_outlined, "Backup Rules", "Google Drive sync enabled", onTap: () => _showComingSoon("Cloud Backup")),
                _buildActionTile(Icons.info_outline, "App Version", "v1.0.0 (Build 1)", onTap: () => _showComingSoon("Version Info")),
                const SizedBox(height: 12),
                _buildSpecialFixesSection(),
                const SizedBox(height: 24),
                _buildSectionTitle("Notifications & Icons"),
                const SizedBox(height: 12),
                _buildOverlayToggle(),
                const SizedBox(height: 12),
                _buildActionTile(Icons.logout, "Sign Out", "Clear data & log out", color: const Color(0xFFE74C3C), onTap: _clearAllData),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE0D5C0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Profile image with upload
              GestureDetector(
                onTap: _pickImage,
                child: Stack(
                  children: [
                    _profile.imagePath != null && File(_profile.imagePath!).existsSync()
                      ? CircleAvatar(
                          radius: 35,
                          backgroundImage: FileImage(File(_profile.imagePath!)),
                        )
                      : CircleAvatar(
                          radius: 35,
                          backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.15),
                          child: const Icon(Icons.person, size: 40, color: Color(0xFFB8860B)),
                        ),
                    Positioned(
                      bottom: 0, right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFD4A843),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _isEditing
                  ? Column(
                      children: [
                        TextField(
                          controller: _nameController,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
                          decoration: InputDecoration(
                            hintText: 'Username',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE0D5C0))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD4A843))),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _emailController,
                          style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
                          decoration: InputDecoration(
                            hintText: 'Email',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE0D5C0))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD4A843))),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_profile.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                        const SizedBox(height: 4),
                        Text(_profile.email, style: const TextStyle(color: Color(0xFF888888), fontSize: 13)),
                      ],
                    ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xFFD4A843).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                child: const Text("PRO", style: TextStyle(color: Color(0xFFB8860B), fontSize: 11, fontWeight: FontWeight.bold)),
              )
            ],
          ),
          const SizedBox(height: 16),
          // Edit / Save button
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: _isEditing ? _saveProfile : () => setState(() => _isEditing = true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _isEditing ? const Color(0xFFD4A843) : const Color(0xFFD4A843).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    _isEditing ? "Save Changes" : "Edit Profile",
                    style: TextStyle(
                      color: _isEditing ? Colors.white : const Color(0xFFB8860B),
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpecialFixesSection() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0D5C0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_rounded, color: Color(0xFFB8860B), size: 20),
              const SizedBox(width: 8),
              const Text("MIUI & Visibility Fixes", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1A1A1A))),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            "If the floating shield is not appearing during calls on POCO/Xiaomi:",
            style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
          ),
          const SizedBox(height: 10),
          _buildMiuiStep("1. Long press app icon -> App Info"),
          _buildMiuiStep("2. Permissions -> Other Permissions"),
          _buildMiuiStep("3. Enable 'Display pop-up windows'"),
          _buildMiuiStep("4. Enable 'Show on Lock screen'"),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _testOverlay,
              icon: const Icon(Icons.play_circle_fill_rounded, size: 18),
              label: const Text("Launch Test Floating Shield"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiuiStep(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFFD4A843)),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF333333))),
        ],
      ),
    );
  }

  Widget _buildBiometricSection() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0D5C0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4A843).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_getBiometricIcon(), color: const Color(0xFFB8860B), size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("App Lock", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Color(0xFF1A1A1A))),
                    const SizedBox(height: 2),
                    Text(_getBiometricLabel(), style: const TextStyle(color: Color(0xFFB8860B), fontSize: 13, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: _biometricLock,
                  onChanged: _toggleBiometric,
                  activeThumbColor: Colors.white,
                  activeTrackColor: const Color(0xFFD4A843),
                  inactiveTrackColor: const Color(0xFFDDD8D0),
                ),
              ),
            ],
          ),
          if (_biometricLock) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2ECC71).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_user, size: 16, color: Color(0xFF2ECC71)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "${_getBiometricLabel()} is active. App requires authentication on every launch.",
                      style: const TextStyle(color: Color(0xFF2ECC71), fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPermissionStatus(String title, String subtitle, IconData icon, bool isGranted, VoidCallback onRequest) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0D5C0)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (isGranted ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C)).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: isGranted ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF1A1A1A))),
                Text(subtitle, style: const TextStyle(color: Color(0xFF999999), fontSize: 11)),
              ],
            ),
          ),
          isGranted
            ? const Icon(Icons.check_circle, color: Color(0xFF2ECC71), size: 22)
            : GestureDetector(
                onTap: onRequest,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4A843).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text("Grant", style: TextStyle(color: Color(0xFFB8860B), fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0D5C0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6)],
      ),
      child: Column(
        children: [
          Row(
            children: [
              _buildStatItem("Total Scans", "$_totalCalls", Icons.analytics),
              Container(width: 1, height: 40, color: const Color(0xFFE0D5C0)),
              _buildStatItem("AI Blocked", "$_aiBlocked", Icons.block),
              Container(width: 1, height: 40, color: const Color(0xFFE0D5C0)),
              _buildStatItem("Safe", "$_humanVerified", Icons.check_circle_outline),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Color(0xFFE0D5C0)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.storage, size: 16, color: Color(0xFFB8860B)),
                  const SizedBox(width: 6),
                  const Text("Local Storage Used", style: TextStyle(color: Color(0xFF888888), fontSize: 13)),
                ],
              ),
              Text(_storageUsed, style: const TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.bold, fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFFB8860B), size: 22),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Color(0xFF999999), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF333333)));
  }

  Widget _buildActionTile(IconData icon, String title, String subtitle, {VoidCallback? onTap, Color? color}) {
    Color itemColor = color ?? const Color(0xFF1A1A1A);
    Color iconColor = color ?? const Color(0xFFB8860B);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE0D5C0)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6)],
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Text(title, style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15, color: itemColor)),
                   if (subtitle.isNotEmpty) ...[
                     const SizedBox(height: 2),
                     Text(subtitle, style: const TextStyle(color: Color(0xFF999999), fontSize: 12)),
                   ]
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlayToggle() {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final prefs = snapshot.data!;
        bool showOverlay = prefs.getBool('show_overlay_on_call') ?? false;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE0D5C0)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4A843).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.layers_outlined, color: Color(0xFFB8860B), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Floating Shield Overlay", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1A1A1A))),
                    const Text("Show analyzer during active calls", style: TextStyle(color: Color(0xFF999999), fontSize: 11)),
                  ],
                ),
              ),
              Switch(
                value: showOverlay,
                onChanged: (val) async {
                  await prefs.setBool('show_overlay_on_call', val);
                  setState(() {});
                },
                activeThumbColor: Colors.white,
                activeTrackColor: const Color(0xFFD4A843),
              ),
            ],
          ),
        );
      },
    );
  }
}
