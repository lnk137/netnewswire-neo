#!/usr/bin/env python3
"""Stage a one-time, owner-only bootstrap for Neo to import into local storage on launch."""
import argparse
import json
import os
import re
import plistlib
from urllib.parse import urlparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("secrets", type=Path)
parser.add_argument("--preserve-settings", action="store_true", help="Keep the current API/model/language/automatic settings during credential migration")
args = parser.parse_args()
section = args.secrets.read_text().split("## 供应商：a6api", 1)[1]
api_key = re.search(r"API 密钥[：:]\s*(\S+)", section).group(1)
base = re.search(r"API 基础地址（Base URL）[：:]\s*(\S+)", section).group(1).rstrip("/")
model = re.search(r"默认模型[：:]\s*(\S+)", section).group(1)
folder = Path.home() / "Library/Application Support/NetNewsWire Neo"
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
path = folder / "bootstrap.json"
payload = {"configuration": {"baseURL": base + "/v1", "model": model, "targetLanguage": "简体中文", "automaticallyTranslate": False}, "apiKey": api_key}
if args.preserve_settings:
    preferences = Path.home() / "Library/Preferences/local.lnk137.NetNewsWireNeo.plist"
    saved = plistlib.loads(preferences.read_bytes())
    configuration = json.loads(saved["AITranslationConfiguration"])
    if urlparse(configuration["baseURL"]).hostname != urlparse(base).hostname:
        raise SystemExit("Current provider differs from a6api; credential migration was not staged.")
    payload["configuration"] = configuration
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, "w") as file:
    json.dump(payload, file, ensure_ascii=False)
print("a6api staged for one-time local import. No credentials were printed.")
