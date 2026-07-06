# Sleep Tracker — GPT-5.5 → Flutter Migration

> **Thesis artifact 2 of 7.** This repository is one implementation from a McMaster University M.Sc. thesis studying whether AI coding agents can migrate a mobile health app across frameworks without degrading usability. See [Thesis citation](#thesis-citation) and [Related repositories](#related-repositories) below.

Flutter/Dart rewrite of the original React Native "Sleep Tracker" privacy-transparency app, produced by **GPT-5.5** under a shared 15-rule migration prompt. It talks to the same Node.js/Express backend as the original app (see [thesis-privacy-baseline](https://github.com/MelvinMo/thesis-privacy-baseline)).

---

## Usability findings (from the thesis)

This migration was evaluated with Nielsen's ten usability heuristics across six standardized tasks by a single assessor (severity 0–4, lower is better). Full detail is in **Chapter 5** of the thesis (App 2).

| Metric | Value |
|---|---|
| Aggregate severity total | **20** |
| vs. baseline (React Native, total 16) | **+4** |
| Rank among all 7 implementations | **Tied 4th of 7** (tied with the GPT-5.5 KMP migration) |

The entire application is a single 9,477-line Dart file — models, BLoCs, services, screens, widgets, routing, and encrypted database access all share one compilation unit. This is the only GPT-5.5 migration to improve on any heuristic (H8, Aesthetic and Minimalist Design): its privacy tooltip scrolls cleanly, avoiding a gesture conflict present in the source app. That gain is offset by regressions in status visibility, user control, error prevention, recognition, and error recovery. Its privacy tooltip is also the most complete of the three GPT-5.5 migrations — four tappable links (PIPEDA regulation, Privacy Policy section, Opt Out, and View Full Privacy Policy) are wired to named routes. See the thesis for the full per-heuristic breakdown and screenshots.

---

## Related repositories

| Repo | Description |
|---|---|
| [thesis-privacy-baseline](https://github.com/MelvinMo/thesis-privacy-baseline) | Original React Native app (unmodified snapshot) |
| [thesis-privacy-sonnet46-kmp](https://github.com/MelvinMo/thesis-privacy-sonnet46-kmp) | Claude Sonnet 4.6 → KMP |
| [thesis-privacy-sonnet46-flutter](https://github.com/MelvinMo/thesis-privacy-sonnet46-flutter) | Claude Sonnet 4.6 → Flutter |
| [thesis-privacy-sonnet46-maui](https://github.com/MelvinMo/thesis-privacy-sonnet46-maui) | Claude Sonnet 4.6 → .NET MAUI |
| [thesis-privacy-gpt55-kmp](https://github.com/MelvinMo/thesis-privacy-gpt55-kmp) | GPT-5.5 → KMP |
| **thesis-privacy-gpt55-flutter** | **This repo** — GPT-5.5 → Flutter |
| [thesis-privacy-gpt55-maui](https://github.com/MelvinMo/thesis-privacy-gpt55-maui) | GPT-5.5 → .NET MAUI |

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Flutter SDK | 3.x | https://docs.flutter.dev/get-started/install |
| Android Studio | latest | Android SDK + platform tools |
| Xcode 14+ | latest (Mac only) | for iOS builds |

Verify your setup:
```bash
flutter doctor
adb version
```

---

## 1. Install dependencies

```bash
flutter pub get
```

Optionally verify the project:
```bash
flutter analyze
flutter test
```

---

## 2. Connect a device

**USB:**
1. Enable Developer Options (Settings → About Phone → tap Build Number 7 times).
2. Enable **USB Debugging**, plug in via USB, and accept the debugging prompt on the phone.
3. Confirm:
```bash
adb devices
flutter devices
```

**Wireless (Android 11+):**
1. On the phone: **Developer Options → Wireless debugging** → enable → **Pair device with pairing code** (note the IP, port, and code shown).
2. Pair once from your computer:
```bash
adb pair <phone-ip>:<pairing-port>
```
3. Connect using the main IP & port shown on the Wireless Debugging screen (different from the pairing port):
```bash
adb connect <phone-ip>:<wireless-debugging-port>
adb devices
flutter devices
```

**Older devices without wireless debugging (USB bootstrap):**
```bash
adb devices                  # confirm USB connection first
adb tcpip 5555
adb connect <phone-ip>:5555  # after unplugging USB
```

---

## 3. Point the app at a backend

Copy the example file for reference values:
```bash
cp .env.example .env
```

```bash
flutter run \
  --dart-define=API_ENCRYPTED_URL=https://<your-backend-host> \
  --dart-define=API_UNENCRYPTED_URL=http://<your-computer's-LAN-IP>:7000/api
```

- On the Android **emulator**, use `10.0.2.2` in place of your LAN IP (it aliases the host machine's `localhost`).
- On a **physical device**, use your computer's actual LAN IP (find it with `ipconfig` on Windows or `ifconfig` on Mac).
- To run the backend locally, see [thesis-privacy-baseline](https://github.com/MelvinMo/thesis-privacy-baseline).

If more than one device is connected, target one explicitly:
```bash
flutter devices
flutter run -d <device-id> --dart-define=API_ENCRYPTED_URL=https://<your-backend-host>
```

---

## 4. Build and install a release/debug APK directly

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell monkey -p com.mcscert.sleeptracker.flutterdev 1
```

Debug builds install under the app ID `com.mcscert.sleeptracker.flutterdev` (kept distinct from release builds, `com.mcscert.sleeptracker`, so this can coexist with other builds during development).

---

## Permissions required at runtime

The app may request **Microphone** (sleep audio monitoring), **Notifications** (foreground service visibility), and **Activity recognition / sensor** permissions depending on Android version — accept these when testing sensor and sleep-mode flows.

---

## Project structure

```
├── lib/
│   └── main.dart          # Entire app: models, BLoCs, services, screens, widgets, routing, DB
├── android/                # Android native project
├── ios/                    # iOS native project (Mac only)
├── .env.example             # Backend URL reference values (see Section 3)
└── .gitignore
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Wireless ADB won't connect | `adb kill-server && adb start-server`, then `adb connect <ip>:<port>` again |
| Multiple devices listed | `flutter run -d <device-id>` |
| VPN or network isolation blocks ADB | Disable VPN; ensure phone and computer share the same Wi-Fi network |
| Wireless debugging port changed | Recheck the port on the phone's Wireless Debugging screen; keep that screen open while pairing |

---

## Known limitations (from the thesis)

- The entire application is implemented in a single 9,477-line file rather than split into conventional `lib/models/`, `lib/blocs/`, `lib/screens/`, `lib/services/` directories.
- H8 (Aesthetic and Minimalist Design) is the only heuristic that improved over baseline; H1, H3, H5, H6, and H9 all regressed.
- See Chapter 5 of the thesis for the full task-by-task and heuristic-by-heuristic severity breakdown, including the two other GPT-5.5 migrations (KMP, MAUI).

---

## Environment variables & secrets

This repository contains **no real credentials**. `.env.example` holds placeholder/reference values only (a backend URL, not a secret). If you deploy your own backend, keep its real `.env` (JWT secret, database/Firebase keys, LLM API keys) out of version control — it's already covered by `.gitignore`.

---

## Thesis citation

If you reference this artifact, please cite:

> Mokhtari, M. (2026). *"Who Moved My Button?": A Usability Evaluation of LLM-Assisted Cross-Platform Migration* [Master's thesis, McMaster University]. Department of Computing and Software. Supervisor: Richard F. Paige.

---

## License

All rights reserved. This repository is published for academic review and reproducibility alongside the thesis above. No license is granted for reuse, modification, or redistribution without permission from the author.
