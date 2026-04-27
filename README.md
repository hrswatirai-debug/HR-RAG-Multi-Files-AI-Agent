# 🧠 HR RAG Multi-Agent AI — Enterprise Document Intelligence System

> **Production-grade Retrieval-Augmented Generation (RAG) system** built entirely on n8n, Pinecone, OpenAI, and PostgreSQL. Designed for enterprises that need secure, auditable, AI-powered answers from internal HR documents — without exposing data to consumer-grade tools.

---

[![n8n](https://img.shields.io/badge/Built%20with-n8n-EA4B71?style=flat-square&logo=n8n)](https://n8n.io)
[![Pinecone](https://img.shields.io/badge/Vector%20DB-Pinecone-00C7B7?style=flat-square)](https://www.pinecone.io)
[![OpenAI](https://img.shields.io/badge/LLM-OpenAI-412991?style=flat-square&logo=openai)](https://openai.com)
[![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL%2018-4169E1?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

---

## 📌 What This Project Does

Employees and HR teams ask natural-language questions like:

> *"What is the parental leave policy?"*
> *"What are the criteria for designing wage structures for blue-collar workers?"*

The system retrieves answers **exclusively from your organization's own HR documents**, cites the source, assigns a confidence level, suggests follow-up questions, and logs every interaction for analytics — all in under ~10 seconds.

It is not a wrapper around a chatbot. It is a **multi-agent orchestration pipeline** with deduplication, caching, reranking, structured logging, and scheduled analytics — production patterns that are rarely seen together in open-source RAG demos.

---

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        HR RAG Multi-Agent AI                        │
│                                                                     │
│  ┌──────────────┐    ┌─────────────────────────────────────────┐   │
│  │  Google Drive │───▶│  WF-1: Ingestion Agent                  │   │
│  │  (HR Docs)   │    │  Hash Dedup → Embed → Pinecone Upsert   │   │
│  └──────────────┘    └───────────────┬─────────────────────────┘   │
│                                      │                              │
│                               ┌──────▼──────┐                      │
│                               │  Pinecone   │                      │
│                               │ Vector Store│                      │
│                               └──────┬──────┘                      │
│                                      │                              │
│  ┌──────────────┐    ┌───────────────▼─────────────────────────┐   │
│  │  REST Client │───▶│  WF-2: Query Agent                      │   │
│  │  (Webhook)   │    │  Cache → Retrieve → Rerank → Answer     │   │
│  └──────────────┘    └───────────────┬─────────────────────────┘   │
│                                      │                              │
│                          ┌───────────▼────────────┐                │
│                          │    PostgreSQL 18        │                │
│                          │  documents | query_log  │                │
│                          │  query_cache | error_log│                │
│                          │  analytics_daily        │                │
│                          └───────────┬────────────┘                │
│                                      │                              │
│  ┌───────────────────────────────────▼─────────────────────────┐   │
│  │  WF-3: Error Handler    │    WF-4: Analytics (2AM Cron)     │   │
│  │  Classify → Log         │    Aggregate → Daily Report       │   │
│  └─────────────────────────┴─────────────────────────────────── ┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 🔄 Workflow Breakdown

The system is composed of **four purpose-built n8n workflows**, all contained in a single importable JSON file.

---

### WF-1 — Document Ingestion Agent

**File:** `Ingestion_wf.png` | **Trigger:** Manual + Schedule (Daily 2AM)

This workflow handles the full document lifecycle — from Google Drive to Pinecone vectors — with production-grade deduplication.

**Node flow:**

```
Set Config → List Files (Google Drive) → Split In Batches
    └── If Valid File Type
            ├── [Invalid] → Log Skipped File
            └── [Valid]   → Download File
                            → Extract Metadata + Hash (SHA-256)
                            → Check Existing Hash (PostgreSQL)
                            → Evaluate Dedup
                            → IF Needs Processing
                                ├── [Skip] → Mark Unchanged
                                └── [Process] → Register Processing (Postgres)
                                                → Restore Binary
                                                → Default Data Loader
                                                → Text Splitter
                                                → Embeddings OpenAI
                                                → Pinecone Upsert
                                                → Mark Indexed (Postgres)
```

**Key design decisions:**

- **SHA-256 content hashing** — Files are only re-ingested when their content actually changes, not just when the filename or modified date changes. This prevents redundant API calls and Pinecone writes.
- **Batch processing** — Documents are processed in configurable batch sizes to respect API rate limits and prevent memory spikes.
- **Dual trigger** — Supports both manual execution (for immediate re-indexing) and a scheduled 2AM cron for fully autonomous operation.
- **PostgreSQL as the document registry** — Every file has a status lifecycle: `pending → processing → indexed | skipped | failed`. This gives full observability into what is and isn't indexed.
- **Error path routing** — Any node failure in the ingestion chain routes to WF-3 (Error Handler) rather than silently failing.

**Documents indexed in this demo:**

| File | Type | Status |
|------|------|--------|
| `Managing.pdf` | Policy | Indexed |
| `Human-Resource-Management.pdf` | Reference | Indexed |
| `Digital Workplace for HR_Supercharging HR with Data...` | Guide | Indexed |
| `Shared-Parental-Leave-Policy.docx` | Policy | Indexed |

---

### WF-2 — Query Agent (RAG Pipeline)

**File:** `Query_wf.png` | **Trigger:** Webhook `POST /webhook-test/hr-query`

This is the core intelligence pipeline. It accepts a natural-language query, retrieves semantically relevant document chunks, reranks them, synthesizes a grounded answer with citations, and logs everything.

**Node flow:**

```
Webhook Query In → Parse + Hash → Cache Lookup (Postgres)
    ├── [Cache Hit]  → Increment Cache Hit → Shape Cached Response → Webhook Response
    └── [Cache Miss] → Classify Doc Types (LLM)
                        → Parse Doc Types
                        → Embed Query (OpenAI)
                        → Build Pinecone Query
                        → Pinecone Query
                        → Deduplicate Chunks
                        → LLM Rerank (Message Model)
                        → Build Context
                        → LLM Answer (Message Model)
                        → Validate Response
                        → Cache Write (Postgres)
                        → Log Query (Postgres)
                        → Webhook Response
```

**Key design decisions:**

- **Query caching layer** — Identical questions (matched by SHA-256 hash of the query text) are served from PostgreSQL cache rather than re-hitting Pinecone and OpenAI. This dramatically reduces latency and API costs for repeated queries.
- **Document type classification** — Before retrieval, an LLM agent classifies which document types are relevant to the query. This narrows the Pinecone namespace search and improves precision.
- **LLM Reranking** — After vector retrieval, a second LLM pass reorders chunks by relevance before synthesis. This is a two-stage retrieval pattern that significantly reduces hallucination from noisy top-k results.
- **Structured response schema** — Every answer is validated against a schema before being returned:
  - `answer` — grounded, source-cited text
  - `sources` — list of document filenames
  - `confidence` — `High` / `Low`
  - `answer_found` — boolean
  - `follow_up_suggestions` — AI-generated follow-up questions
  - `cache_hit` — boolean
  - `latency_ms` — end-to-end response time
- **Out-of-scope handling** — When a query falls outside the document corpus (e.g., *"What is the company stock position?"*), the system returns `answer_found: false` and `confidence: Low` rather than fabricating an answer.

**Sample API response:**

```json
{
  "answer": "The Company recognizes the importance of shared parental leave and aims to provide flexibility for employees to care for and bond with their child during the first year of birth or adoption. [Source: Shared-Parental-Leave-Policy.docx]",
  "sources": ["Shared-Parental-Leave-Policy.docx"],
  "confidence": "High",
  "answer_found": true,
  "follow_up_suggestions": [
    "What specific details about the leave duration or pay would you like to know?"
  ],
  "cache_hit": false,
  "latency_ms": 12573
}
```

---

### WF-3 — Error Handler Agent

**File:** `error-trigger-wf.png` | **Trigger:** Error Trigger (n8n native)

A dedicated error-handling workflow that catches failures from any other workflow and routes them into structured PostgreSQL logs for monitoring and triage.

**Node flow:**

```
Error Trigger → Format + Classify Error → Log Error (Postgres)
```

**Key design decisions:**

- **Error classification** — Errors are automatically categorized: `rate_limit | auth | timeout | parse | other`. This enables pattern detection (e.g., "we're hitting OpenAI rate limits every morning at 2AM").
- **Retry tracking** — The `retry_count` field in `error_log` enables future implementation of exponential backoff and automatic retry logic.
- **Decoupled from main workflows** — Using n8n's native Error Trigger means the error handler activates automatically without any explicit try/catch wiring in each workflow node.
- **Zero silent failures** — Every caught exception lands in a queryable table, making the system auditable and debuggable without log-diving.

**PostgreSQL error_log schema:**

```sql
id | workflow_name | node_name | error_message | error_category | file_id | retry_count | created_at
```

---

### WF-4 — Analytics & Scheduled Maintenance Agent

**File:** `2am-auto-update-wf.png` | **Trigger:** Schedule (Daily 2AM) + Manual

This workflow does double duty: it triggers the ingestion pipeline for new documents AND aggregates the previous day's query activity into the `analytics_daily` table.

**Node flow (analytics branch):**

```
Schedule / Manual Trigger → Top Queries (Postgres) → Top Not Found Queries (Postgres)
    → Merge All Data → Aggregate Report → Write Analytics Report (Postgres)
    → Evict Expired Cache (Postgres)
```

**Metrics computed daily:**

| Metric | Description |
|--------|-------------|
| `total_queries` | Total API calls in the past 24h |
| `cache_hit_rate` | % of queries served from cache |
| `not_found_rate` | % of queries where `answer_found = false` |
| `low_confidence_rate` | % of answers returned with `Low` confidence |
| `avg_latency_ms` | Mean end-to-end response time |
| `p95_latency_ms` | 95th percentile latency |
| `top_queries` | Most frequently asked questions (JSONB) |
| `top_not_found` | Most frequent unanswerable queries (JSONB) |
| `indexed_docs` | Total successfully indexed documents |
| `stale_docs` | Documents pending re-indexing |
| `errors_24h` | Error count from WF-3 in the past 24h |

**Key design decisions:**

- **Cache eviction** — Expired cache entries are purged in the same scheduled run, keeping the `query_cache` table lean without a separate maintenance job.
- **`top_not_found` tracking** — This is a product feedback loop. Queries the system couldn't answer tell you exactly which documents are missing from your knowledge base.
- **Single scheduled job** — Both ingestion (document refresh) and analytics (reporting) run in the same 2AM window, minimising the number of scheduled tasks to manage.

---

## 🗄️ Database Schema

All schema DDL is in `hr-rag-prod.sql`. Safe to run on a fresh database or on top of an existing v1 schema (uses `IF NOT EXISTS` and `ALTER TABLE ADD COLUMN IF NOT EXISTS`).

```
hr-rag-prod (PostgreSQL 18)
│
├── documents          # File-level ingestion registry + SHA-256 hash dedup
├── query_log          # Full audit trail of every query and response
├── query_cache        # PostgreSQL-backed response cache (keyed by query hash)
├── error_log          # Structured error records from WF-3
└── analytics_daily    # Daily aggregated metrics written by WF-4
```

**Index strategy:** All high-frequency query paths are indexed (`status`, `document_type`, `file_hash`, `created_at DESC`, `query_hash`) to ensure sub-second reads even at scale.

---

## ⚡ Performance

Tested against 4 documents (~6MB total) on a local n8n instance:

| Query Type | Latency (first call) | Cache Hit |
|---|---|---|
| HR policy (High confidence) | ~8–13 seconds | ~1ms |
| Out-of-scope query (Low confidence) | ~9 seconds | ~1ms |
| Repeat query (cached) | < 10ms | ✅ |

> Latency is dominated by OpenAI embedding + LLM inference time. Production deployments with a hosted n8n instance and GPT-4o-mini can reduce this to 3–5 seconds.

---

## 🗂️ Repository Structure

```
hr-rag-multi-agent-ai/
│
├── 4_HR_RAG_Multi_Agent_AI.json          # n8n workflow export (all 4 workflows)
├── hr-rag-prod.sql                        # PostgreSQL schema DDL
│
├── screenshots/
│   ├── Ingestion_wf.png                   # WF-1: Ingestion workflow canvas
│   ├── Query_wf.png                       # WF-2: Query workflow canvas
│   ├── error-trigger-wf.png               # WF-3: Error handler canvas
│   ├── 2am-auto-update-wf.png             # WF-4: Analytics + scheduled run
│   ├── query-wf-published.png             # WF-2: Published + live execution
│   ├── thunderclient_response.png         # API test: wage structure query
│   ├── OutofScopeQuery-Test.png           # API test: out-of-scope query handling
│   ├── Postgres-query-logging10_02_22_PM.png  # PostgreSQL query_log table (live data)
│   ├── postgres_indextable.png            # PostgreSQL documents table (indexed files)
│   └── Latency-test.pdf                   # Latency test run documentation
│
└── README.md
```

---

## 🚀 Getting Started

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| n8n | >= 1.30 (self-hosted) | Workflow orchestration |
| PostgreSQL | >= 14 | Metadata, logging, caching |
| Pinecone | Any plan | Vector storage |
| OpenAI API | Active key | Embeddings + LLM |
| Google Drive | OAuth2 | Document source |

---

### Step 1 — Provision the PostgreSQL Database

```bash
# Create database
createdb hr-rag-prod

# Run schema (safe to re-run)
psql -d hr-rag-prod -f hr-rag-prod.sql
```

Verify tables are created:

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' ORDER BY table_name;
-- Expected: analytics_daily, documents, error_log, query_cache, query_log
```

---

### Step 2 — Set Up Pinecone

1. Create a Pinecone index with **dimension 1536** (OpenAI `text-embedding-ada-002`)
2. Choose `cosine` similarity metric
3. Note your index name and API key

---

### Step 3 — Configure Google Drive

1. In n8n, add a Google Drive OAuth2 credential
2. In **WF-1 / Set Config node**, set the target folder ID containing your HR documents
3. Supported file types: `.pdf`, `.docx`, `.txt`

---

### Step 4 — Import the Workflow

1. Open your n8n instance → **Import from file**
2. Select `4_HR_RAG_Multi_Agent_AI.json`
3. All 4 workflows will appear in your workspace

---

### Step 5 — Configure Credentials

Update the following credential references in the imported workflows:

| Credential | Used In |
|-----------|---------|
| OpenAI API Key | WF-1 (Embeddings), WF-2 (LLM Answer, Rerank, Classify) |
| Pinecone API Key | WF-1 (Upsert), WF-2 (Query) |
| PostgreSQL Connection | All workflows |
| Google Drive OAuth2 | WF-1 (List Files, Download) |

---

### Step 6 — Run Ingestion

1. Open **WF-1** → click **Execute workflow from Manual Trigger**
2. Watch the Logs panel — all files should reach `Mark Indexed`
3. Verify in PostgreSQL:

```sql
SELECT file_name, status, chunk_count FROM documents;
```

---

### Step 7 — Test the Query API

```bash
curl -X POST http://localhost:5678/webhook-test/hr-query \
  -H "Content-Type: application/json" \
  -d '{"query": "What is the parental leave policy?"}'
```

Expected response shape:

```json
{
  "answer": "...[Source: Shared-Parental-Leave-Policy.docx]",
  "sources": ["Shared-Parental-Leave-Policy.docx"],
  "confidence": "High",
  "answer_found": true,
  "follow_up_suggestions": ["..."],
  "cache_hit": false,
  "latency_ms": 12573
}
```

---

### Step 8 — Enable Scheduled Runs

1. Open **WF-1** → activate the **Schedule Daily 2AM** trigger
2. Open **WF-4** → activate the analytics cron
3. Both workflows will now run autonomously every night

---

## 📸 Screenshots

### Ingestion Workflow — WF-1
![Ingestion Workflow](screenshots/Ingestion_wf.png)
*Full ingestion pipeline: Google Drive → Hash dedup → Pinecone upsert → PostgreSQL registry*

### Query Workflow — WF-2
![Query Workflow](screenshots/Query_wf.png)
*RAG pipeline: Webhook → Cache lookup → Semantic retrieval → LLM rerank → Grounded answer*

### Error Handler — WF-3
![Error Handler](screenshots/error-trigger-wf.png)
*Dedicated error classification and PostgreSQL logging agent*

### Scheduled Analytics — WF-4
![Analytics Workflow](screenshots/2am-auto-update-wf.png)
*2AM cron: document refresh + daily metrics aggregation + cache eviction*

### Live API Response — Parental Leave Query
![Thunder Client Response](screenshots/thunderclient_response.png)
*High-confidence answer with source citation and follow-up suggestions*

### Out-of-Scope Query Handling
![Out of Scope](screenshots/OutofScopeQuery-Test.png)
*Graceful degradation: answer_found: false with helpful redirection*

### PostgreSQL Query Log (Live)
![Query Log](screenshots/Postgres-query-logging10_02_22_PM.png)
*Full audit trail — query text, confidence, latency, cache status, sources cited*

### PostgreSQL Document Index
![Document Index](screenshots/postgres_indextable.png)
*4 documents indexed: all status=indexed, chunk_count confirmed*

---

## 🔮 Future Enhancements

### Phase 2 — Access Control & Multi-Tenancy
- **Role-Based Access Control (RBAC)** — Pinecone namespace-level access enforcement so that employees only retrieve documents relevant to their department or clearance level. A Finance analyst should not be able to query an Executive Compensation policy.
- **Multi-tenant namespacing** — Extend the schema to support multiple organizations or business units on a single deployment, with isolated document sets and query logs per tenant.
- **JWT-based webhook authentication** — Add token validation at the WF-2 webhook entry point to secure the API endpoint.

### Phase 3 — Enhanced Intelligence
- **Conversational memory** — Extend the query agent to support multi-turn conversations by maintaining session context across API calls, enabling follow-up questions without re-stating context.
- **Cross-document reasoning** — Enable the LLM to synthesize answers that span multiple documents simultaneously (e.g., *"How does our parental leave policy compare with the Kuwait Labour Law requirements?"*).
- **Hybrid search** — Combine Pinecone semantic similarity with PostgreSQL full-text search (`tsvector`) for keyword-sensitive queries where semantic retrieval alone underperforms.
- **Confidence calibration** — Train a lightweight classifier on historical `query_log` data to produce calibrated probability scores rather than binary High/Low confidence.

### Phase 4 — User Interfaces
- **Telegram Bot integration** — Deploy a Telegram-based HR assistant front-end using n8n's Telegram trigger, enabling employees to query HR documents via a familiar messaging interface without any additional tooling.
- **Admin dashboard** — Build a lightweight analytics dashboard (React / Retool) consuming the `analytics_daily` table to give HR ops teams live visibility into query trends and document coverage gaps.
- **Slack / Teams connector** — Expose the webhook as a Slack slash command or Microsoft Teams bot for enterprise messaging platform integration.

### Phase 5 — Operational Excellence
- **Automated document gap detection** — Use `top_not_found` data from WF-4 to automatically generate a weekly "missing documents" report, creating a feedback loop between query analytics and knowledge base curation.
- **Pinecone metadata filtering** — Add document metadata (department, effective date, jurisdiction, document version) as Pinecone vector metadata to enable filtered retrieval (e.g., *"Show only Kuwait-jurisdiction policies"*).
- **Async ingestion queue** — Replace synchronous batch processing in WF-1 with an async queue (Redis or PostgreSQL LISTEN/NOTIFY) to handle large document libraries without timeout risk.
- **Automated regression testing** — Add a WF-5 test harness that runs a golden set of benchmark queries after each ingestion run and alerts if confidence or latency regresses beyond a defined threshold.
- **Document versioning** — Track document version history in PostgreSQL, enabling time-travel queries ("what was the parental leave policy before the March 2025 update?").

---

## 🛡️ Security Notes

- All documents remain within your own Google Drive and Pinecone index — no data is sent to third-party services except OpenAI for embedding/inference.
- The PostgreSQL database stores query text in `query_log`. Ensure your database is not publicly accessible and is encrypted at rest in production.
- Webhook endpoints should be placed behind authentication (API key or JWT) before any production deployment.
- This repository contains **no credentials, PII, or proprietary document content**. All sample query responses shown in screenshots have been generated from generic HR policy documents.

---

## 🤝 Contributing

Contributions, issues and feature requests are welcome. Please open an issue to discuss proposed changes before submitting a pull request.

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgements

Built using:
- [n8n](https://n8n.io) — Open-source workflow automation
- [Pinecone](https://www.pinecone.io) — Managed vector database
- [OpenAI](https://openai.com) — Embeddings and language models
- [PostgreSQL](https://www.postgresql.org) — Relational database for structured metadata and analytics

---

*This project is a proof-of-concept demonstrating production RAG architecture patterns. It is not affiliated with or endorsed by any of the referenced tools or vendors.*
