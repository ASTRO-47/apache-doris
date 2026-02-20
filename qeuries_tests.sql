/* ============================================================
   1️⃣ BASIC SCAN TESTS
   ============================================================ */

-- Full table scan
SELECT COUNT(*) FROM events_s3load;

-- Filtered scan
SELECT COUNT(*)
FROM events_s3load
WHERE value > 100;

-- Timestamp range scan
SELECT *
FROM events_s3load
WHERE timestamp BETWEEN 1700000000 AND 1705000000
LIMIT 100;


/* ============================================================
   2️⃣ AGGREGATION TESTS
   ============================================================ */

-- Group by event
SELECT
    event,
    COUNT(*) AS total_events,
    SUM(value) AS total_value,
    AVG(value) AS avg_value
FROM events_s3load
GROUP BY event
ORDER BY total_events DESC;

-- Group by user
SELECT
    user_id,
    COUNT(*) AS cnt,
    SUM(value) AS total_spent
FROM events_s3load
GROUP BY user_id
ORDER BY total_spent DESC
LIMIT 20;


/* ============================================================
   3️⃣ SELF JOIN TEST (HEAVY)
   ============================================================ */

SELECT
    a.user_id,
    COUNT(a.id) AS event_count,
    SUM(a.value) AS total_value,
    COUNT(DISTINCT b.event) AS distinct_events
FROM events_s3load a
JOIN events_s3load b
    ON a.user_id = b.user_id
WHERE a.value > 50
GROUP BY a.user_id
ORDER BY total_value DESC
LIMIT 20;


/* ============================================================
   4️⃣ WINDOW FUNCTION TESTS
   ============================================================ */

-- Row number per user
SELECT
    user_id,
    event,
    value,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY timestamp DESC) AS rn
FROM events_s3load
LIMIT 100;

-- Running total per user
SELECT
    user_id,
    SUM(value) OVER (PARTITION BY user_id) AS total_user_value
FROM events_s3load
LIMIT 100;


/* ============================================================
   5️⃣ OLAP-STYLE ANALYTICS QUERY
   ============================================================ */

SELECT
    event,
    DATE_FORMAT(FROM_UNIXTIME(timestamp), '%Y-%m') AS month,
    COUNT(*) AS cnt,
    SUM(value) AS total_value,
    AVG(value) AS avg_value
FROM events_s3load
WHERE value > 10
GROUP BY event, month
ORDER BY month DESC, total_value DESC;


/* ============================================================
   6️⃣ CARDINALITY CHECK
   ============================================================ */

SELECT
    COUNT(DISTINCT user_id) AS unique_users,
    COUNT(DISTINCT event) AS unique_events
FROM events_s3load;


/* ============================================================
   7️⃣ SUBQUERY + JOIN + AGGREGATION
   ============================================================ */

SELECT
    t.event,
    COUNT(*) AS total_events,
    SUM(t.value) AS total_value
FROM events_s3load t
JOIN (
    SELECT user_id
    FROM events_s3load
    WHERE value > 500
    GROUP BY user_id
) high_value_users
ON t.user_id = high_value_users.user_id
GROUP BY t.event
ORDER BY total_value DESC;


/* ============================================================
   8️⃣ EXPLAIN ANALYZE EXAMPLE (PERFORMANCE DEBUG)
   ============================================================ */

EXPLAIN ANALYZE
SELECT
    event,
    COUNT(*) AS total_events,
    SUM(value) AS total_value
FROM events_s3load
GROUP BY event;
