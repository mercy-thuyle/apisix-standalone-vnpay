"""Audit log JSONL — append-only, machine-parseable.

Phase 1: logs/dashboard/backend/audit.log (CRUD entity).
Phase 2 sẽ thêm audit-control-plane.log riêng (mức rủi ro cao hơn).
"""

from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

_lock = threading.Lock()


class AuditLog:
    def __init__(self, path: Path):
        self.path = Path(path)

    def write(self, *, actor: str, action: str, entity_type: str, path: str,
              ok: bool, commit: Optional[str] = None, note: str = "",
              detail: Optional[dict[str, Any]] = None) -> None:
        record = {
            "ts": datetime.now(timezone.utc).astimezone().isoformat(),
            "actor": actor,
            "action": action,          # create | update | delete | disable | enable
            "entity_type": entity_type,
            "path": path,
            "ok": ok,
            "commit": commit,
            "note": note or None,
            "detail": detail or None,
        }
        line = json.dumps(record, ensure_ascii=False)
        with _lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")

    def tail(self, limit: int = 100) -> list[dict]:
        if not self.path.is_file():
            return []
        lines = self.path.read_text(encoding="utf-8").splitlines()[-limit:]
        out = []
        for line in lines:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return list(reversed(out))
