"""
session_manager.py
------------------
Manages active call sessions for real-time AI/Human voice tracking.

Each call gets a unique session_id. As audio chunks stream in:
  1. Per-segment deepfake risk is recorded.
  2. Rolling EMA risk is updated (more weight to recent segments).
  3. Speaker fingerprints are compared to detect mid-call voice switching.
  4. All this is stored in `registry.db` for audit/replay.
"""

import uuid
import time
import json
import sqlite3
import numpy as np
from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class SegmentResult:
    segment_index: int
    risk_score: float
    is_ai: bool
    speaker_embedding: Optional[List[float]]
    speaker_similarity: float          # cosine sim vs previous segment (1.0 = same speaker)
    voice_switched: bool               # True if similarity drops below threshold
    pitch_hz: float
    frequency_variance: float
    spectral_centroid: float
    keywords: List[str]
    transcript: str
    threat_level: str
    timestamp: str


@dataclass
class CallSession:
    session_id: str
    phone_number: str
    start_time: str
    segments: List[SegmentResult] = field(default_factory=list)

    # Running state
    ema_risk: float = 0.0              # exponential moving average
    ema_alpha: float = 0.5            # weight for newest segment (0.5 = 50%)
    last_embedding: Optional[List[float]] = None
    voice_switch_count: int = 0
    is_active: bool = True

    # Final verdict (set on session end)
    final_verdict: Optional[str] = None
    final_risk_score: Optional[float] = None
    end_time: Optional[str] = None


# ---------------------------------------------------------------------------
# Singleton session manager
# ---------------------------------------------------------------------------

