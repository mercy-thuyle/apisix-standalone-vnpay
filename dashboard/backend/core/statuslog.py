"""Đọc trạng thái pipeline gitsync → merge → APISIX hot-reload từ log files.

Nguồn (mount read-only vào container dashboard):
- logs/gitsync/gitsync.log   → gitsync.sh log() ghi: START / >DONE / WARN / ERROR
                               + toàn bộ output merge-fragments.sh (qua run_logged)
- logs/apisix/error.log      → dòng "config file ... reloaded" (config_yaml.lua)

Chỉ ĐỌC — dashboard không bao giờ ghi vào 2 file này.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Optional

_START_RE = re.compile(
    r"^(?P<ts>\S+)\s+\[gitsync\] START — DC_PROFILE=(?P<profile>\S+) \| "
    r"commit-id=(?P<commit>\S+) \| commit-msg=(?P<msg>.*)$")
_DONE_RE = re.compile(r"^(?P<ts>\S+)\s+\[gitsync\]\s+>DONE — commit=(?P<commit>\S+)")
_RELOADED_RE = re.compile(
    r"^(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}).*config file (?P<file>\S+) reloaded")


def tail_text(path: Path, max_bytes: int = 131072) -> str:
    """Đọc phần cuối file (log có thể rất lớn) — không load toàn bộ."""
    if not path.is_file():
        return ""
    size = path.stat().st_size
    with path.open("rb") as f:
        if size > max_bytes:
            f.seek(size - max_bytes)
            f.readline()  # bỏ dòng bị cắt giữa chừng
        return f.read().decode("utf-8", errors="replace")


def parse_gitsync(log_path: Path, tail_lines: int = 400) -> dict[str, Any]:
    lines = tail_text(log_path).splitlines()[-tail_lines:]
    last_start: Optional[dict] = None
    last_done: Optional[dict] = None
    warnings: list[str] = []
    for line in lines:
        m = _START_RE.match(line)
        if m:
            last_start = m.groupdict()
            continue
        m = _DONE_RE.match(line)
        if m:
            last_done = m.groupdict()
            continue
        if "WARN" in line or "ERROR" in line:
            warnings.append(line.strip())
    return {
        "available": log_path.is_file(),
        "last_start": last_start,
        "last_done": last_done,
        "recent_warnings": warnings[-20:],
    }


def parse_apisix_reloaded(error_log_path: Path) -> dict[str, Any]:
    last: Optional[dict] = None
    for line in tail_text(error_log_path).splitlines():
        m = _RELOADED_RE.match(line)
        if m:
            last = m.groupdict()
    return {"available": error_log_path.is_file(), "last_reloaded": last}


def gitsync_log_tail(log_path: Path, lines: int = 200) -> str:
    return "\n".join(tail_text(log_path).splitlines()[-lines:])
