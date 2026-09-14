"""Auth mode 'basic' — HTTP Basic với file htpasswd-style (bcrypt).

Tạo file (trên VM):
  htpasswd -B -c secrets/dashboard-users.htpasswd <username>
  chmod 600 secrets/dashboard-users.htpasswd
Mount read-only: ./secrets/dashboard-users.htpasswd:/app/users.htpasswd:ro
"""

from __future__ import annotations

import base64
import binascii
import logging
from pathlib import Path
from typing import Optional

import bcrypt

from .provider import Actor, AuthProvider

log = logging.getLogger("dashboard.auth")


class BasicProvider(AuthProvider):
    name = "basic"
    challenge_header = 'Basic realm="apisix-dashboard"'

    def __init__(self, htpasswd_path: Path):
        self.htpasswd_path = Path(htpasswd_path)

    def _users(self) -> dict[str, str]:
        users: dict[str, str] = {}
        if not self.htpasswd_path.is_file():
            log.error("htpasswd không tồn tại: %s", self.htpasswd_path)
            return users
        for line in self.htpasswd_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            user, hashed = line.split(":", 1)
            users[user] = hashed
        return users

    def authenticate(self, authorization_header: Optional[str]) -> Optional[Actor]:
        if not authorization_header or not authorization_header.startswith("Basic "):
            return None
        try:
            decoded = base64.b64decode(authorization_header[6:]).decode("utf-8")
            username, _, password = decoded.partition(":")
        except (binascii.Error, UnicodeDecodeError):
            return None
        hashed = self._users().get(username)
        if not hashed:
            return None
        if not hashed.startswith(("$2a$", "$2b$", "$2y$")):
            log.error("Hash của user %s không phải bcrypt — dùng htpasswd -B", username)
            return None
        try:
            ok = bcrypt.checkpw(password.encode(), hashed.encode())
        except ValueError:
            return None
        return Actor(username=username, method="basic") if ok else None
