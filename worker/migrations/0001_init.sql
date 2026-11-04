-- An account is identified by its email. Only a hash of the derived auth key
-- is stored, and the data key is stored wrapped by a key only the user has.
CREATE TABLE accounts (
  email TEXT PRIMARY KEY,
  auth_hash TEXT NOT NULL,
  wrapped_data_key TEXT NOT NULL,
  kdf TEXT NOT NULL,
  verified_at INTEGER,
  created_at INTEGER NOT NULL
);

-- Signups that were never confirmed are dropped, so they need to be found by age.
CREATE INDEX accounts_unconfirmed ON accounts (created_at) WHERE verified_at IS NULL;

-- At most one pending confirmation code per email.
CREATE TABLE email_codes (
  email TEXT PRIMARY KEY REFERENCES accounts (email),
  code_hash TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

-- Encrypted records. `seq` grows per account on every accepted change and is
-- the cursor devices pull with.
CREATE TABLE records (
  email TEXT NOT NULL REFERENCES accounts (email),
  kind TEXT NOT NULL,
  id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  data TEXT NOT NULL,
  PRIMARY KEY (email, kind, id)
) WITHOUT ROWID;

CREATE INDEX records_seq ON records (email, seq);

CREATE TABLE inbox (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL REFERENCES accounts (email),
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX inbox_email ON inbox (email, created_at);

-- Daily counters that keep the free plans from being used up: confirmation
-- emails sent ('emails') and records written per account ('w:<email>').
CREATE TABLE usage (
  scope TEXT NOT NULL,
  day TEXT NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (scope, day)
) WITHOUT ROWID;
