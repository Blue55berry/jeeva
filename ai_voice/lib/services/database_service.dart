import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/call_record.dart';
import '../models/user_profile.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;
  
  // Web Fallback Storage
  static final List<CallRecord> _webMockRecords = [];

  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Future<Database?> get database async {
    if (kIsWeb) return null;
    if (_database != null) return _database!;
    try {
      _database = await _initDB();
      return _database!;
    } catch (e) {
      debugPrint("DB Initialization failed: $e");
      return null;
    }
  }

  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'ai_voice.db');
    return await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await _createAllTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Add new tables for blockchain and threat registry
          await _createBlockchainTable(db);
          await _createThreatRegistryTable(db);
          // Add new column to call_records if not exists
          try {
            await db.execute('ALTER TABLE call_records ADD COLUMN block_hash TEXT');
          } catch (_) {
            // Column might already exist
          }
          try {
            await db.execute('ALTER TABLE call_records ADD COLUMN ai_model_used TEXT DEFAULT "simulated"');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE call_records ADD COLUMN is_real_analysis INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE call_records ADD COLUMN contactName TEXT');
          } catch (_) {}
        }
        if (oldVersion < 4) {
          try {
            await db.execute('ALTER TABLE call_records ADD COLUMN analysisSummary TEXT');
          } catch (_) {}
        }
      },
    );
  }

  Future<void> _createAllTables(Database db) async {
    await db.execute('''
      CREATE TABLE call_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        phoneNumber TEXT NOT NULL,
        callType TEXT NOT NULL,
        result TEXT NOT NULL,
        riskScore REAL NOT NULL,
        timestamp TEXT NOT NULL,
        recordingPath TEXT,
        duration INTEGER DEFAULT 0,
        block_hash TEXT,
        ai_model_used TEXT DEFAULT 'simulated',
        contactName TEXT,
        is_real_analysis INTEGER DEFAULT 0,
        analysisSummary TEXT
      )
    ''');
    await _createBlockchainTable(db);
    await _createThreatRegistryTable(db);
  }

  Future<void> _createBlockchainTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS blockchain_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        block_index INTEGER NOT NULL,
        block_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        phone_hash TEXT NOT NULL,
        risk_score REAL NOT NULL,
        verdict TEXT NOT NULL,
        model_version TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createThreatRegistryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS threat_registry (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        phone_hash TEXT NOT NULL UNIQUE,
        phone_display TEXT NOT NULL,
        report_count INTEGER DEFAULT 1,
        avg_risk_score REAL NOT NULL,
        first_reported TEXT NOT NULL,
        last_reported TEXT NOT NULL,
        threat_level TEXT DEFAULT 'LOW',
        threat_type TEXT DEFAULT 'unknown',
        is_blocked INTEGER DEFAULT 0,
        notes TEXT
      )
    ''');
  }

  // ---- CALL RECORDS ----

  Future<int> insertCallRecord(CallRecord record) async {
    if (kIsWeb) {
      _webMockRecords.insert(0, record);
      return 1;
    }
    final db = await database;
    if (db == null) {
      _webMockRecords.insert(0, record);
      return 1;
    }
    return await db.insert('call_records', record.toMap());
  }

  Future<List<CallRecord>> getCallRecords({int limit = 50}) async {
    if (kIsWeb) {
      if (_webMockRecords.isEmpty) {
        _webMockRecords.addAll([
          CallRecord(phoneNumber: "+1 415 555 0192", callType: 'incoming', result: 'ai_blocked', riskScore: 0.94, timestamp: DateTime.now().subtract(const Duration(hours: 2)).toIso8601String()),
          CallRecord(phoneNumber: "+91 98402 12345", callType: 'incoming', result: 'human_verified', riskScore: 0.04, timestamp: DateTime.now().subtract(const Duration(days: 1)).toIso8601String()),
        ]);
      }
      return _webMockRecords.take(limit).toList();
    }

    final db = await database;
    if (db == null) return _webMockRecords;

    final List<Map<String, dynamic>> maps = await db.query(
      'call_records',
      orderBy: 'id DESC',
      limit: limit,
    );
    return List.generate(maps.length, (i) => CallRecord.fromMap(maps[i]));
  }

  Future<int> deleteCallRecord(int id) async {
    if (kIsWeb) {
      _webMockRecords.removeWhere((r) => r.id == id);
      return 1;
    }
    final db = await database;
    if (db == null) return 0;
    return await db.delete('call_records', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateCallRecordContactName(int recordId, String name) async {
    final db = await database;
    if (db == null) return;
    await db.update(
      'call_records',
      {'contactName': name},
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  Future<void> updateCallRecordBlockHash(int recordId, String blockHash) async {
    final db = await database;
    if (db == null) return;
    await db.update(
      'call_records',
      {'block_hash': blockHash},
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  Future<Map<String, dynamic>> getAnalyticsStats() async {
    if (kIsWeb) {
      int total = _webMockRecords.length;
      int aiBlocked = _webMockRecords.where((r) => r.result == 'ai_blocked').length;
      int humanVerified = _webMockRecords.where((r) => r.result == 'human_verified').length;
      double realPercent = total > 0 ? humanVerified / total : 0.78;
      double riskPercent = total > 0 ? aiBlocked / total : 0.22;
      return {
        'total': total,
        'aiBlocked': aiBlocked,
        'humanVerified': humanVerified,
        'realPercent': realPercent,
        'riskPercent': riskPercent,
      };
    }

    final db = await database;
    if (db == null) {
      return { 'total': 0, 'aiBlocked': 0, 'humanVerified': 0, 'realPercent': 0.0, 'riskPercent': 0.0 };
    }
    final total = (await db.rawQuery('SELECT COUNT(*) as count FROM call_records')).first['count'] as int;
    final aiBlocked = (await db.rawQuery("SELECT COUNT(*) as count FROM call_records WHERE result = 'ai_blocked'")).first['count'] as int;
    final humanVerified = (await db.rawQuery("SELECT COUNT(*) as count FROM call_records WHERE result = 'human_verified'")).first['count'] as int;

    double realPercent = total > 0 ? humanVerified / total : 0.78;
    double riskPercent = total > 0 ? aiBlocked / total : 0.22;

    return {
      'total': total,
      'aiBlocked': aiBlocked,
      'humanVerified': humanVerified,
      'realPercent': realPercent,
      'riskPercent': riskPercent,
    };
  }

  /// Get the raw database instance for blockchain/threat services
  Future<Database?> getRawDatabase() async => await database;

  // ---- BLOCKCHAIN & SECURITY ----

  Future<Map<String, dynamic>?> checkNumberSecurity(String number) async {
    final db = await database;
    if (db == null) return null;
    
    // Normalize number
    String cleanNumber = number.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    
    final List<Map<String, dynamic>> results = await db.query(
      'threat_registry',
      where: 'phone_display LIKE ?',
      whereArgs: ['%$cleanNumber%'],
    );
    
    if (results.isNotEmpty) return results.first;
    return null;
  }

  Future<void> reportScam(String number, double risk, {String? evidencePath}) async {
    final db = await database;
    if (db == null) return;

    String cleanNumber = number.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    String timestamp = DateTime.now().toIso8601String();
    
    // 1. Update Threat Registry
    final List<Map<String, dynamic>> existing = await db.query(
      'threat_registry',
      where: 'phone_display LIKE ?',
      whereArgs: ['%$cleanNumber%'],
    );

    if (existing.isEmpty) {
      await db.insert('threat_registry', {
        'phone_hash': 'sha256_mock_${cleanNumber.hashCode}', 
        'phone_display': number,
        'report_count': 1,
        'avg_risk_score': risk,
        'first_reported': timestamp,
        'last_reported': timestamp,
        'threat_level': 'HIGH',
        'threat_type': 'scam',
        'is_blocked': 1,
      });
    } else {
      int count = (existing.first['report_count'] as int) + 1;
      await db.update('threat_registry', {
        'report_count': count,
        'last_reported': timestamp,
        'threat_level': count > 2 ? 'CRITICAL' : 'HIGH',
        'is_blocked': 1,
      }, where: 'id = ?', whereArgs: [existing.first['id']]);
    }

    // 2. Add to Blockchain Ledger (Conceptual)
    await db.insert('blockchain_ledger', {
      'block_index': 1000 + (DateTime.now().millisecondsSinceEpoch % 10000),
      'block_hash': '0000_block_hash_${DateTime.now().millisecond}',
      'previous_hash': 'prev_hash_999',
      'phone_hash': 'masked_${cleanNumber.substring(cleanNumber.length - 4)}',
      'risk_score': risk,
      'timestamp': timestamp
    });

    // 3. Upload to Cloud Blockchain Registry (with Audio Evidence)
    try {
      final prefs = await SharedPreferences.getInstance();
      String? backendUrl = prefs.getString('backend_url');
      if (backendUrl != null && backendUrl.isNotEmpty) {
        backendUrl = backendUrl.replaceAll(RegExp(r'/+$'), '');
        
        var request = http.MultipartRequest('POST', Uri.parse('$backendUrl/blockchain/report/'));
        request.headers['x-api-key'] = 'voxshield_live_secure_v1';
        
        request.fields['phone_hash'] = 'sha256_cloud_${cleanNumber.hashCode}';
        request.fields['phone_display'] = number;
        request.fields['verdict'] = risk > 0.6 ? 'ai_blocked' : 'suspicious';
        request.fields['threat_level'] = risk > 0.8 ? 'CRITICAL' : 'HIGH';
        request.fields['risk_score'] = risk.toString();
        
        if (evidencePath != null) {
          final file = await http.MultipartFile.fromPath('file', evidencePath);
          request.files.add(file);
        }
        
        final streamedResponse = await request.send().timeout(const Duration(seconds: 10));
        final response = await http.Response.fromStream(streamedResponse);
        
        if (response.statusCode == 200) {
          debugPrint('[DatabaseService] ✅ Scam & Audio Evidence synced to Cloud Dashboard');
        }
      }
    } catch (e) {
      debugPrint('[DatabaseService] ❌ Cloud Sync Failed: $e');
    }
  }

  // ---- USER PROFILE (SharedPreferences) ----

  Future<UserProfile> getUserProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return UserProfile(
      name: prefs.getString('profile_name') ?? 'Admin User',
      email: prefs.getString('profile_email') ?? 'admin@intercept.ai',
      imagePath: prefs.getString('profile_image'),
    );
  }

  Future<void> saveUserProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_name', profile.name);
    await prefs.setString('profile_email', profile.email);
    if (profile.imagePath != null) {
      await prefs.setString('profile_image', profile.imagePath!);
    }
  }

  Future<void> saveProfileImage(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_image', path);
  }

  // ---- BIOMETRIC SETTINGS ----

  Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('biometric_enabled') ?? false;
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', value);
  }

  // ---- CLEAR DATA ----

  Future<void> clearAllData() async {
    if (kIsWeb) {
      _webMockRecords.clear();
    } else {
      final db = await database;
      await db?.delete('call_records');
      await db?.delete('blockchain_ledger');
      await db?.delete('threat_registry');
    }
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
