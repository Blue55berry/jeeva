# AI Voice Interceptor Backend

This is the Python FastAPI backend engine responsible for analyzing Audio Files (Wav, MP3, M4A) and predicting whether the voice is biologically Real or Synthetically AI-Generated (Deepfake) using Huggingface's active `.Wav2Vec2` Transformers.

## Features
- **FastAPI Endpoint Framework**: Ultra-fast REST endpoints for mobile app connectivity.
- **HuggingFace Pipeline**: Downloads and executes the `Hemgg/Deepfake-detection-Using-Wav2Vec2` model locally on your hardware.
- **Librosa & PyTorch Extraction**: Resamples audio, generates features and processes gradients through CUDA (or CPU) securely.

## Prerequisites
To run this application, make sure you have Python 3.9+ installed natively.

1. **Install python requirements**:
   ```bash
   pip install -r requirements.txt
   ```

2. **Start the Fast API Web Server**:
   ```bash
   python main.py
   ```
   Or explicitly using: `uvicorn main:app --host 0.0.0.0 --port 8000`

## Connecting your Flutter App!
Because you are running the Flutter App natively on your **POCO X2**, you **cannot** use `localhost` or `127.0.0.1`. You must find your laptop/desktop's IPv4 address on your WiFi network. 
- Open Command Prompt and type `ipconfig`. Find `IPv4 Address`. (e.g. `192.168.1.155`).
- Update the API URL inside `lib/screens/scanner_view.dart` `_pickAudioFile` method!
