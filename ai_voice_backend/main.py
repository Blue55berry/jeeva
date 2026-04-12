"""
main.py
-------
VoxShield AI — FastAPI Backend v3.0

Endpoints:
  GET  /                          → Dashboard UI
  POST /analyze/                  → One-shot audio analysis (legacy / scanner tab)
  POST /session/start             → Start a real-time call session
  POST /session/{id}/analyze      → Analyze one audio chunk inside a session
  GET  /session/{id}/status       → Poll live session state
  POST /session/{id}/end          → Close session, get final verdict
  GET  /session/{id}/segments     → Full per-segment timeline
  GET  /sessions/recent           → List recent call sessions
  WS   /ws/session/{id}           → WebSocket for live push updates
  POST /blockchain/report/        → Report scam with optional audio evidence
  GET  /blockchain/registry/      → View global scam registry
  GET  /blockchain/verify/        → Check if a number is a known scammer
"""

import os
import shutil
import time
import json
import sqlite3
import numpy as np
from typing import Optional

from fastapi import (
    FastAPI, UploadFile, File, Security, HTTPException,
    status, Form, WebSocket, WebSocketDisconnect,
)
from fastapi.security import APIKeyHeader
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel
import uvicorn

import torchaudio
# Monkeypatch for speechbrain compatibility with modern torchaudio
if not hasattr(torchaudio, "list_audio_backends"):
    torchaudio.list_audio_backends = lambda: ["soundfile"]

import soundfile
if not hasattr(soundfile, "SoundFileRuntimeError"):
    soundfile.SoundFileRuntimeError = RuntimeError

from detector import PremiumScamDetector
from session_manager import SessionManager

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

app = FastAPI(title="VoxShield AI — Premium Voice Guard", version="3.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global singletons
detector: Optional[PremiumScamDetector] = None
session_mgr = SessionManager()   # Creates tables on first use

# Active WebSocket connections keyed by session_id
_ws_connections: dict[str, list[WebSocket]] = {}


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

@app.on_event("startup")
async def startup_event():
    global detector
    print("\n--- Initializing VoxShield AI Engine v3 ---")
    try:
        detector = PremiumScamDetector()
        print("--> PREMIUM STACK ACTIVE!")
    except Exception as e:
        print(f"--> [ERROR] Failed to load AI stack: {e}")


# ---------------------------------------------------------------------------
# API Key auth
# ---------------------------------------------------------------------------

API_KEY_NAME = "x-api-key"
API_KEY = "voxshield_live_secure_v1"
api_key_header = APIKeyHeader(name=API_KEY_NAME, auto_error=False)


def get_api_key(key: str = Security(api_key_header)):
    if key == API_KEY:
        return key
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Invalid API Key",
    )


# ---------------------------------------------------------------------------
# Database helpers (for legacy scam registry)
# ---------------------------------------------------------------------------

def init_legacy_db():
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
    
    # 🩹 AUTO-REPAIR: Ensure missing columns exist (for older databases)
    cursor.execute("PRAGMA table_info(global_registry)")
    columns = [col[1] for col in cursor.fetchall()]
    
    if 'risk_score' not in columns:
        print("🩹 [DB Repair] Adding missing 'risk_score' column to global_registry...")
        cursor.execute("ALTER TABLE global_registry ADD COLUMN risk_score REAL DEFAULT 0.0")
    
    if 'audio_path' not in columns:
        print("🩹 [DB Repair] Adding missing 'audio_path' column to global_registry...")
        cursor.execute("ALTER TABLE global_registry ADD COLUMN audio_path TEXT")
        
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


init_legacy_db()

# ---------------------------------------------------------------------------
# Static files / dashboard
# ---------------------------------------------------------------------------

app.mount("/static", StaticFiles(directory="static"), name="static")
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")


@app.get("/")
async def root():
    return FileResponse("static/index.html")


# ---------------------------------------------------------------------------
# Helper: push result to all WebSocket listeners for a session
# ---------------------------------------------------------------------------

async def _push_to_ws(session_id: str, data: dict):
    listeners = _ws_connections.get(session_id, [])
    dead = []
    for ws in listeners:
        try:
            await ws.send_json(data)
        except Exception:
            dead.append(ws)
    for ws in dead:
        listeners.remove(ws)


# ---------------------------------------------------------------------------
# WebSocket endpoint — Flutter subscribes here for real-time push
# ---------------------------------------------------------------------------

