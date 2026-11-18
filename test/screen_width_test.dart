import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:lingua_srs/views/lesson_list_view.dart';
import 'package:lingua_srs/views/recent_ai_discussions_view.dart';
import 'package:lingua_srs/views/sentence_pool_view.dart';
import 'package:lingua_srs/views/vocab_pool_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// Touches no audio plugin.
class _SilentAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Window widths from a small phone to a full HD desktop, with the app's
/// breakpoints (560, 700, 800, 1100) and a pixel either side of them.
const _widths = <double>[
  360,
  411,
  559,
  560,
  561,
  699,
  700,
  701,
  799,
  800,
  801,
  1024,
  1099,
  1100,
  1101,
  1440,
  1920,
];

/// Lessons, words, sentences and discussions with long text, so a screen
/// that cannot fit its content at some width fails with an overflow.
const _lessonYaml = '''
---
vocabulary:
  nouns:
    - ko: 사과
      en: apple
    - ko: 국립중앙박물관
      en: the National Museum of Korea, in Yongsan, Seoul
  verbs:
    - ko: 먹다
      en: to eat
---
# Food and places with a rather long lesson title that has to wrap somewhere
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_screen_width_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (storageDirectory.existsSync()) {
      await storageDirectory.delete(recursive: true);
    }
  });

  Future<(AppProvider, Lesson)> seededProvider(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      'lingua_srs_lessons': '[]',
      'lingua_srs_sentences': '[]',
    });
    final provider = AppProvider();
    addTearDown(provider.dispose);
    for (var i = 0; i < 100 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(provider.isLoading, isFalse, reason: 'provider never loaded');

    final lesson = await tester.runAsync<Lesson>(() async {
      final lesson = await provider.importYaml(
        _lessonYaml,
        defaultUnitTitle: 'Unit 1 with a long folder name::Everyday Korean',
      );
      await provider.addSentenceToPool(
        Sentence(
          targetText: '저는 국립중앙박물관 근처에서 사과를 먹었어요',
          translationText:
              'I ate an apple near the National Museum of Korea '
              'before it opened in the morning',
        ),
      );
      final apple = lesson.vocabularies.first;
      await provider.addAiDiscussionMessage(
        '${apple.id}:no-sentence',
        AiDiscussionMessage(
          role: 'user',
          content:
              'What is the difference between this word and the one '
              'used in formal writing, and when would I use either?',
          createdAt: DateTime(2026, 11, 1, 9),
        ),
      );
      return lesson;
    });
    return (provider, lesson!);
  }

  // Each screen, and a text that shows it has the seeded content.
  final screens = <String, (Widget Function(Lesson lesson), String)>{
    'Lessons': ((_) => const LessonListView(), 'Everyday Korean'),
    'Lesson detail': (
      (lesson) => LessonDetailView(lessonId: lesson.id),
      '국립중앙박물관',
    ),
    'Vocab Pool': ((_) => const VocabPoolView(), '국립중앙박물관'),
    'Sentence Pool': ((_) => const SentencePoolView(), '국립중앙박물관'),
    'Discussions': ((_) => const RecentAiDiscussionsView(), '사과'),
  };

  for (final MapEntry(key: name, value: (screen, shown)) in screens.entries) {
    testWidgets('$name fits every width from 360 to 1920 px', (tester) async {
      final (provider, lesson) = await seededProvider(tester);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final width in _widths) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AppProvider>.value(value: provider),
              ChangeNotifierProvider<AudioService>(
                create: (_) => _SilentAudioService(),
              ),
            ],
            child: MaterialApp(home: screen(lesson)),
          ),
        );
        await tester.pump();
        // An overflow is reported as an exception while laying out.
        expect(tester.takeException(), isNull, reason: '$name at $width px');
        expect(
          find.textContaining(shown, findRichText: true),
          findsWidgets,
          reason: '$name at $width px',
        );
      }
    });
  }
}
