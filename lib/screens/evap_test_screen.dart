import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/analysis/evap_test.dart';
import '../services/datalogger_service.dart';
import '../services/evap_test_runner.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';

/// Prowadzony test zaworu EVAP: porównanie biegu jałowego przed i po zaciśnięciu węża.
class EvapTestScreen extends StatefulWidget {
  const EvapTestScreen({super.key});
  @override
  State<EvapTestScreen> createState() => _EvapTestScreenState();
}

class _EvapTestScreenState extends State<EvapTestScreen> {
  late final EvapTestRunner _runner = EvapTestRunner(obd: context.read<ObdService>())..addListener(_onChange);
  bool _saved = false;

  void _onChange() {
    if (_runner.step == EvapStep.done && !_saved) {
      _saved = true;
      context.read<DataloggerService>().addSession(_runner.buildSession());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _runner.removeListener(_onChange);
    _runner.dispose();
    super.dispose();
  }

  bool get _busy => const {EvapStep.before, EvapStep.settle, EvapStep.after}.contains(_runner.step);

  @override
  Widget build(BuildContext context) {
    final logger = context.watch<DataloggerService>();
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _runner.cancel();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text("Test zaworu EVAP")),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _stepper(),
            const SizedBox(height: 12),
            ..._content(logger),
          ],
        ),
      ),
    );
  }

  Widget _stepper() {
    const labels = ["Przed", "Zaciśnij", "Po", "Wynik"];
    final idx = switch (_runner.step) {
      EvapStep.ready || EvapStep.before => 0,
      EvapStep.clamp || EvapStep.settle => 1,
      EvapStep.after => 2,
      _ => 3,
    };
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const Expanded(child: Divider()),
          Column(children: [
            StatusDot(i <= idx ? AppTheme.accent : AppTheme.border, size: 10),
            const SizedBox(height: 4),
            Text(labels[i], style: TextStyle(fontSize: 11.5, color: i <= idx ? AppTheme.textPrimary : AppTheme.textMuted)),
          ]),
        ],
      ],
    );
  }

  Widget _live() {
    final r = _runner;
    return Panel(
      child: Row(
        children: [
          Expanded(child: Readout(label: "Obroty", value: r.liveRpm?.toInt().toString() ?? "—", unit: "obr/min")),
          Expanded(
            child: Readout(
              label: "Korekty paliwa",
              value: r.liveTrim == null ? "—" : "${r.liveTrim! >= 0 ? '+' : ''}${r.liveTrim!.toStringAsFixed(1)}",
              unit: r.liveTrim == null ? "" : "%",
            ),
          ),
        ],
      ),
    );
  }

  Widget _progress(String text) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: AppTheme.body),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _runner.progress),
          const SizedBox(height: 4),
          Text("Odczytów: ${_runner.samplesInPhase}", style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          const SizedBox(height: 12),
          _live(),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _runner.cancel, child: const Text("Przerwij test")),
        ],
      );

  List<Widget> _content(DataloggerService logger) {
    final r = _runner;
    switch (r.step) {
      case EvapStep.ready:
      case EvapStep.cancelled:
        return [
          if (r.step == EvapStep.cancelled) const Notice("Test przerwany.", tone: AppTheme.warn),
          const Text("Kiedy robić ten test", style: AppTheme.sectionTitle),
          const SizedBox(height: 6),
          const Text(
            "Gdy silnik faluje lub gaśnie na wolnych obrotach (częste po tankowaniu). Test sprawdza, czy winny jest "
            "zawór EVAP — zawór, który wpuszcza opary paliwa z baku do silnika.",
            style: AppTheme.body,
          ),
          const SizedBox(height: 12),
          const Text("Przygotowanie", style: AppTheme.sectionTitle),
          const SizedBox(height: 6),
          const Text(
            "• Rozgrzany silnik, bieg jałowy, luz / P, hamulec ręczny.\n"
            "• Wyłączona klimatyzacja i dmuchawa na minimum.\n"
            "• Przygotuj szczypce do węży (zacisk) — w trakcie zaciśniesz wąż od zaworu EVAP do kolektora ssącego.\n"
            "• Nie dotykaj gazu przez cały test (ok. 1,5 min).",
            style: AppTheme.body,
          ),
          const SizedBox(height: 12),
          if (!r.canRun)
            const Notice("Połącz się z autem (ekran Połączenie), aby rozpocząć test.", tone: AppTheme.warn)
          else if (logger.isRecording)
            const Notice("Zatrzymaj nagrywanie w Rejestratorze — test sam zbiera dane.", tone: AppTheme.warn)
          else ...[
            if (!r.hasTrims)
              const Notice(
                "Sterownik nie podaje korekt paliwa — test oceni tylko falowanie obrotów.",
                tone: AppTheme.textSecondary,
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: r.start,
              icon: const Icon(Icons.play_arrow),
              label: const Text("Rozpocznij test"),
            ),
          ],
        ];
      case EvapStep.before:
        return [
          if (r.engineCold)
            const Notice("Silnik jest zimny (poniżej 70°C) — wynik może być niewiarygodny.", tone: AppTheme.warn),
          _progress("Krok 1 z 2: zapisuję normalną pracę na wolnych obrotach. Nie dotykaj gazu."),
        ];
      case EvapStep.clamp:
        return [
          const Text("Zaciśnij wąż zaworu EVAP", style: AppTheme.sectionTitle),
          const SizedBox(height: 6),
          const Text(
            "Zawór EVAP (zwykle mały elektrozawór z wtyczką, przy kolektorze ssącym lub przepustnicy) ma wąż "
            "biegnący do kolektora. Zaciśnij ten wąż szczypcami do węży albo zdejmij go i zaślep króciec kolektora.\n\n"
            "Samo odpięcie wtyczki nie wystarczy — zacięty zawór przepuszcza opary także bez prądu.",
            style: AppTheme.body,
          ),
          const SizedBox(height: 12),
          _live(),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: r.confirmClamped,
            icon: const Icon(Icons.check),
            label: const Text("Zacisnąłem wąż"),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: r.cancel, child: const Text("Przerwij test")),
        ];
      case EvapStep.settle:
        return [_progress("Czekam, aż silnik się ustabilizuje po zaciśnięciu węża…")];
      case EvapStep.after:
        return [_progress("Krok 2 z 2: zapisuję pracę z zaciśniętym wężem. Nie dotykaj gazu.")];
      case EvapStep.error:
        return [
          Notice(r.error ?? "Błąd testu.", tone: AppTheme.fault),
          const SizedBox(height: 12),
          FilledButton(onPressed: r.start, child: const Text("Spróbuj ponownie")),
        ];
      case EvapStep.done:
        final v = r.verdict!;
        final tone = switch (v.outcome) {
          EvapOutcome.faulty => AppTheme.fault,
          EvapOutcome.ok => AppTheme.ok,
          _ => AppTheme.warn,
        };
        return [
          const Notice("Zdejmij zacisk z węża EVAP!", tone: AppTheme.warn, icon: Icons.warning_amber),
          const SizedBox(height: 12),
          Panel(
            stripe: tone,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.title, style: TextStyle(color: tone, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(v.plainSummary, style: AppTheme.body),
                const SizedBox(height: 10),
                Text(v.comparison, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Wynik zapisano w Historii — jest w zakładce Diagnoza i w raporcie dla klienta.",
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text("Zakończ")),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () {
              setState(() => _saved = false);
              r.start();
            },
            child: const Text("Powtórz test"),
          ),
        ];
    }
  }
}
