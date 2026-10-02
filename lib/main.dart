import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FuelApp());
}

// ==========================================
// 1. MODELE DANYCH (MODELS)
// ==========================================

/// Wpis w bazie tankowań
class RefuelEntry {
  final String id;
  final DateTime date;
  final double odometer; // Stan licznika w km
  final double fuelAmount; // Zatankowane litry

  RefuelEntry({
    required this.id,
    required this.date,
    required this.odometer,
    required this.fuelAmount,
  });
}

/// Główne tryby filtrowania
enum FilterMode {
  time, // Czas
  refuels, // Liczba tankowań
  distance, // Dystans
}

/// Opcje filtru Czasowego
enum TimeFilterOption {
  month, // Ostatni miesiąc (30 dni)
  months3, // Ostatnie 3 miesiące
  months6, // Ostatnie 6 miesięcy
  currentYear, // Bieżący rok
  all, // Wszystko
  custom, // Własny zakres (Kalendarz)
}

/// Opcje filtru Liczby Tankowań
enum RefuelsFilterOption {
  r1(1),
  r5(5),
  r10(10),
  r20(20);

  final int count;
  const RefuelsFilterOption(this.count);
}

/// Opcje filtru Dystansu (w km)
enum DistanceFilterOption {
  d500(500),
  d1000(1000),
  d5000(5000),
  d10000(10000),
  d20000(20000);

  final int kilometers;
  const DistanceFilterOption(this.kilometers);
}

/// Klasa przechowująca aktualny stan wybranego filtra
class FuelFilterState {
  final FilterMode mode;
  final TimeFilterOption timeOption;
  final RefuelsFilterOption refuelsOption;
  final DistanceFilterOption distanceOption;
  final DateTimeRange? customDateRange;

  FuelFilterState({
    this.mode = FilterMode.time,
    this.timeOption = TimeFilterOption.all,
    this.refuelsOption = RefuelsFilterOption.r5,
    this.distanceOption = DistanceFilterOption.d1000,
    this.customDateRange,
  });

  FuelFilterState copyWith({
    FilterMode? mode,
    TimeFilterOption? timeOption,
    RefuelsFilterOption? refuelsOption,
    DistanceFilterOption? distanceOption,
    DateTimeRange? customDateRange,
  }) {
    return FuelFilterState(
      mode: mode ?? this.mode,
      timeOption: timeOption ?? this.timeOption,
      refuelsOption: refuelsOption ?? this.refuelsOption,
      distanceOption: distanceOption ?? this.distanceOption,
      customDateRange: customDateRange ?? this.customDateRange,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'timeOption': timeOption.name,
      'refuelsOption': refuelsOption.name,
      'distanceOption': distanceOption.name,
      'customStartDate': customDateRange?.start.toIso8601String(),
      'customEndDate': customDateRange?.end.toIso8601String(),
    };
  }

  factory FuelFilterState.fromJson(Map<String, dynamic> json) {
    DateTimeRange? customRange;
    if (json['customStartDate'] != null && json['customEndDate'] != null) {
      customRange = DateTimeRange(
        start: DateTime.parse(json['customStartDate']),
        end: DateTime.parse(json['customEndDate']),
      );
    }

    return FuelFilterState(
      mode: FilterMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => FilterMode.time,
      ),
      timeOption: TimeFilterOption.values.firstWhere(
        (e) => e.name == json['timeOption'],
        orElse: () => TimeFilterOption.all,
      ),
      refuelsOption: RefuelsFilterOption.values.firstWhere(
        (e) => e.name == json['refuelsOption'],
        orElse: () => RefuelsFilterOption.r5,
      ),
      distanceOption: DistanceFilterOption.values.firstWhere(
        (e) => e.name == json['distanceOption'],
        orElse: () => DistanceFilterOption.d1000,
      ),
      customDateRange: customRange,
    );
  }
}

