#!/usr/bin/env python3
"""
Data Generator for Doris
Generates CSV data and streams it to Doris via HTTP (Stream Load).

Architecture:
  Generator -> HTTP -> Doris FE -> Redirect -> Doris BE -> MinIO (S3)
                                            (data stored in decoupled storage)
"""

import os
import time
import random
import io
import base64
import requests
import sys

# === CONFIG ===
DORIS_FE = os.environ.get("DORIS_FE_HOST", "doris-fe-01")
DORIS_PORT = int(os.environ.get("DORIS_HTTP_PORT", "8030"))
DB = os.environ.get("DORIS_DB", "events_db")
TABLE = os.environ.get("DORIS_TABLE", "events_stream")

ROWS_PER_BATCH = int(os.environ.get("ROWS_PER_BATCH", "50000"))
BATCHES_PER_ROUND = int(os.environ.get("BATCHES_PER_ROUND", "3"))
SLEEP_SECONDS = int(os.environ.get("SLEEP_SECONDS", "10"))

STATS_FILE = os.environ.get("STATS_FILE", "/tmp/generator-stats.json")

# === TRACKING ===
stats = {"total_bytes": 0, "total_rows": 0, "batches": 0}

def save_stats():
    with open(STATS_FILE, "w") as f:
        f.write(f'{{"total_bytes": {stats["total_bytes"]}, "total_rows": {stats["total_rows"]}, "batches": {stats["batches"]}}}\n')

def format_bytes(num):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if num < 1024:
            return f"{num:.1f}{unit}"
        num /= 1024
    return f"{num:.1f}TB"

# === AUTH ===
auth = base64.b64encode(f"root:".encode()).decode()
headers = {
    "Authorization": f"Basic {auth}",
    "Expect": "100-continue",
    "format": "csv",
    "column_separator": ",",
    "columns": "id,event,value,user_id,timestamp,description",
}

session = requests.Session()
session.headers.update(headers)


def generate_csv(start_id: int) -> bytes:
    """Generate CSV rows in memory."""
    buf = io.StringIO()
    for i in range(ROWS_PER_BATCH):
        buf.write(f"{start_id + i},event{random.randint(1,100)},"
                  f"{random.uniform(1,10000):.2f},"
                  f"{random.randint(1,100000)},"
                  f"{int(time.time()) + random.randint(-86400,86400)},"
                  f"desc_{random.randint(1,50000)}\n")
    return buf.getvalue().encode()


def stream_load(data: bytes, label: str) -> bool:
    """Send data to Doris via Stream Load."""
    global stats
    url = f"http://{DORIS_FE}:{DORIS_PORT}/api/{DB}/{TABLE}/_stream_load"

    try:
        resp = session.put(url, headers={"label": label, **headers},
                          data=data, timeout=300, allow_redirects=False)

        # Doris redirects to BE for actual storage
        if resp.status_code == 307:
            resp = session.put(resp.headers["Location"],
                             headers=headers, data=data, timeout=300)

        result = resp.json()
        if result.get("Status") == "Success":
            rows = result.get("NumberLoadedRows", 0)
            print(f"  [OK] {label}: {rows} rows, {format_bytes(len(data))}")
            stats["total_bytes"] += len(data)
            stats["total_rows"] += rows
            stats["batches"] += 1
            save_stats()
            return True
        else:
            print(f"  [FAIL] {label}: {result.get('Message')}")
    except Exception as e:
        print(f"  [ERROR] {label}: {e}")
    return False


def wait_for_doris() -> bool:
    """Wait for Doris FE to be ready."""
    print("Waiting for Doris...")
    for i in range(30):
        try:
            resp = session.get(f"http://{DORIS_FE}:{DORIS_PORT}/api/bootstrap", timeout=5)
            if resp.status_code == 200:
                print("Doris ready!")
                return True
        except:
            pass
        time.sleep(2)
    print("Doris not available")
    return False


def main():
    print("=== Data Generator ===")
    print(f"Target: {DORIS_FE}:{DORIS_PORT}/{DB}.{TABLE}")
    print(f"Batch: {ROWS_PER_BATCH} rows x {BATCHES_PER_ROUND} files")
    print(f"Stats file: {STATS_FILE}\n")

    if not wait_for_doris():
        sys.exit(1)

    row_id = 1
    while True:
        print(f"[BATCH] {ROWS_PER_BATCH * BATCHES_PER_ROUND} rows...")
        for i in range(BATCHES_PER_ROUND):
            label = f"stream_{int(time.time())}_{i}"
            data = generate_csv(row_id)
            stream_load(data, label)
            row_id += ROWS_PER_BATCH

        print(f"[STATS] Total: {format_bytes(stats['total_bytes'])}, {stats['total_rows']} rows, {stats['batches']} batches")
        print(f"[SLEEP] {SLEEP_SECONDS}s\n")
        time.sleep(SLEEP_SECONDS)


if __name__ == "__main__":
    main()