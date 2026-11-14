import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/lesson_links.dart';
import 'package:lingua_srs/widgets/lesson_content_view.dart';
import 'package:provider/provider.dart';
import 'package:webview_all/webview_all.dart' show WebViewWidget;
import 'package:webview_platform_interface/webview_platform_interface.dart';

import 'fake_webview_platform.dart';

/// Records what the page asks the audio service to play.
class _RecordingAudio extends ChangeNotifier implements AudioService {
  final played = <String>[];

  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  Future<void> speak(String text, {String? language}) async =>
      played.add('speak:$text:$language');
  @override
  Future<void> playAudio(String? urlOrPath, {String? playingKey}) async =>
      played.add('audio:$urlOrPath');
  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  group('LessonContent.parse', () {
    test('starts a chunk at every heading and collects headings', () {
      final content = LessonContent.parse(
        '# One\n\ntext\n\n## 두 번째\n\nmore\n\n### Three',
      );

      expect(content.chunks, ['# One\n\ntext', '## 두 번째\n\nmore', '### Three']);
      expect(content.headings.map((h) => h.level), [1, 2, 3]);
      expect(content.headings.map((h) => h.text), ['One', '두 번째', 'Three']);
      expect(content.headings.map((h) => h.chunk), [0, 1, 2]);
    });

    test('ignores headings and markers inside fenced code', () {
      final content = LessonContent.parse(
        '## A\n\n```\n# not a heading\n<!-- chunk -->\n```\n\n## A',
      );

      expect(content.headings.length, 2);
      expect(content.chunks.length, 2);
      expect(content.chunks.first, contains('<!-- chunk -->'));
    });

    test('returns nothing for empty input', () {
      final content = LessonContent.parse('  \n');

      expect(content.chunks, isEmpty);
      expect(content.headings, isEmpty);
    });

    test('cuts a long section at a blank line', () {
      final content = LessonContent.parse('aaaa\n\nbbbb\n\ncccc', maxChars: 5);

      expect(content.chunks, ['aaaa', 'bbbb', 'cccc']);
    });

    test('does not cut inside a list or a table', () {
      final content = LessonContent.parse(
        '- a\n\n- b\n\n| x |\n|---|\n\n| y |',
        maxChars: 1,
      );

      expect(content.chunks, ['- a\n\n- b\n\n| x |\n|---|\n\n| y |']);
    });

    test('forces a cut at <!-- chunk --> and drops the marker', () {
      final content = LessonContent.parse('one\n\n<!-- chunk -->\n\ntwo');

      expect(content.chunks, ['one', 'two']);
    });

    test('keeps a chunk:start/chunk:end group in one chunk', () {
      final content = LessonContent.parse(
        'before\n\n<!-- chunk:start -->\n\n# Inside\n\n<!-- chunk -->\n\n'
        'body\n\n<!-- chunk:end -->\n\nafter',
        maxChars: 1,
      );

      expect(content.chunks.length, 3);
      expect(content.chunks[0], 'before');
      expect(content.chunks[1], startsWith('# Inside'));
      expect(content.chunks[1], endsWith('body'));
      expect(content.chunks[2], 'after');
      expect(content.headings.single.chunk, 1);
    });
  });

  group('details blocks', () {
    test('stay in one chunk, headings and blank lines included', () {
      final content = LessonContent.parse(
        'before\n\n<details>\n<summary>More</summary>\n\n'
        '## Inside\n\none\n\ntwo\n\n</details>\n\n## After\n\nend',
        maxChars: 1,
      );

      // before | the whole block | ## After | end
      expect(content.chunks, hasLength(4));
      expect(content.chunks[1], startsWith('<details>'));
      expect(content.chunks[1], contains('## Inside'));
      expect(content.chunks[1], endsWith('</details>'));
      expect(content.chunks[2], startsWith('## After'));
      expect(content.headings.map((h) => h.chunk), [1, 2]);
    });

    test('a tag in code does not start one', () {
      final content = LessonContent.parse(
        'Write `<details>` to fold text.\n\n## Next\n\nend',
      );

      expect(content.chunks, hasLength(2));
    });

    test('the Details component is gone: only its content is kept', () {
      final text = LessonContent.preprocess(
        '<Details summary="Examples">\n\ninside\n\n</Details>',
      );

      expect(text.trim(), 'inside');
    });

    test('details and summary tags are kept for the renderer', () {
      final text = LessonContent.preprocess(
        '<details open>\n<summary>More</summary>\n\ninside\n\n</details>',
      );

      expect(text, contains('<details open>'));
      expect(text, contains('<summary>More</summary>'));
      expect(text, contains('</details>'));
    });
  });

