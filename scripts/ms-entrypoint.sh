#!/bin/bash
# Meta Service entrypoint - injects FDB cluster config then starts MS

set -e

FDB_CLUSTER="/var/fdb/fdb.cluster"
CONF="/opt/apache-doris/ms/conf/doris_cloud.conf"

# Wait for FDB to create its cluster file
echo "Waiting for FDB..."
until [ -f "$FDB_CLUSTER" ]; do sleep 1; done

# Read FDB cluster string and inject into config
CLUSTER=$(grep -v '^#' "$FDB_CLUSTER" | head -1)
echo "FDB cluster: $CLUSTER"

# Update config (bind mounts need copy→sed→write)
cp "$CONF" /tmp/doris_cloud.conf
sed "s|^fdb_cluster=.*|fdb_cluster=${CLUSTER}|" /tmp/doris_cloud.conf > "$CONF"

echo "Config updated, starting Meta Service..."
exec /opt/apache-doris/ms/bin/start.sh --console