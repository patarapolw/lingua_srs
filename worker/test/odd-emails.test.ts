import { describe, expect, it } from 'vitest';
import { AUTH_KEY, accountBody, basic, clearDatabase, createConfirmedAccount, createWorld } from './helpers';
import { hex, oddText, seeded } from './odd-text';

clearDatabase();

/**
 * An email made of random awkward characters, without the few the format rules
 * out. It is put in NFKC first, because that turns some characters into
 * spaces (for example the Greek tonos), which are then ruled out too.
 */
function oddEmail(random: () => number): string {
  const local = oddText(random).normalize('NFKC').replace(/[\s@:]/g, 'x');
  const label = oddText(random, 8).normalize('NFKC').replace(/[\s@:.]/g, 'x');
  return `${local}@${label}.example`;
}

describe('emails made of random characters', () => {
  it('can be used to sign in, exactly as the app sends them', async () => {
    for (let seed = 0; seed < 40; seed++) {
      const email = oddEmail(seeded(seed));
      const reason = `seed ${seed}, code points ${hex(email)}`;
      const world = createWorld();

      let auth: string;
      try {
        auth = await createConfirmedAccount(world, email, AUTH_KEY);
      } catch (error) {
        throw new Error(`${reason}: ${error}`);
      }

      const result = await world.call('GET', '/v1/account', { auth });
      expect(result.status, reason).toBe(200);
      await world.call('DELETE', '/v1/account', { auth });
    }
  });

  it('are found again when padded with spaces or typed with other ASCII capitals', async () => {
    for (let seed = 100; seed < 130; seed++) {
      const email = oddEmail(seeded(seed));
      const reason = `seed ${seed}, code points ${hex(email)}`;
      const world = createWorld();
      const auth = await createConfirmedAccount(world, email, AUTH_KEY);

      // Only ASCII letters change case both ways; for others, upper and lower
      // case are different emails (for example the Greek beta symbol).
      const capitals = email.replace(/[a-z]/g, (letter) => letter.toUpperCase());
      for (const variant of [` ${email}\t`, email.toLowerCase(), capitals]) {
        const result = await world.call('GET', '/v1/account', { auth: basic(variant, AUTH_KEY) });
        expect(result.status, `${reason}, variant ${hex(variant)}`).toBe(200);
      }
      await world.call('DELETE', '/v1/account', { auth });
    }
  });

  it('are refused when they contain half of a surrogate pair, which could not be kept', async () => {
    const world = createWorld();
    for (const email of ['a\ud800b@example.com', 'a\udc00b@example.com', 'a\udc00\ud800b@example.com']) {
      const result = await world.call('POST', '/v1/accounts', { body: accountBody(email) });
      expect(result.status, hex(email)).toBe(400);
    }
    // A complete pair (an emoji) is fine.
    const pair = await world.call('POST', '/v1/accounts', { body: accountBody('a\ud83d\ude00b@example.com') });
    expect(pair.status).toBe(202);
    expect(world.mails).toHaveLength(1);
    expect(world.mails[0].to).toBe('a\u{1f600}b@example.com');
  });

  it('are the same account in equivalent spellings', async () => {
    const world = createWorld();
    // An accent as one character, or as a letter and a combining mark; and
    // full-width letters.
    const auth = await createConfirmedAccount(world, 'caf\u00e9@example.com', AUTH_KEY);

    for (const spelling of ['cafe\u0301@example.com', 'CAFE\u0301@Example.com', '\uff43\uff41\uff46\u00e9@example.com']) {
      const result = await world.call('GET', '/v1/account', { auth: basic(spelling, AUTH_KEY) });
      expect(result.status, hex(spelling)).toBe(200);
    }
    // Signing up again with another spelling does not make a second account.
    world.mails.length = 0;
    expect((await world.call('POST', '/v1/accounts', { body: accountBody('cafe\u0301@example.com') })).status).toBe(202);
    expect(world.mails).toHaveLength(0);
    expect(auth).toBeTruthy();
  });

  it('keep accounts apart when they differ by a single character', async () => {
    for (let seed = 200; seed < 220; seed++) {
      const email = oddEmail(seeded(seed));
      const other = email.replace('@', 'y@');
      const world = createWorld();
      const auth = await createConfirmedAccount(world, email, AUTH_KEY);

      const result = await world.call('GET', '/v1/account', { auth: basic(other, AUTH_KEY) });
      expect(result.status, `seed ${seed}`).toBe(401);
      await world.call('DELETE', '/v1/account', { auth });
    }
  });
});
