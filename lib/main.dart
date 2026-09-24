import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/main_tab_screen.dart';
import 'services/datalogger_service.dart';
import 'services/obd_service.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final obdService = ObdService();
  final dataloggerService = DataloggerService(obdService: obdService);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: dataloggerService),
        Provider.value(value: obdService),
      ],
      child: const AutoCheckApp(),
    ),
  );
}

class AutoCheckApp extends StatelessWidget {
  const AutoCheckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "AutoCheck - vLinker MC+ OBD2",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainTabScreen(),
    );
  }
}
