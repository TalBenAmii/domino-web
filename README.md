# דיבור לטקסט — Hebrew Speech-to-Text

A dead-simple, single-screen Flutter app: tap one button, speak Hebrew, see the
text appear in real time. Cross-platform (Android + iOS) with a single codebase
and exactly **one** third-party dependency (`speech_to_text`).

- Material 3 UI, right-to-left Hebrew layout, animated pulsing mic button.
- Live partial results + accumulated final transcript, copy & clear actions.
- Cloud/online recognition via the native engines (Apple Speech / Android
  `SpeechRecognizer`). Hebrew locale is resolved at runtime.

## Project layout

| File | Purpose |
|------|---------|
| `lib/main.dart` | The entire app — UI + speech logic |
| `pubspec.yaml` | One dependency: `speech_to_text` |
| `android/app/src/main/AndroidManifest.xml` | `RECORD_AUDIO` + `INTERNET` + `RecognitionService` query |
| `ios/Runner/Info.plist` | Microphone & speech-recognition usage descriptions |
| `ios/Podfile` | iOS 13.0 deployment target |
| `codemagic.yaml` | Mac-less iOS (TestFlight) cloud build + optional Android APK |

## Toolchain (already installed on this machine)

Flutter SDK at `~/flutter`, Android SDK at `~/Android/sdk`, JDK 17. The
environment lives in `~/.flutterenv` (and at the top of `~/.bashrc` for
interactive shells). In a script, run `source ~/.flutterenv` first.

```bash
source ~/.flutterenv
flutter doctor          # Android toolchain should be green
```

## Run on Android (you build these locally on WSL)

A ready-to-sideload release APK is already built:

```
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   # most modern phones
```

Rebuild any time with:

```bash
source ~/.flutterenv
flutter build apk --release --split-per-abi
```

Install on your phone — pick one:

1. **Sideload (simplest):** copy `app-arm64-v8a-release.apk` to the phone and
   tap it (enable "install unknown apps").
2. **Wireless ADB (live hot reload):** enable Wireless debugging on the phone,
   then `adb connect <PHONE_IP>:<PORT>` and `flutter run`.
3. **USB via usbipd:** on Windows (admin PowerShell) `usbipd bind/attach --wsl`
   the phone, then `adb devices` → `flutter run`.

> Hebrew on Android needs the Google Speech Services Hebrew pack. If recognition
> is unavailable, add Hebrew under **Settings → Google → Voice → Languages**.

## Build for iOS (no Mac — via Codemagic)

iOS signing/builds happen in the cloud. See the setup checklist at the top of
`codemagic.yaml`. In short:

1. Push this repo to GitHub/GitLab.
2. Enroll in the **Apple Developer Program ($99/yr)** — required to install on a
   physical iPhone without a Mac.
3. Create the app in App Store Connect; create an App Store Connect API key and
   add it to Codemagic as `CodemagicASCKey`.
4. Connect the repo in Codemagic and run the **iOS – TestFlight** workflow;
   install on your iPhone via TestFlight.

## Verify it works

Run on a real device, tap the mic, grant the permission prompt, and speak
Hebrew. Words appear live (right-aligned, RTL) and commit to the transcript when
you pause or tap stop.
