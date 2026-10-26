#!/usr/bin/env python3
"""Stage a one-time, owner-only bootstrap for Neo to import into Keychain on launch."""
import argparse
import json
import os
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("secrets", type=Path)
args = parser.parse_args()
section = args.secrets.read_text().split("## 供应商：a6api", 1)[1]
api_key = re.search(r"API 密钥[：:]\s*(\S+)", section).group(1)
base = re.search(r"API 基础地址（Base URL）[：:]\s*(\S+)", section).group(1).rstrip("/")
model = re.search(r"默认模型[：:]\s*(\S+)", section).group(1)
folder = Path.home() / "Library/Application Support/NetNewsWire Neo"
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
path = folder / "bootstrap.json"
payload = {"configuration": {"baseURL": base + "/v1", "model": model, "targetLanguage": "简体中文", "automaticallyTranslate": False}, "apiKey": api_key}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, "w") as file:
    json.dump(payload, file, ensure_ascii=False)
print("a6api staged for one-time Keychain import. No credentials were printed.")
