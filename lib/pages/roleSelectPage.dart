// ---------------------------
// صفحة اختيار الدور
// ---------------------------

import 'package:flutter/material.dart';

import '../permessionManager.dart';
import 'managerPage.dart';
import 'oarticipantPage.dart';

class RoleSelectPage extends StatefulWidget {
  const RoleSelectPage({super.key});
  
  @override
  State<RoleSelectPage> createState() => _RoleSelectPageState();
}

class _RoleSelectPageState extends State<RoleSelectPage> {
  bool _isCheckingPermissions = false;
  
  @override
  void initState() {
    super.initState();
    _checkInitialPermissions();
  }
  
  Future<void> _checkInitialPermissions() async {
    setState(() => _isCheckingPermissions = true);
    
    final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      _showPermissionDialog();
    }
    
    setState(() => _isCheckingPermissions = false);
  }
  
  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('إذن الميكروفون مطلوب'),
        content: const Text(
          'هذا التطبيق يحتاج إلى إذن الوصول للميكروفون لإجراء المكالمات الصوتية. '
          'يرجى السماح بالوصول للميكروفون للمتابعة.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await PermissionManager.requestMicrophonePermission();
            },
            child: const Text('طلب الإذن'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _navigateToManager() async {
    if (_isCheckingPermissions) return;
    
    final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      final granted = await PermissionManager.requestMicrophonePermission();
      if (!granted) {
        _showPermissionDialog();
        return;
      }
    }
    
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ManagerPage())
      );
    }
  }
  
  Future<void> _navigateToParticipant() async {
    if (_isCheckingPermissions) return;
    
    final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      final granted = await PermissionManager.requestMicrophonePermission();
      if (!granted) {
        _showPermissionDialog();
        return;
      }
    }
    
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ParticipantPage())
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('اختر دورك في المكالمة'),
        centerTitle: true,
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue[50]!, Colors.white],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.phone,
                  size: 80,
                  color: Colors.blue[700],
                ),
                const SizedBox(height: 32),
                const Text(
                  'مرحباً بك في تطبيق المكالمات الصوتية',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  'اختر دورك للبدء في المكالمة',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                if (_isCheckingPermissions)
                  const Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('جاري التحقق من الأذونات...'),
                    ],
                  )
                else ...[
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _navigateToManager,
                      icon: const Icon(Icons.wifi_tethering, size: 24),
                      label: const Text(
                        'بدء كمدير (استضافة المكالمة)',
                        style: TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[600],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _navigateToParticipant,
                      icon: const Icon(Icons.person_add, size: 24),
                      label: const Text(
                        'انضمام كمشارك',
                        style: TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[600],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue),
                      SizedBox(height: 8),
                      Text(
                        'نصائح:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '• المدير: يستضيف المكالمة ويدير الاتصالات\n'
                        '• المشارك: ينضم إلى مكالمة موجودة\n'
                        '• تأكد من اتصال جميع الأجهزة بنفس الشبكة',
                        style: TextStyle(fontSize: 12, color: Colors.blue),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