  group('LessonContent.preprocess', () {
    test('turns components into what MarkdownContent renders', () {
      final text = LessonContent.preprocess(
        'Intro\n\n<YouTube id="abc123" />\n\n'
        '<AudioButton src="a.mp3" />\n\n<TTS>안녕</TTS>\n\n'
        '<span class="spoiler">hidden</span>',
      );

      expect(text, contains('lingua-youtube:'));
      expect(text, contains('lingua-audio:?src=a.mp3'));
      expect(text, contains('안녕 ![tts]'));
      expect(text, contains('![spoiler]'));
    });

    test('strips scripts, quizzes, unknown components and comments', () {
      final text = LessonContent.preprocess(
        '<VocabQuiz a="b" />\n<script>alert(1)</script>\n<Foo>x</Foo>\n'
        '<!-- note -->\n<!-- chunk -->',
      );

      expect(text, isNot(contains('VocabQuiz')));
      expect(text, isNot(contains('script')));
      expect(text, isNot(contains('Foo')));
      expect(text, isNot(contains('note')));
      expect(text, contains('<!-- chunk -->'));
    });

    test('turns [[lesson links]] into Markdown links', () {
      final text = LessonContent.preprocess(
        '[[Lesson 1#Past tense]]\n\n```\n[[Lesson 1]]\n```',
      );

      expect(text, contains('[Lesson 1 › Past tense](<lingua-lesson:'));
      expect(text, contains('```\n[[Lesson 1]]\n```'));
    });

    test('does not alter fenced code content', () {
      final text = LessonContent.preprocess('```\n<YouTube id="x" />\n```');

      expect(text, contains('<YouTube id="x" />'));
      expect(text, isNot(contains('lingua-youtube')));
    });
  });

  group('heading anchors', () {
    const markdown =
        '## Present\n\n### Polite\n\n## Past\n\n### Polite\n\n'
        '## Future\n\n### Polite {#future-polite .note}\n\n'
        'Plain\n=====\n\nSetext {#setext}\n------';

    test('number repeated headings and use {#id}', () {
      final content = LessonContent.parse(markdown);

      expect(content.headings.map((h) => h.anchor), [
        'present',
        'polite',
        'past',
        'polite-1',
        'future',
        'future-polite',
        'plain',
        'setext',
      ]);
      expect(content.headings[5].text, 'Polite');
      expect(content.headings[7].text, 'Setext');
    });

    test('drop {#id} from the rendered heading', () {
      final content = LessonContent.parse(markdown);

      expect(content.chunks[5], '### Polite');
      expect(content.chunks[7], startsWith('Setext\n---'));
    });

    test('a link finds a heading by anchor, then by text', () {
      final content = LessonContent.parse(markdown);

      expect(content.headingFor('polite'), same(content.headings[1]));
      expect(content.headingFor('Polite-1'), same(content.headings[3]));
      expect(content.headingFor('future-polite'), same(content.headings[5]));
      expect(content.headingFor('Past'), same(content.headings[2]));
      expect(content.headingFor('nothing'), isNull);
    });

    test('a site generator\'s anchor finds its heading', () {
      // VitePress writes `1. Intro` as `#_1-intro`.
      final content = LessonContent.parse('## 1. Intro\n\ntext');

      expect(content.headingFor('_1-intro'), same(content.headings.single));
    });
  });

  group('setext headings', () {
    test('are listed and start a chunk', () {
      final content = LessonContent.parse(
        'Intro\n\nTitle\n=====\n\nbody\n\nSub\n---\n\ntext',
      );

      expect(content.headings.map((h) => (h.level, h.text)), [
        (1, 'Title'),
        (2, 'Sub'),
      ]);
      expect(content.headings.map((h) => h.chunk), [1, 2]);
    });

    test('ignore rules after a multi-line paragraph and fenced code', () {
      final content = LessonContent.parse(
        'one\ntwo\n---\n\n```\nTitle\n=====\n```',
      );

      expect(content.headings, isEmpty);
    });
  });

