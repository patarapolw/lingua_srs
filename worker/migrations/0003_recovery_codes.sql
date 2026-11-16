-- A recovery code lets the owner unlock the data key without the password.
-- The code itself never reaches the server: it stores a hash of the recovery
-- auth key derived from it, and the data key wrapped by the recovery wrap key
-- derived from it. NULL until the owner creates a code; a new code replaces
-- the old one, so only the newest code works.
ALTER TABLE accounts ADD COLUMN recovery_hash TEXT;
ALTER TABLE accounts ADD COLUMN recovery_wrapped_data_key TEXT;
ALTER TABLE accounts ADD COLUMN recovery_created_at INTEGER;