/// Wynik przeliczenia przekazywany do UI
class FilterResult {
  final List<RefuelEntry> filteredEntries;
  final double totalDistanceKm;
  final double totalFuelLiters;
  final double? averageConsumption;
  final DateTime? startDate;
  final DateTime? endDate;
  final int refuelCount;
  final bool hasInsufficientData;
  final String infoLabel;

  FilterResult({
    required this.filteredEntries,
    required this.totalDistanceKm,
    required this.totalFuelLiters,
    required this.averageConsumption,
    required this.startDate,
    required this.endDate,
    required this.refuelCount,
    required this.hasInsufficientData,
    required this.infoLabel,
  });
}

// ==========================================
// 2. PERSISTENCJA DANYCH (STORAGE)
// ==========================================

class FilterStorageService {
  static const String _key = 'fuel_filter_state_v1';

  static Future<void> saveFilterState(FuelFilterState state) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(state.toJson());
      await prefs.setString(_key, jsonString);
    } catch (e) {
      debugPrint('Błąd zapisu stanu filtra: $e');
    }
  }

  static Future<FuelFilterState> loadFilterState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_key);

      if (jsonString != null) {
        final Map<String, dynamic> jsonMap = jsonDecode(jsonString);
        return FuelFilterState.fromJson(jsonMap);
      }
    } catch (e) {
      debugPrint('Błąd odczytu stanu filtra: $e');
    }
    return FuelFilterState();
  }
}

// ==========================================
// 3. LOGIKA FILTRUJĄCA (SERVICE)
// ==========================================

class FuelFilterService {
  static FilterResult processEntries({
    required List<RefuelEntry> rawEntries,
    required FuelFilterState state,
  }) {
    if (rawEntries.length < 2) {
      return FilterResult(
        filteredEntries: rawEntries,
        totalDistanceKm: 0,
        totalFuelLiters: 0,
        averageConsumption: null,
        startDate: null,
        endDate: null,
        refuelCount: rawEntries.length,
        hasInsufficientData: true,
        infoLabel: 'Wymagane minimum 2 tankowania do obliczenia spalania.',
      );
    }

    // Sortowanie chronologiczne: od najstarszego do najnowszego
    final sorted = List<RefuelEntry>.from(rawEntries)
      ..sort((a, b) => a.date.compareTo(b.date));

    List<RefuelEntry> selectedEntries = [];
    bool isInsufficient = false;

    switch (state.mode) {
      case FilterMode.time:
        selectedEntries = _filterByTime(sorted, state, (val) => isInsufficient = val);
        break;
      case FilterMode.refuels:
        selectedEntries = _filterByRefuels(sorted, state.refuelsOption, (val) => isInsufficient = val);
        break;
      case FilterMode.distance:
        selectedEntries = _filterByDistance(sorted, state.distanceOption.kilometers, (val) => isInsufficient = val);
        break;
    }

    if (selectedEntries.length < 2) {
      return FilterResult(
        filteredEntries: selectedEntries,
        totalDistanceKm: 0,
        totalFuelLiters: 0,
        averageConsumption: null,
        startDate: selectedEntries.isNotEmpty ? selectedEntries.first.date : null,
        endDate: selectedEntries.isNotEmpty ? selectedEntries.last.date : null,
        refuelCount: selectedEntries.length,
        hasInsufficientData: true,
        infoLabel: 'Brak wystarczającej liczby tankowań w wybranym zakresie.',
      );
    }

    final firstEntry = selectedEntries.first;
    final lastEntry = selectedEntries.last;
    final totalDistance = lastEntry.odometer - firstEntry.odometer;

    // Sumujemy litry z wyłączeniem pierwszego tankowania (baza początkowa licznika)
    final totalFuel = selectedEntries
        .skip(1)
        .fold<double>(0.0, (sum, entry) => sum + entry.fuelAmount);

    final avgConsumption = totalDistance > 0 ? (totalFuel / totalDistance) * 100 : null;

    final String labelText = _generateInfoLabel(
      refuelCount: selectedEntries.length - 1,
      distanceKm: totalDistance,
      startDate: firstEntry.date,
      endDate: lastEntry.date,
      hasInsufficientData: isInsufficient,
    );

    return FilterResult(
      filteredEntries: selectedEntries,
      totalDistanceKm: totalDistance,
      totalFuelLiters: totalFuel,
      averageConsumption: avgConsumption,
      startDate: firstEntry.date,
      endDate: lastEntry.date,
      refuelCount: selectedEntries.length - 1,
      hasInsufficientData: isInsufficient,
      infoLabel: labelText,
    );
  }

