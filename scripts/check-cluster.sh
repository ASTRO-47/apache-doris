#!/bin/bash
# Quick script to test cluster health and failover

echo "=== Doris Cluster Health Check ==="
echo ""

MYSQL_CMD="mysql -h 127.0.0.1 -P 9030 -uroot --skip-column-names"

echo "Frontend Status:"
mysql -h 127.0.0.1 -P 9030 -uroot -e "SHOW PROC '/frontends';" | awk '{print $2, $3, $8, $9}'

echo ""
echo "Backend Status:"
mysql -h 127.0.0.1 -P 9030 -uroot -e "SHOW PROC '/backends';" | awk '{print $2, $3, $11}'

echo ""
echo "Table Row Counts:"
mysql -h 127.0.0.1 -P 9030 -uroot -e "SELECT table_name, COUNT(*) as row_count FROM demo_db.user_events GROUP BY table_name UNION ALL SELECT 'purchase_events', COUNT(*) FROM demo_db.purchase_events;" 2>/dev/null || echo "Tables not yet created"

echo ""
echo "=== Test Failover ==="
echo "Commands to test:"
echo "  docker stop doris-be-01    # Stop a backend"
echo "  docker start doris-be-01   # Restart it"
echo "  Watch cluster rebalance automatically!"
