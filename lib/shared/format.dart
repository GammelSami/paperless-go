import 'package:intl/intl.dart';

/// German date display used everywhere in this fork: 13.10.2026.
final DateFormat dateFormatDe = DateFormat('dd.MM.yyyy');

String formatDate(DateTime date) => dateFormatDe.format(date);

/// Parses "13.10.2026" (also "13.10.26", "1.2.2026"). Returns null if invalid.
DateTime? parseDateDe(String input) {
  final m = RegExp(
    r'^\s*(\d{1,2})\.(\d{1,2})\.(\d{2}|\d{4})\s*$',
  ).firstMatch(input);
  if (m == null) return null;
  final day = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  var year = int.parse(m.group(3)!);
  if (year < 100) year += 2000;
  final date = DateTime(year, month, day);
  if (date.day != day || date.month != month) return null;
  return date;
}

/// Paperless monetary values look like "EUR-91.80" or "9.99".
/// Shown with sign, German decimal comma and thousands dot:
/// "-91,80 €", "+9,99 €", "-1.249,90 €".
final NumberFormat _moneyDe = NumberFormat('#,##0.00', 'de_DE');

String formatMoney(Object value) {
  final raw = value.toString();
  final m = RegExp(r'^([A-Z]{3})?(-?\d+(?:\.\d+)?)$').firstMatch(raw);
  final amount = m == null ? null : double.tryParse(m.group(2)!);
  if (amount == null) return raw;
  final currency = m!.group(1) ?? 'EUR';
  final symbol = currency == 'EUR' ? '€' : currency;
  final sign = amount < 0 ? '-' : (amount > 0 ? '+' : '');
  final number = _moneyDe.format(amount.abs());
  return '$sign$number $symbol';
}
