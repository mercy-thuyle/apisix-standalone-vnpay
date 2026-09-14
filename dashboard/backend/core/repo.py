"""Git workspace của dashboard — clone RIÊNG (dashboard-workspace/), KHÔNG đụng gitsync/.

Luồng ghi (Phase 1 — push thẳng main):
  sync() → ghi file → commit (author = actor) → push origin main
  push bị reject (ai đó vừa push) → pull --rebase → push lại 1 lần.

Auth: git đọc HTTPS credential từ $HOME/.netrc
(mount secrets/.netrc-dashboard → /app/.netrc, token RIÊNG — không share gitsync).

Phase 3 sẽ thêm strategy "branch-mr" — giữ interface commit_and_push() ổn định.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from git import Repo
from git.exc import GitCommandError

log = logging.getLogger("dashboard.repo")

COMMIT_TAG = "[dashboard]"


class PushRejected(Exception):
    """Push thất bại sau khi đã retry rebase."""


class Conflict(Exception):
    """File đã bị thay đổi bởi commit khác kể từ khi user mở form (optimistic lock)."""

    def __init__(self, rel: str, current_content: Optional[str], current_blob: Optional[str]):
        super().__init__(f"Conflict: {rel} đã thay đổi trên remote")
        self.rel = rel
        self.current_content = current_content
        self.current_blob = current_blob


@dataclass
class FileChange:
    rel: str
    content: Optional[str]  # None = xoá file


def build_commit_message(entity_type: str, action: str, ident: str,
                         actor: str, note: str = "") -> str:
    """Format chuẩn theo build-prompt mục 2:
    [dashboard] <entity_type> <action> <id/name> by <user> — <ghi chú optional>
    """
    msg = f"{COMMIT_TAG} {entity_type} {action} {ident} by {actor}"
    if note.strip():
        msg += f" — {note.strip()}"
    return msg


class Workspace:
    def __init__(self, path: Path, url: str, branch: str = "main",
                 committer_name: str = "dashboard",
                 committer_email: str = "dashboard@apisix-standalone.local",
                 sync_min_interval: float = 5.0):
        self.path = Path(path)
        self.url = url
        self.branch = branch
        self.committer_name = committer_name
        self.committer_email = committer_email
        self._lock = threading.RLock()
        self._last_sync = 0.0
        self._sync_min_interval = sync_min_interval

    # ── Setup ────────────────────────────────────────────────────────────────

    def ensure(self) -> None:
        """Clone nếu chưa có; set identity + fileMode false (theo README)."""
        with self._lock:
            if not (self.path / ".git").is_dir():
                log.info("Clone %s -> %s", self.url, self.path)
                self.path.mkdir(parents=True, exist_ok=True)
                Repo.clone_from(self.url, self.path, branch=self.branch)
            r = self._repo()
            with r.config_writer() as cw:
                cw.set_value("user", "name", self.committer_name)
                cw.set_value("user", "email", self.committer_email)
                cw.set_value("core", "fileMode", "false")

    def _repo(self) -> Repo:
        return Repo(self.path)

    # ── Sync / đọc ───────────────────────────────────────────────────────────

    def sync(self, force: bool = False) -> None:
        """fetch + reset --hard origin/<branch> + clean.

        Workspace là clone riêng chỉ dashboard dùng, mọi commit đều push ngay —
        reset cứng an toàn và đảm bảo luôn đọc bản mới nhất trước khi mở form
        (yêu cầu build-prompt mục 2). Throttle để list view không fetch dồn dập.
        """
        with self._lock:
            now = time.monotonic()
            if not force and (now - self._last_sync) < self._sync_min_interval:
                return
            r = self._repo()
            r.remotes.origin.fetch()
            r.git.checkout(self.branch)
            r.git.reset("--hard", f"origin/{self.branch}")
            r.git.clean("-fdq")
            self._last_sync = time.monotonic()

    def head_sha(self) -> str:
        return self._repo().head.commit.hexsha

    def file_content(self, rel: str) -> Optional[str]:
        p = self.path / rel
        if not p.is_file():
            return None
        return p.read_text(encoding="utf-8")

    def blob_sha(self, rel: str) -> Optional[str]:
        """Blob sha của file tại HEAD — dùng làm optimistic lock token."""
        try:
            return self._repo().git.rev_parse(f"HEAD:{rel}")
        except GitCommandError:
            return None

    # ── Ghi ──────────────────────────────────────────────────────────────────

    def commit_and_push(self, changes: list[FileChange], message: str, actor: str,
                        base_blobs: Optional[dict[str, Optional[str]]] = None) -> str:
        """Ghi thay đổi → commit → push. Trả commit sha.

        base_blobs: {rel: blob_sha lúc user load} — khác blob hiện tại → Conflict 409.
        base_blob None = user tạo file MỚI → conflict nếu file đã tồn tại.
        """
        with self._lock:
            self.sync(force=True)
            r = self._repo()

            if base_blobs:
                for rel, base in base_blobs.items():
                    current = self.blob_sha(rel)
                    if current != base:
                        raise Conflict(rel, self.file_content(rel), current)

            for ch in changes:
                p = self.path / ch.rel
                if ch.content is None:
                    if p.is_file():
                        r.git.rm("--", ch.rel)
                else:
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_text(ch.content, encoding="utf-8")
                    r.git.add("--", ch.rel)

            if not r.index.diff("HEAD") and not r.git.diff("--cached", "--name-only"):
                raise ValueError("Không có thay đổi nào để commit")

            author = f"{actor} (dashboard) <{actor}@dashboard.local>"
            r.git.commit("-m", message, f"--author={author}")
            sha = r.head.commit.hexsha

            try:
                r.git.push("origin", self.branch)
            except GitCommandError:
                log.warning("Push rejected — thử pull --rebase rồi push lại")
                try:
                    r.git.pull("--rebase", "origin", self.branch)
                    r.git.push("origin", self.branch)
                    sha = r.head.commit.hexsha
                except GitCommandError as e2:
                    r.git.rebase("--abort")
                    self.sync(force=True)
                    raise PushRejected(f"Push thất bại sau retry: {e2}") from e2
            return sha

    # ── History ──────────────────────────────────────────────────────────────

    def history(self, rel: Optional[str] = None, limit: int = 30) -> list[dict]:
        r = self._repo()
        kwargs = {"max_count": limit}
        if rel:
            kwargs["paths"] = rel
        out = []
        for c in r.iter_commits(self.branch, **kwargs):
            out.append({
                "sha": c.hexsha,
                "short": c.hexsha[:10],
                "author": c.author.name,
                "email": c.author.email,
                "date": c.committed_datetime.isoformat(),
                "subject": c.summary,
            })
        return out
