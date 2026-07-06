import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

// MIGRATION: Expo app.json fixed the app to portrait. Flutter needs this
//            platform behavior set before runApp, otherwise Android/iOS allow
//            rotations that the source UI never designed for.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  // MIGRATION: Expo BackgroundFetch/TaskManager is replaced with
  //            flutter_background_service so Android 8+ receives a persistent
  //            foreground notification while accelerometer collection is active.
  await configureBackgroundService();

  final SharedPreferences preferences = await SharedPreferences.getInstance();
  const FlutterSecureStorage secureStorage = FlutterSecureStorage();
  final LocalDatabaseManager databaseManager = LocalDatabaseManager.instance;
  await databaseManager.openDatabase();

  final AuthCubit authCubit = AuthCubit(
    preferences: preferences,
    secureStorage: secureStorage,
    httpClient: CloudStorageService(apiBaseUrl),
  );
  final ProfileCubit profileCubit = ProfileCubit(preferences: preferences);
  final TransparencyBloc transparencyBloc = TransparencyBloc(
    preferences: preferences,
  );

  await authCubit.checkAuth();
  await profileCubit.loadProfileStatus();
  transparencyBloc.add(const LoadTransparencyStatus());

  final AppServices services = AppServices.create(
    authCubit: authCubit,
    profileCubit: profileCubit,
    transparencyBloc: transparencyBloc,
    databaseManager: databaseManager,
    secureStorage: secureStorage,
  );

  // MIGRATION: Source root layout starts background accelerometer after profile
  //            and transparency stores load. The Flutter app does the same from
  //            main because providers are already constructed here.
  await services.sensorBackgroundTaskManager.updateConfig(
    SensorServiceConfigPatch(
      accelerometerEnabled:
          profileCubit.state.userConsentPreferences.accelerometerEnabled,
    ),
  );
  await services.sensorBackgroundTaskManager.registerAccelerometer();

  runApp(
    SleepTrackerApp(
      authCubit: authCubit,
      profileCubit: profileCubit,
      transparencyBloc: transparencyBloc,
      services: services,
    ),
  );
}

const bool inDemoMode = true;

// MIGRATION: Expo env vars become compile-time Dart defines. Defaults mirror
//            local Android emulator access and deployed HTTPS behavior.
const String encryptedApiBaseUrl = String.fromEnvironment(
  'API_ENCRYPTED_URL',
  defaultValue: 'https://example.com',
);
const String unencryptedApiBaseUrl = String.fromEnvironment(
  'API_UNENCRYPTED_URL',
  defaultValue: 'http://10.0.2.2:7000/api',
);
const String apiBaseUrl = inDemoMode
    ? (TransparencyDemoConfig.encryptedInTransit
          ? encryptedApiBaseUrl
          : unencryptedApiBaseUrl)
    : encryptedApiBaseUrl;

StreamSubscription<AccelerometerEvent>? _backgroundAccelerometerSubscription;

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  // MIGRATION_FLAG: iOS background execution remains bounded by iOS fetch/audio
  //                 rules; this mirrors the Expo app's UIBackgroundModes but
  //                 cannot guarantee continuous sensor capture on all devices.
  return true;
}

@pragma('vm:entry-point')
void onAndroidBackgroundServiceStart(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'GPT Sleep Tracker Flutter',
      content: 'Monitoring sleep movement',
    );
  }

  service.on('stopService').listen((Map<String, dynamic>? event) async {
    await _backgroundAccelerometerSubscription?.cancel();
    _backgroundAccelerometerSubscription = null;
    await service.stopSelf();
  });

  service.on('startAccelerometer').listen((Map<String, dynamic>? event) {
    _backgroundAccelerometerSubscription?.cancel();
    final int samplingSeconds = event?['samplingSeconds'] is int
        ? event!['samplingSeconds'] as int
        : 15;

    // MIGRATION: Expo Accelerometer.setUpdateInterval is translated to
    //            sensors_plus' samplingPeriod stream argument.
    _backgroundAccelerometerSubscription =
        accelerometerEventStream(
          samplingPeriod: Duration(seconds: samplingSeconds),
        ).listen((AccelerometerEvent sample) {
          final double magnitude = sqrt(
            sample.x * sample.x + sample.y * sample.y + sample.z * sample.z,
          );
          service.invoke('accelerometerSample', <String, dynamic>{
            'x': sample.x,
            'y': sample.y,
            'z': sample.z,
            'magnitude': magnitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        });
  });
}

Future<void> configureBackgroundService() async {
  final FlutterBackgroundService service = FlutterBackgroundService();
  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onBackground: onIosBackground,
      onForeground: onAndroidBackgroundServiceStart,
    ),
    androidConfiguration: AndroidConfiguration(
      onStart: onAndroidBackgroundServiceStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      initialNotificationTitle: 'GPT Sleep Tracker Flutter',
      initialNotificationContent: 'Monitoring sleep movement',
      foregroundServiceNotificationId: 53079,
      foregroundServiceTypes: const <AndroidForegroundType>[
        AndroidForegroundType.health,
      ],
    ),
  );
}

class AppColors {
  static const Color appBackground = Color(0xFF1A1A2E);
  static const Color accent = Color(0xFF4A90D9);
  static const Color inputFieldBackground = Color(0xFF5B5775);
  static const Color inputFieldPlaceholder = Color(0xFFAFA3BF);
  static const Color inputFieldSelected = Color(0xFFF2D8A7);
  static const Color hyperlinkBlue = Color(0xFF4A90E2);
  static const Color tooltipLinkBlue = Color(0xFF1A365D);
  static const Color generalBlue = Color(0xFF39ACE7);
  static const Color lightBlack = Color(0xFF181719);
  static const Color tooltipGreen = Color(0xFFE0FFDF);
  static const Color tooltipRed = Color(0xFFFD8686);
  static const Color tooltipYellow = Color(0xFFFFFD86);
  static const Color grey = Color(0x80EBEBF5);
  static const Color lightGrey = Color(0xFF888888);
}

class TransparencyUiConfig {
  const TransparencyUiConfig({
    required this.journalTooltipEnabled,
    required this.sleepPageTooltipEnabled,
    required this.sleepModeTooltipEnabled,
  });

  final bool journalTooltipEnabled;
  final bool sleepPageTooltipEnabled;
  final bool sleepModeTooltipEnabled;
}

const TransparencyUiConfig transparencyUiConfig = TransparencyUiConfig(
  journalTooltipEnabled: true,
  sleepPageTooltipEnabled: true,
  sleepModeTooltipEnabled: true,
);

class TransparencyDemoConfig {
  static const bool collectAudio = false;
  static const bool collectLight = false;
  static const bool collectAccelerometer = false;
  static const bool encryptedAtRest = false;
  static const bool encryptedInTransit = false;
}

enum DataType {
  sensorAudio('SENSOR_AUDIO'),
  sensorMotion('SENSOR_MOTION'),
  sensorLight('SENSOR_LIGHT'),
  userJournal('USER_JOURNAL'),
  userProfile('USER_PROFILE'),
  generalSleep('GENERAL_SLEEP'),
  sleepStatistics('SLEEP_STATISTICS'),
  deviceInfo('DEVICE_INFO'),
  location('LOCATION'),
  usageAnalytics('USAGE_ANALYTICS');

  const DataType(this.wireName);
  final String wireName;

  static DataType fromWire(String? value) {
    return DataType.values.firstWhere(
      (DataType item) => item.wireName == value,
      orElse: () => DataType.userJournal,
    );
  }
}

enum DataSource {
  microphone('MICROPHONE'),
  accelerometer('ACCELEROMETER'),
  lightSensor('LIGHT_SENSOR'),
  userInput('USER_INPUT'),
  derivedData('DERIVED_DATA'),
  systemInfo('SYSTEM_INFO');

  const DataSource(this.wireName);
  final String wireName;

  static DataSource fromWire(String? value) {
    return DataSource.values.firstWhere(
      (DataSource item) => item.wireName == value,
      orElse: () => DataSource.userInput,
    );
  }
}

enum DataDestination {
  asyncStorage('ASYNC_STORAGE'),
  secureStore('SECURE_STORE'),
  sqliteDb('SQLITE_DB'),
  memory('MEMORY'),
  googleCloud('GOOGLE_CLOUD'),
  thirdParty('THIRD_PARTY');

  const DataDestination(this.wireName);
  final String wireName;

  static DataDestination? fromWire(String? value) {
    if (value == null) {
      return null;
    }
    return DataDestination.values.firstWhere(
      (DataDestination item) => item.wireName == value,
      orElse: () => DataDestination.memory,
    );
  }
}

enum EncryptionMethod {
  none('NONE'),
  aes256('AES_256'),
  jwt('JWT'),
  deviceKeychain('DEVICE_KEYCHAIN');

  const EncryptionMethod(this.wireName);
  final String wireName;

  static EncryptionMethod? fromWire(String? value) {
    if (value == null) {
      return null;
    }
    return EncryptionMethod.values.firstWhere(
      (EncryptionMethod item) => item.wireName == value,
      orElse: () => EncryptionMethod.none,
    );
  }
}

enum PrivacyRisk {
  low('LOW', 0),
  medium('MEDIUM', 1),
  high('HIGH', 2);

  const PrivacyRisk(this.wireName, this.order);
  final String wireName;
  final int order;

  static PrivacyRisk fromWire(String? value) {
    return PrivacyRisk.values.firstWhere(
      (PrivacyRisk item) => item.wireName == value,
      orElse: () => PrivacyRisk.low,
    );
  }
}

enum RegulatoryFramework {
  pipeda('PIPEDA'),
  phipa('PHIPA'),
  gdpr('GDPR');

  const RegulatoryFramework(this.wireName);
  final String wireName;

  static RegulatoryFramework fromWire(String? value) {
    return RegulatoryFramework.values.firstWhere(
      (RegulatoryFramework item) => item.wireName == value,
      orElse: () => RegulatoryFramework.pipeda,
    );
  }
}

enum TransparencyChannel {
  light('lightSensorTransparency'),
  microphone('microphoneTransparency'),
  accelerometer('accelerometerTransparency'),
  journal('journalTransparency'),
  sleep('generalSleepTransparency'),
  statistics('statisticsTransparency');

  const TransparencyChannel(this.storageKey);
  final String storageKey;
}

enum SleepNote {
  pain('Pain'),
  stress('Stress'),
  anxiety('Anxiety'),
  medication('Medication'),
  caffeine('Caffeine'),
  alcohol('Alcohol'),
  warmBath('Warm Bath'),
  heavyMeal('Heavy Meal');

  const SleepNote(this.label);
  final String label;

  static SleepNote fromLabel(String value) {
    return SleepNote.values.firstWhere(
      (SleepNote item) => item.label == value,
      orElse: () => SleepNote.stress,
    );
  }
}

enum AmbientNoiseLevel {
  quiet('quiet'),
  moderate('moderate'),
  loud('loud'),
  veryLoud('very_loud');

  const AmbientNoiseLevel(this.wireName);
  final String wireName;

  static AmbientNoiseLevel fromWire(String? value) {
    return AmbientNoiseLevel.values.firstWhere(
      (AmbientNoiseLevel item) => item.wireName == value,
      orElse: () => AmbientNoiseLevel.quiet,
    );
  }
}

enum LightLevel {
  dark('dark'),
  dim('dim'),
  moderate('moderate'),
  bright('bright');

  const LightLevel(this.wireName);
  final String wireName;

  static LightLevel fromWire(String? value) {
    return LightLevel.values.firstWhere(
      (LightLevel item) => item.wireName == value,
      orElse: () => LightLevel.dark,
    );
  }
}

enum MovementIntensity {
  still('still'),
  light('light'),
  moderate('moderate'),
  active('active');

  const MovementIntensity(this.wireName);
  final String wireName;

  static MovementIntensity fromWire(String? value) {
    return MovementIntensity.values.firstWhere(
      (MovementIntensity item) => item.wireName == value,
      orElse: () => MovementIntensity.still,
    );
  }
}

Map<String, Object?> stringMapFromJson(String jsonText) {
  final Object? decoded = jsonDecode(jsonText);
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  return <String, Object?>{};
}

List<String> stringListFromObject(Object? raw) {
  if (raw is List<Object?>) {
    return raw.whereType<String>().toList(growable: false);
  }
  return const <String>[];
}

String? nullableString(Object? value) => value is String ? value : null;

bool? nullableBool(Object? value) => value is bool ? value : null;

int? nullableInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

class RegulatoryCompliance {
  const RegulatoryCompliance({
    required this.framework,
    required this.compliant,
    required this.issues,
    required this.relevantSections,
  });

  final RegulatoryFramework framework;
  final bool compliant;
  final String issues;
  final List<String> relevantSections;

  factory RegulatoryCompliance.fromJson(Map<String, Object?> json) {
    return RegulatoryCompliance(
      framework: RegulatoryFramework.fromWire(
        nullableString(json['framework']),
      ),
      compliant: nullableBool(json['compliant']) ?? true,
      issues: nullableString(json['issues']) ?? '',
      relevantSections: stringListFromObject(json['relevantSections']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'framework': framework.wireName,
      'compliant': compliant,
      'issues': issues,
      'relevantSections': relevantSections,
    };
  }
}

class AiExplanation {
  const AiExplanation({
    required this.why,
    required this.storage,
    required this.access,
    required this.privacyExplanation,
    required this.privacyPolicyLink,
    required this.regulationLink,
  });

  final String why;
  final String storage;
  final String access;
  final String privacyExplanation;
  final List<String> privacyPolicyLink;
  final List<String> regulationLink;

  factory AiExplanation.fromJson(Map<String, Object?> json) {
    return AiExplanation(
      why: nullableString(json['why']) ?? '',
      storage: nullableString(json['storage']) ?? '',
      access: nullableString(json['access']) ?? '',
      privacyExplanation: nullableString(json['privacyExplanation']) ?? '',
      privacyPolicyLink: stringListFromObject(json['privacyPolicyLink']),
      regulationLink: stringListFromObject(json['regulationLink']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'why': why,
      'storage': storage,
      'access': access,
      'privacyExplanation': privacyExplanation,
      'privacyPolicyLink': privacyPolicyLink,
      'regulationLink': regulationLink,
    };
  }
}

class TransparencyEvent {
  const TransparencyEvent({
    this.timestamp,
    required this.dataType,
    required this.source,
    this.sensorType,
    this.samplingRate,
    this.duration,
    this.encryptionMethod,
    this.storageLocation,
    this.endpoint,
    this.protocol,
    this.backgroundMode,
    this.userConsent,
    this.privacyRisk,
    this.regulatoryCompliance,
    this.aiExplanation,
  });

  final DateTime? timestamp;
  final DataType dataType;
  final DataSource source;
  final String? sensorType;
  final int? samplingRate;
  final int? duration;
  final EncryptionMethod? encryptionMethod;
  final DataDestination? storageLocation;
  final String? endpoint;
  final String? protocol;
  final bool? backgroundMode;
  final bool? userConsent;
  final PrivacyRisk? privacyRisk;
  final RegulatoryCompliance? regulatoryCompliance;
  final AiExplanation? aiExplanation;

  factory TransparencyEvent.fromJson(Map<String, Object?> json) {
    final Object? compliance = json['regulatoryCompliance'];
    final Object? explanation = json['aiExplanation'];
    return TransparencyEvent(
      timestamp: nullableString(json['timestamp']) == null
          ? null
          : DateTime.tryParse(nullableString(json['timestamp'])!),
      dataType: DataType.fromWire(nullableString(json['dataType'])),
      source: DataSource.fromWire(nullableString(json['source'])),
      sensorType: nullableString(json['sensorType']),
      samplingRate: nullableInt(json['samplingRate']),
      duration: nullableInt(json['duration']),
      encryptionMethod: EncryptionMethod.fromWire(
        nullableString(json['encryptionMethod']),
      ),
      storageLocation: DataDestination.fromWire(
        nullableString(json['storageLocation']),
      ),
      endpoint: nullableString(json['endpoint']),
      protocol: nullableString(json['protocol']),
      backgroundMode: nullableBool(json['backgroundMode']),
      userConsent: nullableBool(json['userConsent']),
      privacyRisk: PrivacyRisk.fromWire(nullableString(json['privacyRisk'])),
      regulatoryCompliance: compliance is Map<String, Object?>
          ? RegulatoryCompliance.fromJson(compliance)
          : null,
      aiExplanation: explanation is Map<String, Object?>
          ? AiExplanation.fromJson(explanation)
          : null,
    );
  }

  TransparencyEvent copyWith({
    DateTime? timestamp,
    String? sensorType,
    int? samplingRate,
    int? duration,
    EncryptionMethod? encryptionMethod,
    DataDestination? storageLocation,
    String? endpoint,
    String? protocol,
    bool? backgroundMode,
    bool? userConsent,
    PrivacyRisk? privacyRisk,
    RegulatoryCompliance? regulatoryCompliance,
    AiExplanation? aiExplanation,
  }) {
    return TransparencyEvent(
      timestamp: timestamp ?? this.timestamp,
      dataType: dataType,
      source: source,
      sensorType: sensorType ?? this.sensorType,
      samplingRate: samplingRate ?? this.samplingRate,
      duration: duration ?? this.duration,
      encryptionMethod: encryptionMethod ?? this.encryptionMethod,
      storageLocation: storageLocation ?? this.storageLocation,
      endpoint: endpoint ?? this.endpoint,
      protocol: protocol ?? this.protocol,
      backgroundMode: backgroundMode ?? this.backgroundMode,
      userConsent: userConsent ?? this.userConsent,
      privacyRisk: privacyRisk ?? this.privacyRisk,
      regulatoryCompliance: regulatoryCompliance ?? this.regulatoryCompliance,
      aiExplanation: aiExplanation ?? this.aiExplanation,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'timestamp': timestamp?.toIso8601String(),
      'dataType': dataType.wireName,
      'source': source.wireName,
      'sensorType': sensorType,
      'samplingRate': samplingRate,
      'duration': duration,
      'encryptionMethod': encryptionMethod?.wireName,
      'storageLocation': storageLocation?.wireName,
      'endpoint': endpoint,
      'protocol': protocol,
      'backgroundMode': backgroundMode,
      'userConsent': userConsent,
      'privacyRisk': privacyRisk?.wireName,
      'regulatoryCompliance': regulatoryCompliance?.toJson(),
      'aiExplanation': aiExplanation?.toJson(),
    };
  }
}

RegulatoryCompliance defaultCompliance() {
  return const RegulatoryCompliance(
    framework: RegulatoryFramework.pipeda,
    compliant: true,
    issues: '',
    relevantSections: <String>[],
  );
}

AiExplanation defaultExplanation({
  required String why,
  String storage = '',
  String access = '',
  String privacyExplanation = '',
  List<String> privacyPolicyLink = const <String>[],
  List<String> regulationLink = const <String>[],
}) {
  return AiExplanation(
    why: why,
    storage: storage,
    access: access,
    privacyExplanation: privacyExplanation,
    privacyPolicyLink: privacyPolicyLink,
    regulationLink: regulationLink,
  );
}

TransparencyEvent defaultJournalTransparencyEvent() {
  return TransparencyEvent(
    dataType: DataType.userJournal,
    source: DataSource.userInput,
    privacyRisk: PrivacyRisk.low,
    regulatoryCompliance: defaultCompliance(),
    aiExplanation: defaultExplanation(
      why:
          'To analyze how your daily mood, habits, sleep goals affects your sleep quality.',
    ),
  );
}

TransparencyEvent defaultLightSensorTransparencyEvent() {
  return TransparencyEvent(
    dataType: DataType.sensorLight,
    source: DataSource.lightSensor,
    privacyRisk: PrivacyRisk.low,
    regulatoryCompliance: defaultCompliance(),
    aiExplanation: defaultExplanation(
      why:
          'To understand how the light conditions in your sleep environment may affect your sleep quality',
    ),
  );
}

TransparencyEvent defaultMicrophoneTransparencyEvent() {
  return TransparencyEvent(
    dataType: DataType.sensorAudio,
    source: DataSource.microphone,
    privacyRisk: PrivacyRisk.low,
    regulatoryCompliance: defaultCompliance(),
    aiExplanation: defaultExplanation(
      why:
          'To analyze sleep disturbances such as snoring and talking, as well as understanding the noise level in your sleep environment',
    ),
  );
}

TransparencyEvent defaultAccelerometerTransparencyEvent() {
  return TransparencyEvent(
    dataType: DataType.sensorMotion,
    source: DataSource.accelerometer,
    privacyRisk: PrivacyRisk.low,
    regulatoryCompliance: defaultCompliance(),
    aiExplanation: defaultExplanation(
      why:
          'To analyze how your movements during sleep and throughout the day impact sleep quality',
    ),
  );
}

TransparencyEvent defaultStatisticsTransparencyEvent() {
  return TransparencyEvent(
    dataType: DataType.sleepStatistics,
    source: DataSource.derivedData,
    privacyRisk: PrivacyRisk.low,
    regulatoryCompliance: defaultCompliance(),
    aiExplanation: defaultExplanation(
      why:
          'Provide summaries and actionable insights to help improve your sleep quality',
      privacyExplanation: 'No privacy risks',
      storage:
          'This data is stored securely in your preferred storage location with encryption.',
      access:
          'No third parties have access to this data. Only you can view it through the app.',
      privacyPolicyLink: <String>['derivedData'],
      regulationLink: <String>['access'],
    ),
  );
}

TransparencyEvent defaultGeneralSleepTransparencyEvent() {
  return TransparencyEvent(
    dataType: DataType.generalSleep,
    source: DataSource.userInput,
    privacyRisk: PrivacyRisk.low,
    regulatoryCompliance: defaultCompliance(),
    aiExplanation: defaultExplanation(
      why: 'To understand your current sleep quality and how we can improve it',
    ),
  );
}

class User {
  const User({
    required this.userId,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.password,
  });

  final String userId;
  final String firstName;
  final String lastName;
  final String email;
  final String password;

  factory User.fromJson(Map<String, Object?> json) {
    return User(
      userId: nullableString(json['userId']) ?? '',
      firstName: nullableString(json['firstName']) ?? '',
      lastName: nullableString(json['lastName']) ?? '',
      email: nullableString(json['email']) ?? '',
      password: nullableString(json['password']) ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'userId': userId,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'password': password,
    };
  }
}

class UserConsentPreferences {
  const UserConsentPreferences({
    required this.accelerometerEnabled,
    required this.lightSensorEnabled,
    required this.microphoneEnabled,
    required this.cloudStorageEnabled,
    required this.agreedToPrivacyPolicy,
    required this.analyticsEnabled,
    required this.marketingCommunications,
    required this.notificationsEnabled,
  });

  final bool accelerometerEnabled;
  final bool lightSensorEnabled;
  final bool microphoneEnabled;
  final bool cloudStorageEnabled;
  final bool agreedToPrivacyPolicy;
  final bool analyticsEnabled;
  final bool marketingCommunications;
  final bool notificationsEnabled;

  static const UserConsentPreferences defaults = UserConsentPreferences(
    accelerometerEnabled: false,
    lightSensorEnabled: false,
    microphoneEnabled: false,
    cloudStorageEnabled: false,
    agreedToPrivacyPolicy: false,
    analyticsEnabled: false,
    marketingCommunications: false,
    notificationsEnabled: false,
  );

  factory UserConsentPreferences.fromJson(Map<String, Object?> json) {
    return UserConsentPreferences(
      accelerometerEnabled: nullableBool(json['accelerometerEnabled']) ?? false,
      lightSensorEnabled: nullableBool(json['lightSensorEnabled']) ?? false,
      microphoneEnabled: nullableBool(json['microphoneEnabled']) ?? false,
      cloudStorageEnabled: nullableBool(json['cloudStorageEnabled']) ?? false,
      agreedToPrivacyPolicy:
          nullableBool(json['agreedToPrivacyPolicy']) ?? false,
      analyticsEnabled: nullableBool(json['analyticsEnabled']) ?? false,
      marketingCommunications:
          nullableBool(json['marketingCommunications']) ?? false,
      notificationsEnabled: nullableBool(json['notificationsEnabled']) ?? false,
    );
  }

  UserConsentPreferences copyWith({
    bool? accelerometerEnabled,
    bool? lightSensorEnabled,
    bool? microphoneEnabled,
    bool? cloudStorageEnabled,
    bool? agreedToPrivacyPolicy,
    bool? analyticsEnabled,
    bool? marketingCommunications,
    bool? notificationsEnabled,
  }) {
    return UserConsentPreferences(
      accelerometerEnabled: accelerometerEnabled ?? this.accelerometerEnabled,
      lightSensorEnabled: lightSensorEnabled ?? this.lightSensorEnabled,
      microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
      cloudStorageEnabled: cloudStorageEnabled ?? this.cloudStorageEnabled,
      agreedToPrivacyPolicy:
          agreedToPrivacyPolicy ?? this.agreedToPrivacyPolicy,
      analyticsEnabled: analyticsEnabled ?? this.analyticsEnabled,
      marketingCommunications:
          marketingCommunications ?? this.marketingCommunications,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'accelerometerEnabled': accelerometerEnabled,
      'lightSensorEnabled': lightSensorEnabled,
      'microphoneEnabled': microphoneEnabled,
      'cloudStorageEnabled': cloudStorageEnabled,
      'agreedToPrivacyPolicy': agreedToPrivacyPolicy,
      'analyticsEnabled': analyticsEnabled,
      'marketingCommunications': marketingCommunications,
      'notificationsEnabled': notificationsEnabled,
    };
  }
}

class JournalData {
  const JournalData({
    required this.date,
    required this.userId,
    required this.journalId,
    required this.bedtime,
    required this.alarmTime,
    required this.sleepDuration,
    required this.diaryEntry,
    required this.sleepNotes,
  });

  final String date;
  final String userId;
  final String journalId;
  final String bedtime;
  final String alarmTime;
  final String sleepDuration;
  final String diaryEntry;
  final List<SleepNote> sleepNotes;

  factory JournalData.fromJson(Map<String, Object?> json) {
    final Object? notes = json['sleepNotes'];
    final List<SleepNote> parsedNotes = notes is List<Object?>
        ? notes
              .whereType<String>()
              .map<SleepNote>(SleepNote.fromLabel)
              .toList(growable: false)
        : <SleepNote>[];
    return JournalData(
      date: nullableString(json['date']) ?? '',
      userId: nullableString(json['userId']) ?? '',
      journalId: nullableString(json['journalId']) ?? '',
      bedtime: nullableString(json['bedtime']) ?? '',
      alarmTime: nullableString(json['alarmTime']) ?? '',
      sleepDuration: nullableString(json['sleepDuration']) ?? '',
      diaryEntry: nullableString(json['diaryEntry']) ?? '',
      sleepNotes: parsedNotes,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'date': date,
      'userId': userId,
      'journalId': journalId,
      'bedtime': bedtime,
      'alarmTime': alarmTime,
      'sleepDuration': sleepDuration,
      'diaryEntry': diaryEntry,
      'sleepNotes': sleepNotes
          .map<String>((SleepNote note) => note.label)
          .toList(),
    };
  }
}

class JournalPatch {
  const JournalPatch({
    this.date,
    this.bedtime,
    this.alarmTime,
    this.sleepDuration,
    this.diaryEntry,
    this.sleepNotes,
  });

  final String? date;
  final String? bedtime;
  final String? alarmTime;
  final String? sleepDuration;
  final String? diaryEntry;
  final List<SleepNote>? sleepNotes;
}

class GeneralSleepData {
  const GeneralSleepData({
    required this.userId,
    required this.currentSleepDuration,
    required this.snoring,
    required this.tirednessFrequency,
    required this.daytimeSleepiness,
  });

  final String userId;
  final String currentSleepDuration;
  final String snoring;
  final String tirednessFrequency;
  final String daytimeSleepiness;

  factory GeneralSleepData.fromJson(Map<String, Object?> json) {
    return GeneralSleepData(
      userId: nullableString(json['userId']) ?? '',
      currentSleepDuration: nullableString(json['currentSleepDuration']) ?? '',
      snoring: nullableString(json['snoring']) ?? '',
      tirednessFrequency: nullableString(json['tirednessFrequency']) ?? '',
      daytimeSleepiness: nullableString(json['daytimeSleepiness']) ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'userId': userId,
      'currentSleepDuration': currentSleepDuration,
      'snoring': snoring,
      'tirednessFrequency': tirednessFrequency,
      'daytimeSleepiness': daytimeSleepiness,
    };
  }
}

class FrequencyBands {
  const FrequencyBands({
    required this.low,
    required this.mid,
    required this.high,
  });

  final String low;
  final String mid;
  final String high;

