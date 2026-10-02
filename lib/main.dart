import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Automatyczny backup sprawdzany przy każdym uruchomieniu aplikacji[cite: 2]
  await _checkAndPerformMonthlyBackup();

  runApp(const FuelApp());
}

// --- AUTOMATYCZNY BACKUP RAZ W MIESIĄCU ---
Future<void> _checkAndPerformMonthlyBackup() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastBackupStr = prefs.getString('last_auto_backup');
    final now = DateTime.now();

    bool shouldBackup = false;
    if (lastBackupStr == null) {
      shouldBackup = true;
    } else {
      final lastBackup = DateTime.parse(lastBackupStr);
      if (now.difference(lastBackup).inDays >= 30) {
        shouldBackup = true;
      }
    }

    if (shouldBackup) {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/Dane_Tankowania.json');
      
      if (await file.exists()) {
        final backupDir = Directory('${directory.path}/backups');
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }

        final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final backupFile = File('${backupDir.path}/fuel_app_backup_$dateStr.json');
        
        await file.copy(backupFile.path);
        await prefs.setString('last_auto_backup', now.toIso8601String());
        debugPrint("Automatyczny miesięczny backup wykonany pomyślnie.");
      }
    }
  } catch (e) {
    debugPrint("Błąd automatycznego backupu: $e");
  }
}

enum FuelType { pb, lpg }

extension FuelTypeExtension on FuelType {
  String get label {
    switch (this) {
      case FuelType.pb:
        return 'Benzyna (PB)';
      case FuelType.lpg:
        return 'LPG';
    }
  }
}

class FuelEntry {
  final String id;
  final FuelType fuelType;
  final double cost;
  final double liters;
  final double? odometer;
  final double? tripDistance;
  final DateTime date;
  final bool isFullTank; // Nowe pole rozróżniające tankowanie do pełna i częściowe

