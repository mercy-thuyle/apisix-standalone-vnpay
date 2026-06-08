# APISIX
## HLD
---
### 1. Các thành phần của APISIX

- Control Plane = nơi khai báo, lưu trữ ý định — "tôi muốn route này chạy thế nào, plugin nào, upstream nào"
- Data Plane = nơi thực thi — nhận request thực, chạy plugin chain, forward xuống RGW
- Các đối tượng như Route, Upstream, Consumer... là definition/config → Control Plane. Data Plane chỉ consume config đó để xử lý traffic. Khi etcd die, Data Plane vẫn tiếp tục chạy bình thường với config đã load vào memory — đây là lý do APISIX tách bạch rõ 2 plane.

```
# Bảng tóm tắt
DATA PLANE                                CONTROL PLANE headless
───────────────────────────────────       ──────────────────────────────
APISIX Core (OpenResty/Nginx + Lua)       Dashboard (optional)
Router Engine (radixtree)                 Admin API (:9180)             
Plugin Runtime (Lua chain)                etcd (config store - database)                
Balancer (chọn upstream node)               ├─ Route
TLS Engine (dynamic cert)                   ├─ Upstream
Connection Pool → RGW backend               ├─ Service
                                            ├─ Plugin config
                                            ├─ Consumer
                                            ├─ SSL
                                            └─ Global Rule
```
#### etcd — Database của APISIX
```
etcd lưu trữ:
  /apisix/routes/*          → tất cả Route object
  /apisix/upstreams/*       → Upstream + health check config
  /apisix/services/*        → Service object
  /apisix/consumers/*       → Consumer (auth)
  /apisix/ssl/*             → TLS cert/key
  /apisix/global_rules/*    → Global Plugin
  /apisix/plugin_configs/*  → Plugin config

Đây là SOURCE OF TRUTH — mất etcd = mất toàn bộ config
(Data Plane vẫn chạy nhưng không thể recover config sau restart)
```

#### Data Plane (xử lý traffic thực tế)
| Thành phần         | Vai trò                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------- |
| APISIX Core        | Engine chính, built on OpenResty/Nginx + Lua. Xử lý toàn bộ request pipeline congdonglinux               |
| Router (radixtree) | Khớp request với route rule theo URI, Host, Header, Method. Hot-reload không restart congdonglinux       |
| Plugin Runtime     | Chain các plugin theo thứ tự: rewrite → access → proxy → header_filter → body_filter → log congdonglinux   |
| Balancer           | LB sang upstream: round-robin, least-conn, consistent-hashing, EWMA congdonglinux                        |
| SSL/TLS Engine     | Dynamic certificate loading, không cần restart khi update cert apisix.apache                              |

#### Control Plane (quản lý cấu hình)
| Thành phần            | Vai trò                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------- |
| etcd                  | Config store phân tán (Raft consensus). APISIX watch etcd để nhận config thay đổi realtime congdonglinux   |
| Admin API (port 9180) | REST API để CRUD Route/Upstream/Plugin/Consumer/SSL. Không expose public congdonglinux                   |
| APISIX Dashboard      | Web UI optional, gọi Admin API bên dưới congdonglinux                                                    |

##### Các đối tượng cấu hình chính
Route       → rule khớp request (URI, method, host, header)
Upstream    → nhóm backend servers + LB algorithm + health check
Service     → tái sử dụng plugin config cho nhiều Route
Plugin      → logic xử lý gắn vào Route/Service/Global
Consumer    → định danh end-user (API key, JWT, HMAC)
SSL         → cert/key mapping theo SNI
Global Rule → plugin áp dụng cho tất cả request

```bash
# Luồng Dữ Liệu
Admin → POST /apisix/admin/routes  (Control Plane)
              │
              ▼
           etcd  ←── APISIX watch (subscribe)
                            │
                            ▼
              Data Plane hot-reload vào memory
              (không restart, không drop connection)
              │
              ▼
Client request → Data Plane dùng config đã load để xử lý
```

##### Mô hình quản trị tập trung
Triết Lý Vận Hành Khác Nhau So Với NGINX
```
NGINX                                  APISIX
─────────────────────────────          ─────────────────────────────
Config = file trên từng server         Config = objects trong etcd
Thay đổi = sửa file + reload           Thay đổi = POST/PUT Admin API
Mỗi node vận hành độc lập              Tất cả node đồng bộ qua etcd
Không có "source of truth" chung       etcd là source of truth duy nhất
Reload = graceful (nginx -s reload)    Hot-reload = tự động, không restart
Rollback = restore file cũ             Rollback = PUT lại object cũ qua API
Audit trail = không có                 Audit trail = etcd revision history
```

---
### 2. Chức năng

#### Traffic Management
- Load Balancing: round-robin, least-conn, consistent-hash
- Health check: active (HTTP probe) + passive (based on response)
- Circuit breaker, retry, timeout, traffic splitting (canary/A-B)
- Rate limiting theo IP/User/Route

#### Security
- TLS termination (dynamic cert, không restart)
- Authentication: API Key, JWT, HMAC, Basic Auth, OAuth2, OIDC
- IP whitelist/blacklist (ip-restriction plugin)
- Request validation (block malformed request trước khi vào backend)

#### Observability
- Access log → file/Kafka/HTTP
- Metrics → Prometheus exporter (port 9091)
- Tracing → OpenTelemetry / Zipkin / SkyWalking

#### Extensibility
- Plugin tự viết bằng Lua, Go (plugin runner), WASM
- Standalone mode: load config từ YAML file, không cần etcd

---
### 3. Hoạt Động Cơ Bản
```
# Lifecycle một request S3 qua APISIX:
Client
  │  HTTPS :443
  ▼
APISIX (Data Plane)
  ├─ 1. TLS Termination
  ├─ 2. Router khớp Route (Host: s3.tenant.vn)
  ├─ 3. Plugin chain thực thi:
  │      ├─ ip-restriction (whitelist)
  │      ├─ limit-req (rate limit)
  │      └─ proxy-rewrite (nếu cần)
  ├─ 4. Balancer chọn RGW instance (health check pass)
  └─ 5. Forward HTTP → RGW :3950
              │
              ▼
        RGW-Data (Lua script, S3 API)
```
```
# Luồng config change (dynamic, zero-downtime):
Admin → Admin API (9180) → etcd → APISIX watch → hot-reload vào memory
                                    (không restart, không drop connection)
```

---

### 4. Hình thức triển khai - Deployment MODE (APISIX software)
Layer 1: Deployment MODE (APISIX software)
  ├─ Traditional   (CP + DP chung process) : data plane + control plane chung 1 process (đơn giản, phù hợp production nhỏ)
  ├─ Decoupled     (CP và DP tách process) : tách CP (port 9180) và DP riêng — phù hợp khi scale nhiều DP node
  └─ Standalone    (không etcd, file-based) : không cần etcd, load config từ YAML — phù hợp môi trường simple/airgap

### 5. Runtime / Hình thức chạy (infrastructure)
Layer 2: Runtime (infrastructure)
  ├─ On-host (bare metal/VM)
  └─ Kubernetes (Container:Docker/Podman)
| Hình thức | Ưu điểm | Nhược điểm | Phù hợp với S3RGW |
| --------- | ------- | ---------- | ----------------- |
| On-host (bare metal/VM)   | Hiệu suất tốt nhất, không overhead container. Full control resource. Debug dễ | Cài đặt thủ công, upgrade phức tạp, không portable                      | ✅ Phù hợp nhất với môi trường on-prem Ceph |
| Container (Docker/Podman) | Dễ deploy, isolate, rollback image. Phù hợp Podman trên Ceph node             | Cần quản lý volume, network mode, sys limit                             | ✅ Tốt nếu đang dùng Podman (Cephadm stack) |
| Kubernetes                | Auto-scaling, self-healing, Ingress Controller native. Ecosystem GitOps tốt   | Phức tạp, overhead K8s control plane, không có sẵn K8s trong S3RGW HLD  | ❌ Over-engineering cho bài toán này        |
| GitOps (CI/CD)            | Config as code, audit trail, rollback dễ. Kết hợp với bất kỳ runtime nào      | Cần pipeline CI/CD infrastructure (ArgoCD/Flux), học thêm toolchain uit | ⚠️ Nên kết hợp sau khi ổn định on-host     |

```
Traditional                    Decoupled                          Standalone
────────────────────────────   ────────────────────────────────   ────────────────────────────
CP + DP = 1 process            CP và DP = 2 process riêng         Không có etcd
1 APISIX instance làm cả 2     CP: chỉ nhận Admin API :9180       Config từ file YAML/JSON local
etcd vẫn cần (config store)     DP: chỉ xử lý traffic               Hot-reload từ file mỗi 1s
                               DP kết nối etcd để watch config     Không có Admin API (file-driven)
```
> Lưu ý quan trọng: Traditional ≠ "không có etcd". Traditional ở đây là mô hình CP và DP chạy chung 1 process APISIX. etcd vẫn là dependency bắt buộc (trừ Standalone).