  factory FrequencyBands.fromJson(Map<String, Object?> json) {
    return FrequencyBands(
      low: nullableString(json['low']) ?? '0',
      mid: nullableString(json['mid']) ?? '0',
      high: nullableString(json['high']) ?? '0',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{'low': low, 'mid': mid, 'high': high};
  }
}

abstract class SensorData {
  const SensorData({
    required this.id,
    required this.userId,
    required this.timestamp,
    required this.date,
    required this.sensorType,
  });

  final String id;
  final String userId;
  final String timestamp;
  final String date;
  final String sensorType;

  Map<String, Object?> toJson();
}

class AudioSensorData extends SensorData {
  const AudioSensorData({
    required super.id,
    required super.userId,
    required super.timestamp,
    required super.date,
    required this.averageDecibels,
    required this.peakDecibels,
    required this.frequencyBands,
    required this.snoreDetected,
    required this.ambientNoiseLevel,
    this.audioClipUri,
  }) : super(sensorType: 'audio');

  final String averageDecibels;
  final String peakDecibels;
  final FrequencyBands frequencyBands;
  final String? audioClipUri;
  final bool snoreDetected;
  final AmbientNoiseLevel ambientNoiseLevel;

  @override
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'userId': userId,
      'timestamp': timestamp,
      'date': date,
      'sensorType': sensorType,
      'averageDecibels': averageDecibels,
      'peakDecibels': peakDecibels,
      'frequencyBands': frequencyBands.toJson(),
      'audioClipUri': audioClipUri,
      'snoreDetected': snoreDetected,
      'ambientNoiseLevel': ambientNoiseLevel.wireName,
    };
  }
}

class LightSensorData extends SensorData {
  const LightSensorData({
    required super.id,
    required super.userId,
    required super.timestamp,
    required super.date,
    required this.illuminance,
    required this.lightLevel,
  }) : super(sensorType: 'light');

  final String illuminance;
  final LightLevel lightLevel;

  @override
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'userId': userId,
      'timestamp': timestamp,
      'date': date,
      'sensorType': sensorType,
      'illuminance': illuminance,
      'lightLevel': lightLevel.wireName,
    };
  }
}

class AccelerometerSensorData extends SensorData {
  const AccelerometerSensorData({
    required super.id,
    required super.userId,
    required super.timestamp,
    required super.date,
    required this.x,
    required this.y,
    required this.z,
    required this.magnitude,
    required this.movementIntensity,
  }) : super(sensorType: 'accelerometer');

  final String x;
  final String y;
  final String z;
  final String magnitude;
  final MovementIntensity movementIntensity;

  @override
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'userId': userId,
      'timestamp': timestamp,
      'date': date,
      'sensorType': sensorType,
      'x': x,
      'y': y,
      'z': z,
      'magnitude': magnitude,
      'movementIntensity': movementIntensity.wireName,
    };
  }
}

SensorData sensorDataFromJson(Map<String, Object?> json) {
  final String sensorType = nullableString(json['sensorType']) ?? '';
  final String id = nullableString(json['id']) ?? '';
  final String userId = nullableString(json['userId']) ?? '';
  final String timestamp = nullableString(json['timestamp']) ?? '';
  final String date = nullableString(json['date']) ?? '';
  switch (sensorType) {
    case 'audio':
      final Object? bands = json['frequencyBands'];
      return AudioSensorData(
        id: id,
        userId: userId,
        timestamp: timestamp,
        date: date,
        averageDecibels: nullableString(json['averageDecibels']) ?? '0',
        peakDecibels: nullableString(json['peakDecibels']) ?? '0',
        frequencyBands: bands is Map<String, Object?>
            ? FrequencyBands.fromJson(bands)
            : const FrequencyBands(low: '0', mid: '0', high: '0'),
        audioClipUri: nullableString(json['audioClipUri']),
        snoreDetected: nullableBool(json['snoreDetected']) ?? false,
        ambientNoiseLevel: AmbientNoiseLevel.fromWire(
          nullableString(json['ambientNoiseLevel']),
        ),
      );
    case 'light':
      return LightSensorData(
        id: id,
        userId: userId,
        timestamp: timestamp,
        date: date,
        illuminance: nullableString(json['illuminance']) ?? '0',
        lightLevel: LightLevel.fromWire(nullableString(json['lightLevel'])),
      );
    case 'accelerometer':
      return AccelerometerSensorData(
        id: id,
        userId: userId,
        timestamp: timestamp,
        date: date,
        x: nullableString(json['x']) ?? '0',
        y: nullableString(json['y']) ?? '0',
        z: nullableString(json['z']) ?? '0',
        magnitude: nullableString(json['magnitude']) ?? '0',
        movementIntensity: MovementIntensity.fromWire(
          nullableString(json['movementIntensity']),
        ),
      );
    default:
      throw StateError('Unknown sensor type: $sensorType');
  }
}

class QueryResult {
  const QueryResult({this.rowsAffected, this.insertId});

  final int? rowsAffected;
  final int? insertId;
}

class LocalDatabaseManager {
  LocalDatabaseManager._();
  static final LocalDatabaseManager instance = LocalDatabaseManager._();

  sqflite.Database? _database;
  final String _dbName = 'sleeptracker_data.db';

  static const String createJournalTableSql = '''
        CREATE TABLE IF NOT EXISTS journals (
            journalId TEXT PRIMARY KEY NOT NULL,
            userId TEXT NOT NULL,
            date TEXT NOT NULL,
            bedtime TEXT,
            alarmTime TEXT,
            sleepDuration TEXT,
            diaryEntry TEXT,
            sleepNotes TEXT,
            createdAt TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW'))
        );
    ''';

  static const String createSensorDataTableSql = '''
        CREATE TABLE IF NOT EXISTS sensor_data (
            id TEXT PRIMARY KEY NOT NULL,
            userId TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            date TEXT NOT NULL,
            sensorType TEXT NOT NULL,
            averageDecibels TEXT,
            peakDecibels TEXT,
            frequencyBands TEXT,
            audioClipUri TEXT,
            snoreDetected INTEGER,
            ambientNoiseLevel TEXT,
            illuminance TEXT,
            lightLevel TEXT,
            x TEXT,
            y TEXT,
            z TEXT,
            magnitude TEXT,
            movementIntensity TEXT,
            createdAt TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW'))
        );
    ''';

  Future<void> openDatabase() async {
    if (_database != null) {
      return;
    }
    final String dbPath = p.join(await sqflite.getDatabasesPath(), _dbName);
    _database = await sqflite.openDatabase(
      dbPath,
      version: 1,
      onCreate: (sqflite.Database database, int version) async {
        await database.execute(createJournalTableSql);
        await database.execute(createSensorDataTableSql);
      },
      onOpen: (sqflite.Database database) async {
        // MIGRATION: Expo SQLite used execAsync at startup. Flutter sqflite
        //            keeps the same table names and column names so existing
        //            local records remain readable.
        await database.execute(createJournalTableSql);
        await database.execute(createSensorDataTableSql);
      },
    );
  }

  Future<QueryResult> executeSql(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) async {
    await openDatabase();
    final int result = await _database!.rawInsert(sql, params);
    return QueryResult(rowsAffected: result == 0 ? 0 : 1, insertId: result);
  }

  Future<int> updateSql(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) async {
    await openDatabase();
    return _database!.rawUpdate(sql, params);
  }

  Future<int> deleteSql(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) async {
    await openDatabase();
    return _database!.rawDelete(sql, params);
  }

  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) async {
    await openDatabase();
    return _database!.rawQuery(sql, params);
  }

  Future<Map<String, Object?>?> getOne(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) async {
    final List<Map<String, Object?>> rows = await getAll(sql, params);
    return rows.isEmpty ? null : rows.first;
  }
}

class EncryptionService {
  EncryptionService({
    required FlutterSecureStorage secureStorage,
    required TransparencyBloc transparencyBloc,
  }) : _secureStorage = secureStorage,
       _transparencyBloc = transparencyBloc;

  final FlutterSecureStorage _secureStorage;
  final TransparencyBloc _transparencyBloc;

  static const String encryptionKeyName = 'myAppEncryptionKey';
  static const String pbkdf2Salt = 'sleeptracker-aes-v1-salt';
  static const int pbkdf2Iterations = 10000;
  static const int aesKeyBytes = 32;

  Future<String> _getOrCreateSecret() async {
    final String? existing = await _secureStorage.read(key: encryptionKeyName);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final Uint8List bytes = _randomBytes(aesKeyBytes);
    final String created = base64Encode(bytes);
    await _secureStorage.write(key: encryptionKeyName, value: created);
    return created;
  }

  Uint8List _randomBytes(int length) {
    final Random random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  Future<Uint8List> _deriveKey() async {
    final String secret = await _getOrCreateSecret();
    final pc.PBKDF2KeyDerivator derivator = pc.PBKDF2KeyDerivator(
      pc.HMac(pc.SHA256Digest(), 64),
    );
    derivator.init(
      pc.Pbkdf2Parameters(
        Uint8List.fromList(utf8.encode(pbkdf2Salt)),
        pbkdf2Iterations,
        aesKeyBytes,
      ),
    );
    // MIGRATION: Required PBKDF2 + AES-256 compatibility is centralized here.
    //            The salt and iteration count are constants so future releases
    //            can keep reading data created by this migration.
    return derivator.process(Uint8List.fromList(utf8.encode(secret)));
  }

  Future<String> encrypt(String data) async {
    if (inDemoMode && !TransparencyDemoConfig.encryptedAtRest) {
      // MIGRATION: Demo Mode's encryption toggle intentionally allows plaintext
      //            storage to demonstrate a privacy violation, while decrypt()
      //            still accepts plaintext for round-trip compatibility.
      return data;
    }
    final Uint8List key = await _deriveKey();
    final Uint8List iv = _randomBytes(16);
    final pc.PaddedBlockCipher cipher = pc.PaddedBlockCipher('AES/CBC/PKCS7');
    cipher.init(
      true,
      pc.PaddedBlockCipherParameters<
        pc.ParametersWithIV<pc.KeyParameter>,
        pc.CipherParameters?
      >(pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv), null),
    );
    final Uint8List encrypted = cipher.process(
      Uint8List.fromList(utf8.encode(data)),
    );
    return '${base64Encode(iv)}:${base64Encode(encrypted)}';
  }

  Future<String> decrypt(String encryptedBase64) async {
    if (!encryptedBase64.contains(':')) {
      return encryptedBase64;
    }
    final List<String> parts = encryptedBase64.split(':');
    if (parts.length != 2) {
      throw StateError(
        'Invalid encrypted data format. Expected "IV:Ciphertext".',
      );
    }
    try {
      return await _decryptWithKey(await _deriveKey(), parts[0], parts[1]);
    } catch (_) {
      // MIGRATION_FLAG: The source CryptoJS code stored a raw random base64
      //                 AES key, while the migration spec requires PBKDF2.
      //                 This fallback preserves existing source-app records
      //                 when they were encrypted with the raw SecureStore key.
      final String secret = await _getOrCreateSecret();
      return _decryptWithKey(base64Decode(secret), parts[0], parts[1]);
    }
  }

  Future<String> _decryptWithKey(
    Uint8List key,
    String ivBase64,
    String ciphertextBase64,
  ) async {
    final pc.PaddedBlockCipher cipher = pc.PaddedBlockCipher('AES/CBC/PKCS7');
    cipher.init(
      false,
      pc.PaddedBlockCipherParameters<
        pc.ParametersWithIV<pc.KeyParameter>,
        pc.CipherParameters?
      >(
        pc.ParametersWithIV<pc.KeyParameter>(
          pc.KeyParameter(key),
          base64Decode(ivBase64),
        ),
        null,
      ),
    );
    final Uint8List decrypted = cipher.process(base64Decode(ciphertextBase64));
    return utf8.decode(decrypted);
  }

  EncryptionMethod _reportedEncryptionMethod() {
    return !inDemoMode || TransparencyDemoConfig.encryptedAtRest
        ? EncryptionMethod.aes256
        : EncryptionMethod.none;
  }

  Future<JournalPatch> encryptJournalData(JournalPatch journalData) async {
    _transparencyBloc.setChannel(
      TransparencyChannel.journal,
      _transparencyBloc.state.journal.copyWith(
        encryptionMethod: _reportedEncryptionMethod(),
      ),
    );
    return JournalPatch(
      date: journalData.date,
      bedtime: journalData.bedtime == null
          ? null
          : await encrypt(journalData.bedtime!),
      alarmTime: journalData.alarmTime == null
          ? null
          : await encrypt(journalData.alarmTime!),
      sleepDuration: journalData.sleepDuration == null
          ? null
          : await encrypt(journalData.sleepDuration!),
      diaryEntry: journalData.diaryEntry == null
          ? null
          : await encrypt(journalData.diaryEntry!),
      sleepNotes: journalData.sleepNotes,
    );
  }

  Future<JournalData> decryptJournalData(JournalData encrypted) async {
    return JournalData(
      date: encrypted.date,
      userId: encrypted.userId,
      journalId: encrypted.journalId,
      bedtime: encrypted.bedtime.isEmpty
          ? ''
          : await decrypt(encrypted.bedtime),
      alarmTime: encrypted.alarmTime.isEmpty
          ? ''
          : await decrypt(encrypted.alarmTime),
      sleepDuration: encrypted.sleepDuration.isEmpty
          ? ''
          : await decrypt(encrypted.sleepDuration),
      diaryEntry: encrypted.diaryEntry.isEmpty
          ? ''
          : await decrypt(encrypted.diaryEntry),
      sleepNotes: encrypted.sleepNotes,
    );
  }

  Future<GeneralSleepData> encryptGeneralSleepData(
    GeneralSleepData data,
  ) async {
    _transparencyBloc.setChannel(
      TransparencyChannel.sleep,
      _transparencyBloc.state.sleep.copyWith(
        encryptionMethod: _reportedEncryptionMethod(),
      ),
    );
    return GeneralSleepData(
      userId: data.userId,
      currentSleepDuration: data.currentSleepDuration.isEmpty
          ? ''
          : await encrypt(data.currentSleepDuration),
      snoring: data.snoring.isEmpty ? '' : await encrypt(data.snoring),
      tirednessFrequency: data.tirednessFrequency.isEmpty
          ? ''
          : await encrypt(data.tirednessFrequency),
      daytimeSleepiness: data.daytimeSleepiness.isEmpty
          ? ''
          : await encrypt(data.daytimeSleepiness),
    );
  }

  Future<GeneralSleepData> decryptGeneralSleepData(
    GeneralSleepData data,
  ) async {
    return GeneralSleepData(
      userId: data.userId,
      currentSleepDuration: data.currentSleepDuration.isEmpty
          ? ''
          : await decrypt(data.currentSleepDuration),
      snoring: data.snoring.isEmpty ? '' : await decrypt(data.snoring),
      tirednessFrequency: data.tirednessFrequency.isEmpty
          ? ''
          : await decrypt(data.tirednessFrequency),
      daytimeSleepiness: data.daytimeSleepiness.isEmpty
          ? ''
          : await decrypt(data.daytimeSleepiness),
    );
  }

  Future<SensorData> encryptSensorData(SensorData data) async {
    final EncryptionMethod method = _reportedEncryptionMethod();
    if (data is AudioSensorData) {
      _transparencyBloc.setChannel(
        TransparencyChannel.microphone,
        _transparencyBloc.state.microphone.copyWith(encryptionMethod: method),
      );
      return AudioSensorData(
        id: data.id,
        userId: data.userId,
        timestamp: data.timestamp,
        date: data.date,
        averageDecibels: await encrypt(data.averageDecibels),
        peakDecibels: await encrypt(data.peakDecibels),
        frequencyBands: FrequencyBands(
          low: await encrypt(data.frequencyBands.low),
          mid: await encrypt(data.frequencyBands.mid),
          high: await encrypt(data.frequencyBands.high),
        ),
        audioClipUri: data.audioClipUri,
        snoreDetected: data.snoreDetected,
        ambientNoiseLevel: data.ambientNoiseLevel,
      );
    }
    if (data is LightSensorData) {
      _transparencyBloc.setChannel(
        TransparencyChannel.light,
        _transparencyBloc.state.light.copyWith(encryptionMethod: method),
      );
      return LightSensorData(
        id: data.id,
        userId: data.userId,
        timestamp: data.timestamp,
        date: data.date,
        illuminance: await encrypt(data.illuminance),
        lightLevel: data.lightLevel,
      );
    }
    final AccelerometerSensorData accelerometer =
        data as AccelerometerSensorData;
    _transparencyBloc.setChannel(
      TransparencyChannel.accelerometer,
      _transparencyBloc.state.accelerometer.copyWith(encryptionMethod: method),
    );
    return AccelerometerSensorData(
      id: accelerometer.id,
      userId: accelerometer.userId,
      timestamp: accelerometer.timestamp,
      date: accelerometer.date,
      x: await encrypt(accelerometer.x),
      y: await encrypt(accelerometer.y),
      z: await encrypt(accelerometer.z),
      magnitude: await encrypt(accelerometer.magnitude),
      movementIntensity: accelerometer.movementIntensity,
    );
  }

  Future<SensorData> decryptSensorData(SensorData data) async {
    if (data is AudioSensorData) {
      return AudioSensorData(
        id: data.id,
        userId: data.userId,
        timestamp: data.timestamp,
        date: data.date,
        averageDecibels: await decrypt(data.averageDecibels),
        peakDecibels: await decrypt(data.peakDecibels),
        frequencyBands: FrequencyBands(
          low: await decrypt(data.frequencyBands.low),
          mid: await decrypt(data.frequencyBands.mid),
          high: await decrypt(data.frequencyBands.high),
        ),
        audioClipUri: data.audioClipUri,
        snoreDetected: data.snoreDetected,
        ambientNoiseLevel: data.ambientNoiseLevel,
      );
    }
    if (data is LightSensorData) {
      return LightSensorData(
        id: data.id,
        userId: data.userId,
        timestamp: data.timestamp,
        date: data.date,
        illuminance: await decrypt(data.illuminance),
        lightLevel: data.lightLevel,
      );
    }
    final AccelerometerSensorData accelerometer =
        data as AccelerometerSensorData;
    return AccelerometerSensorData(
      id: accelerometer.id,
      userId: accelerometer.userId,
      timestamp: accelerometer.timestamp,
      date: accelerometer.date,
      x: await decrypt(accelerometer.x),
      y: await decrypt(accelerometer.y),
      z: await decrypt(accelerometer.z),
      magnitude: await decrypt(accelerometer.magnitude),
      movementIntensity: accelerometer.movementIntensity,
    );
  }
}

abstract class HttpClient {
  Future<Map<String, Object?>> get(String path, {String? token});
  Future<Map<String, Object?>> post(
    String path,
    Map<String, Object?> body, {
    String? token,
  });
  Future<Map<String, Object?>> put(
    String path,
    Map<String, Object?> body, {
    String? token,
  });
  Future<Map<String, Object?>> delete(String path, {String? token});
}

class CloudStorageService implements HttpClient {
  CloudStorageService(this.baseUrl);

  final String baseUrl;
  TransparencyBloc? transparencyBloc;

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    _processTransparency(method, path, body);
    final Uri uri = Uri.parse('$baseUrl$path');
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final http.Response response = switch (method) {
      'GET' =>
        await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 10)),
      'POST' =>
        await http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 10)),
      'PUT' =>
        await http
            .put(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 10)),
      'DELETE' =>
        await http
            .delete(uri, headers: headers)
            .timeout(const Duration(seconds: 10)),
      _ => throw StateError('Unsupported method $method'),
    };
    if (response.statusCode == 204 || response.body.isEmpty) {
      return <String, Object?>{};
    }
    late final Map<String, Object?> decoded;
    try {
      decoded = stringMapFromJson(response.body);
    } on FormatException catch (error) {
      // MIGRATION: fetch/axios callers in the React Native app surfaced JSON
      //            API failures through promise rejection. Flutter's jsonDecode
      //            throws a FormatException for HTML fallback pages, so this
      //            normalizes that into a repository-handled API failure.
      throw StateError(
        'API returned non-JSON for $method $path '
        '(HTTP ${response.statusCode}): ${error.message}',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        nullableString(decoded['message']) ?? 'API request failed',
      );
    }
    return decoded;
  }

  @override
  Future<Map<String, Object?>> get(String path, {String? token}) {
    return _request('GET', path, token: token);
  }

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, Object?> body, {
    String? token,
  }) {
    return _request('POST', path, body: body, token: token);
  }

  @override
  Future<Map<String, Object?>> put(
    String path,
    Map<String, Object?> body, {
    String? token,
  }) {
    return _request('PUT', path, body: body, token: token);
  }

  @override
  Future<Map<String, Object?>> delete(String path, {String? token}) {
    return _request('DELETE', path, token: token);
  }

  void _processTransparency(
    String method,
    String path,
    Map<String, Object?>? body,
  ) {
    if (transparencyBloc == null || (method != 'POST' && method != 'PUT')) {
      return;
    }
    final String protocol = baseUrl.startsWith('https') ? 'HTTPS' : 'HTTP';
    if (path.contains('journal')) {
      transparencyBloc!.setChannel(
        TransparencyChannel.journal,
        transparencyBloc!.state.journal.copyWith(
          endpoint: path,
          protocol: protocol,
        ),
      );
    } else if (path.contains('sensor')) {
      final String? sensorType = nullableString(body?['sensorType']);
      final TransparencyChannel channel = switch (sensorType) {
        'audio' => TransparencyChannel.microphone,
        'light' => TransparencyChannel.light,
        'accelerometer' => TransparencyChannel.accelerometer,
        _ => TransparencyChannel.accelerometer,
      };
      transparencyBloc!.setChannel(
        channel,
        transparencyBloc!.state
            .eventFor(channel)
            .copyWith(endpoint: path, protocol: protocol),
      );
    } else if (path.contains('sleep')) {
      transparencyBloc!.setChannel(
        TransparencyChannel.sleep,
        transparencyBloc!.state.sleep.copyWith(
          endpoint: path,
          protocol: protocol,
        ),
      );
    }
  }
}

class AuthState {
  const AuthState({
    this.user,
    this.token,
    this.isLoading = false,
    this.isCheckingAuth = true,
    this.errorMessage,
  });

  final User? user;
  final String? token;
  final bool isLoading;
  final bool isCheckingAuth;
  final String? errorMessage;

  bool get isAuthenticated => user != null && (token?.isNotEmpty ?? false);

  AuthState copyWith({
    User? user,
    String? token,
    bool? isLoading,
    bool? isCheckingAuth,
    String? errorMessage,
    bool clearUser = false,
    bool clearToken = false,
    bool clearError = false,
  }) {
    return AuthState(
      user: clearUser ? null : user ?? this.user,
      token: clearToken ? null : token ?? this.token,
      isLoading: isLoading ?? this.isLoading,
      isCheckingAuth: isCheckingAuth ?? this.isCheckingAuth,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class AuthCubit extends Cubit<AuthState> {
  AuthCubit({
    required SharedPreferences preferences,
    required FlutterSecureStorage secureStorage,
    required HttpClient httpClient,
  }) : _preferences = preferences,
       _secureStorage = secureStorage,
       _httpClient = httpClient,
       super(const AuthState());

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final HttpClient _httpClient;

  User _requireAuthUser(Object? userRaw) {
    if (userRaw is! Map<String, Object?>) {
      // MIGRATION: The React Native app only authenticated after the backend
      //            returned a concrete user object. Flutter must not invent a
      //            local user for malformed 2xx responses because that would
      //            make credential evaluation happen on-device.
      throw StateError('Authentication response missing user.');
    }
    final User user = User.fromJson(userRaw);
    if (user.userId.isEmpty || user.email.isEmpty) {
      // MIGRATION: A valid backend auth response includes the persistent user
      //            id and email. Empty values indicate a bad response contract,
      //            not a successful login.
      throw StateError('Authentication response returned an invalid user.');
    }
    return user;
  }

  String _requireAuthToken(Map<String, Object?> data) {
    final String? token = nullableString(data['token']);
    if (token == null || token.isEmpty) {
      // MIGRATION: React Native persisted the backend JWT returned by
      //            /auth/login or /auth/register. Flutter requires the same
      //            token before marking the session authenticated.
      throw StateError('Authentication response missing token.');
    }
    return token;
  }

  Future<void> _clearPersistedAuth() async {
    await _preferences.remove('user');
    await _secureStorage.delete(key: 'authToken');
  }

  Future<void> checkAuth() async {
    emit(state.copyWith(isLoading: true));
    final String? userJson = _preferences.getString('user');
    final String? token = await _secureStorage.read(key: 'authToken');
    if (userJson != null && token != null && token.isNotEmpty) {
      emit(
        state.copyWith(
          user: User.fromJson(stringMapFromJson(userJson)),
          token: token,
          isLoading: false,
          isCheckingAuth: false,
          clearError: true,
        ),
      );
    } else {
      await _clearPersistedAuth();
      emit(
        state.copyWith(
          isLoading: false,
          isCheckingAuth: false,
          clearUser: true,
          clearToken: true,
        ),
      );
    }
  }

  Future<bool> login(String email, String password) async {
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final Map<String, Object?> data = await _httpClient.post(
        '/auth/login',
        <String, Object?>{'email': email, 'password': password},
      );
      final User user = _requireAuthUser(data['user']);
      final String token = _requireAuthToken(data);
      await _preferences.setString('user', jsonEncode(user.toJson()));
      await _secureStorage.write(key: 'authToken', value: token);
      emit(state.copyWith(user: user, token: token, isLoading: false));
      return true;
    } catch (error) {
      emit(state.copyWith(isLoading: false, errorMessage: error.toString()));
      return false;
    }
  }

  Future<bool> register(
    String firstName,
    String lastName,
    String email,
    String password,
  ) async {
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final Map<String, Object?> data = await _httpClient
          .post('/auth/register', <String, Object?>{
            'firstName': firstName,
            'lastName': lastName,
            'email': email,
            'password': password,
          });
      final User user = _requireAuthUser(data['user']);
      final String token = _requireAuthToken(data);
      await _preferences.setString('user', jsonEncode(user.toJson()));
      await _secureStorage.write(key: 'authToken', value: token);
      emit(state.copyWith(user: user, token: token, isLoading: false));
      return true;
    } catch (error) {
      emit(state.copyWith(isLoading: false, errorMessage: error.toString()));
      return false;
    }
  }

  Future<void> logout() async {
    await _clearPersistedAuth();
    emit(state.copyWith(clearUser: true, clearToken: true));
  }
}

class ProfileState {
  const ProfileState({
    required this.userConsentPreferences,
    this.isLoading = false,
    this.hasCompletedPrivacyOnboarding = false,
    this.hasCompletedAppOnboarding = false,
  });

  final UserConsentPreferences userConsentPreferences;
  final bool isLoading;
  final bool hasCompletedPrivacyOnboarding;
  final bool hasCompletedAppOnboarding;

  ProfileState copyWith({
    UserConsentPreferences? userConsentPreferences,
    bool? isLoading,
    bool? hasCompletedPrivacyOnboarding,
    bool? hasCompletedAppOnboarding,
  }) {
    return ProfileState(
      userConsentPreferences:
          userConsentPreferences ?? this.userConsentPreferences,
      isLoading: isLoading ?? this.isLoading,
      hasCompletedPrivacyOnboarding:
          hasCompletedPrivacyOnboarding ?? this.hasCompletedPrivacyOnboarding,
      hasCompletedAppOnboarding:
          hasCompletedAppOnboarding ?? this.hasCompletedAppOnboarding,
    );
  }
}

class ProfileCubit extends Cubit<ProfileState> {
  ProfileCubit({required SharedPreferences preferences})
    : _preferences = preferences,
      super(
        const ProfileState(
          userConsentPreferences: UserConsentPreferences.defaults,
        ),
      );

  final SharedPreferences _preferences;

  Future<void> loadProfileStatus() async {
    emit(state.copyWith(isLoading: true));
    final String? preferencesJson = _preferences.getString(
      'userConsentPreferences',
    );
    emit(
      state.copyWith(
        userConsentPreferences: preferencesJson == null
            ? UserConsentPreferences.defaults
            : UserConsentPreferences.fromJson(
                stringMapFromJson(preferencesJson),
              ),
        hasCompletedPrivacyOnboarding:
            _preferences.getBool('hasCompletedPrivacyOnboarding') ?? false,
        hasCompletedAppOnboarding:
            _preferences.getBool('hasCompletedAppOnboarding') ?? false,
        isLoading: false,
      ),
    );
  }

  Future<void> setHasCompletedPrivacyOnboarding(bool value) async {
    await _preferences.setBool('hasCompletedPrivacyOnboarding', value);
    emit(state.copyWith(hasCompletedPrivacyOnboarding: value));
  }

