import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('formats as zero-padded 24-hour HH:mm', () {
    expect(const LocalTimeOfDay(10, 0).toString(), '10:00');
    expect(const LocalTimeOfDay(9, 5).toString(), '09:05');
    expect(const LocalTimeOfDay(21, 30).toString(), '21:30');
    expect(const LocalTimeOfDay(0, 0).toString(), '00:00');
  });

  test('round-trips through parse', () {
    for (final s in ['00:00', '09:05', '10:00', '12:00', '23:59']) {
      expect(LocalTimeOfDay.parse(s).toString(), s);
    }
  });

  test('is strict — a lenient parser would reschedule a warning alarm', () {
    for (final bad in ['9:00', '10:0', '24:00', '10:60', '', '10', '1000']) {
      expect(LocalTimeOfDay.tryParse(bad), isNull, reason: bad);
    }
    expect(() => LocalTimeOfDay.parse('9:00'), throwsFormatException);
  });

  test('orders by time of day', () {
    const midday = LocalTimeOfDay(12, 0);
    const evening = LocalTimeOfDay(18, 0);
    expect(midday < evening, isTrue);
    expect(evening > midday, isTrue);
    expect(midday <= midday, isTrue);
    expect(midday >= midday, isTrue);
    expect(
      ([evening, midday, const LocalTimeOfDay(21, 0)]..sort()).first,
      midday,
    );
  });

  test('value equality', () {
    expect(const LocalTimeOfDay(10, 0), const LocalTimeOfDay(10, 0));
    expect(const LocalTimeOfDay(10, 0).hashCode,
        const LocalTimeOfDay(10, 0).hashCode);
    expect(const LocalTimeOfDay(10, 0), isNot(const LocalTimeOfDay(10, 1)));
  });
}
