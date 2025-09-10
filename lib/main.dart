// main.dart
// Flutter LAN WebRTC محسّن مع جميع الإصلاحات من التقرير


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/homePage.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}



// ---------------------------
// التطبيق الرئيسي
// ---------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مكالمات الصوت عبر الشبكة المحلية',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Arial',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 16),
          bodyMedium: TextStyle(fontSize: 14),
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}


