"""Entity fragment mapping cho apisix_routes/.

Bám sát quy tắc của scripts/runtime/merge-fragments.sh:
- File phải mở đầu bằng key khớp tên folder chứa nó.
- File bị comment toàn bộ = disabled template (skip, không lỗi).
- KHÔNG đặt #END trong fragment.
- routes/ có subfolder theo workload (depth 2); các folder khác flat (depth 1).
  merge-fragments.sh glob cả depth 1 lẫn depth 2 cho routes/ nên file flat
  trong routes/ vẫn hợp lệ — dashboard list cả hai.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from . import yamlio

APISIX_ROUTES_DIR = "apisix_routes"


@dataclass(frozen=True)
class EntityType:
    name: str            # tên folder == YAML key (vd "routes")
    id_field: str        # "id" | "username"
    grouped: bool        # True = có subfolder theo workload (routes/)
    label: str           # nhãn hiển thị UI
    core: bool           # True = thư mục bắt buộc theo merge-fragments.sh


# Thứ tự = chuỗi áp dụng/ghi đè plugin của APISIX (sidebar render theo thứ tự này):
# Upstream (không có plugin, nền LB) → Service → Plugin Config → Route →
# Consumer Group → Consumer (càng xuống càng ưu tiên ghi đè, Consumer cao nhất).
# Global Rules NGOÀI chuỗi override (plugin cùng tên chạy CẢ HAI, tuần tự); SSL không có plugin.
# https://apisix.apache.org/docs/apisix/terminology/plugin/
ENTITY_TYPES: dict[str, EntityType] = {
    "upstreams": EntityType("upstreams", "id", False, "Upstreams", True),
    "services": EntityType("services", "id", False, "Services", True),
    "plugin_configs": EntityType("plugin_configs", "id", False, "Plugin Configs (QoS)", False),
    "routes": EntityType("routes", "id", True, "Routes", True),
    "consumer_groups": EntityType("consumer_groups", "id", False, "Consumer Groups", False),
    "consumers": EntityType("consumers", "username", False, "Consumers", False),
    "global_rules": EntityType("global_rules", "id", False, "Global Rules", False),
    "ssls": EntityType("ssls", "id", False, "SSLs", True),
}

# Các entity nằm trong chuỗi override plugin (để UI nhóm sidebar)
PLUGIN_CHAIN = ["upstreams", "services", "plugin_configs", "routes",
                "consumer_groups", "consumers"]

# Convention naming route (mục 1 build-prompt): route-<domain>-<scheme>-<port>
ROUTE_ID_RE = re.compile(r"^route-(?P<domain>.+)-(?P<scheme>https?)-(?P<port>\d+)$")

_SAFE_SEGMENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def get(etype: str) -> EntityType:
    if etype not in ENTITY_TYPES:
        raise KeyError(f"Entity type không hợp lệ: {etype}")
    return ENTITY_TYPES[etype]


def fragment_dir(repo_root: Path, et: EntityType) -> Path:
    return repo_root / APISIX_ROUTES_DIR / et.name


def is_safe_rel_path(et: EntityType, rel: str) -> bool:
    """Chặn path traversal; rel phải nằm trong apisix_routes/<folder>/ và là *.yaml."""
    parts = Path(rel).parts
    if len(parts) < 3 or parts[0] != APISIX_ROUTES_DIR or parts[1] != et.name:
        return False
    if not rel.endswith(".yaml"):
        return False
    depth = len(parts) - 2  # số segment sau apisix_routes/<folder>/
    if depth > (2 if et.grouped else 1):
        return False
    return all(_SAFE_SEGMENT_RE.match(p) for p in parts[2:])


def list_fragment_files(repo_root: Path, et: EntityType) -> list[str]:
    """Trả rel paths (so với repo root), sorted — mô phỏng glob_yaml_files."""
    base = fragment_dir(repo_root, et)
    if not base.is_dir():
        return []
    found: list[str] = []
    for f in sorted(base.glob("*.yaml")):
        if f.is_file():
            found.append(str(f.relative_to(repo_root)))
    if et.grouped:
        for sub in sorted(p for p in base.iterdir() if p.is_dir()):
            for f in sorted(sub.glob("*.yaml")):
                if f.is_file():
                    found.append(str(f.relative_to(repo_root)))
    return sorted(found)


# ── Disabled template (comment toàn file) ────────────────────────────────────

def is_disabled(content: str) -> bool:
    """True nếu mọi dòng non-blank đều là comment (= merge-fragments skip)."""
    return yamlio.first_key(content) is None


def disable(content: str) -> str:
    """Comment toàn bộ nội dung — prefix '# ' vào mỗi dòng non-blank.

    Round-trip chính xác với enable(): comment sẵn có '# foo' → '# # foo'.
    """
    out = []
    for line in content.splitlines():
        out.append(f"# {line}" if line.strip() else line)
    return "\n".join(out) + ("\n" if content.endswith("\n") else "")


def enable(content: str) -> str:
    """Bỏ 1 lớp comment '# ' (hoặc '#') ở đầu mỗi dòng."""
    out = []
    for line in content.splitlines():
        if line.startswith("# "):
            out.append(line[2:])
        elif line.startswith("#") and line.strip() != "#":
            out.append(line[1:])
        elif line.strip() == "#":
            out.append("")
        else:
            out.append(line)
    return "\n".join(out) + ("\n" if content.endswith("\n") else "")


# ── Parse items ───────────────────────────────────────────────────────────────

def parse_items(et: EntityType, content: str) -> list[dict[str, Any]]:
    """Trả list item {id, name} từ fragment. Raise nếu YAML lỗi/sai cấu trúc."""
    data = yamlio.parse(content)
    if not isinstance(data, dict) or et.name not in data:
        raise ValueError(f"Fragment không có key '{et.name}:'")
    items = data.get(et.name)
    if items is None:
        return []
    if not isinstance(items, list):
        raise ValueError(f"'{et.name}:' phải là danh sách item")
    result = []
    for item in items:
        if isinstance(item, dict):
            result.append({
                "id": item.get(et.id_field),
                "name": item.get("name"),
            })
    return result


def fragment_info(repo_root: Path, et: EntityType, rel: str) -> dict[str, Any]:
    """Metadata 1 fragment file cho list view — không raise, gói lỗi vào field."""
    path = repo_root / rel
    parts = Path(rel).parts
    group = parts[2] if et.grouped and len(parts) == 4 else None
    info: dict[str, Any] = {
        "path": rel,
        "file": parts[-1],
        "group": group,
        "disabled": False,
        "parse_error": None,
        "items": [],
    }
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as e:
        info["parse_error"] = str(e)
        return info
    if not content.strip():
        info["parse_error"] = "File rỗng"
        return info
    if is_disabled(content):
        info["disabled"] = True
        return info
    try:
        info["items"] = parse_items(et, content)
    except Exception as e:  # YAML error, cấu trúc sai — hiển thị thay vì crash
        info["parse_error"] = str(e)
    return info


# ── Templates cho Create ──────────────────────────────────────────────────────

def route_file_name(domain: str, scheme: str, port: int) -> str:
    return f"route-{domain}-{scheme}-{port}.yaml"


def suggest_path(et: EntityType, *, entity_id: str = "", group: str = "",
                 domain: str = "", scheme: str = "", port: int = 0) -> str:
    if et.name == "routes":
        if not (domain and scheme and port and group):
            raise ValueError("routes cần đủ: workload (group), domain, scheme, port")
        if not _SAFE_SEGMENT_RE.match(group):
            raise ValueError(f"Tên workload không hợp lệ: {group}")
        return f"{APISIX_ROUTES_DIR}/routes/{group}/{route_file_name(domain, scheme, port)}"
    if not entity_id:
        raise ValueError("Cần id/username để đặt tên file")
    if not _SAFE_SEGMENT_RE.match(entity_id):
        raise ValueError(f"id không hợp lệ làm tên file: {entity_id}")
    return f"{APISIX_ROUTES_DIR}/{et.name}/{entity_id}.yaml"


def template(et: EntityType, *, entity_id: str = "", domain: str = "",
             scheme: str = "https", port: int = 443) -> str:
    """Skeleton fragment mới — copy schema/comment convention từ file thật trong repo."""
    if et.name == "routes":
        rid = f"route-{domain}-{scheme}-{port}"
        return f"""routes:
  # ── {domain}:{port} ──────────────────────────────────────────
  # Convention id: route-<domain>-<scheme>-<port> (KHÔNG đổi sang workload-based)
  - id: "{rid}"
    name: ""                              # tên workload, vd "hyperstore-cloudian-hcm"
    status: 1                             # 1 = enabled, 0 = disabled
    service_id: ""                        # trỏ services/<service-id>.yaml
    # plugin_config_id: ""                # QoS bundle dùng chung — plugin_configs/
    uri: "/*"
    host: "{domain}"
    methods: ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
    # plugins:
    #   proxy-control: {{ request_buffering: false }}
    timeout: {{ connect: 60, send: 600, read: 600 }}
