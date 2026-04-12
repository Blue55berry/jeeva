import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'dart:io';
import '../services/database_service.dart';
import '../models/call_record.dart';
import 'individual_contact_profile.dart';

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
  Map<String, Map<String, String>> _customProfiles = {};
  
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
      
      _customProfiles = await _db.getCustomContactProfiles();
      final records = _deduplicateCallRecords(await _db.getCallRecords());
      bool anyUpdated = false;
      
      if (await FlutterContacts.requestPermission(readonly: true)) {
        final List<Contact> deviceContacts = await FlutterContacts.getContacts(withProperties: true);
        _contacts = _deduplicateContacts(
          deviceContacts.where((c) => c.phones.isNotEmpty).toList(),
        );
        
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

      final finalRecords = anyUpdated
          ? _deduplicateCallRecords(await _db.getCallRecords())
          : records;

      if (mounted) {
        setState(() {
          _records = finalRecords.where((r) => r.callType != 'uploaded').toList();
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
      return "${dt.hour}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}";
    } catch (e) {
      return 'Unknown';
    }
  }

  String _formatDateHeader(String timestamp) {
    try {
      DateTime dt = DateTime.parse(timestamp);
      DateTime now = DateTime.now();
      if (dt.day == now.day && dt.month == now.month && dt.year == now.year) return 'TODAY';
      if (dt.day == now.day - 1 && dt.month == now.month && dt.year == now.year) return 'YESTERDAY';
      List<String> months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      return "${dt.day} ${months[dt.month - 1]} ${dt.year}".toUpperCase();
    } catch (e) {
      return 'OLDER';
    }
  }

  List<Contact> _deduplicateContacts(List<Contact> contacts) {
    final Map<String, Contact> uniqueContacts = {};
    for (final contact in contacts) {
      final primaryNumber = contact.phones.isNotEmpty
          ? contact.phones.first.number.replaceAll(RegExp(r'[\s\-\(\)\+]'), '')
          : '';
      final key = '${contact.displayName.toLowerCase()}|$primaryNumber';
      uniqueContacts.putIfAbsent(key, () => contact);
    }
    return uniqueContacts.values.toList();
  }

  List<CallRecord> _deduplicateCallRecords(List<CallRecord> records) {
    final List<CallRecord> uniqueRecords = [];
    for (final record in records) {
      final duplicateIndex = uniqueRecords.indexWhere(
        (existing) => _isSameCall(existing, record),
      );

      if (duplicateIndex == -1) {
        uniqueRecords.add(record);
      } else {
        uniqueRecords[duplicateIndex] = _preferRecord(
          uniqueRecords[duplicateIndex],
          record,
        );
      }
    }
    return uniqueRecords;
  }

  bool _isSameCall(CallRecord a, CallRecord b) {
    final normalizedA = a.phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    final normalizedB = b.phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    if (a.callType != b.callType) {
      return false;
    }

    final DateTime timeA = DateTime.tryParse(a.timestamp) ?? DateTime(1970);
    final DateTime timeB = DateTime.tryParse(b.timestamp) ?? DateTime(1970);
    final bool nearInTime = timeA.difference(timeB).inMinutes.abs() <= 2;
    if (normalizedA.isEmpty || normalizedB.isEmpty) {
      return nearInTime && a.result == b.result;
    }
    return normalizedA == normalizedB && timeA.difference(timeB).inMinutes.abs() <= 10;
  }

  CallRecord _preferRecord(CallRecord current, CallRecord candidate) {
    if (_hasDisplayName(candidate) && !_hasDisplayName(current)) return candidate;
    if (_hasKnownNumber(candidate) && !_hasKnownNumber(current)) return candidate;
    if (candidate.duration > current.duration) return candidate;
    if (candidate.isRealAnalysis && !current.isRealAnalysis) return candidate;
    if ((candidate.analysisSummary?.isNotEmpty ?? false) &&
        !(current.analysisSummary?.isNotEmpty ?? false)) {
      return candidate;
    }
    return current;
  }

  bool _hasDisplayName(CallRecord record) {
    final name = record.contactName?.trim() ?? '';
    return name.isNotEmpty && name.toLowerCase() != 'unknown';
  }

  bool _hasKnownNumber(CallRecord record) {
    final number = record.phoneNumber.trim();
    return number.isNotEmpty && number.toLowerCase() != 'unknown';
  }

  String _profileNameForNumber(String phoneNumber, {String? fallbackName}) {
    final profile = _customProfiles[_db.normalizePhoneNumber(phoneNumber)];
    final customName = profile?['displayName']?.trim();
    if (customName != null && customName.isNotEmpty) return customName;
    if (fallbackName != null && fallbackName.trim().isNotEmpty) return fallbackName.trim();
    return phoneNumber;
  }

  String? _profileImageForNumber(String phoneNumber) {
    final profile = _customProfiles[_db.normalizePhoneNumber(phoneNumber)];
    final path = profile?['imagePath']?.trim();
    if (path == null || path.isEmpty) return null;
    return path;
  }

  Widget _buildAvatar(String label, {String? imagePath}) {
    if (imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync()) {
      return CircleAvatar(
        backgroundImage: FileImage(File(imagePath)),
      );
    }

    final initial = label.isNotEmpty ? label[0].toUpperCase() : '?';
    return CircleAvatar(
      backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.1),
      child: Text(
        initial,
        style: const TextStyle(
          color: Color(0xFFB8860B),
          fontWeight: FontWeight.bold,
        ),
      ),
    );
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

    Map<String, List<CallRecord>> grouped = {};
    for (var r in _filteredRecords) {
      String dateKey = _formatDateHeader(r.timestamp);
      grouped.putIfAbsent(dateKey, () => []).add(r);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: grouped.keys.length,
      itemBuilder: (context, index) {
        String date = grouped.keys.elementAt(index);
        List<CallRecord> calls = grouped[date]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 16, bottom: 12),
              child: Text(date,
                  style: const TextStyle(
                      color: Color(0xFFB8860B),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5)),
            ),
            ...calls.map((record) {
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
            }),
          ],
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
        return GestureDetector(
          onTap: () async {
            final changed = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (context) => IndividualContactProfile(
                  phoneNumber: number,
                  displayName: _profileNameForNumber(
                    number,
                    fallbackName: contact.displayName,
                  ),
                  imagePath: _profileImageForNumber(number),
                ),
              ),
            );
            if (changed == true) {
              await refreshHistory();
            }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE0D5C0).withValues(alpha: 0.6)),
            ),
            child: Row(
              children: [
                _buildAvatar(
                  _profileNameForNumber(number, fallbackName: contact.displayName),
                  imagePath: _profileImageForNumber(number),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _profileNameForNumber(number, fallbackName: contact.displayName),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Color(0xFF1A1A1A)),
                      ),
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
          ),
        );
      },
    );
  }

  Widget _buildLogTile(CallRecord record, bool isFake) {
    return GestureDetector(
      onTap: () async {
        final changed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (context) => IndividualContactProfile(
              phoneNumber: record.phoneNumber,
              displayName: _profileNameForNumber(
                record.phoneNumber,
                fallbackName: record.contactName,
              ),
              imagePath: _profileImageForNumber(record.phoneNumber),
            ),
          ),
        );
        if (changed == true) {
          await refreshHistory();
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE0D5C0)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isFake
                    ? const Color(0xFFE74C3C).withValues(alpha: 0.1)
                    : const Color(0xFF2ECC71).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                  isFake ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                  color:
                      isFake ? const Color(0xFFE74C3C) : const Color(0xFF2ECC71)),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      _profileNameForNumber(
                        record.phoneNumber,
                        fallbackName: record.contactName,
                      ),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(isFake ? "AI Blocked" : "Verified",
                          style: TextStyle(
                              color: isFake
                                  ? const Color(0xFFE74C3C)
                                  : const Color(0xFF2ECC71),
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      Text("Risk: ${(record.riskScore * 100).toInt()}%",
                          style: const TextStyle(
                              color: Color(0xFF888888), fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_formatTimestamp(record.timestamp),
                    style:
                        const TextStyle(color: Color(0xFFAAAAAA), fontSize: 11)),
                const SizedBox(height: 4),
                Icon(
                  record.callType == 'incoming'
                      ? Icons.call_received
                      : record.callType == 'outgoing'
                          ? Icons.call_made
                          : Icons.call_missed,
                  size: 16,
                  color: const Color(0xFFB8860B),
                ),
              ],
            ),
          ],
        ),
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
