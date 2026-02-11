#!/usr/bin/env python3
"""
Fake Event Generator for Apache Doris
Generates various event types and inserts them into Doris via MySQL protocol
"""

import pymysql
import time
import random
import os
from datetime import datetime
from faker import Faker

fake = Faker()

# Configuration from environment
DORIS_HOST = os.getenv('DORIS_FE_HOST', '172.20.80.2')
DORIS_PORT = int(os.getenv('DORIS_FE_PORT', '9030'))
DORIS_USER = os.getenv('DORIS_USER', 'root')
DORIS_PASSWORD = os.getenv('DORIS_PASSWORD', '')
EVENTS_PER_SECOND = int(os.getenv('EVENTS_PER_SECOND', '10'))

def get_connection():
    """Establish connection to Doris"""
    max_retries = 10
    for attempt in range(max_retries):
        try:
            conn = pymysql.connect(
                host=DORIS_HOST,
                port=DORIS_PORT,
                user=DORIS_USER,
                password=DORIS_PASSWORD,
                autocommit=True
            )
            print(f"✓ Connected to Doris at {DORIS_HOST}:{DORIS_PORT}")
            return conn
        except Exception as e:
            print(f"Connection attempt {attempt + 1}/{max_retries} failed: {e}")
            time.sleep(5)
    raise Exception("Could not connect to Doris after multiple attempts")

def init_database(conn):
    """Create database and tables if they don't exist"""
    cursor = conn.cursor()
    
    # Create database
    try:
        cursor.execute("CREATE DATABASE IF NOT EXISTS demo_db")
        print("✓ Database 'demo_db' ready")
    except Exception as e:
        print(f"Database creation: {e}")
    
    cursor.execute("USE demo_db")
    
    # Create user_events table
    create_table_sql = """
    CREATE TABLE IF NOT EXISTS user_events (
        event_id BIGINT,
        user_id INT,
        event_type VARCHAR(50),
        event_time DATETIME,
        page_url VARCHAR(200),
        device VARCHAR(50),
        city VARCHAR(100),
        country VARCHAR(100)
    )
    DUPLICATE KEY(event_id)
    DISTRIBUTED BY HASH(user_id) BUCKETS 10
    PROPERTIES (
        "replication_num" = "3"
    )
    """
    
    try:
        cursor.execute(create_table_sql)
        print("✓ Table 'user_events' ready")
    except Exception as e:
        print(f"Table creation: {e}")
    
    # Create purchase_events table
    create_purchase_table = """
    CREATE TABLE IF NOT EXISTS purchase_events (
        purchase_id BIGINT,
        user_id INT,
        product_name VARCHAR(200),
        category VARCHAR(100),
        price DECIMAL(10,2),
        quantity INT,
        purchase_time DATETIME,
        payment_method VARCHAR(50)
    )
    DUPLICATE KEY(purchase_id)
    DISTRIBUTED BY HASH(user_id) BUCKETS 10
    PROPERTIES (
        "replication_num" = "3"
    )
    """
    
    try:
        cursor.execute(create_purchase_table)
        print("✓ Table 'purchase_events' ready")
    except Exception as e:
        print(f"Purchase table creation: {e}")
    
    cursor.close()

def generate_user_event():
    """Generate a fake user event"""
    event_types = ['page_view', 'click', 'scroll', 'search', 'login', 'logout']
    devices = ['desktop', 'mobile', 'tablet']
    
    return {
        'event_id': random.randint(1000000, 9999999),
        'user_id': random.randint(1, 10000),
        'event_type': random.choice(event_types),
        'event_time': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'page_url': fake.url(),
        'device': random.choice(devices),
        'city': fake.city(),
        'country': fake.country()
    }

def generate_purchase_event():
    """Generate a fake purchase event"""
    categories = ['Electronics', 'Clothing', 'Books', 'Home', 'Sports', 'Food']
    payment_methods = ['credit_card', 'paypal', 'crypto', 'debit_card']
    
    return {
        'purchase_id': random.randint(1000000, 9999999),
        'user_id': random.randint(1, 10000),
        'product_name': fake.catch_phrase(),
        'category': random.choice(categories),
        'price': round(random.uniform(5.99, 999.99), 2),
        'quantity': random.randint(1, 5),
        'purchase_time': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'payment_method': random.choice(payment_methods)
    }

def insert_user_event(cursor, event):
    """Insert user event into Doris"""
    sql = """
    INSERT INTO user_events 
    (event_id, user_id, event_type, event_time, page_url, device, city, country)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    """
    cursor.execute(sql, (
        event['event_id'],
        event['user_id'],
        event['event_type'],
        event['event_time'],
        event['page_url'],
        event['device'],
        event['city'],
        event['country']
    ))

def insert_purchase_event(cursor, event):
    """Insert purchase event into Doris"""
    sql = """
    INSERT INTO purchase_events
    (purchase_id, user_id, product_name, category, price, quantity, purchase_time, payment_method)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    """
    cursor.execute(sql, (
        event['purchase_id'],
        event['user_id'],
        event['product_name'],
        event['category'],
        event['price'],
        event['quantity'],
        event['purchase_time'],
        event['payment_method']
    ))

def main():
    """Main event generation loop"""
    print("=" * 60)
    print("Doris Event Generator Starting...")
    print(f"Target: {DORIS_HOST}:{DORIS_PORT}")
    print(f"Rate: {EVENTS_PER_SECOND} events/second")
    print("=" * 60)
    
    conn = get_connection()
    init_database(conn)
    
    cursor = conn.cursor()
    event_count = 0
    
    print("\n Generating events... (Ctrl+C to stop)\n")
    
    try:
        while True:
            # Generate user events (70% of traffic)
            if random.random() < 0.7:
                event = generate_user_event()
                insert_user_event(cursor, event)
                event_count += 1
                print(f"[{event_count}] User Event: {event['event_type']} by user {event['user_id']}")
            
            # Generate purchase events (30% of traffic)
            else:
                event = generate_purchase_event()
                insert_purchase_event(cursor, event)
                event_count += 1
                print(f"[{event_count}] Purchase: {event['product_name'][:30]} - ${event['price']}")
            
            # Control rate
            time.sleep(1.0 / EVENTS_PER_SECOND)
            
    except KeyboardInterrupt:
        print(f"\n✓ Stopped. Total events generated: {event_count}")
    except Exception as e:
        print(f"\n✗ Error: {e}")
    finally:
        cursor.close()
        conn.close()

if __name__ == '__main__':
    main()
