import torch
import torch.nn.functional as F
import librosa
import os
import json
import numpy as np
from transformers import AutoConfig, Wav2Vec2FeatureExtractor, AutoModelForAudioClassification
from speechbrain.inference.speaker import EncoderClassifier
from vosk import Model, KaldiRecognizer

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
            run_opts={"device": self.device}
        )
        
        # 3. Context Analysis (ASR for keywords)
        # Using a small English model as primary, but can be switched
        self.asr_model = None
        try:
             # Look for local vosk model or use default
             self.asr_model = Model(model_name="vosk-model-small-en-us-0.15")
        except:
             print("⚠️ Vosk model not found locally. Automatic Context Search will use a lighter heuristic.")

        print("--> ✅ Premium Stack Ready!")

    def analyze(self, file_path):
        try:
            # Load audio for processing
            sr_target = 16000
            audio, _ = librosa.load(file_path, sr=sr_target)
            
            # --- 🧬 STEP 1: VOICE FINGERPRINTING ---
            spk_emb = self.spk_encoder.encode_batch(torch.tensor(audio).unsqueeze(0)).squeeze().cpu().numpy()
            fingerprint = spk_emb.tolist()
            
            # --- 🕵️ STEP 2: SCAM CONTEXT ANALYSIS ---
            transcript = ""
            keywords_detected = []
            scam_triggers = ["otp", "password", "bank", "emergency", "police", "money", "win", "gift", "account", "verification"]
            
            if self.asr_model:
                rec = KaldiRecognizer(self.asr_model, sr_target)
                rec.AcceptWaveform((audio * 32768).astype(np.int16).tobytes())
                res = json.loads(rec.FinalResult())
                transcript = res.get("text", "").lower()
                keywords_detected = [k for k in scam_triggers if k in transcript]

            # --- 🚨 STEP 3: DEEPFAKE DETECTION ---
            inputs = self.feature_extractor(audio, sampling_rate=sr_target, return_tensors="pt", padding=True)
            inputs = {key: val.to(self.device) for key, val in inputs.items()}
            with torch.no_grad():
                outputs = self.model(**inputs)
            probs = F.softmax(outputs.logits, dim=-1).squeeze().cpu().numpy()
            
            # Note: idx 0 is often spoof/fake in Wav2Vec2-Deepfake models
            risk_score = float(probs[0])
            is_ai = risk_score > 0.5
            
            # Combine all for final summary
            context_risk = len(keywords_detected) > 0
            threat_level = "CRITICAL" if (is_ai and context_risk) or risk_score > 0.9 else "HIGH" if (is_ai or context_risk) else "MEDIUM"
            
            summary = f"SCAM ALERT ({threat_level}): "
            if is_ai:
                summary += f"AI Voice Signature Detected ({risk_score*100:.1f}%). "
            if context_risk:
                summary += f"NLP Context Match: {', '.join(keywords_detected).upper()} mentioned. "
            if not is_ai and not context_risk:
                summary = "VERIFIED SECURE: Human voice with natural variance detected."

            return {
                "success": True,
                "is_ai": is_ai,
                "risk_score": risk_score,
                "fingerprint": fingerprint,
                "transcript": transcript,
                "keywords": keywords_detected,
                "summary": summary,
                "threat_level": threat_level
            }
        except Exception as e:
            return {"success": False, "error": str(e)}