  Future<void> setHasCompletedAppOnboarding(bool value) async {
    await _preferences.setBool('hasCompletedAppOnboarding', value);
    emit(state.copyWith(hasCompletedAppOnboarding: value));
  }

  Future<void> setUserConsentPreferences(
    UserConsentPreferences preferences,
  ) async {
    await _preferences.setString(
      'userConsentPreferences',
      jsonEncode(preferences.toJson()),
    );
    emit(state.copyWith(userConsentPreferences: preferences));
  }
}

class TransparencyState {
  const TransparencyState({
    required this.light,
    required this.microphone,
    required this.accelerometer,
    required this.journal,
    required this.sleep,
    required this.statistics,
  });

  final TransparencyEvent light;
  final TransparencyEvent microphone;
  final TransparencyEvent accelerometer;
  final TransparencyEvent journal;
  final TransparencyEvent sleep;
  final TransparencyEvent statistics;

  factory TransparencyState.defaults() {
    return TransparencyState(
      light: defaultLightSensorTransparencyEvent(),
      microphone: defaultMicrophoneTransparencyEvent(),
      accelerometer: defaultAccelerometerTransparencyEvent(),
      journal: defaultJournalTransparencyEvent(),
      sleep: defaultGeneralSleepTransparencyEvent(),
      statistics: defaultStatisticsTransparencyEvent(),
    );
  }

  TransparencyEvent eventFor(TransparencyChannel channel) {
    return switch (channel) {
      TransparencyChannel.light => light,
      TransparencyChannel.microphone => microphone,
      TransparencyChannel.accelerometer => accelerometer,
      TransparencyChannel.journal => journal,
      TransparencyChannel.sleep => sleep,
      TransparencyChannel.statistics => statistics,
    };
  }

  TransparencyState copyWithChannel(
    TransparencyChannel channel,
    TransparencyEvent event,
  ) {
    return TransparencyState(
      light: channel == TransparencyChannel.light ? event : light,
      microphone: channel == TransparencyChannel.microphone
          ? event
          : microphone,
      accelerometer: channel == TransparencyChannel.accelerometer
          ? event
          : accelerometer,
      journal: channel == TransparencyChannel.journal ? event : journal,
      sleep: channel == TransparencyChannel.sleep ? event : sleep,
      statistics: channel == TransparencyChannel.statistics
          ? event
          : statistics,
    );
  }
}

abstract class TransparencyEventBase {
  const TransparencyEventBase();
}

class LoadTransparencyStatus extends TransparencyEventBase {
  const LoadTransparencyStatus();
}

class UpdateTransparencyChannel extends TransparencyEventBase {
  const UpdateTransparencyChannel(this.channel, this.event);

  final TransparencyChannel channel;
  final TransparencyEvent event;
}

class TransparencyBloc extends Bloc<TransparencyEventBase, TransparencyState> {
  TransparencyBloc({required SharedPreferences preferences})
    : _preferences = preferences,
      super(TransparencyState.defaults()) {
    // MIGRATION: Full Bloc is used here instead of Cubit because the source
    //            TransparencyStore has six independent channels and async
    //            persistence. Events make each channel update explicit and
    //            atomic in the stream.
    on<LoadTransparencyStatus>(_onLoad);
    on<UpdateTransparencyChannel>(_onUpdateChannel);
  }

  final SharedPreferences _preferences;

  void setChannel(TransparencyChannel channel, TransparencyEvent event) {
    add(UpdateTransparencyChannel(channel, event));
  }

  Future<void> _onLoad(
    LoadTransparencyStatus event,
    Emitter<TransparencyState> emit,
  ) async {
    TransparencyState loaded = state;
    for (final TransparencyChannel channel in TransparencyChannel.values) {
      final String? raw = _preferences.getString(channel.storageKey);
      if (raw != null) {
        loaded = loaded.copyWithChannel(
          channel,
          TransparencyEvent.fromJson(stringMapFromJson(raw)),
        );
      }
    }
    emit(loaded);
  }

  Future<void> _onUpdateChannel(
    UpdateTransparencyChannel event,
    Emitter<TransparencyState> emit,
  ) async {
    await _preferences.setString(
      event.channel.storageKey,
      jsonEncode(event.event.toJson()),
    );
    emit(state.copyWithChannel(event.channel, event.event));
  }
}

abstract class JournalDataSource {
  Future<List<JournalData>> getJournalsByUserId(String userId);
  Future<JournalData?> getJournalById(String journalId);
  Future<JournalData?> getJournalByDate(String userId, String date);
  Future<JournalData?> editJournal(
    String date,
    JournalPatch journalData,
    String userId,
  );
  Future<void> deleteJournal(String journalId, String userId);
}

class LocalJournalDataSource implements JournalDataSource {
  LocalJournalDataSource({
    required LocalDatabaseManager dbManager,
    required TransparencyBloc transparencyBloc,
  }) : _dbManager = dbManager,
       _transparencyBloc = transparencyBloc;

  final LocalDatabaseManager _dbManager;
  final TransparencyBloc _transparencyBloc;
  final Uuid _uuid = const Uuid();

  JournalData _mapRow(Map<String, Object?> row) {
    final String notesJson = nullableString(row['sleepNotes']) ?? '[]';
    final Object? notesRaw = jsonDecode(notesJson);
    final List<SleepNote> notes = notesRaw is List<Object?>
        ? notesRaw
              .whereType<String>()
              .map<SleepNote>(SleepNote.fromLabel)
              .toList(growable: false)
        : <SleepNote>[];
    return JournalData(
      journalId: nullableString(row['journalId']) ?? '',
      userId: nullableString(row['userId']) ?? '',
      date: nullableString(row['date']) ?? '',
      bedtime: nullableString(row['bedtime']) ?? '',
      alarmTime: nullableString(row['alarmTime']) ?? '',
      sleepDuration: nullableString(row['sleepDuration']) ?? '',
      diaryEntry: nullableString(row['diaryEntry']) ?? '',
      sleepNotes: notes,
    );
  }

  @override
  Future<List<JournalData>> getJournalsByUserId(String userId) async {
    final List<Map<String, Object?>> rows = await _dbManager.getAll(
      '''
      SELECT journalId, userId, date, bedtime, alarmTime, sleepDuration,
             diaryEntry, sleepNotes
      FROM journals
      WHERE userId = ?
      ORDER BY date DESC
      ''',
      <Object?>[userId],
    );
    return rows.map<JournalData>(_mapRow).toList(growable: false);
  }

  @override
  Future<JournalData?> getJournalById(String journalId) async {
    final Map<String, Object?>? row = await _dbManager.getOne(
      '''
      SELECT journalId, userId, date, bedtime, alarmTime, sleepDuration,
             diaryEntry, sleepNotes
      FROM journals
      WHERE journalId = ?
      ''',
      <Object?>[journalId],
    );
    return row == null ? null : _mapRow(row);
  }

  @override
  Future<JournalData?> getJournalByDate(String userId, String date) async {
    final Map<String, Object?>? row = await _dbManager.getOne(
      '''
      SELECT journalId, userId, date, bedtime, alarmTime, sleepDuration,
             diaryEntry, sleepNotes, createdAt
      FROM journals
      WHERE userId = ? AND date == ?
      ''',
      <Object?>[userId, date],
    );
    return row == null ? null : _mapRow(row);
  }

  @override
  Future<JournalData?> editJournal(
    String date,
    JournalPatch journalData,
    String userId,
  ) async {
    final JournalData? existing = await getJournalByDate(userId, date);
    _transparencyBloc.setChannel(
      TransparencyChannel.journal,
      _transparencyBloc.state.journal.copyWith(
        storageLocation: DataDestination.sqliteDb,
      ),
    );
    if (existing == null) {
      final String journalId = _uuid.v4();
      final String createdAt = DateTime.now().toIso8601String();
      final List<SleepNote> notes = journalData.sleepNotes ?? <SleepNote>[];
      await _dbManager.executeSql(
        '''
        INSERT INTO journals
        (journalId, userId, date, bedtime, alarmTime, sleepDuration, diaryEntry, sleepNotes, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          journalId,
          userId,
          journalData.date ?? date,
          journalData.bedtime ?? '',
          journalData.alarmTime ?? '',
          journalData.sleepDuration ?? '',
          journalData.diaryEntry ?? '',
          jsonEncode(
            notes.map<String>((SleepNote note) => note.label).toList(),
          ),
          createdAt,
        ],
      );
      return JournalData(
        journalId: journalId,
        userId: userId,
        date: date,
        bedtime: journalData.bedtime ?? '',
        alarmTime: journalData.alarmTime ?? '',
        sleepDuration: journalData.sleepDuration ?? '',
        diaryEntry: journalData.diaryEntry ?? '',
        sleepNotes: notes,
      );
    }

    final List<String> updateFields = <String>[];
    final List<Object?> params = <Object?>[];
    void addField(String name, Object? value) {
      updateFields.add('$name = ?');
      params.add(value);
    }

    if (journalData.date != null) addField('date', journalData.date);
    if (journalData.bedtime != null) addField('bedtime', journalData.bedtime);
    if (journalData.alarmTime != null) {
      addField('alarmTime', journalData.alarmTime);
    }
    if (journalData.sleepDuration != null) {
      addField('sleepDuration', journalData.sleepDuration);
    }
    if (journalData.diaryEntry != null) {
      addField('diaryEntry', journalData.diaryEntry);
    }
    if (journalData.sleepNotes != null) {
      addField(
        'sleepNotes',
        jsonEncode(
          journalData.sleepNotes!
              .map<String>((SleepNote note) => note.label)
              .toList(),
        ),
      );
    }
    if (updateFields.isEmpty) {
      return existing;
    }
    params.addAll(<Object?>[date, userId]);
    final int rows = await _dbManager.updateSql('''
      UPDATE journals
      SET ${updateFields.join(', ')}
      WHERE date = ? AND userId = ?
      ''', params);
    return rows == 0 ? null : getJournalByDate(userId, date);
  }

  @override
  Future<void> deleteJournal(String journalId, String userId) async {
    final int rows = await _dbManager.deleteSql(
      'DELETE FROM journals WHERE journalId = ? AND userId = ?',
      <Object?>[journalId, userId],
    );
    if (rows == 0) {
      throw StateError('Journal $journalId not found for user $userId');
    }
  }
}

class CloudJournalDataSource implements JournalDataSource {
  CloudJournalDataSource({
    required HttpClient httpClient,
    required String? Function() getToken,
  }) : _httpClient = httpClient,
       _getToken = getToken;

  final HttpClient _httpClient;
  final String? Function() _getToken;

  String _token() {
    final String? token = _getToken();
    if (token == null) {
      throw StateError('Authentication token missing for cloud operation.');
    }
    return token;
  }

  @override
  Future<void> deleteJournal(String journalId, String userId) async {
    await _httpClient.delete(
      '/phi/journal/$userId/$journalId',
      token: _token(),
    );
  }

  @override
  Future<JournalData?> editJournal(
    String date,
    JournalPatch journalData,
    String userId,
  ) async {
    final Map<String, Object?> response = await _httpClient
        .put('/phi/journal/$userId/$date', <String, Object?>{
          'date': journalData.date,
          'bedtime': journalData.bedtime,
          'alarmTime': journalData.alarmTime,
          'sleepDuration': journalData.sleepDuration,
          'diaryEntry': journalData.diaryEntry,
          'sleepNotes': journalData.sleepNotes
              ?.map<String>((SleepNote note) => note.label)
              .toList(),
        }, token: _token());
    return JournalData.fromJson(response);
  }

  @override
  Future<JournalData?> getJournalByDate(String userId, String date) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/journal/$userId/date/$date',
      token: _token(),
    );
    return response.isEmpty ? null : JournalData.fromJson(response);
  }

  @override
  Future<JournalData?> getJournalById(String journalId) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/journal/$journalId',
      token: _token(),
    );
    return response.isEmpty ? null : JournalData.fromJson(response);
  }

  @override
  Future<List<JournalData>> getJournalsByUserId(String userId) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/journal/$userId',
      token: _token(),
    );
    final Object? rows = response['journals'];
    if (rows is List<Object?>) {
      return rows
          .whereType<Map<String, Object?>>()
          .map<JournalData>(JournalData.fromJson)
          .toList(growable: false);
    }
    return const <JournalData>[];
  }
}

class JournalDataRepository {
  JournalDataRepository({
    required JournalDataSource cloudDataSource,
    required JournalDataSource localDataSource,
    required EncryptionService encryptionService,
    required AuthCubit authCubit,
    required ProfileCubit profileCubit,
    required TransparencyBloc transparencyBloc,
  }) : _cloudDataSource = cloudDataSource,
       _localDataSource = localDataSource,
       _encryptionService = encryptionService,
       _authCubit = authCubit,
       _profileCubit = profileCubit,
       _transparencyBloc = transparencyBloc;

  final JournalDataSource _cloudDataSource;
  final JournalDataSource _localDataSource;
  final EncryptionService _encryptionService;
  final AuthCubit _authCubit;
  final ProfileCubit _profileCubit;
  final TransparencyBloc _transparencyBloc;

  User _authenticatedUser() {
    final User? user = _authCubit.state.user;
    if (user == null) {
      throw StateError('User is not authenticated. Please log in first.');
    }
    return user;
  }

  JournalDataSource _activeDataSource() {
    return _profileCubit.state.userConsentPreferences.cloudStorageEnabled
        ? _cloudDataSource
        : _localDataSource;
  }

  Future<JournalData?> getJournalByDate(String date) async {
    final User user = _authenticatedUser();
    final bool useCloud =
        _profileCubit.state.userConsentPreferences.cloudStorageEnabled;
    JournalData? encrypted;
    if (useCloud) {
      try {
        encrypted = await _cloudDataSource.getJournalByDate(user.userId, date);
      } catch (error) {
        // MIGRATION: The source repository selected cloud/local from consent.
        //            Flutter keeps that preference, but falls back to the
        //            SQLite-compatible local source when the cloud endpoint
        //            returns non-JSON HTML or is temporarily unavailable.
        // MIGRATION_FLAG: A cloud outage may show the newest local journal
        //                 rather than the cloud copy until the API is fixed.
        _transparencyBloc.setChannel(
          TransparencyChannel.journal,
          _transparencyBloc.state.journal.copyWith(
            storageLocation: DataDestination.sqliteDb,
          ),
        );
        encrypted = await _localDataSource.getJournalByDate(user.userId, date);
      }
    } else {
      encrypted = await _localDataSource.getJournalByDate(user.userId, date);
    }
    return encrypted == null
        ? null
        : _encryptionService.decryptJournalData(encrypted);
  }

  Future<JournalData?> editJournal(JournalPatch journal, String date) async {
    final User user = _authenticatedUser();
    final bool useCloud =
        _profileCubit.state.userConsentPreferences.cloudStorageEnabled;
    JournalDataSource source = _activeDataSource();
    if (useCloud) {
      _transparencyBloc.setChannel(
        TransparencyChannel.journal,
        _transparencyBloc.state.journal.copyWith(
          storageLocation: DataDestination.googleCloud,
        ),
      );
    }
    final JournalPatch encrypted = await _encryptionService.encryptJournalData(
      journal,
    );
    JournalData? response;
    try {
      response = await source.editJournal(date, encrypted, user.userId);
    } catch (error) {
      if (!useCloud) rethrow;
      // MIGRATION: React Native cloud writes could fail through rejected
      //            promises. The Flutter repository preserves journaling by
      //            retrying the same encrypted patch locally when cloud returns
      //            HTML/non-JSON or is unreachable.
      // MIGRATION_FLAG: This local fallback preserves the entry on device but
      //                 does not sync the failed cloud write automatically.
      source = _localDataSource;
      _transparencyBloc.setChannel(
        TransparencyChannel.journal,
        _transparencyBloc.state.journal.copyWith(
          storageLocation: DataDestination.sqliteDb,
        ),
      );
      response = await source.editJournal(date, encrypted, user.userId);
    }
    return response == null
        ? null
        : _encryptionService.decryptJournalData(response);
  }

  Future<void> deleteJournal(String journalId) async {
    final User user = _authenticatedUser();
    await _activeDataSource().deleteJournal(journalId, user.userId);
  }
}

abstract class SensorDataSource {
  Future<SensorData> createSensorReading(SensorData sensorData, String userId);
  Future<SensorData?> getSensorReadingById(String userId, String id);
  Future<List<SensorData>> getSensorReadingsByUserId(String userId);
  Future<List<SensorData>> getSensorReadingsByDate(String userId, String date);
  Future<bool> deleteSensorReading(String userId, String id);
}

class LocalSensorDataSource implements SensorDataSource {
  LocalSensorDataSource({
    required LocalDatabaseManager dbManager,
    required TransparencyBloc transparencyBloc,
  }) : _dbManager = dbManager,
       _transparencyBloc = transparencyBloc;

  final LocalDatabaseManager _dbManager;
  final TransparencyBloc _transparencyBloc;
  final Uuid _uuid = const Uuid();

  SensorData _mapRow(Map<String, Object?> row) {
    final String sensorType = nullableString(row['sensorType']) ?? '';
    final Map<String, Object?> base = <String, Object?>{
      'id': nullableString(row['id']) ?? '',
      'userId': nullableString(row['userId']) ?? '',
      'timestamp': (row['timestamp'] ?? '').toString(),
      'date': nullableString(row['date']) ?? '',
      'sensorType': sensorType,
    };
    if (sensorType == 'audio') {
      final String bandsJson = nullableString(row['frequencyBands']) ?? '{}';
      return sensorDataFromJson(<String, Object?>{
        ...base,
        'averageDecibels': nullableString(row['averageDecibels']) ?? '0',
        'peakDecibels': nullableString(row['peakDecibels']) ?? '0',
        'frequencyBands': stringMapFromJson(bandsJson),
        'audioClipUri': nullableString(row['audioClipUri']),
        'snoreDetected': row['snoreDetected'] == 1,
        'ambientNoiseLevel': nullableString(row['ambientNoiseLevel']),
      });
    }
    if (sensorType == 'light') {
      return sensorDataFromJson(<String, Object?>{
        ...base,
        'illuminance': nullableString(row['illuminance']) ?? '0',
        'lightLevel': nullableString(row['lightLevel']),
      });
    }
    return sensorDataFromJson(<String, Object?>{
      ...base,
      'x': nullableString(row['x']) ?? '0',
      'y': nullableString(row['y']) ?? '0',
      'z': nullableString(row['z']) ?? '0',
      'magnitude': nullableString(row['magnitude']) ?? '0',
      'movementIntensity': nullableString(row['movementIntensity']),
    });
  }

  @override
  Future<SensorData> createSensorReading(
    SensorData sensorData,
    String userId,
  ) async {
    final String id = sensorData.id.isEmpty ? _uuid.v4() : sensorData.id;
    final String createdAt = DateTime.now().toIso8601String();
    if (sensorData is AudioSensorData) {
      await _dbManager.executeSql(
        '''
        INSERT INTO sensor_data
        (id, userId, timestamp, date, sensorType, averageDecibels, peakDecibels, frequencyBands, audioClipUri, snoreDetected, ambientNoiseLevel, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          id,
          userId,
          sensorData.timestamp,
          sensorData.date,
          sensorData.sensorType,
          sensorData.averageDecibels,
          sensorData.peakDecibels,
          jsonEncode(sensorData.frequencyBands.toJson()),
          sensorData.audioClipUri,
          sensorData.snoreDetected ? 1 : 0,
          sensorData.ambientNoiseLevel.wireName,
          createdAt,
        ],
      );
    } else if (sensorData is LightSensorData) {
      await _dbManager.executeSql(
        '''
        INSERT INTO sensor_data
        (id, userId, timestamp, date, sensorType, illuminance, lightLevel, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          id,
          userId,
          sensorData.timestamp,
          sensorData.date,
          sensorData.sensorType,
          sensorData.illuminance,
          sensorData.lightLevel.wireName,
          createdAt,
        ],
      );
    } else {
      final AccelerometerSensorData accelerometer =
          sensorData as AccelerometerSensorData;
      await _dbManager.executeSql(
        '''
        INSERT INTO sensor_data
        (id, userId, timestamp, date, sensorType, x, y, z, magnitude, movementIntensity, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          id,
          userId,
          accelerometer.timestamp,
          accelerometer.date,
          accelerometer.sensorType,
          accelerometer.x,
          accelerometer.y,
          accelerometer.z,
          accelerometer.magnitude,
          accelerometer.movementIntensity.wireName,
          createdAt,
        ],
      );
    }
    _logTransparencyEvent(sensorData);
    return sensorDataFromJson(<String, Object?>{
      ...sensorData.toJson(),
      'id': id,
      'userId': userId,
    });
  }

  @override
  Future<bool> deleteSensorReading(String userId, String id) async {
    final int rows = await _dbManager.deleteSql(
      'DELETE FROM sensor_data WHERE id = ? AND userId = ?',
      <Object?>[id, userId],
    );
    return rows > 0;
  }

  @override
  Future<SensorData?> getSensorReadingById(String userId, String id) async {
    final Map<String, Object?>? row = await _dbManager.getOne(
      'SELECT * FROM sensor_data WHERE id = ? AND userId = ?',
      <Object?>[id, userId],
    );
    return row == null ? null : _mapRow(row);
  }

  @override
  Future<List<SensorData>> getSensorReadingsByDate(
    String userId,
    String date,
  ) async {
    final List<Map<String, Object?>> rows = await _dbManager.getAll(
      'SELECT * FROM sensor_data WHERE userId = ? AND date = ?',
      <Object?>[userId, date],
    );
    return rows.map<SensorData>(_mapRow).toList(growable: false);
  }

  @override
  Future<List<SensorData>> getSensorReadingsByUserId(String userId) async {
    final List<Map<String, Object?>> rows = await _dbManager.getAll(
      'SELECT * FROM sensor_data WHERE userId = ? ORDER BY timestamp DESC',
      <Object?>[userId],
    );
    return rows.map<SensorData>(_mapRow).toList(growable: false);
  }

  void _logTransparencyEvent(SensorData sensorData) {
    final TransparencyChannel channel = switch (sensorData.sensorType) {
      'audio' => TransparencyChannel.microphone,
      'light' => TransparencyChannel.light,
      _ => TransparencyChannel.accelerometer,
    };
    _transparencyBloc.setChannel(
      channel,
      _transparencyBloc.state
          .eventFor(channel)
          .copyWith(storageLocation: DataDestination.sqliteDb),
    );
  }
}

class CloudSensorDataSource implements SensorDataSource {
  CloudSensorDataSource({
    required HttpClient httpClient,
    required String? Function() getToken,
  }) : _httpClient = httpClient,
       _getToken = getToken;

  final HttpClient _httpClient;
  final String? Function() _getToken;

  String _token() {
    final String? token = _getToken();
    if (token == null) {
      throw StateError('Authentication token missing for cloud operation.');
    }
    return token;
  }

  @override
  Future<SensorData> createSensorReading(
    SensorData sensorData,
    String userId,
  ) async {
    final Map<String, Object?> response = await _httpClient.post(
      '/phi/sensor-data/$userId',
      sensorData.toJson(),
      token: _token(),
    );
    return sensorDataFromJson(
      response.isEmpty ? sensorData.toJson() : response,
    );
  }

  @override
  Future<bool> deleteSensorReading(String userId, String id) async {
    await _httpClient.delete('/phi/sensor-data/$userId/$id', token: _token());
    return true;
  }

  @override
  Future<SensorData?> getSensorReadingById(String userId, String id) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/sensor-data/$userId/$id',
      token: _token(),
    );
    return response.isEmpty ? null : sensorDataFromJson(response);
  }

  @override
  Future<List<SensorData>> getSensorReadingsByDate(
    String userId,
    String date,
  ) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/sensor-data/$userId/date/$date',
      token: _token(),
    );
    final Object? readings = response['readings'];
    if (readings is List<Object?>) {
      return readings
          .whereType<Map<String, Object?>>()
          .map<SensorData>(sensorDataFromJson)
          .toList(growable: false);
    }
    return const <SensorData>[];
  }

  @override
  Future<List<SensorData>> getSensorReadingsByUserId(String userId) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/sensor-data/$userId',
      token: _token(),
    );
    final Object? readings = response['readings'];
    if (readings is List<Object?>) {
      return readings
          .whereType<Map<String, Object?>>()
          .map<SensorData>(sensorDataFromJson)
          .toList(growable: false);
    }
    return const <SensorData>[];
  }
}

class SensorStorageRepository {
  SensorStorageRepository({
    required SensorDataSource cloudDataSource,
    required SensorDataSource localDataSource,
    required EncryptionService encryptionService,
    required AuthCubit authCubit,
    required ProfileCubit profileCubit,
    required TransparencyBloc transparencyBloc,
  }) : _cloudDataSource = cloudDataSource,
       _localDataSource = localDataSource,
       _encryptionService = encryptionService,
       _authCubit = authCubit,
       _profileCubit = profileCubit,
       _transparencyBloc = transparencyBloc;

  final SensorDataSource _cloudDataSource;
  final SensorDataSource _localDataSource;
  final EncryptionService _encryptionService;
  final AuthCubit _authCubit;
  final ProfileCubit _profileCubit;
  final TransparencyBloc _transparencyBloc;

  User _authenticatedUser() {
    final User? user = _authCubit.state.user;
    if (user == null) {
      throw StateError('User is not authenticated. Please log in first.');
    }
    return user;
  }

  SensorDataSource _activeDataSource() {
    return _profileCubit.state.userConsentPreferences.cloudStorageEnabled
        ? _cloudDataSource
        : _localDataSource;
  }

  Future<SensorData> createSensorReading(SensorData sensorData) async {
    final User user = _authenticatedUser();
    final SensorDataSource dataSource = _activeDataSource();
    _logTransparencyEvent(sensorData, dataSource);
    final SensorData withUser = sensorDataFromJson(<String, Object?>{
      ...sensorData.toJson(),
      'userId': user.userId,
    });
    final SensorData encrypted = await _encryptionService.encryptSensorData(
      withUser,
    );
    final SensorData response = await dataSource.createSensorReading(
      encrypted,
      user.userId,
    );
    return _encryptionService.decryptSensorData(response);
  }

  void _logTransparencyEvent(
    SensorData sensorData,
    SensorDataSource dataSource,
  ) {
    if (dataSource != _cloudDataSource) {
      return;
    }
    final TransparencyChannel channel = switch (sensorData.sensorType) {
      'audio' => TransparencyChannel.microphone,
      'light' => TransparencyChannel.light,
      _ => TransparencyChannel.accelerometer,
    };
    _transparencyBloc.setChannel(
      channel,
      _transparencyBloc.state
          .eventFor(channel)
          .copyWith(storageLocation: DataDestination.googleCloud),
    );
  }
}

abstract class GeneralSleepDataSource {
  Future<GeneralSleepData?> getSleepDataByUserId(String userId);
  Future<GeneralSleepData> createSleepData(GeneralSleepData sleepData);
  Future<void> deleteSleepData(String userId);
}

class LocalGeneralSleepDataSource implements GeneralSleepDataSource {
  LocalGeneralSleepDataSource({required FlutterSecureStorage secureStorage})
    : _secureStorage = secureStorage;

  final FlutterSecureStorage _secureStorage;

  @override
  Future<GeneralSleepData> createSleepData(GeneralSleepData sleepData) async {
    final GeneralSleepData? existing = await getSleepDataByUserId(
      sleepData.userId,
    );
    final GeneralSleepData updated = existing == null
        ? sleepData
        : GeneralSleepData(
            userId: existing.userId,
            currentSleepDuration: sleepData.currentSleepDuration.isEmpty
                ? existing.currentSleepDuration
                : sleepData.currentSleepDuration,
            snoring: sleepData.snoring.isEmpty
                ? existing.snoring
                : sleepData.snoring,
            tirednessFrequency: sleepData.tirednessFrequency.isEmpty
                ? existing.tirednessFrequency
                : sleepData.tirednessFrequency,
            daytimeSleepiness: sleepData.daytimeSleepiness.isEmpty
                ? existing.daytimeSleepiness
                : sleepData.daytimeSleepiness,
          );
    await _secureStorage.write(
      key: 'sleepData_${sleepData.userId}',
      value: jsonEncode(updated.toJson()),
    );
    return updated;
  }

  @override
  Future<void> deleteSleepData(String userId) {
    return _secureStorage.delete(key: 'sleepData_$userId');
  }

  @override
  Future<GeneralSleepData?> getSleepDataByUserId(String userId) async {
    final String? raw = await _secureStorage.read(key: 'sleepData_$userId');
    return raw == null
        ? null
        : GeneralSleepData.fromJson(stringMapFromJson(raw));
  }
}

