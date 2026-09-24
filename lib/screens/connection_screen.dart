import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart' as fbs;
import 'package:provider/provider.dart';
import '../models/dtc_code.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import 'learning_screen.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  List<ScanResult> _scanResults = [];
  List<fbs.BluetoothDevice> _classicDevices = [];
  bool _isLoadingClassic = false;
  String? _classicError;
  List<DtcCode>? _scannedDtcCodes;
  bool _isLoadingDtc = false;
  bool _dtcReadFailed = false;
  String? _moduleScanProgress;
  String? _moduleScanSummary;

  @override
  void initState() {
    super.initState();
    _loadClassicDevices();
  }

  Future<void> _loadClassicDevices() async {
    setState(() {
      _isLoadingClassic = true;
      _classicError = null;
    });
    try {
      // Android 12+: bez BLUETOOTH_CONNECT lista sparowanych urządzeń jest pusta
      await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
      final devices = await fbs.FlutterBluetoothSerial.instance.getBondedDevices();
      if (mounted) setState(() => _classicDevices = devices);
    } catch (e) {
      if (mounted) setState(() => _classicError = "Nie udało się pobrać listy sparowanych urządzeń: $e");
    }
    if (mounted) setState(() => _isLoadingClassic = false);
  }

  Future<void> _startScan(ObdService obd) async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if ((statuses[Permission.bluetoothScan]?.isDenied ?? false) ||
        (statuses[Permission.bluetoothScan]?.isPermanentlyDenied ?? false)) {
      _showSnack("Brak uprawnień do skanowania Bluetooth", AppTheme.fault);
      return;
    }

    setState(() => _scanResults = []);
    final error = await obd.startScan(onResults: (results) {
      if (mounted) setState(() => _scanResults = results);
    });
    if (error != null) _showSnack(error, AppTheme.fault);
  }

  Future<void> _connect(Future<bool> Function() action) async {
    final ok = await action();
    if (!mounted) return;
    final obd = context.read<ObdService>();
    if (ok) {
      setState(() => _scannedDtcCodes = null);
    } else {
      _showSnack(obd.statusMessage, AppTheme.fault);
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _readDtc(ObdService obd) async {
    setState(() => _isLoadingDtc = true);
    final codes = await obd.readDtcCodes();
    if (!mounted) return;
    setState(() {
      _isLoadingDtc = false;
      _dtcReadFailed = codes == null;
      _scannedDtcCodes = codes;
    });
    if (codes == null) {
      _showSnack(
        obd.status == ObdConnectionStatus.connected
            ? "Sterownik nie odpowiedział na zapytanie o kody błędów."
            : "Najpierw połącz się z samochodem.",
        AppTheme.fault,
      );
    }
  }

  void _showAdapterInfo(ObdService obd) {
    final info = obd.adapterInfo;
    final text = info.entries.map((e) => "${e.key}: ${e.value}").join("\n");
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Adapter i możliwości"),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in info.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: "${e.key}: ", style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    TextSpan(text: e.value, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
                  ])),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
              _showSnack("Skopiowano informacje o adapterze", AppTheme.ok);
            },
            child: const Text("Kopiuj"),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Zamknij")),
        ],
      ),
    );
  }

  Future<void> _scanVagModules(ObdService obd) async {
    setState(() {
      _moduleScanProgress = "Przygotowanie skanu...";
      _moduleScanSummary = null;
    });
    // Nowsze moduły (UDS, MQB i nowsze), potem starsze (TP2.0 / KWP2000, platformy PQ)
    final uds = await obd.scanVagModules(onProgress: (done, total, m) {
      if (mounted) setState(() => _moduleScanProgress = "UDS ${done + 1 > total ? total : done + 1}/$total: ${m.name}");
    });
    final tp20 = await obd.scanVagTp20Modules(onProgress: (done, total, name) {
      if (mounted) setState(() => _moduleScanProgress = "TP2.0 ${done + 1 > total ? total : done + 1}/$total: $name");
    });
    if (!mounted) return;
    final responded = [...uds, ...tp20].where((r) => r.responded).toList();
    final withFaults = responded.where((r) => r.dtcs.isNotEmpty).toList();
    // Ten sam kod z tego samego modułu (np. silnik odpowiada i przez UDS, i przez TP2.0) — raz
    final seen = <String>{};
    final codes = <DtcCode>[
      for (final r in responded)
        for (final d in r.dtcs)
          if (seen.add("${r.module.name}|${d.code}")) d,
    ];
    String label(ModuleScanResult r) =>
        "${r.module.name}${r.identification != null ? ' (${r.identification})' : ''}";
    setState(() {
      _moduleScanProgress = null;
      _dtcReadFailed = false;
      _scannedDtcCodes = codes;
      _moduleScanSummary = responded.isEmpty
          ? "Żaden moduł nie odpowiedział ani przez UDS, ani przez TP2.0. Kody silnika odczytasz przyciskiem „Odczytaj kody błędów”."
          : "Odpowiedziało ${responded.length} modułów: ${responded.map(label).join(', ')}. "
              "${withFaults.isEmpty ? 'Żaden nie ma zapisanych błędów.' : 'Błędy w: ${withFaults.map((r) => r.module.name).toSet().join(', ')}.'}";
    });
  }

  Future<void> _clearDtc(ObdService obd) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Skasować kody usterek?"),
        content: const Text(
          "Zapłon musi być włączony, a silnik wyłączony. Skasowanie usuwa też dane "
          "gotowości (readiness) i zapisane zamrożone ramki — nie usuwa przyczyny usterki.",
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Anuluj")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Skasuj", style: TextStyle(color: AppTheme.fault)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ok = await obd.clearDtcCodes();
    if (!mounted) return;
    _showSnack(
      ok
          ? "Sterownik potwierdził skasowanie błędów."
          : "Sterownik nie potwierdził kasowania. Wyłącz silnik (zapłon ON) i spróbuj ponownie.",
      ok ? AppTheme.ok : AppTheme.fault,
    );
    if (ok) await _readDtc(obd);
  }

  @override
  Widget build(BuildContext context) {
    final obd = context.watch<ObdService>();
    final connected = obd.status == ObdConnectionStatus.connected;

    final connectionMethods = [
      _buildBluetoothSection(obd),
      const SizedBox(height: 20),
      _buildClassicBluetoothSection(obd),
      const SizedBox(height: 20),
      _buildWifiSection(obd),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const BrandTitle(),
        actions: [
          if (connected)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: "Adapter i możliwości",
              onPressed: () => _showAdapterInfo(obd),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _buildStatusCard(obd),
          const SizedBox(height: 16),
          if (connected) ...[
            _buildDtcScannerSection(obd),
            const SizedBox(height: 16),
            _buildPidScannerSection(obd),
            const SizedBox(height: 16),
            Panel(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                title: const Text("Połącz z innym adapterem", style: TextStyle(fontSize: 14)),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                children: connectionMethods,
              ),
            ),
          ] else
            ...connectionMethods,
        ],
      ),
    );
  }

  bool _isBusy(ObdService obd) =>
      obd.status == ObdConnectionStatus.connecting || obd.status == ObdConnectionStatus.initializing;

  Widget _buildStatusCard(ObdService obd) {
    final Color tone;
    final String title;
    switch (obd.status) {
      case ObdConnectionStatus.connected:
        tone = AppTheme.ok;
        title = "Połączono z autem";
      case ObdConnectionStatus.connecting:
      case ObdConnectionStatus.initializing:
        tone = AppTheme.warn;
        title = "Łączenie…";
      case ObdConnectionStatus.error:
        tone = AppTheme.fault;
        title = "Błąd połączenia";
      case ObdConnectionStatus.disconnected:
        tone = AppTheme.textMuted;
        title = "Brak połączenia";
    }
    final v = obd.vehicleInfo;
    final connected = obd.status == ObdConnectionStatus.connected;

    TableRow row(String k, String val, {bool mono = false, Color? color}) => TableRow(children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, right: 12),
            child: Text(k, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(val,
                style: TextStyle(
                  color: color ?? AppTheme.textPrimary,
                  fontSize: 12.5,
                  fontFeatures: AppTheme.tabular,
                  fontFamily: mono ? "monospace" : null,
                )),
          ),
        ]);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(tone),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: AppTheme.sectionTitle)),
              if (_isBusy(obd))
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              if (connected) ...[
                if (v != null)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: "Odśwież dane pojazdu",
                    onPressed: () => obd.readVehicleInfo(),
                  ),
                IconButton(
                  icon: const Icon(Icons.link_off, size: 20),
                  tooltip: "Rozłącz",
                  onPressed: () => obd.disconnect(),
                ),
              ],
            ],
          ),
          if (!connected) ...[
            const SizedBox(height: 6),
            Text(
              obd.status == ObdConnectionStatus.disconnected
                  ? "Włącz zapłon, wepnij adapter w gniazdo OBD i wybierz sposób połączenia poniżej."
                  : obd.statusMessage,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
          if (connected) ...[
            const SizedBox(height: 10),
            Table(
              columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
              children: [
                if (v != null) ...[
                  row("Pojazd", "${v.manufacturer} ${v.modelName}${v.year.isNotEmpty ? ' • ${v.year}' : ''}"),
                  row("VIN", v.vin, mono: true),
                  row("Silnik", v.engineDescription),
                  row("Sterownik", "${v.calibrationId}${obd.engineEcuAddress != null ? ' • ${obd.engineEcuAddress}' : ''}"),
                  row("Napięcie", "${v.batteryVoltage.toStringAsFixed(1)} V"),
                  row(
                    "Od kasowania DTC",
                    "${v.distanceSinceDtcClearedKm} km${v.distanceWithMilOnKm > 0 ? ' • z kontrolką ${v.distanceWithMilOnKm} km' : ''}",
                    color: v.distanceSinceDtcClearedKm < 50 ? AppTheme.warn : null,
                  ),
                ],
                row("Adapter", (obd.stnId ?? "").startsWith("DX1") ? "Kostka Dynomic OBD (${obd.stnId})" : obd.stnId ?? obd.adapterId),
                if (obd.protocolName.isNotEmpty) row("Protokół", obd.protocolName.replaceFirst("AUTO, ", "")),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String description) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTheme.sectionTitle),
        const SizedBox(height: 4),
        Text(description, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildWifiSection(ObdService obd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader("Wi-Fi", "Połącz telefon z siecią adaptera (np. WiFi_OBDII) w ustawieniach Wi-Fi, potem naciśnij przycisk."),
        OutlinedButton.icon(
          onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectWifi()),
          icon: const Icon(Icons.wifi, size: 18),
          label: const Text("Połącz przez Wi-Fi"),
        ),
      ],
    );
  }

  Widget _buildClassicBluetoothSection(ObdService obd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          "Bluetooth — sparowane urządzenia",
          "vLinker MC (Android) i zwykłe ELM327. Najpierw sparuj adapter w ustawieniach Bluetooth telefonu.",
        ),
        if (_isLoadingClassic)
          const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
        else if (_classicError != null || _classicDevices.isEmpty)
          Panel(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _classicError ?? "Brak sparowanych urządzeń.",
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  ),
                ),
                IconButton(icon: const Icon(Icons.refresh), tooltip: "Odśwież listę", onPressed: _loadClassicDevices),
              ],
            ),
          )
        else
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (int i = 0; i < _classicDevices.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.bluetooth, size: 20),
                    title: Text(_classicDevices[i].name ?? "Nieznane urządzenie", style: const TextStyle(fontSize: 14)),
                    subtitle: Text(_classicDevices[i].address, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
                    trailing: ElevatedButton(
                      onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectClassic(_classicDevices[i])),
                      child: const Text("Połącz"),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBluetoothSection(ObdService obd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader("Bluetooth LE", "vLinker MC+ i inne adaptery BLE. Włącz zapłon i wyszukaj adapter."),
        ElevatedButton.icon(
          onPressed: obd.isScanning ? () => obd.stopScan() : () => _startScan(obd),
          icon: obd.isScanning
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.onAccent))
              : const Icon(Icons.bluetooth_searching, size: 18),
          label: Text(obd.isScanning ? "Zatrzymaj wyszukiwanie" : "Wyszukaj adapter"),
        ),
        if (_scanResults.isNotEmpty) ...[
          const SizedBox(height: 10),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (int i = 0; i < _scanResults.length; i++) ...[
                  if (i > 0) const Divider(),
                  Builder(builder: (context) {
                    final r = _scanResults[i];
                    final name = r.device.platformName.isNotEmpty ? r.device.platformName : "Nieznane urządzenie";
                    final lower = name.toLowerCase();
                    final likelyObd = lower.contains("vlinker") || lower.contains("obd") || lower.contains("v-link") || lower.contains("dynomic");
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.bluetooth, size: 20, color: likelyObd ? AppTheme.accent : AppTheme.textMuted),
                      title: Text(name, style: TextStyle(fontSize: 14, fontWeight: likelyObd ? FontWeight.w600 : FontWeight.normal)),
                      subtitle: Text(r.device.remoteId.str, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
                      trailing: likelyObd
                          ? ElevatedButton(
                              onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectDevice(r.device)),
                              child: const Text("Połącz"),
                            )
                          : OutlinedButton(
                              onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectDevice(r.device)),
                              child: const Text("Połącz"),
                            ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPidScannerSection(ObdService obd) {
    return Panel(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: const Text("Parametry udostępniane przez auto", style: TextStyle(fontSize: 14)),
        subtitle: Text(
          "${obd.discoveredPids.length} parametrów${obd.engineEcuAddress != null ? ' • sterownik ${obd.engineEcuAddress}' : ''}",
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final pid in obd.discoveredPids)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  ),
                  child: Text(pid.name, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDtcScannerSection(ObdService obd) {
    final codes = _scannedDtcCodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text("Kody usterek", style: AppTheme.sectionTitle)),
            if (codes != null)
              Text(codes.isEmpty ? "brak" : "${codes.length}",
                  style: TextStyle(color: codes.isEmpty ? AppTheme.ok : AppTheme.fault, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isLoadingDtc ? null : () => _readDtc(obd),
                icon: _isLoadingDtc
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.onAccent))
                    : const Icon(Icons.search, size: 18),
                label: const Text("Odczytaj kody"),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _isLoadingDtc ? null : () => _clearDtc(obd),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text("Skasuj"),
            ),
          ],
        ),
        if (obd.canScanVagModules) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _moduleScanProgress != null || _isLoadingDtc ? null : () => _scanVagModules(obd),
            icon: _moduleScanProgress != null
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.account_tree_outlined, size: 18),
            label: Text(_moduleScanProgress ?? "Skanuj wszystkie moduły (VAG)"),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LearningScreen())),
          icon: const Icon(Icons.hearing, size: 18),
          label: const Text("Nauka od testera (kabel Y)"),
        ),
        if (_moduleScanSummary != null) ...[
          const SizedBox(height: 10),
          Text(_moduleScanSummary!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
        ],
        if (_dtcReadFailed) ...[
          const SizedBox(height: 10),
          const Notice("Nie udało się odczytać pamięci usterek. Sprawdź połączenie i włącz zapłon.", tone: AppTheme.fault),
        ],
        if (codes != null) ...[
          const SizedBox(height: 10),
          if (codes.isEmpty)
            const Notice("Brak zapisanych i oczekujących kodów usterek.", tone: AppTheme.ok)
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (int i = 0; i < codes.length; i++) ...[
                    if (i > 0) const Divider(),
                    _dtcTile(codes[i]),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _dtcTile(DtcCode dtc) {
    final tone = dtc.pending ? AppTheme.warn : AppTheme.fault;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(dtc.code,
                  style: TextStyle(color: tone, fontFamily: "monospace", fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            Expanded(child: Text(dtc.title, style: const TextStyle(fontSize: 13.5))),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(left: 64, top: 2),
          child: Text(
            [
              if (dtc.ecuLabel != null) dtc.ecuLabel!,
              dtc.pending ? "oczekujący" : "zapisany",
            ].join(" • "),
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5),
          ),
        ),
        children: [
          Text("Obszar: ${dtc.category}", style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          const SizedBox(height: 4),
          Text(dtc.description, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
          if (dtc.commonCauses.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text("Najczęstsze przyczyny", style: AppTheme.label),
            const SizedBox(height: 4),
            for (final c in dtc.commonCauses)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text("• $c", style: const TextStyle(fontSize: 12.5)),
              ),
          ],
        ],
      ),
    );
  }
}
