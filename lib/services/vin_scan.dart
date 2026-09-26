import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import '../models/vin_decoder.dart';

/// Wyciąganie numeru VIN z rozpoznanego tekstu (OCR) i kodów kreskowych.
///
/// VIN bywa na tabliczce znamionowej, pod szybą, na naklejce w słupku (często z kodem
/// kreskowym Code 39 / Data Matrix) i w dowodzie rejestracyjnym (pole E). OCR myli
/// podobne znaki, więc kandydaci są punktowani, a wynik zawsze trzeba potwierdzić.
class VinExtractor {
  /// Kandydaci na VIN z tekstu, od najbardziej prawdopodobnego.
  static List<String> fromText(String text) {
    final scores = <String, int>{};
    for (final line in text.toUpperCase().split(RegExp(r'[\r\n]+'))) {
      final compact = line.replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (compact.length < 17) continue;
      // Całe „słowa” o długości 17 znaków (VIN wydrukowany bez odstępów) są pewniejsze
      final tokens = line.split(RegExp(r'[^A-Z0-9]+')).where((t) => t.length == 17).toSet();
      final normalized = VinDecoder.normalize(compact);
      for (int i = 0; i + 17 <= normalized.length; i++) {
        final cand = normalized.substring(i, i + 17);
        if (!VinDecoder.isValid(cand)) continue;
        final raw = compact.substring(i, i + 17);
        final s = _score(cand, raw, tokens.contains(raw));
        if (s == null) continue;
        if ((scores[cand] ?? -1) < s) scores[cand] = s;
      }
    }
    final list = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in list) e.key];
  }

  /// VIN z zawartości kodu kreskowego (Code 39 na naklejkach bywa poprzedzony „I”).
  static String? fromBarcode(String raw) {
    var r = raw.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (r.length == 18 && r.startsWith('I')) r = r.substring(1);
    if (r.length != 17) {
      final c = fromText(raw);
      return c.isEmpty ? null : c.first;
    }
    final v = VinDecoder.normalize(r);
    return VinDecoder.isValid(v) ? v : null;
  }

  /// Punktacja kandydata; null = odrzucony.
  static int? _score(String vin, String raw, bool wholeToken) {
    final digits = vin.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digits < 4 || digits == 17) return null; // VIN ma litery (WMI) i sporo cyfr
    if (!RegExp(r'[A-Z]').hasMatch(vin.substring(0, 3))) return null;
    int s = 0;
    final info = VinDecoder.decode(vin);
    if (info.make != null) s += 4; // znany producent (WMI)
    if (VinDecoder.hasValidCheckDigit(vin)) s += 4;
    if (info.year != null) s += 1;
    if (RegExp(r'^[0-9]{4}$').hasMatch(vin.substring(13))) s += 2; // numer seryjny na końcu
    if (wholeToken) s += 3;
    if (raw == vin) s += 1; // bez poprawek O/Q/I
    return s;
  }
}

/// Wynik skanowania: najlepszy VIN i pozostali kandydaci do wyboru.
class VinScanResult {
  final String? vin;
  final List<String> candidates;
  final String source; // „kod kreskowy” / „tekst”
  final String? error;
  const VinScanResult({this.vin, this.candidates = const [], this.source = "", this.error});
}

/// Skanowanie VIN ze zdjęcia (aparat lub galeria): najpierw kody kreskowe, potem tekst.
/// Rozpoznawanie działa na telefonie, bez internetu (ML Kit).
class VinCameraScanner {
  static Future<VinScanResult> scan({bool fromGallery = false}) async {
    final XFile? photo;
    try {
      photo = await ImagePicker().pickImage(
        source: fromGallery ? ImageSource.gallery : ImageSource.camera,
        imageQuality: 95,
        maxWidth: 2400,
      );
    } catch (e) {
      return VinScanResult(error: "Nie udało się otworzyć aparatu: $e");
    }
    if (photo == null) return const VinScanResult(); // anulowano
    return scanFile(photo.path);
  }

  static Future<VinScanResult> scanFile(String path) async {
    final image = InputImage.fromFilePath(path);
    final barcodes = BarcodeScanner(formats: [
      BarcodeFormat.code39,
      BarcodeFormat.code128,
      BarcodeFormat.dataMatrix,
      BarcodeFormat.qrCode,
      BarcodeFormat.pdf417,
    ]);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      for (final b in await barcodes.processImage(image)) {
        final raw = b.rawValue;
        if (raw == null) continue;
        final vin = VinExtractor.fromBarcode(raw);
        if (vin != null) return VinScanResult(vin: vin, candidates: [vin], source: "kod kreskowy");
      }
      final text = await recognizer.processImage(image);
      final cands = VinExtractor.fromText(text.text);
      if (cands.isEmpty) {
        return const VinScanResult(error: "Nie znaleziono numeru VIN na zdjęciu. Zrób zdjęcie bliżej i prosto, w dobrym świetle.");
      }
      return VinScanResult(vin: cands.first, candidates: cands.take(4).toList(), source: "tekst");
    } catch (e) {
      return VinScanResult(error: "Błąd rozpoznawania: $e");
    } finally {
      await barcodes.close();
      await recognizer.close();
    }
  }
}