class CloudGeneralSleepDataSource implements GeneralSleepDataSource {
  CloudGeneralSleepDataSource({
    required HttpClient httpClient,
    required String? Function() getToken,
  }) : _httpClient = httpClient,
       _getToken = getToken;

  final HttpClient _httpClient;
  final String? Function() _getToken;

  String _token() {
    final String? token = _getToken();
    if (token == null) {
      throw StateError('Authentication token missing for cloud operation.');
    }
    return token;
  }

  @override
  Future<GeneralSleepData> createSleepData(GeneralSleepData sleepData) async {
    final Map<String, Object?> response = await _httpClient.post(
      '/phi/generalSleep',
      sleepData.toJson(),
      token: _token(),
    );
    return GeneralSleepData.fromJson(response);
  }

  @override
  Future<void> deleteSleepData(String userId) async {
    await _httpClient.delete('/phi/generalSleep/$userId', token: _token());
  }

  @override
  Future<GeneralSleepData?> getSleepDataByUserId(String userId) async {
    final Map<String, Object?> response = await _httpClient.get(
      '/phi/generalSleep/$userId',
      token: _token(),
    );
    return response.isEmpty ? null : GeneralSleepData.fromJson(response);
  }
}

class GeneralSleepDataRepository {
  GeneralSleepDataRepository({
    required GeneralSleepDataSource cloudDataSource,
    required GeneralSleepDataSource localDataSource,
    required EncryptionService encryptionService,
    required AuthCubit authCubit,
    required ProfileCubit profileCubit,
  }) : _cloudDataSource = cloudDataSource,
       _localDataSource = localDataSource,
       _encryptionService = encryptionService,
       _authCubit = authCubit,
       _profileCubit = profileCubit;

  final GeneralSleepDataSource _cloudDataSource;
  final GeneralSleepDataSource _localDataSource;
  final EncryptionService _encryptionService;
  final AuthCubit _authCubit;
  final ProfileCubit _profileCubit;

  User _authenticatedUser() {
    final User? user = _authCubit.state.user;
    if (user == null) {
      throw StateError('User is not authenticated. Please log in first.');
    }
    return user;
  }

  GeneralSleepDataSource _activeDataSource() {
    return _profileCubit.state.userConsentPreferences.cloudStorageEnabled
        ? _cloudDataSource
        : _localDataSource;
  }

  Future<GeneralSleepData?> getSleepData() async {
    final User user = _authenticatedUser();
    final GeneralSleepData? response = await _activeDataSource()
        .getSleepDataByUserId(user.userId);
    return response == null
        ? null
        : _encryptionService.decryptGeneralSleepData(response);
  }

  Future<GeneralSleepData> createSleepData(GeneralSleepData sleepData) async {
    final User user = _authenticatedUser();
    final GeneralSleepData encrypted = await _encryptionService
        .encryptGeneralSleepData(
          GeneralSleepData(
            userId: user.userId,
            currentSleepDuration: sleepData.currentSleepDuration,
            snoring: sleepData.snoring,
            tirednessFrequency: sleepData.tirednessFrequency,
            daytimeSleepiness: sleepData.daytimeSleepiness,
          ),
        );
    final GeneralSleepData response = await _activeDataSource().createSleepData(
      encrypted,
    );
    return _encryptionService.decryptGeneralSleepData(response);
  }
}

class SensorSamplingRates {
  const SensorSamplingRates({
    required this.audio,
    required this.light,
    required this.accelerometer,
  });

  final int audio;
  final int light;
  final int accelerometer;

  SensorSamplingRates copyWith({int? audio, int? light, int? accelerometer}) {
    return SensorSamplingRates(
      audio: audio ?? this.audio,
      light: light ?? this.light,
      accelerometer: accelerometer ?? this.accelerometer,
    );
  }
}

class AudioProcessingConfig {
  const AudioProcessingConfig({
    required this.enableSnoreDetection,
    required this.saveAudioClips,
    required this.clipDuration,
  });

  final bool enableSnoreDetection;
  final bool saveAudioClips;
  final int clipDuration;
}

class SensorServiceConfig {
  const SensorServiceConfig({
    required this.useSimulation,
    required this.audioEnabled,
    required this.lightEnabled,
    required this.accelerometerEnabled,
    required this.samplingRates,
    required this.audioProcessing,
  });

  final bool useSimulation;
  final bool audioEnabled;
  final bool lightEnabled;
  final bool accelerometerEnabled;
  final SensorSamplingRates samplingRates;
  final AudioProcessingConfig audioProcessing;

  static const SensorServiceConfig defaults = SensorServiceConfig(
    useSimulation: inDemoMode,
    audioEnabled: false,
    lightEnabled: false,
    accelerometerEnabled: false,
    samplingRates: SensorSamplingRates(audio: 15, light: 15, accelerometer: 15),
    audioProcessing: AudioProcessingConfig(
      enableSnoreDetection: true,
      saveAudioClips: true,
      clipDuration: 30,
    ),
  );

  SensorServiceConfig copyWith({
    bool? useSimulation,
    bool? audioEnabled,
    bool? lightEnabled,
    bool? accelerometerEnabled,
    SensorSamplingRates? samplingRates,
    AudioProcessingConfig? audioProcessing,
  }) {
    return SensorServiceConfig(
      useSimulation: useSimulation ?? this.useSimulation,
      audioEnabled: audioEnabled ?? this.audioEnabled,
      lightEnabled: lightEnabled ?? this.lightEnabled,
      accelerometerEnabled: accelerometerEnabled ?? this.accelerometerEnabled,
      samplingRates: samplingRates ?? this.samplingRates,
      audioProcessing: audioProcessing ?? this.audioProcessing,
    );
  }
}

class SensorServiceConfigPatch {
  const SensorServiceConfigPatch({
    this.useSimulation,
    this.audioEnabled,
    this.lightEnabled,
    this.accelerometerEnabled,
  });

  final bool? useSimulation;
  final bool? audioEnabled;
  final bool? lightEnabled;
  final bool? accelerometerEnabled;
}

abstract class SensorService {
  SensorService({
    required this.config,
    required this.transparencyBloc,
    required this.profileCubit,
    required this.transparencyService,
  });

  SensorServiceConfig config;
  final TransparencyBloc transparencyBloc;
  final ProfileCubit profileCubit;
  final TransparencyService transparencyService;
  Future<void> Function(AudioSensorData data)? audioDataHandler;
  Future<void> Function(LightSensorData data)? lightDataHandler;
  Future<void> Function(AccelerometerSensorData data)? accelerometerDataHandler;
  bool isRecording = false;
  String? currentSessionId;

  Future<bool> isAudioAvailable();
  Future<bool> isLightAvailable();
  Future<bool> isAccelerometerAvailable();
  Future<void> startAudioMonitoring();
  Future<void> stopAudioMonitoring();
  Future<void> startLightMonitoring();
  Future<void> stopLightMonitoring();
  Future<void> startAccelerometerMonitoring();
  Future<void> stopAccelerometerMonitoring();

  void updateConfig(SensorServiceConfig newConfig) {
    config = newConfig;
  }

  Future<void> onAudioData(AudioSensorData data) async {
    await audioDataHandler?.call(data);
  }

  Future<void> onLightData(LightSensorData data) async {
    await lightDataHandler?.call(data);
  }

  Future<void> onAccelerometerData(AccelerometerSensorData data) async {
    await accelerometerDataHandler?.call(data);
  }

  void onError(Object error, String sensorType) {
    debugPrint('Sensor error ($sensorType): $error');
  }

  LightLevel categorizeLightLevel(double lux) {
    if (lux < 1) return LightLevel.dark;
    if (lux < 10) return LightLevel.dim;
    if (lux < 100) return LightLevel.moderate;
    return LightLevel.bright;
  }

  MovementIntensity categorizeMovement(double magnitude) {
    if (magnitude < 0.1) return MovementIntensity.still;
    if (magnitude < 0.5) return MovementIntensity.light;
    if (magnitude < 1.0) return MovementIntensity.moderate;
    return MovementIntensity.active;
  }

  AmbientNoiseLevel categorizeNoiseLevel(double decibels) {
    if (decibels < 30) return AmbientNoiseLevel.quiet;
    if (decibels < 50) return AmbientNoiseLevel.moderate;
    if (decibels < 70) return AmbientNoiseLevel.loud;
    return AmbientNoiseLevel.veryLoud;
  }
}

class FlutterSensorService extends SensorService {
  FlutterSensorService({
    required super.config,
    required super.transparencyBloc,
    required super.profileCubit,
    required super.transparencyService,
  });

  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  Timer? _audioAnalysisTimer;
  Timer? _lightFallbackTimer;

  @override
  Future<bool> isAccelerometerAvailable() async => true;

  @override
  Future<bool> isAudioAvailable() {
    return _audioRecorder.hasPermission();
  }

  @override
  Future<bool> isLightAvailable() async {
    // MIGRATION_FLAG: sensors_plus 4.0.2 exposes accelerometer, gyroscope,
    //                 userAccelerometer, and magnetometer streams, but no
    //                 ambient-light stream. iOS is explicitly unsupported by
    //                 the source; Android is simulated until a native light
    //                 plugin/module is added.
    return false;
  }

  @override
  Future<void> startAccelerometerMonitoring() async {
    try {
      final TransparencyEvent event = defaultAccelerometerTransparencyEvent()
          .copyWith(
            backgroundMode: true,
            samplingRate: config.samplingRates.accelerometer,
          );
      transparencyBloc.setChannel(TransparencyChannel.accelerometer, event);
      isRecording = true;
      currentSessionId ??= const Uuid().v4();
      _accelerometerSubscription?.cancel();
      _accelerometerSubscription =
          accelerometerEventStream(
            samplingPeriod: Duration(
              seconds: config.samplingRates.accelerometer,
            ),
          ).listen((AccelerometerEvent sample) {
            final double magnitude = sqrt(
              sample.x * sample.x + sample.y * sample.y + sample.z * sample.z,
            );
            final AccelerometerSensorData data = AccelerometerSensorData(
              id: '',
              userId: '',
              timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
              date: isoDate(DateTime.now()),
              x: sample.x.toString(),
              y: sample.y.toString(),
              z: sample.z.toString(),
              magnitude: magnitude.toString(),
              movementIntensity: categorizeMovement(magnitude),
            );
            unawaited(onAccelerometerData(data));
            _analyzeIfChanged(TransparencyChannel.accelerometer);
          });
    } catch (error) {
      onError(error, 'accelerometer');
    }
  }

  @override
  Future<void> startAudioMonitoring() async {
    try {
      final bool permitted = await _audioRecorder.hasPermission();
      if (!permitted) {
        throw StateError('Microphone permission denied.');
      }
      final Directory tempDirectory = await getTemporaryDirectory();
      final String path = p.join(
        tempDirectory.path,
        'sleep_audio_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      transparencyBloc.setChannel(
        TransparencyChannel.microphone,
        defaultMicrophoneTransparencyEvent().copyWith(
          backgroundMode: true,
          samplingRate: config.samplingRates.audio,
        ),
      );
      isRecording = true;
      currentSessionId ??= const Uuid().v4();
      _audioAnalysisTimer?.cancel();
      _audioAnalysisTimer = Timer.periodic(
        Duration(seconds: config.samplingRates.audio),
        (_) => _analyzeAudioData(),
      );
    } catch (error) {
      onError(error, 'audio');
    }
  }

  Future<void> _analyzeAudioData() async {
    final Random random = Random();
    final double mockDecibels = 30 + random.nextDouble() * 40;
    final double mockPeak = mockDecibels + random.nextDouble() * 20;
    final AudioSensorData data = AudioSensorData(
      id: '',
      userId: '',
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      date: isoDate(DateTime.now()),
      averageDecibels: mockDecibels.toString(),
      peakDecibels: mockPeak.toString(),
      frequencyBands: FrequencyBands(
        low: (random.nextDouble() * 40).toString(),
        mid: (random.nextDouble() * 50).toString(),
        high: (random.nextDouble() * 30).toString(),
      ),
      snoreDetected: random.nextDouble() > 0.9,
      ambientNoiseLevel: categorizeNoiseLevel(mockDecibels),
    );
    onAudioData(data);
    await _analyzeIfChanged(TransparencyChannel.microphone);
  }

  @override
  Future<void> startLightMonitoring() async {
    // MIGRATION: iOS light sensor is explicitly unsupported and shown as a
    //            SensorNotAvailableWidget in the UI. The service keeps a
    //            simulated fallback so Demo Mode remains usable.
    transparencyBloc.setChannel(
      TransparencyChannel.light,
      defaultLightSensorTransparencyEvent().copyWith(
        backgroundMode: true,
        samplingRate: config.samplingRates.light,
      ),
    );
    _lightFallbackTimer?.cancel();
    _lightFallbackTimer = Timer.periodic(
      Duration(seconds: config.samplingRates.light),
      (_) {
        final double mockLux = Random().nextDouble() * 20;
        unawaited(
          onLightData(
            LightSensorData(
              id: '',
              userId: '',
              timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
              date: isoDate(DateTime.now()),
              illuminance: mockLux.toString(),
              lightLevel: categorizeLightLevel(mockLux),
            ),
          ),
        );
      },
    );
  }

  @override
  Future<void> stopAccelerometerMonitoring() async {
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
  }

  @override
  Future<void> stopAudioMonitoring() async {
    _audioAnalysisTimer?.cancel();
    _audioAnalysisTimer = null;
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
  }

  @override
  Future<void> stopLightMonitoring() async {
    _lightFallbackTimer?.cancel();
    _lightFallbackTimer = null;
  }

  Future<void> _analyzeIfChanged(TransparencyChannel channel) async {
    try {
      final TransparencyEvent updated = await transparencyService
          .analyzePrivacyRisks(transparencyBloc.state.eventFor(channel));
      transparencyBloc.setChannel(channel, updated);
    } catch (error) {
      debugPrint('Error analyzing privacy risks: $error');
    }
  }
}

class SimulationSensorService extends SensorService {
  SimulationSensorService({
    required super.config,
    required super.transparencyBloc,
    required super.profileCubit,
    required super.transparencyService,
  });

  final List<Timer> _timers = <Timer>[];

  @override
  Future<bool> isAccelerometerAvailable() async => true;

  @override
  Future<bool> isAudioAvailable() async => true;

  @override
  Future<bool> isLightAvailable() async => true;

  @override
  Future<void> startAccelerometerMonitoring() async {
    transparencyBloc.setChannel(
      TransparencyChannel.accelerometer,
      defaultAccelerometerTransparencyEvent().copyWith(
        userConsent:
            profileCubit.state.userConsentPreferences.accelerometerEnabled,
        backgroundMode: true,
        samplingRate: config.samplingRates.accelerometer,
      ),
    );
    _timers.add(
      Timer.periodic(
        Duration(seconds: config.samplingRates.accelerometer),
        (_) => _generateMockAccelerometerData(),
      ),
    );
  }

  @override
  Future<void> startAudioMonitoring() async {
    transparencyBloc.setChannel(
      TransparencyChannel.microphone,
      defaultMicrophoneTransparencyEvent().copyWith(
        userConsent:
            profileCubit.state.userConsentPreferences.microphoneEnabled,
        backgroundMode: true,
        samplingRate: config.samplingRates.audio,
      ),
    );
    _timers.add(
      Timer.periodic(
        Duration(seconds: config.samplingRates.audio),
        (_) => _generateMockAudioData(),
      ),
    );
  }

  @override
  Future<void> startLightMonitoring() async {
    transparencyBloc.setChannel(
      TransparencyChannel.light,
      defaultLightSensorTransparencyEvent().copyWith(
        userConsent:
            profileCubit.state.userConsentPreferences.lightSensorEnabled,
        backgroundMode: true,
        samplingRate: config.samplingRates.light,
      ),
    );
    _timers.add(
      Timer.periodic(
        Duration(seconds: config.samplingRates.light),
        (_) => _generateMockLightData(),
      ),
    );
  }

  void _clearAllTimers() {
    for (final Timer timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  @override
  Future<void> stopAccelerometerMonitoring() async => _clearAllTimers();

  @override
  Future<void> stopAudioMonitoring() async => _clearAllTimers();

  @override
  Future<void> stopLightMonitoring() async => _clearAllTimers();

  void _generateMockAudioData() {
    final Random random = Random();
    final int hour = DateTime.now().hour;
    final bool isNightTime = hour >= 22 || hour <= 6;
    final double baseDecibels = isNightTime ? 25 : 35;
    final double mockDecibels = baseDecibels + random.nextDouble() * 30;
    unawaited(
      onAudioData(
        AudioSensorData(
          id: '',
          userId: '',
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
          date: isoDate(DateTime.now()),
          averageDecibels: mockDecibels.toString(),
          peakDecibels: (mockDecibels + random.nextDouble() * 20).toString(),
          frequencyBands: FrequencyBands(
            low: (random.nextDouble() * 40).toString(),
            mid: (random.nextDouble() * 50).toString(),
            high: (random.nextDouble() * 30).toString(),
          ),
          snoreDetected: random.nextDouble() > 0.85,
          ambientNoiseLevel: categorizeNoiseLevel(mockDecibels),
        ),
      ),
    );
  }

  void _generateMockLightData() {
    final Random random = Random();
    final int hour = DateTime.now().hour;
    final double mockLux = hour >= 22 || hour <= 6
        ? random.nextDouble() * 5
        : hour >= 7 && hour <= 9
        ? random.nextDouble() * 200
        : random.nextDouble() * 500;
    unawaited(
      onLightData(
        LightSensorData(
          id: '',
          userId: '',
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
          date: isoDate(DateTime.now()),
          illuminance: mockLux.toString(),
          lightLevel: categorizeLightLevel(mockLux),
        ),
      ),
    );
  }

  void _generateMockAccelerometerData() {
    final Random random = Random();
    final bool isAsleep = random.nextDouble() > 0.7;
    final double baseMovement = isAsleep ? 0.05 : 0.3;
    final double x = (random.nextDouble() - 0.5) * baseMovement;
    final double y = (random.nextDouble() - 0.5) * baseMovement;
    final double z = (random.nextDouble() - 0.5) * baseMovement;
    final double magnitude = sqrt(x * x + y * y + z * z);
    unawaited(
      onAccelerometerData(
        AccelerometerSensorData(
          id: '',
          userId: '',
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
          date: isoDate(DateTime.now()),
          x: x.toString(),
          y: y.toString(),
          z: z.toString(),
          magnitude: magnitude.toString(),
          movementIntensity: categorizeMovement(magnitude),
        ),
      ),
    );
  }
}

class SensorRepository {
  SensorRepository({
    required FlutterSensorService realSensorService,
    required SimulationSensorService simulationSensorService,
    required SensorStorageRepository sensorStorageRepository,
    required ProfileCubit profileCubit,
  }) : _realSensorService = realSensorService,
       _simulationSensorService = simulationSensorService,
       _sensorStorageRepository = sensorStorageRepository,
       _currentSensorService = realSensorService {
    _sensorConfig = SensorServiceConfig.defaults.copyWith(
      audioEnabled: profileCubit.state.userConsentPreferences.microphoneEnabled,
      lightEnabled:
          profileCubit.state.userConsentPreferences.lightSensorEnabled,
      accelerometerEnabled:
          profileCubit.state.userConsentPreferences.accelerometerEnabled,
    );
    _setupDataCallbacks(_realSensorService);
    _setupDataCallbacks(_simulationSensorService);
    setSimulationMode();
  }

  final FlutterSensorService _realSensorService;
  final SimulationSensorService _simulationSensorService;
  final SensorStorageRepository _sensorStorageRepository;
  late SensorServiceConfig _sensorConfig;
  SensorService _currentSensorService;

  void setSimulationMode() {
    if (isRecordingActive()) {
      throw StateError(
        'Cannot switch sensor mode while recording is active. Stop recording first.',
      );
    }
    _currentSensorService = _sensorConfig.useSimulation
        ? _simulationSensorService
        : _realSensorService;
    _currentSensorService.updateConfig(_sensorConfig);
  }

  Future<void> startAllSensors() async {
    final List<Future<void>> jobs = <Future<void>>[];
    if ((inDemoMode && TransparencyDemoConfig.collectAudio) ||
        (!inDemoMode && _sensorConfig.audioEnabled)) {
      jobs.add(_currentSensorService.startAudioMonitoring());
    }
    if ((inDemoMode && TransparencyDemoConfig.collectLight) ||
        (!inDemoMode && _sensorConfig.lightEnabled)) {
      jobs.add(_currentSensorService.startLightMonitoring());
    }
    if ((inDemoMode && TransparencyDemoConfig.collectAccelerometer) ||
        (!inDemoMode && _sensorConfig.accelerometerEnabled)) {
      jobs.add(_currentSensorService.startAccelerometerMonitoring());
    }
    await Future.wait(jobs);
  }

  Future<void> stopAllSensors() async {
    await Future.wait(<Future<void>>[
      _currentSensorService.stopAudioMonitoring(),
      _currentSensorService.stopLightMonitoring(),
      _currentSensorService.stopAccelerometerMonitoring(),
    ]);
  }

  Future<void> startAudioMonitoring() async {
    if ((inDemoMode && !TransparencyDemoConfig.collectAudio) ||
        (!inDemoMode && !_sensorConfig.audioEnabled)) {
      throw StateError('Audio monitoring is disabled in configuration');
    }
    await _currentSensorService.startAudioMonitoring();
  }

  Future<void> startLightMonitoring() async {
    if ((inDemoMode && !TransparencyDemoConfig.collectLight) ||
        (!inDemoMode && !_sensorConfig.lightEnabled)) {
      throw StateError('Light monitoring is disabled in configuration');
    }
    await _currentSensorService.startLightMonitoring();
  }

  Future<void> startAccelerometerMonitoring() async {
    if ((inDemoMode && !TransparencyDemoConfig.collectAccelerometer) ||
        (!inDemoMode && !_sensorConfig.accelerometerEnabled)) {
      throw StateError('Accelerometer monitoring is disabled in configuration');
    }
    await _currentSensorService.startAccelerometerMonitoring();
  }

  Future<void> stopAudioMonitoring() =>
      _currentSensorService.stopAudioMonitoring();
  Future<void> stopLightMonitoring() =>
      _currentSensorService.stopLightMonitoring();
  Future<void> stopAccelerometerMonitoring() =>
      _currentSensorService.stopAccelerometerMonitoring();

  bool isRecordingActive() => _currentSensorService.isRecording;

  void updateConfig(SensorServiceConfigPatch patch) {
    _sensorConfig = _sensorConfig.copyWith(
      useSimulation: patch.useSimulation,
      audioEnabled: patch.audioEnabled,
      lightEnabled: patch.lightEnabled,
      accelerometerEnabled: patch.accelerometerEnabled,
    );
    _realSensorService.updateConfig(_sensorConfig);
    _simulationSensorService.updateConfig(_sensorConfig);
  }

  SensorServiceConfig getConfig() => _sensorConfig;

  void _setupDataCallbacks(SensorService sensorService) {
    sensorService.audioDataHandler = (AudioSensorData data) async {
      await _sensorStorageRepository.createSensorReading(data);
    };
    sensorService.lightDataHandler = (LightSensorData data) async {
      await _sensorStorageRepository.createSensorReading(data);
    };
    sensorService.accelerometerDataHandler =
        (AccelerometerSensorData data) async {
          await _sensorStorageRepository.createSensorReading(data);
        };
  }
}

class SensorBackgroundTaskManager {
  SensorBackgroundTaskManager({required SensorRepository sensorRepository})
    : _sensorRepository = sensorRepository {
    _service.on('accelerometerSample').listen((Map<String, dynamic>? event) {
      if (event == null) {
        return;
      }
      final double x = (event['x'] as num?)?.toDouble() ?? 0;
      final double y = (event['y'] as num?)?.toDouble() ?? 0;
      final double z = (event['z'] as num?)?.toDouble() ?? 0;
      final double magnitude = (event['magnitude'] as num?)?.toDouble() ?? 0;
      final AccelerometerSensorData data = AccelerometerSensorData(
        id: '',
        userId: '',
        timestamp:
            (event['timestamp'] as int? ??
                    DateTime.now().millisecondsSinceEpoch)
                .toString(),
        date: isoDate(DateTime.now()),
        x: x.toString(),
        y: y.toString(),
        z: z.toString(),
        magnitude: magnitude.toString(),
        movementIntensity: _categorizeMovement(magnitude),
      );
      unawaited(
        _sensorRepository._sensorStorageRepository
            .createSensorReading(data)
            .catchError((Object error) {
              debugPrint('Background accelerometer sample ignored: $error');
              return data;
            }),
      );
    });
  }

  final SensorRepository _sensorRepository;
  final FlutterBackgroundService _service = FlutterBackgroundService();

  Future<void> registerAccelerometer() async {
    final SensorServiceConfig config = _sensorRepository.getConfig();
    final bool shouldCollect = inDemoMode
        ? TransparencyDemoConfig.collectAccelerometer
        : config.accelerometerEnabled;
    if (!shouldCollect) {
      if (await _service.isRunning()) {
        _service.invoke('stopService');
      }
      await _sensorRepository.stopAccelerometerMonitoring();
      return;
    }
    if (!await _service.isRunning()) {
      await _service.startService();
    }
    _service.invoke('startAccelerometer', <String, dynamic>{
      'samplingSeconds': config.samplingRates.accelerometer,
    });
    try {
      await _sensorRepository.startAccelerometerMonitoring();
    } catch (_) {
      // MIGRATION: Demo mode may intentionally disable accelerometer collection
      //            through transparencyDemoConfig, matching the source toggle.
    }
  }

  Future<void> registerLightSensor() async {
    try {
      await _sensorRepository.startLightMonitoring();
    } catch (_) {}
  }

  Future<void> registerAudioSensor() async {
    try {
      await _sensorRepository.startAudioMonitoring();
    } catch (_) {}
  }

  Future<void> updateConfig(SensorServiceConfigPatch newConfig) async {
    _sensorRepository.updateConfig(newConfig);
    if (newConfig.useSimulation != null) {
      _sensorRepository.setSimulationMode();
    }
    if (newConfig.accelerometerEnabled != null) {
      await _sensorRepository.stopAccelerometerMonitoring();
      await registerAccelerometer();
    }
    if (newConfig.audioEnabled != null) {
      await _sensorRepository.stopAudioMonitoring();
      await registerAudioSensor();
    }
    if (newConfig.lightEnabled != null) {
      await _sensorRepository.stopLightMonitoring();
      await registerLightSensor();
    }
  }
}

MovementIntensity _categorizeMovement(double magnitude) {
  if (magnitude < 0.1) return MovementIntensity.still;
  if (magnitude < 0.5) return MovementIntensity.light;
  if (magnitude < 1.0) return MovementIntensity.moderate;
  return MovementIntensity.active;
}

class TransparencyService {
  TransparencyService({
    required HttpClient httpClient,
    required String? Function() getToken,
    required ProfileCubit profileCubit,
  }) : _httpClient = httpClient,
       _getToken = getToken,
       _profileCubit = profileCubit;

  final HttpClient _httpClient;
  final String? Function() _getToken;
  final ProfileCubit _profileCubit;

  Future<TransparencyEvent> analyzePrivacyRisks(
    TransparencyEvent transparencyEvent,
  ) async {
    final String? token = _getToken();
    if (token == null) {
      return transparencyEvent;
    }
    final Map<String, Object?> prompt = <String, Object?>{
      'transparencyEvent': transparencyEvent.toJson(),
      'privacyPolicy': '{}',
      'userConsentPreferences': _profileCubit.state.userConsentPreferences
          .toJson(),
      'regulationFrameworks': <String>[RegulatoryFramework.pipeda.wireName],
      'pipedaRegulations': '{}',
    };
    final Map<String, Object?> response = await _httpClient.post(
      '/transparency/ai/',
      prompt,
      token: token,
    );
    final Object? event = response['transparencyEvent'];
    return event is Map<String, Object?>
        ? TransparencyEvent.fromJson(event)
        : transparencyEvent;
  }
}

class AppServices {
  const AppServices({
    required this.journalDataRepository,
    required this.generalSleepDataRepository,
    required this.sensorBackgroundTaskManager,
  });

  final JournalDataRepository journalDataRepository;
  final GeneralSleepDataRepository generalSleepDataRepository;
  final SensorBackgroundTaskManager sensorBackgroundTaskManager;

  static AppServices create({
    required AuthCubit authCubit,
    required ProfileCubit profileCubit,
    required TransparencyBloc transparencyBloc,
    required LocalDatabaseManager databaseManager,
    required FlutterSecureStorage secureStorage,
  }) {
    final CloudStorageService httpClient = CloudStorageService(apiBaseUrl)
      ..transparencyBloc = transparencyBloc;
    String? getToken() => authCubit.state.token;
    final TransparencyService transparencyService = TransparencyService(
      httpClient: httpClient,
      getToken: getToken,
      profileCubit: profileCubit,
    );
    final EncryptionService encryptionService = EncryptionService(
      secureStorage: secureStorage,
      transparencyBloc: transparencyBloc,
    );
    final LocalJournalDataSource localJournalDataSource =
        LocalJournalDataSource(
          dbManager: databaseManager,
          transparencyBloc: transparencyBloc,
        );
    final CloudJournalDataSource cloudJournalDataSource =
        CloudJournalDataSource(httpClient: httpClient, getToken: getToken);
    final JournalDataRepository journalDataRepository = JournalDataRepository(
      cloudDataSource: cloudJournalDataSource,
      localDataSource: localJournalDataSource,
      encryptionService: encryptionService,
      authCubit: authCubit,
      profileCubit: profileCubit,
      transparencyBloc: transparencyBloc,
    );
    final LocalSensorDataSource localSensorDataSource = LocalSensorDataSource(
      dbManager: databaseManager,
      transparencyBloc: transparencyBloc,
    );
    final CloudSensorDataSource cloudSensorDataSource = CloudSensorDataSource(
      httpClient: httpClient,
      getToken: getToken,
    );
    final SensorStorageRepository sensorStorageRepository =
        SensorStorageRepository(
          cloudDataSource: cloudSensorDataSource,
          localDataSource: localSensorDataSource,
          encryptionService: encryptionService,
          authCubit: authCubit,
          profileCubit: profileCubit,
          transparencyBloc: transparencyBloc,
        );
    final FlutterSensorService flutterSensorService = FlutterSensorService(
      config: SensorServiceConfig.defaults,
      transparencyBloc: transparencyBloc,
      profileCubit: profileCubit,
      transparencyService: transparencyService,
    );
    final SimulationSensorService simulationSensorService =
        SimulationSensorService(
          config: SensorServiceConfig.defaults,
          transparencyBloc: transparencyBloc,
          profileCubit: profileCubit,
          transparencyService: transparencyService,
        );
    final SensorRepository sensorRepository = SensorRepository(
      realSensorService: flutterSensorService,
      simulationSensorService: simulationSensorService,
      sensorStorageRepository: sensorStorageRepository,
      profileCubit: profileCubit,
    );
    final LocalGeneralSleepDataSource localSleepDataSource =
        LocalGeneralSleepDataSource(secureStorage: secureStorage);
    final CloudGeneralSleepDataSource cloudSleepDataSource =
        CloudGeneralSleepDataSource(httpClient: httpClient, getToken: getToken);
    final GeneralSleepDataRepository sleepDataRepository =
        GeneralSleepDataRepository(
          cloudDataSource: cloudSleepDataSource,
          localDataSource: localSleepDataSource,
          encryptionService: encryptionService,
          authCubit: authCubit,
          profileCubit: profileCubit,
        );
    return AppServices(
      journalDataRepository: journalDataRepository,
      generalSleepDataRepository: sleepDataRepository,
      sensorBackgroundTaskManager: SensorBackgroundTaskManager(
        sensorRepository: sensorRepository,
      ),
    );
  }
}

String isoDate(DateTime date) => date.toIso8601String().split('T').first;

class SleepTrackerApp extends StatefulWidget {
  const SleepTrackerApp({
    super.key,
    required this.authCubit,
    required this.profileCubit,
    required this.transparencyBloc,
    required this.services,
  });

  final AuthCubit authCubit;
  final ProfileCubit profileCubit;
  final TransparencyBloc transparencyBloc;
  final AppServices services;

  @override
  State<SleepTrackerApp> createState() => _SleepTrackerAppState();
}

class _SleepTrackerAppState extends State<SleepTrackerApp> {
  late final AppRouterNotifier _routerNotifier;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _routerNotifier = AppRouterNotifier(
      authCubit: widget.authCubit,
      profileCubit: widget.profileCubit,
    );
    _router = buildRouter(_routerNotifier, widget.services);
  }

  @override
  void dispose() {
    _routerNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: <RepositoryProvider<Object>>[
        RepositoryProvider<AppServices>.value(value: widget.services),
      ],
      child: MultiBlocProvider(
        providers: <BlocProvider>[
          BlocProvider<AuthCubit>.value(value: widget.authCubit),
          BlocProvider<ProfileCubit>.value(value: widget.profileCubit),
          BlocProvider<TransparencyBloc>.value(value: widget.transparencyBloc),
        ],
        child: MaterialApp.router(
          title: 'GPT Sleep Tracker Flutter',
          routerConfig: _router,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: false,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: AppColors.appBackground,
            fontFamily: 'SpaceMono',
            colorScheme: const ColorScheme.dark(
              primary: AppColors.accent,
              secondary: AppColors.generalBlue,
              surface: AppColors.lightBlack,
            ),
            textTheme: const TextTheme(
              bodyMedium: TextStyle(color: Colors.white, letterSpacing: 0),
              bodyLarge: TextStyle(color: Colors.white, letterSpacing: 0),
              titleLarge: TextStyle(color: Colors.white, letterSpacing: 0),
            ),
          ),
        ),
      ),
    );
  }
}

