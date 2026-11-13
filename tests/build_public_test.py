"""Проверка публичной сборки: берёт Azerotok.lua из архива и гоняет на нём те же сценарии.

Запуск: python tests/build_public_test.py  ->  tests/out/test_public.html
"""
import json
import pathlib
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
version = next(l.split()[-1] for l in (root / "WoWTok" / "WoWTok.toc").read_text(encoding="utf-8").splitlines() if l.startswith("## Version"))
z = zipfile.ZipFile(pathlib.Path.home() / "Downloads" / f"Azerotok-{version}-public.zip")
lua = z.read("Azerotok/Azerotok.lua").decode("utf-8")

harness = (root / "tests" / "harness.lua").read_text(encoding="utf-8")
for old, new in (("WoWTokDB", "AzerotokDB"), ("WoWTokFrame", "AzerotokFrame"), ("WOWTOK", "AZEROTOK"),
                 ('"WoWTok"', '"Azerotok"'), ("AddOns\\\\WoWTok\\\\", "AddOns\\\\Azerotok\\\\")):
    assert old in harness, old
    harness = harness.replace(old, new)

src = "local ADDON_SRC = [==[\n" + lua + "]==]\n" + harness
html = (root / "tests" / "out" / "test.html").read_text(encoding="utf-8")
start = html.index("const src = ") + len("const src = ")
end = html.index(";\nconst out")
html = html[:start] + json.dumps(src).replace("</", "<\\/") + html[end:]
(root / "tests" / "out" / "test_public.html").write_text(html, encoding="utf-8")
print("written test_public.html")
