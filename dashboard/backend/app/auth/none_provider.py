"""Auth mode 'none' — chạy trong internal network/VPN only.

Mọi request được chấp nhận, actor = "anonymous" (vẫn ghi audit + commit message).
"""

from __future__ import annotations

from typing import Optional

from .provider import Actor, AuthProvider


class NoneProvider(AuthProvider):
    name = "none"

    def authenticate(self, authorization_header: Optional[str]) -> Optional[Actor]:
        return Actor(username="anonymous", method="none")
