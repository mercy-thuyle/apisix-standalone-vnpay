"""Shared singletons + FastAPI dependencies."""

from __future__ import annotations

from fastapi import HTTPException, Request

from core.audit import AuditLog
from core.repo import Workspace

from ..auth import Actor
from ..settings import settings

workspace = Workspace(
    path=settings.workspace_path,
    url=settings.repo_url,
    branch=settings.repo_branch,
    committer_name=settings.git_committer_name,
    committer_email=settings.git_committer_email,
)

audit = AuditLog(settings.log_dir / "backend" / "audit.log")


def get_actor(request: Request) -> Actor:
    actor = getattr(request.state, "actor", None)
    if actor is None:
        raise HTTPException(status_code=401, detail="Chưa xác thực")
    return actor


def ensure_workspace_ready() -> Workspace:
    try:
        workspace.ensure()
    except Exception as e:
        raise HTTPException(
            status_code=503,
            detail=f"Workspace Git chưa sẵn sàng (kiểm tra secrets/.netrc-dashboard "
                   f"và kết nối GitLab): {e}",
        ) from e
    return workspace
