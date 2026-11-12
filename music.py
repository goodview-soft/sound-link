#!/usr/bin/env python3
"""Moteur Musique de Sound Link : lien YouTube -> mp3 + paroles (lrclib) -> micro virtuel ; paroles tapées dans le chat du jeu.
Lancé par sound-link.sh ; l'appli Godot le pilote en HTTP sur 127.0.0.1:4245."""
import json, os, re, shutil, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4245
asst = {"ptt": "MAJ", "chatkey": "!"}


KEY_ALIASES = {"maj": "Shift_L", "shift": "Shift_L", "ctrl": "Control_L", "alt": "Alt_L", "espace": "space",
               "entrée": "Return", "entree": "Return", "tab": "Tab"}


def _keysym(name):
    from Xlib import XK
    if len(name) == 1:  # un caractère : son keysym est son code (Latin-1) ou 0x1000000 + Unicode
        return ord(name) if ord(name) <= 0xFF else 0x1000000 + ord(name)
    name = name.strip()
    return XK.string_to_keysym(KEY_ALIASES.get(name.lower(), name))


def plan_key(d, name):
    """Séquence de touches pour un nom ou un caractère : [(keycode, modificateur ou None)]."""
    from Xlib import XK
    sym = _keysym(name)
    if not sym:
        return None
    for code, idx in d.keysym_to_keycodes(sym):
        mod = {0: None, 1: "Shift_L", 2: "ISO_Level3_Shift", 3: "ISO_Level3_Shift"}.get(idx)
        return code, (d.keysym_to_keycode(XK.string_to_keysym(mod)) if mod else None)
    return None


def tap(d, plan, hold=0.02):
    from Xlib import X
    from Xlib.ext import xtest
    code, mod = plan
    if mod:
        xtest.fake_input(d, X.KeyPress, mod)
    xtest.fake_input(d, X.KeyPress, code)
    xtest.fake_input(d, X.KeyRelease, code)
    if mod:
        xtest.fake_input(d, X.KeyRelease, mod)
    d.sync()
    time.sleep(hold)


def press_ptt(down):
    """Maintient / relâche la touche push-to-talk du jeu (X11 XTEST) : MAJ par défaut."""
    key = asst["ptt"].strip()
    if not key:
        return
    try:
        from Xlib import X, display
        from Xlib.ext import xtest
        d = display.Display()
        sym = _keysym(key)
        code = d.keysym_to_keycode(sym)
        if code:
            xtest.fake_input(d, X.KeyPress if down else X.KeyRelease, code)
            d.sync()
    except Exception:
        pass


def write_in_game_chat(text, key=None, minlen=3):
    """Ouvre le chat du jeu (touche « ! »), tape le texte, valide avec Entrée. Seuls les caractères présents
    sur le clavier sont tapés (pas de cyrillique sur une disposition française)."""
    import unicodedata
    from Xlib import display
    d = display.Display()
    plans = []
    opener = plan_key(d, key or asst["chatkey"] or "!")
    if not opener:
        return
    for ch in unicodedata.normalize("NFKC", text):
        pl = plan_key(d, ch if ch != " " else "space")
        if pl is None and ch.isalpha():  # lettre accentuée absente : on tente sans accent
            base = unicodedata.normalize("NFKD", ch)[0]
            pl = plan_key(d, base)
        if pl:
            plans.append(pl)
    if len(plans) < minlen:
        return
    tap(d, opener, 0.25)
    for pl in plans:
        tap(d, pl, 0.025)
    tap(d, plan_key(d, "Return"), 0.1)



# ---------------------------------------------------------------- Musique : fichier YouTube -> micro virtuel + paroles (LRC) dans le chat
MDIR = os.path.expanduser("~/.local/share/sound-link/music")
music = {"sel": "", "playing": "", "status": "", "write": True, "ptt": True, "local": True, "stop": threading.Event(), "proc": None}


