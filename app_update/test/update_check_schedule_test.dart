import 'package:app_update/update_check_schedule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('supports disabled, launch, daily, and weekly checks', () async {
    var now = DateTime(2026, 8, 6, 9);
    final schedule = UpdateCheckSchedule(now: () => now);

    expect(await schedule.isDue(enabled: false), isFalse);
    expect(
      await schedule.isDue(frequency: UpdateCheckFrequency.launch),
      isTrue,
    );
    expect(await schedule.isDue(), isTrue);
    await schedule.markChecked();
    expect(await schedule.isDue(), isFalse);
    expect(
      await schedule.isDue(frequency: UpdateCheckFrequency.weekly),
      isFalse,
    );

    now = now.add(const Duration(days: 7));
    expect(
      await schedule.isDue(frequency: UpdateCheckFrequency.weekly),
      isTrue,
    );
  });
}
