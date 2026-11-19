# Vocabulary Section Examples

Lesson files with a `## Vocabulary` section, each followed by the frontmatter that **Move words to frontmatter** gives it, and what the app then reads. The rules are in [lesson-format.md](lesson-format.md#vocabulary-sections); whole lessons in frontmatter form are in [lesson-examples.md](lesson-examples.md).

*The app reads* lists the lesson's title and languages, then one line per word: `[part of speech] word = meaning`, with its other fields under it and its example sentences as `example: sentence = translation`, the word marked in `**`. The last line names the headings of the lesson text the reader shows. For a file without frontmatter, the app reads the same words before the move, from the section. The lesson text can differ: a file that is only a title and the section has no lesson text before the move, and shows the title after it. `test/docs_examples_test.dart` checks every example here.

## Separators

A top-level list item is a word: the word, a separator, the meaning. The separator can be `—` or `–` (with or without spaces), ` - ` or ` = ` (with spaces), `: `, a full-width `：` or a tab. `**` and backticks around the word are dropped. This file has no frontmatter, so it gets one, with the language guessed from the Hangul.

```markdown
# Separators

## Vocabulary

- 학교 — school
- 선생님 – teacher
+ 가다 - to go
1. 책 = book
* **친구**: friend
- `물`：water
```

Moved, the frontmatter is:

```yaml
target: ko
vocabulary:
  words:
    - ko: 학교
      en: school
    - ko: 선생님
      en: teacher
    - ko: 가다
      en: to go
    - ko: 책
      en: book
    - ko: 친구
      en: friend
    - ko: 물
      en: water
```

The app reads:

```text
title: Separators
language: ko → en
- [words] 학교 = school
- [words] 선생님 = teacher
- [words] 가다 = to go
- [words] 책 = book
- [words] 친구 = friend
- [words] 물 = water
lesson text: # Separators
```

## Parts of speech

A `###` heading names the part of speech of the words under it, in lowercase, joined with `_`: `### Set phrases` is `set_phrases`. Words before any heading are `words`.

```markdown
---
vocabulary:
---

# Parts of speech

## Vocabulary

- 네 — yes

### Nouns
- 물 — water

### Set phrases
- 잘 먹겠습니다 — thanks for the meal
```

Moved, the frontmatter is:

```yaml
vocabulary:
  words:
    - ko: 네
      en: yes
  nouns:
    - ko: 물
      en: water
  set_phrases:
    - ko: 잘 먹겠습니다
      en: thanks for the meal
```

The app reads:

```text
title: Parts of speech
language: ko → en
- [words] 네 = yes
- [nouns] 물 = water
- [set_phrases] 잘 먹겠습니다 = thanks for the meal
lesson text: # Parts of speech
```

## Chinese: pinyin and the other script

Bracketed groups after the word, `(…)`, `（…）`, `[…]` or `【…】`, say more about it. In a Chinese lesson, Latin text with tone marks or tone numbers is the pinyin, and Han characters are the other script: Traditional in a Simplified lesson. A label (`繁:`, `简:`, `拼音:`) picks the field; any other group, like `(formal)`, is a note. A separator inside brackets does not count.

```markdown
---
target: zh-CN
vocabulary:
---

# 第二课

## Vocabulary

- 学生 (xuésheng) [學生] — student
- 老师（lǎoshī）（繁：老師）（formal）：teacher
- 学习 【xue2xi2】 — to study
```

Moved, the frontmatter is:

```yaml
target: zh-CN
vocabulary:
  words:
    - zh: 学生
      pinyin: xuésheng
      traditional: 學生
      en: student
    - zh: 老师
      pinyin: lǎoshī
      traditional: 老師
      en: teacher
      notes: formal
    - zh: 学习
      pinyin: xue2xi2
      en: to study
```

The app reads:

```text
title: 第二课
language: zh-CN → en
- [words] 学生 = student
    reading: xuésheng
    traditional: 學生
- [words] 老师 = teacher
    reading: lǎoshī
    traditional: 老師
    notes: formal
- [words] 学习 = to study
    reading: xue2xi2
lesson text: # 第二课
```

## Traditional Chinese

In a lesson whose `target:` is `zh-TW`, `zh-HK`, `zh-MO` or `zh-Hant`, Han characters in brackets are the Simplified form.

```markdown
---
target: zh-TW
vocabulary:
---

# 第二課

## Vocabulary

- 學生 (xuéshēng) (学生) — student
```

Moved, the frontmatter is:

```yaml
target: zh-TW
vocabulary:
  words:
    - zh: 學生
      pinyin: xuéshēng
      simplified: 学生
      en: student
```

The app reads:

```text
title: 第二課
language: zh-TW → en
- [words] 學生 = student
    reading: xuéshēng
    simplified: 学生
lesson text: # 第二課
```

## Korean Hanja, Japanese readings

In a Korean lesson, Han characters in brackets are the Hanja, even mixed with Hangul. In a Japanese lesson, kana in brackets is the reading.

```markdown
---
vocabulary:
---

# Hanja

## Vocabulary

- 학생 (學生) — student
- 선생님 (先生님) — teacher
```

Moved, the frontmatter is:

```yaml
vocabulary:
  words:
    - ko: 학생
      hanja: 學生
      en: student
    - ko: 선생님
      hanja: 先生님
      en: teacher
```

The app reads:

```text
title: Hanja
language: ko → en
- [words] 학생 = student
    hanja: 學生
- [words] 선생님 = teacher
    hanja: 先生님
lesson text: # Hanja
```

```markdown
---
target: ja
vocabulary:
---

# 読み

## Vocabulary

- 学生（がくせい）— student
- 先生（せんせい）— teacher
```

Moved, the frontmatter is:

```yaml
target: ja
vocabulary:
  words:
    - ja: 学生
      reading: がくせい
      en: student
    - ja: 先生
      reading: せんせい
      en: teacher
```

The app reads:

```text
title: 読み
language: ja → en
- [words] 学生 = student
    reading: がくせい
- [words] 先生 = teacher
    reading: せんせい
lesson text: # 読み
```

## Notes, examples and sentence notes

Lines indented under a word belong to it:

- `Note:`, `Usage:`, `注:`, `备注:` or `참고:` starts a note of the word.
- `Example:`, `e.g.`, `例句:` or `예문:` starts an example; so does a line with `**`, or a line with the word and a translation after a separator.
- An example's translation is after a separator, or Latin text in brackets at the end of a sentence that is not Latin, or the first item indented under the example.
- A `Note:` item indented under an example is a **sentence note**: shown on the card back, editable from the Sentence Pool.
- Any other indented line is a note of the word.

```markdown
---
target: zh-CN
vocabulary:
---

# 第三课

## Vocabulary

- 学生 (xuésheng) — student
  - 注：Also used for pupils.
  - 我是学生。 — I am a student.
    - Note: 是 links two nouns.
  - 他是**学生**吗？(Is he a student?)
  - 例句：我们都是学生。
    - We are all students.
    - Note: 都 comes before the verb.
  - Often seen on signs.
```

Moved, the frontmatter is:

```yaml
target: zh-CN
vocabulary:
  words:
    - zh: 学生
      pinyin: xuésheng
      en: student
      notes:
        - Also used for pupils.
        - Often seen on signs.
      examples:
        - zh: 我是**学生**。
          en: I am a student.
          notes: 是 links two nouns.
        - zh: 他是**学生**吗？
          en: Is he a student?
        - zh: 我们都是**学生**。
          en: We are all students.
          notes: 都 comes before the verb.
```

The app reads:

```text
title: 第三课
language: zh-CN → en
- [words] 学生 = student
    reading: xuésheng
    notes: Also used for pupils.

      Often seen on signs.
    example: 我是**学生**。 = I am a student.
      notes: 是 links two nouns.
    example: 他是**学生**吗？ = Is he a student?
    example: 我们都是**学生**。 = We are all students.
      notes: 都 comes before the verb.
lesson text: # 第三课
```

## Marking the word in an example

An example without `**` gets the word marked where it first appears, or its other form, or, in a Korean lesson, the stem of a `-다` word (`먹다` in `먹어요`) or the part before `하다` (`공부하다` in `공부해요`). A labelled example in which the word cannot be found is kept as a note starting `Example:`; an unlabelled one is an ordinary note.

```markdown
---
vocabulary:
---

# Verbs

## Vocabulary

### Verbs
- 먹다 — to eat
  - 밥을 먹어요. — I eat rice.
- 공부하다 — to study
  - 매일 공부해요. — I study every day.
  - Example: 도서관에 가요. — I go to the library.
```

Moved, the frontmatter is:

```yaml
vocabulary:
  verbs:
    - ko: 먹다
      en: to eat
      examples:
        - ko: 밥을 **먹**어요.
          en: I eat rice.
    - ko: 공부하다
      en: to study
      notes: "Example: 도서관에 가요. — I go to the library."
      examples:
        - ko: 매일 **공부**해요.
          en: I study every day.
```

The app reads:

```text
title: Verbs
language: ko → en
- [verbs] 먹다 = to eat
    example: 밥을 **먹**어요. = I eat rice.
- [verbs] 공부하다 = to study
    notes: Example: 도서관에 가요. — I go to the library.
    example: 매일 **공부**해요. = I study every day.
lesson text: # Verbs
```

## Tables with a header row

A table with a header row is read by its column names: the word, `pinyin`/`拼音`/`reading`, `traditional`/`繁`, `simplified`/`简`, `hanja`, the meaning, an example, the example's translation, `notes`, and the part of speech. A column it does not know becomes notes headed by its name. An empty cell, or `-`, is left out.

```markdown
---
target: zh-CN
vocabulary:
---

# 表格

## Vocabulary

| 汉字 | 拼音 | 繁體 | English | 词性 | 例句 | Example translation | Level |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 学生 | xuésheng | 學生 | student | nouns | 我是学生。 | I am a student. | HSK 1 |
| 学习 | xuéxí | 學習 | to study | verbs | - | | HSK 1 |
```

Moved, the frontmatter is:

```yaml
target: zh-CN
vocabulary:
  nouns:
    - zh: 学生
      pinyin: xuésheng
      traditional: 學生
      en: student
      notes: "Level: HSK 1"
      examples:
        - zh: 我是**学生**。
          en: I am a student.
  verbs:
    - zh: 学习
      pinyin: xuéxí
      traditional: 學習
      en: to study
      notes: "Level: HSK 1"
```

The app reads:

```text
title: 表格
language: zh-CN → en
- [nouns] 学生 = student
    reading: xuésheng
    traditional: 學生
    notes: Level: HSK 1
    example: 我是**学生**。 = I am a student.
- [verbs] 学习 = to study
    reading: xuéxí
    traditional: 學習
    notes: Level: HSK 1
lesson text: # 表格
```

## A table without a header row

Without a `|---|` line under its first row, a table is read as the word and its meaning, row by row.

```markdown
---
vocabulary:
---

# Table

## Vocabulary

| 학교 | school |
| **가다** | to go |
```

Moved, the frontmatter is:

```yaml
vocabulary:
  words:
    - ko: 학교
      en: school
    - ko: 가다
      en: to go
```

The app reads:

```text
title: Table
language: ko → en
- [words] 학교 = school
- [words] 가다 = to go
lesson text: # Table
```

## Text that is not about one word

An introduction, text under a `###` heading, and a list item that cannot be read as a word (here one without a meaning) cannot go into the frontmatter. They are kept in the lesson text under `## Vocabulary notes`, in place of the section, with the `###` headings they were under.

```markdown
---
vocabulary:
---

# Lesson 6

## Vocabulary

These words are about school.

### Verbs

Verbs end in 다.

- 가다 — to go
- 오다

## Practice

Practice text.
```

Moved, the frontmatter is:

```yaml
vocabulary:
  verbs:
    - ko: 가다
      en: to go
```

The app reads:

```text
title: Lesson 6
language: ko → en
- [verbs] 가다 = to go
lesson text: # Lesson 6 · ## Vocabulary notes · ### Verbs · ## Practice
```

## Words the frontmatter already has

Words the frontmatter has (the same word, ignoring case and spacing) are skipped, and new ones are added after the entries already in their part of speech. The rest of the frontmatter, comments included, stays as written.

```markdown
---
title: Lesson 7   # shown by VitePress
vocabulary:
  nouns:
    - ko: 학교
      en: school
---

# Lesson 7

## Vocabulary

### Nouns
- 학교 — school
- 교실 — classroom

### Verbs
- 배우다 — to learn
```

Moved, the frontmatter is:

```yaml
title: Lesson 7   # shown by VitePress
vocabulary:
  nouns:
    - ko: 학교
      en: school
    - ko: 교실
      en: classroom
  verbs:
    - ko: 배우다
      en: to learn
```

The app reads:

```text
title: Lesson 7
language: ko → en
- [nouns] 학교 = school
- [nouns] 교실 = classroom
- [verbs] 배우다 = to learn
lesson text: # Lesson 7
```

## A Chinese lesson without frontmatter

With no frontmatter, the language is guessed from the section: Chinese, as it has Han characters and no Hangul or kana. Moving the words writes that as `target: zh`; change it to `zh-CN` or `zh-TW` to pick the voice. Before the move, the app reads the same words from the section.

```markdown
# 第四课：家

## Vocabulary

- 妈妈 (māma) — mom
  - 我妈妈是医生。 — My mom is a doctor.
- 爸爸 (bàba) — dad
```

Moved, the frontmatter is:

```yaml
target: zh
vocabulary:
  words:
    - zh: 妈妈
      pinyin: māma
      en: mom
      examples:
        - zh: 我**妈妈**是医生。
          en: My mom is a doctor.
    - zh: 爸爸
      pinyin: bàba
      en: dad
```

The app reads:

```text
title: 第四课：家
language: zh → en
- [words] 妈妈 = mom
    reading: māma
    example: 我**妈妈**是医生。 = My mom is a doctor.
- [words] 爸爸 = dad
    reading: bàba
lesson text: # 第四课：家
```
