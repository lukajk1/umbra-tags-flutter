// Public, language-independent library format. See LIBRARY_FORMAT.md.
const libraryFormat = 'umbra-tags-library';
const libraryFormatVersion = 1;
const librarySchemaVersion = 1;

const createSchema = '''
CREATE TABLE library (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE assets (
  id TEXT PRIMARY KEY,
  relative_path TEXT NOT NULL UNIQUE,
  original_filename TEXT NOT NULL,
  media_type TEXT NOT NULL,
  width INTEGER NOT NULL CHECK(width > 0),
  height INTEGER NOT NULL CHECK(height > 0),
  byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
  imported_at INTEGER NOT NULL,
  source_modified_at INTEGER,
  sha256 TEXT NOT NULL UNIQUE CHECK(length(sha256) = 64),
  perceptual_hash TEXT,
  archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
  missing INTEGER NOT NULL DEFAULT 0 CHECK(missing IN (0, 1))
);
CREATE INDEX assets_imported ON assets(archived, imported_at DESC, id);
CREATE TABLE tag_groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
  color TEXT,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE tags (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
  parent_id TEXT REFERENCES tags(id) ON DELETE SET NULL,
  group_id TEXT REFERENCES tag_groups(id) ON DELETE SET NULL,
  pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)),
  position INTEGER NOT NULL DEFAULT 0,
  CHECK(parent_id IS NULL OR parent_id != id)
);
CREATE INDEX tags_parent ON tags(parent_id);
CREATE TABLE asset_tags (
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY(asset_id, tag_id)
);
CREATE INDEX asset_tags_tag ON asset_tags(tag_id, asset_id);
CREATE TABLE predictions (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  model_id TEXT NOT NULL,
  model_version TEXT NOT NULL,
  label TEXT NOT NULL,
  confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
  analyzed_sha256 TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(asset_id, model_id, model_version, label, analyzed_sha256)
);
CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  operation TEXT NOT NULL,
  asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed','interrupted')),
  progress REAL NOT NULL DEFAULT 0 CHECK(progress BETWEEN 0 AND 1),
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
PRAGMA user_version = 1;
''';
