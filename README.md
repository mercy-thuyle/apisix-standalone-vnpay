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
