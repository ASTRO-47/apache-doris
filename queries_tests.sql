/* ============================================================
   1️⃣ BASIC SCAN TESTS (Row Counts & Throughput)
   ============================================================ */

-- Total row count (Check growth)
SELECT COUNT(*) AS total_rows FROM events_db.events_stream;

-- Scan with simple filter
SELECT COUNT(*) AS high_value_rows 
FROM events_db.events_stream 
WHERE value > 50.0;

-- Latest 10 records
SELECT * 
FROM events_db.events_stream 
ORDER BY timestamp DESC 
LIMIT 10;

/* ============================================================
   2️⃣ REAL-TIME AGGREGATIONS
   ============================================================ */

-- Event distribution
SELECT 
    event, 
    COUNT(*) AS cnt, 
    AVG(value) AS avg_val,
    MAX(value) AS max_val
FROM events_db.events_stream 
GROUP BY event 
ORDER BY cnt DESC;

-- User activity stats
SELECT 
    user_id, 
    COUNT(*) AS event_count, 
    SUM(value) AS total_value
FROM events_db.events_stream 
GROUP BY user_id 
ORDER BY event_count DESC 
LIMIT 10;

/* ============================================================
   3️⃣ TIME-SERIES ANALYTICS
   ============================================================ */

-- Events per minute (assuming timestamp is unix epoch in seconds)
SELECT 
    FROM_UNIXTIME(timestamp - (timestamp % 60)) AS minute,
    COUNT(*) AS counts
FROM events_db.events_stream
GROUP BY minute
ORDER BY minute DESC
LIMIT 10;

/* ============================================================
   4️⃣ WINDOW FUNCTIONS (Heavier Queries)
   ============================================================ */

-- Last 3 events per user
SELECT * FROM (
    SELECT 
        user_id, 
        event, 
        value, 
        timestamp,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY timestamp DESC) as rank
    FROM events_db.events_stream
) t 
WHERE rank <= 3 
LIMIT 50;

/* ============================================================
   5️⃣ DIAGNOSTICS
   ============================================================ */

-- Tablet distribution (Verify data is spreading across buckets)
SHOW TABLETS FROM events_db.events_stream;

-- Data size vs Tablet count
SELECT 
    COUNT(*) as total_rows,
    SUM(DATA_LENGTH) / 1024 / 1024 as size_mb
FROM information_schema.tables 
WHERE table_schema = 'events_db' 
AND table_name = 'events_stream';
