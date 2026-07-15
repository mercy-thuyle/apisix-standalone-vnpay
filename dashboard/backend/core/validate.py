"""Validate fragment trước khi cho commit.

Cấp độ:
- error   → CHẶN CỨNG save (dup id/username, key mismatch, YAML lỗi,
            blacklist/whitelist rỗng — bài học incident 2026-07-03, #END, plaintext key)
- warning → cho save nhưng phải hiển thị rõ (referential, naming convention,
            prefix bucket-, yamllint warning)
- info    → gợi ý

merge-fragments.sh chỉ check cú pháp + key — validate ở đây bổ sung phần
"đáng lẽ phải có" mà script runtime không làm (theo build-prompt mục 1).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Optional

from . import fragments, yamlio
from .fragments import ENTITY_TYPES, EntityType

# Field kiểu minItems:1 trong schema plugin APISIX — mảng rỗng làm FAIL schema
# validation tại init_worker (lyaml serialize [] thành {}), gây outage 2026-07-03.
_MIN_ITEMS_FIELDS = {"blacklist", "whitelist"}

_END_FLAG_RE = re.compile(r"^\s*#END\s*$", re.MULTILINE)
_PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")


@dataclass
class Finding:
    level: str          # "error" | "warning" | "info"
    message: str
    rule: str
    line: Optional[int] = None

    def to_dict(self) -> dict:
        return asdict(self)


def _yamllint_findings(repo_root: Path, content: str) -> list[Finding]:
    """Chạy yamllint với đúng .yamllint.yaml của repo (chuẩn lint sẵn có của team)."""
    try:
        from yamllint import linter
        from yamllint.config import YamlLintConfig
    except ImportError:
        return []
    cfg_path = repo_root / ".yamllint.yaml"
    if not cfg_path.is_file():
        return []
    try:
        cfg = YamlLintConfig(file=str(cfg_path))
        problems = list(linter.run(content, cfg))
    except Exception as e:
        return [Finding("info", f"yamllint không chạy được: {e}", "yamllint")]
    out = []
    for p in problems:
        # yamllint KHÔNG chặn save: runtime không enforce yamllint (gitsync chỉ chạy
        # merge-fragments), và nhiều file production hiện có trailing-spaces.
        # Chỉ rule cấu trúc (key/dup/empty-min-items...) mới là error.
        out.append(Finding("warning", p.desc, f"yamllint:{p.rule or 'syntax'}", p.line))
    return out


def collect_ids(repo_root: Path, exclude_rel: Optional[str] = None
                ) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """Gom toàn bộ id + username trong repo (trừ file đang sửa).

    Trả (ids, usernames): value = list rel path chứa nó.
    Dup id check GLOBAL trên mọi entity type — giống Pass 3 merge-fragments.sh
    (grep '- id:' trên toàn output, không phân biệt section).
    """
    ids: dict[str, list[str]] = {}
    usernames: dict[str, list[str]] = {}
    for et in ENTITY_TYPES.values():
        for rel in fragments.list_fragment_files(repo_root, et):
            if rel == exclude_rel:
                continue
            try:
                content = (repo_root / rel).read_text(encoding="utf-8")
                if fragments.is_disabled(content):
                    continue
                data = yamlio.parse(content)
            except Exception:
                continue  # file lỗi sẵn trong repo — không chặn validate file khác
            items = data.get(et.name) if isinstance(data, dict) else None
            if not isinstance(items, list):
                continue
            for item in items:
                if not isinstance(item, dict):
                    continue
                if et.id_field == "username":
                    u = item.get("username")
                    if u:
                        usernames.setdefault(str(u), []).append(rel)
                else:
                    i = item.get("id")
                    if i:
                        ids.setdefault(str(i), []).append(rel)
    return ids, usernames


def _check_empty_min_items(data: Any, findings: list[Finding]) -> None:
    for path, key, value in yamlio.walk(data):
        if str(key) in _MIN_ITEMS_FIELDS and isinstance(value, list) and len(value) == 0:
            loc = ".".join(path + (str(key),))
            findings.append(Finding(
                "error",
                f"'{loc}' là mảng RỖNG — schema APISIX yêu cầu minItems:1, "
                "lyaml serialize [] thành {} (sai type) → FAIL schema validation "
                "tại init_worker (production outage 2026-07-03). "
                "Chưa có IP cần chặn → COMMENT toàn bộ block thay vì khai rỗng.",
                "empty-min-items",
            ))


def _check_referential(et: EntityType, items: list, ids: dict[str, list[str]],
                       findings: list[Finding]) -> None:
    """Warning nếu tham chiếu id không tồn tại đâu đó trong repo."""
    refs = {
        "service_id": "services/",
        "upstream_id": "upstreams/",
        "plugin_config_id": "plugin_configs/",
        "group_id": "consumer_groups/",
    }
    for item in items:
        if not isinstance(item, dict):
            continue
        for field_name, folder in refs.items():
            ref = item.get(field_name)
            if ref and str(ref) not in ids:
                findings.append(Finding(
                    "warning",
                    f"{field_name}: \"{ref}\" không tìm thấy trong repo "
                    f"(kiểm tra {fragments.APISIX_ROUTES_DIR}/{folder})",
                    "referential",
                ))


def validate_fragment(repo_root: Path, et: EntityType, rel: str, content: str,
                      is_new: bool = False) -> list[Finding]:
    findings: list[Finding] = []

    if not content.strip():
        return [Finding("error", "File rỗng", "empty")]

    # Disabled template (comment toàn bộ) — hợp lệ, merge script tự skip
    if fragments.is_disabled(content):
        return [Finding("info",
                        "File bị comment toàn bộ (disabled template) — "
                        "merge-fragments.sh sẽ SKIP file này.", "disabled")]

    # #END chỉ được xuất hiện 1 lần ở cuối output merge, KHÔNG trong fragment
    if _END_FLAG_RE.search(content):
        findings.append(Finding("error",
                                "KHÔNG đặt '#END' trong fragment — chỉ xuất hiện "
                                "1 lần ở cuối output do merge-fragments.sh tự thêm.",
                                "end-flag"))

    # Key đầu file phải khớp folder (hard error của merge-fragments.sh)
    fk = yamlio.first_key(content)
    if fk != et.name:
        findings.append(Finding("error",
                                f"Key mismatch: file khai báo '{fk}:' nhưng nằm trong "
                                f"folder '{et.name}/' — merge-fragments.sh sẽ ABORT.",
                                "key-mismatch"))

    # Cú pháp YAML (ruamel — bắt cả duplicate key)
    err = yamlio.syntax_error(content)
    if err:
        findings.append(Finding("error", f"YAML lỗi: {err}", "yaml-syntax"))
        findings.extend(_yamllint_findings(repo_root, content))
        return findings  # không parse được thì dừng các check cấu trúc

    data = yamlio.parse(content)
    if not isinstance(data, dict) or set(data.keys()) != {et.name}:
        extra = [k for k in data.keys() if k != et.name] if isinstance(data, dict) else []
        findings.append(Finding("error",
                                f"Fragment chỉ được chứa duy nhất key '{et.name}:' "
                                + (f"— thừa: {extra}" if extra else ""),
                                "single-key"))
        return findings

    items = data.get(et.name)
    if items is None or (isinstance(items, list) and not items):
        # Key active nhưng toàn bộ item bị comment (template "nửa tắt") — merge script
        # vẫn xử lý được (không emit item nào), vd global_rules/global-loki-logger.yaml
        findings.append(Finding("warning",
                                f"'{et.name}:' không có item nào đang active "
                                "(toàn bộ item bị comment?)", "no-active-items"))
        findings.extend(_yamllint_findings(repo_root, content))
        return findings
    if not isinstance(items, list):
        findings.append(Finding("error", f"'{et.name}:' phải là danh sách item",
                                "items-list"))
        return findings

    # id/username bắt buộc + dup trong file
    seen: dict[str, int] = {}
    for idx, item in enumerate(items):
        if not isinstance(item, dict):
            findings.append(Finding("error", f"Item #{idx + 1} không phải mapping", "item-shape"))
            continue
        ident = item.get(et.id_field)
        if not ident:
            findings.append(Finding("error",
                                    f"Item #{idx + 1} thiếu '{et.id_field}'", "missing-id"))
            continue
        ident = str(ident)
        if ident in seen:
            findings.append(Finding("error",
                                    f"Duplicate {et.id_field} '{ident}' trong cùng file",
                                    "dup-in-file"))
        seen[ident] = idx

    # Dup id/username so với phần còn lại của repo — CHẶN CỨNG
    # (merge-fragments.sh chỉ WARNING, nhưng build-prompt yêu cầu dashboard chặn)
    ids, usernames = collect_ids(repo_root, exclude_rel=None if is_new else rel)
    pool = usernames if et.id_field == "username" else ids
    for ident in seen:
        if ident in pool:
            findings.append(Finding("error",
                                    f"Duplicate {et.id_field} '{ident}' — đã tồn tại trong: "
                                    f"{', '.join(pool[ident])}",
                                    "dup-in-repo"))

    _check_empty_min_items(data, findings)
    _check_referential(et, items, ids, findings)

    # Convention riêng từng loại
    if et.name == "routes":
        for item in items:
            if not isinstance(item, dict) or not item.get("id"):
                continue
            rid = str(item["id"])
            if not fragments.ROUTE_ID_RE.match(rid):
                findings.append(Finding("warning",
                                        f"Route id \"{rid}\" không theo convention "
                                        "route-<domain>-<scheme>-<port>",
                                        "route-naming"))
        fname = Path(rel).name
        if len(items) == 1 and items[0].get("id") and f"{items[0]['id']}.yaml" != fname:
            findings.append(Finding("info",
                                    f"Tên file '{fname}' nên khớp route id "
                                    f"'{items[0]['id']}.yaml'", "route-filename"))

    if et.name == "consumers":
        for item in items:
            if not isinstance(item, dict):
                continue
            plugins = item.get("plugins") or {}
            uname = str(item.get("username", ""))
            if isinstance(plugins, dict) and "custom.s3-bucket-name-consumer" in plugins \
                    and not uname.startswith("bucket-"):
                findings.append(Finding("warning",
                                        f"Consumer '{uname}' dùng custom.s3-bucket-name-consumer "
                                        "→ username phải có prefix 'bucket-'",
                                        "bucket-prefix"))
            key_auth = plugins.get("key-auth") if isinstance(plugins, dict) else None
            if isinstance(key_auth, dict):
                key = str(key_auth.get("key", ""))
                if key and not key.lower().startswith(("$env://", "$secret://")):
                    findings.append(Finding("warning",
                                            f"Consumer '{uname}' có key-auth.key dạng plaintext — "
                                            "PHẢI dùng $env:// hoặc $secret://, KHÔNG commit "
                                            "credential plaintext lên repo.",
                                            "plaintext-credential"))

    if et.name == "ssls":
        if _PRIVATE_KEY_RE.search(content):
            findings.append(Finding("error",
                                    "Phát hiện PRIVATE KEY plaintext trong fragment — "
                                    "cert/key do inject-certs.sh tự inject lúc runtime, "
                                    "KHÔNG commit private key lên repo.",
                                    "plaintext-private-key"))

    findings.extend(_yamllint_findings(repo_root, content))
    return findings


def has_errors(findings: list[Finding]) -> bool:
    return any(f.level == "error" for f in findings)
