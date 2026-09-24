/// Moduły (sterowniki) grupy VAG adresowane przez UDS na CAN 11-bit.
///
/// Adresy z tabeli „VAG UDS IDs” autorstwa Connora Howella
/// (github.com/ConnorHowell/vag-uds-ids, dane wyciągnięte z ODIS). Dotyczą aut
/// z modułami UDS (platformy MQB, MLB i nowsze). Starsze moduły (PQ, TP2.0 /
/// KWP2000) na te adresy nie odpowiadają.
class VagModule {
  final String name; // nazwa do wyświetlenia
  final String asamName; // nazwa z tabeli (skrót ASAM)
  final String requestId;
  final String responseId;

  const VagModule(this.name, this.asamName, this.requestId, this.responseId);

  static const List<VagModule> all = [
    VagModule("Czujniki parkowania", "ParkiAssis", "70A", "774"),
    VagModule("High Beam Assis", "HighBeamAssis", "730", "79A"),
    VagModule("High Beam Assis", "HighBeamAssis", "748", "7B2"),
    VagModule("Speci Funct2", "SpeciFunct2", "72B", "795"),
    VagModule("Silnik", "EnginContrModul1", "7E0", "7E8"),
    VagModule("Silnik 2", "EnginContrModul2", "7E2", "7EA"),
    VagModule("Skrzynia biegów", "TransContrModul", "7E1", "7E9"),
    VagModule("Napęd 4x4", "AllWheelContr", "70F", "779"),
    VagModule("Napęd 4x4", "AllWheelContr", "71D", "787"),
    VagModule("Zamki", "LockElect", "71E", "788"),
    VagModule("ABS / ESP", "Brake1", "713", "77D"),
    VagModule("Tempomat aktywny (ACC)", "AdaptCruisContr", "757", "7C1"),
    VagModule("Czujnik kąta skrętu", "SteerAngleSende", "751", "7BB"),
    VagModule("Amortyzatory elektroniczne", "WheelDampeElect", "772", "7DC"),
    VagModule("Ride Contr Syste", "RideContrSyste", "755", "7BF"),
    VagModule("Kessy (dostęp bezkluczykowy)", "Kessy", "732", "79C"),
    VagModule("Poduszki powietrzne", "Airba", "715", "77F"),
    VagModule("Immobilizer", "Immob", "711", "77B"),
    VagModule("Seat Adjus Passe Side", "SeatAdjusPasseSide", "74D", "7B7"),
    VagModule("Elektronika kolumny kierownicy", "SteerColumElect", "70C", "776"),
    VagModule("Szyberdach", "ElectRoofContr", "72D", "797"),
    VagModule("Zestaw wskaźników", "DashBoard", "714", "77E"),
    VagModule("Klimatyzacja", "AirCondi", "746", "7B0"),
    VagModule("Ogrzewanie postojowe", "AuxilParkiHeate", "76A", "7D4"),
    VagModule("Klimatyzacja tylna", "ClimaContrUnitRear", "71A", "784"),
    VagModule("Elektronika centralna", "CentrElect", "70E", "778"),
    VagModule("Gateway (magistrala)", "Gatew", "710", "77A"),
    VagModule("Activ Steer", "ActivSteer", "716", "780"),
    VagModule("Steer Colum Locki", "SteerColumLocki", "731", "79B"),
    VagModule("Vehic Posit Detec", "VehicPositDetec", "750", "7BA"),
    VagModule("Slidi Door Left", "SlidiDoorLeft", "733", "79D"),
    VagModule("Media Playe Posit1", "MediaPlayePosit1", "770", "7DA"),
    VagModule("Media Playe Posit3", "MediaPlayePosit3", "76E", "7D8"),
    VagModule("Air Condi Compr", "AirCondiCompr", "719", "783"),
    VagModule("Tacho", "Tacho", "771", "7DB"),
    VagModule("Silnik elektryczny", "DriveMotorContrModul", "7E6", "7EE"),
    VagModule("Regulacja akumulatora", "BatteRegul", "728", "792"),
    VagModule("Drzwi kierowcy", "DoorElectDriveSide", "74A", "7B4"),
    VagModule("Drzwi pasażera", "DoorElectPasseSide", "74B", "7B5"),
    VagModule("Hamulec postojowy (EPB)", "ParkiBrake", "752", "7BC"),
    VagModule("Wspomaganie kierownicy", "SteerAssis", "712", "77C"),
    VagModule("Regulacja reflektorów", "HeadlRegul", "754", "7BE"),
    VagModule("Kontrola ciśnienia opon", "TirePressMonit1", "70B", "775"),
    VagModule("Fotel kierowcy", "SeatAdjusDriveSide", "74C", "7B6"),
    VagModule("Moduł komfortu", "CentrModulComfoSyste", "70D", "777"),
    VagModule("Radio", "Radio", "718", "782"),
    VagModule("Nawigacja", "Navig", "76C", "7D6"),
    VagModule("Sound Syste", "SoundSyste", "76F", "7D9"),
    VagModule("TVTuner", "TVTuner", "76D", "7D7"),
    VagModule("Moduł przyczepy", "TrailFunct", "747", "7B1"),
    VagModule("Senso Elect", "SensoElect", "721", "78B"),
    VagModule("Asystent zmiany pasa", "LaneChangAssis", "74E", "7B8"),
    VagModule("Speci Funct", "SpeciFunct", "72C", "796"),
    VagModule("Infor Contr Unit1", "InforContrUnit1", "773", "7DD"),
    VagModule("Prete Front Right", "PreteFrontRight", "75F", "7C9"),
    VagModule("Ładowanie baterii (EV)", "BatteCharg", "765", "7CF"),
    VagModule("Sterowanie wybierakiem biegów", "GearShiftContrModul", "753", "7BD"),
    VagModule("Head Up Displ", "HeadUpDispl", "71B", "785"),
    VagModule("Night Visio", "NightVisio", "727", "791"),
    VagModule("Armre", "Armre", "739", "7A3"),
    VagModule("Telem", "Telem", "767", "7D1"),
    VagModule("On Board Camer", "OnBoardCamer", "726", "790"),
    VagModule("Telep", "Telep", "76B", "7D5"),
    VagModule("Slidi Door Right", "SlidiDoorRight", "734", "79E"),
    VagModule("Multi Conto Seat Drive Side", "MultiContoSeatDriveSide", "735", "79F"),
    VagModule("Multi Conto Seat Passe Side", "MultiContoSeatPasseSide", "736", "7A0"),
    VagModule("Multi Conto Seat Rear Drive Side", "MultiContoSeatRearDriveSide", "737", "7A1"),
    VagModule("Adapt Cruis Contr2", "AdaptCruisContr2", "756", "7C0"),
    VagModule("Kamera cofania", "CamerSysteRearView", "769", "7D3"),
    VagModule("Bateria wysokonapięciowa (BMS)", "BatteEnergContrModul", "7E5", "7ED"),
    VagModule("Deck Lid Contr Unit", "DeckLidContrUnit", "723", "78D"),
    VagModule("Multi Conto Seat Rear Passe Side", "MultiContoSeatRearPasseSide", "738", "7A2"),
    VagModule("Image Proce Elect", "ImageProceElect", "758", "7C2"),
    VagModule("Centr Modul Comfo Syste2", "CentrModulComfoSyste2", "745", "7AF"),
    VagModule("Prete Front Left", "PreteFrontLeft", "75E", "7C8"),
    VagModule("Kamera/radar asystentów", "FrontSensoDriveAssisSyste", "74F", "7B9"),
    VagModule("Micro Contr Unit", "MicroContrUnit", "763", "7CD"),
    VagModule("Infot Inter", "InfotInter", "749", "7B3"),
    VagModule("Elect Roof Contr2", "ElectRoofContr2", "73D", "7A7"),
    VagModule("Actua For Struc Borne Sound", "ActuaForStrucBorneSound", "71C", "786"),
    VagModule("Auxil Displ Contr Unit", "AuxilDisplContrUnit", "73C", "7A6"),
    VagModule("Wheel Brake Rear Right", "WheelBrakeRearRight", "720", "78A"),
    VagModule("Assem Mount", "AssemMount", "72E", "798"),
    VagModule("Wheel Brake Rear Left", "WheelBrakeRearLeft", "71F", "789"),
    VagModule("Door Elect Rear Drive Side", "DoorElectRearDriveSide", "73E", "7A8"),
    VagModule("Reduc Contr Modul", "ReducContrModul", "72A", "794"),
    VagModule("Door Elect Rear Passe Side", "DoorElectRearPasseSide", "73F", "7A9"),
    VagModule("Senso Brake Syste", "SensoBrakeSyste", "762", "7CC"),
  ];
}

