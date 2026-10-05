import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  runApp(const FuelApp());
}

enum FuelType {
  lpg('LPG', Colors.purple),
  pb('Benzyna (PB)', Colors.blue);

  const FuelType(this.label, this.color);
  final String label;
  final Color color;
}

class FuelEntry {
  final String id;
  final FuelType fuelType;
  final DateTime date;
  final double cost;
  final double liters;
  final double? odometer;
  final double? tripDistance;
  final bool isFullTank;
  double? singleConsumption; // Wyliczone chwilowe spalanie (L/100km)

  FuelEntry({
    required this.id,
    required this.fuelType,
    required this.date,
    required this.cost,
    required this.liters,
    this.odometer,
    this.tripDistance,
    required this.isFullTank,
    this.singleConsumption,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fuelType': fuelType.name,
        'date': date.toIso8601String(),
        'cost': cost,
        'liters': liters,
        'odometer': odometer,
        'tripDistance': tripDistance,
        'isFullTank': isFullTank,
        'singleConsumption': singleConsumption,
      };

  factory FuelEntry.fromJson(Map<String, dynamic> json) => FuelEntry(
        id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        fuelType: FuelType.values.firstWhere(
          (e) => e.name == json['fuelType'],
          orElse: () => FuelType.pb,
        ),
        date: DateTime.parse(json['date']),
        cost: (json['cost'] as num).toDouble(),
        liters: (json['liters'] as num).toDouble(),
        odometer: json['odometer'] != null ? (json['odometer'] as num).toDouble() : null,
        tripDistance: json['tripDistance'] != null ? (json['tripDistance'] as num).toDouble() : null,
        isFullTank: json['isFullTank'] ?? false,
        singleConsumption: json['singleConsumption'] != null ? (json['singleConsumption'] as num).toDouble() : null,
      );
}

class FuelApp extends StatelessWidget {
  const FuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fuel App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
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

class _HomeScreenState extends State<HomeScreen> {
  final ValueNotifier<List<FuelEntry>> _entriesNotifier = ValueNotifier([]);
  FuelType _selectedFilter = FuelType.lpg;
  
  // Speech to text
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _speechText = '';

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString('fuel_entries');
      if (jsonString != null) {
        final List<dynamic> decoded = jsonDecode(jsonString);
        final List<FuelEntry> loaded = decoded.map((item) => FuelEntry.fromJson(item)).toList();
        _recalculateConsumptions(loaded);
        _entriesNotifier.value = loaded;
      }
    } catch (e) {
      debugPrint('Błąd wczytywania danych: $e');
    }
  }

