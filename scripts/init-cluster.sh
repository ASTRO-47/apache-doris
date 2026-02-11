#!/bin/bash
# Initialize Doris Cluster - Register FE Followers and BEs

echo "==================================="
echo "Doris Cluster Initialization Script"
echo "==================================="

# Wait for FE master to be ready
echo "Waiting for FE master to be ready..."
sleep 30

# Connect to master FE
MYSQL_CMD="mysql -h 172.20.80.2 -P 9030 -uroot"

echo ""
echo "Step 1: Adding FE Follower (fe-02)..."
$MYSQL_CMD -e "ALTER SYSTEM ADD FOLLOWER '172.20.80.3:9010';" 2>/dev/null
echo "✓ FE Follower added (or already exists)"

echo ""
echo "Step 2: Registering Backend nodes..."
$MYSQL_CMD -e "ALTER SYSTEM ADD BACKEND '172.20.80.4:9050';" 2>/dev/null
$MYSQL_CMD -e "ALTER SYSTEM ADD BACKEND '172.20.80.5:9050';" 2>/dev/null
$MYSQL_CMD -e "ALTER SYSTEM ADD BACKEND '172.20.80.6:9050';" 2>/dev/null
echo "✓ Backend nodes registered"

echo ""
echo "Step 3: Checking cluster status..."
echo ""
echo "--- Frontend Nodes ---"
$MYSQL_CMD -e "SHOW PROC '/frontends'\\G"

echo ""
echo "--- Backend Nodes ---"
$MYSQL_CMD -e "SHOW PROC '/backends'\\G"

echo ""
echo "==================================="
echo "✓ Cluster initialization complete!"
echo "==================================="
echo ""
echo "Access Doris:"
echo "  mysql -h 127.0.0.1 -P 9030 -uroot"
echo ""
echo "Web UI:"
echo "  http://localhost:8030"
echo ""
