import 'dart:convert';

typedef Json = Map<String, dynamic>;
typedef Copy = Map<String, String>;

const skills = ['main', 'detail', 'vocab', 'inference'];

String localized(Copy value, String locale) => value[locale]!;

Copy readCopy(Object? value) {
  final data = value as Map;
  return {
    for (final lang in ['en', 'tl']) lang: readText(data[lang]),
  };
}

String readText(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Missing text');
  }
  return value;
}

class Question {
  const Question(
    this.level,
    this.skill,
    this.prompt,
    this.options,
    this.key,
    this.hints,
    this.explanation,
    this.source,
  );

  factory Question.fromJson(Json json) {
    final options = (json['options'] as List).map(readCopy).toList();
    final hints = (json['hints'] as List).map(readCopy).toList();
    final key = json['key'] as int;
    final level = json['level'] as int;
    final skill = readText(json['skill']);
    if (options.length < 2 ||
        options.length > 4 ||
        hints.length != 2 ||
        key < 0 ||
        key >= options.length ||
        level < 1 ||
        level > 3 ||
        !skills.contains(skill)) {
      throw const FormatException('Invalid question');
    }
    return Question(
      level,
      skill,
      readCopy(json['prompt']),
      options,
      key,
      hints,
      readCopy(json['explanation']),
      json['source'] as int,
    );
  }

  final int level;
  final String skill;
  final Copy prompt;
  final List<Copy> options;
  final int key;
  final List<Copy> hints;
  final Copy explanation;
  final int source;
}

class StudyPack {
  StudyPack.fromJson(this.json) {
    if (json['version'] != 1) throw const FormatException('Unsupported pack');
    id = readText(json['id']);
    title = readText(json['title']);
    paragraphs = (json['paragraphs'] as List).map(readText).toList();
    summaries = (json['summaries'] as List).map((value) {
      final summary = value as Json;
      final refs = (summary['sources'] as List).cast<int>().toList();
      if (refs.isEmpty || !refs.every(validSource)) {
        throw const FormatException('Invalid summary citations');
      }
      return (text: readCopy(summary['text']), sources: refs);
    }).toList();
    questions = (json['questions'] as List)
        .map((value) => Question.fromJson(value as Json))
        .toList();
    cards = (json['cards'] as List).map((value) {
      final card = value as Json;
      return (
        en: readText(card['en']),
        tl: readText(card['tl']),
        definition: readCopy(card['definition']),
      );
    }).toList();
    if (summaries.length != 2 ||
        questions.length < 4 ||
        cards.isEmpty ||
        !questions.every((question) => validSource(question.source)) ||
        !skills.every(
          (skill) => questions.any((question) => question.skill == skill),
        ) ||
        !(sample ? [1, 2] : [1, 2, 3]).every(
          (level) => questions.any((question) => question.level == level),
        )) {
      throw const FormatException('Incomplete study pack');
    }
  }

  final Json json;
  late final String id;
  late final String title;
  late final List<String> paragraphs;
  late final List<({Copy text, List<int> sources})> summaries;
  late final List<Question> questions;
  late final List<({String en, String tl, Copy definition})> cards;
  bool get sample => id == 'water-cycle';
  int get advertisedCount => sample ? 5 : questions.length;
  bool validSource(int id) => id >= 1 && id <= paragraphs.length;

  factory StudyPack.decode(String contents) =>
      StudyPack.fromJson(jsonDecode(contents) as Json);
}

class StudyRun {
  StudyRun(this.pack, this.mode, {Json? restored})
    : data =
          restored ??
          {
            'stage': 'summary',
            'level': mode + 1,
            'used': <int>[],
            'wrong': 0,
            'streak': 0,
            'misses': 0,
            'selected': null,
            'queue': List<int>.generate(pack.cards.length, (index) => index),
            'flipped': false,
          };

  final StudyPack pack;
  final int mode;
  final Json data;
  String get stage => data['stage'] as String;
  set stage(String value) => data['stage'] = value;
  int get level => data['level'] as int;
  List<int> get used => (data['used'] as List).cast<int>();
  List<int> get queue => (data['queue'] as List).cast<int>();
  int get total => pack.sample ? 8 : pack.questions.length;
  int get wrong => data['wrong'] as int;
  int? get selected => data['selected'] as int?;
  bool get flipped => data['flipped'] as bool;
  Question get question => pack.questions[used.last];
  bool get correct => selected == question.key;
  bool get settled => selected != null && (correct || wrong > 2);

  void next() {
    if (used.length == pack.questions.length) {
      stage = 'progress';
      return;
    }
    if (used.isNotEmpty) {
      final firstTry = correct && wrong == 0;
      final streak = firstTry ? (data['streak'] as int) + 1 : 0;
      final misses = correct ? 0 : (data['misses'] as int? ?? 0) + 1;
      if (streak == 3 && level < 3) data['level'] = level + 1;
      if (misses == 2 && level > 1) data['level'] = level - 1;
      data['streak'] = streak >= 3 ? 0 : streak;
      data['misses'] = misses >= 2 ? 0 : misses;
    }
    final available = List.generate(
      pack.questions.length,
      (index) => index,
    ).where((index) => !used.contains(index)).toList();
    final index = pack.sample && mode == 0
        ? available.first
        : available.firstWhere(
            (i) => pack.questions[i].level == level,
            orElse: () => available.reduce(
              (a, b) =>
                  (pack.questions[a].level - level).abs() <=
                      (pack.questions[b].level - level).abs()
                  ? a
                  : b,
            ),
          );
    used.add(index);
    data['selected'] = null;
    data['wrong'] = 0;
    stage = 'question';
  }

  void answer(int index) {
    if (selected != null) return;
    data['selected'] = index;
    if (!correct) data['wrong'] = wrong + 1;
  }

  void retry() => data['selected'] = null;
  void flip() => data['flipped'] = !flipped;
  void rate(bool gotIt) {
    final card = queue.removeAt(0);
    if (!gotIt) queue.add(card);
    data['flipped'] = false;
    if (queue.isEmpty) stage = 'cards-done';
  }
}
