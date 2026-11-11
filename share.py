#!/usr/bin/env python3
"""Sound Link : capture d'une fenêtre (X11) et diffusion en JPEG.
 - 127.0.0.1:PORT : API locale de l'appli (GET /windows, POST /share?win=0x..&h=720, POST /share?stop=1)
 - 0.0.0.0:4246   : image de la fenêtre partagée (aperçu du host et clients), 404 si rien n'est partagé."""
import base64, difflib, io, json, os, re, shutil, subprocess, sys, tempfile, threading, time, urllib.request, wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4245
FRAME_PORT = 4246
cond = threading.Condition()
st = {"proc": None, "frame": b"", "seq": 0, "mode": "window", "win": "", "h": 720}


def list_windows():
    try:
        out = subprocess.run(["wmctrl", "-lG"], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return []
    res = []
    for ln in out.splitlines():
        p = ln.split(None, 7)
        if len(p) < 8:
            continue
        wid, desk, _x, _y, w, h, _host, title = p
        if desk == "-1" or int(w) < 200 or int(h) < 150 or title.strip() in ("Bureau", "Desktop"):
            continue
        res.append({"id": wid, "title": title.strip(), "w": int(w), "h": int(h)})
    return res


def geometry(win):
    """Position absolue et taille de la fenêtre (xwininfo)."""
    out = subprocess.run(["xwininfo", "-id", win], capture_output=True, text=True, timeout=3).stdout
    g = {k: int(re.search(k + r":\s+(-?\d+)", out).group(1)) for k in ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height")}
    return g["Absolute upper-left X"], g["Absolute upper-left Y"], g["Width"] // 2 * 2, g["Height"] // 2 * 2


def is_black(frame):
    try:
        from PIL import Image, ImageStat
        im = Image.open(io.BytesIO(frame)).convert("L").resize((64, 36))
        return ImageStat.Stat(im).mean[0] < 3 and ImageStat.Stat(im).stddev[0] < 3
    except Exception:
        return False


def stop():
    p, st["proc"] = st["proc"], None
    if p:
        try:
            p.kill()
        except Exception:
            pass
    with cond:
        st["frame"] = b""
        st["seq"] += 1
        cond.notify_all()


def _read(p):
    buf = b""
    n = black = 0
    while True:
        chunk = p.stdout.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            a = buf.find(b"\xff\xd8")
            if a < 0:
                buf = b""
                break
            b = buf.find(b"\xff\xd9", a + 2)
            if b < 0:
                buf = buf[a:]
                break
            frame, buf = buf[a:b + 2], buf[b + 2:]
            n += 1
            if st["mode"] == "window" and n <= 10:
                black += is_black(frame)
                if n == 10 and black >= 9:  # capture directe noire (jeu plein écran / Vulkan) : on filme la zone d'écran
                    threading.Thread(target=start, args=(st["win"], st["h"], "region"), daemon=True).start()
            with cond:
                st["frame"] = frame
                st["seq"] += 1
                cond.notify_all()
    if st["proc"] is p:
        stop()


def start(win, height, mode="window"):
    stop()
    st.update(mode=mode, win=win, h=height)
    src = ["-window_id", str(int(win, 16)), "-i", os.environ.get("DISPLAY", ":0")]
    if mode == "region":
        x, y, w, h = geometry(win)
        src = ["-video_size", "%dx%d" % (w, h), "-i", "%s+%d,%d" % (os.environ.get("DISPLAY", ":0"), x, y)]
    cmd = ["ffmpeg", "-loglevel", "error", "-f", "x11grab", "-framerate", "12"] + src + [
        "-vf", "scale=-2:%d" % height, "-q:v", "6", "-f", "image2pipe", "-vcodec", "mjpeg", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    st["proc"] = p
    threading.Thread(target=_read, args=(p,), daemon=True).start()


# ---------------------------------------------------------------- Lecture des cadres (OCR)
regions = {"players": None, "chat": None}  # (x, y, w, h) normalisés dans l'image partagée
players = {}  # pseudo -> dernier instant vu
chat = []     # {id, text, norm, seen}
chat_next = [1]
_ocr = []
TESSDIR = os.path.expanduser("~/.local/share/sound-link/tessdata")
LANGS = "eng"


def setup_tessdata():
    """Prépare le dossier de langues (anglais, français, russe) utilisé par Tesseract."""
    import glob, urllib.request
    os.makedirs(TESSDIR, exist_ok=True)
    for src in glob.glob("/usr/share/tesseract-ocr/*/tessdata") + ["/usr/share/tessdata"]:
        for f in ("eng.traineddata", "fra.traineddata"):
            if os.path.exists(os.path.join(src, f)) and not os.path.exists(os.path.join(TESSDIR, f)):
                shutil.copy(os.path.join(src, f), TESSDIR)
        if os.path.isdir(os.path.join(src, "configs")) and not os.path.isdir(os.path.join(TESSDIR, "configs")):
            shutil.copytree(os.path.join(src, "configs"), os.path.join(TESSDIR, "configs"))
    if not os.path.exists(TESSDIR + "/rus.traineddata"):
        try:
            urllib.request.urlretrieve("https://github.com/tesseract-ocr/tessdata_fast/raw/main/rus.traineddata", TESSDIR + "/rus.traineddata")
        except Exception:
            pass


def norm(t):
    return re.sub(r"[^0-9a-zàâçéèêëîïôûùüÿñæœа-яё]+", "", t.lower())


def _read_rapid(img):
    import numpy as np
    if not _ocr:
        from rapidocr_onnxruntime import RapidOCR
        _ocr.append(RapidOCR())
    from PIL import Image, ImageOps
    k = 3 if img.size[1] < 160 else 2 if img.size[1] < 400 else 1  # petit texte de jeu : on agrandit
    if k > 1:
        img = img.resize((img.size[0] * k, img.size[1] * k), Image.LANCZOS)
    img = ImageOps.autocontrast(img, cutoff=1)
    res, _ = _ocr[0](np.array(img))
    items = []  # (x, y centre, hauteur, texte) : les boîtes d'une même ligne sont recollées
    for box, text, score in res or []:
        if float(score) >= 0.5 and text.strip():
            ys = [pt[1] for pt in box]
            items.append((min(pt[0] for pt in box), (min(ys) + max(ys)) / 2, max(ys) - min(ys), text.strip(), float(score)))
    items.sort(key=lambda i: i[1])
    rows = []
    for it in items:
        if rows and abs(it[1] - rows[-1][-1][1]) < 0.6 * max(it[2], rows[-1][-1][2]):
            rows[-1].append(it)
        else:
            rows.append([it])
    out = []
    for r in rows:
        r = sorted(r)
        txt = " ".join(i[3] for i in r)
        if len(txt) >= 2:
            out.append((txt, sum(i[4] for i in r) / len(r)))  # (texte, confiance moyenne)
    return out


IGNORE = ("sendto", "envoyera")  # champ de saisie du chat


def _clean(txt):
    """Retire les pictogrammes lus comme des petits mots au début de la ligne (icône du canal)."""
    toks = txt.split()
    while len(toks) > 1 and ((len(toks[0]) <= 3 and re.search(r"[^\w]", toks[0])) or (len(toks[0]) == 1 and toks[0] not in "IAa")):
        toks.pop(0)
    return " ".join(toks)


def find_bands(img):
    """Repère les lignes de texte d'un cadre : pixels clairs ou très colorés (texte, icônes de canal),
    projetés horizontalement. Renvoie les (y0, y1) de chaque ligne en pixels."""
    import numpy as np
    a = np.asarray(img.convert("RGB")).astype(np.int16)
    mx, mn = a.max(2), a.min(2)
    lum = (a[:, :, 0] * 3 + a[:, :, 1] * 6 + a[:, :, 2]) // 10
    bg = np.median(lum)
    mask = (lum > max(bg + 55, 120)) | (((mx - mn) > 80) & (mx > 120))  # plus clair que le fond, ou couleur vive
    prof = mask.mean(axis=1)
    h = len(prof)
    on = np.convolve(prof > 0.02, np.ones(3), "same") > 0  # comble les trous entre lettres
    bands, y = [], 0
    while y < h:
        if on[y]:
            y0 = y
            while y < h and on[y]:
                y += 1
            if 7 <= y - y0 <= 45:
                bands.append((max(y0 - 3, 0), min(y + 3, h)))
        else:
            y += 1
    return bands


def _tess(img, psm, langs):
    """Un appel Tesseract : renvoie [(texte, confiance)] par ligne."""
    from PIL import Image, ImageOps
    k = 3 if img.size[1] < 160 else 2 if img.size[1] < 400 else 1
    if k > 1:
        img = img.resize((img.size[0] * k, img.size[1] * k), Image.LANCZOS)
    buf = io.BytesIO()
    ImageOps.autocontrast(img, cutoff=1).save(buf, "PNG")
    out = subprocess.run(["tesseract", "stdin", "stdout", "--psm", str(psm), "-l", langs]
                         + (["--tessdata-dir", TESSDIR] if langs != "eng" else []) + ["tsv"],
                         input=buf.getvalue(), capture_output=True, timeout=15).stdout.decode("utf-8", "replace")
    rows = {}
    for ln in out.splitlines()[1:]:
        c = ln.split("\t")
        if len(c) < 12 or not c[11].strip() or float(c[10]) < 0:
            continue
        rows.setdefault(tuple(c[2:5]), []).append((int(c[6]), c[11].strip(), float(c[10]) / 100.0))
    res = []
    for r in rows.values():
        r.sort()
        txt = _clean(" ".join(w[1] for w in r))
        if len(txt) >= 2 and not norm(txt).startswith(IGNORE):
            res.append((txt, sum(w[2] for w in r) / len(r)))
    return res


def _cyr_ratio(t):
    letters = [c for c in t if c.isalpha()]
    return sum("\u0400" <= c <= "\u04ff" for c in letters) / len(letters) if letters else 0.0


def read_lines(img, split=True):
    """Lignes de texte (texte, confiance) : Tesseract si présent (bons espaces), sinon RapidOCR.
    Chaque ligne repérée est lue seule, en anglais/français d'abord ; le russe seulement si c'est peu fiable
    (évite de lire les pseudos latins en lettres cyrilliques)."""
    global LANGS
    if not shutil.which("tesseract"):
        return _read_rapid(img)
    has_ru = os.path.exists(TESSDIR + "/rus.traineddata") and os.path.isdir(TESSDIR + "/configs")
    latin = "eng+fra" if has_ru else "eng"
    if split:
        try:
            bands = find_bands(img)
        except Exception:
            bands = []
        if 1 <= len(bands) <= 14:
            res = []
            for y0, y1 in bands:
                band = img.crop((0, y0, img.size[0], y1))
                best = _tess(band, 7, latin)
                if has_ru:
                    ru = _tess(band, 7, "rus+eng")
                    # le russe n'est retenu que si le MESSAGE est bien en cyrillique et mieux lu : un pseudo latin
                    # lu en cyrillique ne doit pas faire basculer toute la ligne
                    if ru and _cyr_ratio(split_chat(ru[0][0])[1]) >= 0.7 and (not best or ru[0][1] > best[0][1] + 0.03):
                        best = ru
                res += best
            return res
    return _tess(img, 6, "eng+fra+rus" if has_ru else "eng")


_FOLD = {}
for _grp, _to in (("lLiI1|!", "l"), ("oO0Q", "o"), ("bBD8", "b"), ("sS5", "s"), ("zZ2", "z"), ("gG69q", "g"), ("uUvV", "u"), ("nN", "n")):
    for _c in _grp:
        _FOLD[_c] = _to


for _c, _t in zip("АВСЕНКМОРТХУИаесорху", "abcehkmoptxyuaecopxy"):
    _FOLD[_c] = _t


def canon(t):
    """Forme repliée : les caractères que l'OCR confond (l/I/1, o/0, b/D...) deviennent identiques."""
    return "".join(_FOLD.get(c, c.lower()) for c in t if c.isalnum())


def name_part(t):
    """Pseudo seul : on enlève le tag/grade devant (« 42MHz (Recon)Pseudo » -> « Pseudo »)."""
    return re.split(r"[)\]]", t)[-1].strip() or t


def same_player(a, b):
    ca, cb = canon(a), canon(b)
    na, nb = canon(name_part(a)), canon(name_part(b))
    if min(len(na), len(nb)) >= 4 and (na in nb or nb in na):
        return True
    return max(difflib.SequenceMatcher(None, ca, cb).ratio(), difflib.SequenceMatcher(None, na, nb).ratio()) >= 0.68


def looks_like_name(t, sc):
    """Un pseudo : lisible, presque que des lettres/chiffres/_, pas du bruit de décor."""
    t = re.sub(r"^[^\w\[(]+|[^\w\])]+$", "", t.strip())
    t = " ".join(w for w in t.split() if sum(c.isalnum() for c in w) >= 2)  # lettres isolées = bruit
    alnum = sum(c.isalnum() or c == "_" for c in t)
    if sc < 0.65 or alnum < 4 or len(t) > 40 or alnum / max(len(t.replace(" ", "")), 1) < 0.8:
        return None
    if max((sum(c.isalnum() or c == "_" for c in w) for w in t.split()), default=0) < 4:
        return None  # aucun vrai mot
    for w in t.split():  # un mot mélangeant alphabet latin et cyrillique = bruit
        if re.search(r"[A-Za-z]", w) and re.search(r"[\u0400-\u04ff]", w):
            return None
    return t


def update_players(lines, now):
    """Un pseudo n'est retenu qu'après deux lectures proches (le bruit d'OCR ne se répète pas à l'identique)."""
    for ln, sc in lines:
        ln = looks_like_name(ln, sc)
        if not ln:
            continue
        g = next((g for g in players.values() if any(same_player(v, ln) for v in g["votes"])), None)
        if g is None:
            g = {"votes": {}, "t": now, "n": 0}
            players[len(players) + int(now * 1000)] = g
        g["votes"][ln] = g["votes"].get(ln, 0) + 1
        g["n"] += 1
        g["t"] = now
    for k in [k for k, g in players.items() if (g["n"] < 2 and now - g["t"] > 4.0) or now - g["t"] > 180.0]:
        del players[k]  # lecture jamais confirmée, ou joueur absent depuis 3 min


def player_name(g):
    return max(g["votes"], key=lambda v: (g["votes"][v], len(v)))


CHAT_RE = re.compile(r"^(?P<chan>\[[^\]]{1,12}\]\s*)?(?P<name>[^:]{2,32}?):\s*(?P<msg>.+)$")


def split_chat(text):
    """« [Team] Pseudo: message » -> (pseudo, message)."""
    m = CHAT_RE.match(text)
    if not m:
        tok = text.split(" ", 1)  # « : » non lu : un premier mot long avec « _ » est un pseudo
        if len(tok) == 2 and len(tok[0]) >= 6 and "_" in tok[0]:
            return tok[0], tok[1].strip()
        return "", text
    return ((m.group("chan") or "") + m.group("name")).strip(), m.group("msg").strip()


def detect_lang(t):
    letters = [c for c in t if c.isalpha()]
    if letters and sum("\u0400" <= c <= "\u04ff" for c in letters) / len(letters) > 0.5:
        return "ru"
    try:
        from langdetect import detect_langs
        best = detect_langs(t)[0]
        # petits messages de jeu : seules des langues sûres sont retenues, sinon on suppose de l'anglais
        if best.lang != "en" and (best.prob < 0.85 or (len(t) < 30 and best.lang not in ("fr", "es", "de", "it", "pt", "ru"))):
            return "en"
        return best.lang
    except Exception:
        return "en"


tr_lock = threading.Lock()
tr_failed = set()


def ensure_pair(a, b):
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


def translate_fr(text, src):
    """Traduction hors ligne vers le français (via l'anglais si besoin). Les paquets se téléchargent au premier usage."""
    import argostranslate.translate as at
    steps = [(src, "fr")] if ensure_pair(src, "fr") else ([(src, "en"), ("en", "fr")] if src != "en" and ensure_pair(src, "en") and ensure_pair("en", "fr") else None)
    if not steps:
        return ""
    for a, b in steps:
        text = at.translate(text, a, b)
    return text.strip()


def enrich(e):
    """Sépare pseudo / message, détecte la langue et traduit en français (en tâche de fond, avec reprises)."""
    e["done"] = False
    text = e["text"]
    e["name"], e["msg"] = split_chat(text)
    e["lang"] = detect_lang(e["msg"]) if len(norm(e["msg"])) >= 2 else ""
    e["tr"] = ""
    if e["lang"] and e["lang"] != "fr":
        for attempt in range(3):
            try:
                with tr_lock:
                    e["tr"] = translate_fr(e["msg"], e["lang"])
            except Exception:
                e["tr"] = ""
            if e["tr"] or e["text"] != text:
                break
            time.sleep(2.0)
    if e["text"] != text:  # relu entre-temps (meilleure lecture) : on refait avec le nouveau texte
        return enrich(e)
    e["done"] = True


pending = []  # lignes vues une seule fois : acceptées si relues (évite les lectures parasites)


def update_chat(lines, now):
    """Ajoute seulement les lignes nouvelles et stables : le chat du jeu disparaît, l'historique reste ici."""
    recent = [e for e in chat if now - e["seen"] < 25.0][-80:]

    def same(n, m):
        return n in m or m in n or difflib.SequenceMatcher(None, n, m).ratio() >= 0.7

    def dup_of(ln, n, pool):
        """Doublon = même message (et même pseudo, ou pseudo illisible). Comparer le pseudo seul ferait fusionner
        deux messages courts d'un même joueur."""
        name, msg = split_chat(ln)
        mn = norm(msg)
        for e in pool:
            en, em = e.get("name", ""), norm(e.get("msg", ""))
            if len(mn) >= 3 and len(em) >= 3 and name and en and canon(name) != canon(en) \
                    and difflib.SequenceMatcher(None, canon(name), canon(en)).ratio() < 0.6:
                continue  # pseudos différents : messages distincts
            if len(mn) >= 3 and len(em) >= 3:
                if (min(len(mn), len(em)) >= 6 and (mn in em or em in mn)) or difflib.SequenceMatcher(None, mn, em).ratio() >= 0.78:
                    return e
            elif same(n, e["norm"]):
                return e
        return None

    for ln, sc in lines:
        n = norm(ln)
        if len(n) < 4 or sc < 0.4:
            continue
        dup = dup_of(ln, n, recent)
        if dup:
            dup["seen"] = now
            if sc > dup["score"] and len(n) >= 0.9 * len(dup["norm"]):  # meilleure lecture de la même ligne
                dup.update(text=ln, norm=n, score=sc)
                threading.Thread(target=enrich, args=(dup,), daemon=True).start()
            continue
        pen = dup_of(ln, n, pending)
        if pen is None:
            nm, ms = split_chat(ln)
            pending.append({"text": ln, "norm": n, "score": sc, "count": 1, "seen": now, "name": nm, "msg": ms})
            continue
        pen["count"] += 1
        pen["seen"] = now
        if sc > pen["score"]:
            pen.update(text=ln, norm=n, score=sc, name=split_chat(ln)[0], msg=split_chat(ln)[1])
        if pen["count"] >= 2:
            pending.remove(pen)
            e = {"id": chat_next[0], "text": pen["text"], "norm": pen["norm"], "score": pen["score"], "seen": now,
                 "name": "", "msg": pen["text"], "lang": "", "tr": "", "done": False}
            threading.Thread(target=enrich, args=(e,), daemon=True).start()
            chat_next[0] += 1
            chat.append(e)
            recent.append(e)
    pending[:] = [p for p in pending if now - p["seen"] < 6.0]
    del chat[:-300]


def ocr_loop():
    last = -1
    while True:
        time.sleep(0.6)
        if st["proc"] is None or not any(regions.values()):
            continue
        with cond:
            frame, seq = st["frame"], st["seq"]
        if not frame or seq == last:
            continue
        last = seq
        try:
            from PIL import Image
            im = Image.open(io.BytesIO(frame)).convert("RGB")
            W, H = im.size
            for kind, r in regions.items():
                if not r:
                    continue
                x, y, w, h = r
                lines = read_lines(im.crop((int(x * W), int(y * H), int((x + w) * W), int((y + h) * H))))
                (update_players if kind == "players" else update_chat)(lines, time.time())
        except Exception:
            pass


def ocr_state():
    now = time.time()
    gs = sorted((g for g in players.values() if g["n"] >= 2), key=lambda g: -g["t"])
    return {"speaking": [player_name(g) for g in gs if now - g["t"] < 2.5],
            "players": [player_name(g) for g in gs[:20]],
            "assistant": {"on": asst["on"], "log": asst["log"][-12:]},
            "chat": [{"id": e["id"], "name": e["name"], "msg": e["msg"], "lang": e["lang"], "tr": e["tr"], "done": e["done"]} for e in chat[-200:]]}


# ---------------------------------------------------------------- Assistant : répond au chat, par voix dans le micro
VOICES = {"fr": "fr_FR-siwis-medium", "en": "en_US-lessac-medium", "es": "es_ES-davefx-medium",
          "de": "de_DE-thorsten-medium", "it": "it_IT-paola-medium", "ru": "ru_RU-denis-medium"}
VDIR = os.path.expanduser("~/.local/share/sound-link/voices")
_voices = {}
tts_lock = threading.Lock()
asst = {"on": False, "speak": True, "model": "gemma3:4b", "me": "", "ptt": "MAJ", "write": False, "chatkey": "!", "last": 0.0, "seen": set(), "log": [], "busy": False}
OLLAMA = "http://127.0.0.1:11434/api/chat"
PROMPT = ("Tu es un joueur sympa et plein d'humour dans un jeu multijoueur. Tu reçois le chat récent et un nouveau message. "
          "Réponds par UNE seule courte phrase (12 mots maximum), taquine mais bienveillante, dans la langue demandée. "
          " Réponds normalement à presque tout, y compris aux piques et aux questions. "
          "Écris exactement SKIP seulement si le message est du charabia, du spam ou une insulte grave. "
          "Pas de guillemets, pas d'émojis, pas d'explication.\n"
          "Charabia -> SKIP. Réagis au contenu précis du message.")


def tts_wav(text, lang):
    from piper import PiperVoice
    name = VOICES.get(lang, VOICES["en"])
    with tts_lock:
        if name not in _voices:
            path = os.path.join(VDIR, name + ".onnx")
            if not os.path.exists(path):
                from pathlib import Path
                from piper.download_voices import download_voice
                Path(VDIR).mkdir(parents=True, exist_ok=True)
                download_voice(name, Path(VDIR))
            _voices[name] = PiperVoice.load(path)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            _voices[name].synthesize_wav(text, w)
    return buf.getvalue()


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


def write_in_game_chat(text):
    """Ouvre le chat du jeu (touche « ! »), tape le texte, valide avec Entrée. Seuls les caractères présents
    sur le clavier sont tapés (pas de cyrillique sur une disposition française)."""
    import unicodedata
    from Xlib import display
    d = display.Display()
    plans = []
    opener = plan_key(d, asst["chatkey"] or "!")
    if not opener:
        return
    for ch in unicodedata.normalize("NFKC", text):
        pl = plan_key(d, ch if ch != " " else "space")
        if pl is None and ch.isalpha():  # lettre accentuée absente : on tente sans accent
            base = unicodedata.normalize("NFKD", ch)[0]
            pl = plan_key(d, base)
        if pl:
            plans.append(pl)
    if len(plans) < 3:
        return
    tap(d, opener, 0.25)
    for pl in plans:
        tap(d, pl, 0.025)
    tap(d, plan_key(d, "Return"), 0.1)


def speak(text, lang):
    wav = tts_wav(text, lang)
    f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    f.write(wav)
    f.close()
    sink = subprocess.run(["pactl", "list", "short", "sinks"], capture_output=True, text=True).stdout
    cmd = ["paplay"] + (["--device=soundlink_sink"] if "soundlink_sink" in sink else []) + [f.name]
    press_ptt(True)
    time.sleep(0.25)
    try:
        subprocess.run(cmd, timeout=40)
    finally:
        time.sleep(0.15)
        press_ptt(False)
        os.unlink(f.name)


LANG_NAMES = {"fr": "français", "en": "English", "ru": "русский", "es": "español", "de": "Deutsch", "it": "italiano", "pt": "português"}


def ask_model(e, context):
    lang = LANG_NAMES.get(e.get("lang"), "English")
    body = {"model": asst["model"], "stream": False, "keep_alive": "10m",
            "options": {"temperature": 0.8, "num_predict": 48},
            "messages": [{"role": "system", "content": PROMPT},
                         {"role": "user", "content": "Chat récent :\n%s\n\nNouveau message de %s : %s\n\nRéponds en %s, une phrase courte (ou SKIP)." % (context, e["name"] or "un joueur", e["msg"], lang)}]}
    frame = st["frame"]
    if frame:  # le modèle doit savoir lire les images (gemma3, qwen2.5vl...)
        try:
            from PIL import Image
            im = Image.open(io.BytesIO(frame)).convert("RGB")
            im.thumbnail((640, 640))
            b = io.BytesIO()
            im.save(b, "JPEG", quality=70)
            body["messages"][1]["images"] = [base64.b64encode(b.getvalue()).decode()]
        except Exception:
            pass
    req = urllib.request.Request(OLLAMA, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["message"]["content"].strip().strip('"«» ')


def assistant_loop():
    while True:
        time.sleep(1.0)
        if not asst["on"] or asst["busy"]:
            continue
        now = time.time()
        for e in list(chat):
            if e["id"] in asst["seen"] or not e.get("done"):
                continue
            asst["seen"].add(e["id"])
            if now - asst["last"] < 15 or len(norm(e["msg"])) < 4:
                continue
            if asst["me"] and canon(asst["me"]) and difflib.SequenceMatcher(None, canon(asst["me"]), canon(e["name"])).ratio() > 0.75:
                continue  # mon propre message
            asst["busy"] = True
            try:
                ctx = "\n".join("%s: %s" % (c["name"] or "?", c["msg"]) for c in chat[-7:-1])
                reply = ask_model(e, ctx)[:160]
                if reply and not reply.upper().startswith("SKIP"):
                    asst["last"] = time.time()
                    lang = e["lang"] if e["lang"] in VOICES else "en"
                    asst["log"].append({"to": e["name"], "msg": e["msg"], "reply": reply, "lang": lang})
                    del asst["log"][:-30]
                    if asst["write"]:
                        write_in_game_chat(reply)
                    if asst["speak"]:
                        speak(reply, lang)
            except Exception as ex:
                asst["log"].append({"to": "", "msg": "", "reply": "(erreur : %s)" % str(ex)[:80], "lang": ""})
            finally:
                asst["busy"] = False
            break


class Quiet(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=b"", ctype="application/json", seq=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if seq is not None:
            self.send_header("X-Seq", str(seq))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def json(self, obj):
        self.reply(200, json.dumps(obj, ensure_ascii=False).encode())


class Api(Quiet):
    def do_GET(self):
        if self.path.startswith("/windows"):
            self.json(list_windows())
        elif self.path.startswith("/ocr"):
            self.json(ocr_state())
        else:
            self.json({"sharing": st["proc"] is not None, "mode": st["mode"]})

    def do_POST(self):
        q = parse_qs(urlparse(self.path).query)
        if self.path.startswith("/assistant"):
            was = asst["on"]
            asst["on"] = q.get("on", ["0"])[0] == "1"
            asst["speak"] = q.get("speak", ["1"])[0] == "1"
            asst["me"] = q.get("me", [""])[0]
            asst["ptt"] = q.get("ptt", ["MAJ"])[0]
            asst["write"] = q.get("write", ["0"])[0] == "1"
            asst["chatkey"] = q.get("chat", ["!"])[0] or "!"
            if asst["on"] and not was:
                asst["seen"] = {e["id"] for e in chat}  # on ne répond qu'aux nouveaux messages
            return self.json({"ok": True})
        if self.path.startswith("/regions"):
            if "clear" in q:
                chat.clear()
                players.clear()
            for k in regions:
                if k in q:
                    v = q[k][0]
                    regions[k] = tuple(float(x) for x in v.split(",")) if v else None
            return self.json({"ok": True})
        try:
            if "stop" in q:
                stop()
            else:
                start(q["win"][0], int(q.get("h", ["720"])[0]), q.get("mode", ["window"])[0])
            self.json({"ok": True})
        except Exception as e:
            self.json({"ok": False, "error": str(e)})


class Frames(Quiet):
    def do_GET(self):
        after = int(parse_qs(urlparse(self.path).query).get("after", ["-1"])[0] or -1)
        if st["proc"] is None:
            return self.reply(404)
        with cond:
            cond.wait_for(lambda: st["seq"] != after or st["proc"] is None, timeout=2.0)
            frame, seq = st["frame"], st["seq"]
        if not frame or seq == after:
            return self.reply(204, seq=seq)
        self.reply(200, frame, "image/jpeg", seq)


if __name__ == "__main__":
    try:
        threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", FRAME_PORT), Frames).serve_forever, daemon=True).start()
    except OSError:
        pass
    threading.Thread(target=setup_tessdata, daemon=True).start()
    threading.Thread(target=ocr_loop, daemon=True).start()
    threading.Thread(target=assistant_loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", API_PORT), Api).serve_forever()
