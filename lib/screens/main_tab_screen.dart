import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';
import 'connection_screen.dart';
import 'sensor_select_screen.dart';
import 'logger_screen.dart';
import 'chart_screen.dart';
import 'diagnostic_screen.dart';
import 'logs_history_screen.dart';

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 2; // Domyślnie na ekranie Rejestratora (gotowy do kliknięcia START!)

  void _switchTab(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final anomalyCount = logger.detectedAnomalies.length;

    final screens = [
      const ConnectionScreen(),
      const SensorSelectScreen(),
      LoggerScreen(onNavigateToTab: _switchTab),
      ChartScreen(onNavigateToTab: _switchTab),
      DiagnosticScreen(onNavigateToTab: _switchTab),
      LogsHistoryScreen(onNavigateToTab: _switchTab),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.border, width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _switchTab,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.bluetooth_connected),
              label: "Połączenie",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.tune),
              label: "Czujniki",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.speed),
              label: "Rejestrator",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.show_chart),
              label: "Wykres",
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: anomalyCount > 0,
                backgroundColor: AppTheme.red,
                label: Text(
                  "$anomalyCount",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
                ),
                child: const Icon(Icons.psychology),
              ),
              label: "Asystent",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.history),
              label: "Historia",
            ),
          ],
        ),
      ),
    );
  }
}
