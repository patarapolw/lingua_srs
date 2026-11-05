/**
 * Text built from random pieces of every awkward kind, so tests exercise
 * characters nobody thought to write down. It is seeded, so a failing case can
 * be replayed from its seed.
 */

/** A small seeded random number generator (mulberry32). */
export function seeded(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Ranges of code points, none of them surrogates. */
const RANGES: Array<[number, number]> = [
  [0x21, 0x7e], // printable ASCII, including + & = % # ? / \ : @ ; ' "
  [0x00, 0x1f], // controls, including NUL, tab and newline
  [0x7f, 0x9f], // DEL and the C1 controls
  [0x20, 0x20], // space
  [0xa0, 0xa0], // no-break space
  [0x2000, 0x200a], // wide and thin spaces
  [0x3000, 0x3000], // ideographic space
  [0xa1, 0x24f], // accented Latin
  [0x300, 0x36f], // combining marks
  [0x370, 0x52f], // Greek and Cyrillic
  [0x5d0, 0x5ea], // Hebrew
  [0x627, 0x64a], // Arabic
  [0x3040, 0x309f], // kana
  [0x4e00, 0x4f00], // CJK
  [0xac00, 0xac50], // Hangul
  [0x200b, 0x200f], // zero-width and direction marks
  [0x202a, 0x202e], // direction overrides
  [0xfeff, 0xfeff], // byte order mark
  [0xe000, 0xe0ff], // private use
  [0xfff9, 0xffff], // specials and noncharacters
  [0x1d400, 0x1d7ff], // mathematical alphanumerics
  [0x1f300, 0x1f64f], // emoji
  [0x1f900, 0x1f9ff], // more emoji
];

export function oddChar(random: () => number): string {
  const [low, high] = RANGES[Math.floor(random() * RANGES.length)];
  return String.fromCodePoint(low + Math.floor(random() * (high - low + 1)));
}

export function oddText(random: () => number, maxLength = 40): string {
  const length = 1 + Math.floor(random() * maxLength);
  let text = '';
  for (let i = 0; i < length; i++) text += oddChar(random);
  return text;
}

/** The code points of [text], for failure messages. */
export function hex(text: string): string {
  return [...text].map((char) => char.codePointAt(0)!.toString(16)).join(' ');
}
