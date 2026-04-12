import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/call_record.dart';
import '../services/database_service.dart';

class IndividualContactProfile extends StatefulWidget {
  final String phoneNumber;
  final String? displayName;
  final String? imagePath;

  const IndividualContactProfile({
    super.key,
    required this.phoneNumber,
    this.displayName,
    this.imagePath,
  });

  @override
  State<IndividualContactProfile> createState() => _IndividualContactProfileState();
}

class _IndividualContactProfileState extends State<IndividualContactProfile> {
  final DatabaseService _db = DatabaseService();
  final ImagePicker _imagePicker = ImagePicker();
  List<CallRecord> _allRecords = [];
  bool _isLoading = true;
  bool _hasChanges = false;
  late TextEditingController _nameController;
  String? _imagePath;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.displayName ?? widget.phoneNumber,
    );
    _imagePath = widget.imagePath;
    _loadAllCalls();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadAllCalls() async {
    final records = await _db.getCallRecords();
    // Filter specifically for this number (normalized)
    String normTarget = widget.phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
    if (normTarget.length > 10) normTarget = normTarget.substring(normTarget.length - 10);

    setState(() {
      _allRecords = records.where((r) {
        String rDigits = r.phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
        String rSuffix = rDigits.length >= 10 ? rDigits.substring(rDigits.length - 10) : rDigits;
        return rSuffix == normTarget;
      }).toList();
      _isLoading = false;
    });
  }

  String _formatDateTime(String timestamp) {
    try {
      DateTime dt = DateTime.parse(timestamp);
      return "${dt.hour}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}";
    } catch (e) {
      return "Unknown";
    }
  }

  String _formatFullDate(String timestamp) {
    try {
      DateTime dt = DateTime.parse(timestamp);
      List<String> months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      return "${dt.day} ${months[dt.month - 1]} ${dt.year}";
    } catch (e) {
      return "";
    }
  }

  @override
  Widget build(BuildContext context) {
    // Group records by date
    Map<String, List<CallRecord>> grouped = {};
    for (var r in _allRecords) {
      String date = _formatFullDate(r.timestamp);
      grouped.putIfAbsent(date, () => []).add(r);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF9F9FB),
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(_hasChanges),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: const Text("Call History", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _showEditSheet,
            icon: const Icon(Icons.edit_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4A843)))
                : _allRecords.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        itemCount: grouped.keys.length,
                        itemBuilder: (context, index) {
                          String date = grouped.keys.elementAt(index);
                          List<CallRecord> calls = grouped[date]!;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                child: Text(date, style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.0)),
                              ),
                              ...calls.map((c) => _buildCallItem(c)),
                              const SizedBox(height: 10),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final label = _nameController.text.trim().isEmpty
        ? widget.phoneNumber
        : _nameController.text.trim();
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.only(bottom: 24, top: 10),
      child: Column(
        children: [
          GestureDetector(
            onTap: _pickImage,
            child: CircleAvatar(
              radius: 40,
              backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.1),
              backgroundImage: _imagePath != null && _imagePath!.isNotEmpty && File(_imagePath!).existsSync()
                  ? FileImage(File(_imagePath!))
                  : null,
              child: _imagePath == null || _imagePath!.isEmpty || !File(_imagePath!).existsSync()
                  ? Text(
                      label.substring(0, 1).toUpperCase(),
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFFB8860B)),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 4),
          Text(
            widget.phoneNumber,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildCallItem(CallRecord record) {
    bool isFake = record.result == 'ai_blocked';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Icon(
            record.callType == 'incoming' ? Icons.call_received : record.callType == 'outgoing' ? Icons.call_made : Icons.call_missed,
            size: 18,
            color: record.callType == 'missed' ? Colors.red : const Color(0xFFB8860B),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDateTime(record.timestamp),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1A1A1A)),
                ),
                const SizedBox(height: 2),
                Text(
                  isFake ? "AI Detected Risk" : "Secure Call",
                  style: TextStyle(fontSize: 12, color: isFake ? Colors.red : Colors.green, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Text(
            "${(record.riskScore * 100).toInt()}% Risk",
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_toggle_off_rounded, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text("No logs found", style: TextStyle(color: Colors.grey.shade400, fontSize: 16)),
        ],
      ),
    );
  }

  Future<void> _pickImage() async {
    final file = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (file == null) return;

    setState(() {
      _imagePath = file.path;
      _hasChanges = true;
    });
    await _saveProfileChanges();
  }

  Future<void> _saveProfileChanges() async {
    await _db.saveCustomContactProfile(
      widget.phoneNumber,
      displayName: _nameController.text.trim().isEmpty
          ? widget.phoneNumber
          : _nameController.text.trim(),
      imagePath: _imagePath,
    );
    _hasChanges = true;
  }

  Future<void> _showEditSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Edit Contact',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Contact Name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Update Photo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await _saveProfileChanges();
                    if (mounted) {
                      navigator.pop();
                      setState(() {});
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB8860B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('Save Changes'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
