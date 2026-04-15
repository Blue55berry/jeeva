import sqlite3
conn = sqlite3.connect("registry.db")
cursor = conn.cursor()
cursor.execute("SELECT phone_display, COUNT(*) FROM global_registry GROUP BY phone_display HAVING COUNT(*) > 1")
rows = cursor.fetchall()
if not rows:
    print("No duplicates found.")
else:
    for row in rows:
        print(f"Number: {row[0]}, Count: {row[1]}")
conn.close()
