import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../webServer.dart';
import '../permessionManager.dart';
import 'inCallPage.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final WebServer _server = WebServer();
  final _serverController = TextEditingController();
  bool _isCheckingPermissions = false;
  String _localIp = '';
  final int _port = 5000;
  @override
  void initState() {
    super.initState();
    _checkInitialPermissions();
  }

  Future<void> _checkInitialPermissions() async {
    setState(() => _isCheckingPermissions = true);

    // final hasPermission = await PermissionManager.checkMicrophonePermission();
    final hasPermission = await PermissionManager.checkAllPermissions();
    if (!hasPermission) {
      PermissionManager.showPermissionDialog(context);
    }

    setState(() => _isCheckingPermissions = false);
  }

  Future<void> _navigateToManager() async {
    if (_isCheckingPermissions) return;

    // final hasPermission = await PermissionManager.checkMicrophonePermission();
    final hasPermission = await PermissionManager.checkAllPermissions();
    if (!hasPermission) {
      final granted = await PermissionManager.requestMicrophonePermission();
      if (!granted) {
        PermissionManager.showPermissionDialog(context);
        return;
      }
    }
    await _getLocalIp();
    if (!_server.isRunning) _server.start(port: _port);

    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => InCallPage(
            ip: _localIp,
            isManager: true,
          ),
        ),
      );
    }
  }

  Future<void> _navigateToParticipant() async {
    if (_isCheckingPermissions) return;

    final hasPermission = await PermissionManager.checkAllPermissions();
    // final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      final granted = await PermissionManager.requestMicrophonePermission();
      if (!granted) {
        PermissionManager.showPermissionDialog(context);
        return;
      }
    }

    if (mounted) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => InCallPage(
                ip: _serverController.text,
              )));
    }
  }

  Future<void> _getLocalIp() async {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();

    setState(() {
      _localIp = ip.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('اختار الدور'),
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
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            // mainAxisSize: MainAxisSize.min,
            children: [
              
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
                TextField(
                    controller: _serverController,
                    decoration: InputDecoration(
                      // labelText: 'عنوان خادم الإشارات',
                      hintText: '192.168.43.1',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.dns),
                    )),
                const SizedBox(height: 12),
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
             
            ],
          ),
        ),
      ),
    );
  }
}
