# Prerequisites
```bash
# OS Timezone
sudo timedatectl set-timezone Asia/Ho_Chi_Minh
timedatectl | grep "Time zone"
## Expected: Time zone: Asia/Ho_Chi_Minh (+07, +0700)

# OS Update
sudo apt-get -y update && sudo apt-get -y upgrade
```

> **[ADD]** Nên reboot sau upgrade kernel để đảm bảo kernel mới được load.

```bash
# Upgrade HWE kernel (Ubuntu 22.04)
sudo apt update && sudo apt install -y linux-generic-hwe-22.04
sudo reboot
## Reboot sau bước này nếu kernel version thay đổi
## Verify kernel sau reboot
uname -r
## Expected: 6.x.x-xx-generic (HWE kernel)
```

```bash
# Python3
sudo apt install -y python3
python3 --version
## Expected: Python 3.10.x
```

```bash
# Docker
## Gỡ package cũ (nếu có)
sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)

#Cài đặt từ official apt repo
## GPG key
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

## Add repository
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

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

> **[ADD]** Checklist nhanh — chạy trên từng VM để confirm sẵn sàng. Kiểm tra môi trường trước khi bắt đầu

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

# Kiến trúc thư mục tại local
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

# docker-compose.yaml
> File [docker-compsoe.yaml](../-/blob/main/docker--compose.yaml)
```bash
docker compose -f /opt/apisix/standalone/sandbox/docker-compose.yaml up -d
```

# .env :
```bash
cat > .env << 'EOF'
DC_PROFILE=dc1
EOF
```

# Tạo cấu trúc thư mục 
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

# File bootstrap (cần tồn tại trước khi doker compose up)
> Tạo Access Token **glpat-xxxxxxxxxxxxxxxxxxxx** trên project với permission **read-repository**.

```bash
cat > secrets/.netrc << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-xxxxxxxxxxxxxxxxxxxx
EOF
```

> File [scripts/gitsync.sh](-/blob/main/scripts/gitsync.sh)

# Phân quyền
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

# Validate syntax trước khi merge

- yamllint apisix-dc1.yaml apisix-dc2.yaml
- python3 scripts/compile.py --validate
- docker run apache/apisix:3.15.0-debian apisix test -c apisix-dc1.yaml

> Không merge nếu:
  > YAML syntax lỗi
  > Thiếu #END flag
  > Route trùng ID
  > Upstream không resolve được

# Kiểm tra stack health

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

## Warning — Plugin ảnh hưởng S3 SigV4

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

# Troubleshoot

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
