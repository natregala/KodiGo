import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'study.dart';

const maxPdfBytes = 12 * 1024 * 1024;
const maxPdfChars = 35000;
const maxLessonTitleLength = 80;

const _pdfMagic = <int>[0x25, 0x50, 0x44, 0x46, 0x2d]; // %PDF-

enum PdfImportStage { reading, extracting, generating }

enum PdfImportErrorCode {
  configuration,
  emptyFile,
  fileTooLarge,
  invalidPdf,
  encryptedPdf,
  tooManyPages,
  noSelectableText,
  textTooLong,
  unreadable,
  generatorUnconfigured,
  generationFailed,
  connection,
}

class PdfImportException implements Exception {
  const PdfImportException(
    this.code, {
    this.pageCount,
    this.charCount,
    this.detail,
  });

  final PdfImportErrorCode code;
  final int? pageCount;
  final int? charCount;
  final String? detail;
}

class PickedPdf {
  const PickedPdf({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class ExtractedPdfDocument {
  const ExtractedPdfDocument({
    required this.title,
    required this.pageCount,
    required this.paragraphCount,
    required this.charCount,
    required this.paragraphs,
    required this.warnings,
  });

  factory ExtractedPdfDocument.fromJson(
    Json json, {
    String fallbackTitle = 'Lesson',
  }) {
    final rawParagraphs = json['paragraphs'];
    if (rawParagraphs is! List || rawParagraphs.isEmpty) {
      throw const PdfImportException(PdfImportErrorCode.noSelectableText);
    }
    final paragraphs = rawParagraphs
        .map((item) => readText(item).trim())
        .toList();
    final charCount = json['charCount'] is int
        ? json['charCount'] as int
        : paragraphs.fold<int>(0, (sum, item) => sum + item.length);
    final pageCount = json['pageCount'] is int ? json['pageCount'] as int : 1;
    final paragraphCount = json['paragraphCount'] is int
        ? json['paragraphCount'] as int
        : paragraphs.length;
    final rawTitle = json['title'] is String ? json['title'] as String : '';
    final cleanedTitle = cleanLessonTitle(
      rawTitle.trim().isEmpty ? fallbackTitle : rawTitle,
    );
    final warnings = json['warnings'] is List
        ? (json['warnings'] as List).whereType<String>().toList()
        : const <String>[];

    return ExtractedPdfDocument(
      title: cleanedTitle,
      pageCount: pageCount,
      paragraphCount: paragraphCount,
      charCount: charCount,
      paragraphs: paragraphs,
      warnings: warnings,
    );
  }

  final String title;
  final int pageCount;
  final int paragraphCount;
  final int charCount;
  final List<String> paragraphs;
  final List<String> warnings;
}

void validatePdfBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const PdfImportException(PdfImportErrorCode.emptyFile);
  }
  if (bytes.length > maxPdfBytes) {
    throw const PdfImportException(PdfImportErrorCode.fileTooLarge);
  }
  final searchLimit = math.min(bytes.length, 1024);
  if (!_containsBytes(bytes, _pdfMagic, searchLimit)) {
    throw const PdfImportException(PdfImportErrorCode.invalidPdf);
  }
}

bool _containsBytes(Uint8List haystack, List<int> needle, int limit) {
  if (limit < needle.length) return false;
  for (var i = 0; i <= limit - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

String cleanLessonTitle(String rawName) {
  var value = rawName.trim();
  value = value.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
  value = value.replaceAll(RegExp(r'[_-]+'), ' ');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty) return 'Lesson';
  if (value.length > maxLessonTitleLength) {
    value = value.substring(0, maxLessonTitleLength).trim();
  }
  return value.isEmpty ? 'Lesson' : value;
}

Uri deriveExtractUri(Uri generatorUri) {
  final path = generatorUri.path;
  if (path == '/generate' || path.endsWith('/generate')) {
    final prefix = path.substring(0, path.length - '/generate'.length);
    return generatorUri.replace(path: '$prefix/extract');
  }
  if (path.isEmpty || path == '/') {
    return generatorUri.replace(path: '/extract');
  }
  return generatorUri.resolve('extract');
}

String pdfImportStageLabel(PdfImportStage stage, String locale) {
  final tl = locale == 'tl';
  return switch (stage) {
    PdfImportStage.reading => tl ? 'Binabasa ang file...' : 'Reading file...',
    PdfImportStage.extracting =>
      tl ? 'Kinukuha ang teksto...' : 'Extracting text...',
    PdfImportStage.generating =>
      tl ? 'Ginagawa ang pack...' : 'Creating pack...',
  };
}

({String title, String detail}) pdfImportErrorCopy(
  PdfImportException error,
  String locale,
) {
  final tl = locale == 'tl';
  return switch (error.code) {
    PdfImportErrorCode.configuration => (
      title: tl ? 'Walang konektadong serbisyo' : 'Generator not connected',
      detail: tl
          ? 'Ikonekta ang pack generation service para maghanda ng PDF.'
          : 'Connect the pack generation service to prepare new PDFs.',
    ),
    PdfImportErrorCode.emptyFile => (
      title: tl ? 'Walang laman ang file' : 'Empty PDF file',
      detail: tl
          ? 'Pumili ng PDF na may laman na teksto.'
          : 'Choose a non-empty PDF document.',
    ),
    PdfImportErrorCode.fileTooLarge => (
      title: tl ? 'Masyadong malaki ang file' : 'PDF is too large',
      detail: tl
          ? 'Limitado sa 12 MB ang bawat PDF.'
          : 'Choose a PDF under 12 MB.',
    ),
    PdfImportErrorCode.invalidPdf => (
      title: tl ? 'Hindi valid na PDF' : 'Invalid PDF file',
      detail: tl
          ? 'Mukhang sira o hindi PDF ang file na napili.'
          : 'The selected file is corrupted or not a PDF.',
    ),
    PdfImportErrorCode.encryptedPdf => (
      title: tl ? 'Naka-lock ang PDF' : 'Password-protected PDF',
      detail: tl
          ? 'Mag-upload ng PDF na walang password.'
          : 'Remove the password lock and try again.',
    ),
    PdfImportErrorCode.tooManyPages => (
      title: tl ? 'Lampas sa 40 pahina' : 'Too many pages',
      detail: error.pageCount != null
          ? (tl
                ? 'May ${error.pageCount} pahina ito. Hanggang 40 pahina lang.'
                : 'This PDF has ${error.pageCount} pages. The limit is 40.')
          : (tl
                ? 'Hanggang 40 pahina lang ang puwede.'
                : 'Choose a PDF with 40 pages or fewer.'),
    ),
    PdfImportErrorCode.noSelectableText => (
      title: tl ? 'Walang mababasang teksto' : 'No readable text found',
      detail: tl
          ? 'Scanned image PDF ito. Gumamit ng PDF na may mapipiling teksto.'
          : 'Scanned image PDFs cannot be read. Use selectable text.',
    ),
    PdfImportErrorCode.textTooLong => (
      title: tl ? 'Masyadong mahaba ang teksto' : 'Lesson text is too long',
      detail: error.charCount != null
          ? (tl
                ? 'May ${error.charCount} character ito. Limitado sa 35,000.'
                : 'Extracted ${error.charCount} characters. The limit is 35,000.')
          : (tl
                ? 'Limitado sa 35,000 character ang teksto.'
                : 'Keep extracted text within 35,000 characters.'),
    ),
    PdfImportErrorCode.unreadable => (
      title: tl ? 'Hindi mabasa ang PDF' : 'Could not read PDF',
      detail: tl
          ? 'Gumamit ng PDF na may mapipiling teksto.'
          : 'Use a PDF with selectable text.',
    ),
    PdfImportErrorCode.generatorUnconfigured => (
      title: tl ? 'Hindi handa ang generator' : 'Generator is not configured',
      detail: tl
          ? 'Na-extract ang teksto, pero kulang ang server API setup.'
          : 'Text was extracted, but the server AI key is not set up.',
    ),
    PdfImportErrorCode.generationFailed => (
      title: tl ? 'Hindi nagawa ang study pack' : 'Could not create study pack',
      detail: tl
          ? 'Nagkaproblema ang serbisyo habang ginagawa ang pack. Subukan ulit.'
          : 'The generator failed to build the pack. Please try again.',
    ),
    PdfImportErrorCode.connection => (
      title: tl ? 'Walang koneksyon sa serbisyo' : 'Connection error',
      detail: tl
          ? 'Suriin ang internet o generator URL at subukan ulit.'
          : 'Check your connection or generator URL and try again.',
    ),
  };
}

class PdfImportService {
  const PdfImportService();

  Uri? parseGeneratorUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme)) {
      return null;
    }
    return uri;
  }

  Future<ExtractedPdfDocument?> extract({
    required Uri generatorUri,
    required PickedPdf file,
    required http.Client client,
  }) async {
    validatePdfBytes(file.bytes);
    final extractUri = deriveExtractUri(generatorUri);
    final fallbackTitle = cleanLessonTitle(file.name);
    final response = await client
        .post(
          extractUri,
          headers: {
            'Content-Type': 'application/pdf',
            'X-Lesson-Title': Uri.encodeComponent(fallbackTitle),
          },
          body: file.bytes,
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode == 404 || response.statusCode == 405) {
      return null;
    }
    if (response.statusCode != 200) {
      throw _parseServerError(response);
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const PdfImportException(PdfImportErrorCode.unreadable);
    }
    return ExtractedPdfDocument.fromJson(
      decoded,
      fallbackTitle: fallbackTitle,
    );
  }

  Future<StudyPack> generateFromExtracted({
    required Uri generatorUri,
    required String title,
    required List<String> paragraphs,
    required http.Client client,
  }) async {
    final response = await client
        .post(
          generatorUri,
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            'title': title.trim().isEmpty ? 'Lesson' : title.trim(),
            'paragraphs': paragraphs,
          }),
        )
        .timeout(const Duration(seconds: 150));

    if (response.statusCode != 200) {
      throw _parseServerError(response);
    }
    return StudyPack.decode(utf8.decode(response.bodyBytes));
  }

  Future<StudyPack> generateFromPdf({
    required Uri generatorUri,
    required PickedPdf file,
    required http.Client client,
  }) async {
    validatePdfBytes(file.bytes);
    final response = await client
        .post(
          generatorUri,
          headers: {
            'Content-Type': 'application/pdf',
            'X-Lesson-Title': Uri.encodeComponent(cleanLessonTitle(file.name)),
          },
          body: file.bytes,
        )
        .timeout(const Duration(seconds: 150));

    if (response.statusCode != 200) {
      throw _parseServerError(response);
    }
    return StudyPack.decode(utf8.decode(response.bodyBytes));
  }

  PdfImportException _parseServerError(http.Response response) {
    Map<String, dynamic>? payload;
    try {
      final parsed = jsonDecode(utf8.decode(response.bodyBytes));
      if (parsed is Map<String, dynamic>) payload = parsed;
    } catch (_) {
      payload = null;
    }

    final code = payload?['error'] as String?;
    final pageCount = payload?['pageCount'] as int?;
    final charCount = payload?['charCount'] as int?;
    final detail = payload?['message'] as String?;

    final mapped = switch (code) {
      'empty_file' => PdfImportErrorCode.emptyFile,
      'file_too_large' => PdfImportErrorCode.fileTooLarge,
      'invalid_pdf' => PdfImportErrorCode.invalidPdf,
      'encrypted_pdf' => PdfImportErrorCode.encryptedPdf,
      'too_many_pages' => PdfImportErrorCode.tooManyPages,
      'no_selectable_text' => PdfImportErrorCode.noSelectableText,
      'text_too_long' => PdfImportErrorCode.textTooLong,
      'unreadable_pdf' || 'invalid_paragraphs' => PdfImportErrorCode.unreadable,
      'generator_unconfigured' => PdfImportErrorCode.generatorUnconfigured,
      'generation_failed' => PdfImportErrorCode.generationFailed,
      _ => switch (response.statusCode) {
        413 => PdfImportErrorCode.fileTooLarge,
        422 => PdfImportErrorCode.unreadable,
        503 => PdfImportErrorCode.generatorUnconfigured,
        502 => PdfImportErrorCode.generationFailed,
        _ => PdfImportErrorCode.connection,
      },
    };

    return PdfImportException(
      mapped,
      pageCount: pageCount,
      charCount: charCount,
      detail: detail,
    );
  }
}