class AppRouterNotifier extends ChangeNotifier {
  AppRouterNotifier({
    required AuthCubit authCubit,
    required ProfileCubit profileCubit,
  }) : _authSubscription = authCubit.stream.listen((AuthState _) {}),
       _profileSubscription = profileCubit.stream.listen((ProfileState _) {}) {
    _authSubscription.onData((AuthState _) => notifyListeners());
    _profileSubscription.onData((ProfileState _) => notifyListeners());
  }

  late final StreamSubscription<AuthState> _authSubscription;
  late final StreamSubscription<ProfileState> _profileSubscription;

  @override
  void dispose() {
    _authSubscription.cancel();
    _profileSubscription.cancel();
    super.dispose();
  }
}

GoRouter buildRouter(AppRouterNotifier notifier, AppServices services) {
  return GoRouter(
    initialLocation: '/sleep',
    refreshListenable: notifier,
    routes: <RouteBase>[
      GoRoute(
        path: '/auth',
        builder: (BuildContext context, GoRouterState state) =>
            const AuthPage(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (BuildContext context, GoRouterState state) =>
            const OnboardingPage(),
      ),
      GoRoute(
        path: '/privacy-policy',
        builder: (BuildContext context, GoRouterState state) =>
            PrivacyPolicyPage(
              sectionId: state.uri.queryParameters['sectionId'],
            ),
      ),
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) {
          return TabShell(location: state.uri.path, child: child);
        },
        routes: <RouteBase>[
          GoRoute(
            path: '/sleep',
            builder: (BuildContext context, GoRouterState state) =>
                const SleepPage(),
            routes: <RouteBase>[
              GoRoute(
                path: 'sleep-mode',
                builder: (BuildContext context, GoRouterState state) =>
                    const SleepModePage(),
              ),
            ],
          ),
          GoRoute(
            path: '/journal',
            builder: (BuildContext context, GoRouterState state) =>
                const JournalPage(),
          ),
          GoRoute(
            path: '/statistics',
            builder: (BuildContext context, GoRouterState state) =>
                const StatisticsPage(),
          ),
          GoRoute(
            path: '/profile',
            builder: (BuildContext context, GoRouterState state) =>
                const ProfilePage(),
            routes: <RouteBase>[
              GoRoute(
                path: 'consent-preferences',
                builder: (BuildContext context, GoRouterState state) =>
                    const ConsentPreferencesPage(),
              ),
            ],
          ),
        ],
      ),
    ],
    redirect: (BuildContext context, GoRouterState state) {
      final AuthState auth = context.read<AuthCubit>().state;
      final ProfileState profile = context.read<ProfileCubit>().state;
      final bool inAuth = state.uri.path == '/auth';
      final bool inOnboarding = state.uri.path == '/onboarding';
      final bool onboardingComplete =
          profile.hasCompletedPrivacyOnboarding &&
          profile.hasCompletedAppOnboarding;
      if (!auth.isAuthenticated && !inAuth) {
        return '/auth';
      }
      if (auth.isAuthenticated && !onboardingComplete && !inOnboarding) {
        return '/onboarding';
      }
      if (auth.isAuthenticated && onboardingComplete && inOnboarding) {
        return '/sleep';
      }
      if (auth.isAuthenticated && inAuth) {
        return onboardingComplete ? '/sleep' : '/onboarding';
      }
      return null;
    },
  );
}

class TabShell extends StatelessWidget {
  const TabShell({super.key, required this.child, required this.location});

  final Widget child;
  final String location;

  @override
  Widget build(BuildContext context) {
    final bool hideTabs = location == '/sleep/sleep-mode';
    return Scaffold(
      body: child,
      bottomNavigationBar: hideTabs
          ? null
          : BottomNavigationBar(
              type: BottomNavigationBarType.fixed,
              backgroundColor: AppColors.lightBlack,
              selectedItemColor: AppColors.generalBlue,
              unselectedItemColor: AppColors.grey,
              currentIndex: _indexForLocation(location),
              onTap: (int index) {
                context.go(
                  <String>[
                    '/sleep',
                    '/journal',
                    '/statistics',
                    '/profile',
                  ][index],
                );
              },
              items: const <BottomNavigationBarItem>[
                BottomNavigationBarItem(
                  icon: Icon(Icons.nightlight_round),
                  label: 'Sleep',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.description_outlined),
                  label: 'Journal',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.bar_chart_outlined),
                  label: 'Statistics',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  label: 'Profile',
                ),
              ],
            ),
    );
  }

  int _indexForLocation(String location) {
    if (location.startsWith('/journal')) return 1;
    if (location.startsWith('/statistics')) return 2;
    if (location.startsWith('/profile')) return 3;
    return 0;
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final TextEditingController _firstName = TextEditingController();
  final TextEditingController _lastName = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirmPassword = TextEditingController();
  bool _register = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: BlocBuilder<AuthCubit, AuthState>(
          builder: (BuildContext context, AuthState state) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ListView(
                padding: const EdgeInsets.only(top: 40),
                children: <Widget>[
                  Text(
                    _register ? 'Register Now!' : 'Welcome Back!',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _register ? 'Create an account' : 'Sign in to your account',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 40),
                  if (_register) ...<Widget>[
                    AuthInputField(
                      controller: _email,
                      placeholder: 'Email',
                      keyboardType: TextInputType.emailAddress,
                      textCapitalization: TextCapitalization.none,
                    ),
                    AuthInputField(
                      controller: _firstName,
                      placeholder: 'First Name',
                      textCapitalization: TextCapitalization.words,
                    ),
                    AuthInputField(
                      controller: _lastName,
                      placeholder: 'Last Name',
                      textCapitalization: TextCapitalization.words,
                    ),
                    AuthInputField(
                      controller: _password,
                      placeholder: 'Password',
                      secureTextEntry: true,
                      showPasswordToggle: true,
                    ),
                    AuthInputField(
                      controller: _confirmPassword,
                      placeholder: 'Confirm Password',
                      secureTextEntry: true,
                      showPasswordToggle: true,
                    ),
                  ] else ...<Widget>[
                    AuthInputField(
                      controller: _email,
                      placeholder: 'Email',
                      keyboardType: TextInputType.emailAddress,
                      textCapitalization: TextCapitalization.none,
                    ),
                    AuthInputField(
                      controller: _password,
                      placeholder: 'Password',
                      secureTextEntry: true,
                      showPasswordToggle: true,
                    ),
                  ],
                  if (state.errorMessage != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      state.errorMessage!,
                      style: const TextStyle(color: AppColors.tooltipRed),
                    ),
                    const SizedBox(height: 8),
                  ],
                  AuthPrimaryButton(
                    label: state.isLoading
                        ? 'Loading...'
                        : _register
                        ? 'Register'
                        : 'Sign In',
                    onPressed: state.isLoading
                        ? null
                        : () async {
                            if (_register &&
                                _password.text != _confirmPassword.text) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Passwords do not match'),
                                ),
                              );
                              return;
                            }
                            final AuthCubit auth = context.read<AuthCubit>();
                            final bool ok = _register
                                ? await auth.register(
                                    _firstName.text,
                                    _lastName.text,
                                    _email.text,
                                    _password.text,
                                  )
                                : await auth.login(_email.text, _password.text);
                            if (ok && context.mounted) {
                              final ProfileState profile = context
                                  .read<ProfileCubit>()
                                  .state;
                              final bool onboardingComplete =
                                  profile.hasCompletedPrivacyOnboarding &&
                                  profile.hasCompletedAppOnboarding;
                              context.go(
                                onboardingComplete ? '/sleep' : '/onboarding',
                              );
                            }
                          },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        _register
                            ? 'Do you have an account? '
                            : "Don't have an account? ",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => setState(() => _register = !_register),
                        child: Text(
                          _register ? 'Sign In' : 'Register',
                          style: const TextStyle(
                            color: AppColors.hyperlinkBlue,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class AuthInputField extends StatefulWidget {
  const AuthInputField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.secureTextEntry = false,
    this.showPasswordToggle = false,
    this.keyboardType = TextInputType.text,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController controller;
  final String placeholder;
  final bool secureTextEntry;
  final bool showPasswordToggle;
  final TextInputType keyboardType;
  final TextCapitalization textCapitalization;

  @override
  State<AuthInputField> createState() => _AuthInputFieldState();
}

class _AuthInputFieldState extends State<AuthInputField> {
  late bool _isPasswordVisible = !widget.secureTextEntry;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: AuthInput.tsx used a plain TextInput placeholder without a
    //            floating label. Flutter's TextField is styled to the same
    //            dimensions so login/register stay visually aligned.
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: widget.controller,
        keyboardType: widget.keyboardType,
        textCapitalization: widget.textCapitalization,
        obscureText: widget.secureTextEntry && !_isPasswordVisible,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          hintText: widget.placeholder,
          hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
          filled: true,
          fillColor: AppColors.inputFieldBackground,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          suffixIcon: widget.showPasswordToggle
              ? IconButton(
                  icon: Icon(
                    _isPasswordVisible
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: AppColors.inputFieldPlaceholder,
                    size: 24,
                  ),
                  onPressed: () =>
                      setState(() => _isPasswordVisible = !_isPasswordVisible),
                )
              : null,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.inputFieldSelected),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: GeneralButton.tsx renders TouchableOpacity with dark text and
    //            vertical 16px padding. ElevatedButton keeps native Flutter
    //            semantics while matching that React Native surface.
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.generalBlue,
          foregroundColor: AppColors.lightBlack,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class MigrationTextField extends StatelessWidget {
  const MigrationTextField({
    super.key,
    required this.controller,
    required this.label,
    this.maxLines = 1,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final int maxLines;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      obscureText: obscureText,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.inputFieldPlaceholder),
        filled: true,
        fillColor: AppColors.inputFieldBackground,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.inputFieldSelected),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class BlueButton extends StatelessWidget {
  const BlueButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.generalBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const OnboardingFlowPage();
  }
}

enum OnboardingStep {
  microphone,
  accelerometer,
  lightSensor,
  journalData,
  cloudStorage,
  privacyAgreement,
  transparency,
  questions,
}

class OnboardingFlowPage extends StatefulWidget {
  const OnboardingFlowPage({super.key});

  @override
  State<OnboardingFlowPage> createState() => _OnboardingFlowPageState();
}

class _OnboardingFlowPageState extends State<OnboardingFlowPage> {
  late OnboardingStep _step;
  bool _privacyPolicyAgreed = false;
  String? _selectedSleepOption;

  @override
  void initState() {
    super.initState();
    final ProfileState profile = context.read<ProfileCubit>().state;
    _step =
        profile.hasCompletedPrivacyOnboarding &&
            !profile.hasCompletedAppOnboarding
        ? OnboardingStep.questions
        : OnboardingStep.microphone;
    _privacyPolicyAgreed = profile.userConsentPreferences.agreedToPrivacyPolicy;
  }

  @override
  Widget build(BuildContext context) {
    final UserConsentPreferences preferences = context
        .watch<ProfileCubit>()
        .state
        .userConsentPreferences;
    return switch (_step) {
      OnboardingStep.microphone => OnboardingSensorConsentStep(
        imageAsset: 'assets/images/microphone-bg.png',
        showBack: false,
        purpose:
            'Your microphone will listen for sounds like snoring or sleep talking only while you are sleeping. Analyzing these sounds will help you detect potential sleep disruptions and get a clearer picture of your sleep environment.',
        linkText: 'Read more about sound data and snoring detection',
        sectionId: 'microphone',
        label:
            'Yes, you have permission to access my microphone to record my sleep sounds.',
        value: preferences.microphoneEnabled,
        onBack: _goBack,
        onChanged: _setMicrophoneEnabled,
        onContinue: () => _goTo(OnboardingStep.accelerometer),
      ),
      OnboardingStep.accelerometer => OnboardingSensorConsentStep(
        imageAsset: 'assets/images/running-bg.png',
        showBack: true,
        purpose:
            'The accelerometer on your device will be used to track your body movements during sleep and throughout the day continuously in the background. This will help us to correlate activity levels with sleep quality.',
        linkText: 'More about collecting activity data',
        sectionId: 'accelerometer',
        label:
            'Yes, you have my permission to access my accelerometer to track my activity levels.',
        value: preferences.accelerometerEnabled,
        onBack: _goBack,
        onChanged: _setAccelerometerEnabled,
        onContinue: () => _goTo(OnboardingStep.lightSensor),
      ),
      OnboardingStep.lightSensor => OnboardingSensorConsentStep(
        imageAsset: 'assets/images/bedroom-light-bg.png',
        showBack: true,
        purpose:
            'The ambient light sensor on your device will be used to monitor the light conditions in your sleep environment only while you are sleeping, helping us to understand how light exposure affects your sleep quality.',
        linkText: 'More about collecting ambient light data',
        sectionId: 'lightSensor',
        label:
            'Yes, you have my permission to access my light sensor to track ambient light levels.',
        value: preferences.lightSensorEnabled,
        onBack: _goBack,
        onChanged: (bool value) =>
            _updateConsent(preferences.copyWith(lightSensorEnabled: value)),
        onContinue: () => _goTo(OnboardingStep.journalData),
      ),
      OnboardingStep.journalData => OnboardingJournalDataStep(
        onBack: _goBack,
        onContinue: () => _goTo(OnboardingStep.cloudStorage),
      ),
      OnboardingStep.cloudStorage => OnboardingCloudStorageStep(
        value: preferences.cloudStorageEnabled,
        onBack: _goBack,
        onChanged: (bool value) =>
            _updateConsent(preferences.copyWith(cloudStorageEnabled: value)),
        onContinue: () => _goTo(OnboardingStep.privacyAgreement),
      ),
      OnboardingStep.privacyAgreement => OnboardingPrivacyAgreementStep(
        agreed: _privacyPolicyAgreed,
        onBack: _goBack,
        onToggle: () =>
            setState(() => _privacyPolicyAgreed = !_privacyPolicyAgreed),
        onContinue: _continueFromPrivacyAgreement,
      ),
      OnboardingStep.transparency => OnboardingTransparencyStep(
        onBack: _goBack,
        onContinue: _continueFromTransparency,
      ),
      OnboardingStep.questions => OnboardingQuestionsStep(
        selectedOption: _selectedSleepOption,
        onBack: _goBack,
        onOptionSelected: (String value) =>
            setState(() => _selectedSleepOption = value),
        onContinue: _finishQuestions,
      ),
    };
  }

  void _goTo(OnboardingStep step) {
    setState(() => _step = step);
  }

  void _goBack() {
    final int index = OnboardingStep.values.indexOf(_step);
    if (index <= 0) return;
    setState(() => _step = OnboardingStep.values[index - 1]);
  }

  Future<void> _updateConsent(UserConsentPreferences preferences) {
    return context.read<ProfileCubit>().setUserConsentPreferences(preferences);
  }

  Future<void> _setMicrophoneEnabled(bool value) async {
    final ProfileCubit profileCubit = context.read<ProfileCubit>();
    final UserConsentPreferences preferences =
        profileCubit.state.userConsentPreferences;
    if (value) {
      // MIGRATION: Expo Audio.requestPermissionsAsync is translated to
      //            record.AudioRecorder.hasPermission so the OS microphone
      //            permission gate remains attached to the consent toggle.
      final AudioRecorder recorder = AudioRecorder();
      final bool granted = await recorder.hasPermission();
      await recorder.dispose();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Microphone access denied. Enable it in device settings to use this feature.',
              ),
            ),
          );
        }
        await profileCubit.setUserConsentPreferences(
          preferences.copyWith(microphoneEnabled: false),
        );
        return;
      }
    }
    await profileCubit.setUserConsentPreferences(
      preferences.copyWith(microphoneEnabled: value),
    );
  }

  Future<void> _setAccelerometerEnabled(bool value) async {
    final ProfileCubit profileCubit = context.read<ProfileCubit>();
    final UserConsentPreferences preferences =
        profileCubit.state.userConsentPreferences;
    await profileCubit.setUserConsentPreferences(
      preferences.copyWith(accelerometerEnabled: value),
    );
    if (!mounted) return;
    // MIGRATION: Expo TaskManager background config becomes
    //            SensorBackgroundTaskManager so this onboarding toggle starts
    //            or stops the Android foreground accelerometer service.
    await context.read<AppServices>().sensorBackgroundTaskManager.updateConfig(
      SensorServiceConfigPatch(accelerometerEnabled: value),
    );
  }

  Future<void> _continueFromPrivacyAgreement() async {
    final ProfileCubit profileCubit = context.read<ProfileCubit>();
    await profileCubit.setUserConsentPreferences(
      profileCubit.state.userConsentPreferences.copyWith(
        agreedToPrivacyPolicy: _privacyPolicyAgreed,
      ),
    );
    _goTo(OnboardingStep.transparency);
  }

  Future<void> _continueFromTransparency() async {
    await context.read<ProfileCubit>().setHasCompletedPrivacyOnboarding(true);
    if (mounted) _goTo(OnboardingStep.questions);
  }

  Future<void> _finishQuestions() async {
    final String? selected = _selectedSleepOption;
    final AppServices services = context.read<AppServices>();
    final ProfileCubit profileCubit = context.read<ProfileCubit>();
    final String userId = context.read<AuthCubit>().state.user?.userId ?? '';
    if (selected != null) {
      try {
        await services.generalSleepDataRepository.createSleepData(
          GeneralSleepData(
            userId: userId,
            currentSleepDuration: selected,
            snoring: '',
            tirednessFrequency: '',
            daytimeSleepiness: '',
          ),
        );
      } catch (_) {
        // MIGRATION: The React Native question save is fire-and-forget and
        //            routing continues immediately. Flutter preserves that
        //            action model by not blocking onboarding completion here.
        // MIGRATION_FLAG: If the cloud endpoint is unavailable, this optional
        //                 onboarding answer may not persist until retried.
      }
    }
    await profileCubit.setHasCompletedAppOnboarding(true);
    if (mounted) context.go('/sleep');
  }
}

class OnboardingSensorConsentStep extends StatelessWidget {
  const OnboardingSensorConsentStep({
    super.key,
    required this.imageAsset,
    required this.showBack,
    required this.purpose,
    required this.linkText,
    required this.sectionId,
    required this.label,
    required this.value,
    required this.onBack,
    required this.onChanged,
    required this.onContinue,
  });

  final String imageAsset;
  final bool showBack;
  final String purpose;
  final String linkText;
  final String sectionId;
  final String label;
  final bool value;
  final VoidCallback onBack;
  final ValueChanged<bool> onChanged;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: Expo ImageBackground plus flex top/bottom halves map to a
    //            Flutter Column with Expanded children, preserving the
    //            launch-time permission screen composition.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: ImageBackgroundHeader(
              imageAsset: imageAsset,
              showBack: showBack,
              onBack: onBack,
            ),
          ),
          Expanded(
            flex: 4,
            child: OnboardingScrollablePanel(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const OnboardingSectionTitle('Purpose:'),
                  OnboardingBodyText(purpose),
                  OnboardingInlineLink(text: linkText, sectionId: sectionId),
                  PermissionsToggleLike(
                    value: value,
                    onChanged: onChanged,
                    label: label,
                    horizontalPadding: 0,
                  ),
                ],
              ),
              footer: AuthPrimaryButton(
                label: 'Continue',
                onPressed: onContinue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ImageBackgroundHeader extends StatelessWidget {
  const ImageBackgroundHeader({
    super.key,
    required this.imageAsset,
    required this.showBack,
    required this.onBack,
  });

  final String imageAsset;
  final bool showBack;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Image.asset(imageAsset, fit: BoxFit.cover),
        OnboardingFlowHeader(
          title: 'Your Privacy Matters to Us',
          onBack: showBack ? onBack : null,
        ),
      ],
    );
  }
}

class OnboardingScrollablePanel extends StatelessWidget {
  const OnboardingScrollablePanel({
    super.key,
    required this.body,
    required this.footer,
  });

