CREATE TABLE pairing_invites (
  token_hash TEXT PRIMARY KEY,
  email TEXT NOT NULL REFERENCES accounts (email),
  payload TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX pairing_invites_email ON pairing_invites (email);
CREATE INDEX pairing_invites_expiry ON pairing_invites (expires_at);
