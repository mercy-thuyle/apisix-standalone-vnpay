# Kiến trúc thư mục tại local mỗi DC
```
/opt/apisix/standalone/sandbox/
│
├── gitsync/                                      ← GITSYNC_ROOT, 65533 tự quản, KHÔNG touch
│   ├── current -> .worktrees/1e74...36d5         ← symlink atomic, git-sync tự quản, KHÔNG touch
│   │   ├── .git
│   │   ├── apisix_config/
│   │   ├── apisix_routes/
│   │   ├── certs/
│   │   │   ├── <domain>.cert
│   │   │   └── <domain>.key.enc
│   │   ├── plugins/
│   │   ├── scripts/
│   │   ├── .yamllint.yaml
│   │   ├── docker-compose.yaml
│   │   └── README.md
│   └── sync.log                     
│
├── apisix_config/
│   └── config-dc1.yaml                           ← APISIX đọc và mount file này, nội dung update thay đổi trên gitlab sau đó tạo change,
│                                                   admin copy về local file này và deploy thủ công (lint syntax, logic, dry-run, restart docker container...
│                                                   hoặc combo systemd watcher theo dõi + tự động restart docker container)
├── apisix_routes/
│   └── apisix-dc1.yaml                           ← gitsync.sh ghi ra, APISIX đọc và mount file này
│
├── certs/                                        ← admin KHÔNG chỉnh tay — 2-decrypt-certs.sh ghi ra, APISIX mount, restart khi đổi
│   ├── s3-hcm.sds.infiniband.vn.cert             ← cp từ gitsync
│   ├── s3-hcm.sds.infiniband.vn.key              ← 2-decrypt-cert.sh ghi ra
│   ├── s3-hni.sds.infiniband.vn.cert             ← cp từ gitsync
│   └── s3-hni.sds.infiniband.vn.key              ← 2-decrypt-cert.sh ghi ra
│
├── plugins/                                      ← deploy thủ công, restart khi thay đổi
│   ├── custom/                                   ← Custom APISIX Lua plugins
│   │   ├── s3-normalizer-bucket-name.lua         ← APISIX plugin — S3 API gateway — normalize vhost→path, validate bucket
│   │   └── cmc-validator-bucket-name.lua         ← APISIX plugin — CMC Portal — validate bucket name khi tạo bucket qua UI
│   │
│   └── libraries/                                ← Pure Lua (utility module) shared plugins library
│       └── s3-validator-bucket-name-utils.lua    ← Lua library — validate bucket name & domain
│
├── scripts/
│   ├── debug/                                    ← tool troubleshoot, chạy tay khi cần, không mount vào container
│   │   ├── debug-s3-logicwlua.py                 ← debug S3 normalizer plugin logic (Lua)
│   │   └── debug-s3v4-curl.sh                    ← generate curl command với AWS Signature V4
│   ├── deploy/                                   ← chạy có chủ đích bởi admin, không trigger tự động
│   │   ├── 1-patch-template-lua.sh               ← chạy 1 lần khi deploy hoặc upgrade APISIX
│   │   ├── 2-encrypt-certs.sh                    ← chạy trên máy admin trước khi commit cert lên repo
│   │   ├── 2-decrypt-certs.sh                    ← chạy 1 lần khi deploy hoặc đổi cert
│   │   ├── 3-inject-certs.sh                     ← chạy 1 lần khi deploy hoặc đổi cert
│   │   └── deploy.sh                             ← entry point: patch lua → decrypt certs → compose up
│   ├── libraries/                                ← shared lib, không chạy trực tiếp
│   │   └── cert-domains.sh                       ← danh sách cert domains, lib dùng chung cho 2-decrypt-certs.sh và 3-inject-certs.sh
│   └── runtime/                                  ← được mount vào gitsync container, trigger tự động sau mỗi git sync
│       ├── gitsync.sh                            ← exechook của git-sync, detect layout và gọi merge-fragments.sh
│       └── merge-fragments.sh                    ← validate + gộp upstreams/routes/ssls thành apisix-${DC_PROFILE}.yaml
│
├── logs/
│   └── apisix-dc1/                               ← 1 log dir per VM tại mỗi DC
│
├── secrets/
│   └── .netrc                                    ← GitLab HTTPS auth (có trong .gitignore, KHÔNG commit), chmod 600
│
├── init.lua                                      ← patched — đã xóa set_header X-Forwarded-Port, tạo bởi 1-patch-template-lua.sh
├── init.lua.orig                                 ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── ngx_tpl.lua                                   ← patched — đã xóa proxy_set_header X-Forwarded-Port, tạo bởi 1-patch-template-lua.sh
├── ngx_tpl.lua.orig                              ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── .yamllint.yaml                                ← yamllint rule config — nới lỏng line-length/comment style, giữ error cho trailing-spaces/key-duplicates/newline
├── .env                                          ← DC_PROFILE=dc1 | dc2 và CERT_PASSPHRASE cho encrypt/decrypt (có trong .gitignore, KHÔNG commit)
├── .gitignore
└── docker-compose.yml
```

