"""AuthProvider — adapter pattern (build-prompt mục 5).

Phase 1: none | basic. Phase sau thêm oidc (Keycloak/LDAP) = thêm 1 file provider,
KHÔNG sửa middleware/business logic.

Mọi hành động ghi đều gắn actor (username hoặc "anonymous") vào
Git commit message + audit log — bất kể auth mode.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Actor:
    username: str
    method: str  # "none" | "basic"


class AuthProvider(ABC):
    name: str = "abstract"

    @abstractmethod
    def authenticate(self, authorization_header: Optional[str]) -> Optional[Actor]:
        """Trả Actor nếu hợp lệ, None nếu từ chối (middleware sẽ trả 401)."""

    # Header thách thức khi 401 — provider tự định nghĩa
    challenge_header: Optional[str] = None


def get_provider(mode: str, htpasswd_path=None) -> AuthProvider:
    if mode == "none":
        from .none_provider import NoneProvider
        return NoneProvider()
    if mode == "basic":
        from .basic_provider import BasicProvider
        return BasicProvider(htpasswd_path)
    raise ValueError(f"AUTH_MODE không hỗ trợ: {mode} (none | basic)")
