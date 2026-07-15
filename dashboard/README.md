# APISIX Standalone Config Dashboard

Dashboard quản lý cấu hình APISIX Standalone mode (KHÔNG Admin API/etcd) — mọi thay đổi
đi qua **Git**: sửa fragment YAML → diff + xác nhận → commit + push `main` → gitsync pull
(~30s) → merge-fragments → APISIX hot-reload. Xem kiến trúc đầy đủ:
`apisix-dashboard-build-prompt.md` ở root repo.

## Phase 1 (hiện tại)

- CRUD 8 entity fragment: `upstreams` `services` `plugin_configs` `routes` `global_rules`
  `consumer_groups` `consumers` `ssls` (folder `apisix_routes/`)
- Editor Monaco raw YAML — **giữ nguyên 100% comment nghiệp vụ** (không re-serialize)
- Validate trước commit: key khớp folder, cấm `#END`, **chặn cứng** duplicate id/username
  toàn repo, **chặn cứng** `blacklist`/`whitelist` rỗng (incident 2026-07-03), chặn
  plaintext private key trong `ssls/`; warning: referential (service_id/upstream_id/...),
  naming convention route, prefix `bucket-`, yamllint (theo `.yamllint.yaml` của repo)
- Mọi write: **diff + xác nhận → commit + push thẳng `main`** (optimistic lock — 409 nếu
  người khác vừa sửa). Disable/Enable = comment/bỏ comment toàn file (giữ lịch sử)
- History theo file (git log) + link GitLab; nút Revert là placeholder (Phase 3)
- Trang Status: tail `logs/gitsync/gitsync.log`, check dòng `reloaded` trong
  `logs/apisix/error.log`
- Audit JSONL: `logs/dashboard/backend/audit.log`
- Auth adapter: `none` | `basic` (htpasswd bcrypt) — chuẩn bị sẵn cho OIDC/Keycloak

Phase 2: Lua editor + control-plane (`apisix_config/`) + Certificates.
Phase 3: branch + Merge Request, revert thật, profile-map.

## Bootstrap trên VM (1 lần, tại `/opt/apisix/standalone/sandbox/`)

```bash
# 1. Build + chạy
docker compose up -d --build dashboard

# 2. Kiểm tra
curl -s http://127.0.0.1:18080/healthz        # {"ok":true}
docker logs dashboard --tail 20                # "Workspace sẵn sàng: ... @ <sha>"
```

UI: `http://<VM-IP>:18080` — **firewall/network ACL tự quản** (compose không mở/đóng
firewall; port 18080 đã chọn để tránh trùng 80/443/8443/16443/18090/19443/9080/9443/9091/9099/6379/9121).

## Vận hành

| Việc | Cách |
|---|---|
| Rebuild sau khi code `dashboard/` đổi | `docker compose up -d --build dashboard` |
| Đổi auth mode | Sửa `AUTH_MODE` trong docker-compose.yaml → `docker compose up -d dashboard` |
| Xem audit | `tail -f logs/dashboard/backend/audit.log` (JSONL) hoặc API `/api/git/audit` |
| App log / access log | `logs/dashboard/backend/backend.log` / `logs/dashboard/frontend/frontend.log` |
| Workspace hỏng (hiếm) | `rm -rf dashboard/dashboard-workspace/*` → restart container (tự clone lại) |

**Lưu ý:** `dashboard/dashboard-workspace/` là clone lồng trong clone (đã gitignore +
dockerignore) — KHÔNG `git add` nó từ sandbox, KHÔNG sửa tay trong đó (dashboard reset
cứng theo `origin/main` trước mỗi thao tác).

## File/folder TỰ SINH — không commit (đã gitignore + dockerignore)

Chỉ source trong `dashboard/backend/` + `dashboard/frontend/src/` + config được commit.
Mọi thứ dưới đây sinh ra khi chạy lệnh, KHÔNG được `git add` (giữ commit đầu gọn,
clone nhanh khi scale thêm node APISIX):

| File/folder | Sinh ra bởi lệnh | Ghi chú |
|---|---|---|
| `dashboard/dashboard-workspace/` | Container start lần đầu (tự `git clone`) | Clone lồng trong clone — nặng nhất, tuyệt đối không commit |
| `dashboard/frontend/node_modules/` | `npm install` (dev local) | ~200MB; Docker build có bản riêng trong stage node |
| `dashboard/frontend/dist/` | `npm run build` (dev local) | Docker build tự build trong image, không cần bản trên host |
| `dashboard/backend/.venv/` | `python -m venv .venv` (dev local) | Nếu dev backend bằng venv |
| `__pycache__/` (mọi cấp) | Chạy python/pytest | Bytecode cache |
| `.pytest_cache/` | `python -m pytest tests/` | Test cache |
| `logs/dashboard/` | Container runtime | Đã cover bởi rule `logs/` sẵn có |
| `secrets/.netrc-dashboard`, `secrets/dashboard-users.htpasswd` | Bootstrap (tạo tay) | Đã cover bởi rule `secrets/` sẵn có |

Lưu ý: **deploy production KHÔNG cần chạy npm/pip trên host** — `docker compose up -d
--build dashboard` tự build tất cả bên trong image (multi-stage). Các lệnh npm/pip chỉ
dùng khi dev local.

## Dev local (ngoài VM)

```bash
# Backend (cần git + python3.11+)
cd dashboard/backend && pip install -r requirements.txt
LOG_DIR=/tmp/dash-logs WORKSPACE_PATH=/tmp/dash-ws REPO_URL=<repo> AUTH_MODE=none DASHBOARD_PORT=18080 python run.py

# Frontend (proxy /api → 18080)
cd dashboard/frontend && npm install && npm run dev

# Unit tests (chạy trên fragment thật trong repo)
cd dashboard/backend && python -m pytest tests/
```

Lưu ý macOS: nếu path chứa ký tự `#` (vd thư mục iCloud), `vite build` fail do Rollup
coi `#` là URL fragment — build trong Docker hoặc copy ra path không có `#`.
