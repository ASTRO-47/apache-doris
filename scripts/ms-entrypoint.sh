#!/bin/bash
set -e

CONF_FILE="/opt/apache-doris/ms/conf/doris_cloud.conf"
FDB_CLUSTER_FILE="/var/fdb/fdb.cluster"

# ── 1. Wait for FDB cluster file ──
echo "[ms-entrypoint] Waiting for FDB cluster file..."
until [ -f "$FDB_CLUSTER_FILE" ]; do
  sleep 1
done

# ── 2. Read FDB cluster string and inject into config ──
CLUSTER_STR=$(grep -v '^#' "$FDB_CLUSTER_FILE" | head -1)
echo "[ms-entrypoint] Found FDB cluster string: $CLUSTER_STR"

# sed -i doesn't work on bind-mounted files, so copy → sed → write back
cp "$CONF_FILE" /tmp/doris_cloud.conf
sed "s|^fdb_cluster=.*|fdb_cluster=${CLUSTER_STR}|" /tmp/doris_cloud.conf > "$CONF_FILE"
rm /tmp/doris_cloud.conf

echo "[ms-entrypoint] Updated config:"
cat "$CONF_FILE"

# ── 3. Set correct JAVA_HOME ──
export JAVA_HOME=/usr/lib/jvm/java

# ── 4. Start Meta Service ──
echo "[ms-entrypoint] Starting Meta Service..."
exec /opt/apache-doris/ms/bin/start.sh --console
