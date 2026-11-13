"""mp4 -> кадры и звук для аддона WoWTok.

Игра не умеет проигрывать видео, поэтому ролик превращается в листы кадров
(текстуры 2048x2048, по 32 кадра 256x456 на листе) и звук в .ogg.

Запуск:
    python convert.py [--format jpg|blp|both] [--jobs N] <ролик> [<ролик> ...]
где <ролик> - путь к .mp4 или id ролика из папки raw/ рядом с проектом.
Рядом с роликом может лежать <имя>.info.json (yt-dlp): оттуда берутся автор, подпись, лайки.

Каждый ролик ложится в Media/<id>/ аддона вместе с meta.json. После этого
videos.lua пересобирается из всех meta.json, так что ролики можно добавлять
по одному. Удалить ролик: удалить его папку из Media и запустить convert.py без роликов.

Скрипт сам находит аддон: если он лежит в WoWTok/tools/, пишет в WoWTok/;
если в tools/ проекта - в WoWTok/ рядом.
"""
import argparse
import json
import pathlib
import re
import shutil
import struct
import subprocess
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
if any(HERE.parent.glob("*.toc")):
    ADDON = HERE.parent                   # скрипт лежит внутри аддона
    RAW = ADDON / "raw"
else:
    ADDON = HERE.parent / "WoWTok"        # скрипт лежит в папке проекта
    RAW = HERE.parent / "raw"
MEDIA = ADDON / "Media"

FPS = 12
CELL_W, CELL_H = 256, 456          # кадр: ширина 256, высота под 9:16
SHEET = 2048                       # сторона листа, степень двойки
COLS, ROWS = SHEET // CELL_W, SHEET // CELL_H
PER_SHEET = COLS * ROWS
JPEG_QUALITY = 80
CAPTION_MAX = 110
PREFIX = {"blp": "b", "jpg": "j"}


def read_frames(path):
    """Все кадры ролика: (n, CELL_H, CELL_W, 3). Ролик вписывается в кадр целиком, поля чёрные."""
    vf = (
        f"fps={FPS},format=rgb24,"
        f"scale={CELL_W}:{CELL_H}:force_original_aspect_ratio=decrease:flags=lanczos,"
        f"pad={CELL_W}:{CELL_H}:(ow-iw)/2:(oh-ih)/2:black"
    )
    cmd = ["ffmpeg", "-v", "error", "-i", str(path), "-vf", vf, "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
    data = subprocess.run(cmd, check=True, capture_output=True).stdout
    size = CELL_W * CELL_H * 3
    n = len(data) // size
    return np.frombuffer(data, np.uint8, n * size).reshape(n, CELL_H, CELL_W, 3)


def make_sheets(frames):
    for start in range(0, len(frames), PER_SHEET):
        sheet = np.zeros((SHEET, SHEET, 3), np.uint8)
        for k, frame in enumerate(frames[start:start + PER_SHEET]):
            row, col = divmod(k, COLS)
            sheet[row * CELL_H:(row + 1) * CELL_H, col * CELL_W:(col + 1) * CELL_W] = frame
        yield sheet


def _q565(c):
    c = np.clip(c, 0, 255)
    r = np.rint(c[:, 0] * 31 / 255).astype(np.uint32)
    g = np.rint(c[:, 1] * 63 / 255).astype(np.uint32)
    b = np.rint(c[:, 2] * 31 / 255).astype(np.uint32)
    return (r << 11) | (g << 5) | b


def _expand565(c):
    r, g, b = (c >> 11) & 31, (c >> 5) & 63, c & 31
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], 1).astype(np.float32)


def _bc1_blocks(b):
    """b: (N, 16, 3) float32 -> N блоков DXT1 по 8 байт."""
    mean = b.mean(1, keepdims=True)
    d = b - mean
    cov = np.einsum("nij,nik->njk", d, d)
    # главная ось цветов блока: начинаем с самого далёкого от среднего пикселя и уточняем
    axis = d[np.arange(len(d)), np.argmax((d * d).sum(2), 1)]
    for _ in range(4):
        axis = np.einsum("njk,nk->nj", cov, axis)
        axis = axis / np.maximum(np.linalg.norm(axis, axis=1, keepdims=True), 1e-6)
    t = np.einsum("nij,nj->ni", d, axis)
    lo = mean[:, 0] + axis * t.min(1, keepdims=True)
    hi = mean[:, 0] + axis * t.max(1, keepdims=True)
    c0, c1 = _q565(hi), _q565(lo)
    swap = c0 < c1
    c0, c1 = np.where(swap, c1, c0), np.where(swap, c0, c1)
    p0, p1 = _expand565(c0), _expand565(c1)
    palette = np.stack([p0, p1, (2 * p0 + p1) / 3, (p0 + 2 * p1) / 3], 1)
    dist = ((b[:, :, None, :] - palette[:, None, :, :]) ** 2).sum(3)
    idx = dist.argmin(2).astype(np.uint32)
    idx[c0 == c1] = 0      # при равных цветах индекс 3 означал бы прозрачность
    bits = (idx << (2 * np.arange(16, dtype=np.uint32))).sum(1, dtype=np.uint32)
    out = np.empty(len(b), dtype=[("c0", "<u2"), ("c1", "<u2"), ("bits", "<u4")])
    out["c0"], out["c1"], out["bits"] = c0, c1, bits
    return out.tobytes()


