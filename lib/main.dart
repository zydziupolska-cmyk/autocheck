import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/dtc_code.dart';
import 'package:provider/provider.dart';
import 'screens/main_tab_screen.dart';
import 'services/datalogger_service.dart';
import 'services/obd_service.dart';
import 'services/pid_definitions_store.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opisy kodów błędów (ok. 4500 kodów, język angielski)
  try {
    DtcCode.loadDescriptions(await rootBundle.loadString("assets/dtc/obd_descriptions_en.json"));
    DtcCode.loadVagDescriptions(await rootBundle.loadString("assets/dtc/vag_fault_codes_en.json"));
  } catch (_) {}

  final obdService = ObdService();
  final dataloggerService = DataloggerService(obdService: obdService);
  final definitionsStore = PidDefinitionsStore(obd: obdService);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: obdService),
        ChangeNotifierProvider.value(value: dataloggerService),
        ChangeNotifierProvider.value(value: definitionsStore),
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
      title: "AutoCheck - OBD2",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainTabScreen(),
    );
  }
}
