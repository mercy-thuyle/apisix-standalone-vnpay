"""CRUD 8 loại entity fragment — luồng ghi theo build-prompt mục 2.

Mọi write: sync → validate → (client đã xem diff + xác nhận) → commit → push main.
Optimistic lock: client gửi base_blob (blob sha lúc load) → 409 nếu đã bị đổi.
"""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from core import fragments, validate
from core.repo import Conflict, FileChange, PushRejected, build_commit_message

from ..auth import Actor
from ..settings import settings
from .deps import audit, ensure_workspace_ready, get_actor

log = logging.getLogger("dashboard.api")
router = APIRouter(prefix="/api/entities", tags=["entities"])


def _etype(etype: str) -> fragments.EntityType:
    try:
        return fragments.get(etype)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e


def _check_path(et: fragments.EntityType, rel: str) -> None:
    if not fragments.is_safe_rel_path(et, rel):
        raise HTTPException(status_code=400, detail=f"Path không hợp lệ: {rel}")


def _first_ident(et: fragments.EntityType, content: str, fallback: str) -> str:
    try:
        items = fragments.parse_items(et, content)
        if items and items[0].get("id"):
            return str(items[0]["id"])
    except Exception:
        pass
    return fallback


class SaveRequest(BaseModel):
    path: str
    content: str
    note: str = ""
    base_blob: Optional[str] = None  # None = file mới
    action: str = "update"           # create | update


class DeleteRequest(BaseModel):
    path: str
    note: str = ""
    base_blob: Optional[str] = None


class ToggleRequest(BaseModel):
    path: str
    disable: bool
    note: str = ""
    base_blob: Optional[str] = None
    preview: bool = False  # True = chỉ trả old/new content để UI hiển thị diff, KHÔNG commit


class ValidateRequest(BaseModel):
    path: str
    content: str
    is_new: bool = False


@router.get("")
def entity_meta() -> dict:
    return {
        "entity_types": [
            {"name": et.name, "label": et.label, "grouped": et.grouped,
             "id_field": et.id_field, "core": et.core}
            for et in fragments.ENTITY_TYPES.values()
        ],
    }


@router.get("/{etype}")
def list_entities(etype: str) -> dict:
    et = _etype(etype)
    ws = ensure_workspace_ready()
    ws.sync()
    infos = [fragments.fragment_info(ws.path, et, rel)
             for rel in fragments.list_fragment_files(ws.path, et)]
    groups = sorted({i["group"] for i in infos if i["group"]}) if et.grouped else []
    return {"entity_type": et.name, "files": infos, "groups": groups,
            "head_sha": ws.head_sha()}


@router.get("/{etype}/file")
def get_file(etype: str, path: str = Query(...)) -> dict:
    et = _etype(etype)
    _check_path(et, path)
    ws = ensure_workspace_ready()
    ws.sync(force=True)  # yêu cầu build-prompt: pull mới nhất trước khi mở form edit
    content = ws.file_content(path)
    if content is None:
        raise HTTPException(status_code=404, detail=f"File không tồn tại: {path}")
    return {
        "path": path,
        "content": content,
        "blob_sha": ws.blob_sha(path),
        "head_sha": ws.head_sha(),
        "disabled": fragments.is_disabled(content),
    }