# Prerequisites
```bash
# OS Timezone
sudo timedatectl set-timezone Asia/Ho_Chi_Minh
timedatectl | grep "Time zone"
## Expected: Time zone: Asia/Ho_Chi_Minh (+07, +0700)
```

```bash
# OS Update
sudo apt-get -y update && sudo apt-get -y upgrade
```

```bash
# Python3
sudo apt install -y python3 python3-pip
python3 --version
## Expected: Python 3.10.x
```

```bash
# YAML / LUA syntax
# Cài yamllint nếu chưa có
pip3 install yamllint
# hoặc
sudo apt install yamllint -y

# Cài luac nếu chưa có (Lua compiler)
# lua5.1 hoặc lua5.4
sudo apt install lua5.1 -y
```

```bash
# Docker
curl -fsSL https://get.docker.com -o - | bash 
sudo apt update

## Install
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl status docker | grep Active
## Expected: Active: active (running)

docker --version
## Expected: Docker version 29.x.x, build xxxxxxx

docker compose version
## Expected: Docker Compose version v2.x.x

## Thêm user ubuntu vào group docker để không cần sudo
sudo chmod 666 /var/run/docker.sock
sudo usermod -aG docker ${USER}
su - ${USER}
# Verify: docker ps (không cần sudo)
```

# Tạo cấu trúc thư mục 
```bash
mkdir -p /opt/apisix/standalone/sandbox
cd /opt/apisix/standalone/sandbox
mkdir -p \
  gitsync \
  apisix_config \
  apisix_routes \
  certs \
  plugins/custom \
  plugins/libraries \
  scripts/runtime \
  scripts/deploy \
  scripts/libraries \
  scripts/debug \
  logs/apisix-dc1 \
  secrets
```

# .env 
```bash
# random-strong-passphrase
# base64 — 32 bytes → 44 chars (mặc định có thể có +/=)
openssl rand -base64 32

# hex — 32 bytes → 64 hex chars (chỉ có 0-9a-f, không có ký tự đặc biệt)
openssl rand -hex 32

cat > .env << 'EOF'
DC_PROFILE=dc1
CERT_PASSPHRASE=<random-strong-passphrase>
EOF
```

# File bootstrap (cần tồn tại trước khi doker compose up)
> Tạo Access Token **glpat-xxxxxxxxxxxxxxxxxxxx** trên repo với permission **read-repository**.

```bash
cat > secrets/.netrc << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-xxxxxxxxxxxxxxxxxxxx
EOF
```
> File [docker-compsoe.yaml](./docker-compose.yaml)
> File [.yamllint.yaml](./.yamllint.yaml)
> File [scripts/gitsync.sh](./scripts/gitsync.sh)
> File [scripts/1-patch-template-lua.sh](./scripts/1-patch-template-lua.sh)
> File [scripts/2-decrypt-certs.sh](./scripts/2-decrypt-certs.sh)
> File [scripts/3-inject-certs.sh](./scripts/3-inject-certs.sh)
> File [plugins/custom/s3-normalizer-bucket-name.lua](./plugins/custom/s3-normalizer-bucket-name.lua)
> File [plugins/libraries/s3-validator-bucket-name-utils.lua](./plugins/libraries/s3-validator-bucket-name-utils.lua)

