from __future__ import annotations

from pathlib import Path

import pytest

# repo_root = root của repo apisix-standalone (chứa apisix_routes/, .yamllint.yaml)
# tests/ nằm tại dashboard/backend/tests/ → lùi 3 cấp
REPO_ROOT = Path(__file__).resolve().parents[3]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    assert (REPO_ROOT / "apisix_routes").is_dir(), f"Không tìm thấy apisix_routes/ tại {REPO_ROOT}"
    return REPO_ROOT
