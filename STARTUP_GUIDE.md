# Apache Doris — Startup Guide

## Quick Start (3 commands)

```bash
make up          # 1. Start core services (FE, BE, FDB, MinIO, MS)
# Wait ~30 seconds for services to be ready
make init        # 2. Create bucket, storage vault, register BE, create schema
make gen         # 3. Start the data generator
```

Or do it all at once:
```bash
make fresh       # clean → up → wait 30s → init (then run: make gen)
```

---

## Step-by-Step Breakdown

### Step 1: Start Core Services

```bash
make up
```

This starts (in order):
| Service | Container | What it does |
|---------|-----------|-------------|
| FoundationDB | `fdb` | Metadata KV store |
| FDB Init | `fdb-init` | Configures FDB as `single memory`, then exits |
| MinIO | `minio` | S3-compatible object storage |
| Meta Service | `doris-ms` | Metadata API layer (reads FDB cluster file, connects to FDB) |
| Frontend | `doris-fe-01` | SQL engine, query planner |
| Backend | `doris-be-01` | Compute engine |

**Wait ~30 seconds** for FE to become healthy (check with `docker ps` — FE should show `healthy`).

---

### Step 2: Initialize the Cluster

```bash
make init
```

The `scripts/init-cluster.sh` does 5 things:

1. **Wait for FE** — polls MySQL port until FE responds
2. **Register BE** — `ALTER SYSTEM ADD BACKEND '172.20.80.4:9050'`
3. **Create MinIO bucket** — runs a one-shot `minio/mc` container to create `doris-storage` bucket
4. **Create Storage Vault** — tells Doris to use MinIO as the storage backend:
   ```sql
   CREATE STORAGE VAULT IF NOT EXISTS minio_vault ...
   SET minio_vault AS DEFAULT STORAGE VAULT;
   ```
5. **Create Schema** — creates `events_db` database and `events_stream` table

After this step, **all new data goes to MinIO** (not local BE storage). BEs are now truly stateless.

---

### Step 3: Start the Generator

```bash
make gen
```

This builds and starts the `data-generator` container, which:
- Generates CSV data in memory (100K rows × 3 files per batch)
- Sends it directly to FE via **Stream Load** (HTTP PUT)
- FE routes to BE → BE writes segments to MinIO → metadata to FDB
- Sleeps 10 seconds, repeats

---

## Verify Everything Works

```bash
# Check all containers are running
make status

# Check generator logs
make logs-gen

# Check row count
mysql -h 127.0.0.1 -P 9030 -uroot -e "SELECT COUNT(*) FROM events_db.events_stream;"

# Check storage vault
mysql -h 127.0.0.1 -P 9030 -uroot -e "SHOW STORAGE VAULTS;"

# Check data in MinIO
# Open http://localhost:9001 (astro / Makeclean@123)
# Look for the 'doris-storage' bucket
```

---

## Other Commands

| Command | What it does |
|---------|-------------|
| `make down` | Stop all containers |
| `make clean` | Stop + delete all data (full reset) |
| `make fresh` | Clean → up → wait → init |
| `make logs` | Tail all container logs |
| `make logs-fe` | Tail FE logs only |
| `make logs-be` | Tail BE logs only |
| `make logs-gen` | Tail generator logs only |
| `make logs-ms` | Tail Meta Service logs |
| `make stop-gen` | Stop the generator (keeps data) |
| `make check` | Quick cluster health check |

---

## Data Flow (with Storage Vault)

```
  Generator                    FE                    BE                  MinIO               MS → FDB
     │                         │                     │                    │                    │
     │  HTTP PUT (CSV data)    │                     │                    │                    │
     │────────────────────────►│                     │                    │                    │
     │                         │  307 redirect       │                    │                    │
     │                         │────────────────────►│                    │                    │
     │  HTTP PUT (CSV data)    │                     │                    │                    │
     │──────────────────────────────────────────────►│                    │                    │
     │                         │                     │  write segments    │                    │
     │                         │                     │───────────────────►│                    │
     │                         │                     │  persist metadata  │                    │
     │                         │                     │────────────────────────────────────────►│
     │                         │                     │                    │                    │
     │  HTTP 200 (success)     │                     │                    │                    │
     │◄──────────────────────────────────────────────│                    │                    │
```
