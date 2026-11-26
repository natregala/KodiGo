import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'study.dart';

const paper = Color(0xfff7f6f2);
const ink = Color(0xff1d2320);
const green = Color(0xff1e6b57);
const mint = Color(0xffe3efea);
const stroke = Color(0xffe3e0d8);
const muted = Color(0xff5d615c);

class StudyHome extends StatefulWidget {
  const StudyHome({super.key, required this.sample, required this.storage});
  final StudyPack sample;
  final SharedPreferencesAsync storage;

  @override
  State<StudyHome> createState() => _StudyHomeState();
}

class _StudyHomeState extends State<StudyHome> {
  static const storageKey = 'kodigo-state-v1';
  static const generator = String.fromEnvironment('KODIGO_GENERATOR_URL');
  final packs = <String, StudyPack>{};
  final mastery = <String, Map<String, List<int>>>{};
  final tts = FlutterTts();
  Future<void> writes = Future.value();
  final scroll = ScrollController();
  late StudyPack pack;
  StudyRun? run;
  http.Client? request;
  String locale = 'en';
  String? error;
  int tab = 0;
  bool loading = true;
  bool busy = false;
  bool speaking = false;
  int speechRequest = 0;

  String tr(String en, String tl) => locale == 'en' ? en : tl;
  String copy(Copy text) => localized(text, locale);
  String get stage => run?.stage ?? '';
  bool get inSession =>
      ['summary', 'question', 'cards', 'cards-done'].contains(stage);

