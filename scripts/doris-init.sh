#!/bin/sh
# Register Doris cloud instance + clusters in Meta Service (curl only, no docker)
set -e

MS="http://doris-ms:5000"
TOKEN="greedisgood9999"

echo "[init] Waiting for Meta Service..."
until curl -sf "${MS}/MetaService/http/version?token=${TOKEN}" 2>/dev/null | grep -q '"OK"'; do
  sleep 2
done
echo "[init] Meta Service ready"

echo "[init] Creating instance..."
curl -s "${MS}/MetaService/http/create_instance?token=${TOKEN}" \
  -d '{"instance_id":"doris_cluster","name":"doris_cluster","user_id":"user_1","obj_info":{"ak":"astro","sk":"Makeclean@123","bucket":"doris-storage","prefix":"doris_data","endpoint":"http://minio:9000","external_endpoint":"http://minio:9000","region":"us-east-1","provider":"S3","use_path_style":true}}'

echo ""
echo "[init] Registering FE cluster..."
curl -s "${MS}/MetaService/http/add_cluster?token=${TOKEN}" \
  -d '{"instance_id":"doris_cluster","cluster":{"cluster_name":"RESERVED_CLUSTER_NAME_FOR_SQL_SERVER","cluster_id":"RESERVED_CLUSTER_ID_FOR_SQL_SERVER","type":"SQL","nodes":[{"cloud_unique_id":"1:doris_cluster:fe-01","ip":"172.20.80.2","edit_log_port":9010,"node_type":"FE_MASTER"}]}}'

echo ""
echo "[init] Registering BE cluster (2 nodes)..."
curl -s "${MS}/MetaService/http/add_cluster?token=${TOKEN}" \
  -d '{"instance_id":"doris_cluster","cluster":{"cluster_name":"compute_cluster_0","cluster_id":"compute_cluster_id_0","type":"COMPUTE","nodes":[{"cloud_unique_id":"1:doris_cluster:be-01","ip":"172.20.80.4","heartbeat_port":9050},{"cloud_unique_id":"1:doris_cluster:be-02","ip":"172.20.80.5","heartbeat_port":9050}]}}'

echo ""
echo "[init] Done!"