# Kiến trúc thư mục tại local mỗi DC
```
/opt/apisix/standalone/sandbox/
│
├── gitsync/                                      ← GITSYNC_ROOT, 65533 tự quản, KHÔNG touch
│   ├── .git
│   ├── .worktrees
│   └── current -> .worktrees/1e74...36d5         ← symlink atomic, git-sync tự quản, KHÔNG touch
│       ├── .git
│       ├── .gitignore
│       ├── .yamllint.yaml
│       ├── README.md
│       ├── apisix_config/
│       ├── apisix_routes/
│       ├── certs/
│       │   ├── <domain>.cert
│       │   └── <domain>.key.enc
│       ├── dashboard/
│       ├── docker-compose.yaml
│       ├── grafana-dashboard.json
│       ├── plugins/
│       ├── prometheus.yaml
│       ├── redis.conf
│       ├── samples/
│       └── scripts/
│
├── apisix_config/
│   └── config-hcm.yaml                           ← APISIX đọc và mount file này, nội dung update thay đổi trên gitlab sau đó tạo change,
│                                                   admin copy về local file này và deploy thủ công (lint syntax, logic, dry-run, restart docker container...
│                                                   hoặc combo systemd watcher theo dõi + tự động restart docker container)
│
├── apisix_routes/                                ← thư mục gốc chứa toàn bộ fragments, được merge thành apisix-${DC_PROFILE}.yaml bởi merge-fragments.sh
│   ├── consumer_groups/                          ← gói policy cho consumer, FLAT
│   │   └── <group-id>.yaml                       ← 1 file = 1+ consumer_group, key bắt buộc: "consumer_groups:"
│   │                                             ⚠ 2 NHÁNH dùng CHUNG 1 folder, tách biệt hoàn toàn về cơ chế resolve:
│   │                                                - Control-plane (key-auth, theo API credential)
│   │                                                - S3 data-plane resolve qua custom.s3-qos-consumer, KHÔNG qua key-auth/SigV4.
│   │                                                - Đây là nhánh ĐANG DÙNG hiện tại: 8 group cố định, 2 trục độc lập.
│   │                                                  · Trục Cấp dữ liệu (steady-state):
│   │                                                     consumer-group-s3-tier4-mission-critical.yaml (50 req/60s)
│   │                                                     consumer-group-s3-tier3-business-critical.yaml (500)
│   │                                                     consumer-group-s3-tier2-standard.yaml (300)
│   │                                                     consumer-group-s3-tier1-archive.yaml (1000)
│   │                                                     → gộp cả 4 trong 1 file consumer-group-s3-tiers.yaml
│   │                                                  · Trục xử lý vận hành (chuyển tạm thời):
│   │                                                     consumer-group-s3-boost.yaml (2000, nới quota sự kiện hợp lệ)
│   │                                                     consumer-group-s3-lockdown.yaml (2, siết khẩn cấp)
│   │                                                     consumer-group-s3-incident.yaml (20, đang điều tra)
│   │                                                     consumer-group-s3-event.yaml (800, sự kiện có kế hoạch)
│   │                                                  · Group tạm thời (1 sự kiện/incident cụ thể cần ngưỡng riêng,
│   │                                                     khác pool chung): thêm hậu tố, VD: consumer-group-s3-incident-1545.yaml, consumer-group-s3-event-pay2go3.yaml
│   │                                                     — XOÁ khi xong việc, đưa Consumer về lại group cố định phù hợp.
│   │
│   ├── consumers/                                ← account/service gán vào group_id, FLAT
│   │   └── <username>.yaml                       ← 1 file = 1+ consumer, key bắt buộc: "consumers:"
│   │                                             ⚠ 2 NHÁNH dùng CHUNG 1 folder, khác nhau về việc có credential hay không:
│   │                                                - Control-plane (key-auth, chứa credential thật)
│   │                                                  → PHẢI dùng $env:// hoặc encrypt, KHÔNG commit plaintext — hiện KHÔNG còn file nào thuộc nhánh này
│   │                                                - S3 data-plane, plugin custom.s3-qos-consumer, KHÔNG chứa credential (bucket name/IP vốn public, không cần encrypt)
│   │                                                - Đây là nhánh ĐANG DÙNG hiện tại: 3 loại username, tách theo 3 file riêng,
│   │                                                  thứ tự ưu tiên khi cùng khớp 1 request là combo > bucket > snat-ip:
│   │                                                    · consumer-s3-bucketname.yaml — username "bucket-<tên-bucket>"
│   │                                                    · consumer-s3-snatip.yaml     — username "snatip-<ip-gạch-nối>"
│   │                                                    · consumer-s3-bucketsnat.yaml — username "bucketsnat-<bucket>-<ip-gạch-nối>"
│   │
│   ├── global_rules/                             ← guard chống abuse, áp cho MỌI route, FLAT
│   │   └── <rule-id>.yaml                        ← 1 file = 1+ global_rule, key bắt buộc: "global_rules:"
│   │                                             ⚠ KHÔNG nằm trong chuỗi override Route>PluginConfig>Service — plugin cùng tên ở global_rule và route/service CHẠY CẢ HAI, tuần tự (không bị đè)
│   │                                                
│   ├── plugin_configs/                           ← [MỚI] QoS bundle (limit-count/limit-conn/api-breaker/soft-limit) theo workload, FLAT
│   │   └── <plugin-config-id>.yaml               ← 1 file = 1+ plugin_config, key bắt buộc: "plugin_configs:"
│   │
│   ├── routes/                                   ← GROUPED, nhưng subfolder giờ theo WORKLOAD (không phải domain/service như cũ)
│   │   └── <workload>/                               ← vd: hyperstore-cloudian/, ceph-rados/, ecr/,...
│   │       └── <route-id>.yaml                   ← 1 file = 1 hoặc nhiều route entity, key bắt buộc: "routes:"
│   │                                                Khai service_id (trỏ upstream) + plugin_config_id (trỏ QoS)
│   │                                                KHÔNG khai vars scheme/server_port nếu nginx gốc không phân biệt
│   │                                                (xác nhận từng domain qua nginx-full-config.txt trước khi gộp — không suy đoán)
│   │                                                Domain không thuộc workload nào (debug/lab/test) → giữ nguyên tên folder cũ, không ép vào workload — không tham gia kiến trúc QoS-group
│   │
│   ├── services/                                 ← FLAT — 1 service = 1:1 upstream_id, KHÔNG chứa QoS plugin
│   │   └── <service-id>.yaml                     ← 1 file = 1+ service, key bắt buộc: "services:"
│   │                                             ⚠ Đổi kiến trúc: trước đây service gộp nhiều upstream theo QoS-tier, giờ mỗi service map thẳng 1 upstream (service-upstream-<backend>)
│   │
│   ├── ssls/                                     ← tập hợp SSL cert fragments, FLAT — không đổi
│   │   └── <ssl-id>.yaml                         ← 1 file = 1 hoặc nhiều ssl entity, key bắt buộc: "ssls:"
│   │
│   └── upstreams/                                ← FLAT (đổi từ grouped sang flat) — 1 upstream = 1 backend vật lý, tên file = id
│       └── <upstream-id>.yaml                    ← 1 file = 1 hoặc nhiều upstream entity, key bắt buộc: "upstreams:"
│                                                    ⚠ KHÔNG chứa plugins (schema không có field này) — thuần LB/health-check/TLS
│
├── certs/                                       ← admin KHÔNG chỉnh tay — 2-decrypt-certs.sh ghi ra, APISIX mount, restart khi đổi
│   ├── kafka.crt                                ← cp từ gitsync
│   ├── ca-certificates.crt                       ← cp từ gitsync
│   ├── infiniband.vn.cert                        ← cp từ gitsync
│   ├── infiniband.vn.key                         ← 2-decrypt-cert.sh ghi ra
│   ├── sds.infiniband.vn.cert                    ← cp từ gitsync
│   ├── sds.infiniband.vn.key                     ← 2-decrypt-cert.sh ghi ra
│   ├── s3-hcm.sds.infiniband.vn.cert             ← cp từ gitsync
│   ├── s3-hcm.sds.infiniband.vn.key              ← 2-decrypt-cert.sh ghi ra
│   ├── s3-hni.sds.infiniband.vn.cert             ← cp từ gitsync
│   └── s3-hni.sds.infiniband.vn.key              ← 2-decrypt-cert.sh ghi ra
│
├── dashboard/
│   ├── Dockerfile                                # multi-stage: node build FE → python runtime (+lua5.1/luac)
│   ├── README.md                                 # bootstrap, vận hành, dev local — đọc file này trước khi deploy dashboard
│   ├── dashboard-workspace/                      ← working clone RIÊNG của dashboard (gitignored + dockerignore) — dashboard tự
│   │                                               clone/pull/commit/push; KHÔNG đụng gitsync/ (git-sync tự quản), KHÔNG sửa tay
│   ├── backend/
│   │   ├── pyproject.toml
│   │   ├── app/
│   │   │   ├── main.py                           # FastAPI factory, serve static FE build
│   │   │   ├── settings.py                       # pydantic-settings, đọc .env riêng của dashboard
│   │   │   ├── auth/                             # provider.py (interface) · none.py · basic.py · middleware.py
│   │   │   └── api/                              # routers mỏng:
│   │   │       ├── entities.py                   #   CRUD 8 loại entity fragment
│   │   │       ├── lua_plugins.py                #   list/view/edit plugins/custom + libraries
│   │   │       ├── control_plane.py              #   config-hcm/han: edit + copy-to-sandbox + restart
│   │   │       ├── gitops.py                     #   diff, commit/push, MR, history (git log --follow), revert placeholder
│   │   │       ├── status.py                     #   gitsync log tail, apisix reloaded check, MR poll
│   │   │       └── profile_map.py                #   CRUD profile-map (badge "chưa enforce")
│   │   ├── core/                                 # ★ business logic thuần, không dính FastAPI
│   │   │   ├── repo.py                           #   GitPython wrapper: clone/pull-rebase/commit/push/branch
│   │   │   ├── gitlab_api.py                     #   tạo MR, poll MR status (python-gitlab)
│   │   │   ├── fragments.py                      #   entity model ↔ folder/key mapping, naming convention
│   │   │   │                                     #   route-<domain>-<scheme>-<port>, disable-by-comment toggle
│   │   │   ├──yamlio.py                          #   ruamel round-trip read/write, chuẩn hoá key cột 0
│   │   │   ├── validate.py                       #   key-khớp-folder, dup id/username (chặn cứng),
│   │   │   │                                     #   empty-array minItems warning (bài học incident 2026-07-03)
│   │   │   ├── profile_map.py                    #   parser riêng cho format INI-section-trong-.yaml
│   │   │   ├── lua_lint.py                       #   luac -p subprocess, trả kết quả không tự sửa
│   │   │   ├── docker_ctl.py                     #   restart whitelist cứng "apisix-standalone", không nhận input tuỳ ý
│   │   │   └── audit.py                          #   audit log thường + audit log control-plane riêng (JSONL)
│   │   └── tests/                                # unit test core/ (fragments round-trip giữ comment, validate, profile-map parser)
│   └── frontend/
│       ├── package.json · vite.config.ts · tsconfig.json
│       └── src/
│           ├── api/                            # client + types
│           ├── components/                     # DiffViewer, SaveDialog (main/MR), MonacoYaml, MonacoLua,
│           │                                   # DcBadge ("Dự kiến — chưa enforce"), AuditTable, StatusPanel
│           ├── pages/                          # 8 trang entity + LuaPlugins + ControlPlane + ProfileMap + Status + History
│           └── App.tsx                         # layout, DC selector, auth guard
│
├── logs/
│   ├── apisix/                                   ← 1 log dir per VM tại mỗi DC
│   │   ├── services/
│   │   │   └── <rotue-id/service-id/consumer-id>.log  
│   │   ├── access.log
│   │   ├── error.log
│   │   ├── nginx.pid
│   │   └── worker_events.sock
│   ├── dashboard/
│   │   ├── frontend/
│   │   │   └── frontend.log                      ← HTTP access log (uvicorn access): mọi request tải UI + gọi API (ai truy cập, lúc nào, endpoint gì, status code)
│   │   └── backend/
│   │       ├── backend.log                       ← application log: startup, lỗi, git operations, lint, exceptions
│   │       ├── audit.log                         ← audit CRUD entity (JSONL): actor, entity, action, commit sha, diff stat
│   │       └── audit-control-plane.log           ← audit RIÊNG mức cao: edit config-hcm/han + restart (ai, diff, kết quả restart)
│   │
│   ├── gitsync/
│   │   └── gitsync.log                           ← mount file trực tiếp vào /tmp/logs/gitsync.log, ghi mỗi lần git-sync pull
│   └── redis/
│       └── redis.log
│
├── plugins/                                      ← deploy thủ công, restart khi thay đổi
│   ├── custom/                                   ← Custom APISIX Lua plugins
│   │   ├── cmc-validator-bucket-name.lua         ← APISIX plugin — CMC Portal — validate bucket name khi tạo bucket qua UI
│   │   ├── s3-accesskey-extractor.lua            ← APISIX plugin — Extractor accesskey trên header - phân biệt authenticated và anomyous
│   │   ├── s3-qos-consumer.lua                   ← APISIX plugin — Resolve bucket-name/snat-ip/bucket+snat-ip thành username Consumer, thứ tự ưu tiên combo>bucket>snat-ip
│   │   └── s3-normalizer-bucket-name.lua         ← APISIX plugin — S3 API gateway — normalize vhost→path, validate bucket
│   │
│   └── libraries/                                ← Pure Lua (utility module) shared plugins library
│       ├── s3-akid-utils.lua                     ← Lua library — thư viên custom cho plugin s3-accesskey-extractor reuse
│       └── s3-validator-bucket-name-utils.lua    ← Lua library — validate bucket name & domain
│
├── samples/                                      ← template full khi gộp lại
│   ├── runtime/
│   │   ├── apisix-hcm.yaml
│   │   └── apisix-hni.yaml
│   └── apisix.yaml
│
├── scripts/
│   ├── debug/                                    ← tool troubleshoot, chạy tay khi cần, không mount vào container
│   │   ├── check-apisix-plugin.sh                ← lấy danh sách plugin BUILT-IN thật từ container đang chạy, diff với config-*.yaml (plugin mới xuất hiện / plugin bị xoá sau upgrade image) — KHÔNG check syntax/logic plugin custom
│   │   ├── curl-route.sh                         ← Check curl với backend và apisix
│   │   ├── debug-s3-logicwlua.py                 ← debug S3 normalizer plugin logic (Lua)
│   │   ├── debug-s3v4-curl.sh                    ← generate curl command với AWS Signature V4
│   │   └── verify-apisix.sh                      ← Kiểmt ra lại toàn bộ các logic của apisix và các tính năng đi kèm
│   │
│   ├── deploy/                                   ← chạy có chủ đích bởi admin, không trigger tự động
│   │   ├── 1-patch-template-lua.sh               ← chạy 1 lần khi deploy hoặc upgrade APISIX
│   │   ├── 2-encrypt-certs.sh                    ← chạy trên máy admin trước khi commit cert lên repo
│   │   ├── 3-decrypt-certs.sh                    ← chạy 1 lần khi deploy hoặc đổi cert
│   │   └── deploy.sh                             ← entry point: patch lua → decrypt certs → compose up
│   ├── libraries/                                ← shared lib, không chạy trực tiếp
│   │   ├── cert-list-domains.txt                 ← danh sách domain cần inject cert vào apisix-${DC_PROFILE}.yaml, lib dùng chung cho 2-decrypt-certs.sh và 3-inject-certs.sh
│   │   ├── decrypt-cert-helper.sh                ← CERT_DOMAINS array — nguồn duy nhất domain nào cần cert (dùng bởi 3-decrypt-certs.sh), kèm override filename cho domain đặt tên khác convention (SRC_CERT_FILE/SRC_KEY_ENC_FILE, vd cmc.sds.infiniband.vn copy nguyên tên từ nginx)
│   │   └── profile-map.yaml                      ← khai subfolder nào trong routes/upstreams thuộc DC profile nào (hcm/hni,han/*), dùng bởi merge-fragments.sh — subfolder chưa khai → mặc định shared (*) + WARNING, không block merge
│   └── runtime/                                  ← được mount vào gitsync container, trigger tự động sau mỗi git sync
│       ├── gitsync.sh                            ← exechook của git-sync, detect layout và gọi merge-fragments.sh
│       ├── inject-certs.sh                       ← chạy 1 lần khi deploy hoặc đổi cert
│       └── merge-fragments.sh                    ← validate + gộp upstreams/routes/ssls thành apisix-${DC_PROFILE}.yaml
│

├── secrets/
│   ├── .netrc                                    ← GitLab HTTPS auth cho gitsync, read-only (gitignored, KHÔNG commit), chmod 600
│   ├── .netrc-dashboard                          ← token RIÊNG của dashboard (read+write repository) — tách audit trail, chmod 600
│   └── dashboard-users.htpasswd                  ← (tuỳ chọn) user basic-auth dashboard, bcrypt (htpasswd -B), chmod 600
│

│ 
├── init.lua                                      ← patched — đã xóa set_header X-Forwarded-Port, tạo bởi 1-patch-template-lua.sh
├── init.lua.orig                                 ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── ngx_tpl.lua                                   ← patched — đã xóa proxy_set_header X-Forwarded-Port, tạo bởi 1-patch-template-lua.sh
├── ngx_tpl.lua.orig                              ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── vault.lua.lua                                 ← patched — thay đổi kv v1 thành kv v2, tạo bởi 1-patch-template-lua.sh
├── vault.lua.orig                                ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── config_yaml.lua                               ← patched — thay đổi log warning mặc định của APISIX khi hot-reload
├── config_yaml.lua.orig                          ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── kafka-logger.lua                              ← patched — thêm ssl/ssl_verify support
├── kafka-logger.lua.orig                         ← bản gốc extract từ image, dùng để diff khi upgrade APISIX version
├── .yamllint.yaml                                ← yamllint rule config — nới lỏng line-length/comment style, giữ error cho trailing-spaces/key-duplicates/newline
├── .env                                          ← DC_PROFILE=hcm | han và CERT_PASSPHRASE cho encrypt/decrypt (có trong .gitignore, KHÔNG commit)
├── .gitignore
├── redis.conf                                    ← artifact cho cấu hình của redis local
├── prometheus.yaml                               ← artifact cho cấu hình của prometheus exporter đến mimir
└── docker-compose.yaml                           # thêm service dashboard
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
sudo apt install net-tools jq git tree unzip curl s3cmd tshark kafkacat apache2-utils -y      # kafkacat hoặc kcat tuỳ version repo

# AWS
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
curl https://rclone.org/install.sh | sudo bash
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

# Cài awscurl nếu chưa có
pip install awscurl --break-system-packages   # nếu chưa có
```