---

### 6. Mô hình triển khai
Layer 3: Topology (bố trí các node trên infra). [Chi tiết tại Deployment Mode](README/deployment-modes.md)
  ├─ T1: Traditional, etcd local mỗi node
  ├─ T2: Traditional, etcd cluster Raft
  ├─ T3: Decoupled, CP VM riêng
  ├─ T4: Decoupled, CP đặt tại ZG
  └─ T5: Standalone

---

### 7. Mô hình triển khai với Ceph
- Theo các đánh giá hiện tại VNPAY đưa ra phương án triển khai là Standalone + git-sync. [Chi tiết tại Best practice S3](README/best-pratice-s3.md)

---

# LLD
# 00 — Prerequisites
> Áp dụng cho tất cả VM: global-lb, apisixdc-1, apisixdc-2  
> Chạy các bước này trước khi làm bất kỳ TC nào

---

## Thông tin môi trường

| VM | IP | Role |
|---|---|---|
| global-lb | 172.25.216.164 | etcd + APISIX CP+DP1 (DC1) |
| apisixdc-1 | 172.25.216.168 | APISIX DP2 (DC2) |
| apisixdc-2 | 172.25.216.175 | APISIX CP2+DP2 (TC-01-8+) |

---

## 1. OS Timezone

```bash
sudo timedatectl set-timezone Asia/Ho_Chi_Minh
```

**Expected:**
```bash
timedatectl | grep "Time zone"
# Time zone: Asia/Ho_Chi_Minh (+07, +0700)
```

---

## 2. OS Update

```bash
sudo apt-get -y update && sudo apt-get -y upgrade
```

> **[ADD]** Nên reboot sau upgrade kernel để đảm bảo kernel mới được load.

```bash
# Upgrade HWE kernel (Ubuntu 22.04)
sudo apt update && sudo apt install -y linux-generic-hwe-22.04
# → Reboot sau bước này nếu kernel version thay đổi
sudo reboot
```

**Verify kernel sau reboot:**
```bash
uname -r
# Expected: 6.x.x-xx-generic (HWE kernel)
```

---

## 3. Python3

```bash
sudo apt install -y python3
```

**Expected:**
```bash
python3 --version
# Python 3.10.x
```

---

## 4. Docker — Gỡ package cũ

```bash
sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)
```

> **[ADD]** Lệnh này có thể báo lỗi nếu không có package nào cần remove — bình thường, tiếp tục.

---

## 5. Docker — Cài đặt từ official apt repo

```bash
# GPG key
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add repository
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

# Install
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Verify:**
```bash
sudo systemctl status docker | grep Active
# Active: active (running)

docker --version
# Docker version 29.x.x, build xxxxxxx

docker compose version
# Docker Compose version v2.x.x
```

> **[ADD]** Thêm user ubuntu vào group docker để không cần sudo:
```bash
sudo chmod 666 /var/run/docker.sock
sudo usermod -aG docker ${USER}
su - ${USER}
# Verify: docker ps (không cần sudo)
```

---

## 6. Verify connectivity giữa các VM

> **[ADD]** Chạy trước khi deploy để đảm bảo network OK.

```bash
# Từ apisixdc-1 và apisixdc-2 — ping về global-lb
ping -c 3 172.25.216.164
# Expected: 0% packet loss, rtt < 2ms

# Verify port etcd reach được (chạy sau khi etcd đã up trên global-lb)
nc -zv 172.25.216.164 2379
# Expected: Connection to 172.25.216.164 2379 port [tcp/*] succeeded!
```

---

## 7. Kiểm tra môi trường trước khi bắt đầu

> **[ADD]** Checklist nhanh — chạy trên từng VM để confirm sẵn sàng.

```bash
hostname && ip a | grep 'inet ' | grep -v 127
docker --version
cat /etc/os-release | grep -E 'NAME|VERSION='
python3 --version
```

**Expected output mẫu (apisixdc-1):**
```
apisixdc-1
    inet 172.25.216.168/24 ...
Docker version 29.4.3, build 055a478
NAME="Ubuntu"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
Python 3.10.x
```

# [BEST PRATICE API6](-/blob/main/README/best-pratice-api6.md)

---
# 01 — etcd On-Host
> Chỉ áp dụng cho **global-lb (172.25.216.164)**  
> VM chạy etcd dạng systemd service — không phải container

---

## 1. Cài đặt etcd binary <https://apisix.apache.org/docs/apisix/installation-guide/#installing-etcd>

```bash
ETCD_VERSION='3.5.4'
wget https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz
tar -xvf etcd-v${ETCD_VERSION}-linux-amd64.tar.gz && cd etcd-v${ETCD_VERSION}-linux-amd64 && sudo cp -a etcd etcdctl /usr/bin/
```

> **[ADD]** Lệnh `nohup etcd` bên dưới chỉ để test nhanh, **KHÔNG dùng cho production**.  
> Nếu đã chạy `nohup etcd`, phải kill trước khi tạo systemd service để tránh 2 process conflict:
```bash
# Test nhanh (tạm thời)
nohup etcd >/tmp/etcd.log 2>&1 &

# Xem log test
tail -f /tmp/etcd.log

# KILL trước khi làm bước systemd
pkill etcd
```

**Verify binary:**
```bash
which etcd && etcd --version
# /usr/bin/etcd
# etcd Version: 3.5.4

which etcdctl && etcdctl version
# /usr/bin/etcdctl
# etcdctl version: 3.5.4
```

---

## 2. Tạo systemd service

```bash
sudo nano /etc/systemd/system/etcd.service
```

```ini
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/etcd \
  --name=etcd0 \
  --data-dir=/var/lib/etcd \
  --listen-client-urls=http://0.0.0.0:2379 \
  --advertise-client-urls=http://172.25.216.164:2379 \
  --listen-peer-urls=http://0.0.0.0:2380 \
  --initial-advertise-peer-urls=http://172.25.216.164:2380 \
  --initial-cluster=etcd0=http://172.25.216.164:2380
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

> **[ADD]** ⚠️ IP `172.25.216.164` là IP của `global-lb` — thay đúng IP nếu deploy trên VM khác.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now etcd
```

---

## 3. Verify etcd đang chạy

```bash
# 1. Systemd status
sudo systemctl status etcd | grep Active
# Expected: Active: active (running)

# 2. Process
ps aux | grep etcd | grep -v grep
# Expected: thấy /usr/bin/etcd process

# 3. Port listening
sudo ss -tlnp | grep -E '2379|2380'
# Expected:
# LISTEN 0 4096 *:2379 *:* users:(("etcd",...))
# LISTEN 0 4096 *:2380 *:* users:(("etcd",...))

# 4. Health check
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
# Expected: http://127.0.0.1:2379 is healthy: successfully committed proposal: took = Xms

# 5. Status chi tiết
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --write-out=table
# Expected: IS LEADER = true, ERRORS = (empty)
```

---

## 4. Restart nếu cần

```bash
sudo systemctl daemon-reload && sudo systemctl restart etcd
sudo systemctl status etcd
```

---

## 5. Kiểm tra etcd listen đúng IP cho cross-DC

> **[ADD]** APISIX trên apisixdc-1/2 sẽ kết nối vào `172.25.216.164:2379`.  
> Cần confirm etcd listen trên interface LAN, không chỉ loopback.

```bash
ss -tlnp | grep 2379
# Expected: *:2379 (listen all interfaces) hoặc 0.0.0.0:2379

# Verify từ apisixdc-1
nc -zv 172.25.216.164 2379
# Expected: Connection to 172.25.216.164 2379 port [tcp/*] succeeded!
```
---
-----bỏ
# Tạo user root trước (bắt buộc phải có root user trước khi enable auth)
etcdctl --endpoints=http://127.0.0.1:2379 user add root # Nhập password khi được hỏi, ví dụ: StrongEtcdPassword123!
# Gán role root cho user root
etcctl --endpoints=http://127.0.0.1:2379 user grant-role root root
# Bật auth
etcdctl --endpoints=http://127.0.0.1:2379 auth enable
# Verify
etcdctl --endpoints=http://127.0.0.1:2379 --user=root:root endpoint health
-----bỏ

---

## 6. Backup/Snapshot etcd sau khi setup xong

> **[ADD]** Tạo baseline snapshot ngay sau khi etcd healthy — dùng làm rollback point cho TC-01-7.

```bash
sudo mkdir -p /var/backups/etcd

sudo ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 snapshot save /var/backups/etcd/etcd-post-install-$(date +%Y%m%d).db

# Verify snapshot
sudo ETCDCTL_API=3 etcdctl snapshot status /var/backups/etcd/etcd-post-install-$(date +%Y%m%d).db --write-out=table
```

**Expected:**
```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| xxxxxxxx |        X |         XX |      XX kB |
+----------+----------+------------+------------+
```

---

## 7. etcdctl alias tiện dụng

> **[ADD]** Thêm vào `~/.bashrc` để dùng nhanh.

```bash
cat >> ~/.bashrc <<'EOF'