  static List<RefuelEntry> _filterByTime(
    List<RefuelEntry> sorted,
    FuelFilterState state,
    Function(bool) setInsufficient,
  ) {
    final now = DateTime.now();

    if (state.timeOption == TimeFilterOption.all) {
      return sorted;
    }

    if (state.timeOption == TimeFilterOption.custom && state.customDateRange != null) {
      return sorted.where((e) =>
        e.date.isAfter(state.customDateRange!.start.subtract(const Duration(seconds: 1))) &&
        e.date.isBefore(state.customDateRange!.end.add(const Duration(days: 1)))
      ).toList();
    }

    DateTime cutOffDate;
    switch (state.timeOption) {
      case TimeFilterOption.month:
        cutOffDate = now.subtract(const Duration(days: 30));
        break;
      case TimeFilterOption.months3:
        cutOffDate = now.subtract(const Duration(days: 90));
        break;
      case TimeFilterOption.months6:
        cutOffDate = now.subtract(const Duration(days: 180));
        break;
      case TimeFilterOption.currentYear:
        cutOffDate = DateTime(now.year, 1, 1);
        break;
      default:
        return sorted;
    }

    final filtered = sorted.where((e) => e.date.isAfter(cutOffDate)).toList();

    if (filtered.length < sorted.length) {
      final indexOfFirstFiltered = sorted.indexOf(filtered.first);
      if (indexOfFirstFiltered > 0) {
        filtered.insert(0, sorted[indexOfFirstFiltered - 1]);
      }
    }

    return filtered;
  }

  static List<RefuelEntry> _filterByRefuels(
    List<RefuelEntry> sorted,
    RefuelsFilterOption option,
    Function(bool) setInsufficient,
  ) {
    final neededEntries = option.count + 1;

    if (sorted.length < neededEntries) {
      setInsufficient(true);
      return sorted;
    }

    return sorted.sublist(sorted.length - neededEntries);
  }

  static List<RefuelEntry> _filterByDistance(
    List<RefuelEntry> sorted,
    int targetKm,
    Function(bool) setInsufficient,
  ) {
    if (sorted.length < 2) return sorted;

    final latestOdometer = sorted.last.odometer;
    List<RefuelEntry> result = [sorted.last];

    for (int i = sorted.length - 2; i >= 0; i--) {
      result.add(sorted[i]);
      final currentDistance = latestOdometer - sorted[i].odometer;

      if (currentDistance >= targetKm) {
        return result.reversed.toList();
      }
    }

    setInsufficient(true);
    return sorted;
  }

  static String _generateInfoLabel({
    required int refuelCount,
    required double distanceKm,
    required DateTime startDate,
    required DateTime endDate,
    required bool hasInsufficientData,
  }) {
    final dateFormat = DateFormat('dd.MM.yyyy');
    final startStr = dateFormat.format(startDate);
    final endStr = dateFormat.format(endDate);
    final distanceStr = distanceKm.toStringAsFixed(0);

    String baseText = 'Obliczono z: $refuelCount tank. | $distanceStr km | $startStr – $endStr';

    if (hasInsufficientData) {
      return 'Brak pełnej historii – $baseText';
    }

    return baseText;
  }
}

