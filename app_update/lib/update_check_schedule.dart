import 'package:shared_preferences/shared_preferences.dart';

enum UpdateCheckFrequency { launch, daily, weekly }

abstract interface class UpdateCheckPolicy {
  bool isDue(DateTime now, DateTime? lastChecked);
}

class IntervalUpdateCheckPolicy implements UpdateCheckPolicy {
  const IntervalUpdateCheckPolicy(this.interval);
  final Duration interval;

  @override
  bool isDue(DateTime now, DateTime? lastChecked) =>
      lastChecked == null || now.difference(lastChecked) >= interval;
}

class UpdateCheckSchedule {
  UpdateCheckSchedule({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const _lastDateKey = 'app_update_last_auto_check_date';
  static const _lastTimeKey = 'app_update_last_auto_check_time';
  final DateTime Function() _now;

  Future<bool> isDue({
    bool enabled = true,
    UpdateCheckFrequency frequency = UpdateCheckFrequency.daily,
  }) async {
    if (!enabled) return false;
    if (frequency == UpdateCheckFrequency.launch) return true;

    final preferences = await SharedPreferences.getInstance();
    if (frequency == UpdateCheckFrequency.weekly) {
      final last = preferences.getInt(_lastTimeKey);
      return last == null ||
          _now().difference(DateTime.fromMillisecondsSinceEpoch(last)).inDays >=
              7;
    }
    return preferences.getString(_lastDateKey) != _dateKey(_now());
  }

  Future<bool> isDueFor(UpdateCheckPolicy policy, {bool enabled = true}) async {
    if (!enabled) return false;
    final preferences = await SharedPreferences.getInstance();
    final last = preferences.getInt(_lastTimeKey);
    return policy.isDue(
      _now(),
      last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }

  Future<void> markChecked() async {
    final preferences = await SharedPreferences.getInstance();
    final now = _now();
    await preferences.setString(_lastDateKey, _dateKey(now));
    await preferences.setInt(_lastTimeKey, now.millisecondsSinceEpoch);
  }

  String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
