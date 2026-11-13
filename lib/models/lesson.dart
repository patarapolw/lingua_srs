import 'package:uuid/uuid.dart';

import '../services/hangul_text.dart';
import 'vocab_item.dart';
import 'srs_card.dart';

class Lesson {
  final String id;
  String title;
  String? unitTitle;
  String targetLanguage; // e.g. 'ko', 'es', 'ja', 'fr'
  String nativeLanguage; // e.g. 'en'
  List<VocabItem> vocabularies;
  String markdownContent;

  /// Name of the Markdown file the lesson was imported from (`lesson-26.md`),
  /// so `.md` links between lesson files keep working. Null for lessons made
  /// in the app; see [virtualFileName].
  String? fileName;

  /// The folders that file was in, relative to the folder or ZIP imported
  /// (`unit-2/grammar`), with their names as they were. The app shows them
  /// renamed (`Unit 2 › Grammar`); see [virtualFolder]. Null at the top, or
  /// for lessons made in the app.
  String? fileFolder;

  /// [targetLanguage] as a lowercase code without a region or script: `zh`
  /// for `zh-TW`, `ko` for `ko-KR`.
  String get targetLanguageCode => languageCodeOf(targetLanguage);

  /// What tells this lesson's language from another's when lessons are
  /// shown one language at a time: [targetLanguage] in lower case with `-`
  /// between its parts, without a region that adds nothing (`ko` for
  /// `ko-KR`). Regions that differ stay apart: `zh-cn` and `zh-tw`.
  String get languageKey => languageKeyOf(targetLanguage);

  static String languageKeyOf(String language) =>
      withoutDefaultRegion(language).toLowerCase().replaceAll('_', '-');

  /// [language] as a lowercase code without a region or script.
  static String languageCodeOf(String language) =>
      language.trim().toLowerCase().split(RegExp(r'[-_]')).first;

  /// The region a language's bare code already stands for: `ko` is Korean
  /// as spoken in Korea, so `ko-KR` says nothing more than `ko`.
  ///
  /// Only languages with one such region are here. Chinese, English,
  /// Spanish, Portuguese, French and Arabic are not: their regions differ in
  /// script, voice or spelling, and none is the plain default.
  static const _defaultRegions = {
    'ko': 'kr',
    'ja': 'jp',
    'th': 'th',
    'vi': 'vn',
    'id': 'id',
    'tr': 'tr',
    'de': 'de',
    'it': 'it',
    'ru': 'ru',
    'pl': 'pl',
    'uk': 'ua',
    'cs': 'cz',
    'hu': 'hu',
    'ro': 'ro',
    'el': 'gr',
    'he': 'il',
    'hi': 'in',
    'fi': 'fi',
    'da': 'dk',
  };

  /// [language] without a region that adds nothing to it: `ko` for `ko-KR`
  /// and `ja` for `ja_JP`. A region that tells a variant apart is kept as
  /// written (`zh-TW`, `pt-BR`, `de-AT`), and so is anything else.
  static String withoutDefaultRegion(String language) {
    final tag = language.trim();
    final parts = tag.toLowerCase().split(RegExp(r'[-_]'));
    return parts.length == 2 && _defaultRegions[parts[0]] == parts[1]
        ? parts[0]
        : tag;
  }

  /// [title], [unitTitle], [fileName] and [fileFolder] are kept with Korean syllables
  /// composed ([composeHangul]), so names from a Mac, which can store them as
  /// separate jamo, match the same names from anywhere else. Every lesson is
  /// made here, whether parsed, loaded, synced or restored.
  Lesson({
    String? id,
    required String title,
    String? unitTitle,
    this.targetLanguage = 'ko',
    this.nativeLanguage = 'en',
    List<VocabItem>? vocabularies,
    this.markdownContent = '',
    String? fileName,
    String? fileFolder,
  }) : id = id ?? const Uuid().v4(),
       title = composeHangul(title),
       unitTitle = unitTitle == null ? null : composeHangul(unitTitle),
       fileName = fileName == null ? null : composeHangul(fileName),
       fileFolder = fileFolder == null || fileFolder.isEmpty
           ? null
           : composeHangul(fileFolder),
       vocabularies = vocabularies ?? [];

  /// Folder segments containing this lesson, from [unitTitle] plus any leading
  /// segments of [title].
  List<String> get folderPath {
    final explicitParts = splitHierarchyPath(unitTitle);
    var titleParts = splitHierarchyPath(title);
    if (isHierarchyPathWithin(titleParts, explicitParts)) {
      titleParts = titleParts.skip(explicitParts.length).toList();
    }
    return [
      ...explicitParts,
      ...titleParts.take(titleParts.isEmpty ? 0 : titleParts.length - 1),
    ];
  }

  /// Display-only form of [folderPath].
  String? get effectiveUnitTitle {
    final path = folderPath;
    return path.isEmpty ? null : formatHierarchyPath(path);
  }

  String get displayTitle {
    final titleParts = splitHierarchyPath(title);
    return titleParts.isEmpty ? title : titleParts.last;
  }

