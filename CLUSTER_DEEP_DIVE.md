# Apache Doris Cluster — Deep Dive

> **Version**: Apache Doris 4.0.3 (Storage-Compute Separation Mode)
> **Deployment**: Docker Compose on a single host (`172.20.80.0/24` bridge network)

---

## Table of Contents

1. [Cluster Overview](#1-cluster-overview)
2. [Scaling & Statefulness](#2-scaling--statefulness)
3. [High-Level Architecture Diagram](#3-high-level-architecture-diagram)
4. [Component Deep Dive](#4-component-deep-dive)
5. [Network Architecture](#5-network-architecture)
6. [Data Flow — Write Path](#6-data-flow--write-path)
7. [Data Flow — Read Path](#7-data-flow--read-path)
8. [Configuration Files Explained](#8-configuration-files-explained)
9. [Scripts & Automation](#9-scripts--automation)
10. [Commented-Out / Disabled Components](#10-commented-out--disabled-components)

---

## 1. Cluster Overview

Your cluster runs Apache Doris in **Storage-Compute Separation** mode (introduced in Doris 3.0+). This is different from the classic "shared-nothing" Doris architecture. In this mode:

- **Compute** (BE nodes) is decoupled from **storage** (MinIO / S3-compatible object storage)
- **Metadata** is managed by a dedicated **Meta Service (MS)** backed by **FoundationDB (FDB)**
- The FE still handles SQL parsing, planning, and catalog, but storage metadata lives in FDB

### Currently Running Containers

| Container        | Image                              | IP            | Role                          | Status  |
|------------------|------------------------------------|---------------|-------------------------------|---------|
| `doris-fe-01`    | `apache/doris:fe-4.0.3`           | `172.20.80.2` | Frontend Master (SQL engine)  | Healthy |
| `doris-be-01`    | `apache/doris:be-4.0.3`           | `172.20.80.4` | Backend (compute + local cache)| Up      |
| `doris-ms`       | `apache/doris:ms-4.0.3`           | `172.20.80.21`| Meta Service                  | Up      |
| `fdb`            | `foundationdb/foundationdb:7.1.26`| `172.20.80.20`| FoundationDB (metadata store) | Up      |
| `minio`          | `minio/minio:latest`              | `172.20.80.10`| S3-compatible object storage  | Up      |

---

## 2. Scaling & Statefulness

The whole point of **Storage-Compute Separation** is to make the **compute layer horizontally scalable**. Here's the truth about each component:

### Which Nodes Are Stateless (for Scaling)?

```
  ┌─────────────────────────────────────────────────────────────────┐
  │                    STATELESS (Scale Freely)                    │
  │                                                                │
  │   ┌─────────┐  ┌─────────┐  ┌─────────┐    ┌──────────────┐   │
  │   │  BE-01  │  │  BE-02  │  │  BE-N   │    │  Meta Service │   │
  │   │ compute │  │ compute │  │ compute │    │    (MS)       │   │
  │   └────┬────┘  └────┬────┘  └────┬────┘    └──────┬────────┘   │
  │        │            │            │                │            │
  │    All BEs read/write to the SAME shared storage + metadata    │
  │        │            │            │                │            │
  ├────────┼────────────┼────────────┼────────────────┼────────────┤
  │                    STATEFUL (Must Persist)                     │
  │                                                                │
  │   ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐   │
  │   │   MinIO (S3) │  │     FDB      │  │     FE (Master)    │   │
  │   │  table data  │  │   metadata   │  │  catalog / schema  │   │
  │   └──────────────┘  └──────────────┘  └────────────────────┘   │
  └─────────────────────────────────────────────────────────────────┘
```

| Component | Stateless for Scaling? | What Happens If You Delete Its Volume? |
|-----------|----------------------|----------------------------------------|
| **BE** (Backend) | ✅ **Yes** | Nothing lost. Local `storage/` is just a **cache**. BE re-fetches data from MinIO on next query. You can spin up 10 new BEs and they immediately start serving queries. |
| **MS** (Meta Service) | ✅ **Yes** | Nothing lost. MS is a pure API layer — all state is in FDB. You can restart/replace/scale MS freely. |
| **FE** (Frontend) | ❌ **No** | You lose the **catalog** (database schemas, table definitions, user accounts, permissions). FE stores this locally in BDB-JE at `doris-meta/`. |
| **FDB** (FoundationDB) | ❌ **No** | You lose all **tablet metadata** (which segments belong to which tables, version history, transaction state). Data files in MinIO become orphaned. |
| **MinIO** (S3) | ❌ **No** | You lose the **actual data** (columnar segment files, rowsets). This is your data warehouse. |

### How Scaling Works in Practice

**To scale compute up** — just add more BEs:
```bash
# 1. Uncomment doris-be-02 / doris-be-03 in docker-compose.yml
# 2. Start them
docker compose up -d
# 3. Register them with the FE
mysql -h 127.0.0.1 -P 9030 -uroot -e "ALTER SYSTEM ADD BACKEND '172.20.80.5:9050';"
```

**To scale compute down** — just remove BEs:
```bash
# 1. Decommission gracefully (FE stops sending queries to it)
mysql -h 127.0.0.1 -P 9030 -uroot -e "ALTER SYSTEM DECOMMISSION BACKEND '172.20.80.5:9050';"
# 2. Stop the container
docker stop doris-be-02
```

**No data migration needed.** Because BEs don't own data — they just compute against shared S3 storage. This is the key difference from classic Doris where each BE owned its tablets and decommissioning required data rebalancing.

### Classic Doris vs Your Setup (Separation Mode)

```
  CLASSIC DORIS (shared-nothing)          YOUR SETUP (storage-compute separation)
  ─────────────────────────────           ──────────────────────────────────────

  ┌─────────┐   ┌─────────┐              ┌─────────┐   ┌─────────┐
  │  BE-01  │   │  BE-02  │              │  BE-01  │   │  BE-02  │
  │─────────│   │─────────│              │─────────│   │─────────│
  │ Data A  │   │ Data B  │              │ Cache   │   │ Cache   │
  │ (owned) │   │ (owned) │              │ (temp)  │   │ (temp)  │
  └─────────┘   └─────────┘              └────┬────┘   └────┬────┘
                                              │             │
  Each BE owns its data.                      ▼             ▼
  Remove BE = must migrate data.         ┌────────────────────────┐
  Scale = rebalance tablets.             │    MinIO / S3          │
                                         │  (ALL data lives here) │
                                         └────────────────────────┘

                                         Remove BE = no data loss.
                                         Scale = just add/remove BEs.
```

### What Volumes Are Safe to Delete vs Critical

```
  YOUR DOCKER VOLUMES:

  ./fe-data-01/doris-meta  ──── 🔴 CRITICAL (catalog, schemas)
  ./fe-data-01/log         ──── 🟢 SAFE TO DELETE (just logs)
  ./be-data-01/storage     ──── 🟢 SAFE TO DELETE (just cache, re-fetched from S3)
  ./be-data-01/log         ──── 🟢 SAFE TO DELETE (just logs)
  ./minio-data             ──── 🔴 CRITICAL (actual table data)
  fdb-config (docker vol)  ──── 🔴 CRITICAL (tablet metadata)
```

---

## 3. High-Level Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        Docker Bridge Network: 172.20.80.0/24                │
│                                                                              │
│  ┌──────────────────┐         SQL Queries (MySQL Protocol)                   │
│  │   Client / App   │◄──────────── Port 9030 ──────────────────┐             │
│  │  mysql -P 9030   │              Port 8030 (Web UI)          │             │
│  └──────────────────┘                                          │             │
│           │                                                    │             │
│           ▼                                                    │             │
│  ┌────────────────────────────────────────────────────────┐    │             │
│  │              FRONTEND (FE) — 172.20.80.2               │    │             │
│  │                  doris-fe-01 (Master)                   │    │             │
│  │                                                        │    │             │
│  │  ┌──────────┐  ┌───────────┐  ┌────────────────────┐  │    │             │
│  │  │  SQL     │  │  Query    │  │  Catalog /          │  │    │             │
│  │  │  Parser  │  │  Planner  │  │  Metadata Manager   │  │    │             │
│  │  └──────────┘  └───────────┘  └────────────────────┘  │    │             │
│  │                                                        │    │             │
│  │  Ports: 9030 (MySQL), 8030 (HTTP/WebUI), 9010 (Edit)  │    │             │
│  └─────────────────────────┬──────────────────────────────┘    │             │
│                            │                                    │             │
│              ┌─────────────┼─────────────┐                     │             │
│              │ Query Plan  │  Metadata   │                     │             │
│              ▼             ▼             ▼                      │             │
│  ┌───────────────────┐  ┌─────────────────────────────┐        │             │
│  │  BACKEND (BE)     │  │   META SERVICE (MS)         │        │             │
│  │  172.20.80.4      │  │   172.20.80.21              │        │             │
│  │  doris-be-01      │  │   doris-ms                  │        │             │
│  │                   │  │                             │        │             │
│  │  ┌─────────────┐  │  │  ┌────────────┐            │        │             │
│  │  │  Compute    │  │  │  │  Tablet    │            │        │             │
│  │  │  Engine     │  │  │  │  Metadata  │            │        │             │
│  │  ├─────────────┤  │  │  │  Manager   │            │        │             │
│  │  │  Local      │  │  │  ├────────────┤            │        │             │
│  │  │  Cache      │  │  │  │  S3 Path   │            │        │             │
│  │  ├─────────────┤  │  │  │  Resolver  │            │        │             │
│  │  │ S3 Client   │  │  │  └────────────┘            │        │             │
│  │  └──────┬──────┘  │  │        │                    │        │             │
│  │         │         │  │        │                    │        │             │
│  │  Ports: 9060      │  │  Ports: 5000 (bRPC)        │        │             │
│  │  8040, 9050, 8060 │  │         8900 (HTTP)        │        │             │
│  └─────────┬─────────┘  └────────┬────────────────────┘        │             │
│            │                     │                              │             │
│            │  Read/Write Data    │  Read/Write Metadata         │             │
│            ▼                     ▼                              │             │
│  ┌───────────────────┐  ┌─────────────────────────────┐        │             │
│  │     MinIO (S3)    │  │    FoundationDB (FDB)       │        │             │
│  │   172.20.80.10    │  │    172.20.80.20              │        │             │
│  │                   │  │                             │        │             │
│  │  Bucket:          │  │  Stores:                    │        │             │
│  │  "fake-events"    │  │  - Tablet metadata          │        │             │
│  │                   │  │  - Partition info            │        │             │
│  │  Stores:          │  │  - Version chains            │        │             │
│  │  - SST files      │  │  - Cluster topology          │        │             │
│  │  - Segment data   │  │                             │        │             │
│  │  - CSV uploads    │  │  Port: 4500                  │        │             │
│  │                   │  │  Config: single / memory     │        │             │
│  │  Ports: 9000, 9001│  │                             │        │             │
│  └───────────────────┘  └─────────────────────────────┘        │             │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────┐             │
│  │  DATA GENERATOR — 172.20.80.14  (doris-data-generator)     │             │
│  │                                                             │             │
│  │  1. Generates CSV files (500K rows × 10 files = 5M rows)   │             │
│  │  2. Uploads CSV to MinIO bucket "fake-events"               │             │
│  │  3. Triggers S3 LOAD into Doris table "events_s3load"       │             │
│  │  4. Repeats every 5 seconds                                 │             │
│  └─────────────────────────────────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Simplified Data Flow

```
                  ┌─────┐
                  │ SQL │ (MySQL client / App)
                  └──┬──┘
                     │
                     ▼
               ┌──────────┐
               │  FE-01   │  Parse → Plan → Optimize
               │ (Master) │
               └────┬─────┘
                    │
          ┌─────────┴──────────┐
          │                    │
          ▼                    ▼
    ┌──────────┐        ┌──────────┐
    │  BE-01   │        │ Meta Svc │
    │ (Compute)│        │  (MS)    │
    └────┬─────┘        └────┬─────┘
         │                   │
    ┌────┴────┐        ┌─────┴─────┐
    │  MinIO  │        │    FDB    │
    │ (Data)  │        │(Metadata) │
    └─────────┘        └───────────┘
```

---

## 4. Component Deep Dive

### 4.1 Frontend (FE) — `doris-fe-01`

The **Frontend** is the brain of the cluster. It is a Java process (JDK 17) that handles:

| Responsibility         | Description |
|------------------------|-------------|
| **SQL Parsing**        | Accepts MySQL protocol connections on port `9030` and parses SQL |
| **Query Planning**     | Generates distributed query execution plans using a cost-based optimizer |
| **Catalog Management** | Maintains the database schema, table definitions, user permissions |
| **Transaction Coordination** | Manages transaction IDs, commit/abort decisions |
| **Load Balancing**     | Distributes query fragments across available BE nodes |
| **Web UI**             | Exposes a management dashboard at `http://localhost:8030` |

**How FE works internally:**

```
  Client SQL Query
        │
        ▼
  ┌─────────────┐
  │  Listener   │ ◄── MySQL Protocol (port 9030)
  │  (Netty)    │
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  SQL Parser │ ◄── Converts SQL text → AST (Abstract Syntax Tree)
  │  (ANTLR)    │
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Analyzer   │ ◄── Resolves table/column names, checks permissions
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Planner    │ ◄── Generates logical plan → physical plan
  │  (CBO)      │     Cost-Based Optimizer chooses join orders, indexes
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Coordinator│ ◄── Splits plan into fragments, assigns to BEs
  └──────┬──────┘
         │
         ▼
       BE(s)      ◄── Sends plan fragments via bRPC to Backend nodes
```

**FE Master vs Follower:**
- The **Master FE** (your `doris-fe-01`) handles all write operations (DDL, DML)
- **Follower FEs** (currently commented out as `doris-fe-02`) replicate metadata via a BDB-JE (Berkeley DB Java Edition) based Raft-like protocol for HA
- Followers can serve read queries, distributing query load

---

### 4.2 Backend (BE) — `doris-be-01`

The **Backend** is a C++ process that performs the actual data computation:

| Responsibility       | Description |
|----------------------|-------------|
| **Query Execution**  | Executes query plan fragments received from FE (scan, filter, join, agg) |
| **Storage I/O**      | In separation mode: reads data from MinIO (S3) and caches locally |
| **Local Cache**      | Caches hot data on local disk at `/opt/apache-doris/be/storage` |
| **Data Ingestion**   | Handles data loading (Stream Load, S3 Load, etc.) |
| **Heartbeat**        | Reports health to FE every few seconds via port `9050` |

**BE Port Breakdown:**

| Port   | Protocol | Purpose |
|--------|----------|---------|
| `9060` | Thrift   | BE main port — receives query fragments from FE |
| `8040` | HTTP     | WebServer — exposes metrics, profiles, admin APIs |
| `9050` | Thrift   | Heartbeat service — FE polls this to check BE health |
| `8060` | bRPC     | Inter-BE communication (shuffles, exchanges during distributed queries) |

**How a query executes on BE:**

```
  Plan Fragment (from FE via bRPC)
          │
          ▼
  ┌──────────────┐
  │  Plan        │
  │  Fragment    │
  │  Executor    │
  └──────┬───────┘
         │
   ┌─────┴──────┐
   │             │
   ▼             ▼
┌────────┐  ┌─────────┐
│  Scan  │  │  Join / │
│  Node  │  │  Agg    │
│        │  │  Node   │
└───┬────┘  └────┬────┘
    │            │
    ▼            ▼
┌────────────────────────┐
│     Storage Layer      │
│                        │
│  1. Check local cache  │
│  2. If miss → fetch    │
│     from MinIO (S3)    │
│  3. Decode segment     │
│  4. Apply predicates   │
│  5. Return results     │
└────────────────────────┘
```

---

### 4.3 Meta Service (MS) — `doris-ms`

The **Meta Service** is unique to the **Storage-Compute Separation** architecture. It is a Java service that:

| Responsibility          | Description |
|-------------------------|-------------|
| **Tablet Metadata**     | Tracks which segments/rowsets belong to which tablets |
| **Version Management**  | Maintains version chains for MVCC (Multi-Version Concurrency Control) |
| **S3 Path Resolution**  | Maps logical tablet IDs → physical S3 object paths |
| **Cluster Registration**| Tracks which BEs are part of which compute groups |
| **Transaction Metadata**| Stores transaction commit info in FDB for durability |

**Why MS exists:**
In classic Doris, each BE "owns" its tablets and stores metadata locally. In separation mode, data lives on shared S3 storage, so a centralized metadata service is needed — that's the MS.

```
  FE / BE (need to know where data is)
       │
       ▼
  ┌──────────────┐
  │  Meta        │
  │  Service     │
  │              │
  │  Resolves:   │
  │  tablet_id   │──────► S3 path: s3://bucket/data/xxxxx.dat
  │  version     │──────► Which rowsets are visible
  │  txn_id      │──────► Commit / abort status
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ FoundationDB │  ◄── All metadata persisted here
  └──────────────┘
```

---

### 4.4 FoundationDB (FDB) — `fdb`

**FoundationDB** is an open-source distributed key-value store (originally by Apple). In your cluster, it serves as the **metadata persistence layer** for the Meta Service.

| Property           | Value |
|--------------------|-------|
| **Image**          | `foundationdb/foundationdb:7.1.26` |
| **Configuration**  | `single memory` (single-process, in-memory — suitable for dev) |
| **Cluster String** | `docker:docker@172.20.80.20:4500` |

**Why FDB?**
- ACID transactions with serializable isolation
- Extremely low latency for key-value lookups
- Doris MS stores all tablet metadata as KV pairs in FDB
- In production, you'd run a multi-node FDB cluster with SSD redundancy

**Initialization Flow:**
```
  fdb container starts
        │
        ▼
  fdb-init container waits...
        │
        ▼
  fdbcli --exec 'configure new single memory'
        │
        ▼
  FDB cluster is ready ✓
        │
        ▼
  MS reads fdb.cluster file → connects to FDB
```

---

### 4.5 MinIO — `minio`

**MinIO** is an S3-compatible object storage server. In your setup, it replaces AWS S3 for local development:

| Property         | Value |
|------------------|-------|
| **API Port**     | `9000` |
| **Console Port** | `9001` (Web UI: `http://localhost:9001`) |
| **Access Key**   | `astro` |
| **Secret Key**   | `Makeclean@123` |
| **Data Dir**     | `./minio-data` mounted to `/data` |

**What's stored in MinIO:**
- **Segment files** — Doris BE writes columnar data segments (similar to Parquet) here
- **CSV uploads** — The data generator uploads raw CSV files to the `fake-events` bucket
- **Rowset data** — Compacted data after background merges

---

### 4.6 Data Generator — `doris-data-generator`

A Python service that continuously generates synthetic data:

```
  ┌─────────────────────────────────────────────────┐
  │              Data Generator Loop                │
  │                                                 │
  │  1. Generate 10 × CSV files                     │
  │     (500,000 rows each = 5,000,000 rows/batch)  │
  │                                                 │
  │  2. Upload each CSV to MinIO                    │
  │     Bucket: "fake-events"                       │
  │                                                 │
  │  3. Execute S3 LOAD via MySQL protocol          │
  │     → Doris FE → distributes to BE              │
  │     → BE reads CSV from MinIO                   │
  │     → Ingests into table "events_s3load"        │
  │                                                 │
  │  4. Sleep 5 seconds                             │
  │                                                 │
  │  5. Repeat forever                              │
  └─────────────────────────────────────────────────┘
```

**Schema of generated data:**

| Column      | Type    | Example                  |
|-------------|---------|--------------------------|
| `id`        | INT     | `1000042`                |
| `event`     | STRING  | `event73`                |
| `value`     | DOUBLE  | `4829.31`                |
| `user_id`   | INT     | `58302`                  |
| `timestamp` | INT     | `1708531200`             |
| `description`| STRING | `desc_12345_event`       |

---

## 5. Network Architecture

All containers run on a dedicated Docker bridge network with static IPs:

```
  Docker Bridge Network: doris_net (172.20.80.0/24)
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │   172.20.80.2  ─── doris-fe-01 (FE Master)          │
  │   172.20.80.4  ─── doris-be-01 (BE Node 1)          │
  │   172.20.80.10 ─── minio       (Object Storage)     │
  │   172.20.80.14 ─── data-generator                    │
  │   172.20.80.20 ─── fdb         (FoundationDB)       │
  │   172.20.80.21 ─── doris-ms    (Meta Service)       │
  │                                                      │
  │   Reserved (commented out):                          │
  │   172.20.80.3  ─── doris-fe-02 (FE Follower)        │
  │   172.20.80.5  ─── doris-be-02 (BE Node 2)          │
  │   172.20.80.6  ─── doris-be-03 (BE Node 3)          │
  │   172.20.80.11 ─── prometheus                        │
  │   172.20.80.12 ─── cadvisor                          │
  │   172.20.80.13 ─── grafana                           │
  │                                                      │
  └──────────────────────────────────────────────────────┘
```

### Host Port Mappings

| Host Port | Container Port | Service | Purpose |
|-----------|----------------|---------|---------|
| `8030`    | `8030`         | FE      | Web UI / HTTP API |
| `9030`    | `9030`         | FE      | MySQL protocol (connect with `mysql -P 9030`) |
| `8040`    | `8040`         | BE      | BE WebServer / metrics |
| `5000`    | `5000`         | MS      | bRPC (Meta Service RPC) |
| `8900`    | `8900`         | MS      | HTTP API (Meta Service) |
| `4500`    | `4500`         | FDB     | FoundationDB client port |
| `9000`    | `9000`         | MinIO   | S3 API |
| `9001`    | `9001`         | MinIO   | MinIO Console (Web UI) |

### Inter-Component Communication Map

```
  doris-fe-01
    ├──► doris-be-01    (bRPC :8060) — sends query plan fragments
    ├──► doris-be-01    (Thrift :9050) — heartbeat polling
    └──► doris-ms       (bRPC :5000) — metadata queries

  doris-be-01
    ├──► minio          (HTTP :9000) — read/write S3 data
    └──► doris-ms       (bRPC :5000) — tablet metadata lookups

  doris-ms
    └──► fdb            (TCP :4500) — persist metadata in FoundationDB

  data-generator
    ├──► minio          (HTTP :9000) — upload CSV files
    └──► doris-fe-01    (MySQL :9030) — trigger S3 LOAD commands
```

---

## 6. Data Flow — Write Path

### S3 Load (used by your data generator)

```
  ┌──────────────┐    1. LOAD LABEL SQL     ┌──────────────┐
  │    Client /   │ ──────────────────────► │   FE-01      │
  │  Generator    │                         │              │
  └──────────────┘                         └──────┬───────┘
                                                  │
                                           2. FE creates load job,
                                              assigns to BE
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │   BE-01      │
                                           └──────┬───────┘
                                                  │
                                    3. BE reads CSV from MinIO
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │    MinIO     │
                                           │  (S3 bucket) │
                                           └──────────────┘
                                                  │
                                    4. BE parses CSV rows,
                                       converts to columnar format,
                                       writes segment files to S3
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │   Meta Svc   │
                                           └──────┬───────┘
                                                  │
                                    5. MS records new rowset
                                       version in FDB
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │     FDB      │
                                           └──────────────┘
```

**Step-by-step:**
1. Client sends `LOAD LABEL ...` SQL via MySQL protocol to FE
2. FE validates the SQL, creates a load job, picks a BE to execute
3. BE uses S3 client to pull the CSV from MinIO
4. BE converts rows into Doris's columnar format (segments), writes them back to S3
5. BE notifies MS → MS persists the new rowset metadata (tablet ID, version, S3 paths) into FDB
6. FE marks the load as committed

---

## 7. Data Flow — Read Path

```
  ┌──────────────┐   1. SELECT * FROM t    ┌──────────────┐
  │    Client     │ ─────────────────────► │   FE-01      │
  └──────────────┘                         └──────┬───────┘
                                                  │
                                           2. Parse → Plan → Optimize
                                              Splits into scan fragments
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │   BE-01      │
                                           │  (fragment   │
                                           │   executor)  │
                                           └──────┬───────┘
                                                  │
                                    3. BE asks MS: "What segments
                                       belong to tablet X, version Y?"
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │   Meta Svc   │──► FDB
                                           └──────┬───────┘
                                                  │
                                    4. MS returns: list of S3 paths
                                                  │
                                                  ▼
                                           ┌──────────────┐
                                           │   BE-01      │
                                           │              │
                                           │ 5. Check     │
                                           │    local     │
                                           │    cache     │
                                           │    ↓         │
                                           │ 6. Cache     │
                                           │    miss →    │──► MinIO (S3)
                                           │    fetch     │
                                           │              │
                                           │ 7. Decode,   │
                                           │    filter,   │
                                           │    return    │
                                           └──────┬───────┘
                                                  │
                                           8. Results → FE → Client
```

---

## 8. Configuration Files Explained

### 8.1 `confs/fe.conf` — Frontend Configuration

```properties
# Where FE stores its metadata (BDB-JE database, images, editlog)
meta_dir = /opt/apache-doris/fe/doris-meta

# FE log directory
LOG_DIR = /opt/apache-doris/fe/log

# Max simultaneous client connections (MySQL protocol)
qe_max_connection = 1024

# Max concurrent transactions per database
# Prevents runaway loads from consuming all transaction slots
max_running_txn_num_per_db = 100

# JDK 17 fix: disables container-aware memory detection
# Required because Docker cgroup v2 reports incorrect memory limits
# with some JDK 17 builds, causing the JVM to use too little heap
JAVA_OPTS_FOR_JDK_17="-XX:-UseContainerSupport"

# Tells FE which network interface to bind to
# FE picks the interface whose IP falls in this subnet
priority_networks = 172.20.80.0/24

# S3 (MinIO) credentials — used for S3 catalog access and S3 load
aws_s3_region = us-east-1
aws_s3_endpoint = http://minio:9000
aws_s3_access_key = astro
aws_s3_secret_key = Makeclean@123
aws_s3_use_path_style = true    # Required for MinIO (not virtual-hosted)
```

---

### 8.2 `confs/be.conf` — Backend Configuration

```properties
# Network binding — BE picks the interface matching this subnet
priority_networks = 172.20.80.0/24

# Local storage path for cache and temporary data
storage_root_path = /opt/apache-doris/be/storage

# BE ports:
be_port = 9060                 # Main port — receives query fragments from FE
webserver_port = 8040          # HTTP server for metrics, pprof, admin
heartbeat_service_port = 9050  # FE polls this port to check BE liveness
brpc_port = 8060               # bRPC — inter-BE data exchange (shuffle, broadcast)

# Disable swap to prevent performance degradation
enable_swap = false

# S3 (MinIO) credentials — BE reads/writes data to object storage
aws_s3_region = us-east-1
aws_s3_endpoint = http://minio:9000
aws_s3_access_key = astro
aws_s3_secret_key = Makeclean@123
aws_s3_use_path_style = true
```

---

### 8.3 `confs/doris_cloud.conf` — Meta Service Configuration

```properties
# bRPC listen port for Meta Service
brpc_listen_port = 5000

# Number of bRPC threads (-1 = auto, based on CPU cores)
brpc_num_threads = -1

# FoundationDB connection string
# Format: <description>@<ip>:<port>
# This gets dynamically updated by ms-entrypoint.sh at container startup
fdb_cluster=docker:docker@172.20.80.20:4500

# Unique identifier for this Meta Service instance
# Used for compute group management in multi-MS deployments
cloud_unique_id = 172.20.80.21

# Log directory
log_dir = ./log
```

---

### 8.4 `confs/fdb.cluster` — FoundationDB Cluster File

```
doris:doris@172.20.80.20:4500
```

This is the **cluster coordination file**. Format: `<description>:<ID>@<IP>:<PORT>`. Both FDB clients (the MS) and the FDB server use this file to discover each other.

> **Note**: The `ms-entrypoint.sh` script dynamically reads the FDB-generated cluster file from `/var/fdb/fdb.cluster` and updates `doris_cloud.conf` with the real connection string at startup. This is because FDB generates its own cluster file with a random ID, so the static config may not match.

---

## 9. Scripts & Automation

### 9.1 `scripts/ms-entrypoint.sh` — Meta Service Startup

This script is the entry point for the MS container. It:

1. **Waits** for the FDB cluster file to appear at `/var/fdb/fdb.cluster`
2. **Reads** the FDB connection string from the cluster file
3. **Injects** it into `doris_cloud.conf` (replacing the `fdb_cluster=` line)
4. **Sets** `JAVA_HOME` correctly
5. **Starts** the Meta Service process

This is necessary because FDB generates its cluster file dynamically, and the MS needs to read it after FDB is ready.

---

### 9.2 `scripts/init-cluster.sh` — Cluster Initialization

Run after all containers are up (`make init`). It:

1. Connects to FE master via MySQL protocol
2. Registers the active backend: `ALTER SYSTEM ADD BACKEND '172.20.80.4:9050'`
3. Shows cluster status with `SHOW PROC '/frontends'` and `SHOW PROC '/backends'`

---

### 9.3 `scripts/check-cluster.sh` — Health Check

A quick diagnostic script that:
- Shows frontend status
- Shows backend status
- Queries row counts from `demo_db` tables
- Prints failover test commands

---

### 9.4 `Makefile` — Operational Commands

| Target      | Command                              | Purpose |
|-------------|--------------------------------------|---------|
| `make up`   | `docker compose up -d`               | Start all services |
| `make down` | `docker compose down`                | Stop all services |
| `make logs` | `docker compose logs -f`             | Tail all logs |
| `make logs-fe` | `docker logs -f doris-fe-01`      | Tail FE logs |
| `make logs-be` | `docker logs -f doris-be-01`      | Tail BE logs |
| `make init` | `./scripts/init-cluster.sh`          | Register FE/BE nodes |
| `make check`| `./scripts/check-cluster.sh`         | Health check |
| `make clean`| Remove containers + data directories | Full reset |
| `make fresh`| Clean → up → wait 30s → init        | Complete rebuild |
| `make gen`  | Build + run data generator           | Start data ingestion |

---

## 10. Commented-Out / Disabled Components

Your docker-compose has several commented-out services ready to be enabled:

### Scalability (More FE/BE nodes)

| Service       | IP             | Purpose |
|---------------|----------------|---------|
| `doris-fe-02` | `172.20.80.3`  | FE Follower for HA (reads replicated from master) |
| `doris-be-02` | `172.20.80.5`  | Additional compute node |
| `doris-be-03` | `172.20.80.6`  | Additional compute node |

### Monitoring Stack

| Service       | IP             | Purpose |
|---------------|----------------|---------|
| `prometheus`  | `172.20.80.11` | Metrics collection (scrapes cAdvisor) |
| `cadvisor`    | `172.20.80.12` | Container resource metrics (CPU, memory, I/O) |
| `grafana`     | `172.20.80.13` | Dashboard visualization |

To enable any of these, uncomment the relevant block in `docker-compose.yml` and run `make up`.

---

## 11. Data Generator Workflow (Stream Load)

```
  generator.py (inside doris-data-generator container)
       │
       │  1. GENERATE — Creates CSV in memory (500K rows, ~30MB)
       │     Columns: id, event, value, user_id, timestamp, description
       │
       │  2. STREAM LOAD — HTTP PUT directly to FE:
       │     PUT http://doris-fe-01:8030/api/events_db/events_stream/_stream_load
       │     Body: raw CSV data
       │     (synchronous — response tells you immediately if it worked)
       │
       ▼
  ┌──────────┐
  │  FE-01   │  3. FE validates request, routes to BE-01
  └────┬─────┘
       │
       ▼
  ┌──────────┐
  │  BE-01   │  4. BE receives CSV stream directly in memory
  │ (compute)│     ↓
  │          │  5. Parses rows, converts to columnar segments
  │          │     ↓
  │          │  6. Writes segment files to MinIO (S3)
  │          │     ↓
  │          │  7. Notifies Meta Service: "new rowset created"
  └────┬─────┘
       │
       ▼
  ┌──────────┐
  │ Meta Svc │  8. MS persists metadata to FDB
  └────┬─────┘
       │
       ▼
  ┌──────────┐
  │   FDB    │  9. Committed. FE returns HTTP 200 to generator.
  └──────────┘
```

**Key improvement**: The generator never touches MinIO. Data goes directly from generator → FE → BE → MinIO in a single hop.

