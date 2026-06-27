import json
import threading
from pathlib import Path

LOG_FILE = Path(__file__).parent / "audit_log.json"
_lock = threading.Lock()


def append_entry(entry: dict) -> None:
    with _lock:
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")


def get_entries(limit: int = 20) -> list:
    if not LOG_FILE.exists():
        return []
    with _lock:
        lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
    entries = [json.loads(line) for line in lines if line.strip()]
    return entries[-limit:]


def find_entry(content_id: str) -> dict | None:
    for entry in get_entries(limit=10000):
        if entry.get("content_id") == content_id:
            return entry
    return None


def update_entry(content_id: str, updates: dict) -> bool:
    if not LOG_FILE.exists():
        return False
    with _lock:
        lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
        new_lines = []
        found = False
        for line in lines:
            if not line.strip():
                continue
            entry = json.loads(line)
            if entry.get("content_id") == content_id:
                entry.update(updates)
                found = True
            new_lines.append(json.dumps(entry))
        LOG_FILE.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    return found