"""
    if et.name == "upstreams":
        return f"""upstreams:
  - id: "{entity_id}"
    name: ""
    type: "roundrobin"
    scheme: "http"
    pass_host: "pass"
    nodes:
      "127.0.0.1:80": 1                   # "<ip>:<port>": <weight>
    checks:
      active:
        type: "http"
        http_path: "/"
        host: ""
        timeout: 5
        healthy: {{ interval: 10, successes: 2 }}
        unhealthy: {{ interval: 5, http_failures: 3, tcp_failures: 3 }}
    timeout: {{ connect: 30, send: 600, read: 300 }}
"""
    if et.name == "services":
        return f"""services:
  # Nguyên tắc: service 1:1 với upstream, KHÔNG chứa QoS plugin (QoS đặt ở plugin_configs/)
  - id: "{entity_id}"
    name: ""
    upstream_id: ""                       # trỏ upstreams/<upstream-id>.yaml
"""
    if et.name == "plugin_configs":
        return f"""plugin_configs:
  # QoS bundle dùng chung nhiều route — route gắn qua plugin_config_id.
  # ⚠ Field Redis (policy, redis_host...) PHẢI nested TRONG plugin cụ thể
  #   (vd trong limit-count: / api-breaker:), KHÔNG đặt ngang hàng cấp plugins:.
  # ⚠ KHÔNG BAO GIỜ khai ip-restriction.blacklist: [] (mảng rỗng) — incident 2026-07-03.
  #   Chưa có IP cần chặn → comment toàn bộ block ip-restriction.
  - id: "{entity_id}"
    plugins:
      limit-count:
        count: 500
        time_window: 1
        key_type: var
        key: remote_addr
        rejected_code: 429
        allow_degradation: true
        show_limit_quota_header: true
        policy: redis
        redis_host: 127.0.0.1
        redis_port: 6379
        redis_password: "$ENV://REDIS_PASSWORD"   # đọc từ .env, KHÔNG hardcode
        redis_database: 1
        redis_timeout: 1000
