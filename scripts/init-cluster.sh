#!/bin/bash
# ============================================================
# Doris Cluster Initialization Script
# Run this AFTER:  make up  (core services must be running)
# Run this BEFORE: make gen (generator needs the vault + schema)
# ============================================================



MYSQL_CMD="mysql -h 172.20.80.2 -P 9030 -uroot"
MINIO_ENDPOINT="http://172.20.80.10:9000"
MINIO_ACCESS_KEY="astro"
MINIO_SECRET_KEY="Makeclean@123"
BUCKET_NAME="doris-storage"

echo "======================================="
echo " Doris Cluster Initialization"
echo "======================================="

# ── Step 1: Wait for FE ──
echo ""
echo "[1/5] Waiting for FE to be ready..."
for i in $(seq 1 30); do
    if $MYSQL_CMD -e "SELECT 1" &>/dev/null; then
        echo "  ✓ FE is ready"
        break
    fi
    echo "  Attempt $i/30 — waiting..."
    sleep 5
done

# ── Step 2: Register BE ──
echo ""
echo "[2/5] Registering Backend node..."
$MYSQL_CMD -e "ALTER SYSTEM ADD BACKEND '172.20.80.4:9050';" 2>/dev/null || true
echo "  ✓ BE-01 registered"

# Wait for BE to become alive
echo "  Waiting for BE to be alive..."
for i in $(seq 1 20); do
    ALIVE=$($MYSQL_CMD --skip-column-names -e "SHOW BACKENDS" 2>/dev/null | awk '{print $10}' | head -1)
    if [ "$ALIVE" = "true" ]; then
        echo "  ✓ BE-01 is alive"
        break
    fi
    sleep 3
done

# ── Step 3: Create MinIO bucket ──
echo ""
echo "[3/5] Creating MinIO bucket '$BUCKET_NAME'..."

docker run --rm --network apache-doris_doris_net \
    --entrypoint="" \
    minio/mc:latest \
    sh -c "mc alias set myminio $MINIO_ENDPOINT $MINIO_ACCESS_KEY '$MINIO_SECRET_KEY' --api s3v4 && mc mb --ignore-existing myminio/$BUCKET_NAME"
echo "  ✓ Bucket '$BUCKET_NAME' ready"

# ── Step 4: Create Storage Vault ──
echo ""
echo "[4/5] Creating Storage Vault (S3 → MinIO)..."

$MYSQL_CMD -e "
CREATE STORAGE VAULT IF NOT EXISTS minio_vault
PROPERTIES (
    'type' = 'S3',
    's3.endpoint' = '$MINIO_ENDPOINT',
    's3.access_key' = '$MINIO_ACCESS_KEY',
    's3.secret_key' = '$MINIO_SECRET_KEY',
    's3.region' = 'us-east-1',
    's3.bucket' = '$BUCKET_NAME',
    'use_path_style' = 'true'
);
" 2>/dev/null || true
echo "  ✓ Storage vault 'minio_vault' created"

$MYSQL_CMD -e "SET minio_vault AS DEFAULT STORAGE VAULT;" 2>/dev/null || true
echo "  ✓ Set as default storage vault"

# ── Step 5: Create Database & Table ──
echo ""
echo "[5/5] Creating database and table..."

$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS events_db;" 2>/dev/null
echo "  ✓ Database 'events_db' created"

$MYSQL_CMD -e "
CREATE TABLE IF NOT EXISTS events_db.events_stream
(
    id BIGINT,
    event VARCHAR(50),
    value DOUBLE,
    user_id BIGINT,
    timestamp BIGINT,
    description VARCHAR(100)
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES('replication_num' = '1');
" 2>/dev/null
echo "  ✓ Table 'events_db.events_stream' created"

# ── Done ──
echo ""
echo "======================================="
echo " ✓ Cluster initialization complete!"
echo "======================================="
echo ""
echo "Verify:"
echo "  mysql -h 127.0.0.1 -P 9030 -uroot -e 'SHOW STORAGE VAULTS;'"
echo "  mysql -h 127.0.0.1 -P 9030 -uroot -e 'SHOW BACKENDS;'"
echo ""
echo "Start the data generator:"
echo "  make gen"
echo ""
echo "Web UIs:"
echo "  Doris:  http://localhost:8030"
echo "  MinIO:  http://localhost:9001  (astro / Makeclean@123)"
echo ""
