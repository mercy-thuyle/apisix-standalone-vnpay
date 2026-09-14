"""Entry point — cấu hình logging theo layout logs/dashboard/{frontend,backend} rồi chạy uvicorn.

- backend/backend.log   ← application log (app + git ops + lỗi)
- frontend/frontend.log ← HTTP access log (mọi request UI tĩnh + API)
(Cấu trúc log đã chốt với chủ dự án — xem README mục logs/.)
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import sys
from pathlib import Path

LOG_DIR = Path(os.environ.get("LOG_DIR", "/app/logs"))
FMT = "%(asctime)s %(levelname)s %(name)s %(message)s"


def _handler(path: Path) -> logging.Handler:
    path.parent.mkdir(parents=True, exist_ok=True)
    h = logging.handlers.RotatingFileHandler(path, maxBytes=20 * 1024 * 1024,
                                             backupCount=3, encoding="utf-8")
    h.setFormatter(logging.Formatter(FMT))
    return h


def setup_logging() -> None:
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(logging.Formatter(FMT))

    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(stream)
    root.addHandler(_handler(LOG_DIR / "backend" / "backend.log"))

    access = logging.getLogger("uvicorn.access")
    access.propagate = False
    access.addHandler(stream)
    access.addHandler(_handler(LOG_DIR / "frontend" / "frontend.log"))


if __name__ == "__main__":
    setup_logging()
    import uvicorn

    port = int(os.environ.get("DASHBOARD_PORT", "18080"))
    # DEV: DASHBOARD_RELOAD=true + bind-mount ./dashboard/backend:/app/backend
    # (xem dòng comment trong docker-compose.yaml) → sửa .py là uvicorn tự restart.
    # KHÔNG bật trên production (watcher tốn CPU + restart giữa chừng request).
    reload = os.environ.get("DASHBOARD_RELOAD", "").lower() == "true"
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, log_config=None,
                reload=reload, reload_dirs=["/app/backend"] if reload else None)