# etcdctl shortcuts
export ETCDCTL_API=3
_ETCD_EP="--endpoints=http://127.0.0.1:2379"

etcd-health()   { etcdctl $_ETCD_EP endpoint health; }
etcd-status()   { etcdctl $_ETCD_EP endpoint status --write-out=table; }
etcd-keys()     { etcdctl $_ETCD_EP get /apisix --prefix --keys-only; }
etcd-routes()   { etcdctl $_ETCD_EP get /apisix/routes --prefix --keys-only; }
etcd-get()      { etcdctl $_ETCD_EP get "$1"; }
etcd-watch()    { etcdctl $_ETCD_EP watch /apisix --prefix; }
etcd-compact()  {
  REV=$(etcdctl $_ETCD_EP endpoint status --write-out=json | \
    python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Status']['header']['revision'])")
  echo "Compacting at revision: $REV"
  etcdctl $_ETCD_EP compact $REV
  etcdctl $_ETCD_EP defrag
  etcdctl $_ETCD_EP endpoint status --write-out=table
}
etcd-backup()   {
  mkdir -p /var/backups/etcd
  FILE="/var/backups/etcd/etcd-$(date +%Y%m%d-%H%M%S).db"
  etcdctl $_ETCD_EP snapshot save $FILE
  etcdctl snapshot status $FILE --write-out=table
  echo "Saved: $FILE"
}

export -f etcd-health etcd-status etcd-keys etcd-routes etcd-get etcd-watch etcd-compact etcd-backup
EOF

source ~/.bashrc
```

---

## 8. Restore etcd từ snapshot — TC-01-7

> **[ADD]** Procedure restore khi etcd bị corrupt hoàn toàn hoặc data dir mất.  
> Thực hiện trên **global-lb** — VM chạy etcd onhost.  
>
> **MTTR thực tế đo được (lab):**
> ```
> etcd restore binary:       0.124s
> etcd start → healthy:      19s
> APISIX restart:            ~10s
> ────────────────────────────────
> Total kỹ thuật:            ~30s
> Total thực tế (có detect): ~3 phút
> ```

### Bước 0 — Snapshot trước khi làm gì (điểm restore mới nhất)

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 \
  snapshot save /var/backups/etcd/etcd-pre-restore-$(date +%Y%m%d-%H%M%S).db

sudo ETCDCTL_API=3 etcdctl \
  snapshot status /var/backups/etcd/etcd-pre-restore-*.db \
  --write-out=table

ls -lh /var/backups/etcd/
```

**Expected:**
```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 8bbaa1ec |      302 |        307 |      70 kB |
+----------+----------+------------+------------+
```

---

### Bước 1 — Stop APISIX trên tất cả VM trước

> **[ADD]** Bắt buộc stop APISIX trước khi restore — tránh APISIX write vào etcd
> trong lúc đang restore data dir.

Trên **apisixdc-1**:
```bash
cd ~/apisix && docker compose stop
echo "=== apisixdc-1 APISIX stopped at $(date) ==="
```

Trên **global-lb**:
```bash
cd ~/apisix && docker compose stop
echo "=== global-lb APISIX stopped at $(date) ==="
```

---

### Bước 2 — Stop etcd + simulate corrupt

```bash
sudo systemctl stop etcd
echo "=== etcd stopped at $(date) ==="

# Backup data dir cũ phòng hờ (không xóa ngay)
sudo mv /var/lib/etcd /var/lib/etcd.corrupt-$(date +%Y%m%d-%H%M%S)
sudo mkdir -p /var/lib/etcd
echo "=== data dir cleared ==="

ls -la /var/lib/etcd/
# Expected: thư mục rỗng
```

---

### Bước 3 — Restore từ snapshot

```bash
echo "=== restore start at $(date) ==="

# Thay tên file snapshot phù hợp
SNAP="/var/backups/etcd/etcd-pre-restore-YYYYMMDD-HHMMSS.db"

time sudo ETCDCTL_API=3 etcdctl snapshot restore $SNAP \
  --name=etcd0 \
  --data-dir=/var/lib/etcd \
  --initial-cluster=etcd0=http://172.25.216.164:2380 \
  --initial-advertise-peer-urls=http://172.25.216.164:2380

sudo chown -R root:root /var/lib/etcd
ls -la /var/lib/etcd/
echo "=== restore done at $(date) ==="
```

**Expected:**
```
info    restoring snapshot  {"path": "...db", ...}
info    restored snapshot   {"path": "...db", ...}
real    0m0.124s            ← restore binary rất nhanh

drwx------ 4 root root member/
```

> **[ADD]** Lệnh `etcdctl snapshot restore` sẽ hiện `Deprecated: Use etcdutl` — bình thường,
> vẫn hoạt động đúng với etcd 3.5.4.

---

### Bước 4 — Start etcd + verify healthy

```bash
echo "=== etcd start at $(date) ==="
sudo systemctl start etcd
sleep 2

time ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
echo "=== etcd healthy at $(date) ==="

ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --write-out=table
```

**Expected:**
```
http://127.0.0.1:2379 is healthy: successfully committed proposal: took = 6ms
real    0m0.046s

| http://127.0.0.1:2379 | ef15176a03c43290 | 3.5.4 | 70 kB | true | false | 2 | 5 | 5 | |
```

> **[ADD]** Sau restore:
> - **etcd ID mới** (khác ID cũ) — đúng, restore tạo cluster identity mới
> - **RAFT TERM: 2, RAFT INDEX: 5** — reset về đầu, đúng behavior
> - **DB SIZE khớp snapshot** — data restore thành công

---

### Bước 5 — Verify data còn đủ

```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 \
  get /apisix --prefix --keys-only | wc -l
# Expected: 42

ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 \
  get /apisix/routes --prefix --keys-only
# Expected:
# /apisix/routes/
# /apisix/routes/dashboard
# /apisix/routes/hcm-s3-path
# /apisix/routes/hcm-s3-vhost
# /apisix/routes/route-s3-hcm
```

---

### Bước 6 — Start lại APISIX

Trên **global-lb**:
```bash
cd ~/apisix && docker compose start
sleep 10
docker inspect apisix --format='{{.State.Health.Status}}'
# Expected: healthy
```

Trên **apisixdc-1**:
```bash
cd ~/apisix && docker compose start
sleep 10
docker inspect apisix --format='{{.State.Health.Status}}'
# Expected: healthy
```

---

### Bước 7 — Verify end-to-end

```bash
# Admin API đọc được routes?
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; data=json.load(sys.stdin); print('total routes:', data['total']); [print(' ', r['value']['id']) for r in data['list']]"
# Expected:
# total routes: 4
#   dashboard
#   hcm-s3-path
#   hcm-s3-vhost
#   route-s3-hcm

# S3 traffic OK?
curl -s -o /dev/null -w "HTTP %{http_code} - %{time_total}s\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/
# Expected: HTTP 200 - 0.0xxs
```

---

### Bước 8 — Cleanup data dir cũ (sau khi confirm stable)

> **[ADD]** Giữ lại ít nhất 24h trước khi xóa — phòng trường hợp cần debug.

```bash
# Xem data dir cũ còn đó
ls -lh /var/lib/etcd.corrupt-*/

# Xóa sau khi confirm ổn định
sudo rm -rf /var/lib/etcd.corrupt-*
```

---

## Cài đặt APISIX
```
apisix/
├── docker-compose.yml
├── apisix_conf/
│   └── config.yaml
├── dashboard_conf/         #deprecated
│   └── conf.yaml
├── logs/
│   ├── apisix/
│   │   ├── access.log          
│   │   ├── error.log           
│   │   ├── nginx.pid           
│   │   └── worker_events.sock
│   └── dashboard/          deprecated
└── etcd_data/
```
```
Host machine
├── 127.0.0.1        (loopback - chỉ host thấy)
├── 172.17.0.1       (docker0 - gateway của default bridge)
└── 172.20.0.1       (apisix-net - gateway của network apisix tạo - đây là gateway IP của Docker network apisix-net — tức là địa chỉ của host nhìn từ trong container thuộc network đó.)
         |           Container trong apisix-net muốn gọi ra host → phải dùng 172.20.0.1, không phải 127.0.0.1.
         │
         ├── apisix container        172.20.x.x
         └── apisix-dashboard container  172.20.x.x (từ bản mới đã built-in trong apisix container)
```
# 02 — APISIX Container + etcd cùng VM
> Áp dụng cho **global-lb (172.25.216.164)**  
> TC-00-1: APISIX Traditional mode (CP+DP1) + etcd on-host
> TC-00-2: Tạo upstream, route, SSL cho Ceph S3  
> Yêu cầu: đã hoàn thành `00-prerequisites` và `01-etcd-onhost`

---

## 1. Tạo cấu trúc thư mục

```bash
mkdir -p ~/apisix/apisix_conf ~/apisix/logs/apisix
```

---

## 2. Fix permission logs

> **[ADD]** APISIX container chạy bằng `uid=636(apisix)`.  
> Thư mục logs phải được owned bởi uid=636, không phải ubuntu.

```bash
# Xác nhận uid của APISIX trong image
docker run --rm apache/apisix:3.15.0-debian id
# Expected: uid=636(apisix) gid=636(apisix) groups=636(apisix)

# Set ownership đúng
sudo chown -R nobody:nogroup ~/apisix/logs/
sudo chown -R 636:636 ~/apisix/logs/apisix/
sudo chmod -R 755 ~/apisix/logs/apisix/

sudo chown -R nobody:nogroup \
  ~/apisix-standalone/apisix-standalone-dp-api-driven-yaml/logs/ \
  ~/apisix-standalone/apisix-standalone-dp-api-driven-json/logs/ \
  ~/apisix-standalone/apisix-standalone-traditional/logs/ \
  ~/apisix-traditional/apisix-traditional-1process-cp-dp-0etcd/logs/
sudo chown -R 636:636 \
  ~/apisix-standalone/apisix-standalone-dp-api-driven-yaml/logs/apisix \
  ~/apisix-standalone/apisix-standalone-dp-api-driven-json/logs/apisix \
  ~/apisix-standalone/apisix-standalone-traditional/logs/apisix \
  ~/apisix-traditional/apisix-traditional-1process-cp-dp-0etcd/logs/apisix
sudo chmod -R 755 \
  ~/apisix-standalone/apisix-standalone-dp-api-driven-yaml/logs/apisix \
  ~/apisix-standalone/apisix-standalone-dp-api-driven-json/logs/apisix \
  ~/apisix-standalone/apisix-standalone-traditional/logs/apisix \
  ~/apisix-traditional/apisix-traditional-1process-cp-dp-0etcd/logs/apisix
docker restart \
  apisix-standalone-dp-api-driven-yaml \
  apisix-standalone-dp-api-driven-json \
  apisix-standalone-traditional \
  apisix-traditional-1process-cp-dp-0etcd-A


# Verify
ls -la ~/apisix/logs/
# Expected:
# drwxrwxrwx nobody nogroup  logs/
# drwxr-xr-x 636    636      logs/apisix/
```

> **[ADD]** Nếu container bị restart loop với lỗi "Permission denied on error.log":
```bash
# Xóa file log cũ bị owned sai, để container tự tạo lại
sudo rm -f ~/apisix/logs/apisix/access.log
sudo rm -f ~/apisix/logs/apisix/error.log
# Sau đó docker compose restart
```

---

## 3. Tạo config.yaml

> **[ADD]** File config đầy đủ — bao gồm plugins, prometheus, nginx tuning.  
> Điểm khác biệt với apisixdc-1/2: etcd trỏ `host.docker.internal` (bridge gateway).

```bash
cat > ~/apisix/apisix_conf/config.yaml <<'EOF'
apisix:
  enable_http2: true
  enable_ipv6: false
  node_listen:
    - port: 9080
  ssl:
    enable: true
    listen:
      - port: 9443

deployment:
  admin:
    allow_admin:
      - 0.0.0.0/0
    admin_key:
      - name: "prod-admin"
        key: "1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c"     # openssl rand -hex 32
        role: admin
      - name: "prod-viewer"
        key: "ff09f1b409080faed7d70103597b3d2afeff75ed55ff46d2038a68c113b03dbb"     # openssl rand -hex 32
        role: viewer
    admin_listen:
      ip: 0.0.0.0
      port: 9180

  etcd:
    host:
      - "http://host.docker.internal:2379"
    prefix: "/apisix"
    timeout: 30
    # bỏ user/password vì etcd không còn auth

plugins:
  - real-ip
  - client-control
  - proxy-control
  - request-id
  - zipkin
  - prometheus
  - ip-restriction
  - ua-restriction
  - referer-restriction
  - cors
  - limit-req
  - limit-count
  - limit-conn
  - key-auth
  - jwt-auth
  - basic-auth
  - openid-connect
  - hmac-auth
  - authz-keycloak
  - proxy-rewrite
  - redirect
  - response-rewrite
  - grpc-transcode
  - fault-injection
  - api-breaker
  - traffic-split
  - request-validation

plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics
    enable_export_server: true
    export_addr:
      ip: "0.0.0.0"
      port: 9091

nginx_config:
  worker_processes: auto
  worker_rlimit_nofile: 65536
  event:
    worker_connections: 16384
  http:
    access_log: /usr/local/apisix/logs/access.log
    error_log: /usr/local/apisix/logs/error.log
    error_log_level: warn
    keepalive_timeout: 60
    client_max_body_size: 10m
    lua_shared_dict:
      prometheus-metrics: 15m
EOF
```

---

## 4. Tạo docker-compose.yml

```bash
cat > ~/apisix/docker-compose.yml <<'EOF'
services:
  apisix:
    image: apache/apisix:3.15.0-debian
    container_name: apisix
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./apisix_conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
      - ./logs/apisix:/usr/local/apisix/logs
    ports:
      - "80:9080"
      - "443:9443"
      - "9180:9180"
    environment:
      - TZ=Asia/Ho_Chi_Minh
    healthcheck:
      test: ["CMD-SHELL", "apisix status || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF
```

> **[ADD]** `extra_hosts: host.docker.internal:host-gateway` — cho phép container resolve  
> `host.docker.internal` thành IP của host VM, nơi etcd systemd đang chạy.

---

## 5. Pull image và start

```bash
docker pull apache/apisix:3.15.0-debian

cd ~/apisix && docker compose up -d

# Theo dõi startup
docker logs apisix --tail=20
```

**Expected log startup:**
```
/usr/local/openresty//luajit/bin/luajit ./apisix/cli/apisix.lua init
/usr/local/openresty//luajit/bin/luajit ./apisix/cli/apisix.lua init_etcd
trying to initialize the data of etcd
```

> **[ADD]** Nếu thấy "Permission denied on error.log" → quay lại bước 2 fix permission.

---

## 6. Verify sau khi start

```bash
# Health check
docker inspect apisix --format='{{.State.Health.Status}}'
# Expected: healthy

# Admin API hoạt động
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; print('routes:', json.load(sys.stdin).get('total'))"
# Expected: routes: 4 (hoặc số routes hiện có)

# Dashboard UI
curl -I http://localhost:9180/ui/
# Expected: HTTP/1.1 200 OK

# DP proxy S3
curl -s -o /dev/null -w "HTTP %{http_code} - %{time_total}s\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/
# Expected: HTTP 200 - 0.0xxs
```

---

## 7. Dashboard — cách truy cập đúng (APISIX 3.x)

> **[DEPRECATED]** Đoạn bên dưới là cách cũ dùng cho **APISIX 2.x** với container
> `apache/apisix-dashboard:3.0.1` riêng biệt. Container này đã được **remove** khỏi
> môi trường hiện tại. Route `dashboard` trỏ vào `apisix-dashboard:9000` sẽ trả về
> **502 Bad Gateway** vì upstream không còn tồn tại.
>
> ```bash
> # DEPRECATED — không dùng, chỉ lưu để tham khảo lịch sử
> # Route host-based (APISIX 2.x era)
> curl -X PUT http://172.25.216.164:9180/apisix/admin/routes/dashboard \
>   -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
>   -H "Content-Type: application/json" \
>   -d '{"uri": "/*","host": "api6.lab.thuyldx","upstream": {"type": "roundrobin","nodes": {"apisix-dashboard:9000": 1}}}'
>
> # Route path-based với ip-restriction (APISIX 2.x era)
> curl -X PUT http://172.25.216.164:9180/apisix/admin/routes/dashboard \
>   -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
>   -H "Content-Type: application/json" \
>   -d '{"uri": "/*","upstream": {"type": "roundrobin","nodes": {"apisix-dashboard:9000": 1}},"plugins": {"ip-restriction": {"whitelist": ["<IP_máy_bạn>/32"]}}}'
> ```

**Cách đúng hiện tại — APISIX 3.x tích hợp Dashboard sẵn:**

```bash
# Dashboard UI tại :9180/ui/ — không cần route, không cần container riêng
curl -I http://localhost:9180/ui/
# Expected: HTTP/1.1 200 OK

# Truy cập từ browser
# http://172.25.216.164:9180/ui/
```

> **[ADD]** Nếu muốn expose Dashboard qua domain `api6.lab.thuyldx` trỏ về
> built-in Dashboard (không phải container cũ):
> ```bash
> # Trỏ về chính APISIX process port 9180 — không cần upstream riêng
> curl -X PUT http://172.25.216.164:9180/apisix/admin/routes/dashboard \
>   -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
>   -H "Content-Type: application/json" \
>   -d '{
>     "uri": "/*",
>     "host": "api6.lab.thuyldx",
>     "upstream": {
>       "type": "roundrobin",
>       "nodes": {"172.25.216.164:9180": 1}
>     }
>   }'
> # → Truy cập: http://api6.lab.thuyldx/ui/
> ```

---

## 8. Verify etcd kết nối từ container

> **[ADD]** Confirm container đang dùng etcd onhost, không phải etcd container cũ.

```bash
# Xem config etcd trong container
docker exec apisix cat /usr/local/apisix/conf/config.yaml | grep -A5 etcd
# Expected: host: http://host.docker.internal:2379

# host.docker.internal resolve về IP nào?
docker exec apisix getent hosts host.docker.internal
# Expected: 172.17.0.1 host.docker.internal (hoặc IP bridge tương ứng)
```

---

## 9. Snapshot etcd sau khi APISIX đã config xong

> **[ADD]** Tạo snapshot sau khi đã tạo đủ routes/upstreams/ssl — đây là baseline cho TC-01-7.

```bash
sudo mkdir -p /var/backups/etcd

sudo ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 snapshot save /var/backups/etcd/etcd-baseline-$(date +%Y%m%d).db

sudo ETCDCTL_API=3 etcdctl snapshot status /var/backups/etcd/etcd-baseline-$(date +%Y%m%d).db --write-out=table

ls -lh /var/backups/etcd/
```

**Expected:**
```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 460feb87 |       66 |         71 |      53 kB |
+----------+----------+------------+------------+
-rw------- 1 root root 53K May 11 etcd-baseline-20260511.db
```

---

## 10. Cấu hình Upstream Ceph RGW HCM — TC-00-2

> Topology S3:
> ```
> Client (HTTPS 443)
>     ↓
> APISIX :443  ← SSL termination
>     ↓  HTTP nội bộ
> RGW HCM-1 :3950  (primary,  priority 1)
> RGW HCM-4 :3950  (backup,   priority 0 — chỉ active khi HCM-1 down)
> ```

### 10a. Tạo upstream hcm-rgw (Active/Passive + health check)

```bash
curl -X PUT http://172.25.216.164:9180/apisix/admin/upstreams/hcm-rgw \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hcm-rgw",
    "desc": "Ceph RGW HCM - Active/Passive",
    "type": "roundrobin",
    "nodes": [
      {"host": "172.25.216.241", "port": 3950, "weight": 1, "priority": 1},
      {"host": "172.25.216.186", "port": 3950, "weight": 1, "priority": 0}
    ],
    "checks": {
      "active": {
        "type": "http",
        "http_path": "/",
        "healthy":   {"interval": 5, "successes": 2},
        "unhealthy": {"interval": 5, "http_failures": 3}
      }
    },
    "scheme": "http"
  }'
```

**Expected:** `{"key":"/apisix/upstreams/hcm-rgw","value":{...}}`

> **[ADD]** `priority: 1` = primary (luôn nhận traffic khi healthy).  
> `priority: 0` = backup (chỉ nhận traffic khi priority 1 fail health check).  
> Health check active HTTP GET `/` mỗi 5s — failover sau 3 lần fail liên tiếp.

---

### 10b. Tạo Route path-style

```bash
curl -X PUT http://172.25.216.164:9180/apisix/admin/routes/hcm-s3-path \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hcm-s3-path-style",
    "uri": "/*",
    "host": "s3.hcm.lab.thuyldx",
    "upstream_id": "hcm-rgw"
  }'
```

**Expected:** `{"key":"/apisix/routes/hcm-s3-path","value":{...}}`

> **[ADD]** Path-style S3: `s3.hcm.lab.thuyldx/bucket/object`  
> Route này dùng `upstream_id` tham chiếu upstream đã tạo ở 10a.

---

### 10c. Tạo Route virtual-host style

```bash
curl -X PUT http://172.25.216.164:9180/apisix/admin/routes/hcm-s3-vhost \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hcm-s3-virtual-host",
    "uri": "/*",
    "host": "*.s3.hcm.lab.thuyldx",
    "upstream_id": "hcm-rgw"
  }'
```

**Expected:** `{"key":"/apisix/routes/hcm-s3-vhost","value":{...}}`

> **[ADD]** Virtual-host style S3: `bucket.s3.hcm.lab.thuyldx/object`  
> Wildcard host `*.s3.hcm.lab.thuyldx` match mọi bucket subdomain.

---

## 11. Cấu hình Upstream + Route cho s3.hcm.lab.thuyldx:

### 11a. Tạo Upstream
curl -s http://172.25.216.164:9180/apisix/admin/upstreams/upstream-rgw-hcm \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -H "Content-Type: application/json" \
  -X PUT -d '{
    "id": "upstream-rgw-hcm",
    "name": "RGW HCM Zonegroup",
    "type": "roundrobin",
    "scheme": "http",
    "nodes": {
      "172.25.216.241:3950": 1,
      "172.25.216.186:3950": 1
    }
  }' | jq .

