import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/shared_vocab.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';

SharedVocab sv({String? audio, String notes = ''}) => SharedVocab(
  audioUrl: audio,
  notes: notes,
  cardTargetToNative: SrsCard(direction: CardDirection.targetToNative),
  cardNativeToTarget: SrsCard(direction: CardDirection.nativeToTarget),
);

void main() {
  group('SharedVocab ttsText', () {
    test('is a detail field, imported once and kept after a manual edit', () {
      expect(SharedVocab.detailFields, contains(SharedVocab.ttsField));
      final s = sv();
      expect(
        s.mergeImport(SharedVocab.ttsField, '세 개', lessonId: 'L1'),
        isTrue,
      );
      expect(s.ttsText, '세 개');

      s.setManual(SharedVocab.ttsField, '셋 개');
      expect(
        s.mergeImport(SharedVocab.ttsField, '세 개 b', lessonId: 'L1'),
        isFalse,
      );
      expect(s.ttsText, '셋 개');
      expect(SharedVocab.fromJson(s.toJson()).ttsText, '셋 개');
      expect(s.detachedCopy().ttsText, '셋 개');
    });
  });

  group('SharedVocab.setManual', () {
    test('is a no-op when unchanged, so saving a dialog locks nothing', () {
      final s = sv(audio: 'a');
      expect(s.setManual('audioUrl', 'a'), isFalse);
      expect(s.setManual('notes', ''), isFalse);
      expect(s.meta, isEmpty);
    });

    test('a manual clear locks the field against imports', () {
      final s = sv(audio: 'a');
      expect(s.setManual('audioUrl', '  '), isTrue);
      expect(s.audioUrl, isNull);
      expect(s.mergeImport('audioUrl', 'b', lessonId: 'L1'), isFalse);
      expect(s.audioUrl, isNull);
      expect(s.alternates['audioUrl'], ['b']);
    });
  });

  group('SharedVocab.mergeImport', () {
    test('ignores blank incoming values', () {
      final s = sv(audio: 'a');
      expect(s.mergeImport('audioUrl', '  ', lessonId: 'L1'), isFalse);
      expect(s.mergeImport('audioUrl', null, lessonId: 'L1'), isFalse);
      expect(s.audioUrl, 'a');
    });

    test('fills a blank field and records the writer', () {
      final s = sv();
      expect(s.mergeImport('audioUrl', 'a', lessonId: 'L1'), isTrue);
      expect(s.meta['audioUrl']!.lessonId, 'L1');
      expect(s.meta['audioUrl']!.origin, DetailOrigin.imported);
    });

    test(
      'the writing lesson may replace; another lesson only adds an alternate',
      () {
        final s = sv()..mergeImport('audioUrl', 'a', lessonId: 'L1');
        expect(s.mergeImport('audioUrl', 'b', lessonId: 'L2'), isFalse);
        expect(s.audioUrl, 'a');
        expect(s.alternates['audioUrl'], ['b']);
        expect(s.mergeImport('audioUrl', 'c', lessonId: 'L1'), isTrue);
        expect(s.audioUrl, 'c');
      },
    );

    test('never replaces a manual value, and a null lesson never replaces', () {
      final s = sv(audio: 'a')..setManual('audioUrl', 'm');
      expect(s.mergeImport('audioUrl', 'x', lessonId: 'L1'), isFalse);
      expect(s.audioUrl, 'm');
      final t = sv()..mergeImport('audioUrl', 'a', lessonId: 'L1');
      expect(t.mergeImport('audioUrl', 'b'), isFalse);
      expect(t.audioUrl, 'a');
    });

    test('alternates are de-duplicated and capped at five', () {
      final s = sv(audio: 'a');
      for (var i = 1; i <= 7; i++) {
        s.mergeImport('audioUrl', 'v$i', lessonId: 'L$i');
      }
      s.mergeImport('audioUrl', 'v7', lessonId: 'L9');
      expect(s.alternates['audioUrl'], ['v3', 'v4', 'v5', 'v6', 'v7']);
    });
  });

  test('stampUnowned only stamps non-blank values without a writer', () {
    final s = sv(audio: 'a', notes: 'n')
      ..meta['notes'] = const DetailMeta(DetailOrigin.manual);
    s.stampUnowned('L1');
    expect(s.meta['audioUrl']!.lessonId, 'L1');
    expect(s.meta['notes']!.origin, DetailOrigin.manual);
    expect(s.meta.containsKey('disambiguation'), isFalse);
  });

  test('restoreField copies value, provenance and alternates back', () {
    final before = sv(audio: 'a')
      ..meta['audioUrl'] = const DetailMeta(DetailOrigin.imported, 'L1');
    final now = sv(audio: 'b')
      ..meta['audioUrl'] = const DetailMeta(DetailOrigin.manual)
      ..alternates['audioUrl'] = ['x'];
    now.restoreField('audioUrl', before);
    expect(now.audioUrl, 'a');
    expect(now.meta['audioUrl']!.lessonId, 'L1');
    expect(now.alternates.containsKey('audioUrl'), isFalse);
  });

  test('detachedCopy keeps text and details, resets progress, copies maps', () {
    final s = sv(audio: 'a');
    s.cardTargetToNative
      ..backNotes = 'bn'
      ..frontHint = 'fh'
      ..repetitions = 4;
    s.alternates['audioUrl'] = ['x'];
    final c = s.detachedCopy();
    expect(c.audioUrl, 'a');
    expect(c.cardTargetToNative.backNotes, 'bn');
    expect(c.cardTargetToNative.frontHint, 'fh');
    expect(c.cardTargetToNative.repetitions, 0);
    expect(c.cardTargetToNative.id, isNot(s.cardTargetToNative.id));
    c.alternates['audioUrl']!.add('y');
    expect(s.alternates['audioUrl'], ['x']);
  });

  test('JSON round trip keeps provenance, alternates and card hints', () {
    final s = sv(audio: 'a')
      ..meta['audioUrl'] = const DetailMeta(DetailOrigin.imported, 'L1')
      ..alternates['audioUrl'] = ['x'];
    s.cardNativeToTarget.frontHint = 'general size';
    final back = SharedVocab.fromJson(s.toJson());
    expect(back.audioUrl, 'a');
    expect(back.meta['audioUrl']!.lessonId, 'L1');
    expect(back.alternates['audioUrl'], ['x']);
    expect(back.cardNativeToTarget.frontHint, 'general size');
  });

  test('MergedEntrySnapshot matches by lesson, wording and section path', () {
    final entry = VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns');
    final snap = MergedEntrySnapshot(
      lessonId: 'L1',
      targetWord: '배',
      translation: 'pear',
      sectionPath: List.of(entry.effectiveSectionPath),
      previousId: 'p',
      previousIdIsExplicit: false,
      previousShared: sv().toJson(),
    );
    expect(snap.matches('L1', entry), isTrue);
    expect(snap.matches('L2', entry), isFalse);
    expect(
      MergedEntrySnapshot.fromJson(snap.toJson()).matches('L1', entry),
      isTrue,
    );
  });
}
