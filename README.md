# Apache Doris Learning Cluster

A simple but functional Apache Doris cluster setup for learning and experimentation.

## Architecture

```
┌─────────────────────────────────────────────────┐
│           Frontend Layer (HA)                    │
│  ┌──────────────┐      ┌──────────────┐        │
│  │   FE-01      │◄────►│   FE-02      │        │
│  │   (Master)   │      │  (Follower)  │        │
│  └──────────────┘      └──────────────┘        │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│          Backend Layer (3 replicas)              │
│  ┌────────┐      ┌────────┐      ┌────────┐    │
│  │  BE-01 │      │  BE-02 │      │  BE-03 │    │
│  └────────┘      └────────┘      └────────┘    │
└─────────────────────────────────────────────────┘
                    ▲
                    │
          ┌─────────────────┐
          │ Data Generator   │
          │  (Fake Events)   │
          └─────────────────┘
```

## What You Get

- **2 FE nodes**: 1 Master + 1 Follower (learn high availability)
- **3 BE nodes**: Data replication with 3 copies
- **Event Generator**: Creates fake user and purchase events
- **Auto-setup**: Tables created automatically

## Quick Start

### 1. Start the Cluster

```bash
cd apache-dori
docker-compose up -d
```

Wait ~30 seconds for services to initialize.

### 2. Initialize Cluster (Register nodes)

```bash
chmod +x scripts/*.sh
./scripts/init-cluster.sh
```

This registers the FE follower and all BE nodes.

### 3. Verify Cluster Status

```bash
./scripts/check-cluster.sh
```

Or connect directly:
```bash
mysql -h 127.0.0.1 -P 9030 -uroot
```

### 4. Watch Events Flow

The data generator automatically creates:
- **user_events**: page views, clicks, logins (70% of traffic)
- **purchase_events**: product purchases (30% of traffic)

Check data:
```sql
USE demo_db;
SELECT COUNT(*) FROM user_events;
SELECT COUNT(*) FROM purchase_events;
SELECT * FROM user_events LIMIT 10;
```

## How Events Reach Doris

**Flow:**
1. `generator.py` creates fake events using Faker library
2. Connects to FE via **MySQL protocol** (port 9030)
3. Sends INSERT statements
4. FE determines which BE nodes to use
5. Data is **hashed by user_id** to buckets
6. **3 replicas** created across different BE nodes
7. Data stored in **columnar format** on BE disks

## Learning Experiments

### Test Data Distribution
```sql
-- See how data is distributed across backends
SHOW PROC '/statistic';
SHOW TABLETS FROM user_events;
```

### Test Failover
```bash
# Stop a backend node
docker stop doris-be-01

# Query still works! (other replicas serve data)
mysql -h 127.0.0.1 -P 9030 -uroot -e "SELECT COUNT(*) FROM demo_db.user_events;"

# Restart it
docker start doris-be-01

# Cluster rebalances automatically
```

### Test FE Failover
```bash
# Stop master FE
docker stop doris-fe-01

# Connect to follower (now promoted to master)
mysql -h 127.0.0.1 -P 9031 -uroot
```

### Adjust Event Rate
```bash
# Edit docker-compose.yml, change:
EVENTS_PER_SECOND=50   # More load!

# Restart generator
docker-compose restart data-generator
```

## Useful Commands

**Check cluster health:**
```bash
./scripts/check-cluster.sh
```

**View logs:**
```bash
docker logs doris-fe-01
docker logs doris-be-01
docker logs doris-data-generator
```

**Stop everything:**
```bash
docker-compose down
```

**Clean restart (deletes data):**
```bash
docker-compose down -v
rm -rf fe-data-* be-data-*
docker-compose up -d
./scripts/init-cluster.sh
```

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| FE-01 | 9030 | MySQL protocol |
| FE-01 | 8030 | HTTP API / Web UI |
| FE-02 | 9031 | MySQL protocol |
| FE-02 | 8031 | HTTP API |
| BE-01 | 8040 | Webserver |
| BE-02 | 8041 | Webserver |
| BE-03 | 8042 | Webserver |

## Web UI

Access the Doris Web UI:
- FE-01: http://localhost:8030
- FE-02: http://localhost:8031

Default credentials: `root` / (no password)

## Data Generator Details

Location: `data-generator/generator.py`

**Event Types Generated:**

1. **User Events** (70%)
   - event_type: page_view, click, scroll, search, login, logout
   - Includes: user_id, device, city, country, URL

2. **Purchase Events** (30%)
   - Random products with categories
   - Price ranges: $5.99 - $999.99
   - Payment methods: credit_card, paypal, crypto, debit_card

**Rate Control:**
- Default: 10 events/second
- Configurable via `EVENTS_PER_SECOND` env var

## Query Examples

```sql
-- Top users by activity
SELECT user_id, COUNT(*) as events 
FROM user_events 
GROUP BY user_id 
ORDER BY events DESC 
LIMIT 10;

-- Revenue by category
SELECT category, SUM(price * quantity) as revenue
FROM purchase_events
GROUP BY category
ORDER BY revenue DESC;

-- Events per minute
SELECT 
  DATE_FORMAT(event_time, '%Y-%m-%d %H:%i') as minute,
  COUNT(*) as event_count
FROM user_events
GROUP BY minute
ORDER BY minute DESC
LIMIT 20;

-- Join user events with purchases
SELECT 
  u.user_id,
  COUNT(DISTINCT u.event_id) as total_events,
  COUNT(DISTINCT p.purchase_id) as total_purchases
FROM user_events u
LEFT JOIN purchase_events p ON u.user_id = p.user_id
GROUP BY u.user_id
LIMIT 100;
```

## Next Steps to Learn

1. ✅ Understand data distribution (HASH buckets)
2. ✅ Test replica resilience (stop BE nodes)
3. ✅ Explore FE failover
4. 📚 Learn about partitioning (add time partitions)
5. 📚 Optimize queries (indexes, materialized views)
6. 📚 Bulk loading via Stream Load API
7. 📚 Backup and restore procedures

## Troubleshooting

**BEs not showing up:**
```bash
# Re-run init script
./scripts/init-cluster.sh
```

**No data in tables:**
```bash
# Check generator logs
docker logs doris-data-generator

# Restart generator
docker-compose restart data-generator
```

**"Too many connections" error:**
Increase `qe_max_connection` in `confs/fe.conf`, restart FE.

**Out of disk space:**
Clean up old data directories:
```bash
docker-compose down
rm -rf be-data-*/storage/data/*
docker-compose up -d
```

## Architecture Notes

- **Replication**: Default 3 replicas per tablet
- **Distribution**: HASH(user_id) with 10 buckets
- **Table Model**: DUPLICATE KEY (good for logs/events)
- **Storage**: Data persisted in `be-data-*/storage/`

---

**Happy Learning! 🚀**

Experiment, break things, and learn how Doris handles failures and scales!
