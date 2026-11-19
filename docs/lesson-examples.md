# Lesson Examples

Whole lesson files, each followed by what the app reads from it. The rules are in [lesson-format.md](lesson-format.md); examples of `## Vocabulary` sections, and how they move into the frontmatter, are in [vocabulary-section-examples.md](vocabulary-section-examples.md).

*The app reads* lists the lesson's title and languages, then one line per word: `[part of speech] word = meaning`, with the word's other fields under it and its example sentences as `example: sentence = translation`, the word marked in `**` as the cards blank it. The last line names the headings of the lesson text the reader shows. `test/docs_examples_test.dart` reads every example here and checks it reads as shown.

## A first lesson

The smallest useful lesson: frontmatter with one word and one example sentence, and a heading that gives the title.

```markdown
---
vocabulary:
  nouns:
    - ko: 학교
      en: school
      examples:
        - ko: 저는 **학교**에 가요.
          en: I go to **school**.
---

# Lesson 1: At school

Today's words are about school.
```

The app reads:

```text
title: Lesson 1: At school
language: ko → en
- [nouns] 학교 = school
    example: 저는 **학교**에 가요. = I go to **school**.
lesson text: # Lesson 1: At school
```

## Every field of a word

`tts` is said instead of the word when there is no recording; `audio` is a recording; `notes` can be one string or a list of paragraphs; `disambiguation` is shown on the card front. An example can have its own `audio`, `tts` and `notes`; the notes of an example are sentence notes, shown on the card back.

```markdown
---
vocabulary:
  numbers:
    - ko: 3개
      tts: 세 개
      en: three items
      disambiguation: counting things
      notes:
        - "Native Korean numbers count things: **세** before a counter."
        - "Sino-Korean **삼** is for dates and money."
      examples:
        - ko: 사과 **3개** 주세요.
          tts: 사과 세 개 주세요.
          en: Three apples, please.
          notes: "개 is the general counter."
  verbs:
    - ko: 가다
      en: to go
      audio: https://example.com/gada.mp3
      examples:
        - ko: 집에 **가요**.
          audio: https://example.com/jibe-gayo.mp3
          en: I'm going home.
---

# Lesson 2: Numbers and moving
```

The app reads:

```text
title: Lesson 2: Numbers and moving
language: ko → en
- [numbers] 3개 = three items
    tts: 세 개
    disambiguation: counting things
    notes: Native Korean numbers count things: **세** before a counter.

      Sino-Korean **삼** is for dates and money.
    example: 사과 **3개** 주세요. = Three apples, please.
      tts: 사과 세 개 주세요.
      notes: 개 is the general counter.
- [verbs] 가다 = to go
    audio: https://example.com/gada.mp3
    example: 집에 **가요**. = I'm going home.
      audio: https://example.com/jibe-gayo.mp3
lesson text: # Lesson 2: Numbers and moving
```

## The same word twice

Without an `id`, a word is its form and meaning together: `배` as *pear* and `배` as *boat* are two words with their own cards. An `id` makes entries one word, even under different parts of speech, so they share study progress.

```markdown
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      disambiguation: fruit
    - ko: 배
      en: boat
      disambiguation: vehicle
    - ko: 공부
      en: study
      id: gongbu
  verbs:
    - ko: 공부하다
      en: to study
      id: gongbu
---

# Lesson 3
```

The app reads:

```text
title: Lesson 3
language: ko → en
- [nouns] 배 = pear
    disambiguation: fruit
- [nouns] 배 = boat
    disambiguation: vehicle
- [nouns] 공부 = study
    id: gongbu
- [verbs] 공부하다 = to study
    id: gongbu
lesson text: # Lesson 3
```

## A Chinese lesson

`target:` names the language and region; entries are keyed by the language alone (`zh:`). `pinyin`, `simplified` and `traditional` are shown on the answer side.

```markdown
---
target: zh-CN
vocabulary:
  nouns:
    - zh: 学生
      pinyin: xuésheng
      traditional: 學生
      en: student
      examples:
        - zh: 我是**学生**。
          en: I am a student.
  verbs:
    - zh: 学习
      pinyin: xuéxí
      traditional: 學習
      en: to study
---

# 第一课：学生
```

