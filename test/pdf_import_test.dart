import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kodigo/pdf_import.dart';
import 'package:kodigo/pdf_preview_sheet.dart';
import 'package:kodigo/screens.dart';
import 'package:kodigo/study.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Map<String, dynamic> _buildPackJson({
  String id = 'generated-pack',
  String title = 'Generated Lesson',
  List<String>? paragraphs,
}) {
  final body = paragraphs ?? const ['Paragraph one.', 'Paragraph two.'];
  Map<String, String> bi(String en, String tl) => {'en': en, 'tl': tl};
  return {
    'version': 1,
    'id': id,
    'title': title,
    'paragraphs': body,
    'summaries': [
      {'text': bi('Simple summary.', 'Simpleng buod.'), 'sources': [1]},
      {'text': bi('Academic summary.', 'Pormal na buod.'), 'sources': [1]},
    ],
    'questions': [
      {
        'level': 1,
        'skill': 'main',
        'source': 1,
        'prompt': bi('Main idea?', 'Pangunahing ideya?'),
        'options': [bi('A', 'A'), bi('B', 'B'), bi('C', 'C')],
        'key': 0,
        'hints': [bi('Hint 1', 'Pahiwatig 1'), bi('Hint 2', 'Pahiwatig 2')],
        'explanation': bi('Because of paragraph 1.', 'Dahil sa talata 1.'),
      },
      {
        'level': 2,
        'skill': 'detail',
        'source': 1,
        'prompt': bi('Key detail?', 'Detalye?'),
        'options': [bi('A', 'A'), bi('B', 'B'), bi('C', 'C')],
        'key': 0,
        'hints': [bi('Hint 1', 'Pahiwatig 1'), bi('Hint 2', 'Pahiwatig 2')],
        'explanation': bi('Detail in paragraph 1.', 'Detalye sa talata 1.'),
      },
      {
        'level': 3,
        'skill': 'vocab',
        'source': 1,
        'prompt': bi('Vocab?', 'Talasalitaan?'),
        'options': [bi('A', 'A'), bi('B', 'B'), bi('C', 'C')],
        'key': 0,
        'hints': [bi('Hint 1', 'Pahiwatig 1'), bi('Hint 2', 'Pahiwatig 2')],
        'explanation': bi('Vocab in paragraph 1.', 'Salita sa talata 1.'),
      },
      {
        'level': 2,
        'skill': 'inference',
        'source': 1,
        'prompt': bi('Inference?', 'Paghihinuha?'),
        'options': [bi('A', 'A'), bi('B', 'B'), bi('C', 'C')],
        'key': 0,
        'hints': [bi('Hint 1', 'Pahiwatig 1'), bi('Hint 2', 'Pahiwatig 2')],
        'explanation': bi('Inferred from paragraph 1.', 'Hinuha sa talata 1.'),
      },
    ],
    'cards': [
      {
        'en': 'vapor',
        'tl': 'singaw',
        'definition': bi('Water as gas.', 'Tubig na naging gas.'),
      },
    ],
  };
}

Uint8List _fakePdfBytes([String body = 'hello']) =>
    Uint8List.fromList(utf8.encode('%PDF-1.4\n$body'));

