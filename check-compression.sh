#!/bin/bash
# Compression Ratio: Raw CSV generated vs Doris compressed storage

FE="127.0.0.1"
PORT="9030"

echo "=========================================="
echo " Doris Compression Stats"
echo "=========================================="

# 1. Raw bytes from generator
RAW_BYTES=$(docker exec doris-data-generator cat /data/generator-stats.json 2>/dev/null | grep -o '"total_bytes": [0-9]*' | grep -o '[0-9]*')
RAW_ROWS=$(docker exec doris-data-generator cat /data/generator-stats.json 2>/dev/null | grep -o '"total_rows": [0-9]*' | grep -o '[0-9]*')

if [ -z "$RAW_BYTES" ] || [ "$RAW_BYTES" = "0" ]; then
    echo "No generator stats yet. Run 'make gen' first."
    exit 1
fi

# 2. Compressed size from Doris backend (MinIO Object Storage)
DORIS_BYTES=$(docker exec minio mc du myminio/doris-storage/doris_data --json 2>/dev/null | grep -o '"size":[0-9]*' | grep -o '[0-9]*')
if [ -z "$DORIS_BYTES" ]; then DORIS_BYTES="0"; fi
DORIS_ROWS=$(docker exec doris-fe-01 mysql -h $FE -P $PORT -uroot -N -e "SELECT COUNT(*) FROM events_db.events_stream;" 2>/dev/null | tr -d ' ')

# Convert raw bytes to MB
RAW_MB=$(awk "BEGIN {printf \"%.2f\", $RAW_BYTES / 1024 / 1024}")
DORIS_MB=$(awk "BEGIN {printf \"%.2f\", $DORIS_BYTES / 1024 / 1024}")

echo ""
echo "  📤 Raw CSV generated:    ${RAW_MB} MB  (${RAW_ROWS} rows)"
echo "  📦 Doris stored (MinIO): ${DORIS_MB} MB  (${DORIS_ROWS} rows)"

if [ -n "$DORIS_MB" ] && [ "$DORIS_MB" != "0.00" ] && [ "$DORIS_MB" != "0" ]; then
    RATIO=$(awk "BEGIN {printf \"%.1f\", $RAW_MB / $DORIS_MB}")
    SAVINGS=$(awk "BEGIN {printf \"%.1f\", (1 - ($DORIS_MB / $RAW_MB)) * 100}")
    echo ""
    echo "  🔥 Compression Ratio:    ${RATIO}x"
    echo "  💾 Storage Savings:      ${SAVINGS}%"
fi
echo ""
echo "=========================================="
