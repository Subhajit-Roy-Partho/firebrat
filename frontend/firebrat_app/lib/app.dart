import 'package:flutter/material.dart';
import 'screens/library_screen.dart';
import 'theme/app_theme.dart';

class FirebratApp extends StatelessWidget {
  const FirebratApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Firebrat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const LibraryScreen(),
    );
  }
}