@router.get("/{etype}/template")
def get_template(etype: str, entity_id: str = "", group: str = "",
                 domain: str = "", scheme: str = "https", port: int = 443) -> dict:
    et = _etype(etype)
    try:
        rel = fragments.suggest_path(et, entity_id=entity_id, group=group,
                                     domain=domain, scheme=scheme, port=port)
        if et.name == "routes":
            content = fragments.template(et, domain=domain, scheme=scheme, port=port)
        else:
            content = fragments.template(et, entity_id=entity_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    ws = ensure_workspace_ready()
    if (ws.path / rel).exists():
        raise HTTPException(status_code=409, detail=f"File đã tồn tại: {rel}")
    return {"path": rel, "content": content}


@router.post("/{etype}/validate")
def validate_entity(etype: str, req: ValidateRequest) -> dict:
    et = _etype(etype)
    _check_path(et, req.path)
    ws = ensure_workspace_ready()
    ws.sync()
    findings = validate.validate_fragment(ws.path, et, req.path, req.content,
                                          is_new=req.is_new)
    return {"findings": [f.to_dict() for f in findings],
            "has_errors": validate.has_errors(findings)}


def _do_commit(et: fragments.EntityType, actor: Actor, *, path: str, action: str,
               ident: str, note: str, changes: list[FileChange],
               base_blobs: dict) -> dict:
    ws = ensure_workspace_ready()
    message = build_commit_message(et.name, action, ident, actor.username, note)
    try:
        sha = ws.commit_and_push(changes, message, actor.username, base_blobs)
    except Conflict as c:
        audit.write(actor=actor.username, action=action, entity_type=et.name,
                    path=path, ok=False, note=note, detail={"error": "conflict"})
        raise HTTPException(status_code=409, detail={
            "error": "conflict",
            "message": "File đã bị thay đổi bởi commit khác kể từ khi bạn mở form. "
                       "Xem nội dung mới và áp lại thay đổi của bạn.",
            "current_content": c.current_content,
            "current_blob": c.current_blob,
        }) from c
    except PushRejected as e:
        audit.write(actor=actor.username, action=action, entity_type=et.name,
                    path=path, ok=False, note=note, detail={"error": str(e)})
        raise HTTPException(status_code=502, detail=f"Push lên GitLab thất bại: {e}") from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    audit.write(actor=actor.username, action=action, entity_type=et.name,
                path=path, ok=True, commit=sha, note=note)
    return {
        "commit": sha,
        "commit_short": sha[:10],
        "commit_url": f"{settings.web_url}/-/commit/{sha}",
        "message": message,
        "next": "Đã push lên main — gitsync sẽ pull trong ~30s, merge-fragments chạy, "
                "APISIX tự hot-reload. Theo dõi ở trang Status.",
    }


@router.post("/{etype}/save")
def save_entity(etype: str, req: SaveRequest, actor: Actor = Depends(get_actor)) -> dict:
    et = _etype(etype)
    _check_path(et, req.path)
    if req.action not in ("create", "update"):
        raise HTTPException(status_code=400, detail=f"action không hợp lệ: {req.action}")

    ws = ensure_workspace_ready()
    ws.sync(force=True)
    findings = validate.validate_fragment(ws.path, et, req.path, req.content,
                                          is_new=(req.action == "create"))
    if validate.has_errors(findings):
        raise HTTPException(status_code=422, detail={
            "error": "validation",
            "findings": [f.to_dict() for f in findings],
        })

    content = req.content if req.content.endswith("\n") else req.content + "\n"
    ident = _first_ident(et, content, fallback=req.path.rsplit("/", 1)[-1])
    result = _do_commit(et, actor, path=req.path, action=req.action, ident=ident,
                        note=req.note,
                        changes=[FileChange(req.path, content)],
                        base_blobs={req.path: req.base_blob})
    result["findings"] = [f.to_dict() for f in findings]  # warnings đi kèm kết quả
    return result


@router.post("/{etype}/delete")
def delete_entity(etype: str, req: DeleteRequest, actor: Actor = Depends(get_actor)) -> dict:
    et = _etype(etype)
    _check_path(et, req.path)
    ws = ensure_workspace_ready()
    ws.sync(force=True)
    old = ws.file_content(req.path)
    if old is None:
        raise HTTPException(status_code=404, detail=f"File không tồn tại: {req.path}")
    ident = _first_ident(et, old, fallback=req.path.rsplit("/", 1)[-1])
    return _do_commit(et, actor, path=req.path, action="delete", ident=ident,
                      note=req.note,
                      changes=[FileChange(req.path, None)],
                      base_blobs={req.path: req.base_blob})


@router.post("/{etype}/toggle")
def toggle_entity(etype: str, req: ToggleRequest, actor: Actor = Depends(get_actor)) -> dict:
    """Disable = comment toàn file (giữ lịch sử, merge script tự skip) / Enable = bỏ comment."""
    et = _etype(etype)
    _check_path(et, req.path)
    ws = ensure_workspace_ready()
    ws.sync(force=True)
    old = ws.file_content(req.path)
    if old is None:
        raise HTTPException(status_code=404, detail=f"File không tồn tại: {req.path}")

    if req.disable:
        if fragments.is_disabled(old):
            raise HTTPException(status_code=400, detail="File đã disabled sẵn")
        new_content = fragments.disable(old)
        action = "disable"
    else:
        if not fragments.is_disabled(old):
            raise HTTPException(status_code=400, detail="File đang enabled sẵn")
        new_content = fragments.enable(old)
        findings = validate.validate_fragment(ws.path, et, req.path, new_content)
        if validate.has_errors(findings):
            raise HTTPException(status_code=422, detail={
                "error": "validation",
                "message": "Nội dung sau khi enable không hợp lệ — sửa trong editor trước.",
                "findings": [f.to_dict() for f in findings],
            })
        action = "enable"

    if req.preview:
        return {"preview": True, "old_content": old, "new_content": new_content,
                "blob_sha": ws.blob_sha(req.path)}

    ident = _first_ident(et, new_content if action == "enable" else old,
                         fallback=req.path.rsplit("/", 1)[-1])
    return _do_commit(et, actor, path=req.path, action=action, ident=ident,
                      note=req.note,
                      changes=[FileChange(req.path, new_content)],
                      base_blobs={req.path: req.base_blob})
