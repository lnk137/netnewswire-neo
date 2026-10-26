#!/usr/bin/env python3
"""Translate public UI catalogs through a configured API; credentials never enter the repository."""
import argparse
import concurrent.futures
import json
import re
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--secrets", type=Path, required=True)
parser.add_argument("--cache", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
secret = args.secrets.read_text().split("## 供应商：a6api", 1)[1]
key = re.search(r"API 密钥[：:]\s*(\S+)", secret).group(1)
base = re.search(r"API 基础地址（Base URL）[：:]\s*(\S+)", secret).group(1).rstrip("/")
model = re.search(r"默认模型[：:]\s*(\S+)", secret).group(1)
files = [p for prefix in ["Mac", "Shared", "Modules/ActivityLog"] for p in (root / prefix).rglob("*.xcstrings") if ".build" not in p.parts]
catalogs = {p: json.loads(p.read_text()) for p in files}
cache = json.loads(args.cache.read_text()) if args.cache.exists() else {}
cache.update({"Today": "今天", "All Unread": "全部未读", "Starred": "已收藏", "Smart Feeds": "智能订阅", "On My Mac": "在我的 Mac 上", "General": "通用", "Accounts": "账户", "Advanced": "高级", "Search": "搜索", "NetNewsWire": "NetNewsWire Neo"})

def source(key, value):
    return value.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)

sources = sorted({source(k, v) for data in catalogs.values() for k, v in data["strings"].items() if k})
placeholder = re.compile(r"%(?:\d+\$)?(?:[-+0# ]*\d*(?:\.\d+)?[hlLzjt]*)?[@diufFeEgGxXosc%]")

def translate(batch):
    request_values = {str(i): value for i, value in enumerate(batch)}
    payload = {"model": model, "stream": False, "max_tokens": 8192, "response_format": {"type": "json_object"}, "messages": [
        {"role": "system", "content": "Translate these macOS RSS reader UI strings into natural Simplified Chinese. Return a JSON object with the exact same numeric keys and translated string values. Preserve ALL printf placeholders EXACTLY (including positional indexes), URLs, Markdown links, keyboard shortcuts, newlines and format specifiers such as %#@count@. Do not translate brand names except NetNewsWire becomes NetNewsWire Neo. RSS feed=订阅源; article=文章; starred=已收藏; unread=未读; Reader View=阅读视图. Output only the JSON object."},
        {"role": "user", "content": json.dumps(request_values, ensure_ascii=False)}]}
    for attempt in range(3):
        try:
            request = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(payload).encode(), headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
            result = json.load(urllib.request.urlopen(request, timeout=180))
            choice = result["choices"][0]
            if choice.get("finish_reason") == "length":
                raise ValueError("translation response truncated")
            text = choice["message"]["content"].strip()
            if text.startswith("```"):
                text = text.split("\n", 1)[1].rsplit("```", 1)[0]
            translated = json.loads(text)
            if set(translated) != set(request_values):
                raise ValueError("translation keys do not match")
            for i, original in request_values.items():
                value = translated[i]
                if not isinstance(value, str) or sorted(placeholder.findall(value)) != sorted(placeholder.findall(original)):
                    raise ValueError("translation placeholders do not match")
            return {original: translated[i] for i, original in request_values.items()}
        except Exception as error:
            if attempt == 2:
                raise RuntimeError("UI translation batch failed: " + type(error).__name__) from None
            time.sleep(2 ** attempt)

missing = [s for s in sources if s not in cache]
batches = [missing[i:i + 24] for i in range(0, len(missing), 24)]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    for future in concurrent.futures.as_completed([executor.submit(translate, batch) for batch in batches]):
        cache.update(future.result())
        args.cache.parent.mkdir(parents=True, exist_ok=True)
        args.cache.write_text(json.dumps(cache, ensure_ascii=False, indent=2))
        print(f"Translated {sum(s in cache for s in sources)}/{len(sources)} unique UI strings", flush=True)

for path, data in catalogs.items():
    for k, value in data["strings"].items():
        if not k:
            continue
        original = source(k, value)
        value.setdefault("localizations", {})["zh-Hans"] = {"stringUnit": {"state": "translated", "value": cache[original]}}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(f"Updated {len(catalogs)} Chinese catalogs", flush=True)
