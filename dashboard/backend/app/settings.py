"""Cấu hình dashboard — đọc từ environment (docker-compose service `dashboard`).

KHÔNG env_file: .env gốc của stack — dashboard không được thấy
REDIS_PASSWORD/VAULT_TOKEN/CERT_PASSPHRASE (build-prompt mục 9.5).
Secret duy nhất (GitLab token) nằm trong secrets/.netrc-dashboard,
mount vào $HOME/.netrc — git tự dùng, app không bao giờ đọc/log giá trị.
"""

from __future__ import annotations

from pathlib import Path

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    dashboard_port: int = 18080
    dc_profile: str = ""

    repo_url: str = "https://git-lab.infiniband.vn/apisix/apisix-standalone.git"
    repo_branch: str = "main"
    # Base URL web GitLab cho link commit/history — mặc định suy từ repo_url
    gitlab_web_url: str = ""

    workspace_path: Path = Path("/app/workspace")
    frontend_dist: Path = Path("/app/frontend-dist")
    log_dir: Path = Path("/app/logs")

    # Log pipeline (mount read-only từ host)
    gitsync_log: Path = Path("/host-logs/gitsync/gitsync.log")
    apisix_error_log: Path = Path("/host-logs/apisix/error.log")

    auth_mode: str = "none"  # none | basic
    htpasswd_path: Path = Path("/app/users.htpasswd")

    git_committer_name: str = "dashboard"
    git_committer_email: str = "dashboard@apisix-standalone.local"

    @property
    def web_url(self) -> str:
        if self.gitlab_web_url:
            return self.gitlab_web_url.rstrip("/")
        return self.repo_url.removesuffix(".git")


settings = Settings()