  FuelEntry({
    String? id,
    required this.fuelType,
    required this.cost,
    required this.liters,
    this.odometer,
    this.tripDistance,
    DateTime? date,
    this.isFullTank = true, // Domyślnie każde tankowanie jest pełnym bakiem
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        date = date ?? DateTime.now();

  double get pricePerLiter => liters > 0 ? cost / liters : 0.0;

  double? get singleConsumption {
    if (tripDistance != null && tripDistance! > 0) {
      return (liters / tripDistance!) * 100;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fuelType': fuelType.name,
        'cost': cost,
        'liters': liters,
        'odometer': odometer,
        'tripDistance': tripDistance,
        'date': date.toIso8601String(),
        'isFullTank': isFullTank,
      };

  factory FuelEntry.fromJson(Map<String, dynamic> json) {
    return FuelEntry(
      id: json['id'] as String?,
      fuelType: FuelType.values.firstWhere(
        (e) => e.name == json['fuelType'],
        orElse: () => FuelType.lpg,
      ),
      cost: (json['cost'] as num).toDouble(),
      liters: (json['liters'] as num).toDouble(),
      odometer: json['odometer'] != null ? (json['odometer'] as num).toDouble() : null,
      tripDistance: json['tripDistance'] != null ? (json['tripDistance'] as num).toDouble() : null,
      date: DateTime.parse(json['date']),
      isFullTank: json['isFullTank'] as bool? ?? true, // Zabezpieczenie dla starych plików JSON
    );
  }
}

class FuelApp extends StatelessWidget {
  const FuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fuel App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  List<FuelEntry> _entries = [];
  bool _isScanning = false;
  bool _isLoading = true;
  DateTimeRange? _selectedDateRange;
  late TabController _tabController;

  FuelType _chartFuelType = FuelType.lpg;
  DateTimeRange? _chartDateRange;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 0);
    _loadEntriesFromFile();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<File> _getJsonFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/Dane_Tankowania.json');
  }

  Future<void> _loadEntriesFromFile() async {
    try {
      final file = await _getJsonFile();
      if (await file.exists()) {
        final String contents = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(contents);
        setState(() {
          _entries = jsonList.map((e) => FuelEntry.fromJson(e)).toList();
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint("Błąd wczytywania danych: $e");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveEntriesToFile() async {
    try {
      final file = await _getJsonFile();
      final List<Map<String, dynamic>> jsonList = _entries.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (e) {
      debugPrint("Błąd zapisu danych: $e");
    }
  }

  Future<void> _exportJson() async {
    try {
      final file = await _getJsonFile();
      if (!await file.exists() || _entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brak danych do wyeksportowania.')),
        );
        return;
      }
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Kopia zapasowa - Fuel App',
        text: 'Plik kopii zapasowej bazy danych JSON.',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd eksportu JSON: $e')),
      );
    }
  }

  Future<void> _importJson() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final contents = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(contents);
        final importedEntries = jsonList.map((e) => FuelEntry.fromJson(e)).toList();

        if(!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import danych (JSON)'),
            content: Text('Wczytano ${importedEntries.length} wpisów z pliku. Co chcesz zrobić?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
              ),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _entries = importedEntries;
                  });
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Zastąpiono bazę nowymi danymi.')),
                  );
                },
                child: const Text('Zastąp obecne'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    for (var entry in importedEntries) {
                      if (!_entries.any((e) => e.id == entry.id)) {
                        _entries.add(entry);
                      }
                    }
                  });
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Połączono dane pomyślnie.')),
                  );
                },
                child: const Text('Połącz (Scal)'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd podczas importu pliku: $e')),
      );
    }
  }

  Future<void> _importExcel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();
        final excel = Excel.decodeBytes(bytes);

        List<FuelEntry> importedEntries = [];

        for (var tableKey in excel.tables.keys) {
          final table = excel.tables[tableKey];
          if (table == null) continue;

          FuelType type = FuelType.lpg;
          if (tableKey.toUpperCase().contains('PB') || tableKey.toUpperCase().contains('BENZYNA')) {
            type = FuelType.pb;
          }

          for (int i = 1; i < table.rows.length; i++) {
            final row = table.rows[i];
            if (row.isEmpty || row[0] == null) continue;

            final firstCellVal = row[0]?.value?.toString() ?? '';
            if (firstCellVal.isEmpty || firstCellVal == 'PODSUMOWANIE' || firstCellVal == '-') {
              continue;
            }

            DateTime entryDate = DateTime.now();
            try {
              final parts = firstCellVal.split('.');
              if (parts.length == 3) {
                int day = int.parse(parts[0]);
                int month = int.parse(parts[1]);
                int year = int.parse(parts[2]);
                entryDate = DateTime(year, month, day);
              }
            } catch (_) {}

            double? tripDistance;
            if (row.length > 1 && row[1]?.value != null) {
              final valStr = row[1]!.value.toString();
              if (valStr != '-' && valStr.isNotEmpty) {
                tripDistance = double.tryParse(valStr.replaceAll(',', '.'));
              }
            }

            double? odometer;
            if (row.length > 2 && row[2]?.value != null) {
              final valStr = row[2]!.value.toString();
              if (valStr != '-' && valStr.isNotEmpty) {
                odometer = double.tryParse(valStr.replaceAll(',', '.'));
              }
            }

            double cost = 0.0;
            if (row.length > 3 && row[3]?.value != null) {
              final valStr = row[3]!.value.toString();
              cost = double.tryParse(valStr.replaceAll(',', '.')) ?? 0.0;
            }

            double liters = 0.0;
            if (row.length > 4 && row[4]?.value != null) {
              final valStr = row[4]!.value.toString();
              liters = double.tryParse(valStr.replaceAll(',', '.')) ?? 0.0;
            }

            // Domyślnie z Excela przyjmujemy tankowanie pełne
            if (cost > 0 && liters > 0) {
              importedEntries.add(FuelEntry(
                fuelType: type,
                cost: cost,
                liters: liters,
                odometer: odometer,
                tripDistance: tripDistance,
                date: entryDate,
                isFullTank: true,
              ));
            }
          }
        }

        if (importedEntries.isEmpty) {
          if(!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nie znaleziono poprawnych danych w pliku Excel.')),
          );
          return;
        }

        if(!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import danych z Excela'),
            content: Text('Wczytano ${importedEntries.length} wpisów z pliku Excel. Co chcesz zrobić?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
              ),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _entries = importedEntries;
                  });
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Zastąpiono bazę danymi z pliku Excel.')),
                  );
                },
                child: const Text('Zastąp obecne'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    for (var entry in importedEntries) {
                      bool exists = _entries.any((e) => 
                        e.date.year == entry.date.year &&
                        e.date.month == entry.date.month &&
                        e.date.day == entry.date.day &&
                        e.cost == entry.cost &&
                        e.liters == entry.liters
                      );
                      if (!exists) {
                        _entries.add(entry);
                      }
                    }
                  });
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Połączono dane z pliku Excel pomyślnie.')),
                  );
                },
                child: const Text('Połącz (Scal)'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd podczas importu pliku Excel: $e')),
      );
    }
  }

  List<FuelEntry> get _filteredEntries {
    List<FuelEntry> list = List.from(_entries);
    if (_selectedDateRange != null) {
      list = list.where((e) {
        return e.date.isAfter(_selectedDateRange!.start.subtract(const Duration(days: 1))) &&
               e.date.isBefore(_selectedDateRange!.end.add(const Duration(days: 1)));
      }).toList();
    }
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  List<FuelEntry> _entriesForType(FuelType type) {
    return _filteredEntries.where((e) => e.fuelType == type).toList();
  }

  double _totalCostFor(FuelType type) =>
      _entriesForType(type).fold(0.0, (sum, item) => sum + item.cost);

  double _totalLitersFor(FuelType type) =>
      _entriesForType(type).fold(0.0, (sum, item) => sum + item.liters);

  // --- INTELIGENTNA LOGIKA OBCZYSZCZANIA I CYKLI POMIAROWYCH ---
  double? _calculateConsumptionForList(List<FuelEntry> list) {
    if (list.isEmpty) return null;

    // 1. Jeśli wpisy posiadają wpisany dystans odcinka, używamy go priorytetowo
    double totalDistance = 0.0;
    double totalLitersUsed = 0.0;
    bool hasTrip = false;

    for (var entry in list) {
      if (entry.tripDistance != null && entry.tripDistance! > 0) {
        totalDistance += entry.tripDistance!;
        totalLitersUsed += entry.liters;
        hasTrip = true;
      }
    }

    if (hasTrip && totalDistance > 0 && totalLitersUsed > 0) {
      return (totalLitersUsed / totalDistance) * 100;
    }

    // 2. Obliczenia oparte o stan licznika (odometer) z uwzględnieniem cykli (pełny -> częściowe -> pełny)
    final listWithOdo = list.where((e) => e.odometer != null).toList()
      ..sort((a, b) => a.date.compareTo(b.date)); // od najstarszego do najnowszego

    if (listWithOdo.length < 2) return null;

    double cumulativeOdoDiff = 0.0;
    double cumulativeLiters = 0.0;
    int validCyclesCount = 0;

    int startIndex = 0;
    for (int i = 1; i < listWithOdo.length; i++) {
      // Zamknięcie cyklu następuje przy tankowaniu do pełna
      if (listWithOdo[i].isFullTank) {
        double odoDiff = listWithOdo[i].odometer! - listWithOdo[startIndex].odometer!;
        if (odoDiff > 0) {
          double litersInCycle = 0.0;
          for (int j = startIndex + 1; j <= i; j++) {
            litersInCycle += listWithOdo[j].liters;
          }
          cumulativeOdoDiff += odoDiff;
          cumulativeLiters += litersInCycle;
          validCyclesCount++;
        }
        startIndex = i;
      }
    }

    if (validCyclesCount > 0 && cumulativeOdoDiff > 0 && cumulativeLiters > 0) {
      return (cumulativeLiters / cumulativeOdoDiff) * 100;
    }

    // Fallback do metody liniowej (między skrajnymi licznikami)
    final newest = listWithOdo.last;
    final oldest = listWithOdo.first;
    double odoDiff = newest.odometer! - oldest.odometer!;
    if (odoDiff > 0) {
      double litersDrawn = 0.0;
      for (int i = 0; i < listWithOdo.length - 1; i++) {
        litersDrawn += listWithOdo[i].liters;
      }
      return (litersDrawn / odoDiff) * 100;
    }

    return null;
  }

  // Benzyna (PB): średnie spalanie z 5 ostatnich wpisów
  double? _pbAvgConsumption() {
    final list = _entriesForType(FuelType.pb);
    final sorted = List<FuelEntry>.from(list)..sort((a, b) => b.date.compareTo(a.date));
    final last5 = sorted.take(5).toList();
    return _calculateConsumptionForList(last5);
  }

  // LPG: średnie spalanie z ostatnich 6 miesięcy
  double? _lpgAvgConsumption() {
    final list = _entriesForType(FuelType.lpg);
    final now = DateTime.now();
    final sixMonthsAgo = DateTime(now.year, now.month - 6, now.day);
    final filtered = list.where((e) => e.date.isAfter(sixMonthsAgo) || e.date.isAtSameMomentAs(sixMonthsAgo)).toList();
    return _calculateConsumptionForList(filtered);
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _selectedDateRange,
    );
    if (picked != null) {
      setState(() => _selectedDateRange = picked);
    }
  }

  void _clearDateFilter() {
    setState(() => _selectedDateRange = null);
  }

  void _deleteEntry(FuelEntry entry) {
    final index = _entries.indexWhere((e) => e.id == entry.id);
    if (index == -1) return;

    setState(() {
      _entries.removeAt(index);
    });
    _saveEntriesToFile();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Usunięto wpis tankowania.'),
        action: SnackBarAction(
          label: 'COFNIJ',
          onPressed: () {
            setState(() {
              _entries.insert(index, entry);
            });
            _saveEntriesToFile();
          },
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _scanReceipt(ImageSource source) async {
    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: source);

    if (image == null) return;

    setState(() => _isScanning = true);

    final inputImage = InputImage.fromFilePath(image.path);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);

    final parsedData = _extractFuelData(recognizedText.text);

    await textRecognizer.close();
    setState(() => _isScanning = false);

    _showEntryFormDialog(
      initialCost: parsedData['cost'],
      initialLiters: parsedData['liters'],
      initialType: parsedData['detectedType'],
      initialDate: parsedData['date'],
    );
  }

  Map<String, dynamic> _extractFuelData(String text) {
    double? detectedLiters;
    double? detectedCost;
    FuelType detectedType = FuelType.lpg;
    DateTime? detectedDate;

    if (text.toUpperCase().contains('LPG') || text.toUpperCase().contains('AUTOGAZ')) {
      detectedType = FuelType.lpg;
    } else if (text.toUpperCase().contains('PB') || text.toUpperCase().contains('BENZYNA') || text.toUpperCase().contains('95') || text.toUpperCase().contains('98')) {
      detectedType = FuelType.pb;
    }

    final RegExp litersRegex = RegExp(r'(\d+[\.,]\d{1,2})\s*(l|litr|litry|ltr)\b', caseSensitive: false);
    final litersMatch = litersRegex.firstMatch(text);
    if (litersMatch != null) {
      String rawLiters = litersMatch.group(1)!.replaceAll(',', '.');
      detectedLiters = double.tryParse(rawLiters);
    }

    final RegExp costRegex = RegExp(r'(?:suma|razem|kwota)\s*[:=]?\s*(\d+[\.,]\d{2})', caseSensitive: false);
    final costMatch = costRegex.firstMatch(text);
    if (costMatch != null) {
      String rawCost = costMatch.group(1)!.replaceAll(',', '.');
      detectedCost = double.tryParse(rawCost);
    } else {
      final RegExp plnRegex = RegExp(r'(\d+[\.,]\d{2})\s*(?:pln|zł)', caseSensitive: false);
      final plnMatch = plnRegex.firstMatch(text);
      if (plnMatch != null) {
        String rawCost = plnMatch.group(1)!.replaceAll(',', '.');
        detectedCost = double.tryParse(rawCost);
      }
    }

    final regYMD = RegExp(r'\b(20\d{2})[-./](0[1-9]|1[0-2])[-./](0[1-9]|[12]\d|3[01])\b');
    final matchYMD = regYMD.firstMatch(text);

    if (matchYMD != null) {
      int year = int.parse(matchYMD.group(1)!);
      int month = int.parse(matchYMD.group(2)!);
      int day = int.parse(matchYMD.group(3)!);
      detectedDate = DateTime(year, month, day);
    } else {
      final regDMY = RegExp(r'\b(0[1-9]|[12]\d|3[01])[-./](0[1-9]|1[0-2])[-./](20\d{2})\b');
      final matchDMY = regDMY.firstMatch(text);
      if (matchDMY != null) {
        int day = int.parse(matchDMY.group(1)!);
        int month = int.parse(matchDMY.group(2)!);
        int year = int.parse(matchDMY.group(3)!);
        detectedDate = DateTime(year, month, day);
      }
    }

    return {
      'cost': detectedCost,
      'liters': detectedLiters,
      'detectedType': detectedType,
      'date': detectedDate,
    };
  }

  void _showEntryFormDialog({
    FuelEntry? entryToEdit,
    double? initialCost,
    double? initialLiters,
    FuelType? initialType,
    DateTime? initialDate,
  }) {
    final bool isEditing = entryToEdit != null;

    final costController = TextEditingController(
      text: isEditing ? entryToEdit.cost.toStringAsFixed(2) : initialCost?.toStringAsFixed(2) ?? '',
    );
    final litersController = TextEditingController(
      text: isEditing ? entryToEdit.liters.toStringAsFixed(2) : initialLiters?.toStringAsFixed(2) ?? '',
    );
    final tripController = TextEditingController(
      text: isEditing && entryToEdit.tripDistance != null ? entryToEdit.tripDistance!.toStringAsFixed(1) : '',
    );
    final odometerController = TextEditingController(
      text: isEditing && entryToEdit.odometer != null ? entryToEdit.odometer!.toStringAsFixed(0) : '',
    );
    
    FuelType selectedType = isEditing ? entryToEdit.fuelType : (initialType ?? FuelType.lpg);
    DateTime selectedDate = isEditing ? entryToEdit.date : (initialDate ?? DateTime.now());
    bool isFullTank = isEditing ? entryToEdit.isFullTank : true; // Nowy stan przełącznika

    final sortedEntries = List<FuelEntry>.from(_entries)..sort((a, b) => b.date.compareTo(a.date));
    final entriesWithOdo = sortedEntries.where((e) => e.odometer != null).toList();
    double? lastOdometer = entriesWithOdo.isNotEmpty ? entriesWithOdo.first.odometer : null;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edytuj wpis' : (initialCost != null ? 'Zweryfikuj dane' : 'Dodaj wpis')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isEditing && initialCost != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.orange),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Popraw wartości w polach, jeśli odczyt z paragonu zawiera błędy.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!isEditing && initialCost != null) const SizedBox(height: 16),

                SegmentedButton<FuelType>(
                  segments: const [
                    ButtonSegment(value: FuelType.lpg, label: Text('LPG'), icon: Icon(Icons.propane_tank)),
                    ButtonSegment(value: FuelType.pb, label: Text('PB'), icon: Icon(Icons.local_gas_station)),
                  ],
                  selected: {selectedType},
                  onSelectionChanged: (Set<FuelType> newSelection) {
                    setDialogState(() => selectedType = newSelection.first);
                  },
                ),
                const SizedBox(height: 12),
                
                OutlinedButton.icon(
                  onPressed: () async {
                    final pickedDate = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (pickedDate != null) {
                      setDialogState(() => selectedDate = pickedDate);
                    }
                  },
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text('Data: ${selectedDate.day}.${selectedDate.month}.${selectedDate.year}'),
                ),
                const SizedBox(height: 8),

                // Przełącznik tankowania do pełna / częściowego
                SwitchListTile(
                  title: const Text('Tankowanie do pełna', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    isFullTank ? 'Pełny bak (zamknięcie cyklu)' : 'Częściowe (dolewka / nie do pełna)',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  value: isFullTank,
                  onChanged: (bool value) {
                    setDialogState(() => isFullTank = value);
                  },
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),

                TextField(
                  controller: costController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Całkowity koszt (PLN)*', prefixIcon: Icon(Icons.attach_money)),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: litersController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Zatankowane litry (L)*', prefixIcon: Icon(Icons.opacity)),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const Text(
                  'Podaj jedno z poniższych, aby liczyć spalanie:',
                  style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: tripController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Dystans odcinka (km)',
                    hintText: 'np. 420 km',
                    prefixIcon: Icon(Icons.add_road),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: odometerController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Stan licznika (km)',
                    hintText: (!isEditing && lastOdometer != null) ? 'Ostatnio: ${lastOdometer.toStringAsFixed(0)} km' : 'np. 150000 km',
                    prefixIcon: const Icon(Icons.speed),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                double? cost = double.tryParse(costController.text.replaceAll(',', '.'));
                double? liters = double.tryParse(litersController.text.replaceAll(',', '.'));

                if (cost == null || liters == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Uzupełnij poprawnie Koszt i Litry!'))
                  );
                  return;
                }

                double? odo = odometerController.text.trim().isNotEmpty
                    ? double.tryParse(odometerController.text.replaceAll(',', '.'))
                    : null;

                double? trip = tripController.text.trim().isNotEmpty
                    ? double.tryParse(tripController.text.replaceAll(',', '.'))
                    : null;

                if (odo == null && trip != null && lastOdometer != null && !isEditing) {
                  odo = lastOdometer + trip;
                }

                if (trip == null && odo != null && lastOdometer != null && !isEditing && odo > lastOdometer) {
                  trip = odo - lastOdometer;
                }

                final newEntry = FuelEntry(
                  id: isEditing ? entryToEdit.id : null,
                  fuelType: selectedType,
                  cost: cost,
                  liters: liters,
                  odometer: odo,
                  tripDistance: trip,
                  date: selectedDate,
                  isFullTank: isFullTank, // Przekazanie stanu przełącznika
                );

                setState(() {
                  if (isEditing) {
                    final index = _entries.indexWhere((e) => e.id == entryToEdit.id);
                    if (index != -1) {
                      _entries[index] = newEntry;
                    }
                  } else {
                    _entries.add(newEntry);
                  }
                });
                _saveEntriesToFile();
                Navigator.pop(ctx);
              },
              child: const Text('Zatwierdź'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportToExcel() async {
    if (_filteredEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brak danych do wyeksportowania.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generowanie pliku Excel...')),
    );

    try {
      var excel = Excel.createExcel();

      void createSheetForType(String sheetName, FuelType type) {
        Sheet sheetObject = excel[sheetName];
        final list = _entriesForType(type); 

        sheetObject.appendRow([
          'Data',
          'Dystans (km)',
          'Stan licznika (km)',
          'Koszt (PLN)',
          'Paliwo (L)',
          'Pełny bak?',
          'Spalanie (L/100km)',
        ]);

        for (var entry in list) {
          sheetObject.appendRow([
            '${entry.date.day.toString().padLeft(2, '0')}.${entry.date.month.toString().padLeft(2, '0')}.${entry.date.year}',
            entry.tripDistance ?? '-',
            entry.odometer ?? '-',
            entry.cost,
            entry.liters,
            entry.isFullTank ? 'Tak' : 'Nie',
            entry.singleConsumption != null ? double.parse(entry.singleConsumption!.toStringAsFixed(2)) : '-',
          ]);
        }

        double totalCost = _totalCostFor(type);
        double totalLiters = _totalLitersFor(type);
        double? avgCons = type == FuelType.pb ? _pbAvgConsumption() : _lpgAvgConsumption();

        sheetObject.appendRow([]);
        sheetObject.appendRow([
          'PODSUMOWANIE',
          '-',
          '-',
          double.parse(totalCost.toStringAsFixed(2)),
          double.parse(totalLiters.toStringAsFixed(2)),
          '-',
          avgCons != null ? double.parse(avgCons.toStringAsFixed(2)) : '-',
        ]);
      }

      createSheetForType('LPG', FuelType.lpg);
      createSheetForType('Benzyna (PB)', FuelType.pb);

      excel.delete('Sheet1'); 

      final directory = await getTemporaryDirectory();
      final dateStr = '${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}';
      final filePath = '${directory.path}/Raport_Paliwa_$dateStr.xlsx';
      final fileBytes = excel.save();

      if (fileBytes != null) {
        File(filePath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileBytes);
        
        if(!mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        
        await Share.shareXFiles(
          [XFile(filePath)], 
          subject: 'Raport z aplikacji Fuel App',
          text: 'Rozdzielony raport zużycia paliwa LPG i PB z aplikacji.',
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd podczas eksportu: $e')),
      );
    }
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Dodaj nowe tankowanie',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Skanuj paragon (Aparat)'),
                onTap: () {
                  Navigator.pop(context);
                  _scanReceipt(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Wybierz paragon z galerii'),
                onTap: () {
                  Navigator.pop(context);
                  _scanReceipt(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Dodaj ręcznie'),
                onTap: () {
                  Navigator.pop(context);
                  _showEntryFormDialog();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.file_upload),
                title: const Text('Importuj z JSON'),
                onTap: () {
                  Navigator.pop(context);
                  _importJson();
                },
              ),
              ListTile(
                leading: const Icon(Icons.table_chart),
                title: const Text('Importuj z Excela (.xlsx)'),
                onTap: () {
                  Navigator.pop(context);
                  _importExcel();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fuel App - Zarządzanie paliwem'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'LPG', icon: Icon(Icons.propane_tank)),
            Tab(text: 'Benzyna (PB)', icon: Icon(Icons.local_gas_station)),
            Tab(text: 'Wykresy', icon: Icon(Icons.bar_chart)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: 'Filtruj daty',
            onPressed: _selectDateRange,
          ),
          if (_selectedDateRange != null)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Wyczyść filtr dat',
              onPressed: _clearDateFilter,
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'export_excel') {
                _exportToExcel();
              } else if (value == 'export_json') {
                _exportJson();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(
                value: 'export_excel',
                child: Text('Eksportuj do Excela (.xlsx)'),
              ),
              const PopupMenuItem(
                value: 'export_json',
                child: Text('Eksportuj kopia zapasowa (JSON)'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isScanning
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Skanowanie paragonu przez ML Kit...'),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildFuelTab(FuelType.lpg),
                    _buildFuelTab(FuelType.pb),
                    _buildChartsTab(),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddOptions,
        tooltip: 'Dodaj tankowanie',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildFuelTab(FuelType type) {
    final entries = _entriesForType(type);
    final avgConsumption = type == FuelType.pb ? _pbAvgConsumption() : _lpgAvgConsumption();
    final statTitle = type == FuelType.pb 
        ? 'Średnie spalanie (5 ostatnich wpisów)' 
        : 'Średnie spalanie (ostatnie 6 miesięcy)';

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.all(12),
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildStatItem(
                  statTitle,
                  avgConsumption != null ? '${avgConsumption.toStringAsFixed(2)} L/100km' : 'Brak danych',
                ),
              ],
            ),
          ),
        ),
        if (_selectedDateRange != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Filtr: ${_selectedDateRange!.start.day}.${_selectedDateRange!.start.month}.${_selectedDateRange!.start.year} - ${_selectedDateRange!.end.day}.${_selectedDateRange!.end.month}.${_selectedDateRange!.end.year}',
                  style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey),
                ),
                TextButton(
                  onPressed: _clearDateFilter,
                  child: const Text('Resetuj filtr', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'Brak wpisów dla ${type.label.toLowerCase()}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Dismissible(
                      key: Key(entry.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red,
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      confirmDismiss: (direction) async {
                        return await showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Potwierdzenie'),
                            content: const Text('Czy na pewno chcesz usunąć ten wpis?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Anuluj'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Usuń', style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        );
                      },
                      onDismissed: (direction) {
                        _deleteEntry(entry);
                      },
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: type == FuelType.lpg ? Colors.amber.shade700 : Colors.blue.shade700,
                            child: Icon(
                              type == FuelType.lpg ? Icons.propane_tank : Icons.local_gas_station,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            '${entry.cost.toStringAsFixed(2)} PLN (${entry.liters.toStringAsFixed(2)} L)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'Data: ${entry.date.day}.${entry.date.month}.${entry.date.year}'
                            '${!entry.isFullTank ? ' • [Nie do pełna]' : ''}' // Oznaczenie częściowego tankowania
                            '${entry.tripDistance != null ? ' • Dystans: ${entry.tripDistance} km' : ''}'
                            '${entry.odometer != null ? ' • Licznik: ${entry.odometer} km' : ''}'
                            '${entry.singleConsumption != null ? '\nSpalanie: ${entry.singleConsumption!.toStringAsFixed(2)} L/100km' : ''}',
                          ),
                          isThreeLine: entry.singleConsumption != null || entry.odometer != null || !entry.isFullTank,
                          trailing: IconButton(
                            icon: const Icon(Icons.edit, color: Colors.grey),
                            onPressed: () => _showEntryFormDialog(entryToEdit: entry),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --- ZAKŁADKA WYKRESU SPALANIA (MIESIĘCZNIE) ---
  Widget _buildChartsTab() {
    List<FuelEntry> chartEntries = _entries.where((e) => e.fuelType == _chartFuelType).toList();
    if (_chartDateRange != null) {
      chartEntries = chartEntries.where((e) {
        return e.date.isAfter(_chartDateRange!.start.subtract(const Duration(days: 1))) &&
               e.date.isBefore(_chartDateRange!.end.add(const Duration(days: 1)));
      }).toList();
    }

    final Map<String, List<FuelEntry>> monthlyGroups = {};
    for (var entry in chartEntries) {
      final monthKey = '${entry.date.year}-${entry.date.month.toString().padLeft(2, '0')}';
      monthlyGroups.putIfAbsent(monthKey, () => []).add(entry);
    }

    final Map<String, double> monthlyAverages = {};
    monthlyGroups.forEach((month, list) {
      final avg = _calculateConsumptionForList(list);
      if (avg != null) {
        monthlyAverages[month] = avg;
      }
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<FuelType>(
            segments: const [
              ButtonSegment(value: FuelType.lpg, label: Text('LPG'), icon: Icon(Icons.propane_tank)),
              ButtonSegment(value: FuelType.pb, label: Text('Benzyna (PB)'), icon: Icon(Icons.local_gas_station)),
            ],
            selected: {_chartFuelType},
            onSelectionChanged: (Set<FuelType> newSelection) {
              setState(() => _chartFuelType = newSelection.first);
            },
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                    initialDateRange: _chartDateRange,
                  );
                  if (picked != null) {
                    setState(() => _chartDateRange = picked);
                  }
                },
                icon: const Icon(Icons.date_range, size: 18),
                label: Text(_chartDateRange == null
                    ? 'Wybierz zakres dat'
                    : '${_chartDateRange!.start.day}.${_chartDateRange!.start.month}.${_chartDateRange!.start.year} - ${_chartDateRange!.end.day}.${_chartDateRange!.end.month}.${_chartDateRange!.end.year}'),
              ),
              if (_chartDateRange != null)
                TextButton(
                  onPressed: () => setState(() => _chartDateRange = null),
                  child: const Text('Resetuj zakres'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Średnie miesięczne spalanie (${_chartFuelType.label})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: monthlyAverages.isEmpty
                  ? const SizedBox(
                      height: 200,
                      child: Center(
                        child: Text(
                          'Brak wystarczających danych do wygenerowania wykresu.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : SizedBox(
                      height: 250,
                      child: CustomPaint(
                        painter: MonthlyChartPainter(monthlyAverages),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          if (monthlyAverages.isNotEmpty) ...[
            const Text(
              'Szczegóły miesięczne:',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...monthlyAverages.entries.map((entry) {
              final parts = entry.key.split('-');
              final yearMonthStr = '${parts[1]}.${parts[0]}';
              return ListTile(
                dense: true,
                title: Text('Miesiąc: $yearMonthStr'),
                trailing: Text(
                  '${entry.value.toStringAsFixed(2)} L/100km',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              );
            }),
          ]
        ],
      ),
    );
  }

  Widget _buildStatItem(String title, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

// --- CUSTOM PAINTER DLA WYKRESU SŁUPKOWEGO ---
class MonthlyChartPainter extends CustomPainter {
  final Map<String, double> monthlyData;

  MonthlyChartPainter(this.monthlyData);

  @override
  void paint(Canvas canvas, Size size) {
    if (monthlyData.isEmpty) return;

    final sortedKeys = monthlyData.keys.toList()..sort();
    final count = sortedKeys.length;
    if (count == 0) return;

    double maxVal = 0;
    for (var val in monthlyData.values) {
      if (val > maxVal) maxVal = val;
    }
    if (maxVal == 0) maxVal = 10;
    maxVal = maxVal * 1.25;

    final double chartWidth = size.width - 40;
    final double chartHeight = size.height - 40;
    final double barWidth = (chartWidth / count) * 0.55;
    final double spacing = (chartWidth / count) * 0.45;

    final paint = Paint()..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;

    canvas.drawLine(Offset(30, chartHeight), Offset(size.width - 10, chartHeight), axisPaint);

    for (int i = 0; i < count; i++) {
      final key = sortedKeys[i];
      final val = monthlyData[key] ?? 0.0;

      final double barHeight = (val / maxVal) * chartHeight;
      final double x = 35 + i * (barWidth + spacing);
      final double y = chartHeight - barHeight;

      paint.color = Colors.teal.shade400;
      final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), paint);

      final textSpanVal = TextSpan(
        text: val.toStringAsFixed(1),
        style: const TextStyle(fontSize: 10, color: Colors.black87),
      );
      final tpVal = TextPainter(text: textSpanVal, textDirection: TextDirection.ltr);
      tpVal.layout();
      tpVal.paint(canvas, Offset(x + (barWidth - tpVal.width) / 2, y - 14));

      final parts = key.split('-');
      final label = '${parts[1]}.${parts[0].substring(2)}';
      final textSpanLabel = TextSpan(
        text: label,
        style: const TextStyle(fontSize: 9, color: Colors.grey),
      );
      final tpLabel = TextPainter(text: textSpanLabel, textDirection: TextDirection.ltr);
      tpLabel.layout();
      tpLabel.paint(canvas, Offset(x + (barWidth - tpLabel.width) / 2, chartHeight + 6));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
