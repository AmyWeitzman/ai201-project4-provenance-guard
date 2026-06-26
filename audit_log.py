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
