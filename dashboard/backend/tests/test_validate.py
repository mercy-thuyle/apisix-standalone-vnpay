"""Test core/validate — các rule chặn cứng rút từ merge-fragments.sh + incident history."""

from __future__ import annotations

from core import fragments, validate
from core.fragments import ENTITY_TYPES


def _errors(findings):
    return [f for f in findings if f.level == "error"]


def _rules(findings):
    return {f.rule for f in findings}


# Ngoại lệ ĐÃ BIẾT trong repo hiện tại — nếu xuất hiện thêm case mới thì test FAIL.
# wildcard.thuyldx: cert lab, private key plaintext đã commit sẵn trong repo —
# rule plaintext-private-key của dashboard cố tình chặn (đã báo chủ dự án xử lý).
_KNOWN_EXISTING_VIOLATIONS = {
    ("apisix_routes/ssls/wildcard.thuyldx.yaml", "plaintext-private-key"),
}


def test_all_existing_fragments_have_no_errors(repo_root):
    """Fragment production hiện tại phải pass validate (trừ warning/info + ngoại lệ đã biết)."""
    problems = []
    for et in ENTITY_TYPES.values():
        for rel in fragments.list_fragment_files(repo_root, et):
            content = (repo_root / rel).read_text(encoding="utf-8")
            findings = validate.validate_fragment(repo_root, et, rel, content)
            for f in _errors(findings):
                if (rel, f.rule) in _KNOWN_EXISTING_VIOLATIONS:
                    continue
                problems.append(f"{rel}: [{f.rule}] {f.message[:120]}")
    assert not problems, "Fragment production bị validate chặn:\n" + "\n".join(problems)


def test_key_mismatch_blocked(repo_root):
    et = ENTITY_TYPES["services"]
    content = "routes:\n  - id: \"x\"\n"
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/services/x.yaml", content, is_new=True)
    assert "key-mismatch" in _rules(_errors(findings))


def test_end_flag_blocked(repo_root):
    et = ENTITY_TYPES["services"]
    content = "services:\n  - id: \"svc-test-end\"\n    upstream_id: \"u\"\n#END\n"
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/services/svc-test-end.yaml", content, is_new=True)
    assert "end-flag" in _rules(_errors(findings))


def test_duplicate_id_in_repo_blocked(repo_root):
    """Dup id với file khác trong repo → error (merge script chỉ WARNING,
    dashboard phải chặn cứng theo build-prompt mục 1)."""
    et = ENTITY_TYPES["services"]
    existing = fragments.list_fragment_files(repo_root, et)[0]
    existing_id = fragments.parse_items(
        et, (repo_root / existing).read_text(encoding="utf-8"))[0]["id"]
    content = f"services:\n  - id: \"{existing_id}\"\n    upstream_id: \"u\"\n"
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/services/new-file.yaml", content, is_new=True)
    assert "dup-in-repo" in _rules(_errors(findings))


def test_duplicate_id_same_file_edit_not_flagged(repo_root):
    """Edit lại chính file đó (giữ nguyên id) KHÔNG được báo dup."""
    et = ENTITY_TYPES["services"]
    rel = fragments.list_fragment_files(repo_root, et)[0]
    content = (repo_root / rel).read_text(encoding="utf-8")
    findings = validate.validate_fragment(repo_root, et, rel, content, is_new=False)
    assert "dup-in-repo" not in _rules(findings)


def test_empty_blacklist_blocked(repo_root):
    """Incident 2026-07-03: ip-restriction.blacklist: [] gây outage — phải chặn."""
    et = ENTITY_TYPES["plugin_configs"]
    content = (
        "plugin_configs:\n"
        "  - id: \"pc-test-empty\"\n"
        "    plugins:\n"
        "      ip-restriction:\n"
        "        blacklist: []\n"
    )
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/plugin_configs/pc-test-empty.yaml", content, is_new=True)
    assert "empty-min-items" in _rules(_errors(findings))


def test_disabled_template_is_ok(repo_root):
    et = ENTITY_TYPES["global_rules"]
    content = "# global_rules:\n#   - id: global-test\n"
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/global_rules/global-test.yaml", content, is_new=True)
    assert not _errors(findings)
    assert "disabled" in _rules(findings)


def test_plaintext_private_key_blocked(repo_root):
    et = ENTITY_TYPES["ssls"]
    content = (
        "ssls:\n"
        "  - id: \"ssl-test-plain\"\n"
        "    snis: [\"x.vn\"]\n"
        "    cert: |\n      abc\n"
        "    key: |\n      -----BEGIN RSA PRIVATE KEY-----\n      xxx\n"
    )
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/ssls/ssl-test-plain.yaml", content, is_new=True)
    assert "plaintext-private-key" in _rules(_errors(findings))


def test_consumer_bucket_prefix_warning(repo_root):
    et = ENTITY_TYPES["consumers"]
    content = (
        "consumers:\n"
        "  - username: \"khong-prefix\"\n"
        "    plugins:\n"
        "      custom.s3-bucket-name-consumer: {}\n"
    )
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/consumers/khong-prefix.yaml", content, is_new=True)
    assert "bucket-prefix" in _rules(findings)


def test_referential_warning(repo_root):
    et = ENTITY_TYPES["routes"]
    content = (
        "routes:\n"
        "  - id: \"route-test.vn-https-443\"\n"
        "    status: 1\n"
        "    service_id: \"service-khong-ton-tai\"\n"
        "    uri: \"/*\"\n"
        "    host: \"test.vn\"\n"
    )
    findings = validate.validate_fragment(
        repo_root, et, "apisix_routes/routes/test/route-test.vn-https-443.yaml",
        content, is_new=True)
    assert "referential" in _rules(findings)
    assert not any(f.rule == "referential" and f.level == "error" for f in findings)