void main() {
  final sample = StudyPack.decode(
    File('assets/water_cycle.json').readAsStringSync(),
  );

  group('PDF validation & helpers', () {
    test('validatePdfBytes checks empty, size limit, and %PDF- magic', () {
      expect(
        () => validatePdfBytes(Uint8List(0)),
        throwsA(
          isA<PdfImportException>().having(
            (e) => e.code,
            'code',
            PdfImportErrorCode.emptyFile,
          ),
        ),
      );
      expect(
        () => validatePdfBytes(Uint8List(maxPdfBytes + 1)),
        throwsA(
          isA<PdfImportException>().having(
            (e) => e.code,
            'code',
            PdfImportErrorCode.fileTooLarge,
          ),
        ),
      );
      expect(
        () => validatePdfBytes(Uint8List.fromList(utf8.encode('plain text'))),
        throwsA(
          isA<PdfImportException>().having(
            (e) => e.code,
            'code',
            PdfImportErrorCode.invalidPdf,
          ),
        ),
      );

      final offsetMagic = Uint8List.fromList([
        ...List.filled(32, 0x20),
        ...utf8.encode('%PDF-1.7'),
      ]);
      expect(() => validatePdfBytes(offsetMagic), returnsNormally);
    });

    test('cleanLessonTitle and deriveExtractUri normalize edge cases', () {
      expect(cleanLessonTitle('water_cycle-week_1.PDF'), 'water cycle week 1');
      expect(cleanLessonTitle('   .pdf  '), 'Lesson');
      expect(cleanLessonTitle('A' * 120).length, maxLessonTitleLength);

      expect(
        deriveExtractUri(Uri.parse('http://127.0.0.1:8080/generate')).toString(),
        'http://127.0.0.1:8080/extract',
      );
      expect(
        deriveExtractUri(Uri.parse('https://example.com/api/generate'))
            .toString(),
        'https://example.com/api/extract',
      );
      expect(
        deriveExtractUri(Uri.parse('https://example.com')).toString(),
        'https://example.com/extract',
      );
    });

    test('pdfImportErrorCopy provides EN and TL strings for every code', () {
      for (final code in PdfImportErrorCode.values) {
        final err = PdfImportException(code, pageCount: 44, charCount: 41200);
        final en = pdfImportErrorCopy(err, 'en');
        final tl = pdfImportErrorCopy(err, 'tl');
        expect(en.title.trim(), isNotEmpty);
        expect(en.detail.trim(), isNotEmpty);
        expect(tl.title.trim(), isNotEmpty);
        expect(tl.detail.trim(), isNotEmpty);
      }
      expect(
        pdfImportErrorCopy(
          const PdfImportException(
            PdfImportErrorCode.tooManyPages,
            pageCount: 44,
          ),
          'en',
        ).detail,
        contains('44'),
      );
      expect(
        pdfImportErrorCopy(
          const PdfImportException(
            PdfImportErrorCode.textTooLong,
            charCount: 41200,
          ),
          'tl',
        ).detail,
        contains('41200'),
      );
    });
  });

  group('PdfImportService', () {
    const service = PdfImportService();
    final genUri = Uri.parse('http://127.0.0.1:8080/generate');

    test('extract returns document on 200 and null on 404 fallback', () async {
      final okClient = MockClient((request) async {
        expect(request.url.path, '/extract');
        expect(request.headers['Content-Type'], 'application/pdf');
        return http.Response(
          jsonEncode({
            'title': 'Water_Cycle',
            'pageCount': 3,
            'paragraphCount': 2,
            'charCount': 34,
            'paragraphs': ['First paragraph.', 'Second paragraph.'],
            'warnings': ['stripped_repeated_headers_footers'],
          }),
          200,
        );
      });

      final extracted = await service.extract(
        generatorUri: genUri,
        file: PickedPdf(name: 'lesson.pdf', bytes: _fakePdfBytes()),
        client: okClient,
      );
      expect(extracted, isNotNull);
      expect(extracted!.title, 'Water Cycle');
      expect(extracted.pageCount, 3);
      expect(extracted.paragraphs, ['First paragraph.', 'Second paragraph.']);

      final fallbackClient = MockClient(
        (_) async => http.Response('Not Found', 404),
      );
      final missing = await service.extract(
        generatorUri: genUri,
        file: PickedPdf(name: 'lesson.pdf', bytes: _fakePdfBytes()),
        client: fallbackClient,
      );
      expect(missing, isNull);
    });

    test('maps server error codes and posts edited JSON on generate', () async {
      final errClient = MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'too_many_pages', 'pageCount': 52}),
          422,
        ),
      );
      await expectLater(
        () => service.extract(
          generatorUri: genUri,
          file: PickedPdf(name: 'big.pdf', bytes: _fakePdfBytes()),
          client: errClient,
        ),
        throwsA(
          isA<PdfImportException>()
              .having((e) => e.code, 'code', PdfImportErrorCode.tooManyPages)
              .having((e) => e.pageCount, 'pageCount', 52),
        ),
      );

      final genClient = MockClient((request) async {
        expect(request.url, genUri);
        expect(request.headers['Content-Type'], startsWith('application/json'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['title'], 'Edited Title');
        expect(body['paragraphs'], ['One.', 'Two.']);
        return http.Response(
          jsonEncode(
            _buildPackJson(
              title: body['title'] as String,
              paragraphs: (body['paragraphs'] as List).cast<String>(),
            ),
          ),
          200,
        );
      });

      final pack = await service.generateFromExtracted(
        generatorUri: genUri,
        title: 'Edited Title',
        paragraphs: const ['One.', 'Two.'],
        client: genClient,
      );
      expect(pack.title, 'Edited Title');
      expect(pack.paragraphs, ['One.', 'Two.']);
    });
  });

  group('PDF import UI & preview sheet', () {
    late SharedPreferencesAsync storage;

    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      storage = SharedPreferencesAsync();
    });

    Future<void> pumpHome(
      WidgetTester tester, {
      required Future<PickedPdf?> Function({required bool pdf}) pickFile,
      required http.Client Function() clientFactory,
      double textScale = 1.0,
    }) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 780),
              textScaler: TextScaler.linear(textScale),
            ),
            child: StudyHome(
              sample: sample,
              storage: storage,
              generatorUrl: 'http://127.0.0.1:8080/generate',
              pickFile: pickFile,
              httpClientFactory: clientFactory,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'end-to-end PDF import opens preview sheet, edits title, and creates pack',
      (tester) async {
        String? submittedTitle;
        List<String>? submittedParagraphs;

        await pumpHome(
          tester,
          pickFile: ({required pdf}) async =>
              PickedPdf(name: 'raw_file.pdf', bytes: _fakePdfBytes()),
          clientFactory: () => MockClient((request) async {
            if (request.url.path == '/extract') {
              return http.Response(
                jsonEncode({
                  'title': 'Extracted Title',
                  'pageCount': 3,
                  'paragraphCount': 2,
                  'charCount': 38,
                  'paragraphs': ['First paragraph.', 'Second paragraph.'],
                  'warnings': [],
                }),
                200,
              );
            }
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            submittedTitle = body['title'] as String;
            submittedParagraphs = (body['paragraphs'] as List).cast<String>();
            return http.Response(
              jsonEncode(
                _buildPackJson(
                  id: 'pack-custom',
                  title: submittedTitle!,
                  paragraphs: submittedParagraphs,
                ),
              ),
              200,
            );
          }),
        );

        await tester.tap(find.text('Choose a file from your phone'));
        await tester.pumpAndSettle();

        expect(find.text('Check extracted text'), findsOneWidget);
        expect(find.text('3 pages'), findsOneWidget);
        expect(find.text('2 ¶'), findsOneWidget);
        expect(find.text('¶1'), findsOneWidget);
        expect(find.text('First paragraph.'), findsOneWidget);
        expect(find.text('¶2'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'Custom Science Lesson');
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create study pack'));
        await tester.pumpAndSettle();

        expect(submittedTitle, 'Custom Science Lesson');
        expect(submittedParagraphs, ['First paragraph.', 'Second paragraph.']);
        expect(find.text('How do you want to study?'), findsOneWidget);
        expect(find.text('Custom Science Lesson'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'local validation failure shows error banner with zero HTTP calls',
      (tester) async {
        var httpCalls = 0;
        await pumpHome(
          tester,
          pickFile: ({required pdf}) async => PickedPdf(
            name: 'notes.pdf',
            bytes: Uint8List.fromList(utf8.encode('not a pdf')),
          ),
          clientFactory: () => MockClient((_) async {
            httpCalls++;
            return http.Response('{}', 200);
          }),
        );

        await tester.tap(find.text('Choose a file from your phone'));
        await tester.pumpAndSettle();

        expect(httpCalls, 0);
        expect(find.text('Invalid PDF file'), findsOneWidget);
        expect(find.text('Choose another PDF'), findsOneWidget);

        await tester.tap(find.text('Dismiss'));
        await tester.pumpAndSettle();
        expect(find.text('Invalid PDF file'), findsNothing);
      },
    );

    testWidgets(
      'Tagalog mode at 1.3x scale shows specific server error without overflow',
      (tester) async {
        await pumpHome(
          tester,
          textScale: 1.3,
          pickFile: ({required pdf}) async =>
              PickedPdf(name: 'scan.pdf', bytes: _fakePdfBytes()),
          clientFactory: () => MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'no_selectable_text'}),
              422,
            ),
          ),
        );

        await tester.tap(find.text('Tagalog'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Pumili ng file mula sa phone mo'));
        await tester.pumpAndSettle();

        expect(find.text('Walang mababasang teksto'), findsOneWidget);
        expect(find.text('Pumili ng ibang PDF'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'canceling during extraction aborts cleanly and ignores late response',
      (tester) async {
        final responseCompleter = Completer<http.Response>();
        var closed = false;

        await pumpHome(
          tester,
          pickFile: ({required pdf}) async =>
              PickedPdf(name: 'slow.pdf', bytes: _fakePdfBytes()),
          clientFactory: () => _ClosableMockClient(
            onSend: (_) => responseCompleter.future,
            onClose: () => closed = true,
          ),
        );

        await tester.tap(find.text('Choose a file from your phone'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Extracting text...'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(closed, isTrue);
        expect(find.text('Extracting text...'), findsNothing);

        responseCompleter.complete(
          http.Response(
            jsonEncode({
              'title': 'Late',
              'pageCount': 1,
              'paragraphCount': 1,
              'charCount': 10,
              'paragraphs': ['Late text.'],
              'warnings': [],
            }),
            200,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Check extracted text'), findsNothing);
      },
    );

    testWidgets(
      '60-paragraph preview caps list at 50 and disables CTA when title empty',
      (tester) async {
        tester.view.physicalSize = const Size(390, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final doc = ExtractedPdfDocument(
          title: 'Long Lesson',
          pageCount: 15,
          paragraphCount: 60,
          charCount: 14200,
          paragraphs: List.generate(60, (i) => 'Paragraph item ${i + 1}.'),
          warnings: const [],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 780),
                textScaler: TextScaler.linear(1.3),
              ),
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showPdfPreviewSheet(
                      context: context,
                      document: doc,
                      locale: 'en',
                    ),
                    child: const Text('Open preview'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open preview'));
        await tester.pumpAndSettle();

        expect(find.text('15 pages'), findsOneWidget);
        expect(find.text('60 ¶'), findsOneWidget);
        expect(find.text('14.2k chars'), findsOneWidget);

        final listFinder = find.byType(Scrollable).last;
        await tester.scrollUntilVisible(
          find.text('+10 more paragraphs included'),
          400,
          scrollable: listFinder,
        );
        expect(find.text('+10 more paragraphs included'), findsOneWidget);
        expect(find.text('Paragraph item 51.'), findsNothing);

        await tester.enterText(find.byType(TextField), '   ');
        await tester.pumpAndSettle();

        final createButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Create study pack'),
        );
        expect(createButton.onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

class _ClosableMockClient extends http.BaseClient {
  _ClosableMockClient({required this.onSend, required this.onClose});

  final Future<http.Response> Function(http.BaseRequest request) onSend;
  final VoidCallback onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await onSend(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    onClose();
    super.close();
  }
}