### 11b. Tạo Route
curl -s http://172.25.216.164:9180/apisix/admin/routes/route-s3-hcm \
  -H "X-API-KEY: $KEY" \
  -H "Content-Type: application/json" \
  -X PUT -d '{
    "id": "route-s3-hcm",
    "name": "S3 HCM Zonegroup",
    "host": "s3.hcm.lab.thuyldx",
    "uri": "/*",
    "methods": ["GET","PUT","POST","DELETE","HEAD","OPTIONS","PATCH"],
    "upstream_id": "upstream-rgw-hcm"
  }' | jq .

---

## 12. Upload SSL cert wildcard — TC-00-2

> **[ADD]** Cert `thuyldx.crt` đã có sẵn tại `~/thuyldx.crt` và `~/thuyldx.key`.  
> Valid đến 2036-02-27, cover: `*.thuyldx`, `*.lab.thuyldx`, `*.hcm.lab.thuyldx`, `*.hni.lab.thuyldx`.

### Option A — Upload trực tiếp (yêu cầu jq)

```bash
curl -s http://172.25.216.164:9180/apisix/admin/ssls \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -X POST -d "{
    \"cert\": $(jq -Rs . < ~/thuyldx.crt),
    \"key\": $(jq -Rs . < ~/thuyldx.key),
    \"snis\": [
      \"*.thuyldx\",
      \"*.lab.thuyldx\",
      \"*.hcm.lab.thuyldx\",
      \"*.hni.lab.thuyldx\"
    ]
  }" | jq .
```

