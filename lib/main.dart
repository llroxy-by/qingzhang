import 'package:flutter/material.dart';

import 'db/app_db.dart';
import 'pages/analysis_page.dart';
import 'pages/home_page.dart';
import 'pages/import_page.dart';
import 'pages/settings_page.dart';

/// 全局应用状态：持有数据库 + 提供一个"数据变了，请刷新"的信号
class AppState extends ChangeNotifier {
  final AppDb db = AppDb();
  int _tick = 0;

  int get tick => _tick;

  /// 任何写操作完成后调用，通知各页面重新加载
  void refresh() {
    _tick++;
    notifyListeners();
  }
}

final appState = AppState();

/// PageView 保活包装：页面滑走后被 keep-alive 保留，回来不重建
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QingzhangApp());
}

class QingzhangApp extends StatelessWidget {
  const QingzhangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '轻账',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w700, color: Colors.black87),
        ),
      ),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  final PageController _pageCtrl = PageController();

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final pages = [
          HomePage(tick: appState.tick),
          AnalysisPage(tick: appState.tick),
          ImportPage(tick: appState.tick),
          SettingsPage(tick: appState.tick),
        ];
        return Scaffold(
          // PageView：左右滑动切换页面（总览 ⇄ 分析 ⇄ 导入 ⇄ 设置）。
          // 每页包 _KeepAlive，滑走再滑回时不丢失状态、不重新加载。
          body: PageView(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _index = i),
            children: [
              for (final p in pages) _KeepAlive(child: p),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) {
              setState(() => _index = i);
              _pageCtrl.animateToPage(
                i,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
              );
            },
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '总览'),
              NavigationDestination(
                  icon: Icon(Icons.insights_outlined),
                  selectedIcon: Icon(Icons.insights),
                  label: '分析'),
              NavigationDestination(
                  icon: Icon(Icons.file_download_outlined),
                  selectedIcon: Icon(Icons.file_download),
                  label: '导入'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置'),
            ],
          ),
        );
      },
    );
  }
}
