# KodiGo

KodiGo turns a lesson PDF into an English–Tagalog study pack for Android and iOS. After preparation, summaries, original paragraph citations, adaptive questions, flashcards and progress work from data on the phone.

## Run the app

From the project directory, run `flutter pub get` and `flutter run -d <device-id>`. Find available IDs with `flutter devices`. The Water Cycle example and pack import work without configuring a generator.

To preview the app in Chrome, run `flutter run -d chrome` from the project directory.

Android debug APK — `flutter build apk --debug`. The iOS app targets iOS 14 and later. On a Mac with Xcode, run `open -a Simulator`, then `flutter devices` and `flutter run -d <simulator-id>`. To build the iOS simulator app separately, run `flutter build ios --simulator`.

## Prepare new PDFs

Install the backend dependency with `python -m pip install -r backend/requirements.txt`. Configure `OPENAI_API_KEY` and `KODIGO_MODEL` in the backend process environment. Choose an available Responses API model with JSON output support, for example `gpt-4.1-mini`. Run `python backend/server.py` to listen on port 8080 on the local development machine.

For the Android emulator, run:

```powershell
flutter run -d emulator-5554 --dart-define=KODIGO_GENERATOR_URL=http://10.0.2.2:8080/generate
```

For iOS and physical devices, give the app an HTTPS generator URL reachable from the device. The bundled server is for local development. Put remote access behind an authenticated, rate-limited HTTPS gateway before making it available to students. Keep the provider key in the backend environment. Preparing a lesson sends the selected PDF to the backend, which extracts and submits its text to the model. It accepts text-based PDFs up to 12 MB, 40 pages and 35,000 characters. Use a PDF with selectable text for scanned material.

## Study and transfer

Catch-up starts at Level 1 and Practice starts at Level 2. Three consecutive first-try correct answers raise the level. Two consecutive exhausted questions lower it. Each completed question contributes one mastery result to its tagged skill. The student can reopen the app at the current question and hint stage.

Share saves a versioned KodiGo JSON pack through the device share sheet. Use **Open a pack file** on the receiving device to import it. The file carries the study material and exact stored excerpts. Session history and mastery stay on the original device.

## Verify

Run `flutter analyze` and `flutter test`. Use this student walkthrough for platform testing and the proposal's evaluation:

1. Prepare a new study pack from a short teacher-provided PDF with selectable text. Check a summary citation and a question-feedback citation against the PDF.
2. Start Catch-up. Trigger the two hints, leave the app mid-question, enable airplane mode and reopen it. Verify the question and hint survive. Finish the session and check each skill's progress.
3. Start Practice and confirm the Level 2 starting point. Switch the interface to Tagalog, then review the English and Filipino sides of a card. Use **Show again** and verify the card returns.
4. Share a pack file and import it on a clean installation. Check summary, citations and cards offline. Then try an invalid pack and verify existing lessons remain available.
5. Ask each of the 20 participants to rate the interface, core features including offline saving and bilingual support, and overall usability. The proposal targets at least 16 favorable ratings.

## Reference behavior

The five Water Cycle questions follow the verified sample paths. The sample header uses eight as the display maximum, while the session ends when its five questions are used. Generated lessons use their own question count. The mockup supplies the wordmark, type, color palette, layout and reference flow. Native file picking, speech and sharing use the device's system interfaces.