/// Moduły VAG adresowane przez TP2.0 (KWP2000) — adresy logiczne jak w VCDS.
/// Dotyczy starszych platform (PQ: Golf V/VI, Passat B6/B7, Touran 1T, Octavia II,
/// Rapid, Fabia II/III…). Nazwy za jazdw/vag-blocks.
class VagTp20Module {
  final int address;
  final String name;
  const VagTp20Module(this.address, this.name);

  String get addressHex => address.toRadixString(16).padLeft(2, '0').toUpperCase();

  static const List<VagTp20Module> all = [
    VagTp20Module(0x01, "Silnik"),
    VagTp20Module(0x02, "Skrzynia biegów"),
    VagTp20Module(0x03, "ABS / ESP"),
    VagTp20Module(0x08, "Klimatyzacja / ogrzewanie"),
    VagTp20Module(0x09, "Elektronika centralna"),
    VagTp20Module(0x10, "Czujniki parkowania 2"),
    VagTp20Module(0x11, "Silnik 2"),
    VagTp20Module(0x13, "Tempomat aktywny (ACC)"),
    VagTp20Module(0x14, "Zawieszenie"),
    VagTp20Module(0x15, "Poduszki powietrzne"),
    VagTp20Module(0x16, "Elektronika kierownicy"),
    VagTp20Module(0x17, "Zestaw wskaźników"),
    VagTp20Module(0x18, "Ogrzewanie postojowe"),
    VagTp20Module(0x19, "Gateway (magistrala)"),
    VagTp20Module(0x22, "Napęd 4x4"),
    VagTp20Module(0x25, "Immobilizer"),
    VagTp20Module(0x36, "Fotel kierowcy"),
    VagTp20Module(0x37, "Radio / nawigacja"),
    VagTp20Module(0x42, "Drzwi kierowcy"),
    VagTp20Module(0x44, "Wspomaganie kierownicy"),
    VagTp20Module(0x46, "Moduł komfortu"),
    VagTp20Module(0x52, "Drzwi pasażera"),
    VagTp20Module(0x53, "Hamulec postojowy (EPB)"),
    VagTp20Module(0x55, "Regulacja reflektorów"),
    VagTp20Module(0x56, "Radio"),
    VagTp20Module(0x61, "Regulacja akumulatora"),
    VagTp20Module(0x62, "Drzwi tylne lewe"),
    VagTp20Module(0x65, "Kontrola ciśnienia opon"),
    VagTp20Module(0x72, "Drzwi tylne prawe"),
    VagTp20Module(0x76, "Czujniki parkowania"),
    VagTp20Module(0x77, "Telefon"),
  ];
}
