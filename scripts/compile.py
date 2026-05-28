#!/usr/bin/env python3
"""
compile.py — Gộp các YAML fragment thành file apisix-dc1.yaml hoàn chỉnh
Dùng trong CI Pipeline và local development

Usage:
    python compile.py --manifest manifest.yaml --output dist/apisix-dc1.yaml
    python compile.py --manifest manifest.yaml --output dist/apisix-dc1.yaml --validate
"""

import argparse
import sys
import os
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: Cần cài pyyaml: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


ALLOWED_TOP_KEYS = {"routes", "upstreams", "services", "consumers", "plugins", "global_rules", "stream_routes"}


def load_yaml_file(path: Path) -> dict:
    """Load và parse 1 file YAML, raise lỗi rõ ràng nếu sai."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        if data is None:
            return {}
        if not isinstance(data, dict):
            raise ValueError(f"File {path} phải là YAML object (dict), không phải {type(data).__name__}")
        return data
    except yaml.YAMLError as e:
        print(f"ERROR: YAML syntax error trong {path}:\n  {e}", file=sys.stderr)
        sys.exit(1)


def merge_fragment(base: dict, fragment: dict, source: str) -> dict:
    """
    Merge fragment vào base theo quy tắc:
    - List (routes, upstreams, ...): append
    - Dict: deep merge
    - Primitive: override với warning
    """
    for key, value in fragment.items():
        if key not in ALLOWED_TOP_KEYS:
            print(f"  WARN: Key '{key}' trong {source} không phải key APISIX chuẩn", file=sys.stderr)

        if key not in base:
            base[key] = value
        elif isinstance(base[key], list) and isinstance(value, list):
            # Kiểm tra duplicate ID
            existing_ids = {item.get("id") for item in base[key] if isinstance(item, dict) and "id" in item}
            for item in value:
                item_id = item.get("id") if isinstance(item, dict) else None
                if item_id and item_id in existing_ids:
                    print(f"  WARN: Duplicate id '{item_id}' từ {source} — đã bỏ qua", file=sys.stderr)
                else:
                    base[key].append(item)
                    if item_id:
                        existing_ids.add(item_id)
        elif isinstance(base[key], dict) and isinstance(value, dict):
            base[key].update(value)
        else:
            print(f"  WARN: Override key '{key}' từ {source}", file=sys.stderr)
            base[key] = value

    return base


def validate_compiled(data: dict) -> bool:
    """Kiểm tra cơ bản cấu trúc output."""
    errors = []

    for route in data.get("routes", []):
        if "id" not in route:
            errors.append(f"Route thiếu 'id': {route.get('uri', '?')}")
        if "uri" not in route and "uris" not in route:
            errors.append(f"Route '{route.get('id', '?')}' thiếu 'uri' hoặc 'uris'")
        if "upstream_id" not in route and "upstream" not in route:
            errors.append(f"Route '{route.get('id', '?')}' thiếu 'upstream_id' hoặc 'upstream'")

    for upstream in data.get("upstreams", []):
        if "id" not in upstream:
            errors.append(f"Upstream thiếu 'id'")
        if "nodes" not in upstream:
            errors.append(f"Upstream '{upstream.get('id', '?')}' thiếu 'nodes'")

    if errors:
        for e in errors:
            print(f"  VALIDATE ERROR: {e}", file=sys.stderr)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Compile APISIX YAML fragments")
    parser.add_argument("--manifest", required=True, help="Path tới manifest.yaml")
    parser.add_argument("--output",   required=True, help="Path output file")
    parser.add_argument("--validate", action="store_true", help="Validate structure sau khi compile")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"ERROR: Không tìm thấy manifest: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    base_dir = manifest_path.parent
    manifest = load_yaml_file(manifest_path)

    fragments = manifest.get("fragments", [])
    if not fragments:
        print("ERROR: manifest.yaml không có key 'fragments'", file=sys.stderr)
        sys.exit(1)

    print(f"Compiling {len(fragments)} fragments → {args.output}")

    compiled: dict[str, Any] = {}

    for frag_rel_path in fragments:
        frag_path = base_dir / frag_rel_path
        if not frag_path.exists():
            print(f"  ERROR: Fragment không tồn tại: {frag_path}", file=sys.stderr)
            sys.exit(1)

        print(f"  + {frag_rel_path}")
        fragment = load_yaml_file(frag_path)
        compiled = merge_fragment(compiled, fragment, str(frag_rel_path))

    # Validate nếu được yêu cầu
    if args.validate:
        print("Validating compiled output ...")
        if not validate_compiled(compiled):
            print("ERROR: Validation failed", file=sys.stderr)
            sys.exit(1)
        print("  Validation passed")

    # Ghi output
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as f:
        yaml.dump(
            compiled,
            f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )
        f.write("\n#END\n")

    # In summary
    print(f"\nOutput: {output_path}")
    for key in ALLOWED_TOP_KEYS:
        if key in compiled:
            count = len(compiled[key]) if isinstance(compiled[key], list) else "object"
            print(f"  {key}: {count}")

    print("\nDone.")


if __name__ == "__main__":
    main()