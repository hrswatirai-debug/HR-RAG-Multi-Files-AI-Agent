-- ============================================================
-- HR RAG v2 — PostgreSQL Schema (Production)
-- ============================================================
-- Run this BEFORE importing the 4 workflows.
-- Safe to run on top of v1 schema: uses IF NOT EXISTS + ALTER TABLE.
-- ============================================================

-- ------------------------------------------------------------
-- 1. DOCUMENTS registry (file-level tracking, now with file_hash)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS documents (
    file_id         TEXT PRIMARY KEY,
    file_name       TEXT NOT NULL,
    document_type   TEXT,
    modified_time   TIMESTAMPTZ,
    upload_date     TIMESTAMPTZ DEFAULT NOW(),
    status          TEXT DEFAULT 'pending',  -- pending|processing|indexed|skipped|failed
    chunk_count     INTEGER DEFAULT 0,
    error_message   TEXT,
    file_hash       TEXT,                    -- SHA-256 of file content for dedup
    last_indexed_at TIMESTAMPTZ
);

-- Safe-add columns if upgrading from v1
ALTER TABLE documents ADD COLUMN IF NOT EXISTS file_hash TEXT;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS last_indexed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(status);
CREATE INDEX IF NOT EXISTS idx_documents_type   ON documents(document_type);
CREATE INDEX IF NOT EXISTS idx_documents_hash   ON documents(file_hash);

