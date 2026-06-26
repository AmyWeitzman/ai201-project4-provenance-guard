import json
import threading
import uuid
from pathlib import Path

CERT_FILE = Path(__file__).parent / "certificates.json"
_lock = threading.Lock()


def issue_certificate(entry: dict) -> str:
    certificate_id = str(uuid.uuid4())
    record = {"certificate_id": certificate_id, **entry}
    with _lock:
        with CERT_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    return certificate_id


def find_by_content(content_id: str) -> dict | None:
    if not CERT_FILE.exists():
        return None
    with _lock:
        lines = CERT_FILE.read_text(encoding="utf-8").splitlines()
    for line in lines:
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry.get("content_id") == content_id:
            return entry
    return None


def find_by_id(certificate_id: str) -> dict | None:
    if not CERT_FILE.exists():
        return None
    with _lock:
        lines = CERT_FILE.read_text(encoding="utf-8").splitlines()
    for line in lines:
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry.get("certificate_id") == certificate_id:
            return entry
    return None