### Option B — Tạo payload file trước (an toàn hơn, dễ verify)

```bash
# Tạo payload
jq -n \
  --rawfile cert ~/thuyldx.crt \
  --rawfile key ~/thuyldx.key \
  '{
    cert: $cert,
    key: $key,
    snis: ["*.thuyldx", "*.lab.thuyldx", "*.hcm.lab.thuyldx", "*.hni.lab.thuyldx"]
  }' > /tmp/ssl_payload.json

# Kiểm tra payload trước khi upload
cat /tmp/ssl_payload.json | jq '{snis, cert_preview: (.cert | .[0:50])}'
# Expected: thấy snis array và 50 ký tự đầu của cert

# Upload
curl -s http://172.25.216.164:9180/apisix/admin/ssls \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -H "Content-Type: application/json" \
  -X POST \
  -d @/tmp/ssl_payload.json | jq .
```

**Expected:**
```json
{
  "key": "/apisix/ssls/00000000000000000063",
  "value": {
    "snis": ["*.thuyldx", "*.lab.thuyldx", "*.hcm.lab.thuyldx", "*.hni.lab.thuyldx"],
    "id": "00000000000000000063",
    ...
  }
}
```

> **[ADD]** Verify SSL đã được load:
```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 \
  get /apisix/ssls --prefix --keys-only
# Expected: /apisix/ssls/00000000000000000063
```

---

## 13. Cập nhật DNS — TC-00-2

```bash
sudo nano /etc/bind/zones/db.lab.thuyldx
```

> **[ADD]** Thêm A record cho `s3.hcm.lab.thuyldx` và `api6.lab.thuyldx` trỏ về `172.25.216.164`.  
> Tăng Serial số trước khi reload.

```bash
# Validate zone file
sudo named-checkzone lab.thuyldx /etc/bind/zones/db.lab.thuyldx

# Reload DNS
sudo rndc reload

# Verify DNS resolve
dig s3.hcm.lab.thuyldx +short
# Expected: 172.25.216.164

dig api6.lab.thuyldx +short
# Expected: 172.25.216.164
```

---

## 14. Snapshot sau khi config S3 xong

> **[ADD]** Đây là snapshot quan trọng nhất — sau khi có đủ routes + upstream + SSL.  
> Dùng làm baseline restore cho TC-01-7.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 snapshot save /var/backups/etcd/etcd-s3-configured-$(date +%Y%m%d).db