def music_tracks():
    res = []
    try:
        for f in sorted(os.listdir(MDIR), key=lambda f: -os.path.getmtime(os.path.join(MDIR, f))):
            if f.endswith(".json"):
                m = json.load(open(os.path.join(MDIR, f)))
                m["lrc"] = os.path.exists(os.path.join(MDIR, m["id"] + ".lrc"))
                res.append(m)
    except Exception:
        pass
    return res


def music_state():
    return {"tracks": music_tracks(), "sel": music["sel"], "playing": music["playing"], "status": music["status"],
            "write": music["write"], "ptt": music["ptt"]}


def fetch_lrc(title, artist, dur):
    """Paroles synchronisées depuis lrclib.net (gratuit, sans clé). Renvoie le texte LRC ou ''."""
    import urllib.parse
    title = title.split("|")[0]
    clean = re.sub(r"[\(\[][^\)\]]*[\)\]]|official|video|lyrics|audio|\bhd\b|\b4k\b", " ", title, flags=re.I)
    track = clean.strip()
    if " - " in clean:
        a, t = [x.strip() for x in clean.split(" - ", 1)]
        artist, track = (artist or a), t
    words = [w for w in re.findall(r"\w+", (artist or "").lower()) if len(w) > 2]
    qs = ["search?track_name=%s&artist_name=%s" % (urllib.parse.quote(track), urllib.parse.quote(artist or "")),
          "search?q=" + urllib.parse.quote((artist + " " + track).strip()),
          "search?q=" + urllib.parse.quote(track)]
    for q in qs:
        try:
            req = urllib.request.Request("https://lrclib.net/api/" + q, headers={"User-Agent": "sound-link"})
            with urllib.request.urlopen(req, timeout=15) as r:
                for it in json.load(r):
                    who = (it.get("artistName") or "").lower()
                    if (it.get("syncedLyrics") and (not dur or abs((it.get("duration") or dur) - dur) < 8)
                            and (not words or any(w in who or w in (it.get("trackName") or "").lower() for w in words))):
                        return it["syncedLyrics"]
        except Exception:
            pass
    return ""


def music_download(url):
    music["status"] = "Téléchargement…"
    try:
        os.makedirs(MDIR, exist_ok=True)
        ytdlp = shutil.which("yt-dlp") or os.path.expanduser("~/.local/bin/yt-dlp")
        out = subprocess.run([ytdlp, "-x", "--audio-format", "mp3", "--no-playlist", "--no-simulate", "-o", MDIR + "/%(id)s.%(ext)s",
                              "--print", "%(id)s\t%(title)s\t%(artist)s\t%(duration)s", url],
                             capture_output=True, text=True, timeout=600)
        line = [l for l in out.stdout.splitlines() if l.count("\t") == 3]
        if out.returncode or not line:
            raise RuntimeError((out.stderr.strip().splitlines() or ["échec"])[-1][:100])
        vid, title, artist, dur = line[-1].split("\t")
        artist = "" if artist == "NA" else artist
        dur = float(dur) if dur not in ("NA", "") else 0.0
        music["status"] = "Recherche des paroles…"
        lrc = fetch_lrc(title, artist, dur)
        if lrc:
            open(os.path.join(MDIR, vid + ".lrc"), "w").write(lrc)
        json.dump({"id": vid, "title": title, "artist": artist, "dur": dur}, open(os.path.join(MDIR, vid + ".json"), "w"))
        music["sel"] = vid
        music["status"] = "Prêt : %s%s" % (title, "" if lrc else " (pas de paroles synchronisées trouvées)")
    except Exception as ex:
        music["status"] = "Erreur : %s" % str(ex)[:100]


def parse_lrc(text):
    res = []
    for ln in text.splitlines():
        stamps = re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", ln)
        txt = re.sub(r"\[[^\]]*\]", "", ln).strip()
        for m, sec in stamps:
            res.append((int(m) * 60 + float(sec), txt))
    return sorted(res)


