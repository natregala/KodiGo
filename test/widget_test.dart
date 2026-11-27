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

  Future<List<MethodCall>> readAloudWithVoices(
    WidgetTester tester,
    Object? voices, {
    bool failVoiceEnumeration = false,
  }) async {
    final calls = <MethodCall>[];
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'getVoices' && failVoiceEnumeration) {
            throw PlatformException(code: 'voice-enumeration-unavailable');
          }
          return call.method == 'getVoices' ? voices : 1;
        });
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.pumpWidget(
      KodiGo(sample: sample, storage: SharedPreferencesAsync()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Water Cycle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start from the basics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start studying'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read aloud'));
    await tester.pumpAndSettle();
    return calls;
  }

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
    final speechCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          speechCalls.add(call);
          return 1;
        });
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
    final question = sample.questions.first;
    await tester.tap(find.text('Read aloud'));
    await tester.pumpAndSettle();
    expect(
      speechCalls.lastWhere((call) => call.method == 'speak').arguments,
      '${question.prompt['en']} '
      '${question.options.asMap().entries.map((entry) => '${String.fromCharCode(65 + entry.key)}. ${entry.value['en']}').join('. ')}',
    );
    await tester.tap(find.text('Stop reading'));
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
    final feedbackReadAloud = find.text('Read aloud').last;
    await tester.scrollUntilVisible(
      feedbackReadAloud,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(feedbackReadAloud);
    await tester.pumpAndSettle();
    expect(
      speechCalls.lastWhere((call) => call.method == 'speak').arguments,
      question.hints[1]['en'],
    );
    await tester.tap(find.text('Stop reading').last);
    await tester.pumpAndSettle();
    final reference = find.text('See in lesson ¶1');
    await tester.ensureVisible(reference);
    await tester.tap(reference);
    await tester.pumpAndSettle();
    expect(find.text(sample.paragraphs.first), findsOneWidget);
  });

  testWidgets('read aloud falls back to the platform language', (tester) async {
    final calls = await readAloudWithVoices(tester, []);
    expect(
      calls.any(
        (call) => call.method == 'setLanguage' && call.arguments == 'en-US',
      ),
      isTrue,
    );
    expect(calls.any((call) => call.method == 'speak'), isTrue);
    expect(calls.any((call) => call.method == 'setVoice'), isFalse);
  });

  testWidgets('read aloud falls back if voice enumeration fails', (
    tester,
  ) async {
    final calls = await readAloudWithVoices(
      tester,
      null,
      failVoiceEnumeration: true,
    );
    expect(
      calls.any(
        (call) => call.method == 'setLanguage' && call.arguments == 'en-US',
      ),
      isTrue,
    );
    expect(calls.any((call) => call.method == 'speak'), isTrue);
  });

  testWidgets('read aloud prefers a matching offline voice', (tester) async {
    final calls = await readAloudWithVoices(tester, [
      {'name': 'English Voice', 'locale': 'en-US', 'network_required': false},
    ]);
    expect(calls.any((call) => call.method == 'setVoice'), isTrue);
    expect(calls.any((call) => call.method == 'setLanguage'), isFalse);
    expect(calls.any((call) => call.method == 'speak'), isTrue);
  });

  test('flashcard direction persists and resets the active side', () {
    final run = StudyRun(sample, 0)..stage = 'cards';
    expect(run.reverseCards, isFalse);
    expect(run.showingTagalog, isFalse);
    run.flip();
    expect(run.showingTagalog, isTrue);
    run.setCardDirection(true);
    expect(run.flipped, isFalse);
    expect(run.showingTagalog, isTrue);

    final restored = StudyRun(
      sample,
      0,
      restored: jsonDecode(jsonEncode(run.data)) as Json,
    );
    expect(restored.reverseCards, isTrue);
    restored.flip();
    expect(restored.showingTagalog, isFalse);

    final legacy = StudyRun(sample, 0, restored: {'flipped': false});
    expect(legacy.reverseCards, isFalse);
    expect(legacy.showingTagalog, isFalse);
  });

  testWidgets('Study paths launch reversible flashcards with audio', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          calls.add(call);
          return call.method == 'getVoices' ? [] : 1;
        });
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.pumpWidget(
      KodiGo(sample: sample, storage: SharedPreferencesAsync()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Water Cycle'));
    await tester.pumpAndSettle();
    final review = find.text('Review flashcards');
    await tester.scrollUntilVisible(
      review,
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(review);
    await tester.pumpAndSettle();

    final firstCard = sample.cards.first;
    expect(find.text(firstCard.en), findsOneWidget);
    expect(find.text('ENGLISH'), findsOneWidget);
    await tester.tap(find.text('Tagalog'));
    await tester.pumpAndSettle();
    expect(find.text(firstCard.en), findsOneWidget);
    expect(find.text('INGLES'), findsOneWidget);
    final selector = find.byType(SegmentedButton<String>);
    await tester.tap(
      find.descendant(of: selector, matching: find.text('English')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<String>>(selector).selected, {'en'});
    await tester.tap(find.text('TL → EN'));
    await tester.pumpAndSettle();
    expect(find.text(firstCard.tl), findsOneWidget);
    var readAloud = find.text('Read aloud');
    await tester.scrollUntilVisible(
      readAloud,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(readAloud);
    await tester.pumpAndSettle();
    expect(
      calls.any(
        (call) => call.method == 'setLanguage' && call.arguments == 'fil-PH',
      ),
      isTrue,
    );
    expect(
      calls.lastWhere((call) => call.method == 'speak').arguments,
      firstCard.tl,
    );

    await tester.tap(find.text(firstCard.tl));
    await tester.pumpAndSettle();
    expect(find.text(firstCard.en), findsOneWidget);
    expect(find.text(firstCard.definition['en']!), findsOneWidget);
    readAloud = find.text('Read aloud');
    await tester.scrollUntilVisible(
      readAloud,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(readAloud);
    await tester.pumpAndSettle();
    expect(
      calls.lastWhere((call) => call.method == 'speak').arguments,
      '${firstCard.en}. ${firstCard.definition['en']}',
    );
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text(sample.cards[1].tl), findsOneWidget);
    expect(calls.where((call) => call.method == 'stop'), hasLength(2));
  });

  testWidgets('language can switch during study and updates saved copy', (
    tester,
  ) async {
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
    await tester.tap(find.text('Tagalog'));
    await tester.pumpAndSettle();
    final lesson = find.text('The Water Cycle');
    await tester.scrollUntilVisible(
      lesson,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(lesson);
    await tester.pumpAndSettle();
    expect(find.text('PAGHABOL'), findsOneWidget);
    expect(find.text('PAGSASANAY'), findsOneWidget);

    await tester.tap(find.text('Magsimula sa mga batayan'));
    await tester.pumpAndSettle();
    expect(find.text(sample.summaries.first.text['tl']!), findsOneWidget);
    expect(find.text('Antas 1 · Paghabol'), findsOneWidget);

    final sessionSelector = find.byType(SegmentedButton<String>);
    await tester.tap(
      find.descendant(of: sessionSelector, matching: find.text('English')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<String>>(sessionSelector).selected, {
      'en',
    });
    expect(find.text(sample.summaries.first.text['en']!), findsOneWidget);
    expect(find.text('Level 1 · Catch-up'), findsOneWidget);
    final saved =
        jsonDecode((await storage.getString('kodigo-state-v1'))!) as Json;
    expect(saved['locale'], 'en');
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
