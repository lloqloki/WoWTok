"""Собирает tests/out/test.html: код аддона + поддельный API + сценарии в одной странице.

Страница запускает Lua прямо в браузере (fengari) и пишет результат в <pre id="out">.
Запуск: python tests/build_test.py
"""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
addon = (root / "WoWTok" / "WoWTok.lua").read_text(encoding="utf-8")
harness = (root / "tests" / "harness.lua").read_text(encoding="utf-8")
assert "]==]" not in addon

videos_file = root / "WoWTok" / "videos.lua"
videos = videos_file.read_text(encoding="utf-8") if videos_file.exists() else None
assert videos is None or "]==]" not in videos

lua = "local ADDON_SRC = [==[\n" + addon + "]==]\n"
if videos is not None:
    lua += "local REAL_VIDEOS_SRC = [==[\n" + videos + "]==]\n"   # настоящий список роликов тоже проверяется
lua += harness
html = """<!doctype html>
<meta charset="utf-8">
<title>WoWTok test</title>
<pre id="out">running...</pre>
<script src="https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js"></script>
<script>
const src = %s;
const out = document.getElementById('out');
try {
  out.textContent = String(fengari.load(src, 'harness')());
} catch (e) {
  out.textContent = 'JS ERROR: ' + e + '\\n' + (e && e.stack || '');
}
</script>
""" % json.dumps(lua).replace("</", "<\\/")

out = root / "tests" / "out"
out.mkdir(exist_ok=True)
(out / "test.html").write_text(html, encoding="utf-8")
print("written", out / "test.html", len(html), "bytes")
