import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart' as fbs;
import 'package:provider/provider.dart';
import '../models/dtc_code.dart';
import '../models/vehicle_info.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';

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
      _showSnack("Brak uprawnień do skanowania Bluetooth", AppTheme.red);
      return;
    }

    setState(() => _scanResults = []);
    final error = await obd.startScan(onResults: (results) {
      if (mounted) setState(() => _scanResults = results);
    });
    if (error != null) _showSnack(error, AppTheme.red);
  }

  Future<void> _connect(Future<bool> Function() action) async {
    final ok = await action();
    if (!mounted) return;
    final obd = context.read<ObdService>();
    if (ok) {
      setState(() => _scannedDtcCodes = null);
    } else {
      _showSnack(obd.statusMessage, AppTheme.red);
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
        AppTheme.red,
      );
    }
  }

  void _showAdapterInfo(ObdService obd) {
    final info = obd.adapterInfo;
    final text = info.entries.map((e) => "${e.key}: ${e.value}").join("\n");
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text("Adapter i możliwości", style: TextStyle(color: AppTheme.textPrimary)),
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
              _showSnack("Skopiowano informacje o adapterze", AppTheme.green);
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
        backgroundColor: AppTheme.surface,
        title: const Text("Skasować kody błędów?", style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          "Zapłon musi być włączony, a silnik wyłączony. Skasowanie usuwa też dane "
          "gotowości (readiness) i zapisane zamrożone ramki — nie usuwa przyczyny usterki.",
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Anuluj")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Skasuj", style: TextStyle(color: AppTheme.red)),
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
      ok ? AppTheme.green : AppTheme.red,
    );
    if (ok) await _readDtc(obd);
  }

  @override
  Widget build(BuildContext context) {
    final obd = context.watch<ObdService>();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bluetooth_connected, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("AutoCheck - Połączenie OBD"),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Karta aktualnego statusu
            _buildStatusCard(obd),

            // Karta Identyfikacji Pojazdu z ECU (VIN, Rocznik, Silnik, Sterownik)
            if (obd.vehicleInfo != null) ...[
              const SizedBox(height: 20),
              _buildVehicleInfoCard(obd),
            ],

            const SizedBox(height: 20),

            
            // Sekcja vLinker / Wi-Fi
            _buildWifiSection(obd),

            const SizedBox(height: 24),

            // Sekcja Classic Bluetooth (Sparowane)
            _buildClassicBluetoothSection(obd),
            
            const SizedBox(height: 24),

            // Sekcja vLinker MC+ / Bluetooth
            _buildBluetoothSection(obd),

            const SizedBox(height: 24),

            // Sekcja Skanera Czujników Samochodu (ECU PID Discovery)
            _buildPidScannerSection(obd),

            const SizedBox(height: 24),

            // Sekcja Diagnostyki Błędów Silnika (DTC / Check Engine)
            _buildDtcScannerSection(obd),

          ],
        ),
      ),
    );
  }

  bool _isBusy(ObdService obd) =>
      obd.status == ObdConnectionStatus.connecting || obd.status == ObdConnectionStatus.initializing;

  Widget _buildStatusCard(ObdService obd) {
    Color badgeColor;
    IconData badgeIcon;

    switch (obd.status) {
      case ObdConnectionStatus.connected:
        badgeColor = AppTheme.green;
        badgeIcon = Icons.check_circle;
        break;
      case ObdConnectionStatus.connecting:
      case ObdConnectionStatus.initializing:
        badgeColor = AppTheme.yellow;
        badgeIcon = Icons.sync;
        break;
      case ObdConnectionStatus.error:
        badgeColor = AppTheme.red;
        badgeIcon = Icons.error;
        break;
      case ObdConnectionStatus.disconnected:
        badgeColor = AppTheme.textMuted;
        badgeIcon = Icons.power_off;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: badgeColor.withAlpha(120), width: 1.5),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: badgeColor.withAlpha(40),
            radius: 24,
            child: Icon(badgeIcon, color: badgeColor, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "STATUS POŁĄCZENIA",
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  obd.statusMessage,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (obd.status == ObdConnectionStatus.connected && obd.adapterId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    "Adapter: ${obd.stnId ?? obd.adapterId}${obd.protocolName.isNotEmpty ? ' • ${obd.protocolName}' : ''}",
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                  GestureDetector(
                    onTap: () => _showAdapterInfo(obd),
                    child: const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text("Szczegóły adaptera ›",
                          style: TextStyle(color: AppTheme.cyan, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (obd.status == ObdConnectionStatus.connected)
            IconButton(
              icon: const Icon(Icons.close, color: AppTheme.red),
              tooltip: "Rozłącz",
              onPressed: () => obd.disconnect(),
            ),
        ],
      ),
    );
  }

  Widget _buildWifiSection(ObdService obd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.wifi, color: AppTheme.green, size: 20),
            SizedBox(width: 8),
            Text(
              "Adapter ELM327 / vLinker (Wi-Fi)",
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          "Wejdź w ustawienia Wi-Fi telefonu, połącz się z siecią adaptera (np. WiFi_OBDII) i kliknij przycisk poniżej.",
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectWifi()),
          icon: const Icon(Icons.wifi_tethering),
          label: const Text("Połącz przez Wi-Fi"),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.green,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }

  Widget _buildClassicBluetoothSection(ObdService obd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.bluetooth_audio, color: AppTheme.blue, size: 20),
            SizedBox(width: 8),
            Text(
              "Starsze adaptery (Classic Bluetooth / Android)",
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          "Jeśli masz vLinker MC-Android lub zwykły ELM327 na starym Androidzie, najpierw sparuj go w ustawieniach systemu, a potem wybierz z listy poniżej.",
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (_isLoadingClassic)
          const CircularProgressIndicator()
        else if (_classicError != null || _classicDevices.isEmpty)
          Row(
            children: [
              Expanded(
                child: Text(
                  _classicError ?? "Brak sparowanych urządzeń. Sparuj adapter w ustawieniach Bluetooth telefonu.",
                  style: const TextStyle(color: AppTheme.red),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: AppTheme.cyan),
                tooltip: "Odśwież listę",
                onPressed: _loadClassicDevices,
              ),
            ],
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _classicDevices.length,
            itemBuilder: (context, index) {
              final d = _classicDevices[index];
              return Card(
                color: AppTheme.surfaceLight,
                child: ListTile(
                  leading: const Icon(Icons.bluetooth_connected, color: AppTheme.blue),
                  title: Text(d.name ?? "Nieznane urządzenie", style: const TextStyle(color: Colors.white)),
                  subtitle: Text(d.address, style: const TextStyle(color: AppTheme.textMuted)),
                  trailing: ElevatedButton(
                    onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectClassic(d)),
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.cyan, foregroundColor: Colors.black),
                    child: const Text("Połącz"),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildBluetoothSection(ObdService obd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.bluetooth, color: AppTheme.blue, size: 20),
            SizedBox(width: 8),
            Text(
              "Adapter vLinker MC+ (Bluetooth / BLE)",
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          "Włącz zapłon w samochodzie, wepnij vLinker MC+ do gniazda OBD-II i uruchom wyszukiwanie.",
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: obd.isScanning ? () => obd.stopScan() : () => _startScan(obd),
          icon: obd.isScanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.search),
          label: Text(obd.isScanning ? "Zatrzymaj szukanie" : "Wyszukaj adapter BLE (vLinker MC+)"),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.blue,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        if (_scanResults.isNotEmpty) ...[
          const SizedBox(height: 14),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _scanResults.length,
            itemBuilder: (context, index) {
              final r = _scanResults[index];
              final name = r.device.platformName.isNotEmpty ? r.device.platformName : "Nieznane urządzenie OBD";
              final isVlinker = name.toLowerCase().contains("vlinker") ||
                  name.toLowerCase().contains("obd") ||
                  name.toLowerCase().contains("v-link");

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: isVlinker ? AppTheme.blue.withAlpha(25) : AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isVlinker ? AppTheme.cyan : AppTheme.border,
                    width: isVlinker ? 1.5 : 1,
                  ),
                ),
                child: ListTile(
                  leading: Icon(
                    Icons.bluetooth,
                    color: isVlinker ? AppTheme.cyan : AppTheme.textMuted,
                  ),
                  title: Text(
                    name,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: isVlinker ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    r.device.remoteId.str,
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                  trailing: ElevatedButton(
                    onPressed: _isBusy(obd) ? null : () => _connect(() => obd.connectDevice(r.device)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isVlinker ? AppTheme.cyan : AppTheme.surfaceLight,
                      foregroundColor: isVlinker ? Colors.black : Colors.white,
                    ),
                    child: const Text("Połącz"),
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildPidScannerSection(ObdService obd) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.sensors, color: AppTheme.orange, size: 20),
                  SizedBox(width: 8),
                  Text(
                    "Czujniki Pojazdu (ECU)",
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.orange.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "${obd.discoveredPids.length} wykrytych",
                  style: const TextStyle(
                    color: AppTheme.orange,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            obd.status == ObdConnectionStatus.connected
                ? "Parametry, które zgłosił sterownik silnika${obd.engineEcuAddress != null ? ' (${obd.engineEcuAddress})' : ''} w masce obsługiwanych PID-ów. Tylko te są odpytywane podczas logowania."
                : "Po połączeniu AutoCheck odczyta maskę obsługiwanych PID-ów ze sterownika silnika i pokaże tylko te parametry, które auto faktycznie udostępnia.",
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: obd.discoveredPids.map((pid) {
              return Chip(
                backgroundColor: AppTheme.surfaceLight,
                side: const BorderSide(color: AppTheme.border),
                label: Text(
                  "${pid.shortName} (${pid.unit})",
                  style: TextStyle(
                    color: Color(pid.colorValue),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDtcScannerSection(ObdService obd) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.red.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.troubleshoot, color: AppTheme.red, size: 20),
                  SizedBox(width: 8),
                  Text(
                    "Odczyt Błędów Silnika (DTC)",
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (_scannedDtcCodes != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _scannedDtcCodes!.isEmpty
                        ? AppTheme.green.withAlpha(30)
                        : AppTheme.red.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    "${_scannedDtcCodes!.length} błędów",
                    style: TextStyle(
                      color: _scannedDtcCodes!.isEmpty ? AppTheme.green : AppTheme.red,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            "Odczytuje zarejestrowane błędy z pamięci komputera ECU (np. błąd ciśnienia paliwa P0087, wypadanie zapłonów P0301).",
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isLoadingDtc ? null : () => _readDtc(obd),
                  icon: _isLoadingDtc
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.search),
                  label: const Text("Odczytaj kody błędów"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _isLoadingDtc ? null : () => _clearDtc(obd),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text("Skasuj"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textMuted,
                  side: const BorderSide(color: AppTheme.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          if (obd.canScanVagModules) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _moduleScanProgress != null || _isLoadingDtc ? null : () => _scanVagModules(obd),
                icon: _moduleScanProgress != null
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.manage_search, size: 18),
                label: Text(_moduleScanProgress ?? "Skanuj wszystkie moduły (VAG)"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.cyan,
                  side: const BorderSide(color: AppTheme.cyan),
                ),
              ),
            ),
          ],
          if (_moduleScanSummary != null) ...[
            const SizedBox(height: 8),
            Text(_moduleScanSummary!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ],
          if (_dtcReadFailed) ...[
            const SizedBox(height: 12),
            const Text(
              "Nie udało się odczytać pamięci błędów. Sprawdź połączenie i włącz zapłon.",
              style: TextStyle(color: AppTheme.red, fontSize: 12),
            ),
          ],
          if (_scannedDtcCodes != null) ...[
            const SizedBox(height: 12),
            if (_scannedDtcCodes!.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.green.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.green.withAlpha(80)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: AppTheme.green, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Brak zapisanych i oczekujących kodów usterek w sterownikach.",
                        style: TextStyle(color: AppTheme.green, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _scannedDtcCodes!.length,
                itemBuilder: (context, idx) {
                  final dtc = _scannedDtcCodes![idx];
                  final accent = dtc.pending ? AppTheme.orange : AppTheme.red;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: accent.withAlpha(120)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                dtc.code,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  fontFamily: "monospace",
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                dtc.title,
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (dtc.ecuLabel != null || dtc.pending) ...[
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (dtc.ecuLabel != null) "Źródło: ${dtc.ecuLabel}",
                              if (dtc.pending) "OCZEKUJĄCY (wykryty w tym cyklu jazdy, niepotwierdzony)",
                            ].join("  •  "),
                            style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          "Obszar: ${dtc.category}",
                          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dtc.description,
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Prawdopodobne przyczyny usterki:",
                          style: TextStyle(color: AppTheme.cyan, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        ...dtc.commonCauses.map((c) => Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("• ", style: TextStyle(color: AppTheme.cyan, fontSize: 12)),
                                  Expanded(
                                    child: Text(c, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11)),
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildVehicleInfoCard(ObdService obd) {
    final VehicleInfo? v = obd.vehicleInfo;
    if (v == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cyan.withAlpha(140), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppTheme.cyan.withAlpha(20),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.cyan.withAlpha(35),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.directions_car, color: AppTheme.cyan, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${v.manufacturer} ${v.modelName}",
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Rocznik modelowy: ${v.year} • ${v.countryOfOrigin}",
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.sync, color: AppTheme.cyan, size: 22),
                tooltip: "Odśwież dane pojazdu z ECU (Mode 09)",
                onPressed: () => obd.readVehicleInfo(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: AppTheme.border),
          const SizedBox(height: 10),

          // Numer VIN
          _buildInfoRow(
            icon: Icons.fingerprint,
            label: "Numer VIN",
            value: v.vin,
            valueColor: AppTheme.cyan,
            isMonospace: true,
          ),
          const SizedBox(height: 8),

          // Silnik
          _buildInfoRow(
            icon: Icons.engineering,
            label: "Jednostka napędowa",
            value: v.engineDescription,
          ),
          if (v.fuelType != FuelType.unknown && !v.engineDescription.contains(v.fuelType.label)) ...[
            const SizedBox(height: 8),
            _buildInfoRow(icon: Icons.local_gas_station, label: "Paliwo", value: v.fuelType.label),
          ],
          const SizedBox(height: 8),

          // Sterownik ECU & CALID
          _buildInfoRow(
            icon: Icons.memory,
            label: "Sterownik silnika",
            value: "${v.ecuName}\nSoft (CALID): ${v.calibrationId}",
            valueColor: AppTheme.purple,
          ),
          const SizedBox(height: 8),

          // Napięcie i protokół OBD
          _buildInfoRow(
            icon: Icons.bolt,
            label: "Napięcie / Protokół",
            value: "${v.batteryVoltage.toStringAsFixed(1)} V  •  ${v.obdProtocol}",
            valueColor: AppTheme.green,
          ),
          const SizedBox(height: 8),

          // Dystans od kasowania błędów
          _buildInfoRow(
            icon: Icons.history,
            label: "Dystans od kasowania DTC",
            value: "${v.distanceSinceDtcClearedKm} km  ${v.distanceWithMilOnKm > 0 ? '(Z błędem: ${v.distanceWithMilOnKm} km)' : '(Brak aktywnego błędu MIL)'}",
            valueColor: v.distanceSinceDtcClearedKm < 50 ? AppTheme.orange : AppTheme.textSecondary,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
    bool isMonospace = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppTheme.textMuted),
        const SizedBox(width: 8),
        Text(
          "$label: ",
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor ?? AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: isMonospace ? 'monospace' : null,
              letterSpacing: isMonospace ? 1.0 : 0.0,
            ),
          ),
        ),
      ],
    );
  }
}
