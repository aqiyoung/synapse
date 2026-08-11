import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/api_service.dart';
import 'services/update_service.dart';
import 'models/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge: content extends behind status bar
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 状态栏样式会在主题变化时动态更新

  // Load saved server URL (default to localhost for development)
  final prefs = await SharedPreferences.getInstance();
  final server = prefs.getString('server') ?? 'http://localhost:18800';
  await ApiService.setServer(server);

  // Silent update check（受设置里「启动时自动检查更新」开关控制，默认开启）
  UpdateService().checkOnLaunch();

  runApp(const KnowledgeBaseApp());
}

class _StatusBarObserver extends NavigatorObserver {
  final VoidCallback onRouteChanged;
  _StatusBarObserver(this.onRouteChanged);

  @override
  void didPush(Route route, Route? previousRoute) => onRouteChanged();
  @override
  void didPop(Route route, Route? previousRoute) => onRouteChanged();
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => onRouteChanged();
}

class KnowledgeBaseApp extends StatefulWidget {
  const KnowledgeBaseApp({super.key});

  @override
  State<KnowledgeBaseApp> createState() => _KnowledgeBaseAppState();
}

class _KnowledgeBaseAppState extends State<KnowledgeBaseApp> {
  ThemeMode _themeMode = ThemeMode.light;
  int _themeIndex = 0;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
    _loadThemeIndex();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDark') ?? false;
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
    _updateStatusBar();
  }

  Future<void> _loadThemeIndex() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeIndex = prefs.getInt('themeIndex') ?? 0;
    });
  }

  void _updateStatusBar() {
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

  void toggleTheme() async {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
    // MaterialApp 重建后系统 UI 会被重置, 用 postFrameCallback 确保在 rebuild 之后生效
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateStatusBar());
    _updateStatusBar();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDark', _themeMode == ThemeMode.dark);
  }

  void setThemeIndex(int index) async {
    setState(() {
      _themeIndex = index;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeIndex', index);
  }

  @override
  Widget build(BuildContext context) {
    final appTheme = AppTheme.presets[_themeIndex];

    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [_StatusBarObserver(_updateStatusBar)],
      title: 'Synapse',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.light(
          primary: appTheme.lightPrimary,
          secondary: appTheme.lightPrimary,
          surface: appTheme.lightSurface,
        ),
        scaffoldBackgroundColor: appTheme.lightBg,
        textTheme: const TextTheme().apply(fontFamily: 'MiSans'),
        appBarTheme: const AppBarTheme(
          foregroundColor: Color(0xFF141413),
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.dark(
          primary: appTheme.darkPrimary,
          secondary: appTheme.darkPrimary,
          surface: appTheme.darkSurface,
        ),
        scaffoldBackgroundColor: appTheme.darkBg,
        textTheme: const TextTheme().apply(fontFamily: 'MiSans'),
        appBarTheme: const AppBarTheme(
          foregroundColor: Color(0xFFe4ece0),
          elevation: 0,
        ),
      ),
      home: HomeScreen(
        onToggleTheme: toggleTheme,
        isDark: _themeMode == ThemeMode.dark,
        themeIndex: _themeIndex,
        onThemeChanged: setThemeIndex,
      ),
    );
  }
}