// ==========================================
// 4. INTERFEJS UŻYTKOWNIKA (UI WIDGETS)
// ==========================================

class FuelApp extends StatelessWidget {
  const FuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Średnie Spalanie',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: StatsScreen(allEntries: _getMockData()),
    );
  }

  // Dane testowe zasilające aplikację
  List<RefuelEntry> _getMockData() {
    final now = DateTime.now();
    return [
      RefuelEntry(
        id: '1',
        date: now.subtract(const Duration(days: 120)),
        odometer: 145000,
        fuelAmount: 50.0,
      ),
      RefuelEntry(
        id: '2',
        date: now.subtract(const Duration(days: 90)),
        odometer: 145650,
        fuelAmount: 43.5,
      ),
      RefuelEntry(
        id: '3',
        date: now.subtract(const Duration(days: 60)),
        odometer: 146300,
        fuelAmount: 44.0,
      ),
      RefuelEntry(
        id: '4',
        date: now.subtract(const Duration(days: 35)),
        odometer: 146920,
        fuelAmount: 41.0,
      ),
      RefuelEntry(
        id: '5',
        date: now.subtract(const Duration(days: 14)),
        odometer: 147550,
        fuelAmount: 42.8,
      ),
      RefuelEntry(
        id: '6',
        date: now.subtract(const Duration(days: 2)),
        odometer: 148100,
        fuelAmount: 37.2,
      ),
    ];
  }
}

class StatsScreen extends StatefulWidget {
  final List<RefuelEntry> allEntries;