  Future<void> _saveEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(_entriesNotifier.value.map((e) => e.toJson()).toList());
      await prefs.setString('fuel_entries', encoded);
    } catch (e) {
      debugPrint('Błąd zapisu danych: $e');
    }
  }

  void _recalculateConsumptions(List<FuelEntry> entries) {
    for (var type in FuelType.values) {
      var typeEntries = entries.where((e) => e.fuelType == type).toList()
        ..sort((a, b) => a.date.compareTo(b.date)); // od najstarszego do najnowszego

      FuelEntry? lastFullTank;
      for (var entry in typeEntries) {
        double? distance = entry.tripDistance;
        if (distance == null && entry.odometer != null && lastFullTank != null && lastFullTank.odometer != null) {
          distance = entry.odometer! - lastFullTank.odometer!;
        }

        if (entry.isFullTank) {
          if (lastFullTank != null && distance != null && distance > 0) {
            double totalLitersBetween = 0;
            bool foundPrevious = false;
            for (var e in typeEntries) {
              if (e.date.isAfter(lastFullTank.date) && e.date.isBefore(entry.date) || e.id == entry.id) {
                totalLitersBetween += e.liters;
                if (e.id == entry.id) foundPrevious = true;
              }
            }
            if (foundPrevious) {
              entry.singleConsumption = (totalLitersBetween * 100) / distance;
            }
          }
          lastFullTank = entry;
        } else {
          if (distance != null && distance > 0) {
            entry.singleConsumption = (entry.liters * 100) / distance;
          } else {
            entry.singleConsumption = null;
          }
        }
      }
    }
  }

  void _addEntry(FuelEntry entry) {
    final currentList = List<FuelEntry>.from(_entriesNotifier.value);
    currentList.add(entry);
    _recalculateConsumptions(currentList);
    _entriesNotifier.value = currentList;
    _saveEntries();
  }

  void _deleteEntry(String id) {
    final currentList = List<FuelEntry>.from(_entriesNotifier.value);
    currentList.removeWhere((e) => e.id == id);
    _recalculateConsumptions(currentList);
    _entriesNotifier.value = currentList;
    _saveEntries();
  }

  double? _calculateConsumptionForList(List<FuelEntry> entries) {
    final filtered = entries.where((e) => e.fuelType == _selectedFilter && e.singleConsumption != null).toList();
    if (filtered.isEmpty) return null;
    double sum = filtered.fold(0.0, (prev, element) => prev + element.singleConsumption!);
    return sum / filtered.length;
  }

  // Eksport do pliku CSV
  Future<void> _exportToCsv() async {
    if (_entriesNotifier.value.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brak danych do wyeksportowania.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generowanie pliku CSV...')),
    );

    try {
      final buffer = StringBuffer();
      
      buffer.writeln('Typ Paliwa;Data;Dystans (km);Stan licznika (km);Koszt (PLN);Paliwo (L);Pełny bak?;Spalanie (L/100km)');

      final sortedEntries = List<FuelEntry>.from(_entriesNotifier.value)
        ..sort((a, b) => b.date.compareTo(a.date));

      for (var entry in sortedEntries) {
        final typeStr = entry.fuelType.label;
        final dateStr = '${entry.date.day.toString().padLeft(2, '0')}.${entry.date.month.toString().padLeft(2, '0')}.${entry.date.year}';
        final tripStr = entry.tripDistance != null ? entry.tripDistance.toString() : '-';
        final odoStr = entry.odometer != null ? entry.odometer.toString() : '-';
        final costStr = entry.cost.toStringAsFixed(2);
        final litersStr = entry.liters.toStringAsFixed(2);
        final fullTankStr = entry.isFullTank ? 'Tak' : 'Nie';
        final consStr = entry.singleConsumption != null ? entry.singleConsumption!.toStringAsFixed(2) : '-';

        buffer.writeln('$typeStr;$dateStr;$tripStr;$odoStr;$costStr;$litersStr;$fullTankStr;$consStr');
      }

      double totalCost = sortedEntries.fold(0.0, (sum, e) => sum + e.cost);
      double totalLiters = sortedEntries.fold(0.0, (sum, e) => sum + e.liters);
      double? avgCons = _calculateConsumptionForList(sortedEntries);

      buffer.writeln('PODSUMOWANIE;-;-;-;${totalCost.toStringAsFixed(2)};${totalLiters.toStringAsFixed(2)};-;${avgCons != null ? avgCons.toStringAsFixed(2) : '-'}');

      final directory = await getTemporaryDirectory();
      final dateStr = '${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}';
      final filePath = '${directory.path}/Raport_Paliwa_$dateStr.csv';
      
      final file = File(filePath);
      await file.writeAsString('\uFEFF${buffer.toString()}', encoding: utf8);

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      await Share.shareXFiles(
        [XFile(filePath)],
        subject: 'Raport CSV z aplikacji Fuel App',
        text: 'Plik CSV z historią tankowań.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd podczas eksportu do CSV: $e')),
      );
    }
  }

  // Import z pliku CSV
  Future<void> _importCsv() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final lines = await file.readAsLines(encoding: utf8);

        if (lines.isEmpty) return;

        List<FuelEntry> importedEntries = [];

        for (int i = 1; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.isEmpty) continue;
          
          if (line.startsWith('PODSUMOWANIE')) continue;

          final parts = line.split(';');
          if (parts.length >= 8) {
            try {
              FuelType type = parts[0].contains('LPG') ? FuelType.lpg : FuelType.pb;

              final dateParts = parts[1].split('.');
              DateTime date = DateTime.now();
              if (dateParts.length == 3) {
                int day = int.parse(dateParts[0]);
                int month = int.parse(dateParts[1]);
                int year = int.parse(dateParts[2]);
                date = DateTime(year, month, day);
              }

              double? trip = parts[2] == '-' ? null : double.tryParse(parts[2].replaceAll(',', '.'));
              double? odo = parts[3] == '-' ? null : double.tryParse(parts[3].replaceAll(',', '.'));

              double cost = double.parse(parts[4].replaceAll(',', '.'));
              double liters = double.parse(parts[5].replaceAll(',', '.'));
              bool isFull = parts[6] == 'Tak';

              importedEntries.add(FuelEntry(
                id: DateTime.now().millisecondsSinceEpoch.toString() + i.toString(),
                fuelType: type,
                date: date,
                cost: cost,
                liters: liters,
                odometer: odo,
                tripDistance: trip,
                isFullTank: isFull,
              ));
            } catch (e) {
              debugPrint('Błąd parsowania linii $i: $e');
            }
          }
        }

        if (importedEntries.isNotEmpty) {
          final currentList = List<FuelEntry>.from(_entriesNotifier.value);
          currentList.addAll(importedEntries);
          _recalculateConsumptions(currentList);
          _entriesNotifier.value = currentList;
          _saveEntries();

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Pomyślnie zaimportowano ${importedEntries.length} wpisów z CSV!')),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nie znaleziono poprawnych danych w pliku CSV.')),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd importu CSV: $e')),
      );
    }
  }

  // Eksport JSON (kopia zapasowa)
  Future<void> _exportJson() async {
    try {
      final jsonString = jsonEncode(_entriesNotifier.value.map((e) => e.toJson()).toList());
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/fuel_backup.json';
      final file = File(filePath);
      await file.writeAsString(jsonString);

      await Share.shareXFiles([XFile(filePath)], text: 'Kopia zapasowa danych paliwowych (JSON)');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd eksportu JSON: $e')),
      );
    }
  }

  // Import JSON
  Future<void> _importJson() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final jsonString = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(jsonString);
        final List<FuelEntry> loaded = decoded.map((item) => FuelEntry.fromJson(item)).toList();
        
        _recalculateConsumptions(loaded);
        _entriesNotifier.value = loaded;
        _saveEntries();

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pomyślnie zaimportowano dane z JSON!')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd importu JSON: $e')),
      );
    }
  }

  // Skanowanie paragonu przez OCR
  Future<void> _scanReceipt(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile == null) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Analizowanie paragonu...')),
    );

    try {
      final inputImage = InputImage.fromFilePath(pickedFile.path);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      await textRecognizer.close();

      double? detectedCost;
      double? detectedLiters;
      FuelType detectedType = FuelType.pb;

      for (TextBlock block in recognizedText.blocks) {
        for (TextLine line in block.lines) {
          String text = line.text.toUpperCase();
          if (text.contains('LPG') || text.contains('PROPANE')) {
            detectedType = FuelType.lpg;
          }
          if (text.contains('PB') || text.contains('BENZYNA') || text.contains('95') || text.contains('98')) {
            detectedType = FuelType.pb;
          }

          final RegExp regExp = RegExp(r'\d+[,\.]\d{2}');
          final matches = regExp.allMatches(text);
          for (var match in matches) {
            String valStr = match.group(0)!.replaceAll(',', '.');
            double? val = double.tryParse(valStr);
            if (val != null && val > 0) {
              if (text.contains('PLN') || text.contains('SUMA') || text.contains('ZŁ') || text.contains('TOTAL')) {
                detectedCost ??= val;
              } else if (text.contains('L') || text.contains('LTR') || text.contains('1')) {
                detectedLiters ??= val;
              }
            }
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      _showEntryFormDialog(
        initialCost: detectedCost,
        initialLiters: detectedLiters,
        initialType: detectedType,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd odczytu OCR: $e')),
      );
    }
  }

  // Rozpoznawanie mowy
  void _startVoiceInput() async {
    bool available = await _speech.initialize(
      onStatus: (status) => debugPrint('Status mowy: $status'),
      onError: (error) => debugPrint('Błąd mowy: $error'),
    );

    if (available) {
      setState(() => _isListening = true);
      _speech.listen(
        localeId: 'pl_PL',
        onResult: (result) {
          setState(() {
            _speechText = result.recognizedWords;
          });
          if (result.finalResult) {
            setState(() => _isListening = false);
            _parseVoiceText(_speechText);
          }
        },
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brak dostępu do rozpoznawania mowy.')),
      );
    }
  }

  void _parseVoiceText(String text) {
    double? cost;
    double? liters;
    FuelType type = FuelType.lpg;

    if (text.toLowerCase().contains('benzyna') || text.toLowerCase().contains('pb')) {
      type = FuelType.pb;
    }

    final words = text.split(' ');
    for (int i = 0; i < words.length; i++) {
      if (words[i].contains('zł') || words[i].contains('PLN') || words[i].contains('koszt')) {
        if (i > 0) {
          cost = double.tryParse(words[i - 1].replaceAll(',', '.'));
        }
      }
      if (words[i].contains('litr') || words[i].contains('l')) {
        if (i > 0) {
          liters = double.tryParse(words[i - 1].replaceAll(',', '.'));
        }
      }
    }

    _showEntryFormDialog(initialCost: cost, initialLiters: liters, initialType: type);
  }

  // Okno dialogowe dodawania/edycji wpisu
  void _showEntryFormDialog({double? initialCost, double? initialLiters, FuelType? initialType}) {
    final costController = TextEditingController(text: initialCost?.toString() ?? '');
    final litersController = TextEditingController(text: initialLiters?.toString() ?? '');
    final odoController = TextEditingController();
    final tripController = TextEditingController();
    FuelType selectedType = initialType ?? _selectedFilter;
    DateTime selectedDate = DateTime.now();
    bool isFullTank = true;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Nowe tankowanie'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<FuelType>(
                      value: selectedType,
                      items: FuelType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.label))).toList(),
                      onChanged: (val) => setStateDialog(() => selectedType = val!),
                      decoration: const InputDecoration(labelText: 'Typ paliwa'),
                    ),
                    TextField(
                      controller: costController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Koszt całkowity (PLN)'),
                    ),
                    TextField(
                      controller: litersController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Ilość litrów (L)'),
                    ),
                    TextField(
                      controller: odoController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Stan licznika (km - opcjonalnie)'),
                    ),
                    TextField(
                      controller: tripController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Dystans od ostatniego tankowania (km)'),
                    ),
                    SwitchListTile(
                      title: const Text('Pełny bak?'),
                      value: isFullTank,
                      onChanged: (val) => setStateDialog(() => isFullTank = val),
                    ),
                    Row(
                      children: [
                        Text('Data: ${selectedDate.day}.${selectedDate.month}.${selectedDate.year}'),
                        TextButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: selectedDate,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setStateDialog(() => selectedDate = picked);
                            }
                          },
                          child: const Text('Zmień'),
                        ),
                      ],
                    )
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Anuluj'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final cost = double.tryParse(costController.text.replaceAll(',', '.')) ?? 0;
                    final liters = double.tryParse(litersController.text.replaceAll(',', '.')) ?? 0;
                    final odo = double.tryParse(odoController.text.replaceAll(',', '.'));
                    final trip = double.tryParse(tripController.text.replaceAll(',', '.'));

                    if (cost <= 0 || liters <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Podaj poprawny koszt oraz litry.')),
                      );
                      return;
                    }

                    final newEntry = FuelEntry(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      fuelType: selectedType,
                      date: selectedDate,
                      cost: cost,
                      liters: liters,
                      odometer: odo,
                      tripDistance: trip,
                      isFullTank: isFullTank,
                    );

                    _addEntry(newEntry);
                    Navigator.pop(context);
                  },
                  child: const Text('Zapisz'),
                ),
              ],
            );
          },
        );
      },
    );
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
                leading: const Icon(Icons.mic, color: Colors.deepOrange),
                title: const Text('Głosowe wprowadzanie (Speech-to-Text)'),
                onTap: () {
                  Navigator.pop(context);
                  _startVoiceInput();
                },
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
                title: const Text('Importuj z JSON (Backup)'),
                onTap: () {
                  Navigator.pop(context);
                  _importJson();
                },
              ),
              ListTile(
                leading: const Icon(Icons.table_chart),
                title: const Text('Importuj z CSV (Raport)'),
                onTap: () {
                  Navigator.pop(context);
                  _importCsv();
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
        title: const Text('Fuel App (LPG / PB)'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'export_csv') {
                _exportToCsv();
              } else if (value == 'export_json') {
                _exportJson();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(
                value: 'export_csv',
                child: Text('Eksportuj do CSV (.csv)'),
              ),
              const PopupMenuItem(
                value: 'export_json',
                child: Text('Eksportuj kopia zapasowa (JSON)'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Wybór filtru paliwa
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SegmentedButton<FuelType>(
              segments: FuelType.values.map((t) => ButtonSegment<FuelType>(
                value: t,
                label: Text(t.label),
                icon: Icon(Icons.local_gas_station, color: t.color),
              )).toList(),
              selected: {_selectedFilter},
              onSelectionChanged: (Set<FuelType> newSelection) {
                setState(() => _selectedFilter = newSelection.first);
              },
            ),
          ),
          
          // Panel statystyk/średniego spalania
          ValueListenableBuilder<List<FuelEntry>>(
            valueListenable: _entriesNotifier,
            builder: (context, entries, _) {
              final avgConsumption = _calculateConsumptionForList(entries);
              final filteredCount = entries.where((e) => e.fuelType == _selectedFilter).length;
              
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          const Text('Średnie spalanie', style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 4),
                          Text(
                            avgConsumption != null ? '${avgConsumption.toStringAsFixed(2)} L/100km' : 'Brak danych',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          const Text('Tankowania', style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 4),
                          Text(
                            '$filteredCount',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // Nasłuchiwanie mowy (wskaźnik)
          if (_isListening)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.orange.shade100,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(width: 12),
                  Text('Słucham: $_speechText'),
                ],
              ),
            ),

          // Lista wpisów
          Expanded(
            child: ValueListenableBuilder<List<FuelEntry>>(
              valueListenable: _entriesNotifier,
              builder: (context, entries, _) {
                final filtered = entries.where((e) => e.fuelType == _selectedFilter).toList()
                  ..sort((a, b) => b.date.compareTo(a.date));

                if (filtered.isEmpty) {
                  const centerText = 'Brak wpisów dla wybranego paliwa.\nKliknij +, aby dodać pierwsze tankowanie.';
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Text(centerText, textAlign: TextAlign.center),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final entry = filtered[index];
                    final dateStr = '${entry.date.day}.${entry.date.month}.${entry.date.year}';
                    
                    return Dismissible(
                      key: Key(entry.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red,
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (direction) => _deleteEntry(entry.id),
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: entry.fuelType.color.withOpacity(0.2),
                            child: Icon(Icons.local_gas_station, color: entry.fuelType.color),
                          ),
                          title: Text('$dateStr - ${entry.cost.toStringAsFixed(2)} PLN'),
                          subtitle: Text(
                            'Ilość: ${entry.liters.toStringAsFixed(2)} L'
                            '${entry.tripDistance != null ? ' | Dystans: ${entry.tripDistance} km' : ''}'
                            '${entry.singleConsumption != null ? ' | ${entry.singleConsumption!.toStringAsFixed(2)} L/100km' : ''}'
                            '${entry.isFullTank ? ' (Pełny bak)' : ''}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.grey),
                            onPressed: () => _deleteEntry(entry.id),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddOptions,
        child: const Icon(Icons.add),
      ),
    );
  }
}
