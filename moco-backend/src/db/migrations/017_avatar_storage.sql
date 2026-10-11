-- Tracks the Supabase Storage path for user avatars so old objects can be
-- cleaned up when the avatar changes. avatar_url continues to hold the signed
-- view URL that clients display.
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_storage_path TEXT;
