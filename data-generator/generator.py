import boto3
import pymysql
import time
import random
import os
from datetime import datetime

# =============================
# Configuration
# =============================

MINIO_ENDPOINT = "http://minio:9000"
MINIO_ACCESS_KEY = "astro"
MINIO_SECRET_KEY = "Makeclean@123"
BUCKET_NAME = "fake-events"

DORIS_HOST = "doris-fe-01"
DORIS_PORT = 9030
DORIS_USER = "root"
DORIS_PASSWORD = ""
DORIS_DB = "events_db"
DORIS_TABLE = "events_s3load"

# Throughput settings: ingest 25GB compacted in ~1 hour
# Strategy: more columns + higher cardinality = less compressible = more actual stored data
# At 5:1 compression: need ~125GB raw CSV in 1 hour
ROWS_PER_BATCH = 500000  # 500K rows per file
FILES_PER_BATCH = 10     # 10 files per iteration = 5M rows per iteration
SLEEP_SECONDS = 5        # 5s between iterations

# =============================
# Setup S3 Client
# =============================

s3 = boto3.client(
    "s3",
    endpoint_url=MINIO_ENDPOINT,
    aws_access_key_id=MINIO_ACCESS_KEY,
    aws_secret_access_key=MINIO_SECRET_KEY,
)

# =============================
# Helper Functions
# =============================

def generate_csv(filename, start_id):
    with open(filename, "w") as f:
        print("generating file: " + filename)
        for i in range(ROWS_PER_BATCH):
            row_id = start_id + i
            event_name = f"event{random.randint(1,100)}"
            value = round(random.uniform(1, 10000), 2)
            user_id = random.randint(1, 100000)
            timestamp = int(time.time()) + random.randint(-86400, 86400)
            description = f"desc_{random.randint(1, 50000)}_event"
            f.write(f"{row_id},{event_name},{value},{user_id},{timestamp},{description}\n")


def upload_to_minio(filename):
    s3.upload_file(filename, BUCKET_NAME, filename)
    print(f"[UPLOAD] {filename} uploaded to MinIO")


def load_into_doris(filename, label):
    connection = pymysql.connect(
        host=DORIS_HOST,
        port=DORIS_PORT,
        user=DORIS_USER,
        password=DORIS_PASSWORD,
        database=DORIS_DB,
    )

    sql = f"""
    LOAD LABEL {DORIS_DB}.{label}
    (
        DATA INFILE("s3://{BUCKET_NAME}/{filename}")
        INTO TABLE {DORIS_TABLE}
        COLUMNS TERMINATED BY ","
        FORMAT AS "CSV"
        (id, event, value, user_id, timestamp, description)
    )
    WITH S3
    (
        "provider" = "S3",
        "s3.endpoint" = "{MINIO_ENDPOINT}",
        "s3.region" = "us-east-1",
        "s3.access_key" = "{MINIO_ACCESS_KEY}",
        "s3.secret_key" = "{MINIO_SECRET_KEY}",
        "use_path_style" = "true"
    )
    PROPERTIES
    (
        "timeout" = "3600"
    );
    """

    with connection.cursor() as cursor:
        cursor.execute(sql)

    connection.close()
    print(f"[LOAD] {filename} load triggered")


# =============================
# Main Loop
# =============================

current_id = 1000000

while True:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    print(f"\n[START BATCH] {timestamp} - rows_per_file={ROWS_PER_BATCH}, files={FILES_PER_BATCH}")

    for file_index in range(FILES_PER_BATCH):
        filename = f"events_{timestamp}_{file_index}.csv"
        label = f"batch_{timestamp}_{file_index}"

        generate_csv(filename, current_id)
        upload_to_minio(filename)
        load_into_doris(filename, label)

        current_id += ROWS_PER_BATCH

        try:
            os.remove(filename)
        except OSError:
            pass

    print(f"[SLEEP] Waiting {SLEEP_SECONDS} seconds...\n")
    time.sleep(SLEEP_SECONDS)
