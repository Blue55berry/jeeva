import sqlite3
import os

db_path = "registry.db"
if os.path.exists(db_path):
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    try:
        cursor.execute("ALTER TABLE global_registry ADD COLUMN status TEXT DEFAULT 'pending'")
        print("Status column added.")
    except sqlite3.OperationalError:
        print("Status column already exists.")
    
    # Also update existing admin blocks to 'approved'
    cursor.execute("UPDATE global_registry SET status = 'approved' WHERE phone_hash LIKE 'manual_block_%'")
    conn.commit()
    conn.close()
else:
    print("Database not found.")