  @override
  void initState() {
    super.initState();
    pack = widget.sample;
    packs[pack.id] = pack;
    tts.setCompletionHandler(() {
      if (mounted) setState(() => speaking = false);
    });
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final saved = await widget.storage.getString(storageKey);
      if (saved != null) {
        final data = jsonDecode(saved) as Json;
        for (final raw in data['packs'] as List) {
          final value = StudyPack.fromJson(raw as Json);
          if (!value.sample) packs[value.id] = value;
        }
        locale = data['locale'] == 'tl' ? 'tl' : 'en';
        pack = packs[data['pack']] ?? widget.sample;
        tab = data['tab'] as int;
        (data['mastery'] as Json).forEach((id, value) {
          mastery[id] = (value as Json).map(
            (skill, counts) => MapEntry(skill, (counts as List).cast<int>()),
          );
        });
        if (data['run'] != null) {
          run = StudyRun(
            pack,
            data['mode'] as int,
            restored: data['run'] as Json,
          );
        }
      }
    } catch (_) {
      error = tr(
        'Could not restore your last session.',
        'Hindi naibalik ang huling session mo.',
      );
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> save() {
    final snapshot = jsonEncode({
      'packs': packs.values
          .where((value) => !value.sample)
          .map((value) => value.json)
          .toList(),
      'pack': pack.id,
      'tab': tab,
      'locale': locale,
      'mastery': mastery,
      'run': run?.data,
      'mode': run?.mode,
    });
    writes = writes
        .then((_) => widget.storage.setString(storageKey, snapshot))
        .catchError((Object _) {
          if (mounted) {
            setState(
              () => error = tr(
                'Could not save your changes.',
                'Hindi na-save ang mga pagbabago.',
              ),
            );
          }
        });
    return writes;
  }

  void update(VoidCallback action, {bool top = false}) {
    if (top && scroll.hasClients) scroll.jumpTo(0);
    setState(action);
    unawaited(save());
  }

  @override
  void dispose() {
    request?.close();
    if (speaking) unawaited(tts.stop());
    scroll.dispose();
    super.dispose();
  }

  Future<void> stopSpeech() async {
    speechRequest++;
    if (!speaking) return;
    setState(() => speaking = false);
    await tts.stop();
  }

  Future<void> speak(String text) async {
    if (speaking) return stopSpeech();
    final active = ++speechRequest;
    final language = locale == 'tl' ? 'fil-PH' : 'en-US';
    try {
      final voices = await tts.getVoices;
      final code = language.toLowerCase().split('-').first;
      final available = voices is List
          ? voices.whereType<Map>().where((voice) {
              final networkRequired = voice['network_required'].toString();
              if (networkRequired == '1' || networkRequired == 'true') {
                return false;
              }
              final name = voice['locale'].toString().toLowerCase();
              return name.startsWith(code) ||
                  (locale == 'tl' && name.startsWith('tl'));
            }).firstOrNull
          : null;
      if (available == null) throw StateError('Voice unavailable');
      if (!mounted || active != speechRequest) return;
      await tts.setVoice({
        'name': available['name'].toString(),
        'locale': available['locale'].toString(),
      });
      if (!mounted || !inSession || active != speechRequest) return;
      setState(() => speaking = true);
      await tts.speak(text);
    } catch (_) {
      if (mounted && active == speechRequest) {
        setState(() => speaking = false);
        message(
          tr(
            'Install a voice for this language in your phone settings.',
            'Mag-install ng boses para sa wikang ito sa settings ng phone.',
          ),
        );
      }
    }
  }

  void message(String value) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(value)));

  void closeSession() {
    unawaited(stopSpeech());
    update(() {
      tab = stage.startsWith('cards') ? 2 : 1;
      run = null;
    }, top: true);
  }

  void openPack(StudyPack value) => update(() {
    if (value.id != pack.id) run = null;
    pack = value;
    tab = 1;
  }, top: true);

  void start(int mode) => update(() => run = StudyRun(pack, mode), top: true);

  void nextQuestion() {
    final current = run;
    if (current == null ||
        (current.stage != 'summary' &&
            (current.stage != 'question' || !current.settled))) {
      return;
    }
    unawaited(stopSpeech());
    update(() {
      if (current.stage == 'question' && current.settled) {
        final bySkill = mastery.putIfAbsent(pack.id, () => {});
        final counts = bySkill.putIfAbsent(
          current.question.skill,
          () => [0, 0],
        );
        counts[0] += current.correct ? 1 : 0;
        counts[1]++;
      }
      current.next();
      if (current.stage == 'progress') tab = 2;
    }, top: true);
  }

  Future<void> chooseFile({required bool pdf}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final picked = await FilePicker.pickFiles(
        type: pdf ? FileType.custom : FileType.any,
        allowedExtensions: pdf ? ['pdf'] : null,
      );
      if (picked.isEmpty || !mounted || !busy) return;
      final file = picked.single;
      if ((file.lengthSync() ?? 0) > 12 * 1024 * 1024) {
        throw const FormatException('file_size');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > 12 * 1024 * 1024) {
        throw const FormatException('file_size');
      }
      if (!mounted || !busy) return;
      final StudyPack value;
      if (pdf) {
        final url = Uri.tryParse(generator);
        if (url == null ||
            !url.hasAuthority ||
            !['http', 'https'].contains(url.scheme)) {
          throw const FormatException('configuration');
        }
        final client = http.Client();
        setState(() => request = client);
        final response = await client
            .post(
              url,
              headers: {
                'Content-Type': 'application/pdf',
                'X-Lesson-Title': Uri.encodeComponent(
                  file.name.replaceFirst(
                    RegExp(r'\.pdf$', caseSensitive: false),
                    '',
                  ),
                ),
              },
              body: bytes,
            )
            .timeout(const Duration(seconds: 150));
        if (!mounted || request != client) return;
        if (response.statusCode != 200) {
          throw FormatException(
            response.statusCode == 422 ? 'unreadable' : 'connection',
          );
        }
        value = StudyPack.decode(utf8.decode(response.bodyBytes));
      } else {
        value = StudyPack.decode(utf8.decode(bytes));
      }
      if (value.sample && !pdf) {
        openPack(widget.sample);
      } else {
        final existing = packs[value.id];
        if (existing != null &&
            jsonEncode(existing.json) != jsonEncode(value.json)) {
          throw const FormatException('duplicate');
        }
        packs[value.id] = value;
        openPack(value);
      }
    } catch (cause) {
      if (!mounted ||
          !busy ||
          (pdf && cause is http.ClientException && request == null)) {
        return;
      }
      final code = cause is FormatException ? cause.message : '';
      setState(
        () => error = switch (code) {
          'configuration' => tr(
            'Connect the pack generation service to prepare new PDFs.',
            'Ikonekta ang serbisyo para makagawa ng pack mula sa PDF.',
          ),
          'file_size' => tr(
            'Choose a readable file under 12 MB.',
            'Pumili ng file na mababasa at mas maliit sa 12 MB.',
          ),
          'unreadable' => tr(
            'Use a PDF with selectable text. Scans and locked PDFs cannot be read.',
            'Gumamit ng PDF na may mapipiling teksto. Hindi mabasa ang scan o naka-lock na PDF.',
          ),
          'duplicate' => tr(
            'A different pack with this ID is already saved.',
            'May ibang pack na naka-save gamit ang ID na ito.',
          ),
          _ =>
            pdf
                ? tr(
                    'Could not make the pack. Check your connection and try again.',
                    'Hindi nagawa ang pack. Suriin ang internet at subukan ulit.',
                  )
                : tr(
                    'This file is not a supported KodiGo pack.',
                    'Hindi suportadong KodiGo pack ang file na ito.',
                  ),
        },
      );
    } finally {
      request?.close();
      request = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> share(StudyPack value, BuildContext anchor) async {
    try {
      final box = anchor.findRenderObject()! as RenderBox;
      final origin = box.localToGlobal(Offset.zero) & box.size;
      final name = value.title.replaceAll(RegExp('[^a-zA-Z0-9-]+'), '-');
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              utf8.encode(jsonEncode(value.json)),
              mimeType: 'application/json',
            ),
          ],
          fileNameOverrides: ['$name.kodigo.json'],
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      if (mounted) {
        message(tr('Could not share this pack.', 'Hindi ma-share ang pack.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !inSession,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && inSession) closeSession();
    },
    child: Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: loading
                ? const CircularProgressIndicator()
                : Column(
                    children: [
                      if (inSession) sessionHeader(),
                      Expanded(
                        child: ListView(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          children: [
                            if (error != null)
                              panel(
                                Text(error!),
                                color: const Color(0xffffeee5),
                              ),
                            if (inSession)
                              ...switch (stage) {
                                'summary' => summary(),
                                'question' => question(),
                                'cards-done' => [
                                  heading(
                                    '${pack.cards.length} ${tr('cards done', 'card ang natapos')}',
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    tr(
                                      'You went through all the vocabulary.',
                                      'Narepaso mo ang lahat ng salita.',
                                    ),
                                  ),
                                ],
                                _ => flashcards(),
                              }
                            else
                              ...switch (tab) {
                                0 => library(),
                                1 => paths(),
                                _ => progress(),
                              },
                          ],
                        ),
                      ),
                      if (!inSession) navigation(),
                      if (stage == 'summary')
                        footer(
                          tr('Start studying', 'Simulang mag-aral'),
                          nextQuestion,
                        ),
                      if (stage == 'question')
                        footer(
                          run!.selected == null
                              ? tr('Choose an answer', 'Pumili ng sagot')
                              : run!.settled
                              ? tr('Continue', 'Magpatuloy')
                              : tr('Try again', 'Subukan ulit'),
                          run!.selected == null
                              ? null
                              : run!.settled
                              ? nextQuestion
                              : () => update(run!.retry),
                        ),
                      if (stage == 'cards') cardActions(),
                      if (stage == 'cards-done')
                        footer(
                          tr('Back to Progress', 'Bumalik sa Pag-unlad'),
                          closeSession,
                        ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );

  Widget heading(String label, {double size = 28}) => Text(
    label,
    style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: ink),
  );
  Widget logo() => Align(
    alignment: Alignment.centerLeft,
    widthFactor: 1,
    child: Image.asset('assets/logo.png', width: 114, semanticLabel: 'KodiGo'),
  );
  Widget panel(
    Widget child, {
    Color color = Colors.white,
    Color? border,
    double padding = 16,
  }) => Container(
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: border == null ? null : Border.all(color: border),
    ),
    child: child,
  );
  Widget button(
    String label,
    VoidCallback? tap, {
    bool outline = false,
  }) => SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: tap,
      style: OutlinedButton.styleFrom(
        backgroundColor: outline ? Colors.white : green,
        foregroundColor: outline ? green : Colors.white,
        disabledBackgroundColor: stroke,
        disabledForegroundColor: muted,
        side: BorderSide(color: tap == null ? stroke : green),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        minimumSize: const Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      child: Text(label, textAlign: TextAlign.center),
    ),
  );

  Widget footer(String label, VoidCallback? tap) => Container(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: stroke)),
    ),
    child: button(label, tap),
  );

  Widget navigation() {
    final labels = [
      tr('Lessons', 'Aralin'),
      tr('Study', 'Mag-aral'),
      tr('Progress', 'Pag-unlad'),
    ];
    return Container(
      color: Colors.white,
      height: 66,
      child: Row(
        children: List.generate(
          labels.length,
          (index) => Expanded(
            child: Semantics(
              selected: tab == index,
              child: InkWell(
                onTap: () => update(() {
                  tab = index;
                  error = null;
                }, top: true),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 27,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tab == index ? green : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      labels[index],
                      style: TextStyle(color: tab == index ? green : muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> library() => [
    Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        logo(),
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 42),
            side: BorderSide.none,
            backgroundColor: stroke,
            selectedBackgroundColor: Colors.white,
            selectedForegroundColor: green,
            foregroundColor: muted,
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          segments: const [
            ButtonSegment(value: 'en', label: Text('English')),
            ButtonSegment(value: 'tl', label: Text('Tagalog')),
          ],
          selected: {locale},
          onSelectionChanged: (choice) => update(() => locale = choice.single),
        ),
      ],
    ),
    const SizedBox(height: 22),
    heading(tr('Add a lesson', 'Magdagdag ng aralin')),
    const SizedBox(height: 16),
    panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(
              'Needs internet once to make the pack.',
              'Kailangan ng internet nang isang beses para gawin ang pack.',
            ),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: green,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            tr(
              'After that, study with no internet.',
              'Pagkatapos, puwede kang mag-aral kahit walang internet.',
            ),
          ),
        ],
      ),
      color: mint,
    ),
    const SizedBox(height: 20),
    Semantics(
      button: true,
      child: InkWell(
        onTap: busy ? null : () => chooseFile(pdf: true),
        borderRadius: BorderRadius.circular(16),
        child: CustomPaint(
          foregroundPainter: const _DashedOutline(),
          child: panel(
            Column(
              children: [
                const CircleAvatar(
                  backgroundColor: green,
                  foregroundColor: Colors.white,
                  child: Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                heading(
                  tr(
                    'Choose a file from your phone',
                    'Pumili ng file mula sa phone mo',
                  ),
                  size: 18,
                ),
                const SizedBox(height: 5),
                const Text('PDF'),
              ],
            ),
          ),
        ),
      ),
    ),
    const SizedBox(height: 20),
    button(
      tr('Open a pack file', 'Magbukas ng pack file'),
      busy ? null : () => chooseFile(pdf: false),
      outline: true,
    ),
    if (busy) ...[
      const SizedBox(height: 14),
      const LinearProgressIndicator(),
      TextButton(
        onPressed: request == null
            ? null
            : () {
                final client = request;
                request = null;
                client?.close();
                setState(() {});
              },
        child: Text(tr('Cancel preparation', 'Kanselahin ang paghahanda')),
      ),
    ],
    const SizedBox(height: 20),
    heading(tr('Your study packs', 'Mga study pack mo'), size: 15),
    const SizedBox(height: 10),
    ...packs.values.map(
      (value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                type: MaterialType.transparency,
                child: ListTile(
                  onTap: () => openPack(value),
                  title: heading(value.title, size: 16),
                  subtitle: Text(
                    '${value.sample ? tr('Sample · ', 'Halimbawa · ') : ''}'
                    '${value.advertisedCount} ${tr('questions · saved on phone', 'tanong · naka-save sa phone')}',
                  ),
                  trailing: Text(
                    tr('Study', 'Mag-aral'),
                    style: const TextStyle(
                      color: green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, color: stroke),
              Builder(
                builder: (context) => TextButton.icon(
                  onPressed: () => share(value, context),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: Text(tr('Share', 'I-share')),
                ),
              ),
            ],
          ),
          border: stroke,
          padding: 0,
        ),
      ),
    ),
  ];

  List<Widget> paths() => [
    heading(pack.title),
    const SizedBox(height: 4),
    Text(
      '${pack.advertisedCount} ${tr('questions', 'tanong')} · ${pack.cards.length} ${tr('vocabulary cards', 'vocabulary card')}',
    ),
    const SizedBox(height: 22),
    heading(
      tr('How do you want to study?', 'Paano mo gustong mag-aral?'),
      size: 18,
    ),
    const SizedBox(height: 16),
    modeCard(
      0,
      'CATCH-UP',
      tr('Start from the basics', 'Magsimula sa mga batayan'),
      tr(
        'Simple language, one idea at a time. Good if the lesson is new to you.',
        'Simpleng salita, isang ideya sa bawat hakbang. Para sa bagong aralin.',
      ),
    ),
    const SizedBox(height: 16),
    modeCard(
      1,
      'PRACTICE',
      tr('Test what you know', 'Subukan ang iyong nalalaman'),
      tr(
        "Closer to the exam level. Good if you've already read the lesson.",
        'Mas malapit sa antas ng pagsusulit. Para sa nabasa mo nang aralin.',
      ),
    ),
  ];

  Widget badge(String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: mint,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        label,
        style: const TextStyle(color: green, fontWeight: FontWeight.bold),
      ),
    ),
  );

  Widget modeCard(
    int mode,
    String label,
    String title,
    String description,
  ) => Semantics(
    button: true,
    child: InkWell(
      onTap: () => start(mode),
      borderRadius: BorderRadius.circular(16),
      child: panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge(label),
            const SizedBox(height: 5),
            heading(title, size: 21),
            const SizedBox(height: 4),
            Text(description, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              '${tr('Starts at Level', 'Magsisimula sa Antas')} ${mode + 1}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: muted),
            ),
          ],
        ),
        color: mode == 0 ? mint : Colors.white,
        border: mode == 0 ? green : stroke,
      ),
    ),
  );

  Widget sessionHeader() {
    final current = run!;
    final cards = stage == 'cards';
    final max = cards ? pack.cards.length : current.total;
    final index = cards ? max - current.queue.length + 1 : current.used.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: stroke)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: closeSession,
                tooltip: tr('Close session', 'Isara ang session'),
                icon: const Icon(Icons.close, size: 22),
              ),
              if (stage == 'question' || cards) ...[
                Expanded(
                  child: LinearProgressIndicator(
                    value: (index - 1) / max,
                    minHeight: 9,
                    borderRadius: BorderRadius.circular(8),
                    backgroundColor: stroke,
                  ),
                ),
                const SizedBox(width: 8),
                Text('$index ${tr('of', 'sa')} $max'),
              ],
            ],
          ),
          Row(
            children: [
              Expanded(child: heading(pack.title, size: 16)),
              if (stage == 'question')
                badge('${tr('Level', 'Antas')} ${current.level}'),
            ],
          ),
          Text(
            'ⓘ  ${tr('AI-made, check with your teacher', 'Gawa ng AI, ipasuri sa iyong guro')}',
            style: const TextStyle(color: muted),
          ),
        ],
      ),
    );
  }

  Widget readAloud(String text) => Align(
    alignment: Alignment.centerLeft,
    child: OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        backgroundColor: stage == 'summary' ? mint : Colors.white,
        side: const BorderSide(color: stroke),
        foregroundColor: green,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        minimumSize: Size(stage == 'summary' ? double.infinity : 0, 46),
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => speak(text),
      icon: Icon(speaking ? Icons.stop : Icons.volume_up_outlined, size: 18),
      label: Text(
        speaking
            ? tr('Stop reading', 'Itigil ang pagbasa')
            : tr('Read aloud', 'Basahin nang malakas'),
      ),
    ),
  );

  List<Widget> summary() {
    final index = run!.mode;
    final value = pack.summaries[index];
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: badge(
          '${tr('Level', 'Antas')} ${index + 1} · ${index == 0 ? 'Catch-up' : 'Practice'}',
        ),
      ),
      const SizedBox(height: 12),
      heading(tr('Lesson summary', 'Buod ng aralin'), size: 25),
      const SizedBox(height: 12),
      readAloud(copy(value.text)),
      const SizedBox(height: 16),
      Text(
        copy(value.text),
        style: const TextStyle(fontSize: 18, height: 1.55),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 7,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(tr('From:', 'Mula sa:')),
          for (final id in value.sources) sourceButton(id),
        ],
      ),
    ];
  }

  Widget sourceButton(int id, {bool label = false}) => TextButton(
    onPressed: () => showSource(id),
    style: TextButton.styleFrom(
      backgroundColor: label ? null : mint,
      foregroundColor: green,
      minimumSize: const Size(48, 48),
    ),
    child: Text(
      label ? '${tr('See in lesson', 'Tingnan sa aralin')} ¶$id' : '¶$id',
      semanticsLabel: '${tr('See paragraph', 'Tingnan ang talata')} $id',
    ),
  );

  Future<void> showSource(int id) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .65,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: heading(
                      '${tr('FROM THE LESSON', 'MULA SA ARALIN')}  ¶$id',
                      size: 15,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: tr('Close', 'Isara'),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    pack.paragraphs[id - 1],
                    style: const TextStyle(fontSize: 18, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> question() {
    final current = run!;
    final question = current.question;
    final answered = current.selected != null;
    final hint = answered && !current.settled;
    return [
      heading(copy(question.prompt), size: 22),
      const SizedBox(height: 8),
      readAloud(
        [copy(question.prompt), ...question.options.map(copy)].join('. '),
      ),
      const SizedBox(height: 12),
      ...List.generate(question.options.length, (index) {
        final marked = current.selected == index;
        final right = current.settled && index == question.key;
        final color = right
            ? green
            : marked
            ? const Color(0xff9b4e2f)
            : muted;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Semantics(
            button: true,
            selected: marked,
            child: InkWell(
              onTap: answered
                  ? null
                  : () => update(() => current.answer(index)),
              borderRadius: BorderRadius.circular(16),
              child: panel(
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: marked || right ? color : paper,
                      foregroundColor: marked || right ? Colors.white : ink,
                      child: Text(
                        right
                            ? '✓'
                            : marked
                            ? '×'
                            : String.fromCharCode(65 + index),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        copy(question.options[index]),
                        style: TextStyle(
                          fontSize: 17,
                          color: answered && !marked && !right ? muted : ink,
                        ),
                      ),
                    ),
                  ],
                ),
                border: marked || right ? color : stroke,
                color: right
                    ? mint
                    : marked
                    ? const Color(0xffffeee5)
                    : Colors.white,
                padding: 13,
              ),
            ),
          ),
        );
      }),
      if (answered)
        panel(
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading(
                  hint
                      ? '${tr('HINT', 'PAHIWATIG')} ${current.wrong} ${tr('OF', 'SA')} 2'
                      : current.correct
                      ? tr('Correct!', 'Tama!')
                      : tr("HERE'S THE ANSWER", 'ITO ANG SAGOT'),
                  size: 18,
                ),
                const SizedBox(height: 6),
                Text(
                  copy(
                    hint
                        ? question.hints[current.wrong - 1]
                        : question.explanation,
                  ),
                  style: const TextStyle(fontSize: 16),
                ),
                sourceButton(question.source, label: true),
              ],
            ),
          ),
          color: current.correct ? mint : const Color(0xffffeee5),
        ),
    ];
  }

  List<Widget> flashcards() {
    final current = run!;
    final card = pack.cards[current.queue.first];
    return [
      const SizedBox(height: 24),
      Semantics(
        button: true,
        label: current.flipped
            ? tr(
                'Showing Filipino side. Tap to flip.',
                'Nasa panig na Filipino. I-tap para baliktarin.',
              )
            : tr(
                'Showing English side. Tap to flip.',
                'Nasa panig na English. I-tap para baliktarin.',
              ),
        child: InkWell(
          onTap: () => update(current.flip),
          borderRadius: BorderRadius.circular(16),
          child: panel(
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 54),
                child: Column(
                  children: [
                    badge(current.flipped ? 'FILIPINO' : 'ENGLISH'),
                    const SizedBox(height: 12),
                    heading(current.flipped ? card.tl : card.en, size: 30),
                    const SizedBox(height: 10),
                    Text(
                      current.flipped
                          ? copy(card.definition)
                          : tr('Tap to flip', 'I-tap para baliktarin'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            color: current.flipped ? mint : Colors.white,
            border: stroke,
          ),
        ),
      ),
    ];
  }

  Widget cardActions() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: button(
                tr('Show again', 'Ipakita ulit'),
                () => update(() => run!.rate(false)),
                outline: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: button(
                tr('Got it', 'Nakuha ko'),
                () => update(() => run!.rate(true)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${run!.queue.length} ${tr('cards remaining', 'card ang natitira')}',
        ),
      ],
    ),
  );

  List<Widget> progress() {
    final values = mastery[pack.id] ?? {};
    final labels = [
      tr('Main idea', 'Pangunahing ideya'),
      tr('Detail', 'Detalye'),
      tr('Vocabulary', 'Talasalitaan'),
      tr('Inference', 'Paghihinuha'),
    ];
    return [
      logo(),
      const SizedBox(height: 16),
      heading(tr('Your progress', 'Ang iyong pag-unlad')),
      const SizedBox(height: 4),
      Text(pack.title),
      const SizedBox(height: 16),
      for (var i = 0; i < skills.length; i++) ...[
        masteryRow(labels[i], values[skills[i]] ?? [0, 0]),
        const SizedBox(height: 10),
      ],
      if (values.isEmpty)
        Text(
          tr(
            'No questions answered yet. Pick a path to start.',
            'Wala ka pang nasagot. Pumili ng paraan para magsimula.',
          ),
        ),
      if (values.isNotEmpty)
        Text(
          '${values.values.fold<int>(0, (count, value) => count + value[1])} '
          '${tr('questions answered across all sessions.', 'tanong ang nasagot sa lahat ng session.')}',
        ),
      const SizedBox(height: 16),
      button(
        tr('Study again', 'Mag-aral ulit'),
        () => update(() {
          run = null;
          tab = 1;
        }, top: true),
      ),
      const SizedBox(height: 10),
      button(
        tr('Flashcards', 'Mga flashcard'),
        () => update(() {
          run = StudyRun(pack, 0)..stage = 'cards';
        }, top: true),
        outline: true,
      ),
    ];
  }

  Widget masteryRow(String title, List<int> counts) {
    final count = counts[1];
    final score = count == 0 ? 0.0 : counts[0] / count;
    final description = count == 0
        ? ' · ${tr('not started yet', 'hindi pa nagsisimula')}'
        : '';
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(title, size: 16),
          Text('${(score * 100).round()}%$description'),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: score,
            minHeight: 8,
            semanticsLabel: title,
            borderRadius: BorderRadius.circular(8),
            backgroundColor: stroke,
          ),
        ],
      ),
      border: stroke,
    );
  }
}

class _DashedOutline extends CustomPainter {
  const _DashedOutline();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          const Radius.circular(16),
        ),
      );
    final paint = Paint()
      ..color = green
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 8) {
        canvas.drawPath(metric.extractPath(start, start + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline oldDelegate) => false;
}
