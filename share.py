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
LANGS = "eng+fra" if os.path.exists("/usr/share/tesseract-ocr/5/tessdata/fra.traineddata") or os.path.exists("/usr/share/tesseract-ocr/4.00/tessdata/fra.traineddata") else "eng"


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
    if not shutil.which("tesseract"):
        return _read_rapid(img)
    from PIL import Image, ImageOps
    k = 3 if img.size[1] < 160 else 2 if img.size[1] < 400 else 1
    if k > 1:
        img = img.resize((img.size[0] * k, img.size[1] * k), Image.LANCZOS)
    buf = io.BytesIO()
    ImageOps.autocontrast(img, cutoff=1).save(buf, "PNG")
    out = subprocess.run(["tesseract", "stdin", "stdout", "--psm", "6", "-l", LANGS, "tsv"],
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


def update_players(lines, now):
    for ln, sc in lines:
        if sc < 0.5 or len(norm(ln)) < 3:
            continue
        key = next((k for k in players if difflib.SequenceMatcher(None, norm(k), norm(ln)).ratio() >= 0.8), ln)
        players[key] = now


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
            e = {"id": chat_next[0], "text": pen["text"], "norm": pen["norm"], "score": pen["score"], "seen": now}
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
    return {"speaking": [k for k, t in players.items() if now - t < 1.8],
            "players": sorted(players, key=lambda k: -players[k])[:20],
            "chat": [{"id": e["id"], "text": e["text"]} for e in chat[-200:]]}


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
    threading.Thread(target=ocr_loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", API_PORT), Api).serve_forever()
