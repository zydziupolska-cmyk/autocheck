import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/dtc_code.dart';
import 'models/engine_specs.dart';
import 'package:provider/provider.dart';
import 'screens/main_tab_screen.dart';
import 'services/datalogger_service.dart';
import 'services/obd_service.dart';
import 'services/pid_definitions_store.dart';
import 'services/sniff_service.dart';
import 'services/coding_service.dart';
import 'services/engine_memory.dart';
import 'services/fault_notes.dart';
import 'services/dtc_user_descriptions.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opisy kodów błędów (ok. 4500 kodów, język angielski)
  try {
    DtcCode.loadDescriptions(await rootBundle.loadString("assets/dtc/obd_descriptions_en.json"));
    DtcCode.loadVagDescriptions(await rootBundle.loadString("assets/dtc/vag_fault_codes_en.json"));
    DtcCode.loadPlDescriptions(await rootBundle.loadString("assets/data/dtc_pl.json"));
  } catch (_) {}

  // Specyfikacje silników po kodzie (car2db, offline) — dane do karty silnika i raportu
  try {
    EngineSpecs.loadFromJson(await rootBundle.loadString("assets/data/engine_specs.json"));
  } catch (_) {}

  final obdService = ObdService();
  final engineMemory = EngineMemory();
  final faultNotes = FaultNotes();
  final dtcUserDescriptions = DtcUserDescriptions();
  final dataloggerService = DataloggerService(obdService: obdService, engineMemory: engineMemory);
  final definitionsStore = PidDefinitionsStore(obd: obdService);
  final sniffService = SniffService(obd: obdService);
  final codingService = CodingService(obd: obdService);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: obdService),
        ChangeNotifierProvider.value(value: dataloggerService),
        ChangeNotifierProvider.value(value: definitionsStore),
        ChangeNotifierProvider.value(value: sniffService),
        ChangeNotifierProvider.value(value: codingService),
        ChangeNotifierProvider.value(value: engineMemory),
        ChangeNotifierProvider.value(value: faultNotes),
        ChangeNotifierProvider.value(value: dtcUserDescriptions),
      ],
      child: const DynomicDiagApp(),
    ),
  );
}

class DynomicDiagApp extends StatelessWidget {
  const DynomicDiagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Dynomic Diag",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainTabScreen(),
    );
  }
}
