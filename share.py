#!/usr/bin/env python3
"""Sound Link : capture d'une fenêtre (X11) et diffusion en JPEG.
 - 127.0.0.1:PORT : API locale de l'appli (GET /windows, POST /share?win=0x..&h=720, POST /share?stop=1)
 - 0.0.0.0:4246   : image de la fenêtre partagée (aperçu du host et clients), 404 si rien n'est partagé."""
import difflib, io, json, os, re, shutil, subprocess, sys, threading, time
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
    return re.sub(r"[^0-9a-zàâçéèêëîïôûùüÿñæœ]+", "", t.lower())


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


def read_lines(img):
    """Lignes de texte (texte, confiance) : Tesseract si présent (bons espaces), sinon RapidOCR."""
    global LANGS
    if not shutil.which("tesseract"):
        return _read_rapid(img)
    if LANGS == "eng" and os.path.exists(TESSDIR + "/rus.traineddata") and os.path.isdir(TESSDIR + "/configs"):
        LANGS = "eng+fra+rus"
    from PIL import Image, ImageOps
    k = 3 if img.size[1] < 160 else 2 if img.size[1] < 400 else 1
    if k > 1:
        img = img.resize((img.size[0] * k, img.size[1] * k), Image.LANCZOS)
    buf = io.BytesIO()
    ImageOps.autocontrast(img, cutoff=1).save(buf, "PNG")
    out = subprocess.run(["tesseract", "stdin", "stdout", "--psm", "6", "-l", LANGS] + (["--tessdata-dir", TESSDIR] if LANGS != "eng" else []) + ["tsv"],
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


def update_players(lines, now):
    for ln, sc in lines:
        if sc < 0.4 or len(canon(ln)) < 3:
            continue
        g = next((g for g in players.values() if any(same_player(v, ln) for v in g["votes"])), None)
        if g is None:
            g = {"votes": {}, "t": now}
            players[len(players) + int(now * 1000)] = g
        g["votes"][ln] = g["votes"].get(ln, 0) + 1  # on affichera la lecture la plus fréquente
        g["t"] = now
    if len(players) > 40:
        for k in sorted(players, key=lambda k: players[k]["t"])[:-30]:
            del players[k]


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
    """Sépare pseudo / message, détecte la langue et traduit en français (en tâche de fond)."""
    e["name"], e["msg"] = split_chat(e["text"])
    e["lang"] = detect_lang(e["msg"]) if len(norm(e["msg"])) >= 3 else ""
    if e["lang"] and e["lang"] != "fr":
        try:
            with tr_lock:
                e["tr"] = translate_fr(e["msg"], e["lang"])
        except Exception:
            pass
    e["done"] = True


pending = []  # lignes vues une seule fois : acceptées si relues (évite les lectures parasites)


def update_chat(lines, now):
    """Ajoute seulement les lignes nouvelles et stables : le chat du jeu disparaît, l'historique reste ici."""
    recent = [e for e in chat if now - e["seen"] < 25.0][-80:]

    def same(n, m):
        return n in m or m in n or difflib.SequenceMatcher(None, n, m).ratio() >= 0.7

    for ln, sc in lines:
        n = norm(ln)
        if len(n) < 4 or sc < 0.5:
            continue
        dup = next((e for e in recent if same(n, e["norm"])), None)
        if dup:
            dup["seen"] = now
            if sc > dup["score"] and len(n) >= 0.9 * len(dup["norm"]):  # meilleure lecture de la même ligne
                dup.update(text=ln, norm=n, score=sc)
                dup["name"], dup["msg"] = split_chat(ln)
            continue
        pen = next((p for p in pending if difflib.SequenceMatcher(None, n, p["norm"]).ratio() >= 0.8), None)
        if pen is None:
            pending.append({"text": ln, "norm": n, "score": sc, "count": 1, "seen": now})
            continue
        pen["count"] += 1
        pen["seen"] = now
        if sc > pen["score"]:
            pen.update(text=ln, norm=n, score=sc)
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
    gs = sorted(players.values(), key=lambda g: -g["t"])
    return {"speaking": [player_name(g) for g in gs if now - g["t"] < 2.5],
            "players": [player_name(g) for g in gs[:20]],
            "chat": [{"id": e["id"], "name": e["name"], "msg": e["msg"], "lang": e["lang"], "tr": e["tr"], "done": e["done"]} for e in chat[-200:]]}


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
    ThreadingHTTPServer(("127.0.0.1", API_PORT), Api).serve_forever()
