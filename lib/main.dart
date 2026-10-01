import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const FuelTrackerApp());
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
  final FuelType fuelType;
  final double cost;
  final double liters;
  final double? odometer;
  final double? tripDistance;
  final DateTime date;

  FuelEntry({
    required this.fuelType,
    required this.cost,
    required this.liters,
    this.odometer,
    this.tripDistance,
    DateTime? date,
  }) : date = date ?? DateTime.now();

  double get pricePerLiter => liters > 0 ? cost / liters : 0.0;

  double? get singleConsumption {
    if (tripDistance != null && tripDistance! > 0) {
      return (liters / tripDistance!) * 100;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'fuelType': fuelType.name,
        'cost': cost,
        'liters': liters,
        'odometer': odometer,
        'tripDistance': tripDistance,
        'date': date.toIso8601String(),
      };

  factory FuelEntry.fromJson(Map<String, dynamic> json) {
    return FuelEntry(
      fuelType: FuelType.values.firstWhere(
        (e) => e.name == json['fuelType'],
        orElse: () => FuelType.lpg,
      ),
      cost: (json['cost'] as num).toDouble(),
      liters: (json['liters'] as num).toDouble(),
      odometer: json['odometer'] != null ? (json['odometer'] as num).toDouble() : null,
      tripDistance: json['tripDistance'] != null ? (json['tripDistance'] as num).toDouble() : null,
      date: DateTime.parse(json['date']),
    );
  }
}

