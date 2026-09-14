"""Trạng thái pipeline: gitsync pull/merge → APISIX hot-reload (đọc log, read-only)."""

from __future__ import annotations

from fastapi import APIRouter, Query
from fastapi.responses import PlainTextResponse

from core import statuslog

from ..settings import settings
from .deps import workspace

router = APIRouter(prefix="/api/status", tags=["status"])


@router.get("")
def status() -> dict:
    head = None
    try:
        head = workspace.head_sha()
    except Exception:
        pass
    return {
        "dc_profile": settings.dc_profile,
        "workspace_head": head,
        "gitsync": statuslog.parse_gitsync(settings.gitsync_log),
        "apisix": statuslog.parse_apisix_reloaded(settings.apisix_error_log),
        "hint": "Sau khi push: gitsync pull (~30s) → merge-fragments → inject-certs → "
                "APISIX tự hot-reload (log 'config file ... reloaded'). "
                "Đối chiếu commit-id trong gitsync log với commit vừa push.",
    }


@router.get("/gitsync-log", response_class=PlainTextResponse)
def gitsync_log(lines: int = Query(default=200, le=1000)) -> str:
    return statuslog.gitsync_log_tail(settings.gitsync_log, lines)