def music_play(vid):
    vid = os.path.basename(vid)
    f = os.path.join(MDIR, vid + ".mp3")
    if not os.path.exists(f) or music["playing"]:
        return
    music["sel"] = vid
    music["stop"].clear()
    music["playing"] = vid
    lrc = os.path.join(MDIR, vid + ".lrc")
    lines = parse_lrc(open(lrc).read()) if os.path.exists(lrc) else []

    def run():
        proc = None
        try:
            sink = subprocess.run(["pactl", "list", "short", "sinks"], capture_output=True, text=True).stdout
            env = dict(os.environ, **({"PULSE_SINK": "soundlink_sink"} if "soundlink_sink" in sink else {}))
            if music["ptt"]:
                press_ptt(True)
                time.sleep(0.2)
            music["status"] = "Lecture (F9 pour arrêter)"
            proc = subprocess.Popen(["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", f], env=env)
            music["proc"] = proc
            if music["local"]:  # on l'entend aussi sur les enceintes
                loc = subprocess.Popen(["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", f])
                music["loc"] = loc
            t0 = time.time() + 0.3  # démarrage de ffplay
            if music["write"]:
                for ts, txt in lines:
                    while time.time() - t0 < ts:
                        if music["stop"].is_set() or proc.poll() is not None:
                            return
                        time.sleep(0.05)
                    if music["stop"].is_set() or proc.poll() is not None:
                        return
                    if not txt or time.time() - t0 - ts > 4:  # ligne vide ou déjà trop en retard
                        continue
                    try:
                        write_in_game_chat(txt[:120], "Return", 1)  # Entrée, la ligne, Entrée
                        if music["ptt"]:
                            press_ptt(True)  # une majuscule a relâché MAJ
                    except Exception:
                        pass
            while proc.poll() is None and not music["stop"].is_set():
                time.sleep(0.2)
        finally:
            if proc and proc.poll() is None:
                proc.terminate()
            loc = music.get("loc")
            if loc and loc.poll() is None:
                loc.terminate()
            if music["ptt"]:
                press_ptt(False)
            music["playing"] = ""
            music["proc"] = None
            music["status"] = "Arrêté"
    threading.Thread(target=run, daemon=True).start()


def music_stop():
    music["stop"].set()
    p = music["proc"]
    if p and p.poll() is None:
        p.terminate()
    loc = music.get("loc")
    if loc and loc.poll() is None:
        loc.terminate()


def music_toggle():
    if music["playing"]:
        music_stop()
    elif music["sel"]:
        music_play(music["sel"])


def hotkey_loop():
    """Touche globale F9 (X11) : lance / arrête la musique, même quand le jeu a le focus."""
    try:
        from Xlib import X, XK, display
        d = display.Display()
        root = d.screen().root
        code = d.keysym_to_keycode(XK.string_to_keysym("F9"))
        for m in (0, X.LockMask, X.Mod2Mask, X.LockMask | X.Mod2Mask):
            root.grab_key(code, m, True, X.GrabModeAsync, X.GrabModeAsync)
        d.sync()
        while True:
            ev = d.next_event()
            if ev.type == X.KeyPress and ev.detail == code:
                music_toggle()
    except Exception:
        pass



class Api(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def json(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.json(music_state())

    def do_POST(self):
        q = parse_qs(urlparse(self.path).query)
        if "url" in q:
            threading.Thread(target=music_download, args=(q["url"][0],), daemon=True).start()
        if "sel" in q:
            music["sel"] = q["sel"][0]
        if "play" in q:
            music_play(q["play"][0])
        if "stop" in q:
            music_stop()
        if "toggle" in q:
            music_toggle()
        if "del" in q:
            vid = os.path.basename(q["del"][0])
            for ext in (".mp3", ".json", ".lrc"):
                try:
                    os.unlink(os.path.join(MDIR, vid + ext))
                except OSError:
                    pass
        if "write" in q:
            music["write"] = q["write"][0] == "1"
        if "local" in q:
            music["local"] = q["local"][0] == "1"
        if "ptt" in q:
            music["ptt"] = q["ptt"][0] == "1"
        return self.json({"ok": True})


if __name__ == "__main__":
    threading.Thread(target=hotkey_loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", API_PORT), Api).serve_forever()