-- ------------------------------------------------------------
-- 2. QUERY LOG (every question answered, for analytics)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS query_log (
    id              SERIAL PRIMARY KEY,
    query_text      TEXT NOT NULL,
    query_hash      TEXT,
    response        TEXT,
    confidence      TEXT,
    answer_found    BOOLEAN,
    sources_cited   TEXT[],
    latency_ms      INTEGER,
    cache_hit       BOOLEAN DEFAULT FALSE,
    chunks_retrieved INTEGER,
    doc_types_searched TEXT[],
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE query_log ADD COLUMN IF NOT EXISTS query_hash TEXT;
ALTER TABLE query_log ADD COLUMN IF NOT EXISTS cache_hit BOOLEAN DEFAULT FALSE;
ALTER TABLE query_log ADD COLUMN IF NOT EXISTS chunks_retrieved INTEGER;
ALTER TABLE query_log ADD COLUMN IF NOT EXISTS doc_types_searched TEXT[];

CREATE INDEX IF NOT EXISTS idx_query_log_created ON query_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_query_log_hash    ON query_log(query_hash);

-- ------------------------------------------------------------
-- 3. QUERY CACHE (Postgres-backed cache for repeated questions)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS query_cache (
    query_hash      TEXT PRIMARY KEY,
    query_text      TEXT NOT NULL,
    response_json   JSONB NOT NULL,
    hit_count       INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    expires_at      TIMESTAMPTZ,
    last_hit_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_cache_expires ON query_cache(expires_at);

-- ------------------------------------------------------------
-- 4. ERROR LOG (unchanged from v1, just ensuring it exists)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS error_log (
    id              SERIAL PRIMARY KEY,
    workflow_name   TEXT,
    node_name       TEXT,
    error_message   TEXT,
    error_category  TEXT,               -- rate_limit|auth|timeout|parse|other
    file_id         TEXT,
    retry_count     INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE error_log ADD COLUMN IF NOT EXISTS error_category TEXT;
ALTER TABLE error_log ADD COLUMN IF NOT EXISTS retry_count INTEGER DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_error_log_created ON error_log(created_at DESC);

-- ------------------------------------------------------------
-- 5. ANALYTICS DAILY (written by WF-4 every 3 AM)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics_daily (
    report_date         DATE PRIMARY KEY,
    total_queries       INTEGER,
    cache_hit_rate      NUMERIC(5,2),
    not_found_rate      NUMERIC(5,2),
    low_confidence_rate NUMERIC(5,2),
    avg_latency_ms      INTEGER,
    p95_latency_ms      INTEGER,
    top_queries         JSONB,
    top_not_found       JSONB,
    indexed_docs        INTEGER,
    skipped_docs        INTEGER,
    failed_docs         INTEGER,
    stale_docs          INTEGER,
    errors_24h          INTEGER,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 6. CACHE CLEANUP (optional housekeeping)
-- ------------------------------------------------------------
-- Run manually or via a cron job to evict expired cache entries:
-- DELETE FROM query_cache WHERE expires_at < NOW();

SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;

SELECT 
    'documents' AS table_name, COUNT(*) AS rows FROM documents
UNION ALL SELECT 'query_log',       COUNT(*) FROM query_log
UNION ALL SELECT 'query_cache',     COUNT(*) FROM query_cache
UNION ALL SELECT 'error_log',       COUNT(*) FROM error_log
UNION ALL SELECT 'analytics_daily', COUNT(*) FROM analytics_daily;

SELECT * FROM error_log ORDER BY id DESC LIMIT 1;

SELECT 
    file_id, 
    status, 
    chunk_count, 
    last_indexed_at 
FROM documents 
WHERE status = 'indexed' 
ORDER BY last_indexed_at DESC 
LIMIT 5;

SELECT file_id, file_name, document_type, status, chunk_count, last_indexed_at 
   FROM documents 
   ORDER BY last_indexed_at DESC NULLS LAST;

   SELECT 
    file_id,
    file_name,
    document_type,
    status,
    chunk_count,
    file_hash,
    last_indexed_at,
    upload_date
FROM documents
ORDER BY upload_date DESC NULLS LAST;

SELECT 
    column_name, 
    data_type, 
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema = 'public' 
  AND table_name = 'query_cache'
ORDER BY ordinal_position;

SELECT status, COUNT(*) AS count
FROM documents
GROUP BY status;

SELECT * FROM ingestion_metrics
ORDER BY created_at DESC LIMIT 10;

SELECT 
    workflow_name,
    node_name,
    error_message,
    error_category,
    created_at
FROM error_log
ORDER BY created_at DESC
LIMIT 10;

SELECT 
    file_name, 
    document_type, 
    status, 
    chunk_count, 
    last_indexed_at
FROM documents
ORDER BY last_indexed_at DESC NULLS LAST;

DELETE FROM documents;
DELETE FROM error_log WHERE workflow_name = 'Example Workflow';

DELETE FROM documents ;

SELECT 
    file_name,
    document_type,
    status,
    chunk_count,
    file_hash IS NOT NULL AS has_hash,
    last_indexed_at
FROM documents
ORDER BY last_indexed_at DESC NULLS LAST;

-- Remove the orphaned 'processing' row
DELETE FROM documents WHERE file_name = 'Kuwait_Labour_Law_English.pdf';

-- Verify
SELECT file_name, status, chunk_count FROM documents;

SELECT 
    query_text, 
    confidence, 
    sources_cited, 
    cache_hit, 
    latency_ms,
    created_at
FROM query_log
ORDER BY created_at DESC
LIMIT 10;

SELECT query_text, expires_at, hit_count
FROM query_cache
ORDER BY last_hit_at DESC;

INSERT INTO query_cache (query_hash, query_text, response_json, expires_at, last_hit_at, hit_count)
VALUES (
    'test_hash_123',
    'test query',
    '{"answer": "test"}'::jsonb,
    NOW() + INTERVAL '1 hour',
    NOW(),
    0
);

SELECT * FROM query_cache;

SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;

SELECT 
    file_name,
    document_type,
    status,
    chunk_count,
    last_indexed_at IS NOT NULL AS is_indexed,
    file_hash IS NOT NULL AS has_hash
FROM documents
ORDER BY file_name;

INSERT INTO query_cache (query_hash, query_text, response_json, expires_at, last_hit_at, hit_count)
VALUES (
    'test_hash_123',
    'test query',
    '{"answer": "test"}'::jsonb,
    NOW() + INTERVAL '1 hour',
    NOW(),
    0
);

SELECT * FROM query_cache;

SELECT 
    workflow_name,
    node_name,
    error_message,
    error_category,
    created_at
FROM error_log
WHERE workflow_name != 'Example Workflow'  -- exclude test data
ORDER BY created_at DESC
LIMIT 10;

-- Verify cleanup
SELECT 'error_log' AS table_name, COUNT(*) AS rows FROM error_log
UNION ALL
SELECT 'query_log', COUNT(*) FROM query_log;


SELECT 
    confidence,
    COUNT(*) AS query_count,

SELECT SUM(chunk_count) AS total_chunks_in_postgres FROM documents;
    AVG(latency_ms)::INT AS avg_latency_ms,
    SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END) AS cache_hits,
    SUM(CASE WHEN answer_found THEN 1 ELSE 0 END) AS answers_found
FROM query_log
GROUP BY confidence
ORDER BY query_count DESC;

SELECT COUNT(*) AS chunk_rows FROM chunks;

SELECT * FROM analytics_daily ORDER BY date DESC LIMIT 7;