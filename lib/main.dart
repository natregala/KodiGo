import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens.dart';
import 'study.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sample = StudyPack.decode(
    await rootBundle.loadString('assets/water_cycle.json'),
  );
  runApp(KodiGo(sample: sample, storage: SharedPreferencesAsync()));
}

class KodiGo extends StatelessWidget {
  const KodiGo({super.key, required this.sample, required this.storage});
  final StudyPack sample;
  final SharedPreferencesAsync storage;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'KodiGo',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        primary: green,
        surface: paper,
      ),
      scaffoldBackgroundColor: paper,
      fontFamily: 'Atkinson Hyperlegible',
    ),
    home: StudyHome(sample: sample, storage: storage),
  );
}