```bash
# Docker
curl -fsSL https://get.docker.com -o - | bash 
sudo apt update

## Install
# sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# sudo systemctl status docker | grep Active
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

# Secret git clone repo lần đầu
> Tạo Access Token **glpat-xxxxxxxxxxxxxxxxxxxx** trên repo với permission **read-repository**.

```bash
cat > .netrc << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-xxxxxxxxxxxxxxxxxxxx
EOF

# Tạo thư mục 
mkdir -p /opt/apisix/standalone

# HTTPS (cần nhập username/password hoặc personal access token)
git clone https://git-lab.infiniband.vn/apisix/apisix-standalone.git /opt/apisix/standalone/sandbox
cd sandbox

# Tắt track permission trong repo này
git config core.fileMode false

# Verify
git config --get core.fileMode
# → false
```

# File bootstrap (cần tồn tại trước khi doker compose up)

```bash
## gitsync
mkdir -p gitsync secrets logs/apisix logs/apisix/services logs/redis logs/gitsync logs/dashboard/backend logs/dashboard/frontend dashboard/dashboard-workspace

## .env
# random-strong-passphrase
# base64 — 32 bytes → 44 chars (mặc định có thể có +/=)
openssl rand -base64 32

# hex — 32 bytes → 64 hex chars (chỉ có 0-9a-f, không có ký tự đặc biệt)
openssl rand -hex 32