  final Widget body;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: React Native flex screens tolerate shorter Android viewport
    //            heights more gracefully. Flutter reports a hard RenderFlex
    //            overflow, so the translated onboarding panels keep the same
    //            24/32/40 padding and space-between feel while allowing scroll
    //            when the device cannot fit the full permission copy + button.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    body,
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: footer,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class OnboardingJournalDataStep extends StatelessWidget {
  const OnboardingJournalDataStep({
    super.key,
    required this.onBack,
    required this.onContinue,
  });

  final VoidCallback onBack;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: ImageBackgroundHeader(
              imageAsset: 'assets/images/journal-bg.png',
              showBack: true,
              onBack: onBack,
            ),
          ),
          Expanded(
            flex: 6,
            child: OnboardingScrollablePanel(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const <Widget>[
                  OnboardingSectionTitle('Journal Data:'),
                  OnboardingBodyText(
                    "Information about your mood, habits, symptoms can help us correlate your personal experiences with your sleep patterns. You can voluntarily provide us with this data by making diary entries and sleep notes in the app's Journal section.",
                  ),
                  OnboardingInlineLink(
                    text: 'More about collecting journal data',
                    sectionId: 'journalData',
                  ),
                  OnboardingSectionTitle('Derived Data:'),
                  OnboardingBodyText(
                    'The app will derive data about you such as sleep quality, correlations, insights and recommendations. This will be treated as sensitive personal health information.',
                  ),
                  OnboardingInlineLink(
                    text: 'More about derived data',
                    sectionId: 'derivedData',
                  ),
                ],
              ),
              footer: AuthPrimaryButton(
                label: 'Continue',
                onPressed: onContinue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OnboardingCloudStorageStep extends StatelessWidget {
  const OnboardingCloudStorageStep({
    super.key,
    required this.value,
    required this.onBack,
    required this.onChanged,
    required this.onContinue,
  });

  final bool value;
  final VoidCallback onBack;
  final ValueChanged<bool> onChanged;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: <Widget>[
          OnboardingFlowHeader(
            title: 'Your Privacy Matters to Us',
            onBack: onBack,
          ),
          Expanded(
            child: OnboardingScrollablePanel(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const OnboardingSectionTitle('Data Storage'),
                  const OnboardingBodyText(
                    'By default all of your personal health information (data collected and derived data) will be stored on your mobile device. If you opt in, we will store your personal health information in the cloud, allowing us to provide more complex sleep analysis. All data will be encrypted while in storage and when it is being transmitted.',
                  ),
                  PermissionsToggleLike(
                    value: value,
                    onChanged: onChanged,
                    label:
                        'Yes, you have my permission to store my personal health information on secure Google Cloud servers',
                    horizontalPadding: 0,
                  ),
                  const OnboardingSectionTitle('Data Access:'),
                  const OnboardingBodyText(
                    'We are committed to strict limitations on data sharing. We do not give your personal information to any third parties for marketing, advertising, or any other commercial purposes.',
                  ),
                  const OnboardingInlineLink(
                    text: 'More about data storage and data access',
                    sectionId: 'cloudVsLocalStorage',
                  ),
                ],
              ),
              footer: AuthPrimaryButton(
                label: 'Continue',
                onPressed: onContinue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OnboardingPrivacyAgreementStep extends StatelessWidget {
  const OnboardingPrivacyAgreementStep({
    super.key,
    required this.agreed,
    required this.onBack,
    required this.onToggle,
    required this.onContinue,
  });

  final bool agreed;
  final VoidCallback onBack;
  final VoidCallback onToggle;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: <Widget>[
          OnboardingFlowHeader(
            title: 'Your Privacy Matters to Us',
            onBack: onBack,
          ),
          Expanded(
            child: OnboardingScrollablePanel(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const OnboardingBodyText(
                    'The previous screens explained the most important parts of the privacy policy.\nBefore you proceed, please review the full Privacy Policy to understand in greater detail how we collect, use, and protect your health data.',
                  ),
                  const OnboardingInlineLink(
                    text: 'Read our full Privacy Policy',
                    sectionId: '',
                    fontSize: 16,
                  ),
                  InkWell(
                    onTap: onToggle,
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 24,
                          height: 24,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            color: agreed
                                ? AppColors.generalBlue
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: AppColors.generalBlue,
                              width: 2,
                            ),
                          ),
                          child: agreed
                              ? const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 16,
                                )
                              : null,
                        ),
                        const Expanded(
                          child: Text(
                            'I have read and agree to the Privacy Policy.',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              footer: AuthPrimaryButton(
                label: 'Continue',
                onPressed: agreed ? onContinue : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OnboardingTransparencyStep extends StatelessWidget {
  const OnboardingTransparencyStep({
    super.key,
    required this.onBack,
    required this.onContinue,
  });

  final VoidCallback onBack;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: <Widget>[
          OnboardingFlowHeader(
            title: 'Your Privacy Matters to Us',
            onBack: onBack,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const OnboardingSectionTitle(
                              'Privacy Features In this App',
                            ),
                            const OnboardingBodyText(
                              'This prototype app is designed to prioritize transparency by embedding details about data collection within the UI. Our real-time privacy analysis system monitors data collection and provides instant visual feedback through dynamic privacy icons.',
                            ),
                            const Text(
                              'Key Features:',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const OnboardingBullet(
                              bold: 'Tooltip System:',
                              text:
                                  ' Click privacy icons next to data types for contextual information',
                            ),
                            const OnboardingBullet(
                              bold: 'Privacy Pages:',
                              text:
                                  ' Transform entire screens to show comprehensive privacy details',
                            ),
                            const OnboardingBullet(
                              bold: 'Real-time Analysis:',
                              text:
                                  ' AI-powered system detects and explains privacy risks as they occur',
                            ),
                            const SizedBox(height: 24),
                            const Center(
                              child: Text(
                                'Privacy Risk Indicators',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const PrivacyRiskIconRow(),
                            const SizedBox(height: 24),
                            const Center(
                              child: Text(
                                'Sensor Data Icons',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Below are examples of icons used to convey sensor data privacy risks:',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const SensorIconExamples(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AuthPrimaryButton(label: 'Continue', onPressed: onContinue),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OnboardingQuestionsStep extends StatelessWidget {
  const OnboardingQuestionsStep({
    super.key,
    required this.selectedOption,
    required this.onBack,
    required this.onOptionSelected,
    required this.onContinue,
  });

  final String? selectedOption;
  final VoidCallback onBack;
  final ValueChanged<String> onOptionSelected;
  final VoidCallback onContinue;

  static const List<String> _sleepOptions = <String>[
    '6 hours or less',
    '6 - 8 hours',
    '8 - 10 hours',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            OnboardingFlowHeader(title: '', onBack: onBack),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Text(
                    'How much sleep do you usually get at night?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 32),
                  ..._sleepOptions.map<Widget>((String option) {
                    final bool isSelected = selectedOption == option;
                    return OnboardingQuestionOptionLike(
                      label: option,
                      isSelected: isSelected,
                      onPressed: () => onOptionSelected(option),
                    );
                  }),
                ],
              ),
            ),
            AuthPrimaryButton(label: 'Continue', onPressed: onContinue),
          ],
        ),
      ),
    );
  }
}

class OnboardingFlowHeader extends StatelessWidget {
  const OnboardingFlowHeader({super.key, required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.only(top: 60, bottom: 20),
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(
                Icons.chevron_left,
                color: AppColors.generalBlue,
                size: 24,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            ),
          if (onBack != null) const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              textAlign: onBack == null ? TextAlign.center : TextAlign.left,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OnboardingSectionTitle extends StatelessWidget {
  const OnboardingSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class OnboardingBodyText extends StatelessWidget {
  const OnboardingBodyText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5),
      ),
    );
  }
}

class OnboardingInlineLink extends StatelessWidget {
  const OnboardingInlineLink({
    super.key,
    required this.text,
    required this.sectionId,
    this.fontSize = 14,
  });

  final String text;
  final String sectionId;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final String query = sectionId.isEmpty ? '' : '?sectionId=$sectionId';
        context.push('/privacy-policy$query');
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 32),
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.hyperlinkBlue,
            fontSize: fontSize,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.hyperlinkBlue,
          ),
        ),
      ),
    );
  }
}

class OnboardingBullet extends StatelessWidget {
  const OnboardingBullet({super.key, required this.bold, required this.text});

  final String bold;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '• ',
            style: TextStyle(
              color: AppColors.generalBlue,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  height: 1.4,
                ),
                children: <InlineSpan>[
                  TextSpan(
                    text: bold,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PrivacyRiskIconRow extends StatelessWidget {
  const PrivacyRiskIconRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const <Widget>[
        Expanded(
          child: PrivacyRiskIconExample(
            iconName: 'privacy-high',
            label: 'Major Risk',
            description: 'Policy violations, unauthorized collection',
          ),
        ),
        Expanded(
          child: PrivacyRiskIconExample(
            iconName: 'privacy-medium',
            label: 'Medium Risk',
            description: 'Suboptimal practices, vague purposes',
          ),
        ),
        Expanded(
          child: PrivacyRiskIconExample(
            iconName: 'privacy-low',
            label: 'Low Risk',
            description:
                'Compliant, secure data handling. You will see this by default',
          ),
        ),
      ],
    );
  }
}

class PrivacyRiskIconExample extends StatelessWidget {
  const PrivacyRiskIconExample({
    super.key,
    required this.iconName,
    required this.label,
    required this.description,
  });

  final String iconName;
  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        PrivacyIcon(
          handleIconPress: () {},
          isOpen: false,
          iconName: iconName,
          iconSize: 40,
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

class SensorIconExamples extends StatelessWidget {
  const SensorIconExamples({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Expanded(
              child: SensorIconExample(
                iconName: 'privacy-high',
                storageType: 'cloud',
                sensorType: 'accelerometer',
                description:
                    'Major risk due to accelerometer data being stored in cloud',
              ),
            ),
            Expanded(
              child: SensorIconExample(
                iconName: 'privacy-medium',
                storageType: 'local',
                sensorType: 'light',
                description:
                    'Medium risk due to light sensor data being stored locally',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const SizedBox(
          width: 180,
          child: SensorIconExample(
            iconName: 'privacy-low',
            storageType: 'cloud',
            sensorType: 'microphone',
            description: 'Low risk from microphone data being stored in cloud',
          ),
        ),
      ],
    );
  }
}

class SensorIconExample extends StatelessWidget {
  const SensorIconExample({
    super.key,
    required this.iconName,
    required this.storageType,
    required this.sensorType,
    required this.description,
  });

  final String iconName;
  final String storageType;
  final String sensorType;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SensorPrivacyIcon(
          handleIconPress: () {},
          iconName: iconName,
          storageType: storageType,
          sensorType: sensorType,
        ),
        const SizedBox(height: 8),
        Text(
          description,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

class OnboardingQuestionOptionLike extends StatelessWidget {
  const OnboardingQuestionOptionLike({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onPressed,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.generalBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AppColors.generalBlue),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? Colors.white : AppColors.generalBlue,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (isSelected)
              const Positioned(
                right: 0,
                child: Icon(Icons.check_circle, color: Colors.white, size: 24),
              ),
          ],
        ),
      ),
    );
  }
}

class ConsentSwitch extends StatelessWidget {
  const ConsentSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      value: value,
      activeThumbColor: AppColors.generalBlue,
      onChanged: onChanged,
    );
  }
}

class SleepPage extends StatefulWidget {
  const SleepPage({super.key});

  @override
  State<SleepPage> createState() => _SleepPageState();
}

class _SleepPageState extends State<SleepPage> {
  bool _loading = true;
  String _bedtime = '';
  String _alarm = '';
  bool _displayNormalUi = true;

  @override
  void initState() {
    super.initState();
    _loadJournalData();
  }

  Future<void> _loadJournalData() async {
    try {
      final AppServices services = context.read<AppServices>();
      final JournalData? journal = await services.journalDataRepository
          .getJournalByDate(isoDate(DateTime.now()));
      if (journal != null) {
        _alarm = journal.alarmTime;
        _bedtime = journal.bedtime;
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveTime({String? bedtime, String? alarm}) async {
    final String date = isoDate(DateTime.now());
    final TransparencyBloc transparencyBloc = context.read<TransparencyBloc>();
    final TransparencyEvent event = defaultJournalTransparencyEvent();
    transparencyBloc.setChannel(TransparencyChannel.journal, event);
    await context.read<AppServices>().journalDataRepository.editJournal(
      JournalPatch(
        date: date,
        bedtime: bedtime,
        alarmTime: alarm,
        sleepDuration:
            (bedtime ?? _bedtime).isNotEmpty && (alarm ?? _alarm).isNotEmpty
            ? '8 hours'
            : '',
      ),
      date,
    );
  }

  Future<void> _pickBedtime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null || !mounted) return;
    final String formatted = picked.format(context);
    setState(() => _bedtime = formatted);
    await _saveTime(bedtime: formatted);
  }

  Future<void> _pickAlarm() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null || !mounted) return;
    final String formatted = picked.format(context);
    setState(() => _alarm = formatted);
    await _saveTime(alarm: formatted);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Loader();
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: BlocBuilder<TransparencyBloc, TransparencyState>(
          builder: (BuildContext context, TransparencyState state) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 28, bottom: 10),
                    child: Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'Sleep Tracker',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        transparencyUiConfig.sleepPageTooltipEnabled
                            ? PrivacyTooltip(
                                color: getPrivacyRiskColor(
                                  state.journal.privacyRisk ?? PrivacyRisk.low,
                                ),
                                iconSize: 50,
                                iconName: getPrivacyRiskIcon(
                                  state.journal.privacyRisk ?? PrivacyRisk.low,
                                ),
                                violationsDetected: getPrivacyRiskLabel(
                                  state.journal.privacyRisk ?? PrivacyRisk.low,
                                ),
                                privacyViolations: formatPrivacyViolations(
                                  state.journal,
                                ),
                                purpose: state.journal.aiExplanation?.why ?? '',
                                storage:
                                    state.journal.aiExplanation?.storage ?? '',
                                access:
                                    state.journal.aiExplanation?.access ?? '',
                                privacyPolicySectionLink: state
                                    .journal
                                    .aiExplanation
                                    ?.privacyPolicyLink
                                    .firstOrNull,
                                regulationLink: state
                                    .journal
                                    .aiExplanation
                                    ?.regulationLink
                                    .firstOrNull,
                                dataType: 'Journal',
                              )
                            : PrivacyIcon(
                                handleIconPress: () => setState(
                                  () => _displayNormalUi = !_displayNormalUi,
                                ),
                                isOpen: !_displayNormalUi,
                                iconName: getPrivacyRiskIcon(
                                  state.journal.privacyRisk ?? PrivacyRisk.low,
                                ),
                                iconSize: 50,
                              ),
                      ],
                    ),
                  ),
                  Expanded(
                    child:
                        _displayNormalUi ||
                            transparencyUiConfig.sleepPageTooltipEnabled
                        ? NormalSleepPage(
                            bedtime: _bedtime.isEmpty ? 'Set Time' : _bedtime,
                            alarm: _alarm.isEmpty ? 'Set Time' : _alarm,
                            onEditBedtime: _pickBedtime,
                            onEditAlarm: _pickAlarm,
                            onStartSleepSession: () {
                              if (_bedtime.isEmpty || _alarm.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Please set your Bedtime and Alarm before starting sleep mode.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              context.go('/sleep/sleep-mode');
                            },
                          )
                        : const PrivacySleepPage(),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class NormalSleepPage extends StatelessWidget {
  const NormalSleepPage({
    super.key,
    required this.bedtime,
    required this.alarm,
    required this.onEditBedtime,
    required this.onEditAlarm,
    required this.onStartSleepSession,
  });

  final String bedtime;
  final String alarm;
  final VoidCallback onEditBedtime;
  final VoidCallback onEditAlarm;
  final VoidCallback onStartSleepSession;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: NormalSleepPage.tsx is a direct visual screen, so the Flutter
    //            port keeps the image-first layout instead of replacing it with
    //            generic settings rows.
    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 30),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: AspectRatio(
                aspectRatio: 1,
                child: Image.asset(
                  'assets/images/sleep-duration-wheel.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          TimeTile(label: 'Bedtime', value: bedtime, onTap: onEditBedtime),
          TimeTile(label: 'Alarm', value: alarm, onTap: onEditAlarm),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 20, bottom: 30),
            child: ElevatedButton(
              onPressed: onStartSleepSession,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.generalBlue,
                foregroundColor: Colors.white,
                elevation: 10,
                shadowColor: AppColors.generalBlue.withAlpha(128),
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'SLEEP NOW',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TimeTile extends StatelessWidget {
  const TimeTile({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 15),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        decoration: BoxDecoration(
          color: AppColors.lightBlack,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              value,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.edit_outlined, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }
}

class SleepModePage extends StatefulWidget {
  const SleepModePage({super.key});

  @override
  State<SleepModePage> createState() => _SleepModePageState();
}

class _SleepModePageState extends State<SleepModePage> {
  String _currentTime = '';
  String _alarmTime = '';
  int _pressDuration = 0;
  Timer? _clockTimer;
  Timer? _pressTimer;
  bool _displayNormalUi = true;
  static const int requiredPressDuration = 2000;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final TimeOfDay now = TimeOfDay.now();
      setState(() => _currentTime = now.format(context));
    });
    _enterSleepMode();
  }

  Future<void> _enterSleepMode() async {
    final AppServices services = context.read<AppServices>();
    final UserConsentPreferences consent = context
        .read<ProfileCubit>()
        .state
        .userConsentPreferences;
    final JournalData? journal = await services.journalDataRepository
        .getJournalByDate(isoDate(DateTime.now()));
    if (journal != null && mounted) {
      setState(() => _alarmTime = journal.alarmTime);
    }
    await services.sensorBackgroundTaskManager.updateConfig(
      SensorServiceConfigPatch(
        audioEnabled: consent.microphoneEnabled,
        lightEnabled: consent.lightSensorEnabled,
      ),
    );
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _pressTimer?.cancel();
    super.dispose();
  }

  void _handlePressIn() {
    setState(() => _pressDuration = 0);
    _pressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() => _pressDuration += 100);
      if (_pressDuration >= requiredPressDuration) {
        _pressTimer?.cancel();
        _handleWakeUp();
      }
    });
  }

  void _handlePressOut() {
    _pressTimer?.cancel();
    if (_pressDuration < requiredPressDuration) {
      setState(() => _pressDuration = 0);
    }
  }

  Future<void> _handleWakeUp() async {
    await context.read<AppServices>().sensorBackgroundTaskManager.updateConfig(
      const SensorServiceConfigPatch(audioEnabled: false, lightEnabled: false),
    );
    if (mounted) {
      context.go('/statistics');
    }
  }

  @override
  Widget build(BuildContext context) {
    final double progress = _pressDuration / requiredPressDuration;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.asset('assets/images/sleep-mode-bg.png', fit: BoxFit.cover),
          SafeArea(
            child: BlocBuilder<TransparencyBloc, TransparencyState>(
              builder: (BuildContext context, TransparencyState state) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Stack(
                    children: <Widget>[
                      if (!transparencyUiConfig.sleepModeTooltipEnabled)
                        Positioned(
                          top: 30,
                          right: 10,
                          child: PrivacyIcon(
                            handleIconPress: () => setState(
                              () => _displayNormalUi = !_displayNormalUi,
                            ),
                            isOpen: !_displayNormalUi,
                            iconName: getPrivacyRiskIconForPage(<PrivacyRisk>[
                              state.accelerometer.privacyRisk ??
                                  PrivacyRisk.low,
                              state.light.privacyRisk ?? PrivacyRisk.low,
                              state.microphone.privacyRisk ?? PrivacyRisk.low,
                            ]),
                            iconSize: 50,
                          ),
                        ),
                      if (transparencyUiConfig.sleepModeTooltipEnabled)
                        Positioned(
                          top: 30,
                          left: 0,
                          right: 0,
                          child: Column(
                            children: <Widget>[
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  SensorTooltip(
                                    event: state.accelerometer,
                                    sensorType: 'accelerometer',
                                  ),
                                  SensorTooltip(
                                    event: state.light,
                                    sensorType: 'light',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 15),
                              SensorTooltip(
                                event: state.microphone,
                                sensorType: 'microphone',
                              ),
                              if (Platform.isIOS)
                                const Padding(
                                  padding: EdgeInsets.only(top: 10),
                                  child: SensorNotAvailableWidget(
                                    sensorName: 'Light sensor',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (_displayNormalUi)
                        Column(
                          children: <Widget>[
                            const Spacer(),
                            Text(
                              _currentTime,
                              style: const TextStyle(
                                fontSize: 60,
                                fontWeight: FontWeight.bold,
                                shadows: <Shadow>[
                                  Shadow(
                                    color: Colors.black54,
                                    offset: Offset(1, 1),
                                    blurRadius: 3,
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 20),
                              padding: const EdgeInsets.symmetric(
                                vertical: 15,
                                horizontal: 20,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  const Text('Alarm'),
                                  Text(
                                    _alarmTime,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onLongPressStart: (_) => _handlePressIn(),
                              onLongPressEnd: (_) => _handlePressOut(),
                              child: Stack(
                                children: <Widget>[
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 20,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.generalBlue,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      _pressDuration >= requiredPressDuration
                                          ? 'Releasing...'
                                          : 'Wake up',
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: progress.clamp(0, 1),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white30,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 28),
                          ],
                        )
                      else
                        const PrivacySleepModePage(),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class SensorTooltip extends StatelessWidget {
  const SensorTooltip({
    super.key,
    required this.event,
    required this.sensorType,
  });

  final TransparencyEvent event;
  final String sensorType;

  @override
  Widget build(BuildContext context) {
    final PrivacyRisk risk = event.privacyRisk ?? PrivacyRisk.low;
    return PrivacyTooltip(
      color: getPrivacyRiskColor(risk),
      iconName: getPrivacyRiskIcon(risk),
      violationsDetected: getPrivacyRiskLabel(risk),
      privacyViolations: formatPrivacyViolations(event),
      purpose: event.aiExplanation?.why ?? '',
      storage: event.aiExplanation?.storage ?? '',
      access: event.aiExplanation?.access ?? '',
      optOutLink: '/profile/consent-preferences',
      privacyPolicySectionLink:
          event.aiExplanation?.privacyPolicyLink.firstOrNull,
      regulationLink: event.aiExplanation?.regulationLink.firstOrNull,
      dataType:
          'sensor-$sensorType-${event.storageLocation == DataDestination.googleCloud ? 'cloud' : 'local'}',
    );
  }
}

class JournalPage extends StatefulWidget {
  const JournalPage({super.key});

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  DateTime _selectedDate = DateTime.now();
  bool _showCalendar = false;
  bool _loading = true;
  bool _displayNormalUi = true;
  String _diaryEntry = '';
  String _alarm = '';
  String _bedtime = '';
  String _sleepGoal = '';
  List<SleepNote> _sleepNotes = <SleepNote>[];

  @override
  void initState() {
    super.initState();
    _loadJournalData();
  }

  Future<void> _loadJournalData() async {
    setState(() => _loading = true);
    try {
      final JournalData? journal = await context
          .read<AppServices>()
          .journalDataRepository
          .getJournalByDate(isoDate(_selectedDate));
      if (!mounted) return;
      setState(() {
        _diaryEntry = journal?.diaryEntry ?? '';
        _sleepNotes = journal?.sleepNotes ?? <SleepNote>[];
        _alarm = journal?.alarmTime ?? '';
        _bedtime = journal?.bedtime ?? '';
        _sleepGoal = journal?.sleepDuration ?? '';
      });
    } catch (error) {
      // MIGRATION: The React Native screen always leaves loading in finally and
      //            alerts on repository failures. This keeps Flutter from
      //            sticking on a blank/loading journal page if cloud/local data
      //            throws during hydration.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load journal data: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveJournal({
    String? diaryEntry,
    List<SleepNote>? sleepNotes,
  }) async {
    final String date = isoDate(_selectedDate);
    final TransparencyBloc transparencyBloc = context.read<TransparencyBloc>();
    final TransparencyEvent event = defaultJournalTransparencyEvent();
    transparencyBloc.setChannel(TransparencyChannel.journal, event);
    try {
      final JournalData? result = await context
          .read<AppServices>()
          .journalDataRepository
          .editJournal(
            JournalPatch(
              date: date,
              diaryEntry: diaryEntry,
              sleepNotes: sleepNotes,
            ),
            date,
          );
      if (result != null && mounted) {
        setState(() {
          _diaryEntry = result.diaryEntry;
          _sleepNotes = result.sleepNotes;
          _alarm = result.alarmTime;
          _bedtime = result.bedtime;
          _sleepGoal = result.sleepDuration;
        });
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to save journal')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save journal: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Loader();
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocBuilder<TransparencyBloc, TransparencyState>(
        builder: (BuildContext context, TransparencyState state) {
          return Column(
            children: <Widget>[
              HeaderImage(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        InkWell(
                          onTap: () =>
                              setState(() => _showCalendar = !_showCalendar),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Today',
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                formatMonthDay(_selectedDate),
                                style: const TextStyle(fontSize: 18),
                              ),
                            ],
                          ),
                        ),
                        if (!transparencyUiConfig.journalTooltipEnabled)
                          PrivacyIcon(
                            handleIconPress: () => setState(
                              () => _displayNormalUi = !_displayNormalUi,
                            ),
                            isOpen: !_displayNormalUi,
                            iconName: getPrivacyRiskIconForPage(<PrivacyRisk>[
                              state.journal.privacyRisk ?? PrivacyRisk.low,
                              state.accelerometer.privacyRisk ??
                                  PrivacyRisk.low,
                            ]),
                            iconSize: 50,
                          ),
                      ],
                    ),
                    if (_showCalendar)
                      CalendarStrip(
                        selectedDate: _selectedDate,
                        onSelected: (DateTime date) {
                          setState(() => _selectedDate = date);
                          _loadJournalData();
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: <Widget>[
                    if (_displayNormalUi)
                      NormalJournalPage(
                        showTooltipUi:
                            transparencyUiConfig.journalTooltipEnabled,
                        bedtime: _bedtime,
                        alarm: _alarm,
                        sleepGoal: _sleepGoal,
                        diaryEntry: _diaryEntry,
                        sleepNotes: _sleepNotes,
                        onEditJournalEntry: () async {
                          final String? value = await showTextEditDialog(
                            context,
                            title: 'Journal Entry',
                            initial: _diaryEntry,
                          );
                          if (value != null) {
                            await _saveJournal(diaryEntry: value);
                          }
                        },
                        onEditSleepNotes: () async {
                          final List<SleepNote>? notes =
                              await showSleepNotesDialog(context, _sleepNotes);
                          if (notes != null) {
                            await _saveJournal(sleepNotes: notes);
                          }
                        },
                      )
                    else
                      const PrivacyJournalPage(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class HeaderImage extends StatelessWidget {
  const HeaderImage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: <Widget>[
          Image.network(
            'https://images.unsplash.com/photo-1505142468610-359e7d316be0?ixlib=rb-4.0.3&auto=format&fit=crop&w=1000&q=80',
            height: 170,
            width: double.infinity,
            fit: BoxFit.cover,
            color: const Color(0xCC001428),
            colorBlendMode: BlendMode.srcATop,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 50, 30, 20),
            child: child,
          ),
        ],
      ),
    );
  }
}

class CalendarStrip extends StatelessWidget {
  const CalendarStrip({
    super.key,
    required this.selectedDate,
    required this.onSelected,
  });

  final DateTime selectedDate;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final DateTime start = selectedDate.subtract(const Duration(days: 3));
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemBuilder: (BuildContext context, int index) {
          final DateTime date = start.add(Duration(days: index));
          final bool selected = isoDate(date) == isoDate(selectedDate);
          return ChoiceChip(
            selected: selected,
            label: Text('${date.day}'),
            selectedColor: AppColors.generalBlue,
            onSelected: (_) => onSelected(date),
          );
        },
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 8),
        itemCount: 7,
      ),
    );
  }
}

class NormalJournalPage extends StatelessWidget {
  const NormalJournalPage({
    super.key,
    required this.showTooltipUi,
    required this.bedtime,
    required this.alarm,
    required this.sleepGoal,
    required this.diaryEntry,
    required this.sleepNotes,
    required this.onEditJournalEntry,
    required this.onEditSleepNotes,
  });

  final bool showTooltipUi;
  final String bedtime;
  final String alarm;
  final String sleepGoal;
  final String diaryEntry;
  final List<SleepNote> sleepNotes;
  final VoidCallback onEditJournalEntry;
  final VoidCallback onEditSleepNotes;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: NormalJournalPage.tsx combines several independent privacy
    //            surfaces. BlocBuilder watches TransparencyBloc here so the
    //            two tooltip channels stay reactive without turning this simple
    //            visual component into its own state machine.
    return BlocBuilder<TransparencyBloc, TransparencyState>(
      builder: (BuildContext context, TransparencyState state) {
        final TransparencyEvent journalEvent = state.journal;
        final TransparencyEvent accelerometerEvent = state.accelerometer;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'Sleep Goal',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppColors.lightBlack,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        JournalMetric(
                          icon: Icons.nightlight_round,
                          label: 'Bedtime',
                          value: bedtime,
                          valueSize: 18,
                          valueWeight: FontWeight.w600,
                        ),
                        const SizedBox(height: 15),
                        JournalMetric(
                          icon: Icons.alarm_outlined,
                          label: 'Alarm',
                          value: alarm,
                          valueSize: 16,
                          valueWeight: FontWeight.w500,
                        ),
                      ],
                    ),
                  ),
                  JournalMetric(
                    icon: Icons.explore_outlined,
                    label: 'Goal',
                    value: sleepGoal,
                    alignEnd: true,
                    valueSize: 18,
                    valueWeight: FontWeight.w600,
                  ),
                ],
              ),
            ),
            JournalSectionTitleRow(
              title: 'Diary',
              tooltip: showTooltipUi
                  ? PrivacyTooltip(
                      color: getPrivacyRiskColor(
                        journalEvent.privacyRisk ?? PrivacyRisk.low,
                      ),
                      iconSize: 40,
                      iconName: getPrivacyRiskIcon(
                        journalEvent.privacyRisk ?? PrivacyRisk.low,
                      ),
                      violationsDetected: getPrivacyRiskLabel(
                        journalEvent.privacyRisk ?? PrivacyRisk.low,
                      ),
                      privacyViolations: formatPrivacyViolations(journalEvent),
                      purpose: journalEvent.aiExplanation?.why ?? '',
                      storage: journalEvent.aiExplanation?.storage ?? '',
                      access: journalEvent.aiExplanation?.access ?? '',
                      privacyPolicySectionLink: journalEvent
                          .aiExplanation
                          ?.privacyPolicyLink
                          .firstOrNull,
                      regulationLink: journalEvent
                          .aiExplanation
                          ?.regulationLink
                          .firstOrNull,
                      dataType: 'Journal',
                    )
                  : null,
            ),
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 15),
              decoration: BoxDecoration(
                color: AppColors.lightBlack,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text(
                        'Sleep Notes',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      IconButton(
                        onPressed: onEditSleepNotes,
                        icon: const Icon(
                          Icons.add_circle_outline,
                          color: AppColors.generalBlue,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  if (sleepNotes.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                        'No sleep notes added yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF8E8E93),
                          fontSize: 16,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    )
                  else
                    ...sleepNotes.map<Widget>((SleepNote note) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              '•',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                note.label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.lightBlack,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 6,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 15,
                      ),
                      child: Text(
                        diaryEntry.isEmpty
                            ? 'Write something to record your day... '
                            : diaryEntry,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: IconButton(
                      onPressed: onEditJournalEntry,
                      icon: const Icon(
                        Icons.edit_outlined,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            JournalSectionTitleRow(
              title: 'Activity Tracker',
              tooltip: showTooltipUi
                  ? PrivacyTooltip(
                      color: getPrivacyRiskColor(
                        accelerometerEvent.privacyRisk ?? PrivacyRisk.low,
                      ),
                      iconSize: 40,
                      iconName: getPrivacyRiskIcon(
                        accelerometerEvent.privacyRisk ?? PrivacyRisk.low,
                      ),
                      violationsDetected: getPrivacyRiskLabel(
                        accelerometerEvent.privacyRisk ?? PrivacyRisk.low,
                      ),
                      privacyViolations: formatPrivacyViolations(
                        accelerometerEvent,
                      ),
                      purpose: accelerometerEvent.aiExplanation?.why ?? '',
                      storage: accelerometerEvent.aiExplanation?.storage ?? '',
                      access: accelerometerEvent.aiExplanation?.access ?? '',
                      optOutLink: '/profile/consent-preferences',
                      privacyPolicySectionLink: accelerometerEvent
                          .aiExplanation
                          ?.privacyPolicyLink
                          .firstOrNull,
                      regulationLink: accelerometerEvent
                          .aiExplanation
                          ?.regulationLink
                          .firstOrNull,
                      dataType: 'Activity Tracker',
                    )
                  : null,
            ),
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppColors.lightBlack,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                children: <Widget>[
                  Expanded(
                    child: ActivityProgressItem(label: 'Steps', unit: 'steps'),
                  ),
                  SizedBox(width: 15),
                  Expanded(
                    child: ActivityProgressItem(
                      label: 'Calories',
                      unit: 'kcal',
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class JournalMetric extends StatelessWidget {
  const JournalMetric({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.alignEnd = false,
    required this.valueSize,
    required this.valueWeight,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool alignEnd;
  final double valueSize;
  final FontWeight valueWeight;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: Ionicons from Expo are translated to Material icons with the
    //            closest silhouette available in Flutter's bundled icon set.
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          value.isEmpty ? '' : value,
          textAlign: alignEnd ? TextAlign.end : TextAlign.start,
          style: TextStyle(
            color: Colors.white,
            fontSize: valueSize,
            fontWeight: valueWeight,
          ),
        ),
      ],
    );
  }
}

class JournalSectionTitleRow extends StatelessWidget {
  const JournalSectionTitleRow({super.key, required this.title, this.tooltip});

  final String title;
  final Widget? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget trailing = tooltip ?? const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 15),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class ActivityProgressItem extends StatelessWidget {
  const ActivityProgressItem({
    super.key,
    required this.label,
    required this.unit,
  });

  final String label;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(26),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.generalBlue, width: 3),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text(
                '83',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                unit,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.lightBlack,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: AppColors.lightBlack,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(value),
          ],
        ),
      ),
    );
  }
}

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key});

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  bool _displayNormalUi = true;
  bool _daily = true;
  DateTime _selectedDate = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocBuilder<TransparencyBloc, TransparencyState>(
        builder: (BuildContext context, TransparencyState state) {
          return Column(
            children: <Widget>[
              HeaderImage(
                child: Column(
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            TabPill(
                              label: 'Daily',
                              selected: _daily,
                              onTap: () => setState(() {
                                _daily = true;
                                _displayNormalUi = true;
                              }),
                            ),
                            const SizedBox(width: 10),
                            TabPill(
                              label: 'Statistics',
                              selected: !_daily,
                              onTap: () => setState(() {
                                _daily = false;
                                _displayNormalUi = true;
                              }),
                            ),
                          ],
                        ),
                        PrivacyIcon(
                          handleIconPress: () => setState(
                            () => _displayNormalUi = !_displayNormalUi,
                          ),
                          isOpen: !_displayNormalUi,
                          iconName: getPrivacyRiskIcon(
                            state.statistics.privacyRisk ?? PrivacyRisk.low,
                          ),
                          iconSize: 50,
                        ),
                      ],
                    ),
                    if (_daily)
                      CalendarStrip(
                        selectedDate: _selectedDate,
                        onSelected: (DateTime date) =>
                            setState(() => _selectedDate = date),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: <Widget>[
                    if (_displayNormalUi)
                      if (_daily)
                        const DailyStatisticsPage()
                      else ...<Widget>[
                        StatisticItem(
                          label: 'Sleep Quality',
                          imageAsset: 'assets/images/sleep-quality-graph.png',
                        ),
                        StatisticItem(
                          label: 'Sleep Duration',
                          imageAsset: 'assets/images/sleep-duration-graph.png',
                        ),
                        StatisticItem(
                          label: 'Sleep Stages',
                          imageAsset: 'assets/images/sleep-duration-graph.png',
                        ),
                        StatisticItem(
                          label: 'Snore Time',
                          imageAsset: 'assets/images/sleep-quality-graph.png',
                        ),
                      ]
                    else
                      const PrivacyStatisticsPage(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class TabPill extends StatelessWidget {
  const TabPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.generalBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.lightGrey,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class DailyStatisticsPage extends StatelessWidget {
  const DailyStatisticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // MIGRATION: The React Native DailyStatisticsPage is static prototype UI.
    //            Flutter keeps the same placeholder values/images so the
    //            migrated screen remains visually and functionally equivalent.
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'Sleep Quality',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(height: 15),
        SleepQualityCard(),
        StatisticItem(
          label: 'Sleep Stages',
          imageAsset: 'assets/images/sleep-stages-daily.png',
        ),
        SleepStagesGrid(),
        SleepInsightsGrid(),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'Sleep Clips',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(height: 15),
        SleepClipsCard(),
      ],
    );
  }
}

class SleepQualityCard extends StatelessWidget {
  const SleepQualityCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: AppColors.lightBlack,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: Image.asset(
              'assets/images/sleep-quality-daily.png',
              width: 100,
              height: 100,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 20),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Time in Bed',
                  style: TextStyle(color: Color(0xFF888888), fontSize: 14),
                ),
                SizedBox(height: 2),
                Text(
                  '10:14 PM - 6:44 AM',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '8h 30m',
                  style: TextStyle(color: AppColors.lightGrey, fontSize: 14),
                ),
                SizedBox(height: 8),
                Text(
                  'Pretty Good!',
                  style: TextStyle(
                    color: AppColors.generalBlue,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SleepStagesGrid extends StatelessWidget {
  const SleepStagesGrid({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 15,
        alignment: WrapAlignment.spaceBetween,
        children: <Widget>[
          StageItem(
            label: 'Deep Sleep',
            percentage: '21%',
            duration: '2h 25m',
            icon: Icons.nightlight_round,
            color: Color(0xFF4A4A4A),
          ),
          StageItem(
            label: 'Light Sleep',
            percentage: '56%',
            duration: '4h 35m',
            icon: Icons.nightlight_outlined,
            color: Color(0xFF6A9EFF),
          ),
          StageItem(
            label: 'REM',
            percentage: '17%',
            duration: '1h 25m',
            icon: Icons.visibility,
            color: Color(0xFF8A6AFF),
          ),
          StageItem(
            label: 'Awake',
            percentage: '6%',
            duration: '30m',
            icon: Icons.visibility_outlined,
            color: Color(0xFFFFA64A),
          ),
        ],
      ),
    );
  }
}

class StageItem extends StatelessWidget {
  const StageItem({
    super.key,
    required this.label,
    required this.percentage,
    required this.duration,
    required this.icon,
    required this.color,
  });

  final String label;
  final String percentage;
  final String duration;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.19,
      child: Column(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.lightGrey, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            percentage,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            duration,
            style: const TextStyle(color: AppColors.lightGrey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class SleepInsightsGrid extends StatelessWidget {
  const SleepInsightsGrid({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: InsightItem(
                icon: Icons.bed_outlined,
                color: Color(0xFF4A9EFF),
                label: 'In Bed',
                value: '8h 30 min',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: InsightItem(
                icon: Icons.nightlight_outlined,
                color: Color(0xFF8A6AFF),
                label: 'Asleep',
                value: '7h 34 min',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: InsightItem(
                icon: Icons.access_time,
                color: Color(0xFF6A9EFF),
                label: 'Asleep After',
                value: '11 min',
              ),
            ),
          ],
        ),
        SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: InsightItem(
                icon: Icons.volume_up_outlined,
                color: Color(0xFFFFA64A),
                label: 'Noise',
                value: '39 dB',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: InsightItem(
                icon: Icons.volume_up_outlined,
                color: Color(0xFFFF6B6B),
                label: 'Snoring',
                value: '1h 30 min',
              ),
            ),
            Expanded(child: SizedBox.shrink()),
          ],
        ),
        SizedBox(height: 20),
      ],
    );
  }
}

class InsightItem extends StatelessWidget {
  const InsightItem({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 80),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.lightBlack,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.lightGrey, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class SleepClipsCard extends StatefulWidget {
  const SleepClipsCard({super.key});

  @override
  State<SleepClipsCard> createState() => _SleepClipsCardState();
}

class _SleepClipsCardState extends State<SleepClipsCard> {
  bool _snoring = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: AppColors.lightBlack,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipTab(
                label: 'Snoring',
                selected: _snoring,
                onTap: () => setState(() => _snoring = true),
              ),
              const SizedBox(width: 10),
              ClipTab(
                label: 'Talking',
                selected: !_snoring,
                onTap: () => setState(() => _snoring = false),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const ClipListItem(),
          SizedBox(height: 12),
          const ClipListItem(),
          SizedBox(height: 12),
          const ClipListItem(),
        ],
      ),
    );
  }
}

class ClipTab extends StatelessWidget {
  const ClipTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.generalBlue : const Color(0xFF333333),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.lightGrey,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class ClipListItem extends StatelessWidget {
  const ClipListItem({super.key});

  static const List<double> _barHeights = <double>[
    8,
    18,
    11,
    24,
    15,
    9,
    22,
    14,
    19,
    7,
    25,
    13,
    17,
    10,
    21,
    16,
    12,
    23,
    9,
    18,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF333333),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.play_circle_outline,
            color: Color(0xFF4A9EFF),
            size: 24,
          ),
          const SizedBox(width: 12),
          const SizedBox(
            width: 60,
            child: Text(
              '11:04 PM',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 26,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: _barHeights
                    .map<Widget>((double height) {
                      return Container(
                        width: 2,
                        height: height,
                        margin: const EdgeInsets.only(right: 2),
                        decoration: BoxDecoration(
                          color: AppColors.generalBlue,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.more_horiz, color: Color(0xFF888888), size: 20),
        ],
      ),
    );
  }
}

class StatisticItem extends StatelessWidget {
  const StatisticItem({
    super.key,
    required this.label,
    required this.imageAsset,
  });

  final String label;
  final String imageAsset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 15),
        Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.lightBlack,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Image.asset(
            imageAsset,
            width: double.infinity,
            height: 200,
            fit: BoxFit.contain,
          ),
        ),
      ],
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final User? user = context.watch<AuthCubit>().state.user;
    final String firstName = user?.firstName.isEmpty ?? true
        ? 'Guest'
        : user!.firstName;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              const Text(
                'Profile',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Column(
                children: <Widget>[
                  Text(
                    'Hello, $firstName',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Column(
                children: <Widget>[
                  ProfileMenuItem(
                    title: 'Consent Preferences',
                    onPressed: () => context.go('/profile/consent-preferences'),
                  ),
                  ProfileMenuItem(
                    title: 'Privacy Policy',
                    onPressed: () => context.go('/privacy-policy'),
                  ),
                ],
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => context.read<AuthCubit>().logout(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.generalBlue,
                    foregroundColor: Colors.white,
                    elevation: 10,
                    shadowColor: Colors.black.withAlpha(102),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 30,
                      vertical: 18,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'LOGOUT',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfileMenuItem extends StatelessWidget {
  const ProfileMenuItem({
    super.key,
    required this.title,
    required this.onPressed,
    this.chevronDirection = Icons.chevron_right,
  });

  final String title;
  final VoidCallback onPressed;
  final IconData chevronDirection;

  @override
  Widget build(BuildContext context) {
    // MIGRATION: Expo Ionicons chevron-forward maps to Material
    //            chevron_right while preserving the row dimensions and color.
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 15),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
        decoration: BoxDecoration(
          color: AppColors.lightBlack,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(chevronDirection, color: AppColors.generalBlue, size: 18),
          ],
        ),
      ),
    );
  }
}

class ConsentPreferencesPage extends StatelessWidget {
  const ConsentPreferencesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocBuilder<ProfileCubit, ProfileState>(
        builder: (BuildContext context, ProfileState state) {
          final UserConsentPreferences preferences =
              state.userConsentPreferences;
          return ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              OnboardingHeaderLike(
                title: 'Your Privacy Matters to Us',
                onBackPressed: () =>
                    context.canPop() ? context.pop() : context.go('/profile'),
              ),
              PermissionsToggleLike(
                value: preferences.microphoneEnabled,
                label:
                    'Yes, you have permission to access my microphone to record my sleep sounds.',
                onChanged: (bool value) async {
                  final ProfileCubit profileCubit = context
                      .read<ProfileCubit>();
                  final ScaffoldMessengerState scaffoldMessenger =
                      ScaffoldMessenger.of(context);
                  if (value) {
                    // MIGRATION: Expo Audio.requestPermissionsAsync maps to
                    //            record.AudioRecorder.hasPermission in Flutter.
                    final AudioRecorder recorder = AudioRecorder();
                    final bool granted = await recorder.hasPermission();
                    await recorder.dispose();
                    if (!granted && context.mounted) {
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Microphone access denied. Enable it in device settings to use this feature.',
                          ),
                        ),
                      );
                      await profileCubit.setUserConsentPreferences(
                        preferences.copyWith(microphoneEnabled: false),
                      );
                      return;
                    }
                  }
                  await profileCubit.setUserConsentPreferences(
                    preferences.copyWith(microphoneEnabled: value),
                  );
                },
              ),
              ConsentLink(
                text: 'Read more about sound data and snoring detection',
                sectionId: 'microphone',
              ),
              PermissionsToggleLike(
                value: preferences.accelerometerEnabled,
                label:
                    'Yes, you have my permission to access my accelerometer to track my activity levels.',
                onChanged: (bool value) async {
                  // MIGRATION: Expo TaskManager config updates become
                  //            SensorBackgroundTaskManager updates so Android
                  //            foreground accelerometer collection follows the
                  //            same consent toggle.
                  final UserConsentPreferences updated = preferences.copyWith(
                    accelerometerEnabled: value,
                  );
                  await context.read<ProfileCubit>().setUserConsentPreferences(
                    updated,
                  );
                  if (context.mounted) {
                    await context
                        .read<AppServices>()
                        .sensorBackgroundTaskManager
                        .updateConfig(
                          SensorServiceConfigPatch(accelerometerEnabled: value),
                        );
                  }
                },
              ),
              ConsentLink(
                text: 'More about collecting activity data',
                sectionId: 'accelerometer',
              ),
              PermissionsToggleLike(
                value: preferences.lightSensorEnabled,
                label:
                    'Yes, you have my permission to access my light sensor to track ambient light levels.',
                onChanged: (bool value) =>
                    context.read<ProfileCubit>().setUserConsentPreferences(
                      preferences.copyWith(lightSensorEnabled: value),
                    ),
              ),
              ConsentLink(
                text: 'More about collecting ambient light data',
                sectionId: 'lightSensor',
              ),
              PermissionsToggleLike(
                value: preferences.cloudStorageEnabled,
                label:
                    'Yes, you have my permission to store my personal health information on secure Google Cloud servers',
                onChanged: (bool value) =>
                    context.read<ProfileCubit>().setUserConsentPreferences(
                      preferences.copyWith(cloudStorageEnabled: value),
                    ),
              ),
              ConsentLink(
                text: 'More about data storage and data access',
                sectionId: 'cloudVsLocalStorage',
              ),
            ],
          );
        },
      ),
    );
  }
}

class OnboardingHeaderLike extends StatelessWidget {
  const OnboardingHeaderLike({
    super.key,
    required this.title,
    required this.onBackPressed,
  });

  final String title;
  final VoidCallback onBackPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.only(top: 60, bottom: 20),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onBackPressed,
            icon: const Icon(
              Icons.chevron_left,
              color: AppColors.generalBlue,
              size: 24,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PermissionsToggleLike extends StatelessWidget {
  const PermissionsToggleLike({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.horizontalPadding = 20,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 10,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: const Color(0xFF4CAF50),
            activeThumbColor: Colors.white,
            inactiveTrackColor: const Color(0xFFCCCCCC),
            inactiveThumbColor: Colors.white,
          ),
        ],
      ),
    );
  }
}

class ConsentLink extends StatelessWidget {
  const ConsentLink({super.key, required this.text, required this.sectionId});

  final String text;
  final String sectionId;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        onPressed: () => context.go('/privacy-policy?sectionId=$sectionId'),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.hyperlinkBlue,
            fontSize: 14,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.hyperlinkBlue,
          ),
        ),
      ),
    );
  }
}

class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({super.key, this.sectionId});

  final String? sectionId;

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage> {
  final Map<String, GlobalKey> _sectionKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToInitial());
  }

  @override
  void didUpdateWidget(covariant PrivacyPolicyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sectionId != widget.sectionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToInitial());
    }
  }

  void _scrollToInitial() {
    final String? sectionId = widget.sectionId;
    if (sectionId == null || sectionId.isEmpty) {
      return;
    }
    _scrollToSection(sectionId);
  }

  void _scrollToSection(String sectionId) {
    final BuildContext? target = _sectionKeys[sectionId]?.currentContext;
    if (target == null) {
      return;
    }
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.05,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: Colors.black,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          const Text(
            'Version: 1.0.0 | Effective Date: 2025-06-10 | Last Updated: 2025-07-07',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
          ),
          const SizedBox(height: 20),
          const Text(
            'Table of Contents',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          for (final PrivacyPolicyTocEntry entry in privacyPolicyToc)
            InkWell(
              onTap: () => _scrollToSection(entry.sectionId),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 5),
                child: Text(
                  '• ${entry.title}',
                  style: const TextStyle(
                    color: AppColors.generalBlue,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.lightGrey, height: 24),
          // MIGRATION: React Native rendered this screen from
          //            privacyPolicyData.json. Flutter keeps the same text in
          //            typed constants so section links and policy wording stay
          //            compatible without using dynamic JSON maps.
          for (final PrivacyPolicyContentItem item in privacyPolicyContent)
            _PrivacyPolicyContentWidget(
              key: item.id == null
                  ? null
                  : (_sectionKeys[item.id!] ??= GlobalKey()),
              item: item,
            ),
        ],
      ),
    );
  }
}

enum PrivacyPolicyContentKind {
  heading,
  paragraph,
  description,
  bullet,
  definition,
  subHeading,
  listItem,
}

class PrivacyPolicyTocEntry {
  const PrivacyPolicyTocEntry(this.title, this.sectionId);

