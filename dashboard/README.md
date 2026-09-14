# APISIX Standalone Config Dashboard

Dashboard quản lý cấu hình APISIX Standalone mode (KHÔNG Admin API/etcd) — mọi thay đổi đi qua **Git**: sửa fragment YAML → diff + xác nhận → commit + push `main` → gitsync pull (~30s) → merge-fragments → APISIX hot-reload. Xem kiến trúc đầy đủ: `apisix-dashboard-build-prompt.md` ở root repo.

## Phase 1 (hiện tại)

- CRUD 8 entity fragment: `upstreams` `services` `plugin_configs` `routes` `global_rules`   `consumer_groups` `consumers` `ssls` (folder `apisix_routes/`)
- Editor Monaco raw YAML — **giữ nguyên 100% comment nghiệp vụ** (không re-serialize)
- Validate trước commit: key khớp folder, cấm `#END`, **chặn cứng** duplicate id/username toàn repo, **chặn cứng** `blacklist`/`whitelist` rỗng (incident 2026-07-03), chặn plaintext private key trong `ssls/`; warning: referential (service_id/upstream_id/...), naming convention route, prefix `bucket-`, yamllint (theo `.yamllint.yaml` của repo)
- Mọi write: **diff + xác nhận → commit + push thẳng `main`** (optimistic lock — 409 nếu người khác vừa sửa). Disable/Enable = comment/bỏ comment toàn file (giữ lịch sử)
- History theo file (git log) + link GitLab; nút Revert là placeholder (Phase 3)
- Trang Status: tail `logs/gitsync/gitsync.log`, check dòng `reloaded` trong `logs/apisix/error.log`
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

UI: `http://<VM-IP>:18080` — **firewall/network ACL tự quản** (compose không mở/đóng firewall; port 18080 đã chọn để tránh trùng 80/443/8443/16443/18090/19443/9080/9443/9091/9099/6379/9121).

## Vận hành

| Hạng mục | Command |
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

## Hot-reload khi dev (không cần rebuild image mỗi lần sửa)

**Backend (.py)** — bật dev mode ngay trên VM: bỏ comment 2 dòng trong docker-compose.yaml
(`DASHBOARD_RELOAD=true` + mount `./dashboard/backend:/app/backend`) rồi
`docker compose up -d dashboard`. Từ đó sửa file .py là uvicorn tự restart (~1s),
không cần build. **Nhớ comment lại khi xong** — không để reload mode trên production.

**Frontend (.tsx/.css)** — KHÔNG hot-reload trong container được (image chứa bản build
tĩnh). Cách dev đúng: chạy Vite dev server trên máy local + SSH tunnel tới backend thật:

```bash
ssh -N -L 18080:127.0.0.1:18080 sb-api6-hcm-1   # tunnel tới dashboard VM
cd dashboard/frontend && npm install && npm run dev
# mở http://localhost:5173 — sửa .tsx là browser tự cập nhật tức thì (HMR);
# mọi call /api được Vite proxy về localhost:18080 = backend thật qua tunnel
```

Dev cắm vào DC khác (vd HNI qua tunnel 18081) — đổi proxy target bằng env `DASH_API`;
chạy song song 2 bản thì Vite tự nhảy port (5173 bận → 5174):

```bash
ssh -N -L 18081:127.0.0.1:18080 sb-api6-hni-1
DASH_API=http://127.0.0.1:18081 npm run dev     # → http://localhost:5174 (nhìn badge DC để phân biệt)
```

Khi hài lòng → commit + push → trên VM `docker compose up -d --build dashboard` (bản
production build lại một lần).

## Yêu cầu máy người vận hành (để chạy hub trên máy cá nhân)

Hub cần Docker runtime + `docker compose`. Theo OS:

