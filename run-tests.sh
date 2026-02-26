#!/bin/bash

# Doris Query Monitoring Script
# This script runs a subset of queries from queries_tests.sql in a loop
# to monitor cluster health and ingestion progress.

FE_HOST="127.0.0.1"
FE_PORT="9030"
USER="root"
DB="events_db"

echo "=========================================================="
echo " Starting Doris Query Monitor (Ctrl+C to stop)"
echo " Connecting to $FE_HOST:$FE_PORT as $USER"
echo "=========================================================="

while true; do
    clear
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "Snapshot Time: $TIMESTAMP"
    echo "----------------------------------------------------------"
    
    echo "1. Current Row Count:"
    mysql -h $FE_HOST -P $FE_PORT -u$USER -D$DB -t -e "SELECT COUNT(*) AS total_rows FROM events_stream;"
    
    echo "2. Top 5 Events by Frequency:"
    mysql -h $FE_HOST -P $FE_PORT -u$USER -D$DB -t -e "SELECT event, COUNT(*) as cnt FROM events_stream GROUP BY event ORDER BY cnt DESC LIMIT 5;"
    
    echo "3. Data Ingestion Speed (Last 60s):"
    # This assumes timestamp is unix epoch in seconds
    NOW=$(date +%s)
    ONE_MIN_AGO=$((NOW - 60))
    mysql -h $FE_HOST -P $FE_PORT -u$USER -D$DB -t -e "SELECT COUNT(*) as rows_last_60s FROM events_stream WHERE timestamp > $ONE_MIN_AGO;"

    echo "4. Storage Status (Data in S3):"
    mysql -h $FE_HOST -P $FE_PORT -u$USER -D$DB -G -e "SHOW BACKENDS;" | grep -E "Alive|RemoteUsedCapacity|DataUsedCapacity"
    
    echo "----------------------------------------------------------"
    echo "Next refresh in 5 seconds..."
    sleep 5
done