@app.websocket("/ws/session/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    await websocket.accept()
    _ws_connections.setdefault(session_id, []).append(websocket)
    print(f"[WS] Client connected to session {session_id}")
    try:
        while True:
            # Keep alive; analysis results are pushed FROM the HTTP endpoints
            await websocket.receive_text()
    except WebSocketDisconnect:
        _ws_connections.get(session_id, []).discard(websocket)
        print(f"[WS] Client disconnected from session {session_id}")


# ---------------------------------------------------------------------------
# Session management endpoints
# ---------------------------------------------------------------------------

class SessionStartRequest(BaseModel):
    phone_number: str = "Unknown"


@app.post("/session/start")
async def session_start(
    req: SessionStartRequest,
    api_key: str = Security(get_api_key),
):
    """
    Called by Flutter when a phone call begins.
    Returns a session_id to use for all subsequent chunk uploads.
    """
    session_id = session_mgr.start_session(req.phone_number)
    return {
        "success": True,
        "session_id": session_id,
        "phone_number": req.phone_number,
        "message": "Session started. Upload audio chunks to /session/{id}/analyze",
    }


@app.post("/session/{session_id}/analyze")
async def session_analyze_chunk(
    session_id: str,
    file: UploadFile = File(...),
    api_key: str = Security(get_api_key),
):
    """
    Receive a 3–7s audio chunk recorded during the call.
    Runs full AI analysis, updates session EMA risk, detects speaker switches.
    Pushes result via WebSocket to any listening Flutter clients.
    """
    if detector is None:
        return {"success": False, "error": "AI Model not loaded."}

    session = session_mgr.get_session(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail=f"Session '{session_id}' not found")

    os.makedirs("temp_audio", exist_ok=True)
    temp_path = os.path.join("temp_audio", f"seg_{session_id}_{int(time.time())}.wav")

    try:
        with open(temp_path, "wb") as buf:
            shutil.copyfileobj(file.file, buf)

        # Run AI analysis
        result = detector.analyze(temp_path)
        if not result.get("success"):
            return result

        # --- Fingerprint cross-check against known scammers ---
        conn = sqlite3.connect("registry.db")
        cursor = conn.cursor()
        cursor.execute("SELECT embedding_json, name_label FROM scam_fingerprints")
        known_scammers = cursor.fetchall()

        fingerprint_match = None
        if result.get("fingerprint"):
            current_emb = np.array(result["fingerprint"])
            for k_json, k_name in known_scammers:
                try:
                    known_emb = np.array(json.loads(k_json))
                    similarity = np.dot(current_emb, known_emb) / (
                        np.linalg.norm(current_emb) * np.linalg.norm(known_emb)
                    )
                    if similarity > 0.85:
                        fingerprint_match = k_name
                        break
                except Exception:
                    continue

        if fingerprint_match:
            result["summary"] = (
                f"🚨 IDENTITY MATCH: Known Scammer '{fingerprint_match.upper()}' identified via Voice Blueprint. " + result.get("summary", "")
            )
            result["risk_score"] = 1.0 # Force maximum risk score
            result["threat_level"] = "CRITICAL"
            result["is_ai"] = True
            result["identity_match"] = True
            print(f"[IdentityMatch] WARNING: Known scammer {fingerprint_match} detected!")

        # Auto-learn new scammer fingerprints
        if result.get("risk_score", 0) > 0.95 and not fingerprint_match and result.get("fingerprint"):
            cursor.execute(
                "INSERT INTO scam_fingerprints (name_label, embedding_json, last_seen) VALUES (?, ?, ?)",
                (f"scammer_{int(time.time())}", json.dumps(result["fingerprint"]),
                 time.strftime('%Y-%m-%dT%H:%M:%SZ'))
            )
            conn.commit()

        conn.close()

        # --- Update session (EMA + speaker switch) ---
        enriched = session_mgr.add_segment(session_id, result)

        # --- Push to WebSocket listeners ---
        await _push_to_ws(session_id, enriched)

        return enriched

    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


@app.get("/session/{session_id}/status")
async def session_status(session_id: str, api_key: str = Security(get_api_key)):
    """Poll the current state of an active call session."""
    status_data = session_mgr.get_session_status(session_id)
    if not status_data.get("found"):
        raise HTTPException(status_code=404, detail="Session not found")
    return status_data


@app.post("/session/{session_id}/end")
async def session_end(session_id: str, api_key: str = Security(get_api_key)):
    """
    Called by Flutter when the phone call ends.
    Closes the session and returns the final verdict.
    """
    result = session_mgr.end_session(session_id)
    if not result.get("success"):
        raise HTTPException(status_code=404, detail=result.get("error", "Session not found"))

    # Push final result to any open WebSocket
    await _push_to_ws(session_id, {"type": "session_ended", **result})
    return result


@app.get("/session/{session_id}/segments")
async def session_segments(session_id: str, api_key: str = Security(get_api_key)):
    """Return full per-segment timeline for a call session (for history/audit view)."""
    segments = session_mgr.get_session_segments(session_id)
    return {"session_id": session_id, "segments": segments}


@app.get("/sessions/recent")
async def recent_sessions(api_key: str = Security(get_api_key)):
    """List the 20 most recent call sessions."""
    return session_mgr.list_recent_sessions()


# ---------------------------------------------------------------------------
# Legacy one-shot endpoint (used by Scanner tab file upload)
# ---------------------------------------------------------------------------

@app.post("/analyze/")
async def analyze_audio(
    file: UploadFile = File(...),
    api_key: str = Security(get_api_key),
):
    """
    One-shot analysis for a full audio file (used by the manual scanner tab).
    Does not create a session — just returns the analysis result directly.
    """
    if detector is None:
        return {"success": False, "error": "AI Model not loaded into memory."}

    os.makedirs("temp_audio", exist_ok=True)
    temp_path = os.path.join("temp_audio", f"upload_{int(time.time())}_{file.filename}")

    try:
        with open(temp_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)

        result = detector.analyze(temp_path)
        if not result.get("success"):
            return result

        # Fingerprint cross-check
        conn = sqlite3.connect("registry.db")
        cursor = conn.cursor()
        cursor.execute("SELECT embedding_json, name_label FROM scam_fingerprints")
        known_scammers = cursor.fetchall()

        if result.get("fingerprint"):
            current_emb = np.array(result["fingerprint"])
            for k_json, k_name in known_scammers:
                try:
                    known_emb = np.array(json.loads(k_json))
                    sim = np.dot(current_emb, known_emb) / (
                        np.linalg.norm(current_emb) * np.linalg.norm(known_emb)
                    )
                    if sim > 0.85:
                        result["summary"] = (
                            f"🔥 IDENTITY MATCH: {k_name.upper()} identified. " + result.get("summary", "")
                        )
                        result["threat_level"] = "CRITICAL"
                        result["is_ai"] = True
                        break
                except Exception:
                    continue

        if result.get("risk_score", 0) > 0.95 and result.get("fingerprint"):
            cursor.execute(
                "INSERT OR IGNORE INTO scam_fingerprints (name_label, embedding_json, last_seen) VALUES (?, ?, ?)",
                (f"scammer_{int(time.time())}", json.dumps(result["fingerprint"]),
                 time.strftime('%Y-%m-%dT%H:%M:%SZ'))
            )
            conn.commit()

        conn.close()
        return result

    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


# ---------------------------------------------------------------------------
# Blockchain / scam registry endpoints
# ---------------------------------------------------------------------------

@app.post("/blockchain/report/")
async def report_scam(
    phone_hash: str = Form(...),
    phone_display: str = Form(...),
    verdict: str = Form(...),
    threat_level: str = Form(...),
    risk_score: float = Form(0.0),
    file: Optional[UploadFile] = File(None),
    api_key: str = Security(get_api_key),
):
    try:
        saved_path = None
        if file:
            os.makedirs("uploads", exist_ok=True)
            filename = f"report_{int(time.time())}_{file.filename}"
            saved_path = f"uploads/{filename}"
            with open(saved_path, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)

        conn = sqlite3.connect("registry.db")
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO global_registry
               (phone_hash, phone_display, verdict, threat_level, risk_score, audio_path, timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (phone_hash, phone_display, verdict, threat_level, risk_score,
             saved_path, time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
        )
        conn.commit()
        conn.close()
        print(f"✅ [Registry] New scam record committed: {phone_display}")
        return {"success": True, "message": "Scam reported successfully!"}
    except Exception as e:
        print(f"❌ [Registry Error] Internal Error: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Database Commit Failed: {str(e)}"
        )


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
    clean = "".join(filter(str.isdigit, number))
    cursor.execute(
        "SELECT COUNT(*), threat_level FROM global_registry WHERE phone_display LIKE ?",
        (f"%{clean}%",)
    )
    count, level = cursor.fetchone()
    conn.close()
    return {
        "is_scam": count > 0,
        "report_count": count,
        "threat_level": level or "NONE",
    }


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model_loaded": detector is not None,
        "active_sessions": len(session_mgr._sessions),
        "version": "3.0.0",
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
