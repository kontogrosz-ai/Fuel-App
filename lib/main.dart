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
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FuelApp());
}

// --- AUTOMATYCZNY BACKUP RAZ W MIESIĄCU ---
Future<void> _checkAndPerformMonthlyBackup() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastBackupString = prefs.getString('last_auto_backup');
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);

    DateTime? lastBackup;
    if (lastBackupString != null) {
      lastBackup = DateTime.tryParse(lastBackupString);
    }

    final shouldBackup = lastBackup == null ||
        DateTime(lastBackup.year, lastBackup.month).isBefore(currentMonth);
    if (!shouldBackup) return;

    final directory = await getApplicationDocumentsDirectory();
    final source = File('${directory.path}/Dane_Tankowania.json');

    if (await source.exists()) {
      final backupDirectory = Directory('${directory.path}/backups');
      await backupDirectory.create(recursive: true);
      final dateText =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await source.copy(
        '${backupDirectory.path}/fuel_app_backup_$dateText.json',
      );
      debugPrint('Automatyczny miesięczny backup wykonany pomyślnie.');
    }

    await prefs.setString('last_auto_backup', now.toIso8601String());
  } catch (error, stackTrace) {
    debugPrint('Błąd automatycznego backupu: $error');
    debugPrintStack(stackTrace: stackTrace);
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

// --- DEFINICJE MODELI I STANU FILTROWANIA ---
enum FilterMainMode { time, count, distance, custom }
enum TimeFilterOption { month1, months3, months6, year1, all }
enum CountFilterOption { c5, c10, c20, cAll }
enum DistanceFilterOption { km500, km1000, km5000, kmAll }

@immutable
class FuelFilterState {
  const FuelFilterState({
    this.mainMode = FilterMainMode.time,
    this.timeOption = TimeFilterOption.months6,
    this.countOption = CountFilterOption.c10,
    this.distanceOption = DistanceFilterOption.km1000,
    this.customDateRange,
  });

  final FilterMainMode mainMode;
  final TimeFilterOption timeOption;
  final CountFilterOption countOption;
  final DistanceFilterOption distanceOption;
  final DateTimeRange? customDateRange;

  FuelFilterState copyWith({
    FilterMainMode? mainMode,
    TimeFilterOption? timeOption,
    CountFilterOption? countOption,
    DistanceFilterOption? distanceOption,
    DateTimeRange? customDateRange,
  }) {
    return FuelFilterState(
      mainMode: mainMode ?? this.mainMode,
      timeOption: timeOption ?? this.timeOption,
      countOption: countOption ?? this.countOption,
      distanceOption: distanceOption ?? this.distanceOption,
      customDateRange: customDateRange ?? this.customDateRange,
    );
  }
}

class FilterResult {
  final List<FuelEntry> filteredEntries;
  final bool isDataLimited;
  final String infoMessage;

  FilterResult({
    required this.filteredEntries,
    required this.isDataLimited,
    required this.infoMessage,
  });
}

// --- ALGORYTM FILTRUJĄCY DANE ---
DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _subtractMonths(DateTime value, int months) {
  final firstDayOfTargetMonth = DateTime(value.year, value.month - months);
  final lastDay = DateTime(
    firstDayOfTargetMonth.year,
    firstDayOfTargetMonth.month + 1,
    0,
  ).day;
  final safeDay = value.day > lastDay ? lastDay : value.day;
  return DateTime(
    firstDayOfTargetMonth.year,
    firstDayOfTargetMonth.month,
    safeDay,
  );
}

FilterResult applyFuelFilter(
  List<FuelEntry> allEntries,
  FuelFilterState filterState,
) {
  final sorted = List<FuelEntry>.from(allEntries)
    ..sort((a, b) => b.date.compareTo(a.date));
  if (sorted.isEmpty) {
    return FilterResult(
      filteredEntries: const [],
      isDataLimited: false,
      infoMessage: 'Brak wpisów w bazie danych.',
    );
  }

  List<FuelEntry> result = [];
  String info = '';
  bool limited = false;

  switch (filterState.mainMode) {
    case FilterMainMode.time:
      final now = _dateOnly(DateTime.now());
      if (filterState.timeOption == TimeFilterOption.all) {
        result = sorted;
        info = 'Filtrowanie: Cała historia czasowa';
        break;
      }

      late DateTime cutoffDate;
      switch (filterState.timeOption) {
        case TimeFilterOption.month1:
          cutoffDate = _subtractMonths(now, 1);
          info = 'Filtrowanie: Ostatni miesiąc';
          break;
        case TimeFilterOption.months3:
          cutoffDate = _subtractMonths(now, 3);
          info = 'Filtrowanie: Ostatnie 3 miesiące';
          break;
        case TimeFilterOption.months6:
          cutoffDate = _subtractMonths(now, 6);
          info = 'Filtrowanie: Ostatnie 6 miesięcy';
          break;
        case TimeFilterOption.year1:
          cutoffDate = DateTime(now.year - 1, now.month, now.day);
          info = 'Filtrowanie: Ostatni rok';
          break;
        case TimeFilterOption.all:
          throw StateError('Opcja obsłużona wcześniej.');
      }
      result = sorted.where((entry) => !entry.date.isBefore(cutoffDate)).toList();
      break;

    case FilterMainMode.count:
      final targetCount = switch (filterState.countOption) {
        CountFilterOption.c5 => 5,
        CountFilterOption.c10 => 10,
        CountFilterOption.c20 => 20,
        CountFilterOption.cAll => sorted.length,
      };
      info = switch (filterState.countOption) {
        CountFilterOption.c5 => 'Ostatnie 5 tankowań',
        CountFilterOption.c10 => 'Ostatnie 10 tankowań',
        CountFilterOption.c20 => 'Ostatnie 20 tankowań',
        CountFilterOption.cAll => 'Wszystkie tankowania',
      };
      result = sorted.take(targetCount).toList();
      if (filterState.countOption != CountFilterOption.cAll &&
          sorted.length < targetCount) {
        limited = true;
        info +=
            ' (Dostępne tylko ${sorted.length} z żądanych $targetCount tankowań)';
      }
      break;

    case FilterMainMode.distance:
      final targetKm = switch (filterState.distanceOption) {
        DistanceFilterOption.km500 => 500.0,
        DistanceFilterOption.km1000 => 1000.0,
        DistanceFilterOption.km5000 => 5000.0,
        DistanceFilterOption.kmAll => double.infinity,
      };
      info = switch (filterState.distanceOption) {
        DistanceFilterOption.km500 => 'Ostatnie 500 km',
        DistanceFilterOption.km1000 => 'Ostatnie 1000 km',
        DistanceFilterOption.km5000 => 'Ostatnie 5000 km',
        DistanceFilterOption.kmAll => 'Cały dystans',
      };
      double accumulatedKm = 0;
      for (final entry in sorted) {
        result.add(entry);
        accumulatedKm += entry.tripDistance ?? 0;
        if (accumulatedKm >= targetKm) break;
      }
      if (targetKm.isFinite && accumulatedKm < targetKm) {
        limited = true;
        info +=
            ' (Osiągnięto maksymalny dostępny dystans: ${accumulatedKm.toStringAsFixed(0)} km)';
      }
      break;

    case FilterMainMode.custom:
      final range = filterState.customDateRange;
      if (range == null) {
        result = sorted;
        info = 'Własny zakres: Brak wybranego okresu';
        break;
      }
      final start = _dateOnly(range.start);
      final endExclusive = _dateOnly(range.end).add(const Duration(days: 1));
      result = sorted.where((entry) {
        return !entry.date.isBefore(start) && entry.date.isBefore(endExclusive);
      }).toList();
      info =
          'Zakres: ${start.