sudo ETCDCTL_API=3 etcdctl snapshot status /var/backups/etcd/etcd-s3-configured-$(date +%Y%m%d).db --write-out=table

ls -lh /var/backups/etcd/
```

---

# 03 — APISIX Container DP Only
> Áp dụng cho **apisixdc-1 (172.25.216.168)** và **apisixdc-2 (172.25.216.175)**  
> TC-01-1/TC-01-2: APISIX Traditional mode, trỏ etcd cross-DC về global-lb  
> Yêu cầu: đã hoàn thành `00-prerequisites`, etcd trên global-lb đang healthy

---

## 1. Tạo cấu trúc thư mục

```bash
mkdir -p ~/apisix/apisix_conf ~/apisix/logs/apisix
```

---

## 2. Fix permission logs

> **[ADD]** Bước này **bắt buộc** — nếu bỏ qua, container sẽ restart loop với lỗi  
> `"open() /usr/local/apisix/logs/error.log failed (13: Permission denied)"`.

```bash
# Xác nhận uid APISIX trong image
docker run --rm apache/apisix:3.15.0-debian id
# Expected: uid=636(apisix) gid=636(apisix) groups=636(apisix)

# Set ownership đúng
sudo chown -R nobody:nogroup ~/apisix/logs/
sudo chown -R 636:636 ~/apisix/logs/apisix/
sudo chmod -R 755 ~/apisix/logs/apisix/

# Verify
ls -la ~/apisix/logs/
# Expected:
# drwxrwxrwx nobody nogroup  logs/
# drwxr-xr-x 636    636      logs/apisix/
```

> **[ADD]** Nếu container đã chạy và tạo file log với uid=636 trước đó (restart loop):
```bash
# Xóa file log cũ bị owned sai
sudo rm -f ~/apisix/logs/apisix/access.log
sudo rm -f ~/apisix/logs/apisix/error.log
# Set lại ownership
sudo chown -R 636:636 ~/apisix/logs/apisix/
sudo chmod 755 ~/apisix/logs/apisix/
```

---

## 3. Tạo config.yaml

> **[ADD]** Điểm khác biệt duy nhất so với `global-lb`:  
> `etcd host` trỏ IP thực của global-lb (`172.25.216.164`) thay vì `host.docker.internal`.

```bash
cat > ~/apisix/apisix_conf/config.yaml <<'EOF'
apisix:
  enable_http2: true
  enable_ipv6: false
  node_listen:
    - port: 9080
  ssl:
    enable: true
    listen:
      - port: 9443
      
deployment:
  admin:
    allow_admin:
      - 0.0.0.0/0
    admin_key:
      - name: "prod-admin"
        key: "1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c"     # openssl rand -hex 32
        role: admin
      - name: "prod-viewer"
        key: "ff09f1b409080faed7d70103597b3d2afeff75ed55ff46d2038a68c113b03dbb"     # openssl rand -hex 32
        role: viewer
    admin_listen:
      ip: 0.0.0.0
      port: 9180

  etcd:
    host:
      - "http://172.25.216.164:2379"    # <-- trỏ về etcd trên global-lb
    prefix: "/apisix"
    timeout: 30
    # bỏ user/password vì etcd không còn auth

plugins:
  - real-ip
  - client-control
  - proxy-control
  - request-id
  - zipkin
  - prometheus
  - ip-restriction
  - ua-restriction
  - referer-restriction
  - cors
  - limit-req
  - limit-count
  - limit-conn
  - key-auth
  - jwt-auth
  - basic-auth
  - openid-connect
  - hmac-auth
  - authz-keycloak
  - proxy-rewrite
  - redirect
  - response-rewrite
  - grpc-transcode
  - fault-injection
  - api-breaker
  - traffic-split
  - request-validation

plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics
    enable_export_server: true
    export_addr:
      ip: "0.0.0.0"
      port: 9091

nginx_config:
  worker_processes: auto
  worker_rlimit_nofile: 65536
  event:
    worker_connections: 16384
  http:
    access_log: /usr/local/apisix/logs/access.log
    error_log: /usr/local/apisix/logs/error.log
    error_log_level: warn
    keepalive_timeout: 60
    client_max_body_size: 10m
    lua_shared_dict:
      prometheus-metrics: 15m
