import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_tracker/main.dart';

void main() {
  test('privacy risk helpers preserve source labels', () {
    expect(
      getPrivacyRiskLabel(PrivacyRisk.low),
      'No Privacy Violations Detected',
    );
    expect(getPrivacyRiskIcon(PrivacyRisk.high), 'privacy-high');
  });

  test('journal data maps sleep-note labels without dynamic types', () {
    final JournalData journal = JournalData.fromJson(<String, Object?>{
      'date': '2026-06-13',
      'userId': 'user-1',
      'journalId': 'journal-1',
      'bedtime': '10:30 PM',
      'alarmTime': '06:30 AM',
      'sleepDuration': '8 hours',
      'diaryEntry': 'Slept well',
      'sleepNotes': <String>['Stress', 'Caffeine'],
    });

    expect(journal.sleepNotes, <SleepNote>[
      SleepNote.stress,
      SleepNote.caffeine,
    ]);
  });
}