cat > .env << 'EOF'
DC_PROFILE=hcm
ORDER_NUM=1     # số thứ tự của instance ví dụ 1,2,3,... khi kết hợp sẽ thành hcm-1, han-2,...
CERT_PASSPHRASE=<random-strong-passphrase>
REDIS_PASSWORD=<redis-password>
REDIS_ADDR=redis://127.0.0.1:6379
KAFKA_SASL_USER=apisix
KAFKA_SASL_PASSWORD=<kafka-password>
VAULT_ADDR=https://sb-cloud-internal-vault.infiniband.vn
VAULT_TOKEN=hvs.xxxxxxxxxxxxxxxxx   # token copy từ Vault UI
VAULT_ROLE_ID=
VAULT_SECRET_ID=
EOF

## .secrets/.netrc
cat > secrets/.netrc << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-xxxxxxxxxxxxxxxxxxxx
EOF

## Token GitLab RIÊNG cho dashboard — scope read_repository + write_repository (KHÔNG dùng chung token read-only của gitsync — tách audit trail ai commit gì)
cat > secrets/.netrc-dashboard << 'EOF'
machine git-lab.infiniband.vn
login oauth2
password glpat-yyyyyyyyyyyyyyyyyyyy
EOF

## (Tuỳ chọn) Basic auth: tạo user + đổi AUTH_MODE=basic trong docker-compose.yaml và bỏ comment dòng mount htpasswd
# 1. Hash + ghi vào file (user đầu tiên — có -c), sinh password mạnh bằng openssl (đưa cho user, lưu vào password manager)
htpasswd -B -b -c secrets/dashboard-users.htpasswd <user1> "$(openssl rand -hex 24)"

