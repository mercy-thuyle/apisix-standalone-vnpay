# APISIX Standalone — Best Practices

> **Phạm vi:** APISIX Standalone (`config_provider: yaml/json`) cho S3 gateway 2 DC  
> **Không áp dụng cho:** Traditional mode (etcd) hoặc Decoupled mode  
> **Nguồn:** Lab findings GD0 (TC-00-1 → TC-00-7), GD1 (TC-01-x), GD2 (TC-02-x)  
> **Version:** APISIX 3.15.0-debian  
> **Document version:** 6.0 — GitOps hoàn chỉnh: gitsync.sh wrapper + 3-branch strategy (main/release/routes/release/system) + custom plugin path (plugins/custom/) + docker-compose managed by git-sync

---

## Mục lục

1. [Tổng quan mô hình](#1-tổng-quan-mô-hình)
2. [Best Practices theo góc độ vận hành](#2-best-practices-theo-góc-độ-vận-hành)
3. [Best Practices theo góc độ bảo mật](#3-best-practices-theo-góc-độ-bảo-mật)
4. [Best Practices theo góc độ hiệu năng](#4-best-practices-theo-góc-độ-hiệu-năng)
5. [Best Practices theo góc độ observability](#5-best-practices-theo-góc-độ-observability)
6. [Best Practices theo góc độ resilience](#6-best-practices-theo-góc-độ-resilience)
7. [Yếu điểm Standalone → GitOps cải thiện](#7-yếu-điểm-standalone--gitops-cải-thiện)
8. [Yếu điểm Standalone → Profile cải thiện](#8-yếu-điểm-standalone--profile-cải-thiện)
9. [TC-00-7 Lab Findings — Confirmed Behaviors](#9-tc-00-7-lab-findings--confirmed-behaviors)
10. [Ma trận tổng hợp](#10-ma-trận-tổng-hợp)
11. [GitOps — git-sync Pull-based (Dual-branch)](#11-gitops--git-sync-pull-based-dual-branch)
12. [GitOps — 3-Branch Strategy + gitsync.sh](#14-gitops--3-branch-strategy--gitsyncsh)
13. [Plugin List — Quy hoạch cho S3 Gateway](#12-plugin-list--quy-hoạch-cho-s3-gateway)
14. [Production Deployment — Docker Compose + HAProxy](#13-production-deployment--docker-compose--haproxy)

---

## 1. Tổng quan mô hình

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
  - S3 gateway (low config change frequency)
  - Use case "set and forget" sau khi setup
  - Multi-DC với config khác biệt per DC (confirmed TC-00-7)
  - Không muốn quản lý etcd Raft cluster
```

---

## 2. Best Practices theo góc độ vận hành

### 2.1 Cấu trúc thư mục — confirmed từ TC-00-7

**Cấu trúc đã lab verified:**

```
/opt/apisix/standalone/sandbox/        <- working dir (TC-00-7 dùng ~/profile/)
├── apisix_conf/
│   ├── config-dc1.yaml             <- DC-level: worker_processes=2, plugin list
│   ├── config-dc2.yaml             <- DC-level: worker_processes=1, plugin list
│   ├── apisix-dc1.yaml             <- service: S3 HCM + eKYC routes + upstreams
│   └── apisix-dc2.yaml             <- service: S3 HNI only, không có eKYC
└── logs/
    └── apisix/                     <- chown 636:636, chmod 755 bắt buộc
│       ├── access.log
│       └── error.log
```

**Cấu trúc production Node (DC1 và DC2 giống nhau hoàn toàn, chỉ khác nội dung .env):**
> DC2 giống hệt. Chỉ khác .env (DC_PROFILE=dc2) và file được exechook copy ra là [apisix-dc2.yaml](../-/blob/release/routes/apisix-dc2.yaml) / [config-dc2.yaml](../-/blob/release/system/config-dc2.yaml).

**Permission setup bắt buộc** (từ TC-00-1, TC-00-6, TC-00-7):

```bash
# git-sync (UID 65533) cần write vào conf_routes/ và conf_system/
mkdir -p ~/profile/apisix_conf ~/profile/logs/apisix

# logs — parent dir
sudo chown -R nobody:nogroup ~/profile/logs/
sudo chmod -R 755 ~/profile/logs/apisix/

# APISIX (UID 636) cần write vào từng log dir (uid=636 = apisix user trong container)
sudo chown -R 636:636 ~/profile/logs/apisix/   # uid=636 = apisix user trong container
```

**Tạo .netrc** :
```bash
cat > secrets/.netrc << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-xxxxxxxxxxxxxxxxxxxx
EOF
sudo chown 65533:65533 secrets/.netrc
sudo chmod 600 secrets/.netrc
```

**Tạo .env** :
```bash
cat > .env << 'EOF'
DC_PROFILE=dc1
EOF
```

> **Pitfall:** Container chạy `uid=636(apisix)`. Thư mục logs owned bởi `ubuntu`
> → container crash loop với error: `"Permission denied on error.log"`
> **Fix:** `sudo chown -R 636:636 ~/apisix/logs/apisix/ && sudo rm -f ~/apisix/logs/apisix/*.log`

### 2.2 Hai loại file — hai vòng đời khác nhau

**Confirmed từ TC-00-7 — tách biệt rõ ràng:**

| File | Nội dung | Reload | Owner | Thay đổi khi nào |
|---|---|---|---|---|
| `config-{profile}.yaml` | chỉ chứa deployment config (ports, worker count, worker_processes, plugin list, Prometheus bind, ulimits) | cần `docker restart` để apply| Platform team | Rất hiếm — scale hoặc thêm plugin |
| `apisix-{profile}.yaml` | chứa toàn bộ routes, upstreams, ssl, consumers | Hot-reload mỗi 1s khi mtime thay đổi | Service team | Thêm tenant, sửa upstream Ceph |

> File [config-dc1.yaml](../-/blob/release/system/config-dc1.yaml)
> File [config-dc2.yaml](../-/blob/release/system/config-dc2.yaml)

```yaml
# config-dc1.yaml — DC1 (từ TC-00-7 bước B2)
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
nginx_config:
  worker_processes: 2           # DC1: 2 core — verified TC-00-7
  worker_rlimit_nofile: 65536
  event:
    worker_connections: 16384
plugins:
  - prometheus
  - proxy-rewrite
  - ip-restriction
  - limit-req
  - limit-count

# config-dc2.yaml — DC2 (từ TC-00-7 bước B3)
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
nginx_config:
  worker_processes: 1           # DC2: 1 core — verified TC-00-7
  worker_rlimit_nofile: 32768
  event:
    worker_connections: 8192
plugins:
  - prometheus
  - proxy-rewrite
  - ip-restriction
  # limit-req, limit-count: không có ở DC2 — DC-level plugin isolation
```

### 2.3 Hot-reload — inode pitfall (confirmed TC-00-6, TC-00-7)

APISIX watch file theo **mtime** của inode. Kết quả thực tế từ lab:

| Cách ghi file | Inode | Container detect | Kết quả |
|---|---|---|---|
| `nano`, `vim` trực tiếp trên host | Giữ nguyên | ✅ Ngay lập tức | Hot-reload OK |
| `cp new.yaml apisix-dc1.yaml` | Giữ nguyên | ✅ Ngay lập tức | Hot-reload OK |
| `scp remote:file ./apisix-dc1.yaml` | Giữ nguyên | ✅ Ngay lập tức | Hot-reload OK |
| `python3` write in-place | Giữ nguyên | ✅ Ngay lập tức | Hot-reload OK |
| `cat >> apisix-dc1.yaml` | **Mới** | ❌ Không thấy | **Không reload** |
| `tee apisix-dc1.yaml < file` | **Mới** | ❌ Không thấy | **Không reload** |
| `sed -i` | **Mới** | ❌ Không thấy | ❌ **Không reload** |

**Lab log TC-00-7 bước B10:**
```
# cat >> (SAI) -> inode mới -> APISIX không detect:
[error] config file apisix-dc1.yaml: missing valid end flag

# python3 replace (ĐÚNG) -> inode giữ -> APISIX detect:
[info] config file apisix-dc1.yaml reloaded.
```

**Rule:** Luôn verify sau deploy:
```bash
docker logs apisix --since 5s 2>&1 | grep -E "reloaded|error|warn"
# Expected: "config file apisix-dc1.yaml reloaded."
# Alert nếu thấy: "missing valid end flag" -> file bị lỗi
```

### 2.4 Startup dependency

```
APISIX standalone khởi động:
  1. Đọc config-{profile}.yaml (một lần, không hot-reload)
  2. Đọc apisix-{profile}.yaml → load config vào nginx worker memory
  3. Bắt đầu serve traffic
  4. Timer 1s: watch mtime apisix-{profile}.yaml

Nếu apisix-{profile}.yaml bị lỗi syntax lúc startup:
  → APISIX không start được (không có config nào trong memory)
  → Container exit với log: "failed to parse the content of file"

Nếu apisix-{profile}.yaml bị lỗi syntax lúc hot-reload:
  → APISIX log error → GIỮ NGUYÊN config cũ trong memory ✅
  → Traffic không bị ảnh hưởng

Khi nào cần docker restart (không chỉ hot-reload):
  - Thay đổi config-{profile}.yaml (ports, worker count, plugin list)
  - Thêm/sửa custom Lua plugin (*.lua files)
  - Thay đổi APISIX_PROFILE
  - Upgrade APISIX image version

Khi nào chỉ cần hot-reload (không cần restart):
  - Thêm/sửa/xóa route trong apisix-{profile}.yaml
  - Thêm/sửa upstream nodes
  - Thay đổi plugin config trên route
  - Thêm/xóa SSL certificate
```

**Best practice:** Validate file trước khi deploy. Không bao giờ deploy file chưa qua lint lên production.

### 2.4 Backup trước khi thay đổi - trước khi sử dụng gitops

```bash
# Trước mỗi lần deploy, backup config hiện tại
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
cp ~/opt/apisix/standalone/sandbox/apisix_conf/apisix-dc1.yaml \
  ~/opt/apisix/standalone/sandbox/apisix_conf/profile/apisix-dc1.yaml.bak-${TIMESTAMP}

# Giữ 5 bản gần nhất
ls -t ~/opt/apisix/standalone/sandbox/apisix_conf/apisix-dc1.yaml.bak-* | \
  tail -n +6 | xargs rm -f
```

### 2.5 Volume mount — pitfall quan trọng nhất khi dùng Profile

**Confirmed từ TC-00-7 key finding #1:**

```
APISIX_PROFILE=dc1 -> tìm đúng tên file:
  /usr/local/apisix/conf/config-dc1.yaml    <- BẮT BUỘC
  /usr/local/apisix/conf/apisix-dc1.yaml    <- BẮT BUỘC

Mount sai tên -> crash loop:
  Mount config.yaml -> /conf/config.yaml     <- SAI (không có profile suffix)
  Error: "failed to open file: config-dc1.yaml: No such file or directory"
  -> Container exit -> restart loop liên tục
```

**docker-compose.yml đúng cho Profile:**

```yaml
# docker-compose.yml — DC1
services:
  apisix:
    image: apache/apisix:3.15.0-debian
    container_name: apisix-profile-dc1
    environment:
      - APISIX_PROFILE=dc1              # cố định per DC, không thay đổi runtime
    volumes:
      # Tên file PHẢI khớp với profile suffix
      - ./apisix_conf/config-dc1.yaml:/usr/local/apisix/conf/config-dc1.yaml:ro
      - ./apisix_conf/apisix-dc1.yaml:/usr/local/apisix/conf/apisix-dc1.yaml
      # Custom Lua plugin — mount riêng, read-only
      - ./plugins/ceph-rados-regex.lua:/usr/local/apisix/apisix/plugins/ceph-rados-regex.lua:ro
      - ./logs/apisix:/usr/local/apisix/logs
    ports:
      - "9080:9080"
      - "9443:9443"
      - "9091:9091"   # Prometheus
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf",
             "-H", "Host: s3.hcm.sds.vnpaycloud.vn",
             "http://localhost:9080/"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
```

**Tại sao mount thư mục tốt hơn mount file đơn với Profile:**

```
Mount thư mục (recommended với Profile):
  - ./apisix_conf:/usr/local/apisix/conf
  - Container thấy tất cả file trong thư mục
  - APISIX_PROFILE=dc1 -> chỉ đọc config-dc1.yaml + apisix-dc1.yaml
  - File dc2 tồn tại nhưng không được đọc (không ảnh hưởng)
  - CI/CD chỉ cần scp thư mục một lần cho cả 2 file

Mount file đơn (dùng cho non-profile, TC-00-6):
  - Inode match hoàn toàn -> hot-reload reliable nhất
  - Nhưng với Profile: phải khai báo 2 dòng volumes riêng trong docker-compose
```

### 2.6 Inline upstream vs upstream_id reference

**Pitfall từ TC-00-6:**

```yaml
# SAI — upstream_id standalone reference KHÔNG work
routes:
  - id: s3-dc1-path
    uri: /*
    upstream_id: hcm-rgw-upstream    # <- fail nếu upstream không trong cùng file

# ĐÚNG option 1 — inline upstream trong route
routes:
  - id: s3-dc1-path
    uri: /*
    upstream:
      type: roundrobin
      nodes:
        - host: 172.25.216.241
          port: 3950
          weight: 1
          priority: 1

# ĐÚNG option 2 — upstreams array + upstream_id reference trong cùng file
upstreams:
  - id: hcm-rgw-upstream
    type: roundrobin
    nodes:
      - host: 172.25.216.241
        port: 3950
        weight: 1
        priority: 1

routes:
  - id: s3-dc1-path
    uri: /*
    upstream_id: hcm-rgw-upstream    # <- OK khi upstream khai báo trong cùng file
#END
```

### 2.7 Startup vs hot-reload behavior

```
Lỗi lúc STARTUP:
  -> APISIX không start được -> container exit
  -> Khác với lỗi lúc hot-reload

Lỗi lúc HOT-RELOAD:
  -> APISIX log error -> GIỮ NGUYÊN config cũ -> traffic OK
  -> confirmed TC-00-7 B10: cat >> -> missing #END -> config cũ giữ nguyên

FATAL scenario (xem Section 6.2):
  File lỗi -> hot-reload reject (traffic OK)
  -> ai đó restart container không biết có lỗi
  -> APISIX startup với file lỗi -> FAIL TO START -> crash loop
```

---

## 3. Best Practices theo góc độ bảo mật

### 3.1 Admin API disabled — xác nhận thực tế

**Confirmed từ TC-00-6, TC-00-7:**

```bash
curl -sv http://localhost:9180/apisix/admin/routes 2>&1 | head -5
# Expected: Connection reset by peer
# Không phải 404 — là connection reset hoàn toàn
# Port APISIX (9180) không listen -> attack surface KHÔNG tồn tại
```

Mọi config change bắt buộc qua file. Không thể thay đổi config bằng curl API mà không có SSH access vào host.


### 3.2 Custom plugin bucket validation

Plugin `ceph-rados-regex` chạy ở phase `rewrite` (priority 10005), validate bucket name trước khi request đến Ceph RGW. Kế thừa logic từ `cloudian-regex.lua` đang dùng trên NGINX:

```lua
-- Migrate từ cloudian-regex.lua sang APISIX plugin
-- Logic giữ nguyên, wrap vào APISIX plugin structure

local function is_valid_bucket(bucket)
    -- Bucket phải có dạng: tenant-bucketname (ít nhất 1 dấu gạch ngang)
    return string.match(bucket, "^%w+-[%w-]*%w+$") ~= nil
end

local function is_bucket_in_path(uri)
    return string.match(uri, "^/%w+-[%w-]*%w+/?$") ~= nil
        or string.match(uri, "^/%w+-[%w-]*%w+/.+$") ~= nil
end

-- Vhost: bucket.s3.domain.vn -> extract bucket, rewrite URI cho Rados
-- Path:  s3.domain.vn/bucket -> validate bucket prefix
```

**Mount plugin read-only:**
```yaml
volumes:
  - ./plugins/ceph-rados-regex.lua:/usr/local/apisix/apisix/plugins/ceph-rados-regex.lua:ro
```

> Thay đổi plugin code cần `docker restart` (không hot-reload)

### 3.3 SSL/TLS — không hardcode private key trong Git

```yaml
# apisix-dc1.yaml
ssls:
  - id: wildcard-hcm
    cert: ${{SSL_CERT_HCM}}    # env var, không commit key vào Git
    key: ${{SSL_KEY_HCM}}
    snis:
      - "*.s3.hcm.sds.vnpaycloud.vn"
      - "s3.hcm.sds.vnpaycloud.vn"
#END
```

### 3.4 Phân biệt 2 loại 404 — confirmed TC-00-7 key finding #4

**Nhìn body response TRƯỚC khi vào log:**

```
APISIX 404 -> JSON body:
  {"error_msg":"404 Route Not Found"}
  Tầng: GATEWAY — không có route match
  Debug: Host header sai, URI sai, profile sai, route không có ở DC này

Ceph 404 -> XML body:
  <?xml version="1.0"?>
  <Error><Code>NoSuchBucket</Code>...</Error>
  Tầng: STORAGE — route đúng, bucket không tồn tại
  Debug: bucket chưa tạo, bucket name sai, wrong zone

Rule: Content-Type + body format -> phân loại trong 5 giây
  -> Tiết kiệm 5-10 phút debug mỗi incident
```

---

## 4. Best Practices theo góc độ hiệu năng

### 4.1 Worker process — DC-level tuning (confirmed TC-00-7)

```
Đo thực tế từ TC-00-7:
  docker exec apisix-profile-dc1 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes
  -> worker_processes 2;   (DC1, config-dc1.yaml: worker_processes: 2)
  -> worker_processes 1;   (DC2, config-dc2.yaml: worker_processes: 1)
  -> Cùng 1 image, khác APISIX_PROFILE -> nginx.conf khác nhau ✅
```

```yaml
nginx_config:
  worker_processes: auto         # production: auto = số CPU core
  worker_rlimit_nofile: 65536    # file descriptor limit cho S3 workload
  event:
    worker_connections: 16384    # S3 có nhiều concurrent connection (multipart upload)
```

### 4.2 Upstream Active/Passive với health check — confirmed TC-00-2, TC-00-7

```yaml
upstreams:
  - id: ceph-rgw-dc1
    name: "Ceph RGW HCM Active/Passive"
    type: roundrobin
    nodes:
      - host: 172.25.216.241
        port: 3950
        weight: 1
        priority: 1    # Active — nhận traffic
      - host: 172.25.216.186
        port: 3950
        weight: 1
        priority: 0    # Passive — chỉ nhận khi Active down (confirmed TC-00-2)
    checks:
      active:
        type: http
        http_path: /
        healthy:
          interval: 5
          successes: 2         # 2 lần pass mới mark healthy
        unhealthy:
          interval: 5
          http_failures: 3     # 3 lần fail mới mark unhealthy (~15s detect)
    scheme: http
```

### 4.3 Route matching — path style và vhost style (confirmed TC-00-7 B4-B5)

```yaml
routes:
  # Path style: s3.hcm.sds.vnpaycloud.vn/bucket/key
  - id: s3-dc1-path
    uri: /*
    host: "s3.hcm.sds.vnpaycloud.vn"
    upstream_id: ceph-rgw-dc1

  # Virtual-host style: bucket.s3.hcm.sds.vnpaycloud.vn/key
  - id: s3-dc1-vhost
    uri: /*
    host: "*.s3.hcm.sds.vnpaycloud.vn"
    upstream_id: ceph-rgw-dc1

  # Service chỉ DC1 — DC2 KHÔNG có (confirmed TC-00-7 B5)
  - id: ekyc-dc1
    uri: /ekyc/*
    host: "api.dc1.lab.thuyldx"
    upstream_id: ekyc-backend-dc1
```

---

## 5. Best Practices theo góc độ observability

### 5.1 Prometheus metrics

```yaml
# config-{profile}.yaml
plugins:
  - prometheus

plugin_attr:
  prometheus:
    export_addr:
      ip: "0.0.0.0"
      port: 9091
```

**Alert rules quan trọng cho standalone + S3:**

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
          summary: "Ceph RGW node {{ $labels.name }} unhealthy"

      # Phát hiện config không reload được (file lỗi, thiếu #END)
      - alert: APISIX_ConfigReloadFailed
        expr: time() - apisix_config_reload_success_timestamp > 300
        for: 1m
        annotations:
          summary: "apisix-{profile}.yaml chưa reload trong 5 phút"

      - alert: APISIX_ProcessDown
        expr: up{job="apisix"} == 0
        for: 30s
```

### 5.2 Verify hot-reload thành công sau deploy

```bash
# Verify sau deploy
docker logs apisix --since 10s 2>&1 | grep -E "reloaded|error|warn"

# Success:
# config file /usr/local/apisix/conf/apisix-dc1.yaml reloaded.

# File lỗi (config cũ vẫn chạy — traffic OK):
# failed to parse the content of file .../apisix-dc1.yaml: ...
# missing valid end flag in file .../apisix-dc1.yaml

# Container crash loop (volume mount sai tên — TC-00-7 pitfall #1):
# failed to open file: config-dc1.yaml: No such file or directory
```

### 5.3 Verify DC isolation sau deploy (từ TC-00-7)

```bash
# Verify worker_processes per DC
docker exec apisix-dc1 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes
docker exec apisix-dc2 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes

# Verify service isolation
curl -s -o /dev/null -w "%{http_code}" \
  -H "Host: s3.hcm.sds.vnpaycloud.vn" http://DC1:9080/
# Expected: 200

curl -s -H "Host: api.ekyc.domain.vn" http://DC2:9080/ekyc/
# Expected: {"error_msg":"404 Route Not Found"}  <- APISIX 404 (JSON)

curl -s -H "Host: s3.hni.sds.vnpaycloud.vn" http://DC1:9080/
# Expected: {"error_msg":"404 Route Not Found"}  <- APISIX 404 (JSON)
```

---

## 6. Best Practices theo góc độ resilience

### 6.1 DP resilience — so sánh với Traditional mode

Standalone kế thừa DP resilience của APISIX nhưng loại bỏ toàn bộ failure domain của etcd:

```
Traditional mode (GD0/GD1) failure scenarios:
  etcd die -> CP tê liệt -> không thể change config
  etcd die + DP restart -> DP không load được config <- FATAL (TC-05-9)
  DC1 die -> etcd die -> CP1 + CP2 vô dụng (confirmed TC-01-8B)

Standalone mode failure scenarios:
  File lỗi khi hot-reload -> APISIX reject -> config cũ giữ nguyên ✅
  File lỗi + docker restart -> APISIX startup fail <- FATAL (xem 6.2)
  DC1 die -> DC2 standalone hoàn toàn độc lập, không bị ảnh hưởng ✅
  Git server die -> traffic vẫn OK, chỉ không deploy được ✅
  CI/CD die -> traffic vẫn OK, chỉ không deploy được ✅
```

### 6.2 FATAL scenario — file lỗi khi restart

```
NGUY HIỂM NHẤT TRONG STANDALONE MODE:

  1. File apisix-dc1.yaml bị lỗi syntax
  2. Hot-reload reject -> traffic OK (config cũ trong memory)
  3. Ai đó restart container (không biết có lỗi file)
  4. APISIX startup -> đọc file lỗi -> FAIL TO START
  5. Container exit -> restart loop -> traffic DOWN

Prevention:
  - Validate YAML trước khi deploy (CI/CD gate bắt buộc)
  - Backup file trước khi overwrite (deploy script)
  - Monitor: alert nếu container restart unexpectedly
  - Không restart container khi đang investigate lỗi file
```

### 6.3 Auto-rollback mechanism trong APISIX

```
Parse fail -> config cũ giữ nguyên (confirmed TC-00-7 B10):

  1. File thay đổi detected (mtime watch mỗi 1s)
  2. APISIX parse apisix-{profile}.yaml
  3. Parse FAIL (lỗi syntax hoặc thiếu #END):
     -> Log: "missing valid end flag" / "failed to parse..."
     -> GIỮ NGUYÊN config cũ trong nginx worker memory ✅
     -> Traffic không gián đoạn ✅
  4. Parse OK:
     -> Apply config mới (graceful nginx reload)
     -> Log: "config file apisix-dc1.yaml reloaded."

NOTE: auto-rollback CHỈ áp dụng cho lỗi SYNTAX
  -> Logic error (valid YAML nhưng upstream sai): apply luôn
  -> CI/CD cần health check sau deploy để catch logic error
```

### 6.4 Emergency recovery procedure

```bash
# === EMERGENCY RECOVERY ===

# Bước 1: Xác định trạng thái container
docker inspect apisix --format='{{.State.Health.Status}}'
docker logs apisix --tail=20 2>&1 | grep -E "error|warn|reloaded|failed"

# Bước 2: Tìm backup gần nhất
ls -lt ~/profile/apisix_conf/apisix-dc1.yaml.bak-* | head -5

# Bước 3: Validate backup trước khi restore
python3 -c "
import yaml
with open('apisix-dc1.yaml.bak-TIMESTAMP') as f:
    content = f.read()
assert '#END' in content, 'Missing #END'
yaml.safe_load(content)
print('OK')
"

# Bước 4: Restore (cp giữ inode -> hot-reload tự động)
cp apisix-dc1.yaml.bak-TIMESTAMP ~/profile/apisix_conf/apisix-dc1.yaml

# Bước 5: Nếu container đã crash -> start với file backup đã restore
docker compose up -d

# Bước 6: Verify
sleep 15
docker inspect apisix --format='{{.State.Health.Status}}'
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: s3.hcm.sds.vnpaycloud.vn" http://localhost/
```

---

## 7. Yếu điểm Standalone → GitOps cải thiện

### 7.1 Không có audit trail khi thay đổi thủ công

**Vấn đề:**
```
Thay đổi trực tiếp (nano/vim trên host):
  - Ai thay đổi? Không biết
  - Khi nào? Không biết
  - Tại sao? Không biết
  - 2 engineer sửa cùng lúc -> conflict không ai hay
```

**GitOps cải thiện:**
```
Mọi thay đổi = git commit:
  - Who:    git author
  - When:   commit timestamp
  - What:   git diff (chính xác từng dòng)
  - Why:    commit message
  - Review: Pull Request approval trước khi apply

git log --oneline fragments/services/s3-hcm.yaml
# abc1234 fix(s3): reduce health check interval HCM-1 node
# def5678 feat(s3): add tenant-b bucket prefix routing
```

### 7.2 Config drift giữa DC1 và DC2

**Vấn đề:**
```
Sau sự cố Ceph HCM, engineer sửa upstream DC1
-> Quên update DC2
-> DC2 vẫn trỏ Ceph node đã dead -> 502
-> Không ai biết cho đến khi có request vào DC2
```

**GitOps cải thiện:**
```
CI/CD enforce consistency:
  - Detect _meta.dc: [all] -> rebuild + deploy cả 2 DC
  - Deploy DC1 -> health check pass -> deploy DC2
  - DC1 fail -> auto-rollback DC1, DC2 không được deploy
  - Git repo = ground truth cho cả 2 DC
```

### 7.3 Rollback thủ công chậm khi sự cố

**Vấn đề:**
```
Sự cố lúc 3 giờ sáng:
  On-call: SSH vào host, tìm backup, validate, copy
  MTTR: 5-15 phút
```

**GitOps cải thiện (git-sync):**
```
Tầng 1 — git revert (< 5 phút, có full audit trail):
  git revert <bad-commit> + push lên release/routes
  → git-sync detect trong ≤ 30s
  → exechook copy file → APISIX hot-reload
  → Traffic recovered. Audit: ai revert, lúc mấy giờ, commit nào

Tầng 2 — Manual emergency từ revision cũ (< 1 phút):
  git-sync giữ N revision cũ trên disk (/opt/apisix/standalone/sandbox/conf_routes/rev-XXXXX/)
  → Không cần tìm backup, không cần wget
  → cp rev-cũ/apisix-dc1.yaml apisix-dc1.yaml → hot-reload ngay
  → Nhanh hơn webhook (không cần push, không cần đợi download)
```

### 7.4 Không có dry-run trước khi apply

**Vấn đề:**
```
Không biết config sắp deploy sẽ gây vấn đề gì cho đến khi apply
```

**GitOps cải thiện:**
```
CI/CD Stage validate (trước khi deploy):
  - YAML syntax check
  - #END marker check
  - Required fields: id, uri/host, upstream hoặc upstream_id
  - Duplicate route ID detection
  - Lua plugin config schema validation
  -> Fail fast: validate fail -> pipeline stop, không deploy
```

### 7.5 Không scale-out được khi tải tăng đột biến

**Vấn đề:**
```
Khi S3 traffic tăng đột biến (backup batch, migration):
  → 1 container APISIX standalone không đủ tải
  → Cần thêm instance nhưng config phải đồng bộ
  → Thêm container thủ công → dễ drift config giữa các instance
```

**GitOps + git-sync cải thiện:**
```
Mô hình: mỗi APISIX container có git-sync sidecar riêng
  apisix-dc1-1  ←→  git-sync-dc1-1  (watch release/routes)
  apisix-dc1-2  ←→  git-sync-dc1-2  (watch release/routes — cùng branch)
  apisix-dc1-3  ←→  git-sync-dc1-3  (scale-out: thêm cặp mới)

  apisix-dc2-1  ←→  git-sync-dc2-1  (watch release/routes — DC độc lập)
  apisix-dc2-2  ←→  git-sync-dc2-2

Scale-out = thêm cặp {apisix + git-sync} vào docker-compose
  → Tất cả cặp đều pull từ cùng 1 branch → config luôn nhất quán
  → DC1 và DC2 hoàn toàn độc lập: DC2 chạy khi DC1 down vẫn OK
  → Không có "deploy order": mỗi container tự chủ, tự pull config

Git repo = ground truth: dù có bao nhiêu container,
  config của chúng luôn converge về cùng 1 commit
```

> **Lưu ý:** DC1 và DC2 **không có thứ tự chạy** — đây là thiết kế cố ý.  
> Mỗi DC vận hành hoàn toàn độc lập. DC2 có thể up trong khi DC1 down.  
> Đây là điểm khác biệt căn bản so với Traditional mode (etcd cluster cần quorum).

### 7.6 File lớn, khó review khi nhiều tenant

**Vấn đề:**
```
apisix-dc1.yaml với 50+ routes từ 20 tenant:
  - Khó review thay đổi của 1 tenant
  - Conflict khi nhiều người sửa cùng lúc
```

**GitOps cải thiện:**
```
Fragment-based source:
  fragments/services/s3-hcm.yaml     -> team S3 quản lý
  fragments/services/ekyc.yaml       -> team eKYC quản lý
  fragments/tenants/tenant-a.yaml    -> tenant A config

Build: merge fragments -> apisix-dc1.yaml (generated)
  - Mỗi team có file riêng -> không conflict git merge
  - _meta.dc field -> CI/CD biết deploy DC nào
```

---

## 8. Yếu điểm Standalone → Profile cải thiện

### 8.1 DC1 và DC2 có service khác nhau

**Vấn đề:**
```
Không có Profile -> phải chọn:
  Option A: 1 file chung -> eKYC route DC2 trỏ upstream không tồn tại -> 502
  Option B: 2 file hoàn toàn riêng -> duplicate S3 config, drift theo thời gian
```

**Profile cải thiện (confirmed TC-00-7):**
```
APISIX_PROFILE=dc1 -> apisix-dc1.yaml:  S3 HCM + eKYC
APISIX_PROFILE=dc2 -> apisix-dc2.yaml:  S3 HNI only

Verified behavior từ TC-00-7:
  DC2 eKYC test:   {"error_msg":"404 Route Not Found"}  ✅
  DC1 S3 HNI test: {"error_msg":"404 Route Not Found"}  ✅
  -> Isolation hoàn toàn, không cross-contaminate
```

### 8.2 DC-level deployment config khác nhau

**Vấn đề:**
```
DC1: 4 core -> worker_processes: 4
DC2: 2 core -> worker_processes: 2
-> Không thể dùng 1 config.yaml chung
```

**Profile cải thiện (confirmed TC-00-7):**
```
config-dc1.yaml: worker_processes: 2 -> nginx.conf: "worker_processes 2;"
config-dc2.yaml: worker_processes: 1 -> nginx.conf: "worker_processes 1;"

Cùng 1 docker image -> khác nginx.conf -> khác resource usage
Không cần build image riêng per DC ✅
```

### 8.3 Plugin list khác nhau per DC

**Vấn đề:**
```
DC1 cần: prometheus, proxy-rewrite, ip-restriction, limit-req, limit-count
DC2 chỉ cần: prometheus, proxy-rewrite, ip-restriction
-> Không thể dùng 1 config.yaml chung
```

**Profile cải thiện:**
```yaml
# config-dc1.yaml
plugins: [prometheus, proxy-rewrite, ip-restriction, limit-req, limit-count]

# config-dc2.yaml
plugins: [prometheus, proxy-rewrite, ip-restriction]
# DC2 không load limit-req, limit-count -> tiết kiệm memory
```

### 8.4 Staging vs Production

**Profile cải thiện:**
```
APISIX_PROFILE=dc1-staging -> apisix-dc1-staging.yaml
  -> upstream: Ceph staging (172.25.99.x)
  -> ssl: staging cert

APISIX_PROFILE=dc1 -> apisix-dc1.yaml
  -> upstream: Ceph production (172.25.216.x)
  -> ssl: production cert

CI/CD flow:
  PR merge to develop -> deploy dc1-staging -> smoke test
  Approve -> merge to main -> deploy dc1 production
```

### 8.5 Separation rõ ràng infrastructure vs service config

**Profile cải thiện:**
```
config-{profile}.yaml = DC infrastructure layer
  Owner: Platform team
  Reload: docker restart (ít thay đổi)
  Chứa: nginx tuning, plugin list, Prometheus bind IP

apisix-{profile}.yaml = service config layer
  Owner: per-service team
  Reload: hot-reload (thay đổi thường xuyên hơn)
  Chứa: routes, upstreams, ssl, consumers

-> Hai team làm việc độc lập, không conflict file
```

---

## 9. TC-00-7 Lab Findings — Confirmed Behaviors

> Kết quả thực tế từ lab test TC-00-7 (GD0) — tất cả đã được verify trực tiếp

### Finding 1: Volume mount phải khớp tên file theo APISIX_PROFILE

```
APISIX_PROFILE=dc1 -> APISIX tìm: config-dc1.yaml, apisix-dc1.yaml

Mount đúng tên:
  ./conf/config-dc1.yaml -> /conf/config-dc1.yaml  ✅ Container healthy

Mount sai tên:
  ./conf/config.yaml -> /conf/config.yaml          ❌ Container crash loop
  Error: "failed to open file: config-dc1.yaml: No such file or directory"

-> Pitfall #1 khi migrate từ non-profile sang profile
-> Phải update docker-compose.yml đồng thời với thêm APISIX_PROFILE
```

### Finding 2: DC-level isolation hoạt động đúng

```
Lab verified:
  apisix-profile-dc1: worker_processes: 2  ✅
  apisix-profile-dc2: worker_processes: 1  ✅

  Cùng 1 image apache/apisix:3.15.0-debian
  -> nginx.conf khác nhau per DC
  -> worker_processes, ulimits, plugin list độc lập
  -> Không cần build image riêng per DC
```

### Finding 3: Service-level isolation hoạt động đúng

```
Lab verified:
  DC1 S3 HCM:  HTTP 200  ✅  route s3-dc1-path -> Ceph HCM reachable
  DC1 eKYC:    HTTP 000  ✅  route tồn tại, upstream :8080 không có service thật
  DC2 S3 HNI:  HTTP 200  ✅  route s3-dc2-path -> Ceph HNI reachable
  DC2 eKYC:    HTTP 404  ✅  {"error_msg":"404 Route Not Found"} <- route không có DC2
  DC1 S3 HNI:  HTTP 404  ✅  {"error_msg":"404 Route Not Found"} <- route không có DC1

  -> Thay đổi apisix-dc1.yaml không ảnh hưởng DC2 — hoàn toàn độc lập
```

### Finding 4: Phân biệt 2 loại 404

```
Lab verified (TC-00-7 B12):

APISIX 404 (gateway layer):
  Body: {"error_msg":"404 Route Not Found"}  <- JSON
  Meaning: Không có route match Host+URI
  Debug: gateway config (profile, route, host header)

Ceph 404 (storage layer):
  Body: <?xml...><Code>NoSuchBucket</Code>  <- XML
  Meaning: Route đúng, request đến Ceph, bucket không tồn tại
  Debug: storage (bucket, credentials, zone)

Rule: Nhìn Content-Type và body format TRƯỚC khi vào log
  -> Tiết kiệm 5-10 phút debug mỗi incident
```

### Finding 5: Hot-reload inode pitfall — confirmed thực tế

```
Lab verified (TC-00-7 B10):

SAI (cat >> tạo inode mới):
  cat >> ~/profile/apisix_conf/apisix-dc1.yaml << 'EOF'
    - id: new-route ...
  EOF
  -> APISIX log: "missing valid end flag in file apisix-dc1.yaml"
  -> Container không detect inode mới -> không reload -> config cũ giữ

ĐÚNG (python3 giữ inode):
  python3 -c "
    content = open('apisix-dc1.yaml').read()
    content = content.replace('#END', new_route + '#END')
    open('apisix-dc1.yaml', 'w').write(content)
  "
  -> APISIX log: "config file apisix-dc1.yaml reloaded."
  -> Route mới load thành công

Rule: cp, scp, python3 write-in-place -> giữ inode -> hot-reload OK
```

### Finding 6: Resilience khi file lỗi — confirmed

```
Lab verified (TC-00-7 B10):
  File thiếu #END -> APISIX reject liên tục (log mỗi 1s) ✅
  Config cũ vẫn chạy -> traffic không gián đoạn ✅
  Sau khi fix #END -> auto reload -> không cần can thiệp thủ công ✅

  So với Traditional mode (GD0/GD1):
    etcd corrupt -> cần restart + restore snapshot
    Standalone: chỉ cần fix file -> hot-reload tự động
```

### Finding 7: Separation 2 tầng config — operational implication

```
Lab verified (TC-00-7 B2-B3 + B8):

  config-{profile}.yaml: verify bằng nginx.conf
    docker exec apisix-profile-dc1 cat /usr/local/apisix/conf/nginx.conf | grep worker_processes
    -> worker_processes 2; (DC1 verified)
    -> worker_processes 1; (DC2 verified)

  apisix-{profile}.yaml: verify bằng HTTP test
    curl -H "Host: s3.hcm.lab.thuyldx" http://DC1/ -> 200
    curl -H "Host: api.dc1.lab.thuyldx" http://DC2/ -> 404 JSON

  -> Không cần Admin API để verify config đang chạy
  -> Verify bằng nginx.conf (infrastructure) + HTTP test (service)
```

---

## 10. Ma trận tổng hợp

| Yếu điểm | Loại | Giải pháp | Cơ chế | Lab evidence |
|---|---|---|---|---|
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

---

### Nguyên tắc tổng quát

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

---

*Document version: 5.0 — Production deployment: Docker Compose + HAProxy LB + git-sync exechook fix + scale-out*  
*APISIX version: 3.15.0-debian | K8s: k3s single-node (GD2)*  
*Cập nhật khi: upgrade APISIX version, thêm DC mới, thêm service mới, findings từ TC mới*

---

## 11. Production Deployment — Docker Compose + HAProxy

### 11.1 Kiến trúc triển khai thực tế

```
Internet / S3 Client
  ↓ DNS: s3.hcm.lab.thuyldx → DC1 node IP
  ↓ Port 7080 (HTTP) / 7443 (HTTPS)

┌─────────────────── DC1 Node ─────────────────────────────────┐
│                                                               │
│  haproxy-lb                                                   │
│    :7080 → apisix_pool (leastconn)                           │
│    :7443 → apisix_pool_tls (tcp)                             │
│    :8404 → stats dashboard                                    │
│         ↓ round-robin / leastconn                             │
│  apisix-dc1-1:9080   apisix-dc1-2:9080                       │
│    ↕ hot-reload           ↕                                   │
│  conf_routes/             conf_routes/   (shared mount)       │
│    apisix_routes/         apisix_routes/                      │
│      apisix-dc1.yaml ←─── copy-hook.sh ←── git-sync-routes   │
│  conf_system/                                                 │
│    apisix_config/                                             │
│      config-dc1.yaml ←─── copy-hook.sh ←── git-sync-system   │
│                                                               │
│  logs/apisix-dc1-1/   logs/apisix-dc1-2/                     │
│  secrets/.netrc                                               │
│  scripts/copy-hook.sh                                         │
│  haproxy/haproxy.cfg  haproxy/run/admin.sock                  │
└───────────────────────────────────────────────────────────────┘
  ↓ proxy upstream
Ceph RGW 172.25.216.135:3950
```

### 11.2 Cấu trúc thư mục Node

```
~/opt/apisix/standalone/sandbox/
│
├── docker-compose.yml
├── .env                          ← DC_PROFILE=dc1 | dc2 (có trong .gitignore, KHÔNG commit)
├── .env.example
│
├── conf_routes/                  ← git-sync-routes ghi vào (release/routes)
│   ├── current -> .worktrees/    ← symlink atomic, git-sync tự quản
│   ├── .worktrees/               ← git-sync tự quản, KHÔNG touch
│   ├── .git/                     ← git-sync tự quản, KHÔNG touch
│   ├── sync.log
│   └── apisix_routes/
│       └── apisix-dc1.yaml       ← copy-hook.sh ghi ra, APISIX đọc và mount file này
│
├── conf_system/                  ← git-sync-system ghi vào (release/system)
│   ├── current -> .worktrees/
│   ├── .worktrees/
│   ├── .git/                     ← git-sync tự quản, KHÔNG touch
│   ├── sync.log
│   └── apisix_config/
│       └── config-dc1.yaml       ← copy-hook.sh ghi ra, systemd watcher theo dõi và tự động restart docker container
│
├── scripts/
│   ├── compile.py                ← gộp files khi chạy CI/CD
│   └── copy-hook.sh              ← exechook wrapper, mount read-only vào git-sync
│
├── haproxy/
│   ├── haproxy.cfg
│   └── run/
│       └── admin.sock            ← Unix socket để thao tác HAProxy runtime
│
├── nginx/
│   └── nginx.conf                ← (backup, đang dùng HAProxy)
│
├── plugins/
│   └── ceph-rados-regex.lua      ← deploy thủ công, restart khi thay đổi
│
├── logs/
│   ├── apisix-dc1-1/
│   ├── apisix-dc1-2/
│   └── apisix-dc1-n/
│
└── secrets/
    └── .netrc                    ← GitLab HTTPS auth (có trong .gitignore, KHÔNG commit), chmod 600
```

### 11.3 Phân quyền bắt buộc

```bash
# git-sync (UID 65533) — write vào conf_routes/, conf_system/
sudo chown -R 65533:65533 conf_routes/ conf_system/
sudo chmod -R 755 conf_routes/ conf_system/

# git-sync — đọc .netrc và copy-hook.sh
sudo chown 65533:65533 secrets/.netrc scripts/copy-hook.sh
sudo chmod 600 secrets/.netrc
sudo chmod +x scripts/copy-hook.sh

# APISIX (UID 636) — write vào logs/
sudo chown nobody:nogroup logs/
sudo chown -R 636:636 logs/apisix-dc1-1/ logs/apisix-dc1-2/
sudo chmod -R 755 logs/

# HAProxy socket
sudo chown -R 99:99 haproxy/run/
sudo chmod 666 haproxy/run/admin.sock  # sau khi HAProxy start
```

### 11.4 copy-hook.sh — Exechook wrapper

**Vấn đề gốc rễ:** git-sync v4 exec `GITSYNC_EXECHOOK_COMMAND` **không qua shell** — không support arguments có space, pipes, `&&`. Dùng inline command như `/bin/cp src dst` bị `fork/exec` parse sai.

**Giải pháp:** wrapper script mount riêng vào container, nhận `HOOK_TYPE` và `DC_PROFILE` từ env:

```bash
#!/bin/sh
# ~/opt/apisix/standalone/sandbox/scripts/copy-hook.sh
# HOOK_TYPE: routes | system
# DC_PROFILE: dc1 | dc2 (từ .env)

if [ "$HOOK_TYPE" = "routes" ]; then
    cp /tmp/sync/current/apisix-${DC_PROFILE}.yaml \
       /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml

elif [ "$HOOK_TYPE" = "system" ]; then
    cp /tmp/sync/current/config-${DC_PROFILE}.yaml \
       /tmp/sync/apisix_config/config-${DC_PROFILE}.yaml
fi
```

### 11.5 HAProxy — Load Balancer

**Lý do chọn HAProxy thay vì Nginx:**

| | Nginx | HAProxy |
|---|---|---|
| Health check | Passive only | Active L7 mỗi 5s |
| Tự loại backend chết | Không | Có — sau 2 lần fail |
| Drain graceful | Không có | Runtime API qua socket |
| Stats dashboard | Không | `:8404/stats` |

**Scale-out không downtime:**
```bash
# Thêm apisix-2 vào pool — không cần reload toàn bộ
docker exec haproxy-lb sh -c \
  'echo "set server apisix_pool/apisix-2 state ready" | \
   socat stdio /var/run/haproxy/admin.sock'
```

**Drain trước khi scale-in:**
```bash
# Ngừng nhận request mới, giữ connection đang xử lý
docker exec haproxy-lb sh -c \
  'echo "set server apisix_pool/apisix-2 state drain" | \
   socat stdio /var/run/haproxy/admin.sock'

# Reload config sau khi sửa haproxy.cfg
docker exec haproxy-lb sh -c 'kill -USR2 1'
```

**Quan sát pool realtime:**
```bash
watch -n2 'docker exec haproxy-lb sh -c \
  "echo \"show servers state apisix_pool\" | \
   socat stdio /var/run/haproxy/admin.sock"'
```

### 11.6 Scale-out Pattern

```
1 git-sync-routes  ─────────────────────────────┐
1 git-sync-system  ─────────────────────────────┤
                                                 ↓
                                    conf_routes/apisix_routes/
                                    conf_system/apisix_config/
                                         ↓ shared mount
apisix-dc1-1 ──────────────────────────────────┤
apisix-dc1-2 ──────────────────────────────────┤  ← cùng config
apisix-dc1-n ──────────────────────────────────┘  ← scale thêm không cần config
```

**Thêm instance mới:**
```bash
# 1. Tạo log dir
sudo mkdir -p logs/apisix-dc1-3
sudo chown -R 636:636 logs/apisix-dc1-3

# 2. Uncomment block apisix-3 trong docker-compose.yml

# 3. Start — không ảnh hưởng instance đang chạy
docker compose up -d apisix-3

# 4. Thêm vào HAProxy pool
# Sửa haproxy.cfg: server apisix-3 apisix-dc1-3:9080 check inter 5s fall 2 rise 2
docker exec haproxy-lb sh -c 'kill -USR2 1'
```

### 11.7 Bottleneck Analysis

```
Upstream: Ceph RGW lab = 512 threads | Cloudian prod = 2000 threads (4 node × 500)

Recommended config:

                    Ceph (lab)    Cloudian (prod)
HAProxy maxconn     50000         50000
server maxconn      320/container 1280/container
  (×2 containers)   640 total     2560 total     ← buffer 25% vs upstream
APISIX workers      2 × 16384     2 × 16384
  worker_rlimit     65536         65536
Upstream threads    512 ← bottleneck  2000 ← bottleneck

Rule: server maxconn = (upstream_threads / num_containers) × 1.25
```

### 11.8 Kiểm tra stack health

```bash
# Container status
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check git-sync đã pull commit mới chưa
# Xem revision hiện tại git-sync đang dùng. So sánh với commit hash trên GitLab
# Nếu hash khớp → git-sync đã pull xong
readlink conf_routes/current
readlink conf_system/current
# Check file đã được copy ra chưa
# Xem nội dung file local
cat conf_routes/apisix_routes/apisix-dc1.yaml | head -3
cat conf_system/apisix_config/config-dc1.yaml | grep -E "worker_processes|worker_connections|maxconn"
# So sánh với file trong revision mới nhất
cat conf_system/current/config-dc1.yaml | grep -E "worker_processes|worker_connections|maxconn"

# Xem tình trạng các node trong HAProxy pool
docker exec haproxy-lb sh -c 'echo "show servers state apisix_pool" | socat stdio /var/run/haproxy/admin.sock'

# APISIX routing
curl -s -H "Host: s3.hcm.lab.thuyldx" http://localhost:7080/ | head -1

# APISIX log
tail -f logs/apisix-dc1-1/access.log | grep -v "apisix/status"
```

### 11.9 Troubleshooting thực tế từ lab

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| `fork/exec /bin/cp: no such file or directory` | git-sync exec không qua shell, space trong args bị parse sai | Dùng wrapper script `copy-hook.sh` |
| `Is a directory` khi load plugin | Docker tạo directory thay vì file khi mount target chưa tồn tại trên host | `rm -rf plugins/ceph-rados-regex.lua && cp file.lua plugins/` rồi `docker compose down && up` |
| `413 Request Entity Too Large` | `client_max_body_size: 10m` quá nhỏ cho S3 upload | Set `client_max_body_size: 0` trong `config-dc1.yaml` |
| git-sync `HTTP Basic: Access denied` | `GITSYNC_GIT_CONFIG: credential.helper=store` sai format | Xóa dòng đó, mount `.netrc` vào `/tmp/.netrc` |
| HAProxy socket `Permission denied` | `haproxy/run/` chưa chown cho HAProxy UID 99 | `sudo chown -R 99:99 haproxy/run/` |
| APISIX không hot-reload dù file đã thay đổi | exechook fail → file không được copy ra | Check `docker logs git-sync-routes`, fix exechook |
| exechook copy thủ công OK nhưng tự động fail | Permission: file đích owner là `root` | `sudo chown 65533:65533 conf_*/apisix_*/` |
|current khớp nhưng git-sync chưa update được|git-sync lỗi hoặc down| `docker exec git-sync-{system/routes} /bin/cp /tmp/sync/current/{config/apisix}-{PROFILE}.yaml /tmp/sync/apisix_{config/routes}/{config/apisix}-{PROFILE}}.yaml && echo "OK"`|

---

## 12. GitOps — git-sync Pull-based (Dual-branch)

> **v4.0 — Thay thế adnanh/webhook bằng git-sync.**  
> Lý do migration: webhook yêu cầu GitLab có thể gọi vào VM (inbound port 9000), không phù hợp môi trường DC internal có firewall nghiêm ngặt. git-sync dùng mô hình pull-only, không mở thêm port nào trên VM.

### 12.1 So sánh: Webhook vs git-sync — Lý do chuyển đổi

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


### 12.2 Kiến trúc Dual-branch — Tách biệt 2 vòng đời config

Điểm khác biệt quan trọng nhất so với webhook (1 branch): git-sync dùng **2 branch riêng biệt**, phản ánh đúng 2 loại file trong APISIX Standalone.

```
GitLab Repository (apisix-config) với 3 nhánh master, release/routes và release/system
│
├── master                    ← base: scripts, CI templates, docker-compsoe.yaml, README
│   ├── docker-compose.yaml
│   └── scripts/
│       ├── gitsync.sh        ← exechook wrapper (source of truth)
│       └── compile.py
├── release/routes            ← Service Team: routes, upstreams, services
│   ├── .gitignore
│   ├── fragments/
│   │   ├── routes/
│   │   │   ├── route-s3-dc1.yaml
│   │   │   ├── route-s3-dc2.yaml
│   │   │   ├── route-ekyc-dc1.yaml
│   │   │   └── ...
│   │   └── upstreams/
│   │       ├── upstream-ceph-dc1.yaml
│   │       ├── upstream-ceph-dc2.yaml
│   │       └── ...
│   ├── manifest-dc1.yaml
│   ├── manifest-dc2.yaml
│   ├── apisix-dc1.yaml       ← compiled output cho DC1, CI tự commit sau khi merge
│   └── apisix-dc2.yaml       ← compiled output cho DC2, CI tự commit sau khi merge
└── release/system            ← Platform Team: APISIX (nginx tuning), plugin list
    ├── .gitignore
    ├── fragments/
    │   └── plugins/
    │       └── ceph-s3-regex.lua
    ├── manifest-dc1.yaml
    ├── manifest-dc2.yaml
    ├── config-dc1.yaml       ← worker_processes, plugin list DC1
    └── config-dc2.yaml       ← worker_processes, plugin list DC2

         ↓ mỗi git-sync instance poll 30s (SSH, shallow clone)

┌─────────────────── DC1 (Host) ───────────────────────────┐
│                                                           │
│  /opt/apisix/standalone/sandbox/                                             │
│  ├── conf_routes/   ← release/routes (git-sync-apisix)  │
│  │   ├── current → rev-abc/  (atomic symlink)            │
│  │   └── apisix-dc1.yaml     (exechook copy)             │
│  └── conf_system/  ← release/system (git-sync-config)  │
│      └── config-dc1.yaml     (exechook copy)             │
│                                                           │
│  ┌─────────────────────────────────────────────────┐     │
│  │  apisix-dc1-1  ←→  git-sync-dc1-1  (sidecar)   │     │
│  │  apisix-dc1-2  ←→  git-sync-dc1-2  (sidecar)   │ ← scale-out
│  │  apisix-dc1-N  ←→  git-sync-dc1-N  (sidecar)   │     │
│  └─────────────────────────────────────────────────┘     │
│                                                           │
│  Tất cả apisix-dc1-* đọc cùng conf_routes/              │
│  → Cùng config, dù có N instance                         │
└───────────────────────────────────────────────────────────┘

┌─────────────────── DC2 (Host) ───────────────────────────┐
│  Hoàn toàn độc lập với DC1                               │
│  DC2 up/down không ảnh hưởng DC1 (và ngược lại)          │
│                                                           │
│  ┌─────────────────────────────────────────────────┐     │
│  │  apisix-dc2-1  ←→  git-sync-dc2-1  (sidecar)   │     │
│  │  apisix-dc2-2  ←→  git-sync-dc2-2  (sidecar)   │     │
│  └─────────────────────────────────────────────────┘     │
│  Đọc apisix-dc2.yaml (khác DC1), config-dc2.yaml         │
└───────────────────────────────────────────────────────────┘
```

**Nguyên tắc kiến trúc:**

| Đặc điểm | Mô tả |
|---|---|
| **Sidecar pattern** | Mỗi `apisix-dc{X}-{N}` có `git-sync-dc{X}-{N}` riêng |
| **Shared volume trong DC** | Tất cả instance trong cùng DC đọc chung `conf_routes/` |
| **DC isolation** | DC1 và DC2 **không có deploy order** — độc lập hoàn toàn |
| **Scale-out** | Thêm cặp `{apisix + git-sync}` vào compose — config tự đồng bộ |
| **Branch per DC** | `release/routes` chứa cả `apisix-dc1.yaml` và `apisix-dc2.yaml` |

**Branch ownership:**

| Branch | Owner | Thay đổi khi nào | APISIX action |
|---|---|---|---|
| `main` | Platform Team | Infra thay đổi, script update | Admin tự restart |
| `release/routes` | Service Team | Thêm tenant, sửa upstream, thêm route | Hot-reload < 1s, zero downtime |
| `release/system` | Platform Team | Tune nginx, thêm plugin, thay đổi worker | `docker restart` ~5-10s downtime |

### 12.3 gitsync.sh — Source of truth

Script này là **single entry point** cho toàn bộ exechook logic. Chạy sau mỗi lần git-sync pull thành công.

```bash
#!/bin/sh
# scripts/gitsync.sh
# Env vars:
#   GITSYNC_SCOPE_TARGET : routes | system | master
#   DC_PROFILE           : dc1 | dc2 (từ .env)

case "$GITSYNC_SCOPE_TARGET" in
  routes)
    cp /tmp/sync/current/apisix-${DC_PROFILE}.yaml \
       /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml
    ;;

  system)
    cp /tmp/sync/current/config-${DC_PROFILE}.yaml \
       /tmp/sync/apisix_config/config-${DC_PROFILE}.yaml

    if [ -d /tmp/sync/current/plugins_lua ]; then
      cp -r /tmp/sync/current/plugins_lua/*.lua \
            /tmp/sync/plugins_lua/
    fi
    ;;

  master)
    cp /tmp/sync/current/docker-compose.yaml \
       /tmp/docker-compose.yaml

    if [ -d /tmp/sync/current/scripts ]; then
      cp -r /tmp/sync/current/scripts/* \
            /tmp/scripts/
    fi
    ;;

  *)
    echo "Unknown GITSYNC_SCOPE_TARGET: $GITSYNC_SCOPE_TARGET"
    exit 1
    ;;
esac
```

**Lưu ý quan trọng về shebang:**
```bash
#!/bin/sh           ← ĐÚNG — chỉ path, không có argument
# comment           ← comment nằm dòng riêng

#!/bin/sh comment   ← SAI — "comment" bị parse như argument → /bin/sh: cannot open
```

### 12.4 Luồng update gitsync.sh

```
Dev sửa scripts/gitsync.sh trên GitLab main branch
  ↓ commit
git-sync-master pull về (≤30s)
  ↓ exechook chạy gitsync.sh (case master)
  ↓ cp scripts/* → /tmp/scripts/ → host scripts/
  ↓ host scripts/gitsync.sh được update

git-sync-routes và git-sync-system
  ↓ mount ./scripts/gitsync.sh → /tmp/gitsync.sh (bind mount = live)
  ↓ lần exechook tiếp theo dùng file mới luôn
  ↓ KHÔNG cần restart container
```

**Chicken-egg problem:** lần đầu boot chưa có script → dùng script local trên host làm bootstrap. Sau đó git-sync-master tự update.

### 12.5 Custom Plugin — Lifecycle

```
1. Dev viết plugin mới: my-plugin.lua
2. Commit vào release/system/plugins_lua/my-plugin.lua
3. Commit vào release/system/config-dc1.yaml — thêm: - custom.my-plugin
4. git-sync-system pull về (≤30s)
5. gitsync.sh copy plugins_lua/*.lua → conf_system/plugins_lua/
6. Admin restart APISIX: docker compose restart apisix-standalone
7. APISIX load plugin từ /usr/local/apisix/apisix/plugins/custom/my-plugin.lua
8. Khai báo trong route: custom.my-plugin: {}
```

**Naming convention:**
```
File trên GitLab:  plugins_lua/my-plugin.lua
Mount vào:        /usr/local/apisix/apisix/plugins/custom/my-plugin.lua
Khai báo config:  - custom.my-plugin
Dùng trong route: custom.my-plugin: {}
```

### 12.6 Cấu trúc thư mục trên Host

```
/opt/apisix/standalone/sandbox/
├── docker-compose.yml            ← managed by git-sync-master
├── .env                          ← GITLAB_REPO_URL, DC_PROFILE=dc1|dc2 (không commit vào Git)
├── scripts/                      ← managed by gitsync-master
│   ├── gitsync.sh                ← exechook entry point
│   └── compile.py
├── conf_master/                  ← git-sync-master (main)
│   ├── current -> .worktrees/
│   ├── .worktrees/
│   └── .git/
├── conf_routes/                  ← release/routes sync target
│   ├── current -> .worktrees/
│   ├── .worktrees/
│   ├── .git/
│   └── apisix_routes/
│       └── apisix-dc1.yaml       ← APISIX đọc, hot-reload
├── conf_system/                  ← release/system sync target
│   ├── current -> .worktrees/
│   ├── .worktrees/
│   ├── apisix_config/
│   │   └── config-dc1.yaml       ← APISIX đọc, cần restart khi đổi
│   └── plugins_lua/
│       └── ceph-rados-regex.lua  ← APISIX mount vào plugins/custom/
├── logs/                         ← APISIX logs (chown 636:636)
└── secrets
    ├── ssh/
    │   ├── id_rsa_apisix             ← Ed25519 deploy key (chown 65533:65533, chmod 600)
    │   ├── id_rsa_config             ← Ed25519 deploy key
    │   └── known_hosts
    └── .netrc
```

**Permission bắt buộc (kế thừa từ TC-00-1, TC-00-7):**

```bash
# git-sync chạy UID 65533 — cần write vào mount dirs
sudo chown -R 65533:65533 conf_routes/ conf_system/ conf_master/
sudo chmod -R 755 conf_routes/ conf_system/ conf_master/
sudo chown 65533:65533 secrets/.netrc && sudo chmod 600 secrets/.netrc
sudo chown 65533:65533 scripts/gitsync.sh && sudo chmod +x scripts/gitsync.sh
sudo chown 65533:65533 docker-compose.yaml

# scripts/ folder (git-sync-master write vào đây)
sudo chown -R 65533:65533 scripts/

# APISIX chạy UID 636 — cần write vào logs
sudo chown -R 636:636 /opt/apisix/standalone/sandbox/logs
sudo chmod 755 /opt/apisix/standalone/sandbox/logs/

# SSH keys — chỉ git-sync đọc được
sudo chown -R 65533:65533 /opt/apisix/standalone/sandbox/secrets/ssh
sudo chmod 700 /opt/apisix/standalone/sandbox/secrets/ssh
sudo chmod 600 /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_*
```

### 12.7 docker-compose.yml — Scale-out Pattern

**Nguyên tắc:** mỗi `apisix-dc{X}-{N}` đi kèm `git-sync-dc{X}-{N}` riêng. Tất cả instance trong DC đọc chung `conf_routes/` trên Host — config luôn nhất quán dù có bao nhiêu instance. [docker-compose.yaml](../docker-compose.yaml)


> **Điểm mấu chốt của scale-out pattern:**
> - `git-sync-apisix-dc1` chỉ cần **1 instance** — ghi vào `conf_routes/` shared
> - Tất cả `apisix-dc1-*` mount cùng `conf_routes/` → đều hot-reload khi git-sync pull xong
> - Scale-out = thêm block `apisix-dc1-N` + tạo thêm log dir + đổi port
> - `git-sync-config-dc1` cũng chỉ cần **1 instance** — systemd watcher restart tất cả container DC1

**Script tạo log dirs khi scale-out:**

```bash
# Tạo log dir cho từng instance (chown 636:636 = UID của apisix user)
for i in 1 2 3; do
  sudo mkdir -p /opt/apisix/standalone/sandbox/logs/apisix-dc1-${i}
  sudo chown -R 636:636 /opt/apisix/standalone/sandbox/logs/apisix-dc1-${i}
done
```

**Systemd watcher — restart tất cả container DC1 khi config thay đổi:**

```ini
# /etc/systemd/system/apisix-config-watcher.service
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
# Restart tất cả container DC1 (không quan tâm có bao nhiêu instance)
ExecStart=/bin/sh -c 'docker ps --filter "name=apisix-dc1-" --format "{{.Names}}" | xargs docker restart'
```

### 12.8 Systemd Path Watcher — Hard-restart cho release/system

Config hệ thống (`config-dc*.yaml`) không hot-reload được — cần `docker restart`. Không để git-sync gọi lệnh Docker từ bên trong container (vi phạm security), thay vào đó dùng systemd trên Host OS làm bridge.

**`/etc/systemd/system/apisix-config-watcher.path`**

```ini
[Unit]
Description=Watch APISIX system config changes (release/system branch)
After=docker.service

[Path]
# Theo dõi file cố định mà exechook của git-sync-config ghi ra
# (dùng PathModified, không dùng PathChanged — inotify không theo symlink)
PathModified=/opt/apisix/standalone/sandbox/conf_system/config-dc1.yaml
Unit=apisix-config-watcher.service

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/apisix-config-watcher.service`**

```ini
[Unit]
Description=Hard-restart APISIX after release/system branch change
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
# Debounce 5s — đợi git-sync hoàn tất atomic symlink swap
# Tránh APISIX đọc file trong trạng thái transition
ExecStartPre=/bin/sleep 5
ExecStartPre=/bin/sh -c 'echo "[$(date -Iseconds)] Triggering hard-restart: config changed" | systemd-cat -t apisix-config-watcher'
ExecStart=/usr/bin/docker restart apisix-profile-dc1
ExecStartPost=/bin/sh -c 'echo "[$(date -Iseconds)] Restart complete" | systemd-cat -t apisix-config-watcher'
StandardOutput=journal
StandardError=journal
SyslogIdentifier=apisix-config-watcher
TimeoutStartSec=90
```

```bash
# Kích hoạt
sudo systemctl daemon-reload
sudo systemctl enable --now apisix-config-watcher.path

# Verify
systemctl status apisix-config-watcher.path
# Expected: active (waiting)
```

### 12.9 SSH Deploy Keys cho GitLab Self-hosted

```bash
# Tạo 2 deploy keys riêng biệt (không dùng key cá nhân)
ssh-keygen -t ed25519 -C "git-sync-apisix-dc1@$(hostname)" \
  -f /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_apisix -N ""

ssh-keygen -t ed25519 -C "git-sync-config-dc1@$(hostname)" \
  -f /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_config -N ""

# Lấy known_hosts từ GitLab server
ssh-keyscan -H gitlab.internal > /opt/apisix/standalone/sandbox/secrets/ssh/known_hosts

# Fix permission cho git-sync UID 65533
sudo chown -R 65533:65533 /opt/apisix/standalone/sandbox/secrets/ssh/
sudo chmod 700 /opt/apisix/standalone/sandbox/secrets/ssh/
sudo chmod 600 /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_*
sudo chmod 644 /opt/apisix/standalone/sandbox/secrets/ssh/known_hosts

# In public keys để thêm vào GitLab
cat /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_apisix.pub
cat /opt/apisix/standalone/sandbox/secrets/ssh/id_rsa_config.pub
```

**Thêm vào GitLab:**
```
Project: apisix-config → Settings → Repository → Deploy Keys

Key 1: git-sync-apisix-dc1   [paste id_rsa_apisix.pub]   ✅ Read-only
Key 2: git-sync-config-dc1   [paste id_rsa_config.pub]   ✅ Read-only
```

> ⚠️ **Không cấp Write**. Deploy key chỉ cần pull. Key riêng per DC: DC1 và DC2 dùng key khác nhau.

### 12.10 CI/CD Pipeline — Validate trước khi Merge

git-sync kéo file về sau khi merge. CI là lớp bảo vệ **trước** khi merge vào branch release. [.gitlab-ci.yml](.-/blob/main/.gitlab-ci.yml)

### 12.11 Behavior theo loại file thay đổi

```
Commit thay đổi file        | git-sync action           | APISIX action
─────────────────────────────────────────────────────────────────────────────
release/routes:
  fragments/routes/*.yaml     compile → apisix-dc1.yaml  hot-reload < 1s ✅
  fragments/upstreams/*.yaml  compile → apisix-dc1.yaml  hot-reload < 1s ✅
  apisix-dc1.yaml (compiled)  git-sync pull → exechook    hot-reload < 1s ✅
  apisix-dc2.yaml (compiled)  git-sync pull → exechook    hot-reload < 1s ✅

release/system:
  config-dc1.yaml             git-sync pull → exechook   systemd detect →
                               → copy ra /conf_system/    docker restart DC1 ⚠️
  config-dc2.yaml             git-sync pull → exechook   docker restart DC2 ⚠️

Không thuộc 2 branch trên:
  README.md, scripts/         Không bị kéo về           Không có gì

⚠️ docker restart: downtime ~5-10s
   → Chỉ merge release/system ngoài giờ cao điểm
   → Thông báo trước trên kênh incident response
   → apisix-dc*.yaml (release/routes): thay đổi bất kỳ lúc nào
```

### 12.12 End-to-End: Vòng đời 1 commit từ phím đến APISIX

```
1. Engineer tạo fragment mới: fragments/routes/route-tenant-c-dc1.yaml
   → git push lên branch feature/add-tenant-c
   → Mở MR nhắm vào release/routes

2. CI Pipeline tự kích hoạt:
   → yamllint: kiểm tra syntax
   → compile.py: gộp fragments → dist/apisix-dc1.yaml
   → apisix test: validate Lua schema (dry-run không cần APISIX thật)
   → Pipeline GREEN ✅

3. Tech Lead review + Approve MR → Merge vào release/routes

4. git-sync-apisix (poll 30s) phát hiện commit mới:
   → git pull delta (chỉ tải phần thay đổi, không clone lại)
   → Tạo thư mục rev-abc1234/ với nội dung mới
   → Đổi symlink: current → rev-abc1234/ (atomic)
   → Chạy exechook: cp current/apisix-dc1.yaml → apisix-dc1.yaml

5. APISIX watch mtime (mỗi 1s) phát hiện apisix-dc1.yaml thay đổi:
   → Parse YAML mới
   → Guardrail: nếu thiếu #END hoặc lỗi syntax → reject, giữ config cũ ✅
   → Nếu OK: graceful nginx reload → route mới active
   → Log: "config file apisix-dc1.yaml reloaded."
   → Toàn bộ quá trình: < 1 giây, ZERO downtime

Thời gian tổng: CI (~3-5 phút) + Review + poll lag (0–30s) + reload (< 1s)
```

### 12.13 Rollback

```bash
# === Tầng 1: git revert (< 5 phút, có audit trail) ===
git checkout release/routes
git revert <bad-commit-hash> --no-edit
git push origin release/routes
# git-sync detect trong ≤ 30s → exechook → APISIX hot-reload

# === Tầng 2: Manual emergency (< 1 phút, khi CI quá chậm) ===
# Trên host: dùng revision cũ mà git-sync đã lưu
ls /opt/apisix/standalone/sandbox/conf_routes/
# drwxr-xr-x rev-abc1234/   ← current (lỗi)
# drwxr-xr-x rev-def5678/   ← revision tốt trước đó

# Copy file tốt ra đường dẫn APISIX đọc (giữ inode → hot-reload)
cp /opt/apisix/standalone/sandbox/conf_routes/rev-def5678/apisix-dc1.yaml \
   /opt/apisix/standalone/sandbox/conf_routes/apisix-dc1.yaml

# Verify
sleep 2
docker logs apisix-profile-dc1 --since 5s 2>&1 | grep "reloaded"
# Expected: "config file apisix-dc1.yaml reloaded."
```

> **Lợi thế lớn so với webhook:** git-sync tự động giữ lại N revision gần nhất trên disk (mặc định 5). Emergency rollback không cần backup script, không cần SSH vào Git server.

### 12.14 Verify và Monitor

```bash
# === Verify toàn bộ stack ===

# 1. Container health
docker ps --format "table {{.Names}}\t{{.Status}}"
# Expected: apisix-profile-dc1: healthy | git-sync-apisix: Up | git-sync-config: Up

# 2. git-sync đã sync chưa
ls -la /opt/apisix/standalone/sandbox/conf_routes/
# Phải thấy: current → rev-XXXXX (symlink)
cat /opt/apisix/standalone/sandbox/conf_routes/sync.log | tail -5

# 3. APISIX đã hot-reload chưa (sau khi push release/routes)
docker logs apisix-profile-dc1 --since 60s 2>&1 | grep -E "reloaded|error|parse"
# Expected: "config file apisix-dc1.yaml reloaded."

# 4. systemd watcher (cho release/system)
systemctl status apisix-config-watcher.path
# Expected: active (waiting)
journalctl -u apisix-config-watcher.service -n 10

# 5. S3 routing verify (từ TC-00-7 Finding 3)
curl -s -o /dev/null -w "DC1 S3 HCM: HTTP %{http_code}\n" \
  -H "Host: s3.hcm.sds.vnpaycloud.vn" http://localhost:9080/
curl -s -H "Host: api.ekyc.sds.vnpaycloud.vn" http://localhost:9080/ekyc/ \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('APISIX 404:', d.get('error_msg',''))"
# DC1 S3: 200 ✅ | DC1 eKYC: route tồn tại | DC2 eKYC: 404 Route Not Found ✅
```

### 12.15 Giới hạn của git-sync (honest assessment)

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

## 13. Plugin List — Quy hoạch cho S3 Gateway

### 13.1 Danh sách plugin trong config thực tế từ lab
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

### 13.2 Phân loại theo S3 use case

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

### 13.3 config-dc1.yaml — Plugin list tối ưu cho S3

> File [config-dc1.yaml](../-/blob/release/system/config-dc1.yaml)

```yaml
# config-dc1.yaml — Production S3 Gateway DC1
apisix:
  node_listen: 9080
  enable_ipv6: false

deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml

nginx_config:
  worker_processes: 2
  worker_rlimit_nofile: 65536
  event:
    worker_connections: 16384

plugin_attr:
  prometheus:
    export_addr:
      ip: "0.0.0.0"
      port: 9091
    export_uri: /apisix/prometheus/metrics

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

### 13.4 config-dc2.yaml — Plugin list tối ưu cho S3

DC2 chỉ có S3 HNI, không có eKYC. Plugin list có thể slim hơn DC1 nếu DC2 không cần một số tính năng. 
> File [config-dc2.yaml](../-/blob/release/system/config-dc2.yaml)


```yaml
# config-dc2.yaml — Production S3 Gateway DC2 (S3 only)
# Slim hơn DC1: bỏ fault-injection, traffic-split (không test canary ở DC2)

plugins:
  # === CORE ===
  - real-ip
  - request-id
  - prometheus
  - ip-restriction
  - cors
  - proxy-rewrite
  - ceph-rados-regex

  # === ON-DEMAND ===
  - limit-req
  - limit-count
  - limit-conn
  - client-control
  - proxy-control
  - redirect
  - response-rewrite
  - request-validation
  - api-breaker
  - key-auth

  # DC2 không cần:
  # - traffic-split       # canary chỉ test ở DC1
  # - fault-injection     # chaos testing chỉ ở staging/DC1
```

### 13.5 Kích hoạt plugin theo route — pattern S3

Plugin load trong `config.yaml` chỉ là **danh sách được phép load**. Plugin thực sự hoạt động phải được khai báo trong `apisix-dc1.yaml` trên từng route.
> File [apisix-dc1.yaml](../-/blob/release/routes/apisix-dc1.yaml)

```yaml
# apisix-dc1.yaml — Plugin kích hoạt per route

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

### 13.6 Warning đặc biệt: Plugin ảnh hưởng S3 protocol

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

### 13.7 Plugin đặc biệt: ceph-rados-regex

Plugin này là core business logic, không thể bỏ. File đang dùng trong lab:

```
/opt/apisix/standalone/sandbox/plugins/custom/ceph-rados-regex.lua

Chức năng:
  CASE 1 - Virtual-host style:
    Input:  bucket.s3.hcm.lab.thuyldx/key
    Validate: bucket phải match ^%w+-[%w-]*%w+$
    Rewrite: URI /key → /bucket/key
    Rewrite: Host → s3.hcm.lab.thuyldx (path-style cho Ceph)

  CASE 2 - Path style:
    Input:  s3.hcm.lab.thuyldx/bucket/key
    Validate: bucket trong URI phải match pattern
    Pass through nếu URI là / (list all buckets)

  Reject (HTTP 400):
    - Missing Host header
    - Invalid vhost format
    - Bucket name không match pattern

Porting từ: cloudian-regex.lua (NGINX + Cloudian)
```

**Khi thay đổi `ceph-rados-regex.lua`:**

```
File .lua thay đổi → KHÔNG được hot-reload bởi APISIX → cần docker restart

Với git-sync (v4):
  → git-sync-apisix KHÔNG theo dõi plugins/ (chỉ theo release/routes)
  → Để deploy plugin mới: cần commit vào release/system
  → git-sync-config kéo về → exechook copy → systemd watcher detect
  → docker restart apisix-profile-dc1

Downtime khi restart: ~5-10s per container
→ Nên đổi plugin ngoài giờ cao điểm
→ Hoặc: rolling restart (restart DC2 trước, verify, sau đó restart DC1)
```

### 13.8 Tóm tắt quy hoạch plugin

```
Load mặc định (7 plugin CORE):
  real-ip, request-id, prometheus, ip-restriction,
  cors, proxy-rewrite, ceph-rados-regex

Load sẵn, kích hoạt theo route (11 plugin ON-DEMAND):
  limit-req, limit-count, limit-conn,
  client-control, proxy-control,
  redirect, response-rewrite, request-validation,
  api-breaker, traffic-split, key-auth

Không load (bỏ khỏi plugins list):
  ua-restriction, referer-restriction,
  jwt-auth, basic-auth, openid-connect,
  hmac-auth, authz-keycloak,
  grpc-transcode, zipkin,
  fault-injection (production — chỉ staging)

Nguyên tắc:
  Plugin không load = không tốn memory, không thể bị kích hoạt nhầm
  Plugin load nhưng không khai báo trên route = load vào memory nhưng không chạy
  Plugin khai báo trên route = chạy trên mọi request qua route đó
```



