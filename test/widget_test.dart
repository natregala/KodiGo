import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kodigo/main.dart';
import 'package:kodigo/study.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final source = File('assets/water_cycle.json').readAsStringSync();
  final sample = StudyPack.decode(source);

  test('sample advances after three correct answers and ends after five', () {
    final run = StudyRun(sample, 0)..next();
    expect(run.total, 8);
    for (var i = 0; i < 5; i++) {
      expect(run.level, i < 3 ? 1 : 2);
      expect(run.used.last, i);
      run.answer(run.question.key);
      run.next();
    }
    expect(run.stage, 'progress');
  });

  test('Practice keeps Level 2 after one exhausted question', () {
    final run = StudyRun(sample, 1)..next();
    expect(run.question.skill, 'vocab');
    for (var question = 0; question < 2; question++) {
      final wrong = (run.question.key + 1) % run.question.options.length;
      run.answer(wrong);
      expect(run.settled, isFalse);
      run.retry();
      run.answer(wrong);
      expect(run.settled, isFalse);
      run.retry();
      run.answer(wrong);
      expect(run.settled, isTrue);
      run.next();
      expect(run.level, question == 0 ? 2 : 1);
    }
  });

  test('pack round-trip preserves sources and rejects dangling references', () {
    final copy = StudyPack.decode(jsonEncode(sample.json));
    expect(copy.paragraphs, sample.paragraphs);
    expect(copy.questions.map((value) => value.source), [1, 2, 3, 5, 4]);
    final invalid = jsonDecode(source) as Json;
    invalid['questions'][0]['source'] = 99;
    expect(() => StudyPack.fromJson(invalid), throwsFormatException);
  });

  testWidgets('question feedback survives rebuilding the app', (tester) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final storage = SharedPreferencesAsync();
    await tester.pumpWidget(KodiGo(sample: sample, storage: storage));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Water Cycle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start from the basics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start studying'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('How plants grow'));
    await tester.pumpAndSettle();
    expect(find.text('HINT 1 OF 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(KodiGo(sample: sample, storage: storage));
    await tester.pumpAndSettle();
    expect(find.text('HINT 1 OF 2'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('How to cook rice'));
    await tester.pumpAndSettle();
    expect(find.text('HINT 2 OF 2'), findsOneWidget);
    final reference = find.text('See in lesson ¶1');
    await tester.ensureVisible(reference);
    await tester.tap(reference);
    await tester.pumpAndSettle();
    expect(find.text(sample.paragraphs.first), findsOneWidget);
  });

  test(
    'Show again queues the same card and completion survives a round-trip',
    () {
      final run = StudyRun(sample, 0)..stage = 'cards';
      run.flip();
      run.rate(false);
      expect(run.queue, [1, 2, 0]);
      expect(run.flipped, isFalse);
      final restored = StudyRun(
        sample,
        0,
        restored: jsonDecode(jsonEncode(run.data)) as Json,
      );
      for (var i = 0; i < 3; i++) {
        restored.rate(true);
      }
      expect(restored.stage, 'cards-done');
    },
  );
}