# 2. Thêm user thứ 2 trở đi — KHÔNG có -c vì sẽ ghi đè mất user cũ
htpasswd -B -b secrets/dashboard-users.htpasswd <user2> "$(openssl rand -hex 24)"

## Output:
admin:$2y$05$ui826OxeeEBrc6Msh7rUge0su6INkZbaDuQ1T8KaKi7ZzbcZ5Jnw.
thuyldx:$2y$05$DmXMy37cJeK2jumK2zQyPucr77.yaknw8RVaUji1rZE6AO.PJ7.wC
```

# Phân quyền
```bash
# git-sync (UID 65533), APISIX (UID 636), worker log (UID 65534)
# ── gitsync container — toàn bộ process (không có privilege drop) chạy 65533 ──
sudo chown -R 65533:65533 gitsync/ apisix_routes/ apisix_config/ scripts/ secrets/ plugins/ certs/
# sudo chown -R 65533:65533 docker-compose.yaml
# sudo chown -R 636:636 logs/
sudo chown -R 65533:65533 logs/gitsync/
# ── apisix-standalone — MASTER process = UID 0, 
#    nhưng WORKER process (nơi thực sự xử lý request + ghi log) = UID 65534.
#    logs/ cần ghi bởi WORKER → chown theo 65534, KHÔNG phải 0. ───────────
sudo chown -R 65534:65534 logs/apisix/
# sudo chown -R 0:0 apisix_config/    # chỉ đọc (:ro mount), owner không quan trọng nhiều nhưng giữ nhất quán với master
# sudo chown -R root:root plugins/ certs/ apisix_config
# Container dashboard chạy ROOT (UID 0, image python:3.12-slim mặc định, giống apisix-standalone user "0:0") → chown 0:0 cho nhất quán; file log root tạo là 644 nên user thường vẫn tail được, chỉ không ghi/xoá được.
# Root ghi được mọi nơi nên chown chỉ để nhất quán + tránh Docker tự tạo folder owner root ngoài ý muốn. Nếu sau này hạ quyền (user: "1000:1000" trong compose) → chown lại theo UID đó.
sudo chown -R 0:0 logs/dashboard/ dashboard/dashboard-workspace/
sudo chmod -R 755 gitsync/ apisix_routes/ apisix_config/ logs/ scripts/ logs/dashboard/ dashboard/dashboard-workspace/
sudo chmod 755 certs/ && sudo find plugins/ -type d -exec chmod 755 {} \;
sudo chmod 700 secrets/
sudo chmod 644 certs/*.cert certs/*.crt && sudo find plugins/ -type f -name "*.lua" -exec chmod 644 {} \;
sudo chmod 600 certs/*.key secrets/.netrc secrets/.netrc-dashboard secrets/dashboard-users.htpasswd secrets/dashboard-users.htpasswd
sudo find scripts/ -name "*.sh" -exec chmod +x {} \;

sudo chown -R 65533:65533 gitsync/ apisix_routes/ apisix_config/ scripts/ secrets/ plugins/ certs/ && sudo chown -R 65533:65533 logs/gitsync/ && sudo chown -R 65534:65534 logs/apisix/ && sudo chown -R 0:0 logs/dashboard/ dashboard/dashboard-workspace/ && sudo chmod -R 755 gitsync/ apisix_routes/ apisix_config/ logs/ scripts/ logs/dashboard/ dashboard/dashboard-workspace/ && sudo chmod 755 certs/ && sudo find plugins/ -type d -exec chmod 755 {} \; && sudo chmod 700 secrets/ && sudo chmod 644 certs/*.cert certs/*.crt && sudo find plugins/ -type f -name "*.lua" -exec chmod 644 {} \; && sudo chmod 600 certs/*.key secrets/.netrc secrets/.netrc-dashboard secrets/dashboard-users.htpasswd secrets/dashboard-users.htpasswd && sudo find scripts/ -name "*.sh" -exec chmod +x {} \;
```

# Deploy
```bash
bash scripts/deploy/1-patch-template-lua.sh
docker compose up -d          # gồm cả service dashboard (build lần đầu hơi lâu — npm + pip)
bash scripts/deploy/3-decrypt-certs.sh

# Verify dashboard (UI: http://<VM-IP>:18080 — firewall/ACL tự quản, xem dashboard/README.md)
curl -s http://127.0.0.1:18080/healthz    # {"ok":true}
docker logs dashboard --tail 5            # "Workspace sẵn sàng: ... @ <commit>"
```

# Dashboard — xem/CRUD config qua UI (người vận hành đọc mục này)

Chi tiết đầy đủ: **`dashboard/README.md`**. Tóm tắt 2 cách xem:

**1. Trên VM (đã chạy sẵn cùng stack):** service `dashboard` trong compose, port
`18080`, CRUD 8 loại entity `apisix_routes/` qua Git (diff + xác nhận → push main →
gitsync ~30s → hot-reload). Mọi VM đều có dashboard riêng của DC đó.

**2. Từ máy cá nhân — hub multi-DC (khuyến nghị cho vận hành hằng ngày):**

```bash
# Yêu cầu: Docker (macOS khuyến nghị OrbStack cho nhẹ; Windows: Docker Desktop + WSL2;
#          Linux: docker engine) + SSH tới jump-sb. Chi tiết: dashboard/README.md
ssh -N -L 18080:127.0.0.1:18080 sb-api6-hcm-1 &     # tunnel HCM
ssh -N -L 18081:127.0.0.1:18080 sb-api6-hni-1 &     # tunnel HNI
cd dashboard/hub && cp peers.example.yaml peers.yaml
docker compose up -d --build
# → http://localhost:18000        tổng quan mọi DC (health/commit/reload)
# → http://hcm.localhost:18000    dashboard HCM đầy đủ — xem + CRUD trực tiếp
# → http://hni.localhost:18000    dashboard HNI đầy đủ — xem + CRUD trực tiếp
# Đổi VM ngay trong UI: dropdown "DC — hostname — IP" trên sidebar.
# Scale thêm node: +1 tunnel, +1 block peers.yaml (id mới = subdomain mới).
```

# Cập nhật cert / Patch Lua
## Đổi cert

```bash
# 1. Copy cert mới vào certs/
cp new.cert certs/s3-hcm.sds.infiniband.vn.cert
chmod 644 certs/s3-hcm.sds.infiniband.vn.cert

# 2. Inject lại vào apisix-hcm.yaml
./scripts/runtime/inject-certs.sh

# 3. Commit apisix-hcm.yaml lên GitLab → git-sync tự pull về → hot-reload
```

## Hot-reload (không cần restart)

Commit thay đổi vào `apisix_routes/apisix-${DC_PROFILE}.yaml` trên GitLab → git-sync pull về trong ≤30s → APISIX hot-reload tự động.

## Cần restart

Khi thay đổi:
- `apisix_config/config-hcm.yaml` → cấu hình hệ thống
- `plugins/*.lua`                 → custom plugin
- `ngx_tpl.lua` / `init.lua`      → update apisix version
- Thêm port mới trong route/upstream (`vars: server_port`) → **phải thêm port đó vào `ssl.listen` trong `config-hcm.yaml` trước**, sau đó restart

```bash
docker exec apisix-standalone apisix reload
docker compose up -d --force-recreate
```

> ⚠️ **Lưu ý port mới:**
> Khi thêm route với `vars: ["server_port", "==", "XXXXX"]`,
> port đó **bắt buộc** phải có trong `apisix_config/config-hcm.yaml`:
> ```yaml
> ssl:
>   listen:
>     - port: 443
>     - port: XXXXX   # ← thêm port mới ở đây
> ```
> Xem comment **Port reference** trong `config-hcm.yaml` để biết danh sách port hiện tại.
> Ngược lại: thay đổi routes/upstreams trong `apisix_routes/` → **KHÔNG cần restart**, APISIX hot-reload tự động mỗi 60s.

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
IMAGE="apache/apisix:3.17.0-debian" bash scripts/deploy/1-patch-template-lua.sh

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
cp gitsync/.worktrees/<good-hash>/gitsync/apisix-hcm.yaml \
   gitsync/apisix_routes/apisix-hcm.yaml
```

# Plugin — S3 Gateway

## Toàn bộ plugin theo image
```
# Toàn bộ plugin HTTP
docker run --rm apache/apisix:3.17.0-debian sh -c "ls /usr/local/apisix/apisix/plugins/*.lua | xargs -n1 basename | sed 's/\.lua$//' | sort | sed 's/^/  - /'"
```

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

## Troubleshoot

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| `property "cert" validation failed` | Cert placeholder chưa được inject vào `apisix-hcm.yaml` | Chạy `bash scripts/deploy/3-inject-certs.sh` từ deployment dir |
| `missing valid end flag` | Script `merge-fragments.sh` append `# END` có space thay vì `#END` | Fix `printf '\n#END\n'` trong script → re-run merge |
| HTTPS `SSL_ERROR_SYSCALL` hoặc `tlsv1 alert internal error` | APISIX dùng fallback `ssl_PLACE_HOLDER.crt` vì SNI không match cert nào | Cert chưa inject hoặc SNI không gửi đúng (test bằng IP) → dùng `--resolve domain:port:ip` thay vì IP trực tiếp |
| Port `16443`, `19443` không respond (`000`) | APISIX chưa khai báo listen port trong `config-hcm.yaml` | Thêm port vào `ssl.listen` → bắt buộc restart container (không hot-reload) |
| `bind() to 0.0.0.0:80 failed (13: Permission denied)` | `network_mode: host` nhưng container chạy non-root user | Thêm `user: "0:0"` vào service `apisix-standalone` trong docker-compose |
| Thêm port mới vào route nhưng không connect được | `config-hcm.yaml` chưa có port trong `ssl.listen` | Xem comment port reference trong `config-hcm.yaml` → thêm port → restart |
| `did not find expected key` (lyaml parse error) | did not find expected key (lyaml parse error) | Chạy `yamllint apisix_routes/apisix-hcm.yaml` → fix trailing spaces, duplicate key |
| gitsync overwrite file sau khi sửa local | git pull báo conflict permission 100644 → 100755 | Mọi thay đổi phải commit lên git — không sửa file local trực tiếp |
| `git pull` báo conflict permission `100644 → 100755` | git pull báo conflict permission 100644 → 100755 | `git config core.fileMode false` một lần là xong |
| Container crash loop | Volume mount sai tên file | Kiểm tra tên file khớp `APISIX_PROFILE` |
| APISIX không hot-reload dù file đã thay đổi | exechook fail → file không được copy | `docker logs gitsync --tail 20 \| grep "hook failed"` |
| `missing valid end flag` | File thiếu `#END` hoặc YAML lỗi | Fix file → hot-reload tự động, KHÔNG restart |
| `failed to open file: config-hcm.yaml` | Volume mount sai tên | Tên file phải có profile suffix `-hcm` |
| `fork/exec /bin/cp: no such file or directory` | git-sync exec không qua shell, space trong args bị parse sai | Dùng wrapper script `gitsync.sh` |
| `Is a directory` khi load plugin | Docker tạo directory thay vì file khi mount target chưa tồn tại trên host | `rm -rf plugins/ceph-rados-regex.lua && cp file.lua plugins/` rồi `docker compose down && up` |
| `413 Request Entity Too Large` | `client_max_body_size: 10m` quá nhỏ cho S3 upload | Set `client_max_body_size: 0` trong `config-hcm.yaml` |
| gitsync `HTTP Basic: Access denied` | `GITSYNC_GIT_CONFIG: credential.helper=store` sai format | Xóa dòng đó, mount `.netrc` vào `/tmp/.netrc` |
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
| gitsync pull xong nhưng APISIX chưa reload | exechook fail → file không được copy | `docker logs gitsync --tail 20` |

## Kiểm tra stack health

```bash
# Check health check toàn bộ route/upstream hiện có (check theo số lượng thực tế đi qua APISIX VM đó)
curl -s http://127.0.0.1:9090/v1/healthcheck

# Container status
docker ps --format "table {{.Names}}\t{{.Status}}"

# git-sync đã pull commit mới chưa
readlink gitsync/current   # hash phải khớp GitLab

# File đã copy ra chưa
ls -la apisix_routes/
cat apisix_routes/apisix-hcm.yaml | head -3

# APISIX routing OK
curl -s -H "Host: s3-hcm.sds.infiniband.vn" http://localhost:80/ | head -1
curl -sk -H "Host: s3-hcm.sds.infiniband.vn" https://localhost:443/ | head -1

# Logs
tail -f logs/apisix-hcm/access.log
docker logs gitsync --tail 5
docker logs gitsync --tail 5
```

## Agent quét monitoring mỗi đêm để tính lại Hit-room
> → map vào pipeline hiện có: agent query Prometheus → tính quota mới → commit YAML fragment → merge-fragments → git-sync pull → APISIX hot-reload. Không cần Admin API.


## Kiểm tra v-host/path style (addressing_style=virtual set bằng aws configure), SDK chuẩn, không có quirk header như awscurl
aws configure set default.s3.addressing_style virtual       # auto | path | virtual, default: auto
aws s3api create-bucket --profile <profile-name> --bucket <bucket-name> --endpoint-url https://s3-hcm.sds.infiniband.vn --debug 2>&1 | grep -A 3 "Making request\|'status_code'"
aws s3api create-bucket --profile <profile-name> --bucket <bucket-name> --endpoint-url https://s3-hcm.sds.infiniband.vn --debug 2>&1 | grep -A 3 "Making request\|'status_code'"
awscurl -X PUT --access_key=<access-key> --secret_key=<secret-key> --region=hcm --service=s3 -v -- "https://<bucket-name>.s3-hcm.sds.infiniband.vn/"

## Kiểm tra thời gian modify file theo thời gian lỗi nếu có
stat apisix_routes/consumer_groups/*.yaml | grep Modify

## Trace log
tail -f logs/apisix/error.log | grep -Fv -e "[lua] init.lua:197" -e "[lua] init.lua:217:" -e "ssl_client_hello_phase(): failed to find SNI"
grep -Fv -e "[lua] init.lua:197" -e "[lua] init.lua:217:" -e "ssl_client_hello_phase(): failed to find SNI" logs/apisix/error.log | tail -n 50

## Kiểm tra kafka/loki/prometheus
```bash
# 1. Xác nhận file compose thật đang dùng tên biến gì
grep -A2 "environment:" docker-compose.yaml | grep -i profile

# 2. Xác nhận PID 1 có đúng biến này
docker exec apisix-standalone sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep -i profile'

# 3. QUAN TRỌNG NHẤT — bằng chứng cuối cùng, đọc thẳng từ Loki
curl -s -G -H "X-Scope-OrgID: vnpaycloud" \ "https://maas-service-logs.infiniband.vn/loki/api/v1/label/region/values" | jq .
curl -s -G -H "X-Scope-OrgID: vnpaycloud" \ "https://maas-service-logs.infiniband.vn/loki/api/v1/label/job/values" | jq .

# 4. Tương tự cho Prometheus — đọc file ĐÃ RENDER, không phải sed lại bằng tay
docker exec prometheus cat /tmp/prometheus.yaml | grep -A3 "job_name\|region"

# 5. Verify Prometheus có target UP thật (bằng chứng cuối cùng phía Prometheus)
curl -s http://127.0.0.1:9099/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'
```

## Kiểm tra kafka với kcat
```bash
# Test: liệt kê metadata (nhẹ, không cần biết tên topic đúng)
kcat -b 172.26.24.80:31421 -X security.protocol=SASL_PLAINTEXT -X sasl.mechanisms=PLAIN -X sasl.username=apisix -X sasl.password="<password thật>" -L
kcat -b 172.26.24.80:31421,172.26.24.80:30215,172.26.24.80:30412 -X security.protocol=SASL_PLAINTEXT -X sasl.mechanisms=PLAIN -X sasl.username=apisix -X sasl.password="<password thật>" -L

# Test với SÁL_SSL
kcat -b 172.26.24.80:31421 -X security.protocol=SASL_SSL -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=apisix -X sasl.password="<password thật>" -X enable.ssl.certificate.verification=false -L

echo "test-message-$(date +%s)" | kcat -b 172.26.24.80:31421 -X security.protocol=SASL_SSL -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=apisix -X sasl.password="PEIdcMt7WMmO2SvFdyJvQIPf17jV4nYS" -X enable.ssl.certificate.verification=false -t apisix-gateway-hcm -P
```

## Kiểm tra lấy danh sách lỗi SNI: [error] 52#52: *180366 [lua] init.lua:197: ssl_client_hello_phase(): failed to find SNI: please check if the client requests via IP or uses an outdated protocol. If you need to report an issue, provide a packet capture file of the TLS handshake., context: ssl_client_hello_by_lua*, client:
```bash
docker exec apisix-standalone grep "failed to find SNI" /usr/local/apisix/logs/error.log | awk '{
      match($0, /client: ([0-9.]+)/, ip);
      match($0, /^([0-9\/]+ [0-9:]+)/, ts);
      count[ip[1]]++;
      if (!(ip[1] in first)) first[ip[1]] = ts[1];
      last[ip[1]] = ts[1];
    }
    END {
      for (i in count) printf "%-16s count=%-6d first=%s last=%s\n", i, count[i], first[i], last[i]
    }' | sort -k2 -t= -rn

# Output ví dụ:
10.158.40.25     count=296018 first=2026/07/01 17:47:58 last=2026/07/14 11:31:04
10.158.23.25     count=13379  first=2026/07/08 11:13:49 last=2026/07/14 11:31:05
172.27.2.207     count=1      first=2026/07/08 14:11:23 last=2026/07/08 14:11:23
127.0.0.1        count=1      first=2026/07/03 15:54:33 last=2026/07/03 15:54:33
10.3.14.41       count=1      first=2026/07/02 14:21:38 last=2026/07/02 14:21:38
```


## Kiểm log khi cần trace
```bash
# trong khoảng thời gian
# file logs/apisix/error.log
awk '$1" "$2 >= "2026/07/16 09:30:00" && $1" "$2 <= "2026/07/16 09:45:00"' logs/apisix/error.log

# file logs/apisix/access.log 
jq -c 'select(.time[0:19] >= "2026-07-16T09:00:00" and .time[0:19] <= "2026-07-16T09:45:00")' logs/apisix/access.log

# lấy tail log nhưng loại bỏ các dòng có chuỗi cụ thể
tail -f logs/apisix/error.log | grep -Fv -e "[lua] init.lua:197" -e "[lua] init.lua:217:" -e "ssl_client_hello_phase(): failed to find SNI"
grep -Fv -e "[lua] init.lua:197" -e "[lua] init.lua:217:" -e "ssl_client_hello_phase(): failed to find SNI" logs/apisix/error.log | tail -n 50

# lấy tail log nhưng chỉ lấy các dòng có chuỗi cụ thể
tail -f logs/apisix/error.log | grep -F -e "[lua] init.lua:197" -e "[lua] init.lua:217:" -e "ssl_client_hello_phase(): failed to find SNI"
grep -F -e "[lua] init.lua:197" -e "[lua] init.lua:217:" -e "ssl_client_hello_phase(): failed to find SNI" logs/apisix/error.log | tail -n 50
```

## Kiểm tra thời gian modify file theo thời gian lỗi nếu có
stat apisix_routes/consumer_groups/*.yaml | grep Modify