# Phân quyền
```bash
# git-sync (UID 65533), APISIX (UID 636)
sudo chown -R 65533:65533 gitsync/ apisix_routes/ apisix_config/ scripts/ secrets/ plugins/
# sudo chown -R 65533:65533 docker-compose.yaml
sudo chown -R 636:636 logs/
# sudo chown -R root:root plugins/ certs/ apisix_config
sudo chmod -R 755 gitsync/ apisix_routes/ apisix_config/ logs/ scripts/
sudo chmod 755 certs/ && sudo find plugins/ -type d -exec chmod 755 {} \;
sudo chmod 700 secrets/
sudo chmod 644 certs/*.cert && sudo find plugins/ -type f -name "*.lua" -exec chmod 644 {} \;
sudo chmod 600 secrets/.netrc certs/*.key
sudo find scripts/ -name "*.sh" -exec chmod +x {} \;
```

# Deploy
```bash
docker compose up -d
# hoặc
docker compose -f /opt/apisix/standalone/sandbox/docker-compose.yaml up -d
```

# Cập nhật cert / Patch Lua
## Đổi cert

```bash
# 1. Copy cert mới vào certs/
cp new.cert certs/s3-hcm.sds.infiniband.vn.cert
chmod 644 certs/s3-hcm.sds.infiniband.vn.cert

# 2. Inject lại vào apisix-dc1.yaml
./scripts/3-inject-certs.sh

# 3. Commit apisix-dc1.yaml lên GitLab → git-sync tự pull về → hot-reload
```

## Hot-reload (không cần restart)

Commit thay đổi vào `apisix_routes/apisix-dcX.yaml` trên GitLab → git-sync pull về trong ≤30s → APISIX hot-reload tự động.

## Cần restart

Khi thay đổi:
- `apisix_config/config-dc1.yaml` → cấu hình hệ thống
- `plugins/*.lua`                 → custom plugin
- `ngx_tpl.lua` / `init.lua`      → update apisix version

```bash
docker compose up -d --force-recreate
```

### Scale-out

```bash
# 1. Provision VM mới, clone cấu trúc từ VM hiện tại
# 2. Chạy các bước setup (Section 4)
# 3. Verify routing OK
curl -s -H "Host: s3-hcm.sds.infiniband.vn" http://localhost:80/
# 4. Báo IP cho Infrastructure Team thêm vào LB pool
```

# Upgrade APISIX version

```bash
# 1. Chạy lại patch với image mới
IMAGE="apache/apisix:3.17.0-debian" bash 1-patch-template-lua.sh

# 2. Verify diff
diff ngx_tpl.lua.orig ngx_tpl.lua

# 3. Đổi image tag trong docker-compose.yaml
# 4. Restart
docker compose up -d --force-recreate
```

# Rollback

```bash
# Cách 1: git revert trên GitLab → git-sync tự detect trong ≤30s

# Cách 2: rollback thủ công ngay lập tức
ls gitsync/.worktrees/
cp gitsync/.worktrees/<good-hash>/gitsync/apisix-dc1.yaml \
   gitsync/apisix_routes/apisix-dc1.yaml
```

# Plugin — S3 Gateway
## Phân loại theo S3 use case

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


## Plugin list tối ưu cho S3

```yaml
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

## Quy hoạch plugin:

```
Load mặc định (7 plugin CORE): real-ip, request-id, prometheus, ip-restriction, cors, proxy-rewrite, ceph-rados-regex

Load sẵn, kích hoạt theo route (11 plugin ON-DEMAND): limit-req, limit-count, limit-conn, client-control, proxy-control, redirect, response-rewrite, request-validation, api-breaker, traffic-split, key-auth