"""
    if et.name == "global_rules":
        return f"""global_rules:
  # ⚠ global_rules KHÔNG nằm trong chuỗi override Route > PluginConfig > Service —
  #   plugin cùng tên ở global_rule và route/service CHẠY CẢ HAI, tuần tự.
  - id: "{entity_id}"
    plugins: {{}}
"""
    if et.name == "consumer_groups":
        return f"""consumer_groups:
  - id: "{entity_id}"
    plugins: {{}}
"""
    if et.name == "consumers":
        return f"""consumers:
  # Nhánh S3 data-plane theo TÊN BUCKET: username = "bucket-<tên-bucket>",
  # KHÔNG chứa credential (bucket name vốn public).
  # Nhánh control-plane (key-auth) nếu dùng: credential PHẢI qua $env://, KHÔNG plaintext.
  - username: "{entity_id}"
    group_id: ""                          # trỏ consumer_groups/<group-id>.yaml
    plugins:
      custom.s3-bucket-name-consumer: {{}}  # marker rỗng — chỉ cần tồn tại
"""
    if et.name == "ssls":
        return f"""ssls:
  - id: "{entity_id}"
    status: 1
    snis:
      - ""
    ssl_protocols:
      - TLSv1.2
      - TLSv1.3
    # Cert/key do inject-certs.sh tự inject lúc runtime — GIỮ NGUYÊN placeholder,
    # KHÔNG paste private key plaintext vào đây.
    cert: |
      <PASTE_CONTENT_OF_{entity_id}.cert_HERE>
    key: |
      <PASTE_CONTENT_OF_{entity_id}.key_HERE>
"""
    raise ValueError(f"Chưa có template cho {et.name}")
