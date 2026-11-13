"""Собирает два архива в Downloads.

WoWTok-<версия>.zip            - личная версия со всеми роликами из WoWTok/Media (не для публикации).
Azerotok-<версия>-public.zip   - публичная версия: без роликов, с конвертером, имя без "WoW".
Запуск: python tools/pack.py
"""
import pathlib
import re
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT / "WoWTok"
OUT = pathlib.Path.home() / "Downloads"
STORED = {".jpg", ".blp", ".ogg"}      # уже сжаты: упаковывать повторно бесполезно

version = re.search(r"^## Version: (\S+)", (ADDON / "WoWTok.toc").read_text(encoding="utf-8"), re.M).group(1)


def add(z, arcname, data=None, path=None):
    method = zipfile.ZIP_STORED if pathlib.Path(arcname).suffix.lower() in STORED else zipfile.ZIP_DEFLATED
    if path is not None:
        z.write(path, arcname, compress_type=method)
    else:
        z.writestr(arcname, data, compress_type=method)


# личная версия: аддон как есть
personal = OUT / f"WoWTok-{version}.zip"
with zipfile.ZipFile(personal, "w") as z:
    for p in sorted(ADDON.rglob("*")):
        if p.is_file() and p.name != "meta.json":
            add(z, "WoWTok/" + p.relative_to(ADDON).as_posix(), path=p)

# публичная версия: другое имя, пустая лента, конвертер внутри
def rename(text):
    return (text.replace("WoWTokDB", "AzerotokDB").replace("WoWTokFrame", "AzerotokFrame")
            .replace('"/wowtok"', '"/azerotok"').replace("WOWTOK", "AZEROTOK").replace("WoWTok", "Azerotok"))

public = OUT / f"Azerotok-{version}-public.zip"
with zipfile.ZipFile(public, "w") as z:
    add(z, "Azerotok/Azerotok.toc", rename((ADDON / "WoWTok.toc").read_text(encoding="utf-8")).encode("utf-8"))
    add(z, "Azerotok/Azerotok.lua", rename((ADDON / "WoWTok.lua").read_text(encoding="utf-8")).encode("utf-8"))
    add(z, "Azerotok/videos.lua",
        "-- Сгенерировано convert.py из Media/*/meta.json. Руками не править.\nlocal _, ns = ...\nns.videos = {\n}\n".encode("utf-8"))
    add(z, "Azerotok/tools/convert.py", rename((ROOT / "tools" / "convert.py").read_text(encoding="utf-8")).encode("utf-8"))

for f in (personal, public):
    with zipfile.ZipFile(f) as z:
        bad = z.testzip()
        print(f"{f}  {f.stat().st_size / 1048576:.1f} MB  files={len(z.namelist())}  test={'ok' if bad is None else bad}")
