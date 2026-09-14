"""Test core/fragments trên chính fragment THẬT trong repo —
đảm bảo dashboard đọc được 100% trạng thái production hiện tại."""

from __future__ import annotations

from core import fragments, yamlio
from core.fragments import ENTITY_TYPES


def test_list_all_types_finds_files(repo_root):
    total = 0
    for et in ENTITY_TYPES.values():
        files = fragments.list_fragment_files(repo_root, et)
        if et.core:
            assert files, f"Thư mục core {et.name}/ không có file nào"
        total += len(files)
    assert total >= 30  # repo hiện có 40+ fragment


def test_every_fragment_parses_or_is_disabled(repo_root):
    problems = []
    for et in ENTITY_TYPES.values():
        for rel in fragments.list_fragment_files(repo_root, et):
            info = fragments.fragment_info(repo_root, et, rel)
            if info["parse_error"]:
                problems.append(f"{rel}: {info['parse_error']}")
            elif not info["disabled"]:
                # items có thể rỗng (template "nửa tắt" — key active, item bị comment,
                # vd global_rules/global-loki-logger.yaml); item nào có thì phải có id
                for item in info["items"]:
                    assert item["id"], f"{rel}: item thiếu {et.id_field}"
    assert not problems, "Fragment lỗi:\n" + "\n".join(problems)


def test_first_key_matches_folder_for_all_enabled(repo_root):
    for et in ENTITY_TYPES.values():
        for rel in fragments.list_fragment_files(repo_root, et):
            content = (repo_root / rel).read_text(encoding="utf-8")
            fk = yamlio.first_key(content)
            if fk is not None:  # None = disabled template
                assert fk == et.name, f"{rel}: key '{fk}' != folder '{et.name}'"


def test_routes_grouped_listing(repo_root):
    et = ENTITY_TYPES["routes"]
    files = fragments.list_fragment_files(repo_root, et)
    groups = {fragments.fragment_info(repo_root, et, rel)["group"] for rel in files}
    assert "debug-dump" in groups
    assert any(g and g.startswith("hyperstore-cloudian") for g in groups)


def test_disable_enable_roundtrip(repo_root):
    et = ENTITY_TYPES["services"]
    rel = fragments.list_fragment_files(repo_root, et)[0]
    original = (repo_root / rel).read_text(encoding="utf-8")
    disabled = fragments.disable(original)
    assert fragments.is_disabled(disabled)
    assert not fragments.is_disabled(original)
    assert fragments.enable(disabled) == original  # round-trip chính xác từng byte


def test_safe_rel_path():
    et = ENTITY_TYPES["routes"]
    assert fragments.is_safe_rel_path(et, "apisix_routes/routes/wl/route-a.b-https-443.yaml")
    assert fragments.is_safe_rel_path(et, "apisix_routes/routes/flat.yaml")
    assert not fragments.is_safe_rel_path(et, "apisix_routes/routes/../../etc/passwd")
    assert not fragments.is_safe_rel_path(et, "apisix_routes/services/x.yaml")
    assert not fragments.is_safe_rel_path(et, "apisix_routes/routes/a/b/c.yaml")
    flat = ENTITY_TYPES["services"]
    assert not fragments.is_safe_rel_path(flat, "apisix_routes/services/sub/x.yaml")


def test_route_template_and_suggest_path():
    et = ENTITY_TYPES["routes"]
    rel = fragments.suggest_path(et, group="my-workload", domain="s3.example.vn",
                                 scheme="https", port=443)
    assert rel == "apisix_routes/routes/my-workload/route-s3.example.vn-https-443.yaml"
    content = fragments.template(et, domain="s3.example.vn", scheme="https", port=443)
    assert yamlio.first_key(content) == "routes"
    items = fragments.parse_items(et, content)
    assert items[0]["id"] == "route-s3.example.vn-https-443"
    assert fragments.ROUTE_ID_RE.match(items[0]["id"])


def test_all_templates_parse():
    for et in ENTITY_TYPES.values():
        if et.name == "routes":
            content = fragments.template(et, domain="d.vn", scheme="https", port=443)
        else:
            content = fragments.template(et, entity_id=f"test-{et.name}")
        assert yamlio.first_key(content) == et.name, et.name
        assert fragments.parse_items(et, content), et.name