  const StatsScreen({super.key, required this.allEntries});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  FuelFilterState _filterState = FuelFilterState();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSavedFilterState();
  }

  Future<void> _loadSavedFilterState() async {
    final savedState = await FilterStorageService.loadFilterState();
    if (mounted) {
      setState(() {
        _filterState = savedState;
        _isLoading = false;
      });
    }
  }

  void _onFilterChanged(FuelFilterState newState) {
    setState(() {
      _filterState = newState;
    });
    FilterStorageService.saveFilterState(newState);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final filterResult = FuelFilterService.processEntries(
      rawEntries: widget.allEntries,
      state: _filterState,
    );

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statystyki Spalania'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Komponent wyboru filtrów
            FuelFilterWidget(
              filterState: _filterState,
              filterResult: filterResult,
              onFilterChanged: _onFilterChanged,
            ),

            const Divider(height: 24),

            // Główna sekcja z wynikiem
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const SizedBox(height: 20),
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.primaryContainer.withOpacity(0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24.0),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 32.0,
                          horizontal: 24.0,
                        ),
                        child: Column(
                          children: [
                            Text(
                              filterResult.averageConsumption != null
                                  ? '${filterResult.averageConsumption!.toStringAsFixed(2)} l/100km'
                                  : '---',
                              style: theme.textTheme.displayLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Średnie spalanie w wybranym okresie',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Szczegółowe zestawienie w wybranym podsumowaniu
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            icon: Icons.speed,
                            title: 'Dystans',
                            value: '${filterResult.totalDistanceKm.toStringAsFixed(0)} km',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _StatCard(
                            icon: Icons.local_gas_station,
                            title: 'Paliwo',
                            value: '${filterResult.totalFuelLiters.toStringAsFixed(1)} L',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _StatCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(title, style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 5. WIDŻET KOMPONENTU FILTROWANIA
// ==========================================

class FuelFilterWidget extends StatelessWidget {
  final FuelFilterState filterState;
  final FilterResult filterResult;
  final ValueChanged<FuelFilterState> onFilterChanged;

  const FuelFilterWidget({
    super.key,
    required this.filterState,
    required this.filterResult,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Główny Przełącznik (SegmentedButton)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: SegmentedButton<FilterMode>(
            segments: const [
              ButtonSegment<FilterMode>(
                value: FilterMode.time,
                label: Text('Czas'),
                icon: Icon(Icons.calendar_month_outlined),
              ),
              ButtonSegment<FilterMode>(
                value: FilterMode.refuels,
                label: Text('Tankowania'),
                icon: Icon(Icons.local_gas_station_outlined),
              ),
              ButtonSegment<FilterMode>(
                value: FilterMode.distance,
                label: Text('Dystans'),
                icon: Icon(Icons.add_road_outlined),
              ),
            ],
            selected: {filterState.mode},
            onSelectionChanged: (Set<FilterMode> newSelection) {
              onFilterChanged(filterState.copyWith(mode: newSelection.first));
            },
          ),
        ),

        // 2. Dynamiczne Pigułki (Chips)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Row(
            children: _buildOptionChips(context),
          ),
        ),

        const SizedBox(height: 6),

        // 3. Szara etykieta informacyjna
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: filterResult.hasInsufficientData
                  ? theme.colorScheme.errorContainer.withOpacity(0.4)
                  : theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8.0),
            ),
            child: Row(
              children: [
                Icon(
                  filterResult.hasInsufficientData
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline,
                  size: 16,
                  color: filterResult.hasInsufficientData
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    filterResult.infoLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: filterResult.hasInsufficientData
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildOptionChips(BuildContext context) {
    switch (filterState.mode) {
      case FilterMode.time:
        return _buildTimeChips(context);
      case FilterMode.refuels:
        return _buildRefuelsChips();
      case FilterMode.distance:
        return _buildDistanceChips();
    }
  }

  List<Widget> _buildTimeChips(BuildContext context) {
    final options = [
      (TimeFilterOption.month, 'Ostatni miesiąc'),
      (TimeFilterOption.months3, '3 miesiące'),
      (TimeFilterOption.months6, '6 miesięcy'),
      (TimeFilterOption.currentYear, 'Bieżący rok'),
      (TimeFilterOption.all, 'Wszystko'),
      (TimeFilterOption.custom, 'Własny zakres...'),
    ];

    return options.map((opt) {
      final isSelected = filterState.timeOption == opt.$1;
      return Padding(
        padding: const EdgeInsets.only(right: 8.0),
        child: ChoiceChip(
          label: Text(opt.$2),
          selected: isSelected,
          onSelected: (selected) async {
            if (!selected) return;

            if (opt.$1 == TimeFilterOption.custom) {
              final pickedRange = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime.now(),
                initialDateRange: filterState.customDateRange,
              );

              if (pickedRange != null) {
                onFilterChanged(filterState.copyWith(
                  timeOption: TimeFilterOption.custom,
                  customDateRange: pickedRange,
                ));
              }
            } else {
              onFilterChanged(filterState.copyWith(timeOption: opt.$1));
            }
          },
        ),
      );
    }).toList();
  }

  List<Widget> _buildRefuelsChips() {
    return RefuelsFilterOption.values.map((opt) {
      final isSelected = filterState.refuelsOption == opt;
      final label = opt == RefuelsFilterOption.r1
          ? 'Ostatnie 1 tankowanie'
          : 'Ostatnie ${opt.count} tankowań';

      return Padding(
        padding: const EdgeInsets.only(right: 8.0),
        child: ChoiceChip(
          label: Text(label),
          selected: isSelected,
          onSelected: (selected) {
            if (selected) {
              onFilterChanged(filterState.copyWith(refuelsOption: opt));
            }
          },
        ),
      );
    }).toList();
  }

  List<Widget> _buildDistanceChips() {
    return DistanceFilterOption.values.map((opt) {
      final isSelected = filterState.distanceOption == opt;
      return Padding(
        padding: const EdgeInsets.only(right: 8.0),
        child: ChoiceChip(
          label: Text('Ostatnie ${opt.kilometers} km'),
          selected: isSelected,
          onSelected: (selected) {
            if (selected) {
              onFilterChanged(filterState.copyWith(distanceOption: opt));
            }
          },
        ),
      );
    }).toList();
  }
}