class FuelTrackerApp extends StatelessWidget {
  const FuelTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tanker App',
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this, initialIndex: 1);
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
      final List<Map<String, dynamic>> jsonList =
          _entries.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (e) {
      debugPrint("Błąd zapisu danych: $e");
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
    list.sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  List<FuelEntry> _entriesForType(FuelType type) {
    return _filteredEntries.where((e) => e.fuelType == type).toList();
  }

  double _totalCostFor(FuelType type) =>
      _entriesForType(type).fold(0.0, (sum, item) => sum + item.cost);

  double _totalLitersFor(FuelType type) =>
      _entriesForType(type).fold(0.0, (sum, item) => sum + item.liters);

  double? _calculatedAvgConsumptionFor(FuelType type) {
    final list = _entriesForType(type);
    if (list.isEmpty) return null;

    double totalDistance = 0.0;
    double totalLitersUsed = 0.0;

    for (var entry in list) {
      if (entry.tripDistance != null && entry.tripDistance! > 0) {
        totalDistance += entry.tripDistance!;
        totalLitersUsed += entry.liters;
      }
    }

    if (totalDistance > 0 && totalLitersUsed > 0) {
      return (totalLitersUsed / totalDistance) * 100;
    }

    final listWithOdo = list.where((e) => e.odometer != null).toList();
    if (listWithOdo.length >= 2) {
      final first = listWithOdo.first;
      final last = listWithOdo.last;
      double odoDiff = last.odometer! - first.odometer!;

      if (odoDiff > 0) {
        double litersDrawn = 0.0;
        for (int i = 1; i < listWithOdo.length; i++) {
          litersDrawn += listWithOdo[i].liters;
        }
        return (litersDrawn / odoDiff) * 100;
      }
    }

    return null;
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

  Future<void> _scanReceipt() async {
    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera);

    if (image == null) return;

    setState(() => _isScanning = true);

    final inputImage = InputImage.fromFilePath(image.path);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);

    final parsedData = _extractFuelData(recognizedText.text);

    await textRecognizer.close();
    setState(() => _isScanning = false);

    _showConfirmationDialog(
      parsedData['cost'],
      parsedData['liters'],
      parsedData['detectedType'],
      parsedData['date'],
    );
  }

  Map<String, dynamic> _extractFuelData(String text) {
    double? detectedLiters;
    FuelType detectedType = FuelType.lpg;
    DateTime? detectedDate;

    // 1. Detekcja typu paliwa
    if (text.toUpperCase().contains('LPG') || text.toUpperCase().contains('AUTOGAZ')) {
      detectedType = FuelType.lpg;
    } else if (text.toUpperCase().contains('PB') || text.toUpperCase().contains('BENZYNA') || text.toUpperCase().contains('95') || text.toUpperCase().contains('98')) {
      detectedType = FuelType.pb;
    }

    // 2. Detekcja ilości litrów
    final RegExp litersRegex = RegExp(r'(\d+[\.,]\d{1,2})\s*(l|litr|litry|ltr)\b', caseSensitive: false);
    final litersMatch = litersRegex.firstMatch(text);
    if (litersMatch != null) {
      String rawLiters = litersMatch.group(1)!.replaceAll(',', '.');
      detectedLiters = double.tryParse(rawLiters);
    }

    // 3. Detekcja daty transakcji (YYYY-MM-DD lub DD.MM.YYYY lub YYYY/MM/DD itp.)
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
      'cost': null,
      'liters': detectedLiters,
      'detectedType': detectedType,
      'date': detectedDate,
    };
  }

  void _showConfirmationDialog(double? initialCost, double? initialLiters, FuelType? initialType, DateTime? initialDate) {
    final costController = TextEditingController(text: initialCost?.toStringAsFixed(2) ?? '');
    final litersController = TextEditingController(text: initialLiters?.toStringAsFixed(2) ?? '');
    
    FuelType selectedType = initialType ?? FuelType.lpg;
    DateTime selectedDate = initialDate ?? DateTime.now();

    final entriesWithOdo = _entries.where((e) => e.odometer != null).toList();
    double? lastOdometer = entriesWithOdo.isNotEmpty ? entriesWithOdo.last.odometer : null;

    final odometerController = TextEditingController();
    final tripController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Dane tankowania'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<FuelType>(
                  segments: const [
                    ButtonSegment(value: FuelType.pb, label: Text('Benzyna PB'), icon: Icon(Icons.local_gas_station)),
                    ButtonSegment(value: FuelType.lpg, label: Text('LPG'), icon: Icon(Icons.propane_tank)),
                  ],
                  selected: {selectedType},
                  onSelectionChanged: (Set<FuelType> newSelection) {
                    setDialogState(() => selectedType = newSelection.first);
                  },
                ),
                const SizedBox(height: 12),
                
                // Przycisk wyboru/potwierdzenia daty
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

                TextField(
                  controller: costController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Koszt (PLN)*', prefixIcon: Icon(Icons.attach_money)),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: litersController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Paliwo (Litry)*', prefixIcon: Icon(Icons.opacity)),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Wypełnij jedno z poniższych pól (drugie wyliczy się automatycznie):',
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
                    hintText: lastOdometer != null ? 'Ostatnio: ${lastOdometer.toStringAsFixed(0)} km' : 'np. 150000 km',
                    prefixIcon: const Icon(Icons.speed),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
            ElevatedButton(
              onPressed: () {
                double? cost = double.tryParse(costController.text.replaceAll(',', '.'));
                double? liters = double.tryParse(litersController.text.replaceAll(',', '.'));

                double? odo = odometerController.text.trim().isNotEmpty
                    ? double.tryParse(odometerController.text.replaceAll(',', '.'))
                    : null;

                double? trip = tripController.text.trim().isNotEmpty
                    ? double.tryParse(tripController.text.replaceAll(',', '.'))
                    : null;

                if (odo == null && trip != null && lastOdometer != null) {
                  odo = lastOdometer + trip;
                }

                if (trip == null && odo != null && lastOdometer != null && odo > lastOdometer) {
                  trip = odo - lastOdometer;
                }

                if (cost != null && liters != null) {
                  setState(() {
                    _entries.add(FuelEntry(
                      fuelType: selectedType,
                      cost: cost,
                      liters: liters,
                      odometer: odo,
                      tripDistance: trip,
                      date: selectedDate,
                    ));
                  });
                  _saveEntriesToFile();
                }
                Navigator.pop(ctx);
              },
              child: const Text('Zapisz'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportToExcel() async {
    if (_filteredEntries.isEmpty) return;

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
        'Spalanie (L/100km)',
      ]);

      for (var entry in list) {
        sheetObject.appendRow([
          '${entry.date.day}.${entry.date.month}.${entry.date.year}',
          entry.tripDistance ?? '-',
          entry.odometer ?? '-',
          entry.cost,
          entry.liters,
          entry.singleConsumption != null ? double.parse(entry.singleConsumption!.toStringAsFixed(2)) : '-',
        ]);
      }

      double totalCost = _totalCostFor(type);
      double totalLiters = _totalLitersFor(type);
      double? avgCons = _calculatedAvgConsumptionFor(type);

      sheetObject.appendRow([]);
      sheetObject.appendRow([
        'PODSUMOWANIE',
        '-',
        '-',
        double.parse(totalCost.toStringAsFixed(2)),
        double.parse(totalLiters.toStringAsFixed(2)),
        avgCons != null ? double.parse(avgCons.toStringAsFixed(2)) : '-',
      ]);
    }

    createSheetForType('Benzyna (PB)', FuelType.pb);
    createSheetForType('LPG', FuelType.lpg);

    excel.delete('Sheet1');

    final directory = await getTemporaryDirectory();
    final filePath = '${directory.path}/raport_paliwa_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final fileBytes = excel.save();

    if (fileBytes != null) {
      File(filePath)..createSync(recursive: true)..writeAsBytesSync(fileBytes);
      await Share.shareXFiles([XFile(filePath)], text: 'Rozdzielony raport paliwa PB i LPG');
    }
  }

  Widget _buildFuelTab(FuelType type) {
    final list = _entriesForType(type);
    final totalCost = _totalCostFor(type);
    final totalLiters = _totalLitersFor(type);
    final avgConsumption = _calculatedAvgConsumptionFor(type);

    final color = type == FuelType.pb ? Colors.teal : Colors.orange;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.shade200),
          ),
          child: Column(
            children: [
              Text('ŚREDNIE SPALANIE (${type.label.toUpperCase()})',
                  style: TextStyle(fontSize: 12, color: color.shade900, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                avgConsumption != null ? '${avgConsumption.toStringAsFixed(2)} l/100km' : '--',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: avgConsumption != null ? color.shade900 : Colors.grey,
                ),
              ),
              if (avgConsumption == null)
                const Text('(podaj dystans lub stan licznika)', style: TextStyle(fontSize: 11, color: Colors.grey)),
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text('Koszt łączny', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text('${totalCost.toStringAsFixed(2)} zł', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Column(
                    children: [
                      const Text('Paliwo łącznie', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text('${totalLiters.toStringAsFixed(2)} L', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              )
            ],
          ),
        ),

        Expanded(
          child: list.isEmpty
              ? Center(child: Text('Brak wpisów dla ${type.label}.'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (ctx, index) {
                    final entry = list[index];
                    final singleCons = entry.singleConsumption;

                    String detailsText = '';
                    if (entry.tripDistance != null) {
                      detailsText += 'Trasa: ${entry.tripDistance!.toStringAsFixed(1)} km  ';
                    }
                    if (entry.odometer != null) {
                      detailsText += '• Licznik: ${entry.odometer!.toStringAsFixed(0)} km';
                    }
                    if (detailsText.isEmpty) {
                      detailsText = 'Brak danych przebiegu';
                    }

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: color.shade100,
                        child: Icon(type == FuelType.pb ? Icons.local_gas_station : Icons.propane_tank, color: color.shade900),
                      ),
                      title: Text('${entry.liters.toStringAsFixed(2)} L — ${entry.cost.toStringAsFixed(2)} zł'),
                      subtitle: Text(detailsText),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${entry.date.day}.${entry.date.month}.${entry.date.year}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          if (singleCons != null)
                            Text(
                              '${singleCons.toStringAsFixed(1)} l/100km',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color.shade900),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tanker App'),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: 'Filtruj okres',
            onPressed: _selectDateRange,
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'Eksportuj do Excela',
            onPressed: _exportToExcel,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.local_gas_station), text: 'Benzyna (PB)'),
            Tab(icon: Icon(Icons.propane_tank), text: 'LPG'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isScanning
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (_selectedDateRange != null)
                      Container(
                        color: Colors.amber.shade100,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Okres: ${_selectedDateRange!.start.day}.${_selectedDateRange!.start.month} - ${_selectedDateRange!.end.day}.${_selectedDateRange!.end.month}.${_selectedDateRange!.end.year}',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            InkWell(
                              onTap: _clearDateFilter,
                              child: const Icon(Icons.close, size: 20),
                            )
                          ],
                        ),
                      ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildFuelTab(FuelType.pb),
                          _buildFuelTab(FuelType.lpg),
                        ],
                      ),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanReceipt,
        icon: const Icon(Icons.camera_alt),
        label: const Text('Zeskanuj paragon'),
      ),
    );
  }
}
