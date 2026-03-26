import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Threat Registry Service for VoxShield AI.
/// Tracks reported scam/deepfake phone numbers and provides
/// real-time threat warnings when known scam numbers call.
class ThreatRegistryService {
  static final ThreatRegistryService _instance = ThreatRegistryService._internal();
  factory ThreatRegistryService() => _instance;
  ThreatRegistryService._internal();

  /// Hash phone number for privacy-preserving storage
  String _hashPhone(String phoneNumber) {
    final normalized = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    final bytes = utf8.encode('voxshield_threat_v1:$normalized');
    return sha256.convert(bytes).toString();
  }

  /// Report a phone number as a threat
  Future<void> reportThreat({
    required Database db,
    required String phoneNumber,
    required double riskScore,
    required String threatType, // 'deepfake', 'scam', 'impersonation', 'voice_clone'
    String? notes,
  }) async {
    final phoneHash = _hashPhone(phoneNumber);
    final timestamp = DateTime.now().toIso8601String();

    // Check if already in registry
    final existing = await db.query(
      'threat_registry',
      where: 'phone_hash = ?',
      whereArgs: [phoneHash],
    );

    if (existing.isNotEmpty) {
      // Update existing record
      final currentCount = existing.first['report_count'] as int;
      final currentAvgRisk = existing.first['avg_risk_score'] as double;
      final newAvgRisk = ((currentAvgRisk * currentCount) + riskScore) / (currentCount + 1);

      await db.update(
        'threat_registry',
        {
          'report_count': currentCount + 1,
          'avg_risk_score': newAvgRisk,
          'last_reported': timestamp,
          'threat_level': _calculateThreatLevel(currentCount + 1, newAvgRisk),
          'threat_type': threatType,
        },
        where: 'phone_hash = ?',
        whereArgs: [phoneHash],
      );
      debugPrint('[ThreatRegistry] Updated threat: $phoneHash (reports: ${currentCount + 1})');
    } else {
      // New entry
      await db.insert('threat_registry', {
        'phone_hash': phoneHash,
        'phone_display': _maskPhoneNumber(phoneNumber),
        'report_count': 1,
        'avg_risk_score': riskScore,
        'first_reported': timestamp,
        'last_reported': timestamp,
        'threat_level': _calculateThreatLevel(1, riskScore),
        'threat_type': threatType,
        'is_blocked': 0,
        'notes': notes,
      });
      debugPrint('[ThreatRegistry] New threat registered: $phoneHash');
    }
  }

  /// Check if a phone number is in the threat registry
  Future<Map<String, dynamic>?> checkThreat(Database db, String phoneNumber) async {
    final phoneHash = _hashPhone(phoneNumber);
    final results = await db.query(
      'threat_registry',
      where: 'phone_hash = ?',
      whereArgs: [phoneHash],
    );

    if (results.isNotEmpty) {
      debugPrint('[ThreatRegistry] ⚠️ Known threat found: ${results.first['threat_level']}');
      return results.first;
    }
    return null;
  }

  /// Get all threats sorted by danger level
  Future<List<Map<String, dynamic>>> getAllThreats(Database db) async {
    return await db.query(
      'threat_registry',
      orderBy: 'report_count DESC, avg_risk_score DESC',
    );
  }

  /// Get threat statistics
  Future<Map<String, dynamic>> getStats(Database db) async {
    final total = (await db.rawQuery('SELECT COUNT(*) as c FROM threat_registry')).first['c'] as int;
    final blocked = (await db.rawQuery('SELECT COUNT(*) as c FROM threat_registry WHERE is_blocked = 1')).first['c'] as int;
    final critical = (await db.rawQuery("SELECT COUNT(*) as c FROM threat_registry WHERE threat_level = 'CRITICAL'")).first['c'] as int;
    final high = (await db.rawQuery("SELECT COUNT(*) as c FROM threat_registry WHERE threat_level = 'HIGH'")).first['c'] as int;

    return {
      'total_threats': total,
      'blocked': blocked,
      'critical': critical,
      'high': high,
    };
  }

  /// Block/Unblock a threat
  Future<void> toggleBlock(Database db, String phoneHash, bool block) async {
    await db.update(
      'threat_registry',
      {'is_blocked': block ? 1 : 0},
      where: 'phone_hash = ?',
      whereArgs: [phoneHash],
    );
  }

  /// Remove a threat from registry
  Future<void> removeThreat(Database db, String phoneHash) async {
    await db.delete('threat_registry', where: 'phone_hash = ?', whereArgs: [phoneHash]);
  }

  /// Calculate threat level based on report count and risk score
  String _calculateThreatLevel(int reportCount, double avgRisk) {
    if (reportCount >= 5 || avgRisk >= 0.9) return 'CRITICAL';
    if (reportCount >= 3 || avgRisk >= 0.7) return 'HIGH';
    if (reportCount >= 2 || avgRisk >= 0.5) return 'MEDIUM';
    return 'LOW';
  }

  /// Mask phone number for display (privacy)
  String _maskPhoneNumber(String phone) {
    if (phone.length <= 4) return phone;
    final visible = phone.substring(phone.length - 4);
    return '****$visible';
  }
}
