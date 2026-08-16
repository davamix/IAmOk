import 'package:i_am_ok/domain/domain.dart';
import 'package:timezone/timezone.dart' as tz;

/// Zones used across the suite.
///
/// Chosen so the watched person's zone and the watcher's zone genuinely
/// disagree about what day it is — the case the design turns on and the one an
/// all-Madrid fixture set silently never exercises.
tz.Location get madrid => TimeZones.location('Europe/Madrid');

/// UTC-10, no DST. Nearly a day behind Madrid.
tz.Location get honolulu => TimeZones.location('Pacific/Honolulu');

/// UTC+12/+13. Nearly a day ahead of Madrid.
tz.Location get auckland => TimeZones.location('Pacific/Auckland');

/// UTC-5/-4, DST transitions on different dates from the EU.
tz.Location get newYork => TimeZones.location('America/New_York');

tz.Location get utc => TimeZones.utc;

/// A wall-clock instant in [zone], written the way a human would say it.
tz.TZDateTime at(
  tz.Location zone,
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) =>
    tz.TZDateTime(zone, year, month, day, hour, minute, second);

DayKey day(String iso) => DayKey.parse(iso);

Set<DayKey> days(Iterable<String> isos) => isos.map(DayKey.parse).toSet();