| OS | Khuyến nghị | Ghi chú |
|---|---|---|
| **macOS** | [OrbStack](https://orbstack.dev) — nhẹ hơn Docker Desktop nhiều (RAM idle ~thấp, khởi động ~2s), có UI quản lý container, tương thích 100% lệnh `docker`/`docker compose` | Free cho cá nhân; dùng thương mại cần license. Thay thế free hoàn toàn: [Colima](https://github.com/abiosoft/colima) (`brew install colima docker docker-compose && colima start`) — không UI nhưng rất nhẹ. Docker Desktop vẫn dùng được nếu đã cài |
| **Windows** | Docker Desktop + **WSL2 backend** (bật trong Settings → General) | Chạy lệnh git/compose trong terminal WSL (Ubuntu) để path/line-ending nhất quán; `*.localhost` hoạt động bình thường trên browser Windows |
| **Linux** | Docker Engine + compose plugin (`apt install docker-ce docker-compose-plugin`) | Lệnh y hệt macOS; compose hub đã có `extra_hosts: host.docker.internal:host-gateway` nên không cần chỉnh gì |

Mọi lệnh trong README này giữ nguyên trên cả 3 OS (OrbStack/Colima đều cung cấp
`docker` CLI chuẩn). Ngoài Docker cần thêm: `ssh` (mở tunnel — có sẵn mọi OS) và
quyền truy cập jump host `jump-sb` trong `~/.ssh/config`.

## Hub multi-DC trên máy local (`dashboard/hub/`) — gateway xem & CRUD trực tiếp

Hub chạy trên Mac/laptop admin, làm 2 việc:

1. **Trang tổng quan** `http://localhost:18000` — card mỗi VM: online/unreachable, DC,
   HEAD commit, gitsync DONE, APISIX reloaded, số WARN.
2. **Reverse proxy theo subdomain** `http://<id>.localhost:18000` — toàn bộ UI + API
   (kể cả POST save/delete) của dashboard VM đó được forward qua hub → **xem và CRUD
   trực tiếp từ hub**, không cần mở dashboard từng VM. `*.localhost` tự trỏ 127.0.0.1
   trên Chrome/Firefox (Safari cũ: thêm `127.0.0.1 hcm.localhost` vào /etc/hosts).
3. **Dropdown chọn VM ngay trong dashboard**: khi chạy sau hub, badge `DC:` trên
   sidebar thành dropdown `<DC> — <hostname> — <ip>` (từ `hostname`/`ip` trong
   peers.yaml, hub trả qua endpoint riêng `/__hub/peers`) — đổi VM giữ nguyên trang
   đang xem. Truy cập thẳng trên VM (không qua hub) thì vẫn là badge tĩnh.

Mac KHÔNG route trực tiếp tới VM (sau jump host — đã test curl timeout, /etc/hosts
không thay được route) → hub đi qua SSH tunnel mở sẵn trên máy local.

```bash
# 1. Tunnel tới từng VM
ssh -N -L 18080:127.0.0.1:18080 sb-api6-hcm-1 &
ssh -N -L 18081:127.0.0.1:18080 sb-api6-hni-1 &

# 2. Khai báo peers (gitignored — có thể chứa auth_basic)
cd dashboard/hub && cp peers.example.yaml peers.yaml

# 3. Chạy hub
docker compose up -d --build
# → http://localhost:18000        (tổng quan)
# → http://hcm.localhost:18000    (dashboard HCM đầy đủ, CRUD được)
# → http://hni.localhost:18000    (dashboard HNI đầy đủ, CRUD được)
# Không dùng Docker: pip install fastapi uvicorn httpx pyyaml
#   && PEERS_FILE=peers.yaml python app.py   (url trong peers dùng 127.0.0.1:<port-tunnel>)
```

Scale thêm node APISIX: mở thêm 1 tunnel (port local mới) + thêm 1 block `peers.yaml`
(id mới = subdomain mới). Khai báo tĩnh — không có auto-discovery qua tunnel.
Peer "unreachable" → kiểm tra tunnel còn mở không.

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