class SessionManager:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._sessions: Dict[str, CallSession] = {}
            cls._instance._init_db()
        return cls._instance

    # ---- DB helpers -------------------------------------------------------

    def _init_db(self):
        """Create the session/segment tables if they don't exist."""
        conn = sqlite3.connect("registry.db")
        cursor = conn.cursor()

        cursor.execute('''
            CREATE TABLE IF NOT EXISTS call_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL UNIQUE,
                phone_number TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time TEXT,
                final_verdict TEXT,
                final_risk_score REAL,
                segment_count INTEGER DEFAULT 0,
                voice_switch_count INTEGER DEFAULT 0
            )
        ''')

        cursor.execute('''
            CREATE TABLE IF NOT EXISTS segment_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                segment_index INTEGER NOT NULL,
                risk_score REAL NOT NULL,
                ema_risk REAL NOT NULL,
                is_ai INTEGER NOT NULL,
                speaker_similarity REAL,
                voice_switched INTEGER DEFAULT 0,
                pitch_hz REAL,
                frequency_variance REAL,
                spectral_centroid REAL,
                keywords TEXT,
                transcript TEXT,
                threat_level TEXT,
                timestamp TEXT NOT NULL
            )
        ''')

        conn.commit()
        conn.close()

    def _db_conn(self):
        return sqlite3.connect("registry.db")

    # ---- Session lifecycle ------------------------------------------------

    def start_session(self, phone_number: str) -> str:
        """Create a new call session, persist to DB, return session_id."""
        session_id = str(uuid.uuid4())
        start_time = time.strftime('%Y-%m-%dT%H:%M:%SZ')

        session = CallSession(
            session_id=session_id,
            phone_number=phone_number,
            start_time=start_time,
        )
        self._sessions[session_id] = session

        conn = self._db_conn()
        conn.execute(
            "INSERT INTO call_sessions (session_id, phone_number, start_time) VALUES (?, ?, ?)",
            (session_id, phone_number, start_time)
        )
        conn.commit()
        conn.close()

        print(f"[SessionManager] 📞 Session started: {session_id} for {phone_number}")
        return session_id

    def end_session(self, session_id: str) -> Dict[str, Any]:
        """Close a session, compute final verdict, persist to DB."""
        session = self._sessions.get(session_id)
        if not session:
            return {"success": False, "error": "Session not found"}

        session.is_active = False
        session.end_time = time.strftime('%Y-%m-%dT%H:%M:%SZ')

        # Final verdict = EMA risk at end of call
        final_risk = session.ema_risk
        if len(session.segments) == 0:
            final_risk = 0.0

        verdict = "ai_detected" if final_risk > 0.5 else "human_verified"
        if session.voice_switch_count >= 2:
            verdict = "ai_detected"   # Mid-call voice switch = strong AI signal

        session.final_verdict = verdict
        session.final_risk_score = final_risk

        conn = self._db_conn()
        conn.execute(
            """UPDATE call_sessions SET end_time=?, final_verdict=?, final_risk_score=?,
               segment_count=?, voice_switch_count=? WHERE session_id=?""",
            (session.end_time, verdict, final_risk,
             len(session.segments), session.voice_switch_count, session_id)
        )
        conn.commit()
        conn.close()

        print(f"[SessionManager] 🔚 Session ended: {session_id} | verdict={verdict} | risk={final_risk:.2f}")

        # Remove from memory after a short grace period
        del self._sessions[session_id]

        return {
            "success": True,
            "session_id": session_id,
            "final_verdict": verdict,
            "final_risk_score": final_risk,
            "segment_count": len(session.segments),
            "voice_switch_count": session.voice_switch_count,
            "end_time": session.end_time,
        }

    def get_session(self, session_id: str) -> Optional[CallSession]:
        return self._sessions.get(session_id)

    def get_session_status(self, session_id: str) -> Dict[str, Any]:
        session = self._sessions.get(session_id)
        if not session:
            # Try DB for completed sessions
            conn = self._db_conn()
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT * FROM call_sessions WHERE session_id=?", (session_id,)
            ).fetchone()
            conn.close()
            if row:
                return {"found": True, "is_active": False, **dict(row)}
            return {"found": False}

        return {
            "found": True,
            "is_active": session.is_active,
            "session_id": session.session_id,
            "phone_number": session.phone_number,
            "start_time": session.start_time,
            "ema_risk": session.ema_risk,
            "segment_count": len(session.segments),
            "voice_switch_count": session.voice_switch_count,
        }

    # ---- Per-segment update -----------------------------------------------

    def add_segment(self, session_id: str, result: Dict[str, Any]) -> Dict[str, Any]:
        """
        Called after each audio chunk is analyzed.
        Updates EMA risk, detects speaker switches, saves to DB.
        Returns enriched result with session-level context.
        """
        session = self._sessions.get(session_id)
        if not session:
            return {"success": False, "error": "Session not found or expired"}

        segment_index = len(session.segments)
        timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ')

        # --- Speaker switch detection ---
        current_embedding = result.get("fingerprint")
        speaker_similarity = 1.0
        voice_switched = False

        if current_embedding and session.last_embedding:
            curr = np.array(current_embedding)
            prev = np.array(session.last_embedding)
            norm_c = np.linalg.norm(curr)
            norm_p = np.linalg.norm(prev)
            if norm_c > 0 and norm_p > 0:
                speaker_similarity = float(np.dot(curr, prev) / (norm_c * norm_p))
                # Similarity < 0.70 = different speaker
                if speaker_similarity < 0.70:
                    voice_switched = True
                    session.voice_switch_count += 1
                    print(f"[SessionManager] 🔄 VOICE SWITCH DETECTED (sim={speaker_similarity:.2f})")

        if current_embedding:
            session.last_embedding = current_embedding

        # --- EMA risk update ---
        raw_risk = result.get("risk_score", 0.0)
        if segment_index == 0:
            session.ema_risk = raw_risk
        else:
            session.ema_risk = session.ema_alpha * raw_risk + (1 - session.ema_alpha) * session.ema_risk

        # --- Build segment record ---
        seg = SegmentResult(
            segment_index=segment_index,
            risk_score=raw_risk,
            is_ai=result.get("is_ai", False),
            speaker_embedding=current_embedding,
            speaker_similarity=speaker_similarity,
            voice_switched=voice_switched,
            pitch_hz=result.get("pitch_hz", 0.0),
            frequency_variance=result.get("frequency_variance_val", 0.0),
            spectral_centroid=result.get("spectral_centroid", 0.0),
            keywords=result.get("keywords", []),
            transcript=result.get("transcript", ""),
            threat_level=result.get("threat_level", "LOW"),
            timestamp=timestamp,
        )
        session.segments.append(seg)

        # --- Persist segment ---
        conn = self._db_conn()
        conn.execute(
            """INSERT INTO segment_results
               (session_id, segment_index, risk_score, ema_risk, is_ai,
                speaker_similarity, voice_switched, pitch_hz, frequency_variance,
                spectral_centroid, keywords, transcript, threat_level, timestamp)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                session_id, segment_index, raw_risk, session.ema_risk,
                1 if seg.is_ai else 0,
                speaker_similarity, 1 if voice_switched else 0,
                seg.pitch_hz, seg.frequency_variance, seg.spectral_centroid,
                json.dumps(seg.keywords), seg.transcript,
                seg.threat_level, timestamp,
            )
        )
        conn.commit()
        conn.close()

        # --- Return enriched response ---
        enriched = {
            **result,
            "session_id": session_id,
            "segment_index": segment_index,
            "ema_risk": session.ema_risk,
            "speaker_similarity": speaker_similarity,
            "voice_switched": voice_switched,
            "voice_switch_count": session.voice_switch_count,
            "segments_analyzed": len(session.segments),
        }

        # Determine enriched threat level
        if voice_switched or (session.ema_risk > 0.85 and session.voice_switch_count > 0):
            enriched["threat_level"] = "CRITICAL"
        elif session.ema_risk > 0.7:
            enriched["threat_level"] = "HIGH"

        return enriched

    def list_recent_sessions(self, limit: int = 20) -> List[Dict[str, Any]]:
        conn = self._db_conn()
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM call_sessions ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        conn.close()
        return [dict(r) for r in rows]

    def get_session_segments(self, session_id: str) -> List[Dict[str, Any]]:
        conn = self._db_conn()
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM segment_results WHERE session_id=? ORDER BY segment_index ASC",
            (session_id,)
        ).fetchall()
        conn.close()
        return [dict(r) for r in rows]