  final String title;
  final String sectionId;
}

class PrivacyPolicyContentItem {
  const PrivacyPolicyContentItem._({
    required this.kind,
    required this.text,
    this.label,
    this.level = 0,
    this.id,
  });

  const PrivacyPolicyContentItem.heading(
    String text, {
    required int level,
    String? id,
  }) : this._(
         kind: PrivacyPolicyContentKind.heading,
         text: text,
         level: level,
         id: id,
       );

  const PrivacyPolicyContentItem.paragraph(String text, {String? id})
    : this._(kind: PrivacyPolicyContentKind.paragraph, text: text, id: id);

  const PrivacyPolicyContentItem.description(String text, {String? id})
    : this._(kind: PrivacyPolicyContentKind.description, text: text, id: id);

  const PrivacyPolicyContentItem.bullet(String label, String text, {String? id})
    : this._(
        kind: PrivacyPolicyContentKind.bullet,
        label: label,
        text: text,
        id: id,
      );

  const PrivacyPolicyContentItem.definition(
    String label,
    String text, {
    String? id,
  }) : this._(
         kind: PrivacyPolicyContentKind.definition,
         label: label,
         text: text,
         id: id,
       );

  const PrivacyPolicyContentItem.subHeading(String text, {String? id})
    : this._(kind: PrivacyPolicyContentKind.subHeading, text: text, id: id);

  const PrivacyPolicyContentItem.listItem(String text, {String? id})
    : this._(kind: PrivacyPolicyContentKind.listItem, text: text, id: id);

  final PrivacyPolicyContentKind kind;
  final String text;
  final String? label;
  final int level;
  final String? id;
}

class _PrivacyPolicyContentWidget extends StatelessWidget {
  const _PrivacyPolicyContentWidget({super.key, required this.item});

  final PrivacyPolicyContentItem item;

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case PrivacyPolicyContentKind.heading:
        final double fontSize = item.level == 1
            ? 22
            : item.level == 2
            ? 18
            : 16;
        return Padding(
          padding: EdgeInsets.only(
            top: item.level == 1 ? 18 : 10,
            bottom: item.level == 1 ? 10 : 8,
            left: item.level == 1
                ? 0
                : item.level == 2
                ? 5
                : 10,
          ),
          child: Text(
            item.text,
            style: TextStyle(
              color: AppColors.generalBlue,
              fontSize: fontSize,
              fontWeight: item.level == 1
                  ? FontWeight.bold
                  : item.level == 2
                  ? FontWeight.w600
                  : FontWeight.w500,
            ),
          ),
        );
      case PrivacyPolicyContentKind.description:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            item.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.45,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case PrivacyPolicyContentKind.bullet:
        return Padding(
          padding: const EdgeInsets.only(left: 15, bottom: 5),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(
                color: Color(0xFFADD8E6),
                fontSize: 14,
                height: 1.35,
                fontFamily: 'SpaceMono',
              ),
              children: <TextSpan>[
                TextSpan(text: '• ${item.label} '),
                TextSpan(
                  text: item.text,
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        );
      case PrivacyPolicyContentKind.definition:
        return Padding(
          padding: const EdgeInsets.only(left: 10, bottom: 8),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.35,
                fontFamily: 'SpaceMono',
              ),
              children: <TextSpan>[
                TextSpan(
                  text: '${item.label} ',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: item.text),
              ],
            ),
          ),
        );
      case PrivacyPolicyContentKind.subHeading:
        return Padding(
          padding: const EdgeInsets.only(left: 15, top: 5, bottom: 3),
          child: Text(
            item.text,
            style: const TextStyle(
              color: Color(0xFFADD8E6),
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      case PrivacyPolicyContentKind.listItem:
        return Padding(
          padding: const EdgeInsets.only(left: 25, bottom: 5),
          child: Text(
            '- ${item.text}',
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        );
      case PrivacyPolicyContentKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            item.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.5,
            ),
          ),
        );
    }
  }
}

const List<PrivacyPolicyTocEntry> privacyPolicyToc = <PrivacyPolicyTocEntry>[
  PrivacyPolicyTocEntry(
    'Interpretation and Definitions',
    'interpretationsAndDefinitions',
  ),
  PrivacyPolicyTocEntry(
    'Types of Information Collected and How We Use it',
    'dataCollection',
  ),
  PrivacyPolicyTocEntry(
    'Cloud vs. Local Data Storage & Processing',
    'cloudVsLocalStorage',
  ),
  PrivacyPolicyTocEntry(
    'Data Encryption and Pseudonymization',
    'dataEncryptionAndPsuedonymization',
  ),
  PrivacyPolicyTocEntry('How We share Your information', 'dataSharing'),
  PrivacyPolicyTocEntry('Retention of Your information', 'dataRetention'),
  PrivacyPolicyTocEntry('Your Rights under PIPEDA', 'userRights'),
  PrivacyPolicyTocEntry('Changes to the Privacy Policy', 'policyChanges'),
  PrivacyPolicyTocEntry('Contact Us', 'contact'),
];

