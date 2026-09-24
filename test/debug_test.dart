import 'package:autocheck/services/simulator_service.dart'; import 'package:autocheck/services/anomaly_engine.dart'; void main() { final points = SimulatorService.generateFullRun(SimScenario.knockRetard); final anomalies = AnomalyEngine.analyzeSession(points); print('Found \$($anomalies.length) anomalies'); anomalies.forEach((a) => print(a.id)); }


