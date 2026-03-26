class CallRecord {
  final int? id;
  final String phoneNumber;
  final String callType; // 'incoming', 'outgoing', 'missed'
  final String result; // 'ai_blocked', 'human_verified', 'unknown'
  final double riskScore;
  final String timestamp;
  final String? recordingPath;
  final int duration; // in seconds
  final String? blockHash;
  final String? aiModelUsed;
  final String? contactName;
  final bool isRealAnalysis;
  final String? analysisSummary;

  CallRecord({
    this.id,
    required this.phoneNumber,
    this.contactName,
    required this.callType,
    required this.result,
    required this.riskScore,
    required this.timestamp,
    this.recordingPath,
    this.duration = 0,
    this.blockHash,
    this.aiModelUsed = 'simulated',
    this.isRealAnalysis = false,
    this.analysisSummary,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'phoneNumber': phoneNumber,
      'contactName': contactName,
      'callType': callType,
      'result': result,
      'riskScore': riskScore,
      'timestamp': timestamp,
      'recordingPath': recordingPath,
      'duration': duration,
      'block_hash': blockHash,
      'ai_model_used': aiModelUsed,
      'is_real_analysis': isRealAnalysis ? 1 : 0,
      'analysisSummary': analysisSummary,
    };
  }

  factory CallRecord.fromMap(Map<String, dynamic> map) {
    return CallRecord(
      id: map['id'] as int?,
      phoneNumber: map['phoneNumber'] as String,
      contactName: map['contactName'] as String?,
      callType: map['callType'] as String,
      result: map['result'] as String,
      riskScore: (map['riskScore'] as num).toDouble(),
      timestamp: map['timestamp'] as String,
      recordingPath: map['recordingPath'] as String?,
      duration: map['duration'] as int? ?? 0,
      blockHash: map['block_hash'] as String?,
      aiModelUsed: map['ai_model_used'] as String? ?? 'simulated',
      isRealAnalysis: (map['is_real_analysis'] as int? ?? 0) == 1,
      analysisSummary: map['analysisSummary'] as String?,
    );
  }
}
