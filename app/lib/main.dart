import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge: content extends behind status bar
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));

  // Load saved server URL (default to localhost for development)
  final prefs = await SharedPreferences.getInstance();
  final server = prefs.getString('server') ?? 'http://localhost:18800';
  await ApiService.setServer(server);

  runApp(const KnowledgeBaseApp());
}

class KnowledgeBaseApp extends StatefulWidget {
  const KnowledgeBaseApp({super.key});

  @override
  State<KnowledgeBaseApp> createState() => _KnowledgeBaseAppState();
}

class _KnowledgeBaseAppState extends State<KnowledgeBaseApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
    // Update status bar icons for theme
    SystemChrome.setSystemUIOverlayStyle(
      _themeMode == ThemeMode.dark
          ? const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '知识库',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.light(
          primary: const Color(0xFFc96442),
          secondary: const Color(0xFFc96442),
          surface: const Color(0xFFFFFFFF),
          background: const Color(0xFFf5f4ed),
        ),
        scaffoldBackgroundColor: const Color(0xFFf5f4ed),
        textTheme: const TextTheme().apply(fontFamily: 'MiSans'),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          foregroundColor: Color(0xFF141413),
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFd4785a),
          secondary: const Color(0xFFd4785a),
          surface: const Color(0xFF1c1c1a),
          background: const Color(0xFF141413),
        ),
        scaffoldBackgroundColor: const Color(0xFF141413),
        textTheme: const TextTheme().apply(fontFamily: 'MiSans'),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1c1c1a),
          foregroundColor: Color(0xFFe4ece0),
          elevation: 0,
        ),
      ),
      home: HomeScreen(
        onToggleTheme: toggleTheme,
        isDark: _themeMode == ThemeMode.dark,
      ),
    );
  }
}
