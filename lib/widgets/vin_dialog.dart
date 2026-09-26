import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/vehicle_info.dart';
import '../models/vin_decoder.dart';
import '../services/vin_scan.dart';
import '../theme/app_theme.dart';

/// Okno wpisania lub zeskanowania numeru VIN. Zwraca poprawny VIN albo null.
Future<String?> showVinDialog(BuildContext context, {String initial = ""}) {
  return showDialog<String>(context: context, builder: (_) => _VinDialog(initial: initial));
}

/// Wielkie litery, tylko znaki VIN; O/Q → 0 i I → 1 (tych liter nie ma w VIN).
class _VinFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final t = VinDecoder.normalize(newValue.text).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final clipped = t.length > 17 ? t.substring(0, 17) : t;
    return TextEditingValue(text: clipped, selection: TextSelection.collapsed(offset: clipped.length));
  }
}

class _VinDialog extends StatefulWidget {
  final String initial;
  const _VinDialog({required this.initial});
  @override
  State<_VinDialog> createState() => _VinDialogState();
}

class _VinDialogState extends State<_VinDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);
  bool _scanning = false;
  String? _scanInfo;
  List<String> _candidates = const [];

  Future<void> _scan({bool gallery = false}) async {
    setState(() {
      _scanning = true;
      _scanInfo = null;
    });
    final r = await VinCameraScanner.scan(fromGallery: gallery);
    if (!mounted) return;
    setState(() {
      _scanning = false;
      if (r.vin != null) {
        _ctrl.text = r.vin!;
        _candidates = r.candidates.length > 1 ? r.candidates : const [];
        _scanInfo = "Odczytano z: ${r.source}. Porównaj z tabliczką/dowodem przed zapisem.";
      } else if (r.error != null) {
        _scanInfo = r.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vin = _ctrl.text;
    final valid = VinDecoder.isValid(vin);
    final info = valid ? VehicleInfo.decodeFromRawData(rawVin: vin) : null;
    return AlertDialog(
      title: const Text("Numer VIN", style: TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Sterownik nie podał VIN (częste w starszych autach). Wpisz go z dowodu rejestracyjnego (pole E) "
              "albo zrób zdjęcie tabliczki, szyby lub dowodu.",
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: widget.initial.isEmpty,
              inputFormatters: [_VinFormatter()],
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: "monospace", fontSize: 16, letterSpacing: 1.2),
              decoration: InputDecoration(
                labelText: "VIN (17 znaków)",
                counterText: "${vin.length}/17",
                errorText: vin.isNotEmpty && vin.length == 17 && !valid ? "Niepoprawny VIN" : null,
              ),
              onChanged: (_) => setState(() => _candidates = const []),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _scanning ? null : () => _scan(),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text("Aparat"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _scanning ? null : () => _scan(gallery: true),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text("Galeria"),
                  ),
                ),
              ],
            ),
            if (_scanning) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
            if (_scanInfo != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_scanInfo!, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              ),
            if (_candidates.isNotEmpty) ...[
              const SizedBox(height: 6),
              const Text("Inne możliwe odczyty:", style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              Wrap(
                spacing: 6,
                children: [
                  for (final c in _candidates)
                    ChoiceChip(
                      label: Text(c, style: const TextStyle(fontFamily: "monospace", fontSize: 12)),
                      selected: c == vin,
                      onSelected: (_) => setState(() => _ctrl.text = c),
                    ),
                ],
              ),
            ],
            if (info != null) ...[
              const SizedBox(height: 12),
              Text(info.label.split(" • ").first, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                [
                  if (info.year != "Nieokreślony") "rocznik ${info.year}",
                  if (info.engineDescription != "Dane silnika z ECU") info.engineDescription,
                ].join(" • "),
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Anuluj")),
        FilledButton(onPressed: valid ? () => Navigator.pop(context, vin) : null, child: const Text("Zapisz")),
      ],
    );
  }
}
