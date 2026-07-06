# Migration Notes

## Step 1: Source Inventory

Key React Native / Expo imports and exports reviewed:

- `expo-router`: `Stack`, `Tabs`, `router.push`, `router.replace`, `useSegments`
- `expo-font` and `expo-splash-screen`: SpaceMono loading and splash control
- `expo-secure-store`: auth token, encryption key, local general sleep data
- `expo-sqlite`: local `journals` and `sensor_data` tables
- `expo-sensors`: `Accelerometer`, `LightSensor`
- `expo-av`: `Audio.Recording`
- `expo-crypto`: UUID generation
- `@react-native-async-storage/async-storage`: auth/profile/transparency persistence
- `zustand`: `authStore`, `userProfileStore`, `transparencyStore`
- `react-native-walkthrough-tooltip`: privacy tooltip placement
- `@expo/vector-icons/Ionicons`: tab and action icons
- Source service exports from `frontend/services/index.ts`: repositories, data sources, sensor services, background task manager, transparency service

Async patterns reviewed:

- Store hydration on app startup: auth, profile, transparency state
- Repository calls returning encrypted/decrypted domain models
- Fire-and-forget transparency AI analysis after journal/sensor updates
- Timer/interval loops for audio simulation, light simulation, accelerometer simulation, clock, and long-press wake flow
- SQLite `prepareAsync`/`executeAsync`/`getAllAsync` flows
- SecureStore read/write/delete flows
- HTTP `fetch` with token-bearing JSON requests

## Step 2: Dart Equivalents

- Expo Router -> `go_router ^14` with `ShellRoute` for tab navigation
- Zustand -> `flutter_bloc ^8`; Cubit for auth/profile, full `TransparencyBloc` for six atomic transparency channels
- AsyncStorage -> `shared_preferences`
- SecureStore -> `flutter_secure_storage ^9`
- Expo SQLite -> `sqflite ^2`, preserving `journals` and `sensor_data` table/column names
- CryptoJS AES -> `pointycastle ^3` AES-CBC-PKCS7 with PBKDF2 key derivation
- Expo Sensors accelerometer -> `sensors_plus ^4`
- Expo LightSensor -> graceful stub and simulated fallback; `sensors_plus ^4.0.2` has no ambient-light API
- Expo AV recording -> `record ^5`
- Expo background task placeholder -> `flutter_background_service ^5` foreground service with persistent Android notification
- Expo Linking -> `url_launcher`
- Expo Crypto UUID -> `uuid`

## Platform Flags

- `MIGRATION_FLAG`: The source encryption code stored a random base64 AES key directly; the target spec requires PBKDF2. The Flutter code uses PBKDF2 for new records and falls back to the raw key path when decrypting legacy source records.
- `MIGRATION_FLAG`: `sensors_plus ^4.0.2` does not expose an ambient-light stream. iOS shows `SensorNotAvailableWidget`; Android currently uses the simulated fallback until a native light-sensor plugin/module is added.
- `MIGRATION_FLAG`: iOS background collection remains constrained by iOS background execution policy even though `UIBackgroundModes` mirrors the Expo app.
