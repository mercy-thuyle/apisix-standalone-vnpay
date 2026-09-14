"""Git history / thông tin repo. Revert: Phase 1 chỉ trả link GitLab (placeholder)."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query

from ..settings import settings
from .deps import audit, ensure_workspace_ready

router = APIRouter(prefix="/api/git", tags=["git"])


@router.get("/history")
def history(path: str = Query(default=""), limit: int = Query(default=30, le=100)) -> dict:
    ws = ensure_workspace_ready()
    ws.sync()
    commits = ws.history(rel=path or None, limit=limit)
    for c in commits:
        c["web_url"] = f"{settings.web_url}/-/commit/{c['sha']}"
        # Phase 1: revert chưa thực thi — link sang GitLab để revert thủ công (mục 9.7)
        c["revert_hint"] = f"{settings.web_url}/-/commit/{c['sha']}#revert"
    return {
        "path": path or None,
        "commits": commits,
        "file_history_url": (f"{settings.web_url}/-/commits/{settings.repo_branch}/{path}"
                             if path else f"{settings.web_url}/-/commits/{settings.repo_branch}"),
    }


@router.get("/info")
def info() -> dict:
    ws = ensure_workspace_ready()
    ws.sync()
    return {
        "branch": settings.repo_branch,
        "head_sha": ws.head_sha(),
        "web_url": settings.web_url,
    }


@router.get("/audit")
def audit_tail(limit: int = Query(default=50, le=500)) -> dict:
    return {"records": audit.tail(limit)}
