# APISIX Standalone — Best Practices

> **Phạm vi:** APISIX Standalone (`config_provider: yaml`) cho S3 gateway 2 DC  
> **Không áp dụng cho:** Traditional mode (etcd) hoặc Decoupled mode  
> **Nguồn:** Lab findings GD0 (TC-00-1 → TC-00-7), GD1, GD2  
> **Version:** APISIX 3.15.0-debian  
> **Document version:** 9.0

---

## Mục lục

1. [Tổng quan & Nguyên tắc](#1-tổng-quan-nguyên-tắc)
2. [GitOps — release/routes & release/system](#2-gitops-releaseroutes-releasesystem)
3. [Production Deployment](#3-production-deployment)
4. [Plugin — S3 Gateway](#4-plugin-s3-gateway)
5. [Vận hành](#5-vận-hành)
6. [Bảo mật](#6-bảo-mật)
7. [Hiệu năng & Resilience](#7-hiệu-năng-resilience)
8. [Observability](#8-observability)
9. [Ma trận tổng hợp & Troubleshoot](#9-ma-trận-tổng-hợp--troubleshoot)

---

## 1. Tổng quan & Nguyên tắc

```
Standalone mode = data_plane + config_provider: yaml/json

Đặc điểm cơ bản:
  - Không có etcd dependency               <- loại bỏ SPOF lớn nhất của GD0/GD1
  - Không có Admin API (port 9180 disabled) <- confirmed TC-00-6, TC-00-7
  - Config từ file local: apisix-{profile}.yaml hoặc apisix-{profile}.json
  - Hot-reload: APISIX watch mtime file mỗi 1 giây
  - Config trong nginx worker memory: serve traffic kể cả khi file bị thao tác sai

So sánh với Traditional mode (GD0/GD1):
  Traditional: DP serve OK khi etcd die — nhưng etcd là SPOF của CP
  Standalone:  không có etcd = không có failure domain đó = simpler operations


Phù hợp với:
  - S3 gateway (config thay đổi ít)
  - Multi-DC config khác nhau per DC
  - Không muốn quản lý etcd cluster
```

**3 tầng độc lập, bổ sung nhau:**

| Tầng | Giải quyết | Cơ chế |
|---|---|---|
| **Standalone** | Runtime — khi file thay đổi thì làm gì | Hot-reload / docker restart |
| **Profile** | Identity — đọc file nào | `APISIX_PROFILE=dc1` |
| **GitOps (git-sync)** | Delivery — file đến từ đâu, ai thay đổi | release/routes + release/system |

**2 loại file — 2 vòng đời khác nhau:**

| File | Nội dung | Reload | Owner |
|---|---|---|---|
| `config-{profile}.yaml` | worker_processes, plugin list, ports | `docker restart` | Platform Team |
| `apisix-{profile}.yaml` | routes, upstreams, ssl, consumers | Hot-reload tự động | Service Team |

---

## 2. GitOps — release/routes & release/system

### 2.1 Lý do dùng git-sync thay Webhook

> Lý do migration: webhook yêu cầu GitLab có thể gọi vào VM (inbound port 9000), không phù hợp môi trường DC internal có firewall nghiêm ngặt. git-sync dùng mô hình pull-only, không mở thêm port nào trên VM.

| Tiêu chí | Webhook (adnanh) — v3 | git-sync Pull-based — v4 |
|---|---|---|
| **Trigger** | GitLab push → gọi vào VM port 9000 | VM chủ động poll GitLab mỗi 30s |
| **Hướng kết nối** | GitLab → VM (**inbound** — cần mở firewall) | VM → GitLab (**outbound** — không mở port) |
| **Phù hợp DC internal** | ❌ Khó — firewall block inbound từ GitLab | ✅ Dễ — VM luôn có thể kết nối ra GitLab |
| **Độ trễ apply** | < 1s sau push | 0–30s (tùy poll interval) |
| **Tách biệt release/system vs release/routes** | ❌ Không có — 1 branch, 1 hook | ✅ Có — 2 git-sync instance, 2 branch |
| **Hard-restart tự động** | ✅ deploy.sh tự detect + restart | ✅ systemd path watcher trên host |
| **Hot-reload** | ✅ cp giữ inode → APISIX detect | ✅ exechook copy file → inotify detect |
| **Rollback** | git revert → push → webhook trigger | git revert → push → git-sync detect tự động |
| **Cài đặt** | Binary systemd (nhẹ) | Container sidecar trong docker-compose |
| **Secret** | Token tĩnh trong hooks.json | SSH Deploy Key (Ed25519, Read-only) |
| **Không cần CI Runner** | ✅ | ✅ |

**Kết luận:** git-sync phù hợp hơn cho môi trường DC internal. Trade-off duy nhất là độ trễ tối đa 30s thay vì < 1s — chấp nhận được với S3 config thay đổi ít.

### 2.2 Kiến trúc 2 branch chính

Điểm khác biệt quan trọng nhất so với webhook (1 branch): git-sync dùng **2 branch riêng biệt**, phản ánh đúng 2 loại file trong APISIX Standalone.

```
GitLab repo
│
├── main                    ← Infra: scripts, CI templates, docker-compsoe.yaml, README
│   ├── docker-compose.yaml
│   └── scripts/
│       ├── gitsync.sh        ← exechook wrapper (source of truth)
│       └── compile.py
├── release/routes          ← Service Team: routes, upstreams, services, ssl
│   ├── fragments/routes/   ← source fragments per service/tenant
│   │   ├── route-s3-dc1.yaml
│   │   ├── route-s3-dc2.yaml
│   │   ├── route-ekyc-dc1.yaml
│   │   └── ...
│   ├── fragments/upstreams/
│   │   ├── upstream-ceph-dc1.yaml
│   │   ├── upstream-ceph-dc2.yaml
│   │   └── ...
│   ├── apisix-dc1.yaml     ← compiled output cho DC1, CI tự commit sau khi merge
│   └── apisix-dc2.yaml     ← compiled output cho DC2, CI tự commit sau khi merge
└── release/system          ← Platform Team: system config + custom plugins + APISIX (nginx tuning)
    ├── config-dc1.yaml     ← worker_processes, plugin list DC1
    ├── config-dc2.yaml     ← worker_processes, plugin list DC2
    └── plugins_lua/
        └── ceph-rados-regex.lua


    ↓ mỗi git-sync instance poll 30s (SSH, shallow clone)
┌─────────────────── DC1 (Host) ───────────────────────────┐
│                                                          │
│  /opt/apisix/standalone/sandbox/                         │
│  ├── conf_routes/   ← release/routes (gitsync-routes)   │
│  │   ├── current → rev-abc/  (atomic symlink)            │
│  │   └── apisix-dc1.yaml     (exechook copy)             │
│  └── conf_system/  ← release/system (gitsync-system)    │
│      └── config-dc1.yaml     (exechook copy)             │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │  apisix-dc1-1  ←→  gitsync-dc1-1  (sidecar)    │     │
│  │  apisix-dc1-2  ←→  gitsync-dc1-2  (sidecar)    │ ← scale-out
│  │  apisix-dc1-N  ←→  gitsync-dc1-N  (sidecar)    │     │
│  └─────────────────────────────────────────────────┘     │
│                                                          │
│  Tất cả apisix-dc1-* đọc cùng conf_routes/               │
│  → Cùng config, dù có N instance                         │
└──────────────────────────────────────────────────────────┘

┌─────────────────── DC2 (Host) ───────────────────────────┐
│  Hoàn toàn độc lập với DC1                               │
│  DC2 up/down không ảnh hưởng DC1 (và ngược lại)          │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │  apisix-dc2-1  ←→  gitsync-dc2-1  (sidecar)    │     │
│  │  apisix-dc2-2  ←→  gitsync-dc2-2  (sidecar)    │     │
│  └─────────────────────────────────────────────────┘     │
│  Đọc apisix-dc2.yaml (khác DC1), config-dc2.yaml         │
└──────────────────────────────────────────────────────────┘
```

**Branch ownership:**

| Branch | Owner | Thay đổi khi nào | APISIX action | Downtime |
|---|---|---|---|
| `release/routes` | Service Team | Thêm tenant, sửa upstream, thêm route | Hot-reload tự động | Zero |
| `release/system` | Platform Team | Tune nginx, thêm plugin, thay đổi worker | Admin `docker restart` | ~5-10s |
| `main` | Platform Team | Infra thay đổi, script update | Admin apply thủ công | Theo service |

### 2.3 gitsync.sh — Exechook wrapper

**Vấn đề:** git-sync v4 exec command không qua shell → inline command có space bị parse sai.  
**Giải pháp:** wrapper script, managed trên `main` branch, gitsync-master tự sync về.
> File [gitsync.sh](../-/blob/main/scripts/gitsync.sh)

> **Lưu ý shebang:** `#!/bin/sh` — không được thêm text sau `/bin/sh`, sẽ bị parse như argument → `fork/exec` fail.

### 2.4 Luồng deploy theo loại thay đổi

**Thêm/sửa route (Service Team):**
```
commit → merge vào release/routes
  → gitsync-routes pull về (≤30s)
  → gitsync.sh copy apisix-dc1.yaml
  → APISIX hot-reload tự động ✅
```

**Thêm plugin / sửa config system (Platform Team):**
```
commit → merge vào release/system
  → gitsync-system pull về (≤30s)
  → gitsync.sh copy config-dc1.yaml + plugins_lua/
  → Admin: docker compose restart apisix-standalone
```

**Thay đổi docker-compose / gitsync.sh (Platform Team):**
```
commit → merge vào main
  → gitsync-master pull về (≤30s)
  → gitsync.sh copy docker-compose.yaml + scripts/*
  → Admin review diff rồi tự quyết định có restart không
```

### 2.5 Rollback

```bash
# Rollback release/routes (Service Team)
git revert <bad-commit> && git push origin release/routes
# git-sync tự detect trong ≤30s → hot-reload tự động

# Rollback khẩn cấp không cần GitLab
cp conf_routes/.worktrees/<good-hash>/apisix-dc1.yaml \
   conf_routes/apisix_routes/apisix-dc1.yaml
```

### 2.6 CI/CD — Validate trước khi merge

```yaml
# .gitlab-ci.yml (release/routes)
validate:
  script:
    - yamllint apisix-dc1.yaml apisix-dc2.yaml
    - python3 scripts/compile.py --validate
    - docker run apache/apisix:3.15.0-debian apisix test -c apisix-dc1.yaml

# Không merge nếu:
# - YAML syntax lỗi
# - Thiếu #END flag
# - Route trùng ID
# - Upstream không resolve được
```

### 2.7 Systemd watcher — auto restart khi release/system thay đổi

```ini
# /etc/systemd/system/apisix-config-watcher.path
[Path]
PathModified=/opt/apisix/standalone/sandbox/conf_system/apisix_config/config-dc1.yaml
Unit=apisix-config-watcher.service

# /etc/systemd/system/apisix-config-watcher.service
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/docker restart apisix-dc1
```

```bash
sudo systemctl enable --now apisix-config-watcher.path
systemctl status apisix-config-watcher.path
# Expected: active (waiting)
```

### 2.8 Giới hạn của git-sync

```
Không có:
  - Event-driven như webhook (< 1s) → lag tối đa 30s
    → Chấp nhận được: S3 config thay đổi ít, không cần real-time
    → Nếu cần nhanh hơn: giảm GITSYNC_PERIOD xuống 10s

  - Validate logic error sau hot-reload
    → Upstream IP sai (valid YAML) → apply luôn → 502 đến khi revert
    → Rule: luôn health-check curl sau khi merge release/routes
    → Prometheus alert: APISIX_UpstreamUnhealthy catch trong 30s

  - Kiểm soát thứ tự hot-reload giữa các instance trong DC
    → Tất cả apisix-dc1-* đọc chung conf_routes/ → hot-reload gần như đồng thời
    → Khoảng cách chỉ vài ms (do mtime poll 1s của mỗi worker độc lập)
    → Trong thời gian chuyển tiếp ngắn: các instance có thể chạy config khác nhau
    → Thực tế: không gây vấn đề với stateless S3 proxy

Có:
  ✅ Pull-only — không cần mở inbound port (phù hợp DC internal)
  ✅ Atomic symlink — không bao giờ đọc file dở dang
  ✅ Giữ N revision cũ → emergency rollback không cần backup script
  ✅ Tách biệt release/routes vs release/system — 2 vòng đời độc lập
  ✅ Scale-out zero-config: thêm apisix-dc1-N mount vào cùng conf_routes/ → tự đồng bộ
  ✅ DC isolation: DC1 và DC2 hoàn toàn độc lập, không có deploy order
  ✅ inode-safe: exechook dùng `cp` → APISIX hot-reload reliable (Finding 5)
  ✅ SSH Deploy Key: an toàn hơn token tĩnh, dễ rotate
  ✅ Không cần CI runner trên VM
  ✅ systemd path watcher: hard-restart tất cả container DC khi config thay đổi
```

---

## 3. Production Deployment

### 3.1 Kiến trúc — 1 APISIX per VM

```
[ External L4 LB ]          ← Infrastructure Team quản lý
  ↓ round-robin
  ├── VM DC1-Node-1 :9080   ← APISIX + git-sync
  ├── VM DC1-Node-2 :9080   ← scale-out: thêm VM, báo IP cho LB team
  └── VM DC1-Node-N :9080

Mỗi VM:
  apisix-standalone :9080/:9443/:9091
  gitsync-routes    → release/routes → hot-reload
  gitsync-system    → release/system → admin restart
  gitsync-master    → main → docker-compose.yaml + scripts/
```

**Team APISIX không quản lý L4 LB.** Scale-out:
1. Provision VM mới, chạy `docker compose up -d`
2. Verify routing OK: `curl -H "Host: s3.hcm..." http://localhost:9080/`
3. Báo IP cho Infrastructure Team thêm vào LB pool

### 3.2 docker-compose.yaml
> File [docker-compsoe.yaml](../-/blob/main/docker--compose.yaml)

### 3.3 Tạo file .env :
```bash
cat > .env << 'EOF'
DC_PROFILE=dc1
EOF
```

### 3.4 Tạo cấu trúc thư mục 
```bash
mkdir -p /opt/apisix/standalone/sandbox
cd /opt/apisix/standalone/sandbox
mkdir -p \
  conf_routes/apisix_routes \
  conf_system/apisix_config \
  conf_system/plugins_lua \
  conf_master \
  scripts \
  logs/apisix-dc1 \
  secrets
```

### 3.5 Tạo file bootstrap (cần tồn tại trước khi doker compose up)
File secrets/.netrc:
```bash
cat > secrets/.netrc << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-xxxxxxxxxxxxxxxxxxxx
EOF
```

File [docker-compose.yaml](-/blob/main/docker-compsoe.yaml)
File [scripts/gitsync.sh](-/blob/main/scripts/gitsync.sh)

### 3.5 Phân quyền
```bash
# git-sync (UID 65533) — write vào conf_routes/, conf_system/
sudo chown -R 65533:65533 conf_routes/ conf_system/ conf_master/
sudo chmod -R 755 conf_routes/ conf_routes/apisix_routes conf_system/ conf_system/apisix_config conf_master/

# git-sync — đọc .netrc và gitsync.sh, write vào scripts/, docker-compose.yaml
sudo chown 65533:65533 secrets/.netrc && sudo chmod 600 secrets/.netrc
sudo chown -R 65533:65533 scripts/ && sudo chmod +x scripts/gitsync.sh
sudo chown 65533:65533 docker-compose.yaml

# APISIX (UID 636) — write vào logs/
sudo chown nobody:nogroup logs/
sudo chown -R 636:636 logs/
sudo chmod -R 755 logs/apisix-dc1

# SSH keys — chỉ git-sync đọc được
sudo chown -R 65533:65533 /opt/apisix/standalone/sandbox/secrets/ssh
sudo chmod 700 /opt/apisix/standalone/sandbox/secrets/ssh
sudo chmod 600 /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_*
```

### 3.6 Kiểm tra stack health

```bash
# Container status
docker ps --format "table {{.Names}}\t{{.Status}}"

# git-sync đã pull commit mới chưa
readlink conf_routes/current   # hash phải khớp GitLab
readlink conf_system/current

# File đã copy ra chưa
cat conf_routes/apisix_routes/apisix-dc1.yaml | head -3
cat conf_system/apisix_config/config-dc1.yaml | grep worker_processes

# APISIX routing OK
curl -s -H "Host: s3.hcm.sds.vnpaycloud.vn" http://localhost:9080/ | head -1

# Logs
tail -f logs/apisix-dc1/access.log
docker logs gitsync-routes --tail 5
docker logs gitsync-system --tail 5
```

> Xem troubleshoot đầy đủ tại [Section 9.2](#9-ma-trận-tổng-hợp--troubleshoot)

---

## 4. Plugin — S3 Gateway

### 4.1 Danh sách plugin trong config thực tế từ lab
> Dựa trên config thực tế từ lab: `config-dc1.yaml` và `config-dc2.yaml`  
> Phân loại theo 3 tier: **ALWAYS ON** / **ON-DEMAND** / **REMOVE**

File `config-dc1.yaml` và `config-dc2.yaml` hiện tại đang load cùng 1 danh sách 22 plugin. Đây là toàn bộ những gì cần đánh giá:

```
real-ip, client-control, proxy-control, request-id, zipkin,
prometheus, ip-restriction, ua-restriction, referer-restriction,
cors, limit-req, limit-count, limit-conn,
key-auth, jwt-auth, basic-auth, openid-connect, hmac-auth, authz-keycloak,
proxy-rewrite, redirect, response-rewrite,
grpc-transcode, fault-injection, api-breaker, traffic-split,
request-validation, ceph-rados-regex
```

```
3 nguyên tắc:

1. Plugin không load = không tốn memory, không thể bị kích hoạt nhầm
   → Bỏ hoàn toàn các plugin không bao giờ dùng cho S3

2. Plugin load nhưng không khai báo trên route = nằm trong memory, không chạy
   → Load sẵn các plugin có thể cần (on-demand) nhưng không khai báo trên route mặc định

3. Plugin khai báo trên route = chạy trên mọi request qua route đó
   → Chỉ bật mặc định những plugin thực sự cần cho mọi S3 request

S3 protocol constraint — AWS SigV4:
   Signature bao gồm: method + URI + headers + body hash
   Plugin nào modify request trước khi đến Ceph RGW → SigV4 mismatch → 403
   → ceph-rados-regex.lua đã handle đúng: chỉ rewrite URI và Host
   → Các plugin modify header/body khác cần cẩn thận
```

### 4.2 Phân loại theo S3 use case

```
LEGEND:
  ✅ LOAD — cần thiết cho S3 gateway, nên enable trong plugins list
  ⚙️  ON-DEMAND — có thể cần theo yêu cầu, enable khi cần, tắt nếu không dùng
  ❌ KHÔNG CẦN — không liên quan S3 hoặc conflict với S3 protocol, nên bỏ khỏi list
  ⚠️  CẨN THẬN — có tác động đặc biệt với S3 workload, cần đọc kỹ trước khi enable
```

| Plugin | Phân loại | Lý do | Ghi chú |
|---|---|---|---|
| `prometheus` | ✅ LOAD | Monitoring bắt buộc — metrics DP health, upstream status, request rate | collect metrics, không affect traffic. Per-route metrics: request count, latency, status code. Không modify request → an toàn với SigV4. Bỏ đi = mù hoàn toàn về S3 traffic |
| `proxy-rewrite` | ✅ LOAD | Cần thiết cho vhost→path rewrite (bucket.s3.domain → /bucket/path) | |
| `real-ip` | ✅ LOAD | Lấy client IP thật khi đứng sau LB/proxy — cần cho ip-restriction | ALWAYS ON nếu có load balancer trước APISIX. Lấy IP thật từ X-Forwarded-For hoặc X-Real-IP. Cần cho ip-restriction và logging chính xác. Nếu APISIX expose trực tiếp (không qua LB): có thể bỏ |
| `ip-restriction` | ✅ LOAD | Whitelist IP cho S3 internal tenant — security cơ bản | per tenant route. Whitelist/blacklist IP cho tenant cụ thể. Bật khi: tenant yêu cầu chỉ cho phép IP của họ truy cập |
| `ceph-rados-regex` | ✅ LOAD | Custom plugin bucket name validation — core business logic | Bucket name validation (format: tenant-bucketname). Vhost → path rewrite trước khi đến Ceph RGW. Priority 10005 — chạy đầu tiên trước mọi plugin khác. Không thể bỏ: đây là core logic phân biệt S3 request hợp lệ |
| `request-id` | ✅ LOAD | Gắn X-Request-ID cho mỗi S3 request — trace end-to-end | Gán X-Request-ID cho mọi request. Trace request qua APISIX → Ceph RGW log → debug dễ hơn. Không modify request body hay auth header → an toàn SigV4 |
| `cors` | ✅ LOAD | S3 browser client (SDK JS, MinIO console) cần CORS headers | nếu S3 được access từ browser. S3 browser-based upload (presigned URL + JavaScript) |
| `limit-req` | ⚙️ ON-DEMAND | Rate limit per tenant — enable trên route khi cần, không phải global | per tenant route. Rate limiting theo request/giây. Bật khi: tenant có nguy cơ abuse hoặc yêu cầu SLA riêng. S3 production: cần đánh giá threshold thực tế trước khi bật |
| `limit-count` | ⚙️ ON-DEMAND | Request count limit per tenant — tương tự limit-req | per tenant route. Rate limiting theo số lượng request trong time window. Dùng cùng hoặc thay thế limit-req tùy use case |
| `limit-conn` | ⚙️ ON-DEMAND | Connection limit — hữu ích cho multipart upload kiểm soát | per route. Rate limiting theo số lượng request trong time window. Dùng cùng hoặc thay thế limit-req tùy use case |
| `key-auth` | ⚙️ ON-DEMAND | Nếu cần thêm gateway-level auth ngoài AWS SigV4 của S3 | nếu cần API key layer. S3 dùng SigV4, không cần APISIX key-auth. Nếu cần thêm API key layer trước S3: bật ON-DEMAND |
| `fault-injection` | ⚙️ ON-DEMAND | Chaos testing — staging only, không bao giờ enable production | Chỉ dùng khi chaos testing. Tuyệt đối không load trên production S3. Nếu vô tình kích hoạt → inject fault vào S3 traffic thật |
| `api-breaker` | ⚙️ ON-DEMAND | Circuit breaker cho Ceph RGW — hữu ích khi Ceph unhealthy | circuit breaker. Tự động ngắt khi Ceph RGW liên tục fail. Nâng cao — cần set threshold đúng, không dùng mặc định |
| `traffic-split` | ⚙️ ON-DEMAND | Canary release khi nâng cấp Ceph RGW version | canary/migration. Split traffic giữa 2 Ceph cluster (migration use case). Không phải S3 daily operation |
| `response-rewrite` | ⚙️ ON-DEMAND | Sửa response header nếu Ceph trả về header không mong muốn | nếu cần custom response header. Chỉ modify response, không affect request → an toàn SigV4. Dùng khi: thêm CORS header, remove server info header |
| `redirect` | ⚙️ ON-DEMAND | HTTP → HTTPS redirect | ít dùng với S3. HTTP → HTTPS redirect. Thường handle ở load balancer trước APISIX |
| `client-control` | ⚙️ ON-DEMAND | Giới hạn request body size — hữu ích nếu muốn cap upload size | Giới hạn max request body size. Hữu ích khi cần cap upload size per tenant |
| `proxy-control` | ⚙️ ON-DEMAND | Kiểm soát upstream behavior | Control proxy behavior (timeout, buffer). Bật khi cần tune timeout riêng cho S3 large object |
| `request-validation` | ⚙️ ON-DEMAND | Validate request header/body — thêm lớp validation ngoài bucket regex | extra validation layer. Validate header/query string pattern. Không modify → an toàn SigV4. Bật khi cần thêm lớp kiểm tra input |
| `ua-restriction` | ❌ KHÔNG CẦN | Block user agent — S3 SDK dùng user-agent chuẩn AWS, không cần filter | User-Agent restriction — không áp dụng cho S3. AWS SDK có UA cố định, restrict dễ break client |
| `referer-restriction` | ❌ KHÔNG CẦN | Chặn theo Referer header — không áp dụng cho S3 API | Referer header — không có trong S3 SDK request. Không liên quan S3 use case |
| `jwt-auth` | ❌ KHÔNG CẦN | S3 dùng AWS SigV4, không dùng JWT | S3 dùng AWS SigV4, không dùng JWT. Load = tốn memory, không bao giờ được gọi |
| `basic-auth` | ❌ KHÔNG CẦN | S3 dùng AWS SigV4, không dùng Basic Auth | S3 dùng AWS SigV4, không dùng Basic Auth. Security risk nếu vô tình kích hoạt nhầm |
| `openid-connect` | ❌ KHÔNG CẦN | OIDC cho web app, không phải S3 API | OIDC cho API gateway B2C — không phải S3 use case. Dependency nặng (cần OIDC provider) |
| `hmac-auth` | ❌ KHÔNG CẦN | S3 đã có SigV4 (HMAC-SHA256), không cần double auth | S3 đã có SigV4 là HMAC-based auth của riêng nó. Thêm hmac-auth của APISIX = double auth không cần thiết |
| `authz-keycloak` | ❌ KHÔNG CẦN | Keycloak authz không áp dụng cho S3 API pattern | Enterprise SSO — không phải S3 use case. Nếu cần authz: handle ở application layer, không phải gateway |
| `grpc-transcode` | ❌ KHÔNG CẦN | S3 là REST/HTTP, không phải gRPC | S3 là REST/HTTP, không phải gRPC. Load = tốn memory hoàn toàn vô nghĩa|
| `zipkin` | ❌ KHÔNG CẦN | Distributed tracing — nếu có Zipkin infra thì thêm, mặc định bỏ | (dùng prometheus thay thế). Distributed tracing — over-engineered cho S3 gateway. Nếu cần tracing: OpenTelemetry qua prometheus đủ. Zipkin cần Zipkin server riêng — thêm dependency |


### 4.1 Plugin list tối ưu cho S3

```yaml
plugins:
plugins:
  # === CORE — bắt buộc load cho S3 gateway ===
  - real-ip               # client IP thật khi đứng sau LB
  - request-id            # trace ID cho mỗi S3 request
  - prometheus            # metrics monitoring
  - ip-restriction        # whitelist IP per tenant/route
  - cors                  # S3 browser SDK cần CORS
  - proxy-rewrite         # vhost → path rewrite cho Ceph
  - ceph-rados-regex      # bucket name validation (custom)

  # === ON-DEMAND — load sẵn, kích hoạt theo route khi cần ===
  - limit-req             # rate limiting per tenant
  - limit-count           # request count limiting
  - limit-conn            # connection limiting (multipart upload)
  - client-control        # request body size limit
  - proxy-control         # upstream behavior control
  - redirect              # HTTP → HTTPS redirect
  - response-rewrite      # sửa response header nếu cần
  - request-validation    # thêm lớp validation
  - api-breaker           # circuit breaker cho Ceph RGW
  - traffic-split         # canary release khi nâng cấp RGW
  - key-auth              # gateway auth nếu cần thêm lớp ngoài SigV4
  - fault-injection       # chaos testing (staging only)

  # === KHÔNG LOAD — bỏ khỏi list ===
  # - ua-restriction      # không áp dụng S3
  # - referer-restriction # không áp dụng S3
  # - jwt-auth            # S3 dùng SigV4, không dùng JWT
  # - basic-auth          # S3 dùng SigV4, không dùng Basic Auth
  # - openid-connect      # web app only, không phải S3 API
  # - hmac-auth           # S3 đã có SigV4 built-in
  # - authz-keycloak      # không áp dụng S3 pattern
  # - grpc-transcode      # S3 là REST, không phải gRPC
  # - zipkin              # chỉ thêm khi có Zipkin infra
```

> Plugin không load = không tốn memory, không thể bị kích hoạt nhầm.  
> Plugin load nhưng không khai báo trên route = load vào memory nhưng không chạy.

> 8 Tóm tắt quy hoạch plugin:

```
Load mặc định (7 plugin CORE): real-ip, request-id, prometheus, ip-restriction, cors, proxy-rewrite, ceph-rados-regex

Load sẵn, kích hoạt theo route (11 plugin ON-DEMAND): limit-req, limit-count, limit-conn, client-control, proxy-control, redirect, response-rewrite, request-validation, api-breaker, traffic-split, key-auth

Không load (bỏ khỏi plugins list): ua-restriction, referer-restriction, jwt-auth, basic-auth, openid-connect, hmac-auth, authz-keycloak, grpc-transcode, zipkin, fault-injection (production — chỉ staging)
```

> Nguyên tắc:
>   Plugin không load = không tốn memory, không thể bị kích hoạt nhầm
>   Plugin load nhưng không khai báo trên route = load vào memory nhưng không chạy
>   Plugin khai báo trên route = chạy trên mọi request qua route đó

### 4.2 Kích hoạt plugin per route

Plugin load trong `config.yaml` chỉ là **danh sách được phép load**. Plugin thực sự hoạt động phải được khai báo trong `apisix-dc1.yaml` trên từng route.
> File [apisix-dc1.yaml](../-/blob/release/routes/apisix-dc1.yaml)

```yaml
routes:
  # Route S3 path-style — production config
  - id: s3-dc1-path
    uri: /*
    host: s3.hcm.lab.thuyldx
    plugins:
      # Luôn bật
      ceph-rados-regex: {}         # bucket validation
      request-id:
        header_name: X-Request-ID
        include_in_response: true
      prometheus: {}               # per-route metrics
      # Bật theo nhu cầu tenant
      # ip-restriction:
      #   whitelist: ["10.10.0.0/16"]
      # limit-req:
      #   rate: 1000
      #   burst: 200
      #   key: remote_addr
    upstream_id: ceph-rgw-dc1

  # Route S3 vhost-style — cần proxy-rewrite để rewrite host
  - id: s3-dc1-vhost
    uri: /*
    host: "*.s3.hcm.lab.thuyldx"
    plugins:
      ceph-rados-regex: {}         # vhost → path rewrite + validation
      request-id:
        header_name: X-Request-ID
        include_in_response: true
    upstream_id: ceph-rgw-dc1
#END
```

### 4.3 Warning — Plugin ảnh hưởng S3 SigV4

S3 dùng AWS Signature V4. Bất kỳ thay đổi vào request trước khi đến Ceph → SigV4 mismatch → 403.

```
AN TOÀN (không modify request):
  limit-req, limit-count, limit-conn, ip-restriction → ✅
  response-rewrite → ✅ (chỉ sửa response)

CẨN THẬN:
  proxy-rewrite → nếu đổi Host header → SigV4 fail
  custom.ceph-rados-regex → đã handle đúng (set Host về path-style)

KHÔNG DÙNG với S3 client chuẩn:
  key-auth, jwt-auth, basic-auth → S3 SDK không gửi header tương ứng
```

Warning đặc biệt: Plugin ảnh hưởng S3 protocol
```
S3 protocol dùng AWS Signature Version 4 (SigV4):
  - Signature bao gồm: method + URI + query string + selected headers + body hash
  - Bất kỳ thay đổi nào vào request trước khi đến Ceph RGW → SigV4 mismatch → 403

Các plugin CÓ THỂ break SigV4 nếu cấu hình sai:

proxy-rewrite:
  → Thay đổi Host header → SigV4 header "Host" không match → 403
  → Rule: chỉ rewrite Host khi APISIX đồng thời không forward Authorization header
  → ceph-rados-regex.lua đã handle đúng: set Host về path-style sau khi extract bucket

response-rewrite:
  → Chỉ sửa response, không ảnh hưởng request → an toàn

request-validation:
  → Validate headers/body → không modify → an toàn nếu chỉ validate

limit-req / limit-count / limit-conn:
  → Không modify request → an toàn

ip-restriction:
  → Không modify request → an toàn

key-auth / jwt-auth / basic-auth:
  → Thêm auth layer ngoài SigV4
  → S3 SDK sẽ fail nếu cần thêm header mà SDK không gửi
  → Chỉ dùng nếu có custom S3 client hoặc proxy layer

cors:
  → Thêm response headers → an toàn cho response
  → preflight OPTIONS: Ceph RGW handle được, không cần APISIX can thiệp
```

### 4.4 Lifecycle custom plugin

```
1. Viết plugin: plugins_lua/my-plugin.lua
2. Commit vào release/system + thêm - custom.my-plugin vào config-dc1.yaml
3. gitsync-system pull về (≤30s) → gitsync.sh copy file
4. Admin: docker compose restart apisix-standalone
5. Verify: docker exec apisix-dc1 ls apisix/plugins/custom/
6. Dùng trong route: custom.my-plugin: {}
```

---

## 5. Vận hành

### 5.1 Cấu trúc thư mục production

```
/opt/apisix/standalone/sandbox/
│
├── docker-compose.yml            ← managed by gitsync-master (main branch)
├── .env                          ← DC_PROFILE=dc1 | dc2 (có trong .gitignore, KHÔNG commit)
├── .env.example
│
├── conf_routes/                  ← gitsync-routes ghi vào (release/routes)
│   ├── current -> .worktrees/    ← symlink atomic, git-sync tự quản
│   ├── .worktrees/               ← git-sync tự quản, KHÔNG touch
│   ├── .git/                     ← git-sync tự quản, KHÔNG touch
│   ├── sync.log
│   └── apisix_routes/
│       └── apisix-dc1.yaml       ← copy-hook.sh ghi ra, APISIX đọc và mount file này
│
├── conf_system/                  ← gitsync-system ghi vào (release/system)
│   ├── current -> .worktrees/
│   ├── .worktrees/
│   ├── .git/                     ← git-sync tự quản, KHÔNG touch
│   ├── sync.log
│   └── apisix_config/
│       └── config-dc1.yaml       ← copy-hook.sh ghi ra, systemd watcher theo dõi và tự động restart docker container
│
├── conf_master/                  ← gitsync-master (main branch)
│   ├── current -> .worktrees/
│   └── .worktrees/
│
├── scripts/
│   ├── compile.py                ← gộp files khi chạy CI/CD
│   └── copy-hook.sh              ← exechook wrapper, mount read-only vào git-sync
│
├── plugins/
│   └── ceph-rados-regex.lua      ← deploy thủ công, restart khi thay đổi
│
├── logs/
│   └── apisix-dc1/            ← 1 log dir per VM
│
└── secrets/
    └── .netrc                    ← GitLab HTTPS auth (có trong .gitignore, KHÔNG commit), chmod 600
```

**Phân quyền bắt buộc: [xem tại mục ](#35-phân-quyền)**

### 5.2 Volume mount — pitfall #1 (confirmed TC-00-7)

```
APISIX_PROFILE=dc1 → tìm đúng tên:
  /usr/local/apisix/conf/config-dc1.yaml    ← BẮT BUỘC
  /usr/local/apisix/conf/apisix-dc1.yaml    ← BẮT BUỘC

Mount sai tên → crash loop:
  config.yaml → /conf/config.yaml           ← SAI
  Error: "failed to open file: config-dc1.yaml: No such file or directory"
```

### 5.3 Hot-reload — inode pitfall (confirmed TC-00-7 B10)

APISIX watch file theo **mtime của inode**. Nếu tạo inode mới → không detect:

| Cách ghi | Inode | Hot-reload |
|---|---|---|
| `cp`, `scp`, `python3` write in-place | Giữ | ✅ OK |
| `nano`, `vim` | Giữ | ✅ OK |
| `cat >>`, `tee`, `sed -i` | **Mới** | ❌ Không reload |

> `gitsync.sh` dùng `cp` → giữ inode → hot-reload OK tự động.

**Verify sau deploy:**
```bash
docker logs apisix-dc1 --since 10s | grep -E "reloaded|error"
# OK:    "config file apisix-dc1.yaml reloaded."
# FAIL:  "missing valid end flag" → file lỗi, config cũ vẫn giữ
# FATAL: "failed to open file" → volume mount sai tên
```

### 5.4 Khi nào restart, khi nào hot-reload

```
Chỉ hot-reload (không cần restart):
  - Thêm/sửa/xóa route, upstream, ssl trong apisix-{DC_PROFILE}.yaml

Cần docker restart:
  - Thay đổi config-{profile}.yaml (worker_processes, plugin list)
  - Thêm/sửa custom Lua plugin (*.lua)
  - Thay đổi APISIX_PROFILE hoặc upgrade image

FATAL — không restart khi đang có file lỗi:
  File lỗi + hot-reload → config cũ giữ (traffic OK) ✅
  File lỗi + restart → APISIX startup fail → crash loop ❌
```

### 5.5 Upstream — inline vs upstream_id

```yaml
# SAI: upstream_id reference file khác
routes:
  - upstream_id: hcm-rgw   # ← fail nếu upstream không trong cùng file

# ĐÚNG: khai báo upstreams array + reference trong cùng file
upstreams:
  - id: hcm-rgw
    type: roundrobin
    nodes:
      - host: 172.25.216.241
        port: 3950
        weight: 1
routes:
  - upstream_id: hcm-rgw   # ← OK khi cùng file
```

### 5.6 Rollback khẩn cấp

```bash
# git-sync giữ lịch sử revision trong .worktrees/
# Rollback = git revert trên GitLab → git-sync tự pull về trong ≤30s

# Nếu cần rollback thủ công ngay lập tức:
# Xem các revision cũ
ls conf_routes/.worktrees/

# Copy từ revision cũ (giữ inode → hot-reload tự động)
cp conf_routes/.worktrees/<old-hash>/apisix-dc1.yaml \
   conf_routes/apisix_routes/apisix-dc1.yaml
```

---

## 6. Bảo mật

### 6.1 Admin API disabled

```bash
curl -sv http://localhost:9180/apisix/admin/routes 2>&1 | head -3
# Expected: "Connection reset by peer"
# Port 9180 không listen → attack surface không tồn tại
# Mọi config change bắt buộc qua file + SSH access
```

### 6.2 Custom plugin — bucket validation

Plugin `ceph-rados-regex` chạy ở phase `rewrite` (priority 10005), validate bucket name trước khi request đến Ceph RGW. Kế thừa logic từ `cloudian-regex.lua` đang dùng trên NGINX:


```lua
local function is_valid_bucket(bucket)
    return string.match(bucket, "^%w+-[%w-]*%w+$") ~= nil
end
-- Vhost: bucket.s3.domain → extract bucket, rewrite URI
-- Path:  s3.domain/bucket → validate, pass through
-- Reject (HTTP 400): bucket name không match pattern
```

**Mount vào `plugins/custom/` — tách biệt với built-in:**
```yaml
volumes:
  - ./conf_system/plugins_lua:/usr/local/apisix/apisix/plugins/custom:ro
```
Khai báo trong config: `- custom.ceph-rados-regex`

### 6.3 SSL/TLS

```yaml
ssls:
  - id: wildcard-hcm
    cert: ${{SSL_CERT_HCM}}    # env var, không hardcode vào Git
    key: ${{SSL_KEY_HCM}}
    snis:
      - "*.s3.hcm.sds.vnpaycloud.vn"
```

### 6.4 Phân biệt 2 loại 404 (confirmed TC-00-7)

```
APISIX 404 → JSON:  {"error_msg":"404 Route Not Found"}
  Tầng: GATEWAY — Host header sai, route không tồn tại ở DC này
  Debug: kiểm tra Host header, profile, route config

Ceph 404 → XML:  <Error><Code>NoSuchBucket</Code></Error>
  Tầng: STORAGE — route đúng, bucket chưa tạo hoặc sai zone
  Debug: kiểm tra bucket, credentials, zone

Rule: nhìn Content-Type + body format trước khi vào log.
```

---

## 7. Hiệu năng & Resilience

### 7.1 Worker config

```yaml
# config-dc1.yaml
nginx_config:
  worker_processes: 2          # DC1: match số CPU core
  worker_rlimit_nofile: 65536  # = worker_connections × 2
  event:
    worker_connections: 16384  # 2 × 16384 = 32768 concurrent/container
http:
  client_max_body_size: 0      # unlimited — Ceph/Cloudian tự giới hạn
  keepalive_timeout: 60
  client_header_timeout: 150s
  client_body_timeout: 100s
  send_timeout: 300s
```

**Verify:**
```bash
docker exec apisix-dc1 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes
# DC1: worker_processes 2;   DC2: worker_processes 1;
```

### 7.2 Upstream Active/Passive với health check

```yaml
upstreams:
  - id: ceph-rgw-dc1
    type: roundrobin
    nodes:
      - host: 172.25.216.241
        port: 3950
        weight: 1
        priority: 1    # Active
      - host: 172.25.216.186
        port: 3950
        weight: 1
        priority: 0    # Passive — chỉ nhận khi Active down
    checks:
      active:
        type: http
        http_path: /
        healthy:
          interval: 5
          successes: 2
        unhealthy:
          interval: 5
          http_failures: 3   # ~15s detect
```

### 7.3 Resilience so với Traditional mode

```
Standalone failure scenarios:
  File lỗi khi hot-reload  → config cũ giữ nguyên ✅ (traffic OK)
  File lỗi + restart       → crash loop ← FATAL (phải validate trước)
  DC1 die                  → DC2 độc lập, không bị ảnh hưởng ✅
  Git server die           → traffic OK, chỉ không deploy được ✅

Traditional mode (GD0/GD1) so sánh:
  etcd die + DP restart    → DP không load config ← FATAL (TC-05-9)
  DC1 die                  → etcd lose quorum → CP1+CP2 vô dụng
```

**Emergency recovery:**
```bash
# Tìm revision tốt gần nhất
ls conf_routes/.worktrees/

# Restore (giữ inode → hot-reload tự động)
cp conf_routes/.worktrees/<good-hash>/apisix-dc1.yaml \
   conf_routes/apisix_routes/apisix-dc1.yaml

# Verify
sleep 5
docker logs apisix-dc1 --since 10s | grep reloaded
curl -s -H "Host: s3.hcm.sds.vnpaycloud.vn" http://localhost:9080/
```

---

## 8. Observability

### 8.1 Prometheus metrics

```yaml
# config-{profile}.yaml
plugins:
  - prometheus

plugin_attr:
  prometheus:
    export_addr:
      ip: "0.0.0.0"
      port: 9091
    export_uri: /apisix/prometheus/metrics
```

**Alert rules cho S3:**

```yaml
groups:
  - name: apisix-standalone-s3
    rules:
      - alert: APISIX_S3_HighErrorRate
        expr: |
          rate(apisix_http_status{status=~"5.."}[5m])
          / rate(apisix_http_status[5m]) > 0.01
        for: 2m

      - alert: APISIX_UpstreamUnhealthy
        expr: apisix_upstream_status{status="unhealthy"} == 1
        for: 30s
        annotations:
          summary: "Ceph RGW {{ $labels.name }} unhealthy"

      - alert: APISIX_ConfigReloadFailed
        expr: time() - apisix_config_reload_success_timestamp > 300
        for: 1m
        annotations:
          summary: "apisix-{profile}.yaml chưa reload trong 5 phút"

      - alert: APISIX_ProcessDown
        expr: up{job="apisix"} == 0
        for: 30s
```

### 8.2 Verify DC isolation

```bash
# Worker config đúng per DC
docker exec apisix-dc1 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes
docker exec apisix-dc2 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes

# Service isolation đúng
curl -s -H "Host: s3.hcm.sds.vnpaycloud.vn" http://DC1:9080/
# Expected: 200 XML (Ceph response)

curl -s -H "Host: api.ekyc.domain.vn" http://DC2:9080/ekyc/
# Expected: {"error_msg":"404 Route Not Found"}  ← APISIX 404 (DC2 không có route này)
```

---

## 9. Ma trận tổng hợp & Troubleshoot

### 9.1 Ma trận vấn đề → giải pháp

| Vấn đề | Loại | Giải pháp | Cơ chế | Ghi chú Lab|
|---|---|---|---|
| Không audit trail | GitOps | git log / PR history | — |
| Config drift 2 DC | GitOps + Profile | CI enforce + APISIX_PROFILE | Confirmed TC-00-7 #2 |
| Rollback chậm | git-sync | git revert → tự detect ≤30s | Revision cũ trong .worktrees/ |
| Không dry-run | CI/CD gate | yamllint + compile + apisix test | Bắt buộc trước merge |
| Scale-out config drift | git-sync | Mỗi VM tự pull từ cùng branch | Zero-config |
| File lớn khó review | Fragment-based | fragments/ per service/tenant | compile.py merge |
| Inbound firewall | git-sync pull | VM outbound → GitLab | Không mở port |
| Config khác per DC | Profile | `APISIX_PROFILE=dc{X}` | Confirmed TC-00-7 #1,#2 |
| Plugin list khác per DC | release/system | config-dc1 vs config-dc2 | Platform Team |
| Staging vs Production | Profile | `APISIX_PROFILE=dc1-staging` | — |
| File lỗi + restart = crash | CI gate + monitor | Validate trước merge | FATAL scenario |
| inode pitfall khi edit | gitsync.sh dùng `cp` | Giữ inode → hot-reload OK | Confirmed TC-00-7 #5 |
| 2 loại 404 khó phân biệt | — | JSON = APISIX, XML = Ceph | Confirmed TC-00-7 #4 |
| Không có audit trail | Governance | GitOps | git log / PR history | TC-00-7: manual change không traceable |
| Config drift 2 DC | Consistency | GitOps | CI/CD pipeline enforce | TC-00-7: missed update dễ xảy ra |
| Rollback thủ công chậm | Operations | GitOps (git-sync) | git revert + poll detect / cp từ revision cũ | TC-00-7 B10: manual fix tốn thời gian |
| Không có dry-run | Safety | GitOps | CI validate: yamllint + compile + apisix test | TC-00-7: file lỗi cần test trước |
| Scale-out không đồng bộ config | Scalability | git-sync shared mount | Tất cả instance mount chung `conf_routes/` → tự đồng bộ | S3 traffic spike |
| File lớn khó review | Maintainability | GitOps | Fragment-based source per team | — |
| Inbound firewall block GitLab→VM | Network | git-sync (Pull) | VM chủ động poll GitLab — không mở inbound port | Môi trường DC internal |
| DC1/DC2 service khác nhau | Config | Profile | `APISIX_PROFILE` per DC | TC-00-7 finding #3: isolation confirmed |
| Deployment config khác per DC | Config | Profile | `config-{profile}.yaml` | TC-00-7 finding #2: worker_processes |
| Plugin list khác per DC | Config | Profile | `release/system` branch riêng | TC-00-7 B2-B3: plugins per DC |
| Staging vs Production | Environment | Profile | `APISIX_PROFILE=dc1-staging` | — |
| Separation infra vs service | Architecture | Profile + Dual-branch | `release/routes` vs `release/system` | TC-00-7 finding #7: verified |
| File lỗi + restart = crash | FATAL | GitOps + CI gate | Validate trước merge + APISIX auto-reject khi hot-reload | TC-00-7 B10: #END missing scenario |
| Volume mount sai tên | Pitfall | Naming convention | File name = profile suffix | TC-00-7 finding #1: crash loop |
| inode pitfall khi edit | Pitfall | GitOps (git-sync exechook) | exechook dùng `cp` giữ inode → hot-reload OK | TC-00-7 finding #5: confirmed |
| 2 loại 404 khó phân biệt | Troubleshoot | — | JSON = APISIX, XML = Ceph | TC-00-7 finding #4: confirmed |

### 9.2 Nguyên tắc tổng quát

```
Standalone + Profile + GitOps (git-sync): 3 tầng độc lập, bổ sung cho nhau

Standalone (APISIX runtime):
  -> Loại bỏ etcd = loại bỏ SPOF tầng storage
  -> Config trong file local = resilient khi external dependency die
  -> Hot-reload = zero downtime config update (apisix-{profile}.yaml)
  -> Admin API disabled = attack surface nhỏ

Profile (config identity):
  -> Giải quyết: config khác nhau per DC/environment
  -> "APISIX_PROFILE=dc1 đọc file nào?"
  -> Native feature của APISIX, không cần tool bên ngoài

GitOps / git-sync Dual-branch (change delivery):
  -> Giải quyết: quá trình thay đổi config (who, when, what, why)
  -> "File đó đến từ đâu và được thay đổi như thế nào?"
  -> release/routes  → hot-reload  → Service Team tự chủ
  -> release/system  → hard-restart → Platform Team kiểm soát chặt
  -> Pull-only = không mở inbound port = phù hợp DC internal firewall
  -> Shared mount = scale-out zero-config: thêm instance → tự nhận config
  -> DC1 và DC2 hoàn toàn độc lập, không có deploy order
  -> Audit trail, consistency enforcement, emergency rollback từ revision cũ

Kết hợp:
  Profile định nghĩa       "đọc file nào"
  git-sync dual-branch định nghĩa "file đó đến từ đâu và ai được thay đổi"
  Standalone định nghĩa    "khi file thay đổi thì làm gì"
  -> Không overlap, không conflict, bổ sung hoàn toàn
```

### 9.3 Troubleshoot

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| `fork/exec /tmp/gitsync.sh: no such file or directory` | Mount source là directory | `rm -rf scripts/gitsync.sh && cat > scripts/gitsync.sh` |
| `fork/exec /tmp/gitsync.sh: permission denied` | Thiếu execute bit | `chmod +x scripts/gitsync.sh && chown 65533:65533 scripts/gitsync.sh` |
| `/bin/sh: 0: cannot open X: No such file` | Shebang sai — có text sau `/bin/sh` | Sửa thành `#!/bin/sh` không có gì theo sau |
| `couldn't find remote ref master` | Branch tên `master` không tồn tại | Đổi `GITSYNC_REF: "main"` |
| `cp: cannot create: Permission denied` | File đích chưa chown 65533 | `sudo chown 65533:65533 <file>` |
| `413 Request Entity Too Large` | `client_max_body_size` nhỏ | Set `client_max_body_size: 0` |
| `Is a directory` khi load plugin | Docker tạo dir thay vì file | `rm -rf <file>; touch <file>; docker compose down && up` |
| `HTTP Basic: Access denied` | `.netrc` sai format | Mount `.netrc` vào `/tmp/.netrc` |
| Container crash loop | Volume mount sai tên file | Kiểm tra tên file khớp `APISIX_PROFILE` |
| exechook OK thủ công nhưng auto fail | File đích owner là `root` | `sudo chown 65533:65533 conf_*/apisix_*/` |
| APISIX không hot-reload dù file đã thay đổi | exechook fail → file không được copy | `docker logs gitsync-routes --tail 20 \| grep "hook failed"` |
| `missing valid end flag` | File thiếu `#END` hoặc YAML lỗi | Fix file → hot-reload tự động, KHÔNG restart |
| `failed to open file: config-dc1.yaml` | Volume mount sai tên | Tên file phải có profile suffix `-dc1` |
| git-sync pull xong nhưng APISIX chưa nhận | exechook không chạy được | Check `docker logs gitsync-routes` |
| `fork/exec /bin/cp: no such file or directory` | git-sync exec không qua shell, space trong args bị parse sai | Dùng wrapper script `copy-hook.sh` |
| `Is a directory` khi load plugin | Docker tạo directory thay vì file khi mount target chưa tồn tại trên host | `rm -rf plugins/ceph-rados-regex.lua && cp file.lua plugins/` rồi `docker compose down && up` |
| `413 Request Entity Too Large` | `client_max_body_size: 10m` quá nhỏ cho S3 upload | Set `client_max_body_size: 0` trong `config-dc1.yaml` |
| git-sync `HTTP Basic: Access denied` | `GITSYNC_GIT_CONFIG: credential.helper=store` sai format | Xóa dòng đó, mount `.netrc` vào `/tmp/.netrc` |
| HAProxy socket `Permission denied` | `haproxy/run/` chưa chown cho HAProxy UID 99 | `sudo chown -R 99:99 haproxy/run/` |
| APISIX không hot-reload dù file đã thay đổi | exechook fail → file không được copy ra | Check `docker logs gitsync-routes`, fix exechook |
| exechook copy thủ công OK nhưng tự động fail | Permission: file đích owner là `root` | `sudo chown 65533:65533 conf_*/apisix_*/` |
|current khớp nhưng git-sync chưa update được|git-sync lỗi hoặc down| `docker exec gitsync-{system/routes} /bin/cp /tmp/sync/current/{config/apisix}-{PROFILE}.yaml /tmp/sync/apisix_{config/routes}/{config/apisix}-{PROFILE}}.yaml && echo "OK"`|
| `fork/exec /tmp/gitsync.sh: no such file or directory` | Mount source là directory thay vì file | `rm -rf scripts/gitsync.sh && cat > scripts/gitsync.sh` |
| `fork/exec /tmp/gitsync.sh: permission denied` | Thiếu execute bit hoặc sai owner | `chmod +x scripts/gitsync.sh && chown 65533:65533 scripts/gitsync.sh` |
| `/bin/sh: 0: cannot open X: No such file` | Shebang sai — có argument sau `/bin/sh` | Sửa thành `#!/bin/sh` không có gì theo sau |
| `couldn't find remote ref master` | Branch tên `master` không tồn tại | Đổi `GITSYNC_REF: "main"` |
| `cp: cannot create regular file: Permission denied` | File đích chưa chown 65533 | `sudo chown 65533:65533 <file>` |
| `413 Request Entity Too Large` | `client_max_body_size` quá nhỏ | Set `client_max_body_size: 0` |
| `Is a directory` khi load plugin | Docker tạo dir thay vì file khi mount | `rm -rf <file>; touch <file>; docker compose down && up` |
| `HTTP Basic: Access denied` | `.netrc` sai format hoặc sai path | Mount `.netrc` vào `/tmp/.netrc` |
| exechook copy thủ công OK nhưng auto fail | File đích owner là `root` | `sudo chown 65533:65533 conf_*/apisix_*/` |
| git-sync pull xong nhưng APISIX chưa reload | exechook fail → file không được copy | `docker logs gitsync-routes --tail 20` |

---

*Document version: 9.0*  
*APISIX version: 3.15.0-debian*  
*Cập nhật khi: upgrade APISIX, thêm DC mới, thêm service, findings từ TC mới*