Không load (bỏ khỏi plugins list): ua-restriction, referer-restriction, jwt-auth, basic-auth, openid-connect, hmac-auth, authz-keycloak, grpc-transcode, zipkin, fault-injection (production — chỉ staging)
```

> Nguyên tắc:
>   Plugin không load = không tốn memory, không thể bị kích hoạt nhầm
>   Plugin load nhưng không khai báo trên route = load vào memory nhưng không chạy
>   Plugin khai báo trên route = chạy trên mọi request qua route đó

# Troubleshoot

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| Container crash loop | Volume mount sai tên file | Kiểm tra tên file khớp `APISIX_PROFILE` |
| APISIX không hot-reload dù file đã thay đổi | exechook fail → file không được copy | `docker logs gitsync --tail 20 \| grep "hook failed"` |
| `missing valid end flag` | File thiếu `#END` hoặc YAML lỗi | Fix file → hot-reload tự động, KHÔNG restart |
| `failed to open file: config-dc1.yaml` | Volume mount sai tên | Tên file phải có profile suffix `-dc1` |
| `fork/exec /bin/cp: no such file or directory` | git-sync exec không qua shell, space trong args bị parse sai | Dùng wrapper script `gitsync.sh` |
| `Is a directory` khi load plugin | Docker tạo directory thay vì file khi mount target chưa tồn tại trên host | `rm -rf plugins/ceph-rados-regex.lua && cp file.lua plugins/` rồi `docker compose down && up` |
| `413 Request Entity Too Large` | `client_max_body_size: 10m` quá nhỏ cho S3 upload | Set `client_max_body_size: 0` trong `config-dc1.yaml` |
| git-sync `HTTP Basic: Access denied` | `GITSYNC_GIT_CONFIG: credential.helper=store` sai format | Xóa dòng đó, mount `.netrc` vào `/tmp/.netrc` |
| exechook copy thủ công OK nhưng tự động fail | Permission: file đích owner là `root` | `sudo chown 65533:65533 apisix_*/` |
|current khớp nhưng git-sync chưa update được|git-sync lỗi hoặc down| `docker exec gitsync /bin/cp /tmp/sync/current/{config/apisix}-{PROFILE}.yaml /tmp/sync/apisix_{config/routes}/{config/apisix}-{PROFILE}}.yaml && echo "OK"`|
| `fork/exec /tmp/gitsync.sh: no such file or directory` | Mount source là directory thay vì file | `rm -rf scripts/gitsync.sh && cat > scripts/gitsync.sh` |
| `fork/exec /tmp/gitsync.sh: permission denied` | Thiếu execute bit hoặc sai owner | `chmod +x scripts/gitsync.sh && chown 65533:65533 scripts/gitsync.sh` |
| `/bin/sh: 0: cannot open X: No such file` | Shebang sai — có argument sau `/bin/sh` | Sửa thành `#!/bin/sh` không có gì theo sau |
| `couldn't find remote ref master` | Branch tên `master` không tồn tại | Đổi `GITSYNC_REF: "main"` |
| `cp: cannot create regular file: Permission denied` | File đích chưa chown 65533 | `sudo chown 65533:65533 <file>` |
| `413 Request Entity Too Large` | `client_max_body_size` quá nhỏ | Set `client_max_body_size: 0` |
| `Is a directory` khi load plugin | Docker tạo dir thay vì file khi mount | `rm -rf <file>; touch <file>; docker compose down && up` |
| `HTTP Basic: Access denied` | `.netrc` sai format hoặc sai path | Mount `.netrc` vào `/tmp/.netrc` |
| git-sync pull xong nhưng APISIX chưa reload | exechook fail → file không được copy | `docker logs gitsync --tail 20` |

# Kiểm tra stack health

```bash
# Container status
docker ps --format "table {{.Names}}\t{{.Status}}"

# git-sync đã pull commit mới chưa
readlink gitsync/current   # hash phải khớp GitLab

# File đã copy ra chưa
ls -la apisix_routes/
cat apisix_routes/apisix-dc1.yaml | head -3

# APISIX routing OK
curl -s -H "Host: s3-hcm.sds.infiniband.vn" http://localhost:80/ | head -1
curl -sk -H "Host: s3-hcm.sds.infiniband.vn" https://localhost:443/ | head -1

# Logs
tail -f logs/apisix-dc1/access.log
docker logs gitsync --tail 5
docker logs gitsync --tail 5
```