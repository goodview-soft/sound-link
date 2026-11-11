#!/usr/bin/env python3
"""Sound Link : transcription locale (whisper, langue détectée automatiquement).
Serveur HTTP local : POST /transcribe (PCM s16le 16 kHz mono) -> JSON ; GET / = état."""
import io, json, os, shutil, subprocess, sys, tempfile, threading, wave
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4245
MODEL = sys.argv[2] if len(sys.argv) > 2 else "small"
JUNK = ("thanks for watching", "sous-titr", "merci d'avoir regardé", "subtitles by", "amara.org",
        "thank you for watching", "www.")

state = {"ready": False, "device": "", "error": ""}
lock = threading.Lock()
model = None


tr_lock = threading.Lock()
tr_failed = set()


def ensure_pair(a, b):
    """Installe (une fois) le paquet de traduction argos a -> b."""
    import argostranslate.package as ap
    import argostranslate.translate as at
    if any(l.code == a and any(t.to_lang.code == b for t in l.translations_from) for l in at.get_installed_languages()):
        return True
    if (a, b) in tr_failed:
        return False
    try:
        ap.update_package_index()
        pk = next((p for p in ap.get_available_packages() if p.from_code == a and p.to_code == b), None)
        if pk is None:
            tr_failed.add((a, b))
            return False
        ap.install_from_path(pk.download())
        return True
    except Exception:
        tr_failed.add((a, b))
        return False


def translate(text, src, target="fr"):
    """Traduction hors ligne vers le français (via l'anglais si besoin)."""
    if not text or src == target or not src:
        return ""
    try:
        import argostranslate.translate as at
        with tr_lock:
            if src == "en":
                ok = ensure_pair("en", target)
                steps = [("en", target)]
            else:
                ok = ensure_pair(src, target) or (ensure_pair(src, "en") and ensure_pair("en", target))
                steps = [(src, target)] if ensure_pair(src, target) else [(src, "en"), ("en", target)]
            if not ok:
                return ""
            out = text
            for a, b in steps:
                out = at.translate(out, a, b)
            return out.strip()
    except Exception:
        return ""


VOICES = {"fr": "fr_FR-siwis-medium", "en": "en_US-lessac-medium", "es": "es_ES-davefx-medium",
          "de": "de_DE-thorsten-medium", "it": "it_IT-paola-medium", "ru": "ru_RU-denis-medium"}
VDIR = Path(os.path.expanduser("~/.local/share/sound-link/voices"))
voices = {}
tts_lock = threading.Lock()


def tts(text, lang):
    """Synthèse vocale hors ligne (piper). La voix est téléchargée au premier usage."""
    from piper import PiperVoice
    name = VOICES.get(lang, VOICES["en"])
    with tts_lock:
        if name not in voices:
            if not (VDIR / (name + ".onnx")).exists():
                from piper.download_voices import download_voice
                VDIR.mkdir(parents=True, exist_ok=True)
                download_voice(name, VDIR)
            voices[name] = PiperVoice.load(str(VDIR / (name + ".onnx")))
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            voices[name].synthesize_wav(text, w)
    return buf.getvalue()


def transcribe(pcm, target):
    import numpy as np
    audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    if len(audio) < 8000:
        return {"text": "", "lang": "", "tr": ""}
    with lock:
        r = model.transcribe(audio, fp16=state["device"] == "cuda", temperature=0.0,
                             condition_on_previous_text=False, no_speech_threshold=0.5)
    segs = r.get("segments", [])
    text = r.get("text", "").strip()
    if not segs or all(s["no_speech_prob"] > 0.5 or s["avg_logprob"] < -1.3 for s in segs):
        text = ""
    if any(j in text.lower() for j in JUNK) and len(text) < 60:
        text = ""
    lang = r.get("language", "")
    return {"text": text, "lang": lang, "tr": translate(text, lang, target)}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(state)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        pcm = self.rfile.read(n)
        if self.path.startswith("/play"):  # rejoue un clip PCM 16 kHz sur les haut-parleurs du PC
            player = shutil.which("paplay") or shutil.which("pw-play") or shutil.which("aplay")
            if player and pcm:
                f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
                with wave.open(f, "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(16000)
                    w.writeframes(pcm)
                subprocess.Popen(["sh", "-c", '"$0" "$1"; rm -f "$1"', player, f.name],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self._send({"ok": bool(player)})
            return
        if self.path.startswith("/tts"):
            lang = parse_qs(urlparse(self.path).query).get("lang", ["fr"])[0]
            try:
                b = tts(pcm.decode("utf-8")[:500], lang)
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
            except Exception:
                b = b""
                self.send_response(500)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        target = parse_qs(urlparse(self.path).query).get("target", ["fr"])[0]
        try:
            self._send(transcribe(pcm, target))
        except Exception as e:
            self._send({"text": "", "lang": "", "tr": "", "error": str(e)})


def load():
    global model
    try:
        import torch, whisper
        state["device"] = "cuda" if torch.cuda.is_available() else "cpu"
        name = MODEL if state["device"] == "cuda" else "base"
        model = whisper.load_model(name, device=state["device"])
        state["ready"] = True
    except Exception as e:
        state["error"] = str(e)[:200]


if __name__ == "__main__":
    threading.Thread(target=load, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
