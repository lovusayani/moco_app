/// Compact relative-time labels for chat timestamps. No `intl` dependency —
/// the format needed here is small and fixed enough not to justify one.
String formatRelativeTime(DateTime? time) {
  if (time == null) return '';
  final now = DateTime.now();
  final diff = now.difference(time);

  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';

  final sameYear = time.year == now.year;
  final month = _months[time.month - 1];
  return sameYear ? '$month ${time.day}' : '$month ${time.day}, ${time.year}';
}

/// A bubble timestamp — always a clock time, the date separator carries the day.
String formatClockTime(DateTime time) {
  final hour24 = time.hour;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final period = hour24 < 12 ? 'AM' : 'PM';
  return '$hour12:$minute $period';
}

/// Label for a date separator between groups of messages.
String formatDateSeparator(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(day.year, day.month, day.day);
  final diff = today.difference(target).inDays;

  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final sameYear = day.year == now.year;
  final month = _months[day.month - 1];
  return sameYear ? '$month ${day.day}' : '$month ${day.day}, ${day.year}';
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
