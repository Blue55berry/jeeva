import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Local blockchain-like tamper-proof audit ledger for VoxShield AI.
/// Each call verification is hashed and chained to the previous record,
/// creating an immutable chain of evidence that cannot be altered.
class BlockchainService {
  static final BlockchainService _instance = BlockchainService._internal();
  factory BlockchainService() => _instance;
  BlockchainService._internal();

  /// Generate SHA-256 hash of call verification data
  String generateHash({
    required String phoneHash,
    required double riskScore,
    required String verdict,
    required String timestamp,
    required String previousHash,
    required String modelVersion,
  }) {
    final data = '$phoneHash|$riskScore|$verdict|$timestamp|$previousHash|$modelVersion';
    final bytes = utf8.encode(data);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  /// Hash a phone number for privacy-preserving storage
  String hashPhoneNumber(String phoneNumber) {
    // Normalize phone number (remove spaces, dashes, etc.)
    final normalized = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    final bytes = utf8.encode('voxshield_salt_v1:$normalized');
    return sha256.convert(bytes).toString();
  }

  /// Add a new block to the local ledger
  Future<Map<String, dynamic>> addBlock({
    required Database db,
    required String phoneNumber,
    required double riskScore,
    required String verdict,
    required String modelVersion,
  }) async {
    try {
      // Get the previous block's hash
      final previousBlocks = await db.query(
        'blockchain_ledger',
        orderBy: 'block_index DESC',
        limit: 1,
      );

      String previousHash = '0000000000000000000000000000000000000000000000000000000000000000'; // Genesis
      int blockIndex = 0;

      if (previousBlocks.isNotEmpty) {
        previousHash = previousBlocks.first['block_hash'] as String;
        blockIndex = (previousBlocks.first['block_index'] as int) + 1;
      }

      final timestamp = DateTime.now().toIso8601String();
      final phoneHash = hashPhoneNumber(phoneNumber);

      // Generate the block hash
      final blockHash = generateHash(
        phoneHash: phoneHash,
        riskScore: riskScore,
        verdict: verdict,
        timestamp: timestamp,
        previousHash: previousHash,
        modelVersion: modelVersion,
      );

      // Insert the block
      await db.insert('blockchain_ledger', {
        'block_index': blockIndex,
        'block_hash': blockHash,
        'previous_hash': previousHash,
        'phone_hash': phoneHash,
        'risk_score': riskScore,
        'verdict': verdict,
        'model_version': modelVersion,
        'timestamp': timestamp,
      });

      debugPrint('[Blockchain] Block #$blockIndex added: ${blockHash.substring(0, 16)}...');

      return {
        'block_index': blockIndex,
        'block_hash': blockHash,
        'phone_hash': phoneHash,
        'timestamp': timestamp,
      };
    } catch (e) {
      debugPrint('[Blockchain] Error adding block: $e');
      return {};
    }
  }

  /// Verify the integrity of the entire chain
  Future<Map<String, dynamic>> verifyChain(Database db) async {
    try {
      final blocks = await db.query('blockchain_ledger', orderBy: 'block_index ASC');

      if (blocks.isEmpty) {
        return {'valid': true, 'blocks': 0, 'message': 'Empty chain'};
      }

      String expectedPreviousHash = '0000000000000000000000000000000000000000000000000000000000000000';
      int validBlocks = 0;

      for (final block in blocks) {
        final storedPreviousHash = block['previous_hash'] as String;
        final storedHash = block['block_hash'] as String;

        // Verify chain link
        if (storedPreviousHash != expectedPreviousHash) {
          return {
            'valid': false,
            'blocks': blocks.length,
            'broken_at': block['block_index'],
            'message': 'Chain broken at block #${block['block_index']}',
          };
        }

        // Verify hash integrity
        final recalculatedHash = generateHash(
          phoneHash: block['phone_hash'] as String,
          riskScore: block['risk_score'] as double,
          verdict: block['verdict'] as String,
          timestamp: block['timestamp'] as String,
          previousHash: storedPreviousHash,
          modelVersion: block['model_version'] as String,
        );

        if (recalculatedHash != storedHash) {
          return {
            'valid': false,
            'blocks': blocks.length,
            'tampered_at': block['block_index'],
            'message': 'Data tampered at block #${block['block_index']}',
          };
        }

        expectedPreviousHash = storedHash;
        validBlocks++;
      }

      return {
        'valid': true,
        'blocks': validBlocks,
        'message': 'Chain verified: $validBlocks blocks intact',
      };
    } catch (e) {
      return {'valid': false, 'blocks': 0, 'message': 'Verification error: $e'};
    }
  }

  /// Get total block count
  Future<int> getBlockCount(Database db) async {
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM blockchain_ledger');
    return result.first['count'] as int;
  }

  /// Get recent blocks for display
  Future<List<Map<String, dynamic>>> getRecentBlocks(Database db, {int limit = 10}) async {
    return await db.query('blockchain_ledger', orderBy: 'block_index DESC', limit: limit);
  }
}