  group('LessonContentView', () {
    const lesson =
        '# Lesson\n\nIntro.\n\n## Past tense\n\nText.\n\n'
        '[[Lesson 1#Past tense]]\n';
    late FakeWebViewPlatform platform;
    late _RecordingAudio audio;

    setUp(() {
      platform = FakeWebViewPlatform();
      WebViewPlatform.instance = platform;
      audio = _RecordingAudio();
      LessonScrollMemory.clear();
    });

    Future<void> show(
      WidgetTester tester, {
      String markdown = lesson,
      String? initialHeading,
      String? scrollKey,
      LessonContentController? controller,
      void Function(LessonLink link)? onLessonLink,
    }) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AudioService>.value(
          value: audio,
          child: MaterialApp(
            home: Scaffold(
              body: LessonContentView(
                key: UniqueKey(),
                markdown: markdown,
                controller: controller,
                initialHeading: initialHeading,
                scrollKey: scrollKey,
                onLessonLink: onLessonLink,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('loads the lesson as one page, with a real origin', (
      tester,
    ) async {
      await show(tester);

      final web = platform.controller;
      expect(web.baseUrl, 'https://www.youtube-nocookie.com/');
      expect(web.html, contains('<h1 id="lesson">Lesson</h1>'));
      expect(web.html, contains('<h2 id="past-tense">Past tense</h2>'));
      expect(web.html, contains('linguaStart(0.0, null)'));
    });

    testWidgets('Windows loads a packaged HTTPS host asset', (tester) async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await show(tester);

      final web = platform.controller;
      expect(web.flutterAsset, 'assets/webview_host.html');
      expect(web.requested, isNull);
      web.finish();
      expect(
        web.scripts.single,
        contains('document.documentElement.innerHTML'),
      );
    });

    testWidgets('a link to a heading scrolls the page to it', (tester) async {
      await show(tester);
      platform.controller.finish();

      platform.controller.send({'type': 'link', 'href': '#Past tense'});
      await tester.pump();

      expect(platform.controller.scripts, [
        'linguaScrollTo("past-tense", true);',
      ]);
    });

    testWidgets('a scroll asked for while loading waits for the page', (
      tester,
    ) async {
      final controller = LessonContentController();
      await show(tester, controller: controller);

      expect(controller.scrollToHeadingNamed('past-tense'), isTrue);
      expect(platform.controller.scripts, isEmpty);
      platform.controller.finish();
      expect(platform.controller.scripts, [
        'linguaScrollTo("past-tense", true);',
      ]);
      expect(controller.scrollToHeadingNamed('nowhere'), isFalse);
    });

    testWidgets('a link to a missing heading says so', (tester) async {
      await show(tester);
      platform.controller.finish();

      platform.controller.send({'type': 'link', 'href': '#nowhere'});
      await tester.pump();

      expect(find.text('No heading “nowhere” in this lesson.'), findsOneWidget);
    });

    testWidgets('a link to another lesson goes to onLessonLink', (
      tester,
    ) async {
      final links = <LessonLink>[];
      await show(tester, onLessonLink: links.add);

      platform.controller.send({
        'type': 'link',
        'href': const LessonLink(
          lesson: 'Lesson 1',
          heading: 'Past tense',
        ).href,
      });
      await tester.pump();

      expect(links.single.lesson, 'Lesson 1');
      expect(links.single.heading, 'Past tense');
      expect(platform.controller.scripts, isEmpty);
    });

    testWidgets('opens at initialHeading', (tester) async {
      await show(tester, initialHeading: 'Past tense');

      expect(
        platform.controller.html,
        contains('linguaStart(0.0, "past-tense")'),
      );
    });

    testWidgets('plays audio and speaks text for the page', (tester) async {
      await show(tester);

      platform.controller.send({'type': 'audio', 'src': 'https://a/b.mp3'});
      platform.controller.send({'type': 'tts', 'text': '안녕'});
      platform.controller.send({'type': 'tts', 'text': '  '});
      await tester.pump();

      expect(audio.played, ['audio:https://a/b.mp3', 'speak:안녕:ko']);
    });

    testWidgets('keeps out navigations once the page has loaded', (
      tester,
    ) async {
      await show(tester);
      final delegate = platform.controller.delegate!;
      NavigationRequest request(String url, {bool main = true}) =>
          NavigationRequest(url: url, isMainFrame: main);

      expect(
        delegate.onNavigationRequest!(request('about:blank')),
        NavigationDecision.navigate,
      );
      platform.controller.finish();
      expect(
        delegate.onNavigationRequest!(request('https://example.com/')),
        NavigationDecision.prevent,
      );
      expect(
        delegate.onNavigationRequest!(
          request('https://www.youtube-nocookie.com/embed/x', main: false),
        ),
        NavigationDecision.navigate,
      );
    });

    testWidgets('a link out of the player opens the playing video', (
      tester,
    ) async {
      await show(tester);
      platform.controller.finish();
      final delegate = platform.controller.delegate!;

      platform.controller.send({
        'type': 'youtube',
        'watch': 'https://www.youtube.com/watch?v=abc',
      });
      await tester.pump();

      expect(
        delegate.onNavigationRequest!(
          const NavigationRequest(
            url: 'intent://watch?v=abc#Intent;scheme=vnd.youtube;end',
            isMainFrame: false,
          ),
        ),
        NavigationDecision.prevent,
      );
    });

    testWidgets(
      'rotation expands the active video without replacing the page',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        platform.android = true;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fullscreen = <bool>[];
        final controller = LessonContentController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LessonContentView(
                markdown: '<YouTube id="abc" />',
                controller: controller,
                onVideoFullscreenChanged: fullscreen.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final web = platform.controller;
        final player = tester.element(find.byType(WebViewWidget));

        tester.view.physicalSize = const Size(800, 400);
        await tester.pumpAndSettle();
        expect(fullscreen, isEmpty);
        web.send({
          'type': 'youtube',
          'watch': 'https://youtube.com/watch?v=abc',
        });
        await tester.pumpAndSettle();
        expect(fullscreen, [true]);
        expect(web.scripts.last, 'linguaSetYouTubeFullscreen(true);');
        expect(tester.element(find.byType(WebViewWidget)), same(player));

        controller.exitVideoFullscreen();
        await tester.pumpAndSettle();
        expect(fullscreen, [true, false]);
        expect(web.scripts.last, 'linguaSetYouTubeFullscreen(false);');

        tester.view.physicalSize = const Size(400, 800);
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(800, 400);
        await tester.pumpAndSettle();
        expect(fullscreen, [true, false, true]);
        tester.view.physicalSize = const Size(400, 800);
        await tester.pumpAndSettle();
        expect(fullscreen, [true, false, true, false]);
        expect(tester.element(find.byType(WebViewWidget)), same(player));
      },
    );

    testWidgets('iframe fullscreen keeps the lesson WebView active', (
      tester,
    ) async {
      platform.android = true;
      await show(tester);
      final web = platform.controller as FakeAndroidWebViewController;
      final player = tester.element(find.byType(WebViewWidget));
      var hidden = false;
      web.onShowCustomWidget!(const Text('fullscreen video'), () {
        hidden = true;
        web.onHideCustomWidget!();
      });
      await tester.pumpAndSettle();
      expect(find.text('fullscreen video'), findsOneWidget);
      expect(tester.element(find.byType(WebViewWidget)), same(player));
      expect(hidden, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(hidden, isTrue);
      expect(tester.element(find.byType(WebViewWidget)), same(player));
    });

    testWidgets('portrait rotation exits native iframe fullscreen', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      platform.android = true;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await show(tester);
      final web = platform.controller as FakeAndroidWebViewController;
      web.send({'type': 'youtube', 'watch': 'https://youtube.com/watch?v=abc'});
      var hidden = false;
      web.onShowCustomWidget!(const Text('fullscreen video'), () {
        hidden = true;
        web.onHideCustomWidget!();
      });
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      expect(find.text('fullscreen video'), findsOneWidget);
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(hidden, isTrue);
      expect(find.text('fullscreen video'), findsNothing);
      expect(find.byType(WebViewWidget), findsOneWidget);
    });

    group('returning to a lesson', () {
      testWidgets('opens it where it was left', (tester) async {
        await show(tester, scrollKey: 'a');
        platform.controller.send({'type': 'scroll', 'y': 420});

        await tester.pumpWidget(const SizedBox());
        await show(tester, scrollKey: 'a');

        expect(platform.controller.html, contains('linguaStart(420.0, null)'));
      });

      testWidgets('starts other lessons, and changed text, at the top', (
        tester,
      ) async {
        await show(tester, scrollKey: 'a');
        platform.controller.send({'type': 'scroll', 'y': 420});

        await tester.pumpWidget(const SizedBox());
        await show(tester, scrollKey: 'b');
        expect(platform.controller.html, contains('linguaStart(0.0, null)'));

        await tester.pumpWidget(const SizedBox());
        await show(tester, scrollKey: 'a', markdown: '# Changed\n\nText.');
        expect(platform.controller.html, contains('linguaStart(0.0, null)'));
      });

      testWidgets('goes to a linked heading instead of the saved place', (
        tester,
      ) async {
        await show(tester, scrollKey: 'a');
        platform.controller.send({'type': 'scroll', 'y': 420});

        await tester.pumpWidget(const SizedBox());
        await show(tester, scrollKey: 'a', initialHeading: 'Past tense');

        expect(
          platform.controller.html,
          contains('linguaStart(0.0, "past-tense")'),
        );
      });
    });
  });
}