def bc1(img):
    h, w, _ = img.shape
    assert h % 4 == 0 and w % 4 == 0
    blocks = img.reshape(h // 4, 4, w // 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3).astype(np.float32)
    step = 32768
    return b"".join(_bc1_blocks(blocks[i:i + step]) for i in range(0, len(blocks), step))


def write_blp(path, img):
    """BLP2, сжатие DXT1, без прозрачности и без уменьшенных копий."""
    h, w, _ = img.shape
    data = bc1(img)
    header = struct.pack("<4sIBBBBII", b"BLP2", 1, 2, 0, 0, 0, w, h)
    header += struct.pack("<16I", 1172, *([0] * 15))
    header += struct.pack("<16I", len(data), *([0] * 15))
    header += bytes(1024)
    assert len(header) == 1172
    path.write_bytes(header + data)


def write_audio(src, dst):
    for codec in (["-c:a", "libvorbis", "-q:a", "4"], ["-c:a", "vorbis", "-strict", "-2", "-b:a", "128k"]):
        cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-vn", "-ac", "2", "-ar", "44100", *codec, str(dst)]
        if subprocess.run(cmd, capture_output=True).returncode == 0 and dst.exists() and dst.stat().st_size > 0:
            return True
    return False


ALLOWED = re.compile(r"[^0-9A-Za-zА-Яа-яЁё .,!?:;()\-+#@_/%&'\"«»]")


def clean(text, limit=None):
    """Оставляет только то, что есть в шрифтах игры (эмодзи там нет)."""
    text = ALLOWED.sub(" ", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    if limit and len(text) > limit:
        text = text[:limit].rsplit(" ", 1)[0] + "..."
    return text


def lua_str(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def resolve(arg):
    """Путь к .mp4 или id из raw/ -> (id, путь к mp4, путь к info.json)."""
    p = pathlib.Path(arg)
    if not p.suffix:
        p = RAW / f"{arg}.mp4"
    if not p.exists():
        raise SystemExit(f"нет такого ролика: {arg}")
    vid = re.sub(r"[^0-9A-Za-z_-]", "_", p.stem)
    return vid, p, p.with_name(p.stem + ".info.json")


def convert(job):
    vid, src, info_path, formats, order = job
    info = json.loads(info_path.read_text(encoding="utf-8")) if info_path.exists() else {}
    out = MEDIA / vid
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    frames = read_frames(src)
    n_sheets = 0
    for n_sheets, sheet in enumerate(make_sheets(frames), 1):
        if "blp" in formats:
            write_blp(out / f"b{n_sheets:03d}.blp", sheet)
        if "jpg" in formats:
            Image.fromarray(sheet).save(out / f"j{n_sheets:03d}.jpg", "JPEG", quality=JPEG_QUALITY,
                                        subsampling="4:2:0", progressive=False, optimize=True)
    has_audio = write_audio(src, out / "a.ogg")

    meta = {
        "id": vid, "order": order, "frames": len(frames), "sheets": n_sheets, "fps": FPS,
        "cols": COLS, "rows": ROWS, "cellW": CELL_W, "cellH": CELL_H, "sheetSize": SHEET,
        "formats": formats, "audio": has_audio,
        "author": clean(info.get("uploader") or info.get("channel") or "") or "unknown",
        "caption": clean(info.get("description") or "", CAPTION_MAX),
        "likes": int(info.get("like_count") or 0), "comments": int(info.get("comment_count") or 0),
    }
    (out / "meta.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    mb = sum(f.stat().st_size for f in out.iterdir()) / 1048576
    return f"{vid}: {len(frames)} frames, {len(frames) / FPS:.1f}s, {n_sheets} sheets, {mb:.1f} MB"


def write_list():
    metas = []
    for m in MEDIA.glob("*/meta.json") if MEDIA.exists() else []:
        metas.append(json.loads(m.read_text(encoding="utf-8")))
    metas.sort(key=lambda m: (m["order"], m["id"]))
    lines = ["-- Сгенерировано convert.py из Media/*/meta.json. Руками не править.", "local _, ns = ...", "ns.videos = {"]
    for v in metas:
        lines.append(
            "    {{ id = {id}, frames = {frames}, sheets = {sheets}, fps = {fps}, cols = {cols}, rows = {rows}, "
            "cellW = {cellW}, cellH = {cellH}, sheetSize = {sheetSize}, formats = {{ {fmts} }}, audio = {audio}, "
            "likes = {likes}, comments = {comments}, author = {author}, caption = {caption} }},".format(
                **{k: v[k] for k in ("frames", "sheets", "fps", "cols", "rows", "cellW", "cellH", "sheetSize", "likes", "comments")},
                id=lua_str(v["id"]), fmts=", ".join(lua_str(f) for f in v["formats"]),
                audio="true" if v["audio"] else "false", author=lua_str(v["author"]), caption=lua_str(v["caption"]),
            )
        )
    lines.append("}")
    (ADDON / "videos.lua").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"videos.lua: {len(metas)} clips")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=("jpg", "blp", "both"), default="jpg")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("clips", nargs="*")
    args = ap.parse_args()
    formats = ["blp", "jpg"] if args.format == "both" else [args.format]

    start = 0
    for m in MEDIA.glob("*/meta.json") if MEDIA.exists() else []:
        start = max(start, json.loads(m.read_text(encoding="utf-8"))["order"])
    jobs = [(*resolve(c), formats, start + i + 1) for i, c in enumerate(args.clips)]
    with ProcessPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for line in pool.map(convert, jobs):
            print(line, flush=True)
    write_list()


if __name__ == "__main__":
    main()
