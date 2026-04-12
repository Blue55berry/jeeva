"""
detector.py
-----------
PremiumScamDetector — core AI analysis engine.

Per chunk (3-7s of audio) it runs:
  1. Wav2Vec2 deepfake classification  → risk_score, is_ai
  2. SpeechBrain ECAPA speaker embedding → fingerprint (for cross-call ID & switch detection)
  3. Pitch analysis via librosa         → pitch_hz, pitch_label
  4. Spectral analysis                  → frequency_variance_val, spectral_centroid
  5. Vosk keyword ASR                   → transcript, keywords
  6. Combined threat level              → threat_level, summary
"""

import torch
import torch.nn.functional as F
import librosa
import os
import json
import numpy as np
import warnings
from transformers import AutoConfig, Wav2Vec2FeatureExtractor, AutoModelForAudioClassification
from speechbrain.inference.speaker import EncoderClassifier
from vosk import Model, KaldiRecognizer

# Suppress librosa's audioread and PySoundFile warnings for mp3/m4a wrappers
warnings.filterwarnings("ignore", category=UserWarning, module="librosa.core.audio")
warnings.filterwarnings("ignore", category=FutureWarning, module="librosa.core.audio")

class PremiumScamDetector:
    def __init__(self, model_name="MelodyMachine/Deepfake-audio-detection-V2"):
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        print(f"🧬 Loading Premium AI Stack on {self.device}")

        # 1. Deepfake Model (Wav2Vec2)
        self.config = AutoConfig.from_pretrained(model_name)
        self.feature_extractor = Wav2Vec2FeatureExtractor.from_pretrained(model_name)
        self.model = AutoModelForAudioClassification.from_pretrained(model_name).to(self.device).eval()

        # 2. Voice Fingerprinter (Speaker ID)
        self.spk_encoder = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb",
            run_opts={"device": str(self.device)}
        )

        # 3. Context Analysis (ASR for keywords)
        self.asr_model = None
        try:
            self.asr_model = Model(model_name="vosk-model-small-en-us-0.15")
        except Exception:
            print("⚠️ Vosk model not found locally. Keyword context will be skipped.")

        print("--> ✅ Premium Stack Ready!")

    # ------------------------------------------------------------------
    # Public: analyze a single audio file (chunk or full recording)
    # ------------------------------------------------------------------

    def analyze(self, file_path: str) -> dict:
        """
        Analyze an audio file/chunk and return the full result dict.
        """
        try:
            sr_target = 16000
            audio, _ = librosa.load(file_path, sr=sr_target)

            # Guard: reject very short audio (< 0.5s)
            if len(audio) < sr_target * 0.5:
                return {"success": False, "error": "Audio too short for analysis (< 0.5s)"}

            # ── 1. VOICE FINGERPRINTING ──────────────────────────────────
            spk_emb = (
                self.spk_encoder
                    .encode_batch(torch.tensor(audio).unsqueeze(0))
                    .squeeze()
                    .cpu()
                    .numpy()
            )
            fingerprint = spk_emb.tolist()

            # ── 2. PITCH ANALYSIS ────────────────────────────────────────
            pitch_hz, pitch_label, pitch_variance = self._analyze_pitch(audio, sr_target)

            # ── 3. SPECTRAL ANALYSIS ─────────────────────────────────────
            spectral_centroid, freq_variance_val, freq_variance_label = self._analyze_spectral(audio, sr_target)

            # ── 4. KEYWORD ASR ───────────────────────────────────────────
            transcript, keywords_detected = self._run_asr(audio, sr_target)

            # ── 5. DEEPFAKE DETECTION ────────────────────────────────────
            inputs = self.feature_extractor(
                audio, sampling_rate=sr_target, return_tensors="pt", padding=True
            )
            inputs = {k: v.to(self.device) for k, v in inputs.items()}

            with torch.no_grad():
                outputs = self.model(**inputs)

            probs = F.softmax(outputs.logits, dim=-1).squeeze().cpu().numpy()
            # idx=0 → spoof/fake in Wav2Vec2-Deepfake models
            risk_score = float(probs[0])
            is_ai = risk_score > 0.5

            # ── 6. COMBINED THREAT LEVEL & SUMMARY ──────────────────────
            context_risk = len(keywords_detected) > 0
            threat_level = self._compute_threat_level(risk_score, is_ai, context_risk)
            summary = self._build_summary(is_ai, risk_score, context_risk, keywords_detected, threat_level)

            return {
                "success": True,
                # Core detection
                "is_ai": is_ai,
                "risk_score": risk_score,
                "threat_level": threat_level,
                "summary": summary,
                # Speaker fingerprint (for cross-check & switch detection)
                "fingerprint": fingerprint,
                # Pitch
                "pitch_hz": pitch_hz,
                "pitch_analysis": pitch_label,
                "pitch_variance": pitch_variance,
                # Spectral / frequency
                "spectral_centroid": spectral_centroid,
                "frequency_variance_val": freq_variance_val,
                "frequency_variance": freq_variance_label,
                # ASR
                "transcript": transcript,
                "keywords": keywords_detected,
            }

        except Exception as e:
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    def _analyze_pitch(self, audio: np.ndarray, sr: int):
        """
        Extract fundamental frequency using librosa's YIN algorithm.
        Returns: (mean_hz: float, label: str, variance: float)
        """
        try:
            # pyin gives voiced/unvoiced probabilities alongside pitch
            f0, voiced_flag, _ = librosa.pyin(
                audio,
                fmin=librosa.note_to_hz("C2"),   # ~65 Hz
                fmax=librosa.note_to_hz("C7"),   # ~2093 Hz
                sr=sr,
                frame_length=2048,
            )
            # Only use voiced frames
            voiced_f0 = f0[voiced_flag] if voiced_flag is not None else f0
            voiced_f0 = voiced_f0[~np.isnan(voiced_f0)]

            if len(voiced_f0) == 0:
                return 0.0, "Insufficient Voice Signal", 0.0

            mean_hz = float(np.mean(voiced_f0))
            variance = float(np.var(voiced_f0))

            # Human voice: ~85–255 Hz male, ~165–255 Hz female
            # AI TTS: tends to have very low variance (<50) or unnatural range
            if variance < 50:
                label = f"Monotone ({mean_hz:.0f} Hz) — Synthetic signature"
            elif mean_hz < 80:
                label = f"Unnaturally Low ({mean_hz:.0f} Hz)"
            elif mean_hz > 350:
                label = f"Unnaturally High ({mean_hz:.0f} Hz)"
            else:
                label = f"Natural Dynamic ({mean_hz:.0f} Hz)"

            return mean_hz, label, variance

        except Exception as e:
            return 0.0, f"Pitch Error: {e}", 0.0

    def _analyze_spectral(self, audio: np.ndarray, sr: int):
        """
        Extract spectral centroid and spectral bandwidth (frequency variance proxy).
        Returns: (centroid_hz: float, variance_val: float, label: str)
        """
        try:
            centroid = librosa.feature.spectral_centroid(y=audio, sr=sr)
            bandwidth = librosa.feature.spectral_bandwidth(y=audio, sr=sr)

            mean_centroid = float(np.mean(centroid))
            mean_bandwidth = float(np.mean(bandwidth))
            variance_val = float(np.var(centroid))

            # AI voices often show narrow bandwidth = lower variance
            if variance_val < 50000:
                label = f"Narrow Spectrum ({mean_bandwidth:.0f} Hz BW) — Possible synthetic"
            else:
                label = f"Broad Natural Spectrum ({mean_bandwidth:.0f} Hz BW)"

            return mean_centroid, variance_val, label

        except Exception as e:
            return 0.0, 0.0, f"Spectral Error: {e}"

    def _run_asr(self, audio: np.ndarray, sr: int):
        """Run Vosk ASR for keyword context analysis."""
        scam_triggers = [
            "otp", "password", "bank", "emergency", "police", "money",
            "win", "gift", "account", "verification", "kyc", "transfer",
            "arrested", "suspicious", "block", "expired", "urgent",
        ]
        transcript = ""
        keywords_detected = []

        if self.asr_model:
            try:
                rec = KaldiRecognizer(self.asr_model, sr)
                rec.AcceptWaveform((audio * 32768).astype(np.int16).tobytes())
                res = json.loads(rec.FinalResult())
                transcript = res.get("text", "").lower()
                keywords_detected = [k for k in scam_triggers if k in transcript]
            except Exception as e:
                print(f"[Detector] ASR error: {e}")

        return transcript, keywords_detected

    def _compute_threat_level(self, risk_score: float, is_ai: bool, context_risk: bool) -> str:
        if risk_score > 0.90 or (is_ai and context_risk):
            return "CRITICAL"
        if risk_score > 0.65 or is_ai or context_risk:
            return "HIGH"
        if risk_score > 0.40:
            return "MEDIUM"
        return "LOW"

    def _build_summary(
        self, is_ai: bool, risk_score: float,
        context_risk: bool, keywords: list, threat_level: str
    ) -> str:
        if not is_ai and not context_risk:
            return "✅ VERIFIED SECURE: Human voice with natural variance detected."

        parts = [f"⚠️ SCAM ALERT ({threat_level}):"]
        if is_ai:
            parts.append(f" AI Voice Signature Detected ({risk_score*100:.1f}%).")
        if context_risk:
            parts.append(f" NLP Context Match: {', '.join(keywords).upper()} mentioned.")
        return " ".join(parts)
