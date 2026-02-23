import requests
import time
import random
import io
import sys
import os
import logging
import base64
from datetime import datetime

# =============================
# Configuration
# =============================

DORIS_HOST = os.environ.get("DORIS_FE_HOST", "doris-fe-01")
DORIS_HTTP_PORT = int(os.environ.get("DORIS_HTTP_PORT", "8030"))
DORIS_USER = os.environ.get("DORIS_USER", "root")
DORIS_PASSWORD = os.environ.get("DORIS_PASSWORD", "")
DORIS_DB = os.environ.get("DORIS_DB", "events_db")
DORIS_TABLE = os.environ.get("DORIS_TABLE", "events_stream")

# Throughput settings
ROWS_PER_BATCH = int(os.environ.get("ROWS_PER_BATCH", "100000"))
FILES_PER_BATCH = int(os.environ.get("FILES_PER_BATCH", "3"))
SLEEP_SECONDS = int(os.environ.get("SLEEP_SECONDS", "10"))

# Retry settings
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
RETRY_DELAY = int(os.environ.get("RETRY_DELAY", "5"))

# Starting row ID
START_ROW_ID = int(os.environ.get("START_ROW_ID", "1000000"))

# =============================
# Setup Logging
# =============================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

# =============================
# HTTP Session (connection reuse)
# =============================

session = requests.Session()

# Doris Stream Load requires explicit Basic auth header
_auth_str = base64.b64encode(f"{DORIS_USER}:{DORIS_PASSWORD}".encode()).decode()
session.headers.update({"Authorization": f"Basic {_auth_str}"})

STREAM_LOAD_URL = f"http://{DORIS_HOST}:{DORIS_HTTP_PORT}/api/{DORIS_DB}/{DORIS_TABLE}/_stream_load"


# =============================
# Helper Functions
# =============================

def generate_csv_data(start_id: int) -> bytes:
    """Generate CSV data in memory and return as bytes."""
    buf = io.StringIO()
    for i in range(ROWS_PER_BATCH):
        row_id = start_id + i
        event_name = f"event{random.randint(1, 100)}"
        value = round(random.uniform(1, 10000), 2)
        user_id = random.randint(1, 100000)
        timestamp = int(time.time()) + random.randint(-86400, 86400)
        description = f"desc_{random.randint(1, 50000)}_event"
        buf.write(f"{row_id},{event_name},{value},{user_id},{timestamp},{description}\n")
    data = buf.getvalue().encode("utf-8")
    buf.close()
    return data


def stream_load(csv_data: bytes, label: str) -> bool:
    """Load data into Doris via Stream Load (HTTP PUT to FE)."""
    headers = {
        "label": label,
        "format": "csv",
        "column_separator": ",",
        "columns": "id, event, value, user_id, timestamp, description",
        "Expect": "100-continue",
    }

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            logger.info(f"[LOAD] Stream Load '{label}' (attempt {attempt}/{MAX_RETRIES})")

            # Step 1: PUT to FE — it returns 307 redirect to BE
            resp = session.put(
                STREAM_LOAD_URL,
                headers=headers,
                data=csv_data,
                timeout=300,
                allow_redirects=False,
            )

            # Step 2: Follow the redirect manually (preserves auth header)
            if resp.status_code == 307:
                be_url = resp.headers.get("Location")
                logger.info(f"[LOAD] Redirected to BE: {be_url}")
                resp = session.put(be_url, headers=headers, data=csv_data, timeout=300)

            result = resp.json()
            status = result.get("Status")

            if status == "Success":
                rows = result.get("NumberLoadedRows", "?")
                logger.info(f"[LOAD] '{label}' succeeded — {rows} rows loaded")
                return True
            elif status == "Label Already Exists":
                logger.warning(f"[LOAD] '{label}' already exists, skipping")
                return True
            else:
                msg = result.get("Message", "unknown error")
                logger.warning(f"[LOAD] '{label}' failed: {status} — {msg}")

        except requests.RequestException as e:
            logger.warning(f"[LOAD] Attempt {attempt}/{MAX_RETRIES} failed: {e}")

        if attempt < MAX_RETRIES:
            time.sleep(RETRY_DELAY)

    logger.error(f"[LOAD] '{label}' failed after {MAX_RETRIES} attempts")
    return False


def wait_for_doris(max_attempts: int = 30, delay: int = 5) -> bool:
    """Wait for Doris FE + table to be available via HTTP."""
    logger.info("Waiting for Doris to be ready...")
    for attempt in range(1, max_attempts + 1):
        try:
            resp = session.get(
                f"http://{DORIS_HOST}:{DORIS_HTTP_PORT}/api/bootstrap",
                timeout=5,
            )
            if resp.status_code == 200:
                logger.info("Doris Frontend is available")
                return True
        except requests.RequestException:
            pass
        logger.info(f"Attempt {attempt}/{max_attempts}: Doris not ready...")
        if attempt < max_attempts:
            time.sleep(delay)
    logger.error("Doris Frontend did not become available")
    return False


# =============================
# Main Loop
# =============================

def main():
    """Main data generation loop."""
    logger.info("=" * 50)
    logger.info("Data Generator Starting (Stream Load)")
    logger.info(f"Target: {DORIS_HOST}:{DORIS_HTTP_PORT}/{DORIS_DB}.{DORIS_TABLE}")
    logger.info(f"Batch: {ROWS_PER_BATCH} rows x {FILES_PER_BATCH} files")
    logger.info("=" * 50)

    if not wait_for_doris():
        logger.error("Doris not available. Exiting.")
        sys.exit(1)

    current_id = START_ROW_ID
    batch_count = 0

    try:
        while True:
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            batch_count += 1
            logger.info(f"\n[START BATCH #{batch_count}] {ts}")

            for file_index in range(FILES_PER_BATCH):
                label = f"stream_{ts}_{file_index}"

                try:
                    logger.info(f"Generating {ROWS_PER_BATCH} rows in memory...")
                    csv_data = generate_csv_data(current_id)
                    logger.info(f"Generated {len(csv_data) / 1024 / 1024:.1f} MB CSV")

                    success = stream_load(csv_data, label)
                    if not success:
                        logger.error(f"Failed to load batch {label}, continuing...")

                    current_id += ROWS_PER_BATCH

                except Exception as e:
                    logger.error(f"Error processing batch {label}: {e}")
                    continue

            logger.info(f"[BATCH #{batch_count}] Completed. Next row ID: {current_id}")
            logger.info(f"[SLEEP] Waiting {SLEEP_SECONDS} seconds...")
            time.sleep(SLEEP_SECONDS)

    except KeyboardInterrupt:
        logger.info("\n[SHUTDOWN] Received interrupt signal, stopping gracefully...")
        sys.exit(0)
    except Exception as e:
        logger.error(f"[FATAL] Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()