The app reads:

```text
title: 第一课：学生
language: zh-CN → en
- [nouns] 学生 = student
    reading: xuésheng
    traditional: 學生
    example: 我是**学生**。 = I am a student.
- [verbs] 学习 = to study
    reading: xuéxí
    traditional: 學習
lesson text: # 第一课：学生
```

## A Traditional Chinese lesson

`zh-TW` keeps its region, so the words are spoken by a Taiwanese voice. The card shows the form that differs from the word: here the Simplified one.

```markdown
---
target: zh-TW
vocabulary:
  nouns:
    - zh: 學生
      pinyin: xuéshēng
      simplified: 学生
      en: student
---

# 第一課
```

The app reads:

```text
title: 第一課
language: zh-TW → en
- [nouns] 學生 = student
    reading: xuéshēng
    simplified: 学生
lesson text: # 第一課
```

## Korean with Hanja, Japanese with a reading

`hanja` is the Hanja of a Sino-Korean word. In a Japanese lesson, `reading` is the kana of a word written in kanji.

```markdown
---
vocabulary:
  nouns:
    - ko: 학생
      hanja: 學生
      en: student
    - ko: 사람
      en: person
---

# 학생
```

The app reads:

```text
title: 학생
language: ko → en
- [nouns] 학생 = student
    hanja: 學生
- [nouns] 사람 = person
lesson text: # 학생
```

```markdown
---
target: ja
vocabulary:
  nouns:
    - ja: 学生
      reading: がくせい
      en: student
---

# 学生
```

The app reads:

```text
title: 学生
language: ja → en
- [nouns] 学生 = student
    reading: がくせい
lesson text: # 学生
```

## Groups inside a part of speech

A part of speech can hold named groups; the word's section is the whole path.

```markdown
---
vocabulary:
  verbs:
    regular:
      - ko: 먹다
        en: to eat
    irregular:
      - ko: 듣다
        en: to listen
---

# Verbs
```

The app reads:

```text
title: Verbs
language: ko → en
- [verbs › regular] 먹다 = to eat
- [verbs › irregular] 듣다 = to listen
lesson text: # Verbs
```

## Plain YAML

A lesson can be YAML without Markdown. `lesson:` gives its title and `unit:` its folder; it has no lesson text.

```markdown
lesson: Greetings
unit: Unit 1
vocabulary:
  expressions:
    - ko: 안녕하세요
      en: hello
```

The app reads:

```text
title: Greetings
unit: Unit 1
language: ko → en
- [expressions] 안녕하세요 = hello
lesson text: (none)
```

## A Vocabulary section next to the frontmatter

With frontmatter, the words come from the frontmatter, even when the file also lists them in a `## Vocabulary` section, and the section is left out of the lesson text, up to the next `## ` heading or a `<!-- /Vocabulary -->` line. The import screen offers to move words the frontmatter lacks into it ([examples](vocabulary-section-examples.md)).

```markdown
---
vocabulary:
  nouns:
    - ko: 학교
      en: school
---

# Lesson 4

Intro.

## Vocabulary

- 학교 — school
<!-- /Vocabulary -->

Footer text.

## Practice

Read the dialogue aloud.
```

The app reads:

```text
title: Lesson 4
language: ko → en
- [nouns] 학교 = school
lesson text: # Lesson 4 · ## Practice
```

## A lesson without frontmatter

With no frontmatter, the `## Vocabulary` section is where the words come from, and its language is guessed from its script. Text in it that is not about one word is kept under `## Vocabulary notes`. Without the section, the file would not be a lesson at all.

```markdown
# Lesson 5: Family

## Vocabulary

Family words.

### Nouns
- 엄마 — mom
  - 우리 엄마는 의사예요. — My mom is a doctor.
- 아빠 — dad
```

The app reads:

```text
title: Lesson 5: Family
language: ko → en
words read from: ## Vocabulary
- [nouns] 엄마 = mom
    example: 우리 **엄마**는 의사예요. = My mom is a doctor.
- [nouns] 아빠 = dad
lesson text: # Lesson 5: Family · ## Vocabulary notes
```