EOF
```

> **[ADD]** Khi deploy lên **apisixdc-2** cho TC-01-8 (Case 4 CP2):  
> Config giữ nguyên — apisixdc-2 cũng trỏ etcd về `172.25.216.164:2379`.

---

## 4. Tạo docker-compose.yml

> **[ADD]** File này giống hệt `global-lb` — `extra_hosts` giữ nguyên,  
> không ảnh hưởng gì khi etcd trỏ IP trực tiếp trong config.yaml.

```bash
cat > ~/apisix/docker-compose.yml <<'EOF'
services:
  apisix:
    image: apache/apisix:3.15.0-debian
    container_name: apisix
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./apisix_conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
      - ./logs/apisix:/usr/local/apisix/logs
    ports:
      - "80:9080"
      - "443:9443"
      - "9180:9180"
    environment:
      - TZ=Asia/Ho_Chi_Minh
    healthcheck:
      test: ["CMD-SHELL", "apisix status || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF
```

---

## 5. Pull image và start

```bash
docker pull apache/apisix:3.15.0-debian

cd ~/apisix && docker compose up -d

# Theo dõi startup
sleep 15 && docker logs apisix --tail=10
```

**Expected log startup (clean, không có error):**
```
/usr/local/openresty//luajit/bin/luajit ./apisix/cli/apisix.lua init
/usr/local/openresty//luajit/bin/luajit ./apisix/cli/apisix.lua init_etcd
trying to initialize the data of etcd
```

> **[ADD]** Nếu thấy "Permission denied" → quay lại bước 2.  
> Nếu thấy "has no healthy etcd endpoint" → kiểm tra connectivity port 2379 về global-lb.

---

## 6. Verify sau khi start

```bash
# Health check
docker inspect apisix --format='{{.State.Health.Status}}'
# Expected: healthy

# Đọc routes từ etcd DC1 (cross-DC)
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; data=json.load(sys.stdin); print('total routes:', data['total']); [print(' ', r['value']['id'], '->', r['value'].get('host','')) for r in data['list']]"
# Expected: total routes: 4 — thấy đúng routes đã tạo từ global-lb

# DP proxy S3
curl -s -o /dev/null -w "HTTP %{http_code} - %{time_total}s\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/
# Expected: HTTP 200 - 0.0xxs

# Verify response header có APISIX và x-amz
curl -sI -H 'Host: s3.hcm.lab.thuyldx' http://localhost/ | grep -E 'HTTP|Server|x-amz'
# Expected:
# HTTP/1.1 200 OK
# x-amz-request-id: txXXXXXXXXXXXXXXXX
# Server: APISIX/3.15.0
```

---

## 7. Troubleshooting

> **[ADD]** Các lỗi thường gặp và cách fix.

### Container restart loop — Permission denied
```bash
# Xem lỗi
docker logs apisix --tail=5
# "open() /usr/local/apisix/logs/error.log failed (13: Permission denied)"

# Fix
docker compose down
sudo rm -f ~/apisix/logs/apisix/*.log
sudo chown -R 636:636 ~/apisix/logs/apisix/
docker compose up -d
```

### etcd không reach được
```bash
# Kiểm tra connectivity
nc -zv 172.25.216.164 2379
# Nếu fail → check firewall global-lb:
# sudo iptables -L INPUT -n | grep 2379
# sudo ufw status

# Kiểm tra etcd trên global-lb có đang chạy không
ssh ubuntu@172.25.216.164 'sudo systemctl status etcd | grep Active'
```

### Admin API trả về "has no healthy etcd endpoint"
```bash
# etcd đang chết hoặc blocked
# Kiểm tra từ container
docker exec apisix wget -qO- http://172.25.216.164:2379/health
# Expected: {"health":"true","reason":""}
```

---

# 04 — Verify Checklist
> Chạy sau mỗi deploy hoặc sau mỗi TC để confirm trạng thái hệ thống  
> Tất cả lệnh dùng inline key, không dùng biến shell

---

## Checklist tổng quan

| # | Check | VM | Expected |
|---|---|---|---|
| 1 | etcd healthy | global-lb | `is healthy` |
| 2 | APISIX container healthy | tất cả | `healthy` |
| 3 | Admin API đọc được routes | tất cả | `total: 4` |
| 4 | DP proxy S3 | tất cả | `HTTP 200` |
| 5 | etcd data còn đủ | global-lb | `71 keys` |

---

## 1. etcd health — global-lb

```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
```
**Expected:**
```
http://127.0.0.1:2379 is healthy: successfully committed proposal: took = Xms
```

```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --write-out=table
```
**Expected:**
```
| http://127.0.0.1:2379 | 1c70f9bbb41018f | 3.5.4 | 53 kB | true | false | 5 | 79 | 79 | |
```

---

## 2. APISIX container health — tất cả VM

```bash
docker inspect apisix --format='{{.State.Health.Status}}'
```
**Expected:** `healthy`

```bash
docker ps -a
```
**Expected:** `STATUS: Up X minutes (healthy)`, không có `Restarting`

---

## 3. Admin API — đọc routes

**Từ global-lb:**
```bash
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; data=json.load(sys.stdin); print('total routes:', data['total']); [print(' ', r['value']['id'], '->', r['value'].get('host','')) for r in data['list']]"
```

**Từ apisixdc-1:**
```bash
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; data=json.load(sys.stdin); print('total routes:', data['total']); [print(' ', r['value']['id'], '->', r['value'].get('host','')) for r in data['list']]"
```

**Expected (cả 2 phải giống nhau):**
```
total routes: 4
  dashboard -> api6.lab.thuyldx
  hcm-s3-path -> s3.hcm.lab.thuyldx
  hcm-s3-vhost -> *.s3.hcm.lab.thuyldx
  route-s3-hcm -> s3.hcm.lab.thuyldx
```

---

## 4. DP proxy S3 — tất cả VM

```bash
curl -s -o /dev/null -w "HTTP %{http_code} - %{time_total}s\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/
```
**Expected:** `HTTP 200 - 0.0xxs`

```bash
curl -sI -H 'Host: s3.hcm.lab.thuyldx' http://localhost/ | grep -E 'HTTP|Server|x-amz'
```
**Expected:**
```
HTTP/1.1 200 OK
x-amz-request-id: txXXXXXXXXXXXXXXXX
Server: APISIX/3.15.0
```

---

## 5. etcd data integrity — global-lb

```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 get /apisix --prefix --keys-only | wc -l
```
**Expected:** `42` (hoặc số keys hiện tại)

```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 get /apisix --prefix --keys-only
```
**Expected — các keys quan trọng phải có:**
```
/apisix/routes/hcm-s3-path
/apisix/routes/hcm-s3-vhost
/apisix/upstreams/hcm-rgw
/apisix/ssls/00000000000000000063
```

---

## 6. Admin API write test — verify CP hoạt động

> **[ADD]** Test nhanh xem CP có ghi được vào etcd không.

```bash
# Tạo route test
curl -s -X PUT "http://localhost:9180/apisix/admin/routes/verify-test" -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" -H "Content-Type: application/json" -d '{"uri":"/verify","host":"verify.lab","upstream":{"type":"roundrobin","nodes":{"127.0.0.1:9999":1}}}'
```
**Expected:** `{"key":"/apisix/routes/verify-test","value":{...}}`

```bash
# Cleanup
curl -s -X DELETE "http://localhost:9180/apisix/admin/routes/verify-test" -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c"
```
**Expected:** `{"key":"/apisix/routes/verify-test","deleted":"1"}`

---

## 7. Snapshot status — global-lb

```bash
ls -lh /var/backups/etcd/
```
**Expected:** có ít nhất 1 file `.db`

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /var/backups/etcd/etcd-baseline-20260511.db --write-out=table
```
**Expected:**
```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 460feb87 |       66 |         71 |      53 kB |
+----------+----------+------------+------------+
```

---

## 8. Quick all-in-one check

> **[ADD]** Chạy 1 lệnh để kiểm tra nhanh toàn bộ trạng thái.  
> Chạy trên **global-lb**:

```bash
echo "=== $(date) ===" && \
echo "--- etcd ---" && \
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint health && \
echo "--- APISIX DC1 ---" && \
docker inspect apisix --format='health: {{.State.Health.Status}}' && \
curl -s -o /dev/null -w "S3 DP1: HTTP %{http_code}\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/ && \
echo "--- routes ---" && \
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 get /apisix/routes --prefix --keys-only
```

> Chạy trên **apisixdc-1**:
```bash
echo "=== $(date) ===" && \
echo "--- APISIX DC2 ---" && \
docker inspect apisix --format='health: {{.State.Health.Status}}' && \
curl -s -o /dev/null -w "S3 DP2: HTTP %{http_code}\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/ && \
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; print('routes:', json.load(sys.stdin).get('total','ERROR'))"
```

**Expected cả 2:**
```
=== Wed May 13 ...===
--- etcd ---
http://127.0.0.1:2379 is healthy ...
--- APISIX DC1/DC2 ---
health: healthy
S3 DP1/DP2: HTTP 200
--- routes ---
/apisix/routes/hcm-s3-path
/apisix/routes/hcm-s3-vhost
...
routes: 4
```

---

## 9. Test S3 end-to-end — HTTP + HTTPS

> Chạy sau khi đã upload SSL cert và DNS đã resolve đúng (xem `02-apisix-with-etcd.md` mục 10-11).

### 9a. Test HTTPS SSL handshake

```bash
curl -vk https://s3.hcm.lab.thuyldx 2>&1 | grep -E "SSL|subject|issuer|HTTP|< "
```
**Expected:**
```
* SSL connection using TLSv1.3 / ...
* Server certificate:
*   subject: CN=thuyldx
*   issuer: CN=ThuyLDX Root CA
< HTTP/2 200
```

### 9b. Test S3 API — list buckets (HTTP)

```bash
curl -sk https://s3.hcm.lab.thuyldx -H "Host: s3.hcm.lab.thuyldx" | head -20
```
**Expected:** XML response từ Ceph RGW
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListAllMyBucketsResult ...>
```

### 9c. Test bằng s3cmd

```bash
s3cmd --host=s3.hcm.lab.thuyldx \
      --host-bucket="%(bucket)s.s3.hcm.lab.thuyldx" \
      --access_key=YOUR_ACCESS_KEY \
      --secret_key=YOUR_SECRET_KEY \
      --no-ssl-check \
      ls
```
**Expected:** danh sách buckets hoặc empty list (không có 4xx/5xx error)

### 9d. Test bằng AWS CLI

```bash
aws s3 ls \
  --endpoint-url https://s3.hcm.lab.thuyldx \
  --no-verify-ssl
```
**Expected:** danh sách buckets hoặc empty (không có `An error occurred`)

> **[ADD]** Nếu nhận `SSL: CERTIFICATE_VERIFY_FAILED` với s3cmd/awscli:  
> Thêm `--no-ssl-check` (s3cmd) hoặc `--no-verify-ssl` (awscli) cho lab.  
> Production cần import rootCA vào system trust store:
> ```bash
> sudo cp ~/rootCA.crt /usr/local/share/ca-certificates/thuyldx-root.crt
> sudo update-ca-certificates
> ```


## Quick Reference — Behavior Matrix
```
┌──────────────┬──────────┬──────────┬──────────┬──────────┐
│ Scenario     │ S3 DC1   │ S3 DC2   │ CP write │ CP read  │
├──────────────┼──────────┼──────────┼──────────┼──────────┤
│ All healthy  │ ✅ 200   │ ✅ 200   │ ✅ 27ms  │ ✅       │
│ etcd block   │ ✅ 200   │ ✅ 200   │ ❌ fail  │ ❌ fail  │
│ etcd die     │ ✅ 200   │ ✅ 200   │ ❌ fail  │ ❌ fail  │
│ DC1 die      │ ❌ down  │ ✅ 200   │ ❌ fail  │ ❌ fail  │
│ etcd restore │ ✅ 200   │ ✅ 200   │ ✅ auto  │ ✅ auto  │
│ APISIX rst   │ ✅ 200*  │ ✅ 200   │ ✅       │ ✅       │
└──────────────┴──────────┴──────────┴──────────┴──────────┘
* APISIX restart yêu cầu etcd phải healthy trước






### Cài ADC
Chạy trên global-lb - đang test case traditional mode:
B1: Cài adc CLI
curl -sL https://run.api7.ai/adc/install | bash
adc --version
# Expected: 0.25.0

B2: Ping verify kết nối — token pass trực tiếp (không có configure command)
adc ping --backend apisix --server http://127.0.0.1:9180 --token 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c
# Expected: Connected to the "apisix" backend successfully!

B3: Dump current config
adc dump --backend apisix --server http://127.0.0.1:9180 --token 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c -o ~/adc-current.yaml
cat ~/adc-current.yaml
# Expected: thấy ssls, services, consumers... hiện có

B4: Tạo file desired — schema adc v0.25.0 dùng services+uris (không phải routes+uri)
cat > ~/adc-desired.yaml <<'EOF'
services:
  - name: adc-test-service
    upstream:
      name: adc-test-upstream
      scheme: http
      type: roundrobin
      nodes:
        - host: 172.25.216.241
          port: 3950
          weight: 1
    routes:
      - name: adc-test-route
        uris:
          - /adc-test
        methods:
          - GET
          - PUT
          - POST
          - DELETE
          - HEAD
          - OPTIONS
          - PATCH
EOF

# Lint trước khi diff
adc lint -f ~/adc-desired.yaml
# Expected: All is well

B5: Diff — QUAN TRỌNG đọc kỹ trước khi sync
adc diff --backend apisix --server http://127.0.0.1:9180 --token 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c -f ~/adc-desired.yaml
cat ~/diff.yaml | grep "type:"
# Expected:
# type: delete → ssl ⚠️  (vì adc-desired.yaml không có ssls section)
# type: create → service adc-test-service
# type: create → route adc-test-route
# → PHẢI dùng --exclude-resource-type ssl khi sync

B6: Sync — exclude ssl để không xóa cert
adc sync --backend apisix --server http://127.0.0.1:9180 --token 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c --exclude-resource-type ssl -f ~/adc-desired.yaml
# Expected:
# Create service: "adc-test-service" ✅
# Create route: "adc-test-route" ✅

# Verify Admin API
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; data=json.load(sys.stdin); print('total:', data['total']); [print(' ', r['value']['id']) for r in data['list']]"
# Expected: total: 5 (4 cũ + 1 mới với ID hash)

B7: Test DP proxy route vừa tạo
curl -sv http://localhost/adc-test 2>&1 | grep -E "HTTP|x-amz|Server"
# Expected:
# HTTP/1.1 404 (404 từ RGW — không phải APISIX)
# x-amz-request-id: ... ← confirm request đã qua RGW
# Server: APISIX/3.15.0

B8: Delete — sync về empty state
cat > ~/adc-empty.yaml <<'EOF'
services: []
EOF

adc sync --backend apisix --server http://127.0.0.1:9180 --token 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c --exclude-resource-type ssl -f ~/adc-empty.yaml
# Expected:
# Delete route: "adc-test-route" ✅
# Delete service: "adc-test-service" ✅

# Verify về lại 4 routes, ssl còn nguyên, S3 OK
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; print('total:', json.load(sys.stdin)['total'])"
curl -s http://localhost:9180/apisix/admin/ssls -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | python3 -c "import sys,json; print('ssls:', json.load(sys.stdin)['total'])"
curl -s -o /dev/null -w "S3: HTTP %{http_code}\n" -H 'Host: s3.hcm.lab.thuyldx' http://localhost/
# Expected: total: 4 / ssls: 1 / S3: HTTP 200







### Bật plugin cho route
# Enable trên hcm-s3-path
curl -s -X PATCH http://172.25.216.164:1180/apisix/admin/routes/hcm-s3-path \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" \
  -H "Content-Type: application/json" \
  -d '{"plugins": {"ceph-rados-regex": {}}}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('hcm-s3-path plugins:', list(d['value']['plugins'].keys()))
"


### Kiếm tra những plugin đang được bật ở all route:
curl -s http://172.25.216.164:1180/apisix/admin/routes \
  -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data['list']:
    v = r['value']
    print(f'{v[\"id\"]:25} plugins: {list(v.get(\"plugins\",{}).keys())}')
"





### Cài WebHook
Chuẩn bị
Trên GitLab
    Xác định Project ID.
    Tạo Personal Access Token có scope read_repository.
    Tạo webhook trong project:
        URL: http://172.25.216.164:9000/hooks/redeploy
        Secret token: ví dụ Aqswde123@@
        Trigger: Push events

~/webhook/
├── hooks.json
├── deploy.log
└── scripts/
    └── deploy.sh

sudo apt-get install webhook
webhook --version
mkdir -p ~/webhook/scripts


~/etc/systemd/system/webhook.service 
  [Unit]
  Description=Webhook Server
  Documentation=https://github.com/adnanh/webhook
  After=network.target

  [Service]
  Type=simple
  User=ubuntu
  #Group=webhook
  ExecStart=/usr/bin/webhook -verbose -hotreload \
      -hooks /home/ubuntu/webhook/hooks.json \
      -port 9000 \
  #    -ip 127.0.0.1
  Restart=always
  RestartSec=5
  #NoNewPrivileges=true
  #ProtectHome=true

  [Install]
  WantedBy=multi-user.target



Kích hoạt:
sudo systemctl daemon-reload && sudo systemctl enable webhook && sudo systemctl restart webhook && sudo systemctl status webhook



~/webhook/hooks.json
  [
    {
      "id": "redeploy",
      "execute-command": "/home/ubuntu/webhook/scripts/deploy.sh",
      "command-working-directory": "/home/ubuntu/webhook",
      "pass-environment-to-command": [
        {
          "envname": "PAYLOAD",
          "source": "entire-payload"
        }
      ],
      "trigger-rule": {
        "match": {
          "type": "value",
          "value": "Aqswde123@@",
          "parameter": { "source": "header", "name": "X-Gitlab-Token" }
        }
      }
    }
  ]


~/webhook/scripts/deploy.sh
  #!/bin/bash

  PROJECT_DIR="/home/ubuntu/apisix-standalone/apisix-standalone-yaml-profile"
  LOG="/home/ubuntu/webhook/deploy.log"
  GITLAB_TOKEN="glpat-qnJsQLKZowospax-XH6u"   # thay token thật vào đây
  GITLAB_PROJECT_ID="151"
  GITLAB_HOST="https://git-lab.infiniband.vn"
  BRANCH="main"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Webhook triggered" >> "$LOG"

  if [ -z "$PAYLOAD" ] || [ "$PAYLOAD" = "null" ]; then
    echo "No payload received" >> "$LOG"
    exit 0
  fi

  # Lấy tất cả file thay đổi (modified + added) từ commit mới nhất
  CHANGED_FILES=$(echo "$PAYLOAD" | python3 -c "
  import sys, json
  data = json.load(sys.stdin)
  files = set()
  for commit in data.get('commits', []):
      files.update(commit.get('modified', []))
      files.update(commit.get('added', []))
  for f in files:
      print(f)
  ")

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Changed files: $CHANGED_FILES" >> "$LOG"

  # Download từng file về đúng vị trí
  while IFS= read -r FILE_PATH; do
    [ -z "$FILE_PATH" ] && continue

    ENCODED_PATH="${FILE_PATH//\//%2F}"
    LOCAL_PATH="$PROJECT_DIR/$FILE_PATH"

    # Tạo thư mục nếu chưa có
    mkdir -p "$(dirname "$LOCAL_PATH")"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Downloading: $FILE_PATH" >> "$LOG"

    wget -q --header="PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT_ID}/repository/files/${ENCODED_PATH}/raw?ref=${BRANCH}" \
      -O "$LOCAL_PATH" 2>> "$LOG"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated: $LOCAL_PATH" >> "$LOG"

  done <<< "$CHANGED_FILES"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done" >> "$LOG"



Kích hoạt:
chmod +x ~/webhook/scripts/deploy.sh


Test local:
curl -X POST http://localhost:9000/hooks/redeploy \
  -H "X-Gitlab-Token: Aqswde123@@"


Xem log:
sudo journalctl -u webhook -f
tail -f ~/webhook/deploy.log

Quy trình vận hành
    Dev sửa file trong GitLab repo.
    Commit và push lên branch main.
    GitLab Webhook gọi vào VM.
    webhook nhận payload.
    deploy.sh đọc danh sách file thay đổi.
    Script tải từng file tương ứng từ GitLab API.
    File local được ghi đè.
    APISIX standalone tự reload nếu môi trường của bạn hỗ trợ hot reload.

Khuyến nghị vận hành
    Chỉ cho phép các path hợp lệ như apisix_conf/*.yaml và docker-compose.yaml.
    Không dùng token quá quyền, chỉ cần read_repository.
    Định kỳ kiểm tra ~/webhook/deploy.log.
    Nếu đổi file bằng editor như nano, nhớ rằng hot reload file watcher có thể bị ảnh hưởng nếu file bị replace hoàn toàn; nếu gặp lỗi, restart service để reload hook.
    Nếu commit nhiều file cùng lúc, script hiện tại đã gom toàn bộ modified + added, nên sẽ tải đủ các file được thay đổi.

Checklist triển khai
    Cài binary webhook
    Tạo ~/webhook/hooks.json
    Tạo ~/webhook/scripts/deploy.sh
    Cấp quyền execute cho script
    Tạo systemd service
    Restart và verify service
    Cấu hình GitLab Webhook
    Test push event thật
    Kiểm tra file đã về đúng thư mục


ADMIN_KEY=""
HOST=""

# Routes
echo "=== ROUTES ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/routes | jq .

# Services
echo "=== SERVICES ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/services | jq .

# Upstreams
echo "=== UPSTREAMS ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/upstreams | jq .

# Plugins list
echo "=== PLUGINS ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/plugins/list | jq .

# SSL
echo "=== SSL ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/ssls | jq .

# Global rules
echo "=== GLOBAL RULES ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/global_rules | jq .

# Consumers
echo "=== CONSUMERS ===" && curl -s -H "X-API-KEY: 1df5f679c8669b7f06a8db95016ec377742810717fa2d7d1d4221e877f12a84c" http://172.25.216.164:1180/apisix/admin/consumers | jq .