"""YAML I/O helpers.

Nguyên tắc Phase 1: dashboard cho user sửa RAW TEXT (Monaco) và ghi nguyên văn —
comment nghiệp vụ được giữ 100% vì không bao giờ re-serialize.
ruamel.yaml chỉ dùng để PARSE (validate + trích id/name).
"""

from __future__ import annotations

import re
from io import StringIO
from typing import Any, Optional

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError

_COMMENT_OR_BLANK_RE = re.compile(r"^\s*(#|$)")


def _yaml() -> YAML:
    y = YAML(typ="rt")  # round-trip: giữ vị trí lỗi chính xác, bắt duplicate key
    y.preserve_quotes = True
    return y


def parse(content: str) -> Any:
    """Parse YAML — raise YAMLError nếu sai cú pháp/duplicate key."""
    return _yaml().load(StringIO(content))


def syntax_error(content: str) -> Optional[str]:
    """Trả message lỗi cú pháp (kèm dòng) hoặc None nếu hợp lệ."""
    try:
        parse(content)
        return None
    except YAMLError as e:
        return str(e)
    except Exception as e:  # ruamel đôi khi raise lỗi khác cho input hỏng nặng
        return str(e)


def first_key(content: str) -> Optional[str]:
    """Mô phỏng get_file_key() của merge-fragments.sh:

    dòng đầu tiên không phải comment/blank → phần trước ':' (strip space).
    Trả None nếu toàn bộ file là comment/blank (disabled template).
    """
    for line in content.splitlines():
        if _COMMENT_OR_BLANK_RE.match(line):
            continue
        return line.split(":", 1)[0].replace(" ", "")
    return None


def walk(node: Any, path: tuple = ()):  # noqa: ANN001
    """Duyệt đệ quy cấu trúc parse được — yield (path, key, value) cho mọi mapping entry."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield path, k, v
            yield from walk(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, path + (f"[{i}]",))