  /// The folders of the lesson's virtual path: those of the file it was
  /// imported from ([fileFolder]), with their names as they were, while the
  /// lesson is still in the app folders they were imported as; otherwise,
  /// such as after a move, its app folders ([folderPath]).
  ///
  /// Folder import turns `unit-2` into `Unit 2` and `past_tense` into
  /// `Past Tense`, so a folder counts as the same when [looseNameKey] says so.
  List<String> get virtualFolder {
    final app = folderPath;
    final original = fileFolder?.split('/') ?? const <String>[];
    if (original.isEmpty || original.length != app.length) return app;
    for (var i = 0; i < app.length; i++) {
      if (looseNameKey(original[i]) != looseNameKey(app[i])) return app;
    }
    return original;
  }

  /// The lesson's file name in its virtual folder ([virtualFolder]): the file
  /// it was imported from, or its title with `.md`, made safe as a file name.
  String get virtualFileName =>
      safePathSegment(fileName ?? '${safePathSegment(displayTitle)}.md');

  /// [virtualFolder] followed by [virtualFileName], each made safe as a file
  /// name: where `.md` links between lessons look for it, and where export
  /// writes it.
  List<String> get virtualPath => [
    ...virtualFolder.map(safePathSegment),
    virtualFileName,
  ];

  void moveToFolder(List<String> folder) {
    final leafTitle = displayTitle;
    unitTitle = folder.isEmpty ? null : joinHierarchyPath(folder);
    title = leafTitle;
  }

  int get activeCardsCount {
    int count = 0;
    final countedCards = <String>{};
    for (final v in vocabularies) {
      if (v.cardTargetToNative.isActive &&
          countedCards.add(v.cardTargetToNative.id)) {
        count++;
      }
      if (v.cardNativeToTarget.isActive &&
          countedCards.add(v.cardNativeToTarget.id)) {
        count++;
      }
    }
    return count;
  }

  int get dueCardsCount {
    int count = 0;
    final countedCards = <String>{};
    for (final v in vocabularies) {
      if (v.cardTargetToNative.isActive &&
          v.cardTargetToNative.isDue &&
          countedCards.add(v.cardTargetToNative.id)) {
        count++;
      }
      if (v.cardNativeToTarget.isActive &&
          v.cardNativeToTarget.isDue &&
          countedCards.add(v.cardNativeToTarget.id)) {
        count++;
      }
    }
    return count;
  }

  int get newCardsCount {
    int count = 0;
    final countedCards = <String>{};
    for (final v in vocabularies) {
      if (v.cardTargetToNative.isActive &&
          v.cardTargetToNative.status == SrsStatus.isNew &&
          countedCards.add(v.cardTargetToNative.id)) {
        count++;
      }
      if (v.cardNativeToTarget.isActive &&
          v.cardNativeToTarget.status == SrsStatus.isNew &&
          countedCards.add(v.cardNativeToTarget.id)) {
        count++;
      }
    }
    return count;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'unitTitle': unitTitle,
    'targetLanguage': targetLanguage,
    'nativeLanguage': nativeLanguage,
    'fileName': ?fileName,
    'fileFolder': ?fileFolder,
    'vocabularies': vocabularies.map((v) => v.toJson()).toList(),
  };

  factory Lesson.fromJson(Map<String, dynamic> json) => Lesson(
    id: json['id'] as String?,
    title: json['title'] as String? ?? 'Untitled Lesson',
    unitTitle: json['unitTitle'] as String?,
    targetLanguage: json['targetLanguage'] as String? ?? 'ko',
    nativeLanguage: json['nativeLanguage'] as String? ?? 'en',
    markdownContent: json['markdownContent'] as String? ?? '',
    fileName: json['fileName'] as String?,
    fileFolder: json['fileFolder'] as String?,
    vocabularies:
        (json['vocabularies'] as List<dynamic>?)
            ?.map(
              (v) => VocabItem.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList() ??
        [],
  );
}

const hierarchySeparator = '::';

/// [name] for loose comparison: Korean composed, lower case, and every run
/// of other characters than letters and digits made one space, so `unit-2`,
/// `Unit 2` and `unit_2` are the same, as folder import names folders.
String looseNameKey(String name) =>
    composeHangul(name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();

/// [value] as one file or folder name: characters that are not allowed in
/// one (`/`, `:`, `?`, …) become `_`, and trailing dots and spaces go.
String safePathSegment(String value) {
  final safe = value
      .replaceAll(RegExp(r'[\x00-\x1F<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  return safe.isEmpty || safe == '.' || safe == '..' ? 'Untitled' : safe;
}

/// The only place a stored/typed path string is split. Everything else passes
/// `List<String>` so segments containing `/` or spaces are never mangled.
List<String> splitHierarchyPath(String? path) =>
    path
        ?.split(hierarchySeparator)
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList() ??
    [];

String joinHierarchyPath(Iterable<String> path) =>
    path.join(hierarchySeparator);

String formatHierarchyPath(Iterable<String> path) => path.join(' › ');

String hierarchyFolderKey(Iterable<String> path) =>
    'folder:${path.map((part) => part.toLowerCase()).join(hierarchySeparator)}';

/// Whether [path] equals [ancestor] or is nested beneath it (case-insensitive).
bool isHierarchyPathWithin(List<String> path, List<String> ancestor) {
  if (ancestor.isEmpty || path.length < ancestor.length) return false;
  for (var index = 0; index < ancestor.length; index++) {
    if (path[index].toLowerCase() != ancestor[index].toLowerCase()) {
      return false;
    }
  }
  return true;
}

bool isSameHierarchyPath(List<String> a, List<String> b) =>
    a.length == b.length && (a.isEmpty || isHierarchyPathWithin(a, b));
