/// How times are saved: as UTC, so a saved time names the same instant
/// after the device changes time zone. They are read back as local times,
/// so comparisons and calendar-day grouping (`DateTime(t.year, t.month,
/// t.day)`) work in the zone the device is in now.
///
/// Times saved before this have no zone, such as `2026-11-08T09:00:00.000`.
/// They are read as local time, as they always were, and saved in UTC from
/// the next save on.
library;

/// [time] as saved: UTC, ending in `Z`.
String savedTime(DateTime time) => time.toUtc().toIso8601String();

/// A saved time as a local time. Throws a [FormatException] when [value] is
/// not a time.
DateTime loadedTime(String value) => DateTime.parse(value).toLocal();

/// A saved time as a local time, or null when [value] is not a time.
DateTime? tryLoadedTime(String value) => DateTime.tryParse(value)?.toLocal();