const List<PrivacyPolicyContentItem>
privacyPolicyContent = <PrivacyPolicyContentItem>[
  PrivacyPolicyContentItem.paragraph(
    'This Privacy Policy describes Our policies and procedures on the collection, use and disclosure of Your information when You use the App and tells You about Your privacy rights and how the Personal Information Protection and Electronic Documents Act (PIPEDA) protects You. We use Your Personal data to provide and improve the App.',
    id: 'introduction',
  ),
  PrivacyPolicyContentItem.heading(
    'Interpretation and Definitions',
    level: 1,
    id: 'interpretationsAndDefinitions',
  ),
  PrivacyPolicyContentItem.definition(
    'You:',
    'refers to the individual accessing or using the Service (Individual under PIPEDA). For the purposes of PIPEDA, You can be referred to as the Individual.',
  ),
  PrivacyPolicyContentItem.definition(
    'Company:',
    'refers to Sleep Tracker Inc. (Organization under PIPEDA). For the purposes of PIPEDA, Company can be referred to as the Organization',
  ),
  PrivacyPolicyContentItem.definition(
    'App:',
    'refers to the Sleep Tracker application that is provided by the Company and downloaded by You on any mobile device ',
  ),
  PrivacyPolicyContentItem.definition(
    'Personal Information:',
    'information about an identifiable individual',
  ),
  PrivacyPolicyContentItem.definition(
    'Personal Health Information:',
    'information concerning the physical or mental health of the individual or concerning any health service provided to the individual that is collected, or that is collected in the course of providing health services, or collected incidentally to the provision of health services.',
  ),
  PrivacyPolicyContentItem.heading(
    'Types of Information Collected and How We Use Your Information',
    level: 1,
    id: 'dataCollection',
  ),
  PrivacyPolicyContentItem.paragraph(
    'We collect various types of information to provide and improve Our App for You. The collection and use of this information are directly linked to the specific functionalities and benefits provided by the App.',
  ),
  PrivacyPolicyContentItem.heading(
    'Personal Information',
    level: 2,
    id: 'personalInformation',
  ),
  PrivacyPolicyContentItem.description(
    'While using Our App, We may ask You to provide Us with certain personally identifiable information that can be used to contact or identify You.',
  ),
  PrivacyPolicyContentItem.heading('Account Information', level: 3),
  PrivacyPolicyContentItem.bullet('Data Type:', 'Email Address and Name'),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'Your email address and name are collected to create and manage Your user account, enable secure login, provide essential notifications (e.g., account-related updates), and personalize Your in-app experience. This information is fundamental for Your account functionality and access to the App\'s services, regardless of Your cloud storage preference for Personal Health Information.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Collection Method:',
    'Directly from You when You register for an account.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Storage:',
    'Your email address and name are stored on secure Company servers located in Canada. This data is encrypted at rest using industry-standard encryption protocols (e.g., AES-256) to protect it from unauthorized access. All communication involving Your email address and name between Your device and Our servers is encrypted in transit using Transport Layer Security (TLS 1.2 or higher).',
  ),
  PrivacyPolicyContentItem.heading(
    'Personal Health Information',
    level: 2,
    id: 'personalHealthInformation',
  ),
  PrivacyPolicyContentItem.description(
    'Given the nature of a sleep tracking application, We collect information that may be considered Personal Health Information under PIPEDA. ',
  ),
  PrivacyPolicyContentItem.heading('Sensor Data', level: 3, id: 'sensorData'),
  PrivacyPolicyContentItem.subHeading('Microphone:', id: 'microphone'),
  PrivacyPolicyContentItem.bullet('Data Type:', 'Ambient sound levels'),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'To detect and record ambient sound patterns that may indicate sleep disturbances (e.g., snoring, sleep talking). This data is used to help You identify factors impacting Your sleep environment.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Collection Method:',
    'Collected from Your device\'s microphone sensor while You are using the “Sleep” functionality of the App and explicit permission must be granted.',
  ),
  PrivacyPolicyContentItem.subHeading('Accelerometer:', id: 'accelerometer'),
  PrivacyPolicyContentItem.bullet('Data Type:', 'Motion and movement data'),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'To track Your body movements during sleep, which can help infer sleep stages (e.g., light sleep, deep sleep, REM) and identify restless sleep periods. This data is used to provide You with insights into Your sleep cycles. It is also used to track Your activity levels throughout the day, allowing You to correlate activity levels to sleep quality. ',
  ),
  PrivacyPolicyContentItem.bullet(
    'Collection Method:',
    'Collected from Your device\'s accelerometer sensor continuously in the background and explicit permission must be granted.',
  ),
  PrivacyPolicyContentItem.subHeading('Light Sensor:', id: 'lightSensor'),
  PrivacyPolicyContentItem.bullet('Data Type:', 'Ambient light levels'),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'To monitor the light conditions in Your sleep environment, helping You understand how light exposure may affect Your sleep onset and quality.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Collection Method:',
    'Collected from Your device\'s light sensor while You are using the “Sleep” functionality of the App and explicit permission must be granted.',
  ),
  PrivacyPolicyContentItem.heading('Journal Data', level: 3, id: 'journalData'),
  PrivacyPolicyContentItem.bullet(
    'Data Type:',
    'Mood, Habits, Symptoms, Diary Entries',
  ),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'To allow You to record personal observations about Your daily mood, habits (e.g., caffeine intake, exercise), and any symptoms You are experiencing. This data helps You correlate Your personal experiences with Your sleep patterns and identify potential influences on Your sleep quality.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Collection Method:',
    'Directly from You when You voluntarily input entries into the App\'s journal feature.',
  ),
  PrivacyPolicyContentItem.heading('Derived Data', level: 3, id: 'derivedData'),
  PrivacyPolicyContentItem.paragraph(
    'This type of data is not collected directly from You, but The App will derive this information about You from the Personal Health Information it collects from You. This includes sleep quality scores, correlations between habits and sleep quality and personalized insights. We generate this derived data solely to provide You with more personalized and actionable insights into Your well-being, to help You understand potential correlations between different aspects of Your health, and to improve the relevance of the information and recommendations We offer within the App.',
  ),
  PrivacyPolicyContentItem.heading('Usage Data', level: 2, id: 'usageData'),
  PrivacyPolicyContentItem.description(
    'Usage Data is collected automatically when You use the App.',
  ),
  PrivacyPolicyContentItem.heading('Technical Information', level: 3),
  PrivacyPolicyContentItem.bullet(
    'Data Type:',
    'Technical Information (device\'s IP address, device name and model, operating system name and version, unique device identifiers, App version, crash logs, time zone, system language, and country)',
  ),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'To monitor the overall performance and stability of the App, identify and resolve technical issues (e.g., crashes, bugs), understand user engagement with different features, and make improvements to the App\'s functionality.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Collection Method:',
    'Automatically collected from Your device and App interactions.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Storage Location:',
    'Usage data is stored on our secure Company servers located in Canada. ',
  ),
  PrivacyPolicyContentItem.bullet(
    'Troubleshooting:',
    'For troubleshooting specific issues (e.g., why a particular feature is crashing), this data may be pseudonymized. This allows us to track patterns and resolve problems affecting Your experience without directly identifying You.',
  ),
  PrivacyPolicyContentItem.bullet(
    'General Analytics:',
    'For general analytics and long-term trends (e.g., understanding the most used features or overall performance metrics), this data is anonymized by aggregating it and removing any potential identifiers, ensuring it cannot be linked back to any individual. This helps us to make broad improvements to the App while fully preserving Your privacy.',
  ),
  PrivacyPolicyContentItem.heading(
    'Cloud vs. Local Data Storage & Processing',
    level: 1,
    id: 'cloudVsLocalStorage',
  ),
  PrivacyPolicyContentItem.paragraph(
    'We offer You a choice regarding where Your Personal Health Information (sensor data, journal data and derived data) is stored and processed. You will be presented with a clear choice regarding cloud storage of Personal Health Information upon initial use of the App, and You will have the option to change this setting within the App\'s privacy settings.',
  ),
  PrivacyPolicyContentItem.heading(
    'Cloud Storage (Opt-In)',
    level: 2,
    id: 'cloudStorage',
  ),
  PrivacyPolicyContentItem.description(
    'By opting in to cloud storage, Your Personal Health Information will be securely stored and processed on Google Cloud servers.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Benefits:',
    'This option enables more complex sleep analysis, trending of Your sleep data over longer periods, and future functionalities that require significant computing resources or data synchronization across multiple devices.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Data Location:',
    'Please be aware that Google Cloud servers may be located in various data centers globally, including locations outside of Canada. While we choose Google Cloud for its robust security and data management capabilities, data stored outside of the Country may be subject to the laws of the jurisdiction where the servers are located. For more information on Google Cloud\'s data handling practices, please refer to Google Cloud\'s Privacy Policy.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Accountability:',
    'Regardless of where Your data is stored by Google Cloud, Sleep Tracker Inc. remains accountable for the protection of Your Personal Information and Personal Health Information under PIPEDA. We enter into contractual agreements with Google Cloud to ensure they provide a comparable level of protection consistent with PIPEDA principles.',
  ),
  PrivacyPolicyContentItem.heading(
    'Local Storage (Default without Cloud Opt-In)',
    level: 2,
    id: 'localStorage',
  ),
  PrivacyPolicyContentItem.description(
    'If You do not opt-in to cloud storage, or opt-out at any time, Your Personal Health Information will be stored primarily on Your local device.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Limitations:',
    'Please be aware that certain advanced or complex sleep analysis features, which require significant computing resources or data synchronization across devices, will not be available when data is stored locally.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Responsibility:',
    'The Company is not responsible for Personal Health Information stored solely on Your local device. If You delete the App from Your device, factory reset Your device, or if Your device is lost or damaged, all locally stored data will be permanently lost, as We do not retain copies of locally stored data on Our servers unless You have opted in for cloud storage.',
  ),
  PrivacyPolicyContentItem.bullet('Consent:', 'default'),
  PrivacyPolicyContentItem.heading(
    'Data Encryption and Pseudonymization',
    level: 1,
    id: 'dataEncryptionAndPsuedonymization',
  ),
  PrivacyPolicyContentItem.description(
    'We employ robust security measures to protect Your data, both at rest and in transit.',
  ),
  PrivacyPolicyContentItem.heading('Encryption', level: 2, id: 'encryption'),
  PrivacyPolicyContentItem.subHeading('At Rest:'),
  PrivacyPolicyContentItem.bullet(
    'Server Data:',
    'All Usage Data, Personal Information and Personal Health Information stored on Google Cloud servers and Our servers is encrypted at rest using industry-standard encryption protocols (e.g., AES-256). Google Cloud implements multiple layers of encryption to protect data on its storage devices.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Local Data:',
    'Personal Health Information stored locally on Your device is encrypted using standard device-level encryption features available on modern mobile operating systems. This ensures that Your data is protected even if your device is compromised.',
  ),
  PrivacyPolicyContentItem.subHeading('In Transit:'),
  PrivacyPolicyContentItem.paragraph(
    'All data transmitted between Your device, Our backend servers (for Account Information), and Google Cloud servers (for cloud-stored Personal Health Information) is encrypted using Transport Layer Security (TLS 1.2 or higher) protocols. This ensures that Your data is protected from interception during transfer.',
  ),
  PrivacyPolicyContentItem.heading(
    'Pseudonymization',
    level: 2,
    id: 'pseudonymization',
  ),
  PrivacyPolicyContentItem.description(
    'When Your Personal Health Information (sensor data, journal data and derived data) is transmitted to Google Cloud, it is pseudonymized by replacing direct identifiers (like Your name or email address) with unique, random identifiers. This means that while the data can be linked back to a specific user through a separate mapping held securely by the Company, it is not directly identifiable by Google Cloud or others accessing the pseudonymized data.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Purpose:',
    'Pseudonymization allows us to perform necessary data processing and analysis in the cloud while reducing the direct link between Your Personal Health Information and Your identity, enhancing privacy.',
  ),
  PrivacyPolicyContentItem.heading(
    'How We Share Your Information',
    level: 1,
    id: 'dataSharing',
  ),
  PrivacyPolicyContentItem.description(
    'We are committed to strict limitations on data sharing. We do not give Your Personal Information or Personal Health Information to any third parties for marketing, advertising, or any other commercial purposes, with the exceptions stated below. ',
  ),
  PrivacyPolicyContentItem.heading(
    'Strictly with Google Cloud (only if opted-in)',
    level: 2,
  ),
  PrivacyPolicyContentItem.description(
    'The only third-party service provider with whom Your Personal Information and Personal Health Information (Sensor Data, Journal Data and Derived Data) may be shared is Google Cloud, and only if You have explicitly opted in to cloud storage as described in the "Cloud vs. Local Data Storage & Processing" section. Google Cloud processes this data solely for the purpose of providing the hosting and processing services necessary for the App\'s functionality. We do not engage with any other third parties for analytics, advertising, payments, or any other purposes.',
  ),
  PrivacyPolicyContentItem.heading('For Legal Reasons', level: 2),
  PrivacyPolicyContentItem.description(
    'We may disclose Your Personal Information and/or Personal Health Information where required to do so by law or in response to valid requests by public authorities (e.g., a court order or a government agency), but only to the extent necessary and in compliance with PIPEDA. ',
  ),
  PrivacyPolicyContentItem.heading(
    'Retention of Your Information',
    level: 1,
    id: 'dataRetention',
  ),
  PrivacyPolicyContentItem.description(
    'We retain Your Personal Information and Personal Health Information only for as long as is necessary to fulfill the purposes for which it was collected, including for satisfying any legal, accounting, or reporting requirements, and to provide you with the services you request.',
  ),
  PrivacyPolicyContentItem.heading('Account Information', level: 2),
  PrivacyPolicyContentItem.description(
    'Your email address and name are retained as long as Your account is active. If You request to delete Your account, Your email address and name will be permanently deleted from Our systems immediately upon receiving and verifying Your request, along with all other associated data.',
  ),
  PrivacyPolicyContentItem.bullet('Data Type:', 'Email Address and Name'),
  PrivacyPolicyContentItem.heading('Personal Health Information', level: 2),
  PrivacyPolicyContentItem.bullet(
    'Cloud Stored:',
    'If You have opted into cloud storage and subsequently delete the App from Your device, We will retain Your cloud-stored Personal Health Information for a period of one (1) year from the date of App deletion. This is to facilitate Your potential return to the App, allowing You to resume Your sleep tracking without loss of historical data.',
  ),
  PrivacyPolicyContentItem.bullet(
    'User Initiated Deletion:',
    'If You explicitly request Us to delete Your Personal Health Information from the cloud (even if Your account remains active), We will delete it immediately upon receiving and verifying Your request.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Local Stored:',
    'As stated above, We are not responsible for locally stored data. This data will be retained on Your device until You delete it or the App, or if Your device is compromised.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Data Type:',
    'Sensor Data, Journal Data and Derived Data',
  ),
  PrivacyPolicyContentItem.heading('Usage Data', level: 2),
  PrivacyPolicyContentItem.bullet(
    'Pseudonymized:',
    'Psuedonomyzed usage data will be stored on Our servers up to a maximum of two (2) years after which it will be permanently deleted. If you choose to delete Your account or ask Us to delete Your usage data, the direct link between Your account (email/name) and Your pseudonymized usage data will be immediately severed, anonymizing it. This ensures that the remaining usage data, while still useful for overall App improvement, can no longer be associated with You as an identifiable individual.',
  ),
  PrivacyPolicyContentItem.bullet(
    'Anonymized:',
    'Anonymized or aggregated Usage Data may be retained indefinitely for internal analytical purposes to improve the App, as this data does not identify You personally.',
  ),
  PrivacyPolicyContentItem.heading(
    'Your Rights under PIPEDA',
    level: 1,
    id: 'userRights',
  ),
  PrivacyPolicyContentItem.description(
    'Under PIPEDA, You have specific rights regarding Your Personal Information. We are committed to upholding these rights',
  ),
  PrivacyPolicyContentItem.heading('Right to Access', level: 2),
  PrivacyPolicyContentItem.paragraph(
    'You have the right to request access to the Personal Information We hold about You. We will provide You with access to Your information within 30 days of receiving a written request.',
  ),
  PrivacyPolicyContentItem.heading(
    'Right to Correction/Rectification',
    level: 2,
  ),
  PrivacyPolicyContentItem.paragraph(
    'You have the right to request that We correct or amend any inaccurate or incomplete Personal Information We hold about You.',
  ),
  PrivacyPolicyContentItem.heading('Right to Withdraw Consent', level: 2),
  PrivacyPolicyContentItem.paragraph(
    'You have the right to withdraw Your consent to the collection, use, and disclosure of Your Personal Information at any time, subject to legal or contractual restrictions and reasonable notice. Please note that withdrawing consent, particularly for essential data (like sensor data or cloud storage), may impact Your ability to use certain features or the entire App. For example, opting out of cloud storage will limit the availability of complex sleep analysis features.',
  ),
  PrivacyPolicyContentItem.heading(
    'Right to Be Informed (Accountability and Openness): ',
    level: 2,
  ),
  PrivacyPolicyContentItem.paragraph(
    'We are accountable for the Personal Information under Our control and will make information about Our policies and practices relating to the management of Personal Information readily available to You through this Privacy Policy and the App’s transparency features.',
  ),
  PrivacyPolicyContentItem.heading('Right to Challenge Compliance', level: 2),
  PrivacyPolicyContentItem.paragraph(
    'You have the right to address a challenge concerning Our compliance with the above principles to Our Privacy Officer.',
  ),
  PrivacyPolicyContentItem.paragraph(
    'To exercise any of these rights, please contact Us using the contact information provided below. We may require You to provide specific information to help Us confirm Your identity and Your right to access Your Personal Information.',
  ),
  PrivacyPolicyContentItem.heading(
    'Data Breach Notification',
    level: 1,
    id: 'dataBreachNotification',
  ),
  PrivacyPolicyContentItem.description(
    'In the event of a breach of security safeguards involving personal information under Our control, We have a comprehensive plan in place to respond and notify You in accordance with PIPEDA requirements.',
  ),
  PrivacyPolicyContentItem.heading('Assessment of Risk', level: 2),
  PrivacyPolicyContentItem.paragraph(
    'Upon discovering a breach, We will immediately assess whether there is a "real risk of significant harm" to any individual whose personal information is involved. "Significant harm" includes bodily harm, humiliation, damage to reputation or relationships, loss of employment, business or professional opportunities, financial loss, identity theft, negative effects on the credit record, and damage to or loss of property.',
  ),
  PrivacyPolicyContentItem.heading(
    'Notification to the Office of the Privacy Commissioner of Canada (OPC)',
    level: 2,
  ),
  PrivacyPolicyContentItem.paragraph(
    'If We determine that there is a real risk of significant harm, We will report the breach to the OPC as soon as feasible. The report will include the prescribed information about the breach.',
  ),
  PrivacyPolicyContentItem.heading(
    'Notification to Affected Individuals',
    level: 2,
  ),
  PrivacyPolicyContentItem.paragraph(
    'If We determine that there is a real risk of significant harm to You, We will notify You as soon as feasible. The notification will be conspicuous and direct (e.g., via email or in-app message) and will include',
  ),
  PrivacyPolicyContentItem.listItem(
    'A description of the circumstances of the breach.',
  ),
  PrivacyPolicyContentItem.listItem(
    'The date or approximate period of the breach.',
  ),
  PrivacyPolicyContentItem.listItem(
    'A description of the personal information involved.',
  ),
  PrivacyPolicyContentItem.listItem(
    'The steps We have taken to reduce the risk of harm.',
  ),
  PrivacyPolicyContentItem.listItem(
    'The steps You can take to reduce Your risk of harm or mitigate any harm.',
  ),
  PrivacyPolicyContentItem.listItem('Contact information for further inquiry.'),
  PrivacyPolicyContentItem.heading(
    'Notification to Other Organizations',
    level: 2,
  ),
  PrivacyPolicyContentItem.paragraph(
    'We will also notify any other organization or government institution that may be able to reduce or mitigate the risk of harm resulting from the breach (e.g., law enforcement), as appropriate.',
  ),
  PrivacyPolicyContentItem.heading('Record Keeping', level: 2),
  PrivacyPolicyContentItem.paragraph(
    'We will keep a record of every breach of security safeguards involving personal information under Our control, regardless of whether it results in a real risk of significant harm. These records will be maintained for a minimum of two years.',
  ),
  PrivacyPolicyContentItem.heading(
    'Changes to the Privacy Policy',
    level: 1,
    id: 'policyChanges',
  ),
  PrivacyPolicyContentItem.paragraph(
    'We reserve the right to change this Privacy Policy from time to time. We will inform You of any significant changes by posting the updated notice in the App and on Our website. If We make any significant changes to Our notice, We will push a notification through the Sleep Tracker app and by e-mail.',
  ),
  PrivacyPolicyContentItem.heading('Contact Us', level: 1, id: 'contact'),
  PrivacyPolicyContentItem.description(
    'We encourage You to contact Us if You have any questions about the notice or about how We process Your personal information.  ',
  ),
  PrivacyPolicyContentItem.bullet('Email:', 'privacysupport@sleeptracker.com'),
];

class PrivacyTooltip extends StatefulWidget {
  const PrivacyTooltip({
    super.key,
    required this.color,
    this.iconSize = 40,
    required this.iconName,
    required this.violationsDetected,
    this.privacyViolations,
    required this.purpose,
    required this.storage,
    required this.access,
    this.optOutLink,
    this.privacyPolicySectionLink,
    this.regulationLink,
    required this.dataType,
  });

  final Color color;
  final double iconSize;
  final String iconName;
  final String violationsDetected;
  final String? privacyViolations;
  final String purpose;
  final String storage;
  final String access;
  final String? optOutLink;
  final String? privacyPolicySectionLink;
  final String? regulationLink;
  final String dataType;

  @override
  State<PrivacyTooltip> createState() => _PrivacyTooltipState();
}

class _PrivacyTooltipState extends State<PrivacyTooltip> {
  final GlobalKey _iconKey = GlobalKey();
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  void _handleIconPress() {
    final RenderBox? renderBox =
        _iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }
    final Offset position = renderBox.localToGlobal(Offset.zero);
    final Size iconSize = renderBox.size;
    final Size screen = MediaQuery.of(context).size;
    final bool showAbove = position.dy > screen.height / 2;
    _overlayEntry?.remove();
    _overlayEntry = OverlayEntry(
      builder: (BuildContext context) {
        // MIGRATION: React Native measured pageY and chose top/bottom tooltip
        //            placement. Flutter uses RenderBox.localToGlobal for the
        //            same screen-relative measurement.
        final double width = screen.width * 0.8;
        final double left = ((screen.width - width) / 2).clamp(
          12,
          screen.width,
        );
        final double top = showAbove
            ? max(24, position.dy - 510)
            : min(screen.height - 520, position.dy + iconSize.height + 12);
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeTooltip,
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: top,
              left: left,
              width: width,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 500),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _TooltipContent(
                      widget: widget,
                      onClose: _closeTooltip,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _isOpen = true);
  }

  void _closeTooltip() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _isOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dataType.contains('sensor')) {
      final List<String> parts = widget.dataType.split('-');
      return SensorPrivacyIcon(
        key: _iconKey,
        sensorType: parts.length > 1 ? parts[1] : 'accelerometer',
        iconName: widget.iconName,
        storageType: widget.dataType.contains('cloud') ? 'cloud' : 'local',
        handleIconPress: _handleIconPress,
      );
    }
    return PrivacyIcon(
      key: _iconKey,
      handleIconPress: _handleIconPress,
      isOpen: _isOpen,
      iconName: widget.iconName,
      iconSize: widget.iconSize,
    );
  }
}

class _TooltipContent extends StatelessWidget {
  const _TooltipContent({required this.widget, required this.onClose});

  final PrivacyTooltip widget;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bool lowRisk =
        widget.violationsDetected == getPrivacyRiskLabel(PrivacyRisk.low);
    return DefaultTextStyle(
      style: const TextStyle(color: Colors.black, fontSize: 12, height: 1.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.violationsDetected,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          if (!lowRisk && widget.privacyViolations != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(widget.privacyViolations!),
          ],
          const SizedBox(height: 12),
          const Text('Purpose:', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(widget.purpose),
          if (lowRisk) ...<Widget>[
            const SizedBox(height: 12),
            const Text(
              'Storage:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(widget.storage),
            const SizedBox(height: 12),
            const Text(
              'Access:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(widget.access),
          ],
          const Divider(color: Colors.white38),
          if (widget.privacyPolicySectionLink != null)
            TooltipLink(
              label: 'Link to privacy policy section',
              onTap: () {
                onClose();
                context.push(
                  '/privacy-policy?sectionId=${Uri.encodeQueryComponent(widget.privacyPolicySectionLink!)}',
                );
              },
            ),
          if (widget.regulationLink != null)
            TooltipLink(
              label: 'PIPEDA regulation',
              onTap: () => handlePipedaLink(widget.regulationLink!),
            ),
          if (widget.optOutLink != null)
            TooltipLink(
              label: 'Opt Out',
              onTap: () {
                onClose();
                context.go(widget.optOutLink!);
              },
            ),
          TooltipLink(
            label: 'View Full Privacy Policy',
            onTap: () {
              onClose();
              context.push('/privacy-policy');
            },
          ),
        ],
      ),
    );
  }
}

class TooltipLink extends StatelessWidget {
  const TooltipLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.tooltipLinkBlue,
            decoration: TextDecoration.underline,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class PrivacyIcon extends StatelessWidget {
  const PrivacyIcon({
    super.key,
    required this.handleIconPress,
    required this.isOpen,
    required this.iconName,
    this.iconSize = 40,
  });

  final VoidCallback handleIconPress;
  final bool isOpen;
  final String iconName;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final String key = isOpen ? '$iconName-open' : iconName;
    final String asset =
        <String, String>{
          'privacy-high': 'assets/images/privacy/privacy-high.png',
          'privacy-medium': 'assets/images/privacy/privacy-medium.png',
          'privacy-low': 'assets/images/privacy/privacy-low.png',
          'privacy-high-open': 'assets/images/privacy/privacy-high-open.png',
          'privacy-medium-open':
              'assets/images/privacy/privacy-medium-open.png',
          'privacy-low-open': 'assets/images/privacy/privacy-low-open.png',
        }[key] ??
        'assets/images/privacy/privacy-low.png';
    final double size = isOpen ? iconSize + 10 : iconSize;
    return IconButton(
      padding: const EdgeInsets.all(4),
      onPressed: handleIconPress,
      icon: Image.asset(asset, width: size, height: size),
    );
  }
}

class SensorPrivacyIcon extends StatelessWidget {
  const SensorPrivacyIcon({
    super.key,
    required this.sensorType,
    required this.iconName,
    required this.storageType,
    required this.handleIconPress,
  });

  final String sensorType;
  final String iconName;
  final String storageType;
  final VoidCallback handleIconPress;

  @override
  Widget build(BuildContext context) {
    final String asset =
        'assets/images/privacy/sensor/$sensorType-$storageType-$iconName.png';
    return IconButton(
      padding: const EdgeInsets.all(4),
      onPressed: handleIconPress,
      icon: Image.asset(
        asset,
        width: sensorType == 'accelerometer' ? 121 : 124,
        height: storageType == 'cloud' ? 36 : 45,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
          return Image.asset(
            'assets/images/privacy/privacy-low.png',
            width: 40,
            height: 40,
          );
        },
      ),
    );
  }
}

class SensorNotAvailableWidget extends StatelessWidget {
  const SensorNotAvailableWidget({super.key, required this.sensorName});

  final String sensorName;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        '$sensorName unavailable on iOS',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

class PrivacySleepPage extends StatelessWidget {
  const PrivacySleepPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransparencyBloc, TransparencyState>(
      builder: (BuildContext context, TransparencyState state) {
        return PrivacyDetail(event: state.journal);
      },
    );
  }
}

class PrivacyJournalPage extends StatelessWidget {
  const PrivacyJournalPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransparencyBloc, TransparencyState>(
      builder: (BuildContext context, TransparencyState state) {
        final bool accelerometerMoreSevere =
            (state.accelerometer.privacyRisk ?? PrivacyRisk.low).order >
            (state.journal.privacyRisk ?? PrivacyRisk.low).order;
        final List<Widget> sections = <Widget>[
          PrivacyDetail(title: 'Journal', event: state.journal),
          PrivacyDetail(title: 'Activity Tracker', event: state.accelerometer),
        ];
        return Column(
          children: accelerometerMoreSevere
              ? sections.reversed.toList(growable: false)
              : sections,
        );
      },
    );
  }
}

class PrivacySleepModePage extends StatelessWidget {
  const PrivacySleepModePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransparencyBloc, TransparencyState>(
      builder: (BuildContext context, TransparencyState state) {
        final List<MapEntry<String, TransparencyEvent>> sensors =
            <MapEntry<String, TransparencyEvent>>[
              MapEntry<String, TransparencyEvent>(
                'Accelerometer',
                state.accelerometer,
              ),
              MapEntry<String, TransparencyEvent>('Light Sensor', state.light),
              MapEntry<String, TransparencyEvent>(
                'Microphone',
                state.microphone,
              ),
            ]..sort(
              (
                MapEntry<String, TransparencyEvent> a,
                MapEntry<String, TransparencyEvent> b,
              ) => (b.value.privacyRisk ?? PrivacyRisk.low).order.compareTo(
                (a.value.privacyRisk ?? PrivacyRisk.low).order,
              ),
            );
        return ListView(
          padding: const EdgeInsets.only(top: 72),
          children: sensors
              .map<Widget>(
                (MapEntry<String, TransparencyEvent> entry) =>
                    PrivacyDetail(title: entry.key, event: entry.value),
              )
              .toList(),
        );
      },
    );
  }
}

class PrivacyStatisticsPage extends StatelessWidget {
  const PrivacyStatisticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransparencyBloc, TransparencyState>(
      builder: (BuildContext context, TransparencyState state) {
        return PrivacyDetail(title: 'Statistics', event: state.statistics);
      },
    );
  }
}

class PrivacyDetail extends StatelessWidget {
  const PrivacyDetail({super.key, this.title, required this.event});

  final String? title;
  final TransparencyEvent event;

  @override
  Widget build(BuildContext context) {
    final PrivacyRisk risk = event.privacyRisk ?? PrivacyRisk.low;
    final bool isLowRisk = risk == PrivacyRisk.low;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Text(
                title!,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Text(
              getPrivacyRiskLabel(risk),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          if (!isLowRisk)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Text(formatPrivacyViolations(event)),
            ),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: AppColors.lightBlack,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                RichText(
                  text: TextSpan(
                    style: const TextStyle(color: Colors.white, height: 1.35),
                    children: <InlineSpan>[
                      const TextSpan(
                        text: 'Purpose: ',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: event.aiExplanation?.why ?? ''),
                    ],
                  ),
                ),
                if (isLowRisk) ...<Widget>[
                  const SizedBox(height: 8),
                  Text('Storage: ${event.aiExplanation?.storage ?? ''}'),
                  const SizedBox(height: 8),
                  Text('Access: ${event.aiExplanation?.access ?? ''}'),
                ],
              ],
            ),
          ),
          TextButton(
            onPressed: () => context.push('/privacy-policy'),
            child: const Text('View Full Privacy Policy'),
          ),
        ],
      ),
    );
  }
}

class Loader extends StatelessWidget {
  const Loader({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.appBackground,
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

Color getPrivacyRiskColor(PrivacyRisk risk) {
  return switch (risk) {
    PrivacyRisk.high => AppColors.tooltipRed,
    PrivacyRisk.medium => AppColors.tooltipYellow,
    PrivacyRisk.low => AppColors.tooltipGreen,
  };
}

String getPrivacyRiskIcon(PrivacyRisk risk) {
  return switch (risk) {
    PrivacyRisk.high => 'privacy-high',
    PrivacyRisk.medium => 'privacy-medium',
    PrivacyRisk.low => 'privacy-low',
  };
}

String getPrivacyRiskIconForPage(List<PrivacyRisk> risks) {
  if (risks.contains(PrivacyRisk.high)) return 'privacy-high';
  if (risks.contains(PrivacyRisk.medium)) return 'privacy-medium';
  return 'privacy-low';
}

String getPrivacyRiskLabel(PrivacyRisk risk) {
  return switch (risk) {
    PrivacyRisk.high => 'Major Privacy Violation Detected:',
    PrivacyRisk.medium => 'Some Privacy Concerns Detected:',
    PrivacyRisk.low => 'No Privacy Violations Detected',
  };
}

String formatPrivacyViolations(TransparencyEvent transparency) {
  final String issues = transparency.regulatoryCompliance?.issues ?? '';
  if (issues.isEmpty) {
    return 'No privacy violations detected';
  }
  return transparency.aiExplanation?.privacyExplanation ?? issues;
}

Future<void> handlePipedaLink(String regulationLink) async {
  const String pipedaBaseUrl =
      'https://www.priv.gc.ca/en/privacy-topics/privacy-laws-in-canada/the-personal-information-protection-and-electronic-documents-act-pipeda/p_principle/principles';
  final String url = regulationLink.isEmpty
      ? pipedaBaseUrl
      : '$pipedaBaseUrl/p_$regulationLink/';
  final Uri uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

String formatMonthDay(DateTime date) {
  const List<String> months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${months[date.month - 1]} ${date.day.toString().padLeft(2, '0')}';
}

Future<String?> showTextEditDialog(
  BuildContext context, {
  required String title,
  required String initial,
}) async {
  final TextEditingController controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: AppColors.lightBlack,
        title: Text(title),
        content: MigrationTextField(
          controller: controller,
          label: title,
          maxLines: 5,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

Future<List<SleepNote>?> showSleepNotesDialog(
  BuildContext context,
  List<SleepNote> initial,
) async {
  final Set<SleepNote> selected = initial.toSet();
  return showDialog<List<SleepNote>>(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          return AlertDialog(
            backgroundColor: AppColors.lightBlack,
            title: const Text('Sleep Notes'),
            content: SingleChildScrollView(
              child: Column(
                children: SleepNote.values.map<Widget>((SleepNote note) {
                  return CheckboxListTile(
                    value: selected.contains(note),
                    title: Text(note.label),
                    activeColor: AppColors.generalBlue,
                    onChanged: (bool? value) {
                      setState(() {
                        if (value ?? false) {
                          selected.add(note);
                        } else {
                          selected.remove(note);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(selected.toList(growable: false)),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}

extension FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
