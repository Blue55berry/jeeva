import 'package:flutter/material.dart';
import '../services/database_service.dart';
import 'package:intl/intl.dart';

class AnalyticsView extends StatefulWidget {
  const AnalyticsView({super.key});

  @override
  State<AnalyticsView> createState() => _AnalyticsViewState();
}

class _AnalyticsViewState extends State<AnalyticsView> {
  bool _isLoading = true;
  int _totalUploads = 0;
  int _totalLiveCalls = 0;
  int _totalThreatsBlocked = 0;
  Map<String, int> _dateWiseUsage = {};
  
  @override
  void initState() {
    super.initState();
    _fetchUsageStats();
  }

  Future<void> _fetchUsageStats() async {
    try {
      final records = await DatabaseService().getCallRecords(limit: 500); // grabbing a large chunk
      
      int uploads = 0;
      int liveCalls = 0;
      int threats = 0;
      Map<String, int> dates = {};

      for (var record in records) {
        if (record.callType == 'uploaded') {
          uploads++;
        } else {
          liveCalls++;
        }
        
        if (record.result == 'ai_blocked') {
          threats++;
        }
        
        // Group by distinct date strings format YYYY-MM-DD
        try {
          DateTime dt = DateTime.parse(record.timestamp);
          String dateStr = DateFormat('MMM dd, yyyy').format(dt);
          dates[dateStr] = (dates[dateStr] ?? 0) + 1;
        } catch (e) {
          // skip parse error
        }
      }

      if (mounted) {
        setState(() {
          _totalUploads = uploads;
          _totalLiveCalls = liveCalls;
          _totalThreatsBlocked = threats;
          
          // Sort dates chronologically
          _dateWiseUsage = Map.fromEntries(
            dates.entries.toList()..sort((a, b) => b.key.compareTo(a.key))
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Analytics Fetch Error: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFD4A843)));
    }
    
    double bottomPadding = MediaQuery.of(context).padding.bottom;
    int totalInteractions = _totalUploads + _totalLiveCalls;
    double uploadRatio = totalInteractions > 0 ? (_totalUploads / totalInteractions) : 0;
    double callRatio = totalInteractions > 0 ? (_totalLiveCalls / totalInteractions) : 0;

    return SingleChildScrollView(
      key: const ValueKey('analytics'),
      padding: EdgeInsets.only(left: 20, right: 20, bottom: 80 + bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Usage & Analytics", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 8),
          const Text("Track where your deepfake analysis comes from", style: TextStyle(color: Color(0xFF666666), fontSize: 13)),
          const SizedBox(height: 24),

          // High Level Summary Card
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.3)),
              boxShadow: [BoxShadow(color: const Color(0xFFD4A843).withValues(alpha: 0.08), blurRadius: 16)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Primary Source", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFF2ECC71).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        _totalLiveCalls >= _totalUploads ? "Live Calling" : "File Uploads", 
                        style: const TextStyle(color: Color(0xFF2ECC71), fontSize: 11, fontWeight: FontWeight.bold)
                      ),
                    )
                  ],
                ),
                const SizedBox(height: 20),
                
                // Progress Bar representation
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    height: 12,
                    child: Row(
                      children: [
                        if (totalInteractions == 0) Expanded(child: Container(color: const Color(0xFFEEEEEE))),
                        if (totalInteractions > 0) Expanded(flex: (callRatio * 100).toInt(), child: Container(color: const Color(0xFFD4A843))),
                        if (totalInteractions > 0) Expanded(flex: (uploadRatio * 100).toInt(), child: Container(color: const Color(0xFFE74C3C))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildLegendDot(const Color(0xFFD4A843), "Live Calls", "${(callRatio * 100).toInt()}%"),
                    _buildLegendDot(const Color(0xFFE74C3C), "Uploads", "${(uploadRatio * 100).toInt()}%"),
                  ],
                )
              ],
            ),
          ),
          const SizedBox(height: 30),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatSquare(Icons.security, "Total Protected", "$totalInteractions"),
              _buildStatSquare(Icons.warning_amber_rounded, "Threats Blocked", "$_totalThreatsBlocked", isRed: true),
            ],
          ),
          
          const SizedBox(height: 30),
          const Text("Date-wise Usage", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 16),
          
          if (_dateWiseUsage.isEmpty)
            const Text("No usage data available yet.", style: TextStyle(color: Color(0xFF999999), fontStyle: FontStyle.italic))
          else
            ..._dateWiseUsage.entries.map((req) {
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE0D5C0)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.calendar_month, color: Color(0xFFB8860B), size: 20),
                        const SizedBox(width: 12),
                        Text(req.key, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF333333))),
                      ],
                    ),
                    Text("${req.value} Analysis runs", style: const TextStyle(color: Color(0xFF666666), fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              );
            }),
            
        ],
      ),
    );
  }

  Widget _buildLegendDot(Color color, String label, String percentage) {
    return Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text("$label ($percentage)", style: const TextStyle(color: Color(0xFF666666), fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }
  
  Widget _buildStatSquare(IconData icon, String title, String value, {bool isRed = false}) {
    Color primColor = isRed ? const Color(0xFFE74C3C) : const Color(0xFFD4A843);
    
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: primColor.withValues(alpha: 0.05),
          border: Border.all(color: primColor.withValues(alpha: 0.2)),
          borderRadius: BorderRadius.circular(20)
        ),
        child: Column(
          children: [
            Icon(icon, color: primColor, size: 28),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: primColor)),
            Text(title, style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
          ],
        )
      ),
    );
  }
}
