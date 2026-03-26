import os
import shutil
import time
from fastapi import FastAPI, UploadFile, File, Security, HTTPException, status
from fastapi.security import APIKeyHeader
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import torchaudio
# Monkeypatch for speechbrain compatibility with modern torchaudio
if not hasattr(torchaudio, "list_audio_backends"):
    torchaudio.list_audio_backends = lambda: ["soundfile"]

from detector import PremiumScamDetector

app = FastAPI(title="AI Voice Interceptor Premium", version="2.0.0")

# Setup CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global model instance
detector = None

@app.on_event("startup")
async def startup_event():
    global detector
    print("\n--- Initializing PREMIUM AI Engine (Fingerprinting + NLP) ---")
    try:
        detector = PremiumScamDetector()
        print("--> PREMIUM STACK ACTIVE!")
    except Exception as e:
        print(f"--> [ERROR] Failed to load premium stack: {e}\n")


API_KEY_NAME = "x-api-key"
API_KEY = "voxshield_live_secure_v1"
api_key_header = APIKeyHeader(name=API_KEY_NAME, auto_error=False)

def get_api_key(api_key_header: str = Security(api_key_header)):
    if api_key_header == API_KEY:
        return api_key_header
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Could not validate credentials - Invalid API Key",
    )

import sqlite3
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# Initialize Registry DB
def init_db():
    conn = sqlite3.connect("registry.db")
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS global_registry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            phone_hash TEXT NOT NULL,
            phone_display TEXT NOT NULL,
            verdict TEXT NOT NULL,
            threat_level TEXT NOT NULL,
            risk_score REAL,
            audio_path TEXT,
            timestamp TEXT NOT NULL
        )
    ''')
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS scam_fingerprints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name_label TEXT,
            embedding_json TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            threat_count INTEGER DEFAULT 1
        )
    ''')
    conn.commit()
    conn.close()

init_db()

class ScamReport(BaseModel):
    phone_hash: str
    phone_display: str
    verdict: str
    threat_level: str
    risk_score: float

# serve static files (Dashboard UI)
app.mount("/static", StaticFiles(directory="static"), name="static")

@app.get("/")
async def root():
    from fastapi.responses import FileResponse
    return FileResponse("static/index.html")

from fastapi import Form
from typing import Optional

# serve uploaded audio files
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

@app.post("/blockchain/report/")
async def report_scam(
    phone_hash: str = Form(...),
    phone_display: str = Form(...),
    verdict: str = Form(...),
    threat_level: str = Form(...),
    risk_score: float = Form(...),
    file: Optional[UploadFile] = File(None),
    api_key: str = Security(get_api_key)
):
    saved_path = None
    if file:
        filename = f"report_{int(time.time())}_{file.filename}"
        saved_path = f"uploads/{filename}"
        with open(saved_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)

    conn = sqlite3.connect("registry.db")
    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO global_registry (phone_hash, phone_display, verdict, threat_level, risk_score, audio_path, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (phone_hash, phone_display, verdict, threat_level, risk_score, saved_path, time.strftime('%Y-%m-%dT%H:%M:%SZ'))
    )
    conn.commit()
    conn.close()
    return {"success": True, "message": "Scam reported with audio evidence!"}

@app.get("/blockchain/registry/")
async def get_registry():
    conn = sqlite3.connect("registry.db")
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM global_registry ORDER BY id DESC LIMIT 100")
    rows = cursor.fetchall()
    conn.close()
    return [dict(row) for row in rows]

@app.get("/blockchain/verify/")
async def verify_number(number: str):
    conn = sqlite3.connect("registry.db")
    cursor = conn.cursor()
    # Normalize
    clean = "".join(filter(str.isdigit, number))
    cursor.execute("SELECT COUNT(*), threat_level FROM global_registry WHERE phone_display LIKE ?", (f"%{clean}%",))
    count, level = cursor.fetchone()
    conn.close()
    return {
        "is_scam": count > 0,
        "report_count": count,
        "threat_level": level or "NONE"
    }

@app.post("/analyze/")
async def analyze_audio(file: UploadFile = File(...), api_key: str = Security(get_api_key)):
    if detector is None:
        return {"success": False, "error": "AI Model not loaded into memory."}

    temp_path = os.path.join("temp_audio", file.filename)
    os.makedirs("temp_audio", exist_ok=True)

    try:
        with open(temp_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        # 1. Premium AI Analysis
        res = detector.analyze(temp_path)
        if not res["success"]: return res

        # 2. Fingerprint Cross-Check
        conn = sqlite3.connect("registry.db")
        cursor = conn.cursor()
        cursor.execute("SELECT embedding_json, name_label FROM scam_fingerprints")
        known_scammers = cursor.fetchall()
        
        fingerprint_match = None
        current_emb = np.array(res["fingerprint"])
        
        for k_json, k_name in known_scammers:
            known_emb = np.array(json.loads(k_json))
            # Cosine similarity
            similarity = np.dot(current_emb, known_emb) / (np.linalg.norm(current_emb) * np.linalg.norm(known_emb))
            if similarity > 0.85: # Threshold for biometric match
                fingerprint_match = k_name
                break
        
        if fingerprint_match:
            res["summary"] = f"🔥 IDENTITY MATCH: {fingerprint_match.upper()} identified. " + res["summary"]
            res["threat_level"] = "CRITICAL"
            res["is_ai"] = True # Force high risk if fingerprint matches a known scammer

        # 3. Save as new fingerprint if risk is very high (Automatic Learning)
        if res["risk_score"] > 0.95 and not fingerprint_match:
            cursor.execute(
                "INSERT INTO scam_fingerprints (name_label, embedding_json, last_seen) VALUES (?, ?, ?)",
                (f"scammer_{int(time.time())}", json.dumps(res["fingerprint"]), time.strftime('%Y-%m-%dT%H:%M:%SZ'))
            )
            conn.commit()

        conn.close()
        return res
    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        if os.path.exists(temp_path): os.remove(temp_path)

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
