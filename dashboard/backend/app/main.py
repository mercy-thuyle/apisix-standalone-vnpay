"""FastAPI app — API + serve SPA build (frontend-dist).

Auth middleware áp cho MỌI request trừ /healthz — tách hoàn toàn khỏi
business logic (adapter pattern, build-prompt mục 5).
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from core import fragments

from .api import entities, gitops, status
from .api.deps import workspace
from .auth import get_provider
from .settings import settings

log = logging.getLogger("dashboard")


def create_app() -> FastAPI:
    app = FastAPI(title="APISIX Standalone Config Dashboard", docs_url=None, redoc_url=None)

    provider = get_provider(settings.auth_mode, settings.htpasswd_path)
    log.info("Auth mode: %s", provider.name)

    @app.middleware("http")
    async def auth_middleware(request: Request, call_next):
        if request.url.path == "/healthz":
            return await call_next(request)
        actor = provider.authenticate(request.headers.get("Authorization"))
        if actor is None:
            headers = {}
            if provider.challenge_header:
                headers["WWW-Authenticate"] = provider.challenge_header
            return JSONResponse(status_code=401,
                                content={"detail": "Chưa xác thực"}, headers=headers)
        request.state.actor = actor
        return await call_next(request)

    @app.get("/healthz")
    def healthz() -> dict:
        return {"ok": True}

    @app.get("/api/meta")
    def meta(request: Request) -> dict:
        return {
            "dc_profile": settings.dc_profile,
            "branch": settings.repo_branch,
            "gitlab_web_url": settings.web_url,
            "auth_mode": settings.auth_mode,
            "actor": request.state.actor.username,
            "entity_types": [
                {"name": et.name, "label": et.label, "grouped": et.grouped,
                 "id_field": et.id_field, "core": et.core}
                for et in fragments.ENTITY_TYPES.values()
            ],
        }

    app.include_router(entities.router)
    app.include_router(gitops.router)
    app.include_router(status.router)

    # ── SPA static ────────────────────────────────────────────────────────────
    dist = settings.frontend_dist
    if (dist / "assets").is_dir():
        app.mount("/assets", StaticFiles(directory=dist / "assets"), name="assets")

    @app.get("/{full_path:path}", include_in_schema=False)
    def spa(full_path: str) -> Response:
        # deep-link SPA (vd /entities/routes) → index.html; file tĩnh khác nếu tồn tại
        if full_path and not full_path.startswith("api"):
            candidate = dist / full_path
            if candidate.is_file():
                return FileResponse(candidate)
        index = dist / "index.html"
        if index.is_file():
            return FileResponse(index)
        return JSONResponse(status_code=404, content={"detail": "frontend chưa được build"})

    @app.on_event("startup")
    def startup() -> None:
        try:
            workspace.ensure()
            workspace.sync(force=True)
            log.info("Workspace sẵn sàng: %s @ %s", workspace.path, workspace.head_sha()[:10])
        except Exception as e:
            # Không crash app — endpoint sẽ trả 503 kèm hướng dẫn khi user thao tác
            log.error("Workspace chưa sẵn sàng: %s", e)

    return app


app = create_app()
