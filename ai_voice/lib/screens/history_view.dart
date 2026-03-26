import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../services/database_service.dart';
import '../models/call_record.dart';

class HistoryView extends StatefulWidget {
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => HistoryViewState();
}

class HistoryViewState extends State<HistoryView> with SingleTickerProviderStateMixin {
  final DatabaseService _db = DatabaseService();
  List<CallRecord> _records = [];
  List<Contact> _contacts = [];
  List<Contact> _filteredContacts = [];
  List<CallRecord> _filteredRecords = [];
  
  bool _isLoading = true;
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _searchController.addListener(_performSearch);
    refreshHistory();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _performSearch() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredContacts = _contacts.where((c) => 
        c.displayName.toLowerCase().contains(query) || 
        c.phones.any((p) => p.number.contains(query))
      ).toList();
      
      _filteredRecords = _records.where((r) => 
        (r.contactName?.toLowerCase().contains(query) ?? false) || 
        r.phoneNumber.contains(query)
      ).toList();
    });
  }

  Future<void> refreshHistory() async {
    try {
      if (mounted) setState(() => _isLoading = true);
      
      final records = await _db.getCallRecords();
      bool anyUpdated = false;
      
      // Fetch device contacts for the second section
      if (await FlutterContacts.requestPermission(readonly: true)) {
        final List<Contact> deviceContacts = await FlutterContacts.getContacts(withProperties: true);
        _contacts = deviceContacts.where((c) => c.phones.isNotEmpty).toList();
        
        // Auto-resolve names for records
        for (var record in records) {
          if (record.contactName == null || record.contactName!.isEmpty) {
            String normTarget = record.phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
            for (var c in _contacts) {
               for (var p in c.phones) {
                 String normP = p.number.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
                 if (normP.contains(normTarget) || normTarget.contains(normP)) {
                    await _db.updateCallRecordContactName(record.id!, c.displayName);
                    anyUpdated = true;
                    break;
                 }
               }
               if (anyUpdated) break;
            }
          }
        }
      }

      final finalRecords = anyUpdated ? await _db.getCallRecords() : records;

      if (mounted) {
        setState(() {
          // Aggressive Deduplication: One entry per person/number
          final Map<String, CallRecord> uniqueMap = {};
          final Set<String> processedBaseNumbers = {};
          
          for (var r in finalRecords) {
            // ONLY show actual telephony logs (Filter out manual uploads/songs)
            if (r.callType == 'uploaded') continue; 
            
            // Normalize phone for comparison (numbers only)
            String digits = r.phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
            // Key by normalized digits to collapse international/local formatting differences
            if (digits.length >= 10) {
              String suffix = digits.substring(digits.length - 10);
              if (!processedBaseNumbers.contains(suffix)) {
                processedBaseNumbers.add(suffix);
                uniqueMap[suffix] = r;
              }
            } else if (!uniqueMap.containsKey(digits)) {
              uniqueMap[digits] = r;
            }
          }
          
          _records = uniqueMap.values.toList();
          _filteredRecords = _records;
          _filteredContacts = _contacts;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("History Refresh Error: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatTimestamp(String timestamp) {
    try {
      DateTime dt = DateTime.parse(timestamp);
      Duration diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (e) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('history'),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Scanner Dashboard", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
              IconButton(
                onPressed: refreshHistory,
                icon: const Icon(Icons.sync_rounded, color: Color(0xFFB8860B)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          
          // Search Bar
          Container(
            height: 48,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE0D5C0)),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 4)],
            ),
            child: Row(
              children: [
                const Icon(Icons.search_rounded, color: Color(0xFFAAAAAA), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: "Find registry number or log...",
                      hintStyle: TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Custom Styled TabBar
          Container(
            height: 50,
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: const Color(0xFFF2EBE0).withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: const Color(0xFFE0D5C0).withValues(alpha: 0.3)),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFB8860B).withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ],
              ),
              labelColor: const Color(0xFFB8860B),
              unselectedLabelColor: const Color(0xFF7A6E5D),
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.3),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              labelPadding: EdgeInsets.zero,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: const [
                 Tab(text: "Monitoring Logs"),
                 Tab(text: "Secure Registry"),
              ],
            ),
          ),
          
          const SizedBox(height: 16),
          
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4A843)))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildMonitoringSection(),
                    _buildContactsSection(),
                  ],
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonitoringSection() {
    if (_filteredRecords.isEmpty) {
       return _buildEmptyState("No matching logs", "No identified security warnings found.", Icons.shield_outlined);
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _filteredRecords.length,
      itemBuilder: (context, index) {
        final record = _filteredRecords[index];
        bool isFake = record.result == 'ai_blocked';
        return Dismissible(
          key: Key(record.id.toString()),
          direction: DismissDirection.endToStart,
          onDismissed: (_) async {
            if (record.id != null) {
              await _db.deleteCallRecord(record.id!);
              refreshHistory();
            }
          },
          child: _buildLogTile(record, isFake),
        );
      },
    );
  }

  Widget _buildContactsSection() {
    if (_filteredContacts.isEmpty) {
       return _buildEmptyState("No matching registry", "Searching in your trusted contacts...", Icons.contact_page_outlined);
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _filteredContacts.length,
      itemBuilder: (context, index) {
        final contact = _filteredContacts[index];
        String number = contact.phones.isNotEmpty ? contact.phones.first.number : 'No number';
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE0D5C0).withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.1),
                child: Text(contact.displayName[0], style: const TextStyle(color: Color(0xFFB8860B), fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(contact.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Color(0xFF1A1A1A))),
                    Text(number, style: const TextStyle(color: Color(0xFF888888), fontSize: 13)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2ECC71).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text("TRUSTED", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF2ECC71))),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLogTile(CallRecord record, bool isFake) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0D5C0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isFake ? const Color(0xFFE74C3C).withValues(alpha: 0.1) : const Color(0xFF2ECC71).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(isFake ? Icons.warning_amber_rounded : Icons.check_circle_outline, color: isFake ? const Color(0xFFE74C3C) : const Color(0xFF2ECC71)),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.contactName != null && record.contactName!.isNotEmpty ? record.contactName! : record.phoneNumber, 
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1A1A1A))
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(isFake ? "AI Blocked" : "Verified", style: TextStyle(color: isFake ? const Color(0xFFE74C3C) : const Color(0xFF2ECC71), fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text("Risk: ${(record.riskScore * 100).toInt()}%", style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_formatTimestamp(record.timestamp), style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 11)),
              const SizedBox(height: 4),
              Icon(
                record.callType == 'incoming' ? Icons.call_received : record.callType == 'outgoing' ? Icons.call_made : Icons.call_missed,
                size: 16, color: const Color(0xFFB8860B),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String title, String sub, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 50, color: const Color(0xFFD4A843).withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(color: Color(0xFF999999), fontSize: 16, fontWeight: FontWeight.w500)),
          Text(sub, style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 13)),
        ],
      ),
    );
  }
}
