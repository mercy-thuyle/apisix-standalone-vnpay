# Note kỹ thuật

File này gom toàn bộ giải thích, ghi chú vận hành, quyết định thiết kế và lịch sử
liên quan đến **toàn bộ repo source code**. Các file config gốc chỉ chứa cấu
hình thuần, không còn comment giải thích — mọi lý do "vì sao" nằm ở đây.
 
Định dạng mỗi mục: `file:line` (dòng tham chiếu trong file config hiện tại) kèm
nội dung giải thích.

**Phiên bản áp dụng:** đã upgrade `3.15.0 → 3.17.0` (xem mục "Upgrade APISIX
3.15.0 → 3.17.0" phía dưới). Các note **chưa có mốc ngày sau 2026-08-10** vẫn
là verify trên **3.15** — coi là tham khảo lịch sử, cần re-verify trước khi
tin tuyệt đối. Các note có mốc ngày **2026-08-10 trở về sau** đã verify trực
tiếp trên **3.17.0**. Khi upgrade version tiếp theo, áp dụng lại đúng nguyên
tắc này.

**Tài liệu tham khảo chính thức cho các field trong `apisix_config/config-
{DC_PROFILE}.yaml`** (`nginx_config`, `apisix.*`, `plugin_attr`...):
<https://docs.api7.ai/api7-gateway/reference/configuration> — dùng để tra cứu
nhanh field nào có sẵn trong schema gốc APISIX/API7 khi cần xác nhận, thay vì
suy đoán.

---

## apisix_config/config-{DC_PROFILE).yaml:1-3 — `node_listen.port: 80`

Container expose port 80 ra ngoài thay vì port mặc định 9080 của APISIX. Lý do:
port 80 khớp với convention reverse-proxy/LB phía trước (VD SLB/keepalived) đang
trỏ vào cổng chuẩn HTTP, tránh phải thêm rule NAT/port-forward riêng cho 9080.

## apisix_config/config-{DC_PROFILE).yaml:5 — `enable_server_tokens: false`

Theo đúng mô tả trong tài liệu chính thức
(<https://docs.api7.ai/api7-gateway/reference/configuration>): *"Whether the
APISIX version number should be shown in Server header"* — tắt field này chỉ
**ẩn số version APISIX** khỏi header `Server` trả về client, **không** xoá
hẳn header `Server` hay giấu hoàn toàn việc đang chạy APISIX (theo thảo luận
chính thức từ maintainer APISIX, muốn thay hẳn giá trị header `Server` phải
dùng plugin `response-rewrite`, field này không làm được việc đó). Vẫn có
giá trị thực tế: giảm bớt thông tin version cụ thể lộ ra ngoài — hữu ích cho
domain phơi internet (`iam`/`sts`/`sqs`/S3 SDK, đã note ở `plugin_configs/`),
giảm bề mặt thông tin cho kẻ tấn công dò quét theo version có lỗ hổng đã biết
(banner grabbing). Đặt ở cấp `apisix` — áp dụng toàn cục cho mọi route, không
cấu hình riêng được theo route.

## apisix_config/config-{DC_PROFILE).yaml:8 — `enable_http2: false`

Từ APISIX 3.9+, `enable_http2` phải khai báo ở level `apisix`, KHÔNG đặt trong
`ssl.listen`. Tắt HTTP/2 vì AWS S3 SDK (client thực tế đi qua gateway) dùng
HTTP/1.1; bật HTTP/2 từng gây vấn đề với streaming upload/download object lớn.

## apisix_config/config-{DC_PROFILE).yaml:10-11 — `extra_lua_path` / `extra_lua_cpath`

Bật pattern shared utility library cho toàn bộ custom plugin. Các file Lua
thuần (không phải plugin, chỉ là hàm dùng chung) đặt tại
`apisix/plugins/libraries/`, cho phép bất kỳ plugin nào `require("ten-file")`
để tái sử dụng logic mà không copy code. `extra_lua_cpath` dành cho module biên
dịch C (`.so`) nếu sau này cần.

## apisix_config/config-{DC_PROFILE).yaml:13-24 — `ssl.listen` (danh sách port HTTPS)

Mapping port ↔ service trong hệ sinh thái Cloudian HyperStore:

| Port  | Service                                            |
|-------|-----------------------------------------------------|
| 443   | S3 HTTPS, CMC Portal, HyperIQ, Ceph RGW S3           |
| 8443  | Ceph RGW Admin UI (upstream :8443)                   |
| 16443 | Cloudian IAM + STS (`iam.sds`, `sts.sds` → :16443)   |
| 19443 | Cloudian S3 Admin (`s3-admin.sds` → :19443)          |

Cloudian SQS chạy HTTP thuần ở `:18090`, không cần thêm vào `ssl.listen`.

**Quy trình khi thêm service mới có port riêng:**
1. Thêm port vào `ssl.listen`.
2. Restart container: `docker compose restart apisix-standalone` —
   thay đổi `config.yaml` KHÔNG hot-reload, bắt buộc phải restart.
3. Khác với `apisix-hcm.yaml` (routes/upstreams) — file đó hot-reload tự động
   theo chu kỳ poll của `gitsync` (30s).

## apisix_config/config-{DC_PROFILE).yaml:23-24 — `ssl_certificate` / `ssl_certificate_key`

Dùng cert wildcard `*.sds.infiniband.vn`, cover toàn bộ service `.sds`. Đây là
cert fallback khi client connect bằng IP hoặc không gửi SNI extension (giống
hành vi default_server của NGINX cũ).

## apisix_config/config-{DC_PROFILE).yaml:25 — `# fallback_sni: "sds.infiniband.vn"` (đang tắt)
 
Directive dự phòng cho trường hợp APISIX cần chỉ định tường minh SNI mặc định
khi không có cert nào khớp SNI client gửi lên (khác với `ssl_certificate` ở
dòng 21-22 — đó là cert fallback theo *cert*, còn `fallback_sni` fallback theo
*tên miền* dùng để chọn cert trong `ssl_default_domain` khi nhiều SSL object
được nạp qua Admin API/etcd).
 
**Vì sao đang tắt:** ở kiến trúc Standalone (file-driven, không etcd) hiện tại
chỉ có duy nhất 1 cert wildcard `*.sds.infiniband.vn` khai báo tĩnh qua
`ssl_certificate`/`ssl_certificate_key`, nên chưa phát sinh trường hợp cần
APISIX tự chọn giữa nhiều SSL object theo SNI — giữ tắt để tránh cấu hình dư
thừa không có tác dụng.
 
**Khi nào cần bật:** nếu sau này nạp thêm SSL certificate qua route/SSL object
riêng (nhiều domain, nhiều cert khác nhau cho từng route) thay vì chỉ dùng 1
cert tĩnh cấp `apisix.ssl` như hiện tại, cần bật `fallback_sni` để APISIX biết
domain nào dùng làm fallback khi client không gửi SNI hoặc gửi SNI không khớp
cert nào đã nạp.

## apisix_config/config-{DC_PROFILE).yaml:27-33 — `secret_providers` (Vault) — ⚠️ ĐÍNH CHÍNH 27/08/2026, xem mục "Cert qua Vault" cuối file

**Đính chính quan trọng — SAI VỊ TRÍ FILE, không hoạt động nếu bật nguyên trạng.** Đoạn note gốc bên dưới (giữ lại để đối chiếu lịch sử) mô tả khối này khai trong `config-{DC_PROFILE}.yaml` — **đây chính là root cause thật của bug `PEM_read_bio_X509_AUX() failed`** đã từng gặp khi thử nghiệm Vault cho SSL (ProxyHub từng lặp lại đúng lỗi này, đã trace root cause đầy đủ — xem mục "Cert qua Vault — cơ chế đúng" ở cuối file). APISIX Standalone chỉ đọc cơ chế Secret từ top-level key **`secrets:`** (số nhiều) trong file **dynamic resources** (`apisix-{DC_PROFILE}.yaml`, do `merge-fragments.sh` gộp từ `apisix_routes/`) — **KHÔNG** phải `config-{DC_PROFILE}.yaml`. Đặt ở `config.yaml` như note gốc mô tả → object `/secrets` nội bộ APISIX luôn rỗng → mọi `$secret://vault/...` fallback về chính chuỗi literal chưa resolve → APISIX cố parse chuỗi đó thành PEM → lỗi `PEM_read_bio_X509_AUX() failed`.

**Nội dung note gốc (SAI VỊ TRÍ, giữ để đối chiếu lịch sử — không làm theo):**

Khối này khai báo Vault KV provider để lấy cert/key qua `$secret://vault/...`
thay vì inject cert trực tiếp vào YAML. **Hiện chưa active trên thực tế** — chờ
team hạ tầng cấp thông tin Vault (địa chỉ, token/AppRole). Khi có, SSL entry
trong `apisix-hcm.yaml` sẽ đổi sang:

```yaml
cert: $secret://vault/ssl/<domain>/cert
key:  $secret://vault/ssl/<domain>/key
```

Xác thực bằng token (`VAULT_TOKEN` từ biến môi trường docker-compose) là cách
đang cấu hình sẵn. AppRole (`role_id`/`secret_id`) là phương án khuyến nghị hơn
cho production nhưng chưa triển khai — cần bổ sung khối `auth.method: approle`
khi chuyển đổi. Ví dụ như sau:
```yaml
    auth:
      method: approle
      role_id: "${{VAULT_ROLE_ID}}"
      secret_id: "${{VAULT_SECRET_ID}}"
```

**Cách khai đúng** (thay thế hoàn toàn đoạn trên khi kích hoạt Vault thật): tạo file mới `apisix_routes/secrets/vault-provider.yaml`, top-level key `secrets:`, field `id` gộp `<manager>/<confid>` — xem đầy đủ ở mục "Cert qua Vault — cơ chế đúng" cuối file, phần "Kích hoạt cho cụm S3-storage".


## apisix_config/config-{DC_PROFILE).yaml:40-101 — `nginx_config` (NGINX directive overrides)

Không có trường tùy ý ở tầng `apisix`; toàn bộ timeout upload/body được inject
qua `nginx_config.http` bên dưới. `apisix_config/config-{DC_PROFILE).yaml:40-101` là cấu hình Nginx directive overrides (thông qua nginx_config)

### apisix_config/config-{DC_PROFILE).yaml:41-44 — `worker_processes` / `worker_rlimit_nofile`

`worker_processes: auto` — mỗi worker chạy trên 1 CPU core để xử lý song song.
`worker_rlimit_nofile: 32768` set tường minh (không để APISIX tự tính theo
công thức `worker_connections × 2 + 64`) vì giá trị tự tính có thể vượt giới
hạn file descriptor của host. Ràng buộc: `rlimit_nofile` phải ≥
`worker_connections × 2 × worker_processes`.

### apisix_config/config-{DC_PROFILE).yaml:46-47 — `event.worker_connections`

Mỗi container APISIX xử lý tối đa 32768 connection đồng thời. Do NGINX tính 2×
(listen + upstream), tổng concurrent connection tối đa mỗi container APISIX =
`2 × 32768 = 65536`.

### apisix_config/config-{DC_PROFILE).yaml:52 — `access_log_format`

Format JSON 1 dòng, **không dùng `|` block scalar**. Lý do: mỗi dòng trong
`access.log` = 1 log record khi Loki/Promtail tail theo dòng. Nếu dùng `|` và
JSON value chứa newline thật, 1 record sẽ bị xé thành nhiều dòng file, khiến
Loki parse sai (mất record hoặc gộp nhầm record).

**Sự kiện:** Trước đây từng có format debug log cả `Authorization`/request
header để trace lỗi — đã loại bỏ khỏi cấu hình chính thức vì log credential ra
file là rủi ro bảo mật, không được để trên production dù chỉ tạm thời.

### apisix_config/config-{DC_PROFILE).yaml:53 — `access_log_format_escape: json`

Escape giá trị biến (`$request_uri`, `$http_user_agent`...) đúng chuẩn JSON
(RFC 8259): escape `"`, `\` và control char (`\n \t \r`...). Mặc định
(`escape: default`) dùng kiểu NGINX cũ, KHÔNG đảm bảo escape đúng chuẩn JSON —
input độc hại (VD User-Agent giả mạo chứa `"` hoặc ký tự xuống dòng) có thể làm
gãy cấu trúc JSON của cả dòng log, khiến Loki không parse được hoặc bị "tiêm"
field giả.

### apisix_config/config-{DC_PROFILE}.yaml:51-52 — `error_log` / `error_log_level` — ĐÃ SỬA vị trí sai

**🔴 Bug đã fix — vị trí sai gây mất log hoàn toàn, tra ra bằng nguồn chính
thức:** trước đây 2 field này bị đặt lồng trong `nginx_config.http:` — sai
vị trí. Đối chiếu trực tiếp file mặc định thật của APISIX
(`conf/config-default.yaml`, repo `apache/apisix`):
```yaml
nginx_config:                     # config for render the template to generate nginx.conf
  error_log: logs/error.log
  error_log_level:  warn          # warn,error
  worker_processes: auto
  ...
```
`error_log`/`error_log_level` nằm ở **cấp cao nhất của `nginx_config:`**,
anh em cùng cấp với `worker_processes`/`event:` — **không** nằm trong
`http:`. Đặt sai vị trí khiến APISIX không nhận diện được key này → âm thầm
bỏ qua → merge về giá trị mặc định (`warn`) bất kể `config-hcm.yaml` khai
gì. Đây chính là nguyên nhân gốc của mục "Chưa giải quyết" từng ghi ở phần
`s3-traffic-classifier.lua` — **nay đã giải quyết**, xem cập nhật ở đó.

**Vì sao trước đây tưởng đường dẫn log "vẫn đúng" dù đặt sai vị trí:** giá
trị `error_log` Mercy đặt (`logs/error.log`) trùng khớp ngẫu nhiên với giá
trị mặc định của chính APISIX — nên dù bị bỏ qua, kết quả nhìn vẫn "đúng",
che giấu việc field này thực ra không được đọc. Chỉ `error_log_level` mới
lộ ra vì `debug` ≠ mặc định `warn`.

**Fix đã áp dụng:** chuyển cả 2 dòng ra khỏi `http:`, đặt ngay dưới
`worker_rlimit_nofile`, trước khối `event:` — đúng vị trí `nginx_config`
cấp cao nhất. Hiện tại (đã verify qua `nginx.conf` container) đang giữ
`error_log_level: warn` — mức hợp lệ cho vận hành thường xuyên.

**Cảnh báo vận hành:** mức `debug` chỉ dùng khi đang chủ động debug sự cố.
Các mức hợp lệ khác: `warn` | `info`. Không để `debug` chạy dài hạn trên
production — log verbose ảnh hưởng I/O và làm phình dung lượng log nhanh.
`info` là lựa chọn cân bằng khi cần thấy log tự viết (`core.log.info(...)`
trong các plugin custom, VD `s3-traffic-classifier`) mà không muốn full
`debug` (vốn dồn thêm rất nhiều dòng nội bộ của APISIX như
`ctx.lua:245: __index()`, `ssl.lua:314`, `healthcheck.lua:1385` request
head chi tiết từng target — không liên quan gì tới plugin custom, chỉ làm
nhiễu). Lưu ý: chữ `[DEBUG]` trong message của `s3-traffic-classifier` chỉ
là text Mercy tự đặt, không phải mức log thật — dòng đó vẫn ghi ở mức
`[info]` (`core.log.info`), nên `error_log_level: info` là đủ để thấy, không
cần `debug`.

### apisix_config/config-{DC_PROFILE}.yaml:61-62 — `client_max_body_size: "5120m"`

Giới hạn 5 GB, bắt buộc là chuỗi có đơn vị (không phải số nguyên byte). Vượt
giới hạn này trả lỗi `413 Request Entity Too Large`. Môi trường sandbox từng
test với `"100G"` (gần như unlimited, để Ceph/Cloudian tự giới hạn object
size) — giá trị production chốt là 5 GB theo yêu cầu nghiệp vụ hiện tại; đổi
lại giá trị này nếu yêu cầu object size thay đổi.

### apisix_config/config-{DC_PROFILE).yaml:60 — `client_body_buffer_size: "16k"`

Cố tình để nhỏ — mục tiêu là stream thẳng, không buffer body vào memory.

### apisix_config/config-{DC_PROFILE).yaml:74-76 — Proxy timeout tới upstream S3 backend

`proxy_connect_timeout` = thời gian establish TCP. `proxy_send_timeout` = thời
gian gửi request (upload) tới backend. `proxy_read_timeout` = thời gian nhận
response (download) từ backend. Cả 3 đặt 600s (10 phút) để phù hợp upload/
download object lớn qua S3 API.

### apisix_config/config-{DC_PROFILE).yaml:78-80 — `proxy_buffering` / `proxy_request_buffering`

Tắt hoàn toàn buffering hai chiều. APISIX/NGINX mặc định sẽ buffer request
body vào memory/disk nếu không tắt — với object lên tới hàng chục/trăm GB,
buffer sẽ gây OOM. Set `off` đảm bảo APISIX stream thẳng object lên Cloudian
thay vì buffer.

### apisix_config/config-{DC_PROFILE).yaml:85-86 — `proxy_ssl_server_name` / `proxy_ssl_name`

Force NGINX gửi đúng SNI (`$host` = Host header từ client) khi TLS handshake
tới backend. Nếu không set, NGINX dùng IP làm SNI → Cloudian không nhận ra
domain và có thể trả sai cert hoặc từ chối kết nối.

### apisix_config/config-{DC_PROFILE).yaml:88 — `proxy_http_version: "1.1"`

Đặt ở level `nginx_config` (không đặt qua plugin `proxy-rewrite` trong route
YAML) để đảm bảo NGINX variable được resolve đúng — `proxy-rewrite` ở tầng
Standalone YAML KHÔNG resolve nginx variable.

### apisix_config/config-{DC_PROFILE).yaml:95-101 — `lua_shared_dicts` & chính sách rate-limit theo policy

Kích thước shared dict cho các plugin cần state trong Lua (không tính riêng
`prometheus_metrics` — 15m tương đương directive gốc `lua_shared_dict
prometheus_metrics 10M`, đã điều chỉnh lên 15m cho dư tải).

**Ghi chú kiến trúc quan trọng (đính chính 2026-08-14, áp dụng cho bản
APISIX 3.17 đang chạy):**
- `limit-count`, `limit-conn` **và** `limit-req` đều hỗ trợ policy `local`
  / `redis` / `redis-cluster` — cả 3 plugin dùng chung 1 schema `policy`
  (enum 3 giá trị, default `local`). **Không có** sự khác biệt "chỉ
  limit-count mới hỗ trợ Redis" như ghi nhận cũ — xác nhận qua docs chính
  thức: [limit-count.md](https://github.com/apache/apisix/blob/master/docs/en/latest/plugins/limit-count.md),
  [limit-conn.md](https://github.com/apache/apisix/blob/master/docs/en/latest/plugins/limit-conn.md).
  Redis cho `limit-conn` có từ PR #10866, tức có từ trước 3.15 rất lâu.
- Việc rate/connection được tính riêng theo từng node hay chia sẻ toàn cục
  **phụ thuộc vào `policy` đang khai trong từng route/consumer-group cụ
  thể**, không phải giới hạn cố định của plugin. Hệ thống hiện tại (xem
  `redis-local-tradeoff.html`) đang **chủ động chọn** `local` cho phần lớn
  đối tượng (cardinality cao, ưu tiên hiệu năng) và `redis` cho nhóm cần
  enforcement chính xác (lockdown/incident/tier4-mission-critical) —
  không phải do plugin thiếu hỗ trợ.
- Hệ quả không đổi: route/consumer-group nào đang để `policy: local`
  (mặc định khi không khai `policy`) mà chạy N node phía sau LB → ngưỡng
  hiệu lực thực tế = `limit × N` (hoặc `limit / N` mỗi node, tuỳ cách
  diễn giải). Muốn có trần toàn cục thật sự, chuyển sang `policy: redis`.
- Giá trị **duy nhất thật sự không có** ở bản community: `redis-sentinel`
  (chỉ có ở API7 Enterprise ≥3.8.19). Dùng Sentinel với bản community
  phải qua lớp VIP (HAProxy+Keepalived) rồi khai `policy: redis` trỏ vào
  VIP đó.
  khi định cỡ ngưỡng.

## apisix_config/config-{DC_PROFILE).yaml:103-110 — `plugin_attr.prometheus`

Cơ chế: APISIX mở HTTP server riêng tại `export_addr` để Prometheus server
scrape (pull model). `export_addr.ip: 0.0.0.0` để VM khác scrape được, không
chỉ localhost. Port `9091` chọn để tránh conflict với các port APISIX đang
dùng (80/443/16443/19443). `export_uri` đổi từ default `/metrics` sang
`/apisix/prometheus/metrics` để tránh conflict với nginx-exporter đang chạy
trên cùng host. `metric_prefix: "apisix_"` — prefix cho toàn bộ metric name
(`apisix_http_status`, `apisix_bandwidth`...).

**Verify sau khi đổi cấu hình:**
```bash
curl http://172.27.2.206:9091/apisix/prometheus/metrics | grep apisix_http
```

**Scrape config phía Prometheus (tham khảo — không phải file này quản lý):**
```yaml
job_name: apisix-hcm
metrics_path: /apisix/prometheus/metrics   # KHÔNG phải /metrics
static_configs:
  - targets: ['172.27.2.206:9091']
    labels: {node: sb-s3-lb-api6-hcm-1, component: apisix, dc: hcm}
```

**Cảnh báo vận hành:**
- Metric chỉ có data khi route bật `prometheus: {}` (xem route trong
  `apisix-hcm.yaml`).
- Đổi port/path → phải thông báo lại team Observability để cập nhật scrape
  config.
- Thay đổi bất kỳ giá trị nào trong `plugin_attr` yêu cầu **restart container**
  (không hot-reload như `apisix-hcm.yaml`).

## [ĐÃ GỠ KHỎI FILE] Loki logger qua `plugin_attr.loki-logger`

Trước đây file có sẵn khối `plugin_attr.loki-logger` (bị comment, chưa từng
active) để định nghĩa default cho plugin push log lên Loki. Khối này **đã
được thay thế hoàn toàn bằng global rule** tại
`global_rules/global-loki-logger.yaml` (bật cho TẤT CẢ route), nên đã xoá khỏi
`config-{DC_PROFILE).yaml` để tránh trùng lặp nguồn cấu hình.

Ghi chú lại nội dung/cơ chế cho người cần đối chiếu sau này:
- Cơ chế: APISIX chủ động HTTP POST log vào Loki sau mỗi request (push model,
  ngược với Prometheus là pull model) — không cần agent/Promtail trên VM.
- `endpoint_addrs`: Loki push endpoint — verify bằng
  `curl .../loki/api/v1/labels` phải trả 200.
- `tenant_id`: giá trị header `X-Scope-OrgID` — bắt buộc với Loki
  multi-tenant của team Observability.
- `batch_max_size`/`batch_max_age`: gom log trước khi push, tránh gọi HTTP mỗi
  request.
- `ssl_verify: false`: cert Loki là private CA nội bộ, APISIX container không
  verify được.
- `log_labels` trong `plugin_attr` chỉ là DEFAULT — route/global_rule có thể
  override riêng.
- Đổi endpoint/tenant_id → phải đồng bộ cả hai nơi: file này (nếu còn dùng
  làm default) và `global_rules/global-loki-logger.yaml`.

**Lệnh verify khi bật lại (tham khảo):**
```bash
docker logs apisix-standalone --tail 20 | grep -i loki

curl -s -H "X-Scope-OrgID: vnpaycloud" \
  "https://maas-service-logs.infiniband.vn/loki/api/v1/query_range" \
  --data-urlencode 'query={vnpaycloud_service="apisix",region="HCM"}' \
  --data-urlencode 'limit=5' | python3 -m json.tool
```

## apisix_config/config-{DC_PROFILE).yaml:124-199 — `plugins` (danh sách 75 plugin built-in)

Toàn bộ danh sách lấy trực tiếp từ container `apisix-standalone`, file
`apisix/cli/config.lua` — verify lần gần nhất: **2026-07-08**.

**Loại trừ có chủ đích:** plugin `server-info` — đã deprecated, sẽ bị xoá ở
version APISIX tương lai, KHÔNG thêm vào danh sách.

**Cần verify lại danh sách này mỗi khi upgrade version APISIX**, vì danh sách
plugin mặc định trong `config.lua` có thể thay đổi giữa các version.

## apisix_config/config-{DC_PROFILE).yaml:187-188 — `serverless-post-function` / `serverless-pre-function`

Không nằm trong nhóm liệt kê tự nhiên theo alphabet gốc — được thêm có chủ
đích, bắt buộc phải bật cho:
- `serverless-pre-function`: global rule inject header + cảnh báo soft-limit.
- `serverless-post-function`: strip `JSESSIONID` của CMC + cảnh báo soft-limit
  cho các service liên quan.

## apisix_config/config-{DC_PROFILE).yaml:201-206 — Nhóm plugin auth (basic-auth, hmac-auth, jwt-auth, key-auth, openid-connect, request-validation)

Nhóm plugin này **KHÔNG nằm trong danh sách default** của `config.lua` — nghĩa
là APISIX gốc không tự động enable nếu không khai báo tường minh trong
`config.yaml`. Xác nhận đây là bổ sung **thủ công** từ giai đoạn triển khai
đầu, không phải mặc định của APISIX gốc.

## apisix_config/config-{DC_PROFILE).yaml:207-210 — Custom plugin nội bộ

5 plugin Lua tự viết, không thuộc APISIX gốc:

| Plugin                                | Chức năng                                              |
|----------------------------------------|----------------------------------------------------------|
| `custom.s3-normalizer-bucket-name`     | S3 API gateway — normalize vhost→path, validate bucket   |
| `custom.cmc-validator-bucket-name`     | CMC Portal — validate bucket name khi tạo bucket qua UI  |
| `custom.s3-accesskey-extractor`        | Extract AKID từ request cho rate-limit theo access key   |
| `custom.s3-bucket-name-consumer`       | Resolve bucket name → Consumer object cho QoS/consumer group |
| `custom.s3-traffic-classifier`         | Phân loại Authenticated/SNAT/Anonymous cho Layer 2 Dynamic Policy |

### apisix_config/config-{DC_PROFILE).yaml:207-210 — So sánh 5 custom plugin theo trục dữ liệu/route/phase — vì sao không gộp

**Chỗ đọc chung** cho câu hỏi "các file trông giống nhau, gộp lại được
không" — chi tiết từng file xem tại đúng heading `Toàn file` tương ứng (link
nhảy tới):

| Plugin | Trục dữ liệu | Route | Phase | Input | Output |
|---|---|---|---|---|---|
| [`s3-normalizer-bucket-name`](#pluginscustoms3-normalizer-bucket-namelua1-139-toàn-file) | Bucket name | S3 API (SDK/CLI) | `rewrite` | Host/URI (vhost + path style) | `ctx.s3_bucket_name` + header `X-S3-Bucket-Name`; 400 JSON nếu sai |
| [`cmc-validator-bucket-name`](#pluginscustomcmc-validator-bucket-namelua1-180-toàn-file) | Bucket name | CMC Portal (browser) | `access` (bắt buộc — cần đọc POST body) | POST form field `bucketName` | Redirect 302 về trang lỗi portal, hoặc 400 JSON (host lạ) |
| [`s3-bucket-name-consumer`](#pluginscustoms3-bucket-name-consumerlua1-135-toàn-file-plugin-phức-tạp-nhất-có-lịch-sử-fix-crash-nghiêm-trọng) | **Không phải extraction** — resolve Consumer | S3 API | `rewrite`, phụ thuộc cứng `ctx.s3_bucket_name` (chạy sau normalizer) | `ctx.s3_bucket_name` | `ctx.consumer` qua `consumer_mod.attach_consumer()` |
| [`s3-accesskey-extractor`](#pluginscustoms3-accesskey-extractorlua1-106-toàn-file) | AKID — trục hoàn toàn khác bucket name | S3 API | `rewrite`, độc lập (không phụ thuộc 4 file kia) | Header `Authorization` / query presigned | `ctx.s3_access_key` + header `X-S3-Access-Key` |
| [`s3-traffic-classifier`](#pluginscustoms3-traffic-classifierlua1-183-toàn-file) | **Không phải extraction** — gắn nhãn nhóm Authen/SNAT/Anon cho Layer 2 | S3 API | `rewrite`, phụ thuộc cứng `ctx.s3_bucket_name` (chạy sau normalizer, priority 9000 < 10005) | `ctx.s3_bucket_name` + `ctx.var.remote_addr` + `plugin_metadata.snat_cidrs` | Header `X-SNAT`/`X-SNAT-Ip` hoặc `X-Real-Ip` (loại trừ lẫn nhau, không set gì nếu đã có bucket) |

**Vì sao không gộp**, dù `s3-normalizer` và `cmc-validator` bề ngoài giống
nhau nhất (cả 2 cùng gọi `isBucket()` từ thư viện dùng chung
`s3-validator-bucket-name-utils.lua` — nghĩa là chỉ có **1 bộ quy tắc syntax
bucket-name duy nhất**, không phải 2 luồng validate khác nhau):

- **`s3-normalizer` + `cmc-validator`:** kỹ thuật gộp được (1 file Lua vẫn
  định nghĩa được cả `_M.rewrite()` lẫn `_M.access()`) — nhưng route hoàn
  toàn không overlap (S3 API vs CMC portal, 2 kênh khác nhau), khác phase,
  khác response khi lỗi (400 JSON vs redirect browser). Gộp sẽ tăng blast
  radius: sửa rule cho 1 kênh dễ vô tình ảnh hưởng sang kênh kia.
- **`s3-bucket-name-consumer`:** không cùng việc "extract" — là resolve
  Consumer, phụ thuộc cứng vào output của `s3-normalizer` qua
  `ctx.s3_bucket_name` (priority 9500 < 10005 → chạy sau, xem
  [priority order](#pluginscustoms3-bucket-name-consumerlua1-135-toàn-file-plugin-phức-tạp-nhất-có-lịch-sử-fix-crash-nghiêm-trọng)).
- **`s3-accesskey-extractor`:** trục dữ liệu khác hẳn (AKID, không phải
  bucket name), priority 2510 độc lập, không phụ thuộc 4 file kia.
- **`s3-traffic-classifier`:** cùng phụ thuộc `ctx.s3_bucket_name` như
  `s3-bucket-name-consumer` nhưng mục đích hoàn toàn khác — 1 bên resolve
  Consumer (Layer 3), 1 bên gắn nhãn nhóm rate-limit (Layer 2). Không gộp
  vào `s3-bucket-name-consumer` vì 2 concern độc lập: sửa logic resolve
  Consumer không nên có nguy cơ ảnh hưởng logic phân loại SNAT/Anonymous và
  ngược lại. Không gộp vào `s3-normalizer` vì đó là plugin Layer 0
  (extraction/validate, chạy sớm) còn đây là chuẩn bị dữ liệu riêng cho
  Layer 2 — khác tầng trách nhiệm trong kiến trúc 4 Layer.

**Kết luận:** giữ nguyên 5 file — mỗi file đúng nguyên tắc single-
responsibility, không phải trùng lặp cần dọn.

---

## [ĐÃ GỠ KHỎI FILE] Cơ chế chung — Consumer Group theo bucket S3 (áp dụng cho cả 3 file `consumer-group-s3bucket-internal.yaml` / `-partner.yaml` / `-restricted.yaml`)

Cả 3 file này trước đây có chung 1 khối comment giải thích ở đầu file (giống hệt
nhau trên cả 3), nay đã xoá khỏi cả 3 file để tránh lặp lại cùng 1 đoạn giải
thích 3 lần. Nội dung được gom về đây, áp dụng chung cho cả 3.

**Mục đích:** đây là tầng policy áp theo **tên bucket S3 cụ thể**, khác hoàn
toàn với các consumer group cũ (`cg-standard`/`cg-premium`/`cg-internal-batch`
— dùng cho control-plane API qua `key-auth`, đã xoá). 3 group này thuộc nhánh
riêng cho S3 dataplane, resolve theo **tên bucket** (không phải AKID/chữ ký
SigV4).

**Cơ chế** (chi tiết xem `plugins/custom/s3-bucket-name-consumer.lua`):
```
request → s3-normalizer-bucket-name (parse bucket từ URL, set ctx.s3_bucket_name)
        → s3-bucket-name-consumer (bucket có trong consumers.yaml không?)
        → CÓ  → attach_consumer() → merge plugin của group_id tương ứng
                 (Consumer Group nằm TRÊN Route/Plugin Config trong thứ tự
                 merge — policy ở đây sẽ ĐÈ policy mặc định của route)
        → KHÔNG → bỏ qua, dùng nguyên policy mặc định ở Route/Plugin Config
                 (VD plugin-config-traffic-classifier: limit-count 4000 req/s theo AKID)
```

**Sự kiện — trạng thái tại thời điểm 2026-07-13:** cả 3 group đang ở **soft
mode** — chỉ quan sát, không enforce. `internal` và `partner` đã bật thật
`limit-conn`/`limit-count`; riêng `restricted` vẫn đang comment out phần
`limit-conn`/`limit-count`, chỉ có `ip-restriction` đang chạy thật (xem phần
cảnh báo riêng cho `restricted.yaml` bên dưới). Cả 3 đều bật `response-rewrite`
để xác nhận resolve đúng qua header `X-Debug-Consumer-Resolved`.

**Chuyển sang enforcement thật:** bỏ comment phần plugin tương ứng ngay trong
từng file. Không cần sửa route hay file `.lua` — chỉ sửa file
`consumer-group-s3bucket-*.yaml`, `gitsync` tự pull (≤30s), APISIX tự
hot-reload, không cần restart container.

**Thêm bucket mới vào 1 group:** thêm entry trong `consumers.yaml` với
`username = "bucket-<tên-bucket-thật>"` (prefix `bucket-` **bắt buộc** — xem
mục NAMESPACE COLLISION trong `s3-bucket-name-consumer.lua`) và `group_id` trỏ
đúng 1 trong 3 id: `consumer-group-s3bucket-internal` /
`consumer-group-s3bucket-partner` / `consumer-group-s3bucket-restricted`.

---

## apisix_routes/consumer_groups/consumer-group-s3bucket-internal.yaml:1-26 — Toàn file

**Ý nghĩa:** bucket nội bộ (team/dự án của chính hạ tầng) — độ tin cậy cao
nhất trong 3 group, traffic nội bộ thường ổn định và kiểm soát được nguồn
gốc. Không cần `ip-restriction` — bucket internal không cần allowlist theo IP.

### apisix_routes/consumer_groups/consumer-group-s3bucket-internal.yaml:4-11 — `limit-conn`

Giới hạn **connection đồng thời** theo `consumer_name` (= bucket đã resolve).
`rejected_code: 429` nghĩa là APISIX tự chặn ngay tại gateway, request chưa
từng chạm tới backend Cloudian khi vượt quota.

### apisix_routes/consumer_groups/consumer-group-s3bucket-internal.yaml:13-21 — `limit-count`

Giới hạn **request/giây** theo `consumer_name`. `allow_degradation: true` —
nếu Redis (nơi lưu state rate-limit) lỗi, APISIX **cho request đi qua** thay
vì trả 500 cho toàn bộ traffic (fail-open, ưu tiên uptime hơn enforce cứng
nhắc khi hạ tầng phụ trợ có sự cố). `show_limit_quota_header: true` — trả
header `X-RateLimit-*` để client/dev tự thấy quota còn lại.

### apisix_routes/consumer_groups/consumer-group-s3bucket-internal.yaml:23-26 — `response-rewrite`

Inject header `X-Debug-Consumer-Resolved` = tên consumer đã resolve được, dùng
để verify resolve đúng bucket → consumer → group trong lúc soft mode (chưa
enforce thật), không phục vụ mục đích rate-limit.

**⚠ Cần Mercy xác nhận — số liệu trong file KHÔNG khớp với quota dự kiến đã
trao đổi trước đó:** `limit-count` hiện đặt `count: 2, time_window: 1` (tức
**2 req/s**), trong khi quota dự kiến cho group internal (rộng nhất trong 3
group) là **20000 req/s**. Nếu 2 req/s là giá trị **cố ý đặt thấp để test soft
mode** trước khi ramp dần lên 20000, không có gì sai — nhưng nếu ai đó bật
enforcement thật (bỏ comment, hiện tại 2 file này đã bật thật rồi) mà chưa
sửa lại con số, bucket nội bộ sẽ bị giới hạn còn **2 req/s** thay vì 20000,
tương đương outage cho toàn bộ traffic nội bộ. Cần xác nhận lại giá trị đúng
trước khi coi đây là cấu hình production-ready.

---

## apisix_routes/consumer_groups/consumer-group-s3bucket-partner.yaml:1-26 — Toàn file

**Ý nghĩa:** bucket của đối tác/khách hàng đã đăng ký chính thức (không phải
anonymous, không phải nội bộ) — cần quota riêng tách khỏi mặc định AKID-based
(`plugin-config-traffic-classifier`: 4000 req/s dùng chung mọi AKID chưa đăng ký), để đảm
bảo SLA cho đối tác không bị ảnh hưởng bởi traffic AKID khác cùng chung route.

Cấu trúc plugin giống hệt `consumer-group-s3bucket-internal.yaml` (xem note
phần `limit-conn`/`limit-count`/`response-rewrite` ở trên), chỉ khác giá trị
ngưỡng: `conn: 4`, `count: 4`.

**⚠ Cần Mercy xác nhận — cùng loại vấn đề như file `internal`:** quota dự
kiến khi bật thật là **4000 req/s** ("bằng đúng mặc định hiện tại, coi như
đảm bảo SLA riêng theo consumer_name thay vì ưu đãi thêm"), nhưng giá trị
đang cấu hình trong `limit-count` là `count: 4, time_window: 1` — tức **4
req/s**, thấp hơn dự kiến 1000 lần. File này (giống `internal`) đã bật
enforcement thật (không còn comment), nên nếu 4 là giá trị test còn sót lại
chưa cập nhật, đối tác đang bị giới hạn còn 4 req/s trên production ngay bây
giờ — cần xác nhận và sửa gấp nếu đúng là chưa cập nhật.

Nếu về sau cần tách quota riêng theo từng đối tác cụ thể (không dùng chung 1
ngưỡng cho tất cả partner), cân nhắc tách thêm group con (VD
`consumer-group-s3bucket-partner-premium`) thay vì sửa số trực tiếp ở group
này.

---

## apisix_routes/consumer_groups/consumer-group-s3bucket-restricted.yaml:1-32 — Toàn file

**Ý nghĩa:** bucket nhạy cảm (dữ liệu private/tài chính/compliance...) — cần
**hạn chế theo nguồn truy cập**, không chỉ giới hạn tốc độ.

### apisix_routes/consumer_groups/consumer-group-s3bucket-restricted.yaml:5-22 — `limit-conn` / `limit-count` (đang comment, chưa bật)

Cấu trúc giống hệt group `internal`/`partner` nhưng **đang tắt** — group này
không có quota mặc định vì mục tiêu chính là allowlist theo nguồn, không phải
giới hạn tốc độ. Muốn vừa allowlist vừa giới hạn tốc độ, bỏ comment khối này
và tự chỉnh `conn`/`count` phù hợp (không có số dự kiến sẵn cho group này,
khác với `internal`/`partner`).

### apisix_routes/consumer_groups/consumer-group-s3bucket-restricted.yaml:24-27 — `ip-restriction`

**🔴 Cảnh báo nghiêm trọng — sai lệch giữa ý định thiết kế và cấu hình thực
tế:** mục đích ban đầu của group này là **whitelist** — chỉ IP trong danh
sách mới được truy cập bucket nhạy cảm, còn lại bị từ chối dù request hợp lệ
(bucket có thật, chữ ký SigV4 đúng). Nhưng cấu hình hiện tại dùng
**`blacklist: ["10.3.14.41"]`**, không phải `whitelist` — theo cơ chế
`ip-restriction` của APISIX, `blacklist` có nghĩa **ngược lại hoàn toàn**:
chặn đúng IP đó, còn **lại tất cả IP khác đều được đi qua bình thường**.

Với 1 bucket được đặt tên "restricted" (dữ liệu private/compliance), cấu hình
`blacklist` 1 IP duy nhất **không đạt được mục tiêu hạn chế truy cập** — thực
chất đang mở cho toàn bộ Internet trừ đúng 1 địa chỉ IP nội bộ (theo comment
gốc, IP `10.3.14.41` là địa chỉ của máy cá nhân dùng để test trong lúc debug,
không phải danh sách nguồn được phép).

Dòng `# whitelist: ["10.3.14.41"]` (đã comment) cho thấy đây đúng là hướng
thiết kế ban đầu (whitelist), còn `blacklist` hiện tại chỉ là giá trị dùng để
**verify plugin chặn đúng IP test** trong lúc debug, chưa phải cấu hình cuối
cùng. **Trước khi coi group này production-ready, bắt buộc phải đổi lại thành
`whitelist` với dải IP thật** (VPN nội bộ / subnet ứng dụng được phép truy
cập bucket nhạy cảm) — nếu không, ai cũng truy cập được trừ 1 máy test.

Tham khảo: [APISIX `ip-restriction` plugin docs](https://apisix.apache.org/docs/apisix/plugins/ip-restriction/)
— `whitelist` và `blacklist` là hai field loại trừ lẫn nhau, không dùng đồng
thời; ý nghĩa đúng như mô tả ở trên.

### apisix_routes/consumer_groups/consumer-group-s3bucket-restricted.yaml:29-32 — `response-rewrite`

Giống 2 group kia — chỉ để debug resolve, không ảnh hưởng enforcement.

---

## 🔧 Đính chính 2 note cũ trong file này (sau khi đối chiếu trực tiếp với `global_rules/*.yaml`)

Phần note về `config-hcm.yaml` ở trên (mục Loki logger và mục
`plugin_attr.prometheus`) được viết **trước khi có source code thật của
`global_rules/`**, dựa trên suy đoán hợp lý nhưng chưa verify — nay đối chiếu
xong, có 2 chỗ cần sửa lại để không gây hiểu lầm cho người đọc sau. Theo đúng
nguyên tắc "kết luận phải từ trạng thái hiện tại, không suy luận từ quá khứ":

1. **Loki KHÔNG phải pipeline log đang hoạt động.** Note cũ viết:
   *"[plugin_attr.loki-logger] đã được thay thế hoàn toàn bằng global rule tại
   `global_rules/global-loki-logger.yaml` (bật cho TẤT CẢ route)"* — sai. Thực
   tế `global_rules/global-loki-logger.yaml` **toàn bộ file đang bị comment**
   (xem mục bên dưới), tức đang tắt hoàn toàn. Pipeline log thật đang chạy là
   **Kafka** (`global_rules/global-kafka-logger.yaml`), Loki chỉ nhận log
   gián tiếp qua consumer đọc từ Kafka topic, không phải APISIX push thẳng.

2. **Prometheus đang thu metric GLOBAL, không chỉ per-route.** Note cũ ở mục
   `plugin_attr.prometheus` viết *"Metric chỉ có data khi route bật
   `prometheus: {}`"* — đúng về mặt cơ chế plugin, nhưng **không còn phản ánh
   đúng cấu hình hiện tại**: `global_rules/global-prometheus.yaml` đang
   **active** (không comment dòng nào), nghĩa là metric đang được thu cho
   **TẤT CẢ route**, không phụ thuộc route có khai `prometheus: {}` riêng hay
   không. Xem chi tiết ở mục `global-prometheus.yaml` bên dưới.

---

## apisix_routes/global_rules/global-abuse-guard.yaml:1-26 — Toàn file (Vòng 1 — Priority 1)

**Mục đích:** guard chống 1 IP đơn lẻ làm sập cả hệ thống — áp dụng cho **mọi**
route/service, không phân biệt tier. Ngưỡng ở đây phải đặt **RỘNG**, vì đây là
lưới an toàn cuối cùng (circuit breaker cấp hạ tầng), còn QoS chi tiết theo
từng tier là việc của `services`/`consumer_groups` bên dưới.

**⚠ Ràng buộc thiết kế quan trọng — dễ bị phá vỡ khi thêm tier mới:** ngưỡng
global ở đây **phải luôn cao hơn** mọi trần per-IP của bất kỳ tier nào bên
dưới. Nếu ai đó thêm 1 tier mới với trần per-IP cao hơn 10000 conn mà quên đối
chiếu lại file này, ngưỡng global sẽ **vô tình trở thành trần thật** của tier
đó — sai hoàn toàn thiết kế phân tier ban đầu.

### apisix_routes/global_rules/global-abuse-guard.yaml:4-11 — `limit-conn`

Giới hạn **concurrent connection theo IP** (`key: remote_addr`), không phải
req/s. Với object storage, đây mới là chỉ số saturation thật: 1 request PUT
5GB giữ 1 connection trong hàng phút — 50 req/s nghe có vẻ nhỏ, nhưng thực tế
có thể là 50 upload 5GB chạy song song, ăn hết pool connection/băng thông của
node. Concurrency quan trọng hơn req/s trong bối cảnh này.

```yaml
limit-conn:
  conn: 10000
  burst: 5000
  default_conn_delay: 0.1
  key_type: var
  key: remote_addr
  rejected_code: 429
  rejected_msg: "[APISIX-QOS:global-guard]: Too many concurrent connections from your IP..."
```

`rejected_code: 429` được set tường minh — **không dùng mặc định 503** của
plugin, để user/dev phân biệt rõ đây là bị APISIX chặn do vượt ngưỡng (429 =
Too Many Requests), không phải lỗi backend (503 = Service Unavailable).

**⚠ ĐÍNH CHÍNH (2026-08-14):** bản ghi trước đây tại mục này khẳng định
*"`limit-conn` không có policy `redis`, khác với `limit-count`"* — **SAI**,
đã kiểm tra lại với docs chính thức Apache APISIX (community, không phải
API7) và cần sửa lại như sau.

**Thực tế đã xác nhận:** `limit-conn` **CÓ** hỗ trợ `policy: local` /
`redis` / `redis-cluster` — giống hệt `limit-count`, cùng schema
(`policy` enum 3 giá trị, default `local`). Hỗ trợ Redis cho `limit-conn`
đã có từ PR
[#10866](https://github.com/apache/apisix/pull/10866) (`feat: add redis
and redis-cluster in limit-conn`), tức là có **trước** APISIX 3.15 rất
lâu — không phải giới hạn của bản 3.15 hay bản community như ghi nhận cũ.
Dẫn chứng chính thức:
[limit-conn.md](https://github.com/apache/apisix/blob/master/docs/en/latest/plugins/limit-conn.md)
— "*The policy for rate limiting counter. If it is local, the counter is
stored in memory locally. If it is redis, the counter is stored on a
Redis instance.*"

**Cái duy nhất bản community thật sự KHÔNG có** (điểm này giữ nguyên,
xác nhận đúng): `policy: redis-sentinel`. Giá trị này chỉ tồn tại ở API7
Enterprise (từ bản 3.8.19), không có trong Apache APISIX community —
xác nhận qua [docs.api7.ai/hub/ai-rate-limiting/configuration](https://docs.api7.ai/hub/ai-rate-limiting/configuration).
Muốn dùng Sentinel với bản community thì vẫn phải qua lớp VIP
(HAProxy+Keepalived) trỏ `policy: redis` vào VIP đó — xem
`redis-local-tradeoff.html` Mục 04.

**Giới hạn kỹ thuật thật sự cần biết ở `global-abuse-guard`:** route này
đang **cố ý** để `limit-conn` chạy `policy: local` (mặc định, không khai
`policy` trong YAML) — đây là **lựa chọn thiết kế**, không phải giới hạn
kỹ thuật của plugin. Lý do giữ local: traffic ở tầng này là **mọi IP vãng
lai** chạm gateway (lưới an toàn cuối cùng), cardinality cực cao — đưa
qua Redis vừa tốn RAM (mỗi IP là 1 key) vừa cộng round-trip Redis vào
100% request chỉ để chặn thô ban đầu. Xem `redis-local-tradeoff.html`
Mục 03, hàng `global-abuse-guard`.

Vì đang chạy `policy: local`, hệ quả **vẫn đúng như ghi nhận cũ**: chạy N
node phía sau LB → ngưỡng hiệu lực thực tế = `conn / N` mỗi node. Muốn
giữ đúng trần 10000 conn/IP toàn cụm khi scale ngang, phải tự chia lại số
này theo N (hoặc cân nhắc chuyển sang `policy: redis` nếu sau này thấy
cardinality kiểm soát được) — plugin không tự làm điều đó.

### apisix_routes/global_rules/global-abuse-guard.yaml:13-25 — `serverless-pre-function` (inject `X-Route-Id` / `X-Service-Id` / `X-Consumer`)

**Vì sao cần plugin này (đọc trước khi sửa/xoá):** APISIX **không có sẵn**
nginx variable `$route_id` / `$service_id` / `$consumer_name` để dùng trực
tiếp trong `nginx_config.http.access_log_format`. Các giá trị này chỉ tồn tại
dưới dạng field trong Lua table (`ctx.matched_route.value.id`,
`ctx.consumer.username`) — truy cập được trong Lua code, nhưng **nginx core
không tự nhận diện** `$route_id` như một compiled-in variable. Khai báo thẳng
`"$route_id"` trong `access_log_format` sẽ làm nginx **crash lúc compile
config**:

```
nginx: [emerg] unknown "route_id" variable
```

→ container rơi vào crash loop (`init → init_etcd → emerg → restart → lặp
lại`) — đây là lỗi nghiêm trọng, không phải cảnh báo, phải tránh tuyệt đối.

**Cách workaround hoạt động:** chạy ở `phase: rewrite` (trước khi log ghi ở
`log` phase, cuối request). Tự set 2-3 header **request** từ Lua
(`ngx.req.set_header`), lấy dữ liệu từ `ctx.matched_route` (đã được APISIX
core populate sẵn ở routing phase, trước rewrite) và `ctx.consumer`.
`access_log_format` (khai ở `config-hcm.yaml`) sau đó đọc lại qua
`$http_x_route_id` / `$http_x_service_id` / `$http_x_consumer` — tiền tố
`$http_*` đọc **request header**, khác với `$sent_http_*` dùng cho **response
header** (VD các field rate-limit `rt_limit`/`rt_remaining` trong cùng
`access_log_format`).

```lua
return function(conf, ctx)
  ngx.req.set_header("X-Route-Id", ctx.matched_route and ctx.matched_route.value.id or "-")
  ngx.req.set_header("X-Service-Id", ctx.matched_route and ctx.matched_route.value.service_id or "-")
  -- Global rule chạy trước plugin local. Với S3, custom.s3-qos-consumer
  -- attach Consumer SAU block này nên access log hiện vẫn có thể là "-".
  -- key-auth/JWT là một cách attach Consumer khác, không phải điều kiện duy nhất.
  ngx.req.set_header("X-Consumer", ctx.consumer and ctx.consumer.username or "-")
end
```

**Vì sao đặt ở `global_rules` (không phải từng route/service):** áp dụng 1
lần cho **tất cả** route, không cần sửa hàng chục route file riêng lẻ. Quan
trọng hơn: route/service nào có `serverless-pre-function` **riêng** vẫn
**không mất** phần inject header này, vì `global_rules` luôn chạy kèm — khác
với cách merge plugin cùng tên ở route/service, nơi khai lại cùng 1 plugin sẽ
**đè** (override) plugin cha thay vì cộng dồn.

**⚠ Cảnh báo vận hành — header này gửi thẳng lên upstream (Cloudian/Ceph),
không chỉ để log:** `ngx.req.set_header()` sửa **request** trước khi proxy đi
tiếp lên backend, nghĩa là Cloudian/Ceph cũng nhận được 3 header này, không
chỉ riêng APISIX dùng để log. Nếu backend không cần thấy header lạ này, có thể
cân nhắc chuyển sang `serverless-post-function` (`header_filter` phase, set
vào **response** thay vì **request**). Đánh đổi: response header thì **client
cũng nhìn thấy được** — có thể không muốn lộ `route_id` nội bộ ra ngoài
public. **Hiện tại chưa xử lý vấn đề này**, cần đánh giá thêm nếu thấy không
phù hợp với yêu cầu bảo mật.

**Khi cần chỉnh:**
- Đổi tên header → phải sửa **cả 2 chỗ**: ở file này VÀ trong
  `access_log_format` (`$http_x_route_id` phải khớp tên header `X-Route-Id`
  viết thường, gạch dưới thay gạch ngang).
- Muốn thêm field khác từ `ctx.matched_route` (VD `upstream_id` nếu route
  dùng `upstream_id` thay vì `upstream` inline) → đọc thêm
  `ctx.matched_route.value.*`.

---

## apisix_routes/global_rules/global-http-logger.yaml:1-22 — Toàn file (ĐANG TẮT — template dự phòng)

**Toàn bộ file đang comment** (kể cả `global_rules:` ở dòng 1) — đây là
template dự phòng, **không** đang chạy. Pipeline log thật hiện tại là Kafka
(xem `global-kafka-logger.yaml`).

**Mục đích khi cần dùng:** đẩy access log lên **bất kỳ HTTP endpoint nào**
nhận JSON — generic hơn `loki-logger` và `kafka-logger`, dùng khi endpoint
đích không phải Loki native hoặc Kafka mà là:
- Elasticsearch (`_bulk` API)
- Custom log receiver / webhook
- Logstash HTTP input
- Vector HTTP source
- Splunk HEC (HTTP Event Collector)
- Bất kỳ service nào nhận `POST` JSON

**Khác với `loki-logger`:** `loki-logger` tự format payload theo đúng chuẩn
Loki push API; `http-logger` gửi **raw JSON**, endpoint phải tự parse — linh
hoạt hơn nhưng phải tự đảm bảo endpoint hiểu đúng format JSON mà APISIX gửi.

```yaml
# global_rules:
#   - id: global-http-logger
#     plugins:
#       http-logger:
#         uri: "https://maas-service-logs.infiniband.vn/loki/api/v1/push"
#         headers:
#           Content-Type: "application/json"
#           X-Scope-OrgID: "vnpaycloud"
#         batch_max_size: 1000
#         batch_max_age: 5
#         max_retry_count: 3
#         retry_delay: 1
#         timeout: 3000
#         ssl_verify: false
#         concat_method: "new_line"
```

**Use case ví dụ khi cần bật:** team Observability chuyển sang dùng Logstash
HTTP input thay vì Loki; cần đẩy log song song sang Elasticsearch để search;
debug nhanh bằng cách trỏ `uri` về `webhook.site` để xem raw payload APISIX
gửi ra.

**Khi cần chỉnh để bật thật:**
1. Bỏ comment toàn bộ block, đổi `uri` thành endpoint thật.
2. Thêm/bớt `headers` theo yêu cầu endpoint (VD `Authorization: Bearer
   <token>` hoặc `X-Splunk-Token` cho Splunk HEC).
3. Cân nhắc tắt `global-kafka-logger.yaml` nếu không muốn đẩy log song song 2
   nơi cùng lúc (tốn thêm CPU/network mỗi request).

---

## apisix_routes/global_rules/global-kafka-logger.yaml:1-34 — Toàn file (ĐANG ACTIVE — pipeline log chính hiện tại)

**Đây là pipeline log thật đang chạy** — dòng `# status: 0` ở dòng 3 đang bị
comment, nghĩa là giá trị `status: 0` (tắt rule) **không áp dụng**, rule mặc
định ở trạng thái **enabled**.

**Vì sao Kafka thay vì Loki push trực tiếp:** `loki-logger` push HTTP trực
tiếp **không có buffer/queue** → mất log khi Loki down/restart/network
glitch. Đã xác nhận qua thực tế: log bật từ 29/6 nhưng Grafana chỉ thấy
~600 dòng — tức phần lớn log bị rơi mất giữa đường. Kafka đóng vai trò buffer
trung gian bền vững (retention 3 ngày):

```
APISIX → Kafka (durable, retention 3 ngày) → Consumer (Logstash/Vector/Flink) → Loki/ES
```

**Ưu điểm so với loki-logger trực tiếp:**
- Back-pressure handling: Loki chậm/down → log nằm trong queue, không mất.
- Fan-out: 1 topic → nhiều consumer (Loki + Elasticsearch + data warehouse).
- Replay: consumer lỗi → rewind offset, xử lý lại từ đầu.
- Throughput cao hơn (>5k req/s): Kafka xử lý tốt hơn HTTP push liên tục.

**Nhược điểm:** phụ thuộc thêm Kafka cluster (phải phối hợp team
Observability); cần dựng consumer pipeline (Kafka → Logstash/Vector → Loki);
phức tạp hơn — thêm component, thêm điểm có thể lỗi.

### apisix_routes/global_rules/global-kafka-logger.yaml:6-24 — `brokers` (đa ứng dụng — 1 file dùng chung mọi DC)

```yaml
brokers:
  - host: "172.26.24.80"
    port: 31421
    sasl_config:
      mechanism: "SCRAM-SHA-512"
      user: "${{KAFKA_SASL_USER}}"
      password: "${{KAFKA_SASL_PASSWORD}}"
  # ... 2 broker còn lại cùng host, khác port (30215, 30412)
```

3 broker cùng 1 host `172.26.24.80` nhưng khác port — đúng theo mô hình
Strimzi (Kafka trên Kubernetes) expose từng broker qua NodePort riêng, không
phải 3 máy vật lý khác nhau. Auth SASL SCRAM-SHA-512, user/password inject từ
biến môi trường (`KAFKA_SASL_USER`/`KAFKA_SASL_PASSWORD`) qua docker-compose,
không hardcode trong file.

**⚠ Điểm cần lưu ý — nhãn comment không khớp thực tế:** trong bản `-cũ.yaml`,
khối brokers đang active này được đặt dưới tiêu đề comment **"Broker config —
không có SSL"**, nhưng plugin config bên dưới (dòng 31) vẫn set `ssl: true`.
Đây là nhãn còn sót lại từ 1 bản draft trước, **không phản ánh đúng hành vi
thật** — thực tế kết nối VẪN dùng TLS (đã xác nhận TLS handshake thành công
với cả 3 broker trong quá trình verify Kafka cluster Strimzi/SASL_SSL). Khối
"có SSL" (host `172.16.x`, port `9093`) ngay phía trên bị comment mới đúng là
bản dự phòng dùng khi cần trỏ tới listener SASL_SSL chuẩn (port 9093) thay vì
NodePort hiện tại.

**⚠ Vì sao field `ssl`/`ssl_verify` hoạt động được — phụ thuộc vào patch nội
bộ:** schema gốc của plugin `kafka-logger` trên APISIX 3.15 (đã verify bằng
source code, kể cả tài liệu 3.17 mới nhất) **KHÔNG có field `ssl`/`ssl_verify`**.
Field này chỉ tồn tại vì có **patch nội bộ** (`1-patch-template-lua.sh`,
patch [5] — `kafka-logger.lua`) đã thêm field `ssl`/`ssl_verify` vào schema +
`broker_config`. Nếu patch này bị revert (VD do upgrade APISIX không áp lại
patch), field `ssl: true` sẽ bị schema coi là additional property không xác
định — APISIX 3.15 mặc định **cho phép** additional property (không fail
validation), nhưng plugin sẽ **âm thầm bỏ qua** field này, kết nối rơi về
PLAINTEXT — nếu broker listener yêu cầu bắt buộc TLS, kết nối sẽ reject ở
tầng protocol (không phải lỗi auth, dễ nhầm sang sai SASL credential khi
debug).

### apisix_routes/global_rules/global-kafka-logger.yaml:26 — `kafka_topic: "apisix-gateway-${{DC_PROFILE}}"`

**Đã verify thực nghiệm:** APISIX resolve `"${{VAR}}"` ở lớp đọc file dùng
chung, **TRƯỚC KHI** `config_yaml.lua` parse YAML — áp dụng cho **mọi** file
YAML mà APISIX đọc (kể cả `global_rules/*.yaml`), không riêng
`conf/config.yaml` như tài liệu chính thức mô tả. Đây là hành vi đã tự verify
qua thực nghiệm, không chỉ dựa theo docs.

**Cách verify lại khi nghi ngờ:** xem label `region` trên Loki sau khi
hot-reload — phải ra đúng giá trị literal `"hcm"` hoặc `"han"`, **không được**
là chuỗi literal `"${{DC_PROFILE}}"` chưa resolve.

**⚠ Cập nhật quan trọng khi upgrade lên APISIX 3.17.0 — chính đoạn note này
từng là nguyên nhân gây crash:** cơ chế "resolve trước khi parse" mô tả ở
trên vẫn đúng, nhưng ở APISIX 3.17.0 nó áp dụng **kể cả trên phần text nằm
trong comment** (vì lúc resolve, file còn là raw text, chưa phân biệt được
đâu là comment YAML). Bản thân file `global-kafka-logger.yaml` từng có 1
dòng comment minh hoạ dùng literal `"${{VAR}}"` (đặt "VAR" làm ví dụ chung
chung, không phải biến thật) — dòng đó khiến CLI init 3.17.0 đi tìm biến môi
trường tên `VAR`, không thấy → container crash-loop ngay từ bước init. Đã
sửa (xem section "🔧 Upgrade APISIX 3.15.0 → 3.17.0" cuối file). Từ giờ
**không viết literal `${{...}}` liền nhau trong bất kỳ comment nào** ở
`apisix_routes/`, kể cả để minh hoạ — dùng cách viết tách như "dollar
double-brace" thay thế.

### apisix_routes/global_rules/global-kafka-logger.yaml:28 — `batch_max_size: 1` (BẮT BUỘC = 1, không phải tối ưu hiệu năng)

**Đây là field quyết định cấu trúc JSON gửi lên Kafka, ảnh hưởng trực tiếp
tới việc Grafana/Loki có đọc được dashboard hay không** — không phải tham số
tối ưu hiệu năng thông thường. Theo đúng source code `kafka-logger.lua`:

```lua
if batch_max_size == 1 then
    data = entries[1]; data = core.json.encode(data)  -- {} — object đơn
else
    data = core.json.encode(entries)                  -- [{}] — mảng object
end
```

- `batch_max_size > 1` (mặc định 1000 nếu không set): nhiều entry gộp thành 1
  mảng JSON `[{...}, {...}, ...]` trước khi gửi — tiết kiệm số lần gọi
  producer, **nhưng** mỗi dòng log trong Loki lúc đó chứa NHIỀU request gộp
  chung → filter `| json` của LogQL **không parse được** (chỉ nhận object ở
  top-level, không nhận array) → toàn bộ query/dashboard dựa trên field JSON
  (route, status, uri...) lỗi `JSONParserErr`, và đếm log-line ≠ đếm request
  thật.
- `batch_max_size == 1`: mỗi request tạo đúng 1 message riêng, encode thành 1
  object JSON đơn `{...}` — **bắt buộc** để `| json` trong Loki hoạt động
  đúng và dashboard Grafana (bucket_name, top URI lỗi, error rate...) đọc
  đúng dữ liệu.

**Đánh đổi:** tăng tần suất gọi `producer:send()` (1 lần/request thay vì gộp
nhiều request/lần gọi), nhưng `lua-resty-kafka` vẫn tự gộp ở tầng network
riêng (`producer_batch_num`, mặc định 200, không bị field này ảnh hưởng) —
network I/O tới broker **không** tăng tương ứng 1:1 theo số request; overhead
chủ yếu là CPU (JSON encode nhỏ hơn nhưng gọi hàm nhiều hơn), đánh đổi hợp lý
để phục vụ dashboard Traffic & Errors chạy đúng.

### apisix_routes/global_rules/global-kafka-logger.yaml:30 — `# key: "$remote_addr"` (cố tình để tắt, không phải thiếu sót)

`key` (partition key cho Kafka) **cố tình không khai báo**, không phải quên.
Schema yêu cầu `key` type=string **không nullable** — khai `key: null` sẽ
fail schema validation. Omit hẳn field này = dùng round-robin partition mặc
định của `lua-resty-kafka`. Đây là quyết định đã thống nhất từ đầu để tránh
hot-partition khi traffic lệch nhiều về 1 IP/1 route (nếu dùng `$remote_addr`
hoặc `$uri` làm key, traffic tập trung sẽ dồn hết vào 1 partition).

### apisix_routes/global_rules/global-kafka-logger.yaml:34 — `api_version: 2`

Tương ứng patch nội bộ [5.b] — kích hoạt Kafka Message Format v1, giúp message
có timestamp thật (không phải timestamp do broker gán lúc nhận).

**[ĐÃ DỌN] Field chết `batch_num`:** bản `-cũ.yaml` từng có dòng
`# batch_num: 10` kèm ghi chú dài giải thích đây là field APISIX **âm thầm bỏ
qua** (schema cho phép additional property, `batch_num` không phải field hợp
lệ của `kafka-logger` — field thật là `producer_batch_num`, hoàn toàn khác ý
nghĩa, đó là tham số network-level của `lua-resty-kafka`, không liên quan gì
đến việc gộp log). Dòng này đã được xoá hẳn trong bản hiện tại — không cần
giữ lại nữa.

**Thông tin cần hỏi team Observability trước khi đổi broker/topic:**
Bootstrap servers, topic name, SASL mechanism (`PLAIN` |
`SCRAM-SHA-256` | `SCRAM-SHA-512`), SASL credentials, có bắt buộc TLS hay
không.

**Khi cần chỉnh:**
- Điền `brokers` + `kafka_topic` mới từ team Observability.
- Đổi DC → chỉ sửa `.env` (`DC_PROFILE`), **không** sửa file này.
- Đổi `producer_type: sync` nếu cần đảm bảo delivery chắc chắn (đánh đổi:
  chậm hơn `async`).
- Nếu Kafka reject do thiếu SSL đúng chuẩn → cân nhắc phương án thay thế dùng
  log-shipping agent (Vector/Filebeat) đọc trực tiếp `access.log`, không dùng
  plugin `kafka-logger` nữa — Vector hỗ trợ đầy đủ SASL_SSL, còn plugin gốc
  APISIX (trước patch) thì không.

---

## apisix_routes/global_rules/global-loki-logger.yaml:1-29 — Toàn file (ĐANG TẮT — đã bị thay bằng Kafka)

**Toàn bộ file đang comment** (kể cả `global_rules:` ở dòng 1) — **không**
đang chạy. Đây là cấu hình push log **trực tiếp** lên Loki (HTTP push model),
đã bị thay thế bởi pipeline Kafka (`global-kafka-logger.yaml`) vì lý do mất
log không có buffer (xem chi tiết ở mục kafka-logger phía trên).

**Mục đích ban đầu (khi còn dùng):** đẩy access log của **tất cả** route lên
Loki tập trung. Khác với `prometheus` (có thể bật per-route vì không phải
route nào cũng cần metric riêng), log cần thu **toàn bộ** request để phục vụ
audit trail và troubleshoot → đặt ở `global_rules`, không đặt per-route/
service.

```yaml
# global_rules:
#   - id: global-loki-logger
#     plugins:
#       loki-logger:
#         endpoint_addrs:
#           - "https://maas-service-logs.infiniband.vn"
#         tenant_id: "vnpaycloud"
#         log_labels:
#           vnpaycloud_product: "gateway"
#           vnpaycloud_service: "apisix"
#           vnpaycloud_team: "Cloud"
#           region: "${{DC_PROFILE}}"
#           job: "apisix-log"
#         batch_max_size: 1000
#         batch_max_age: 5
#         max_retry_count: 3
#         retry_delay: 1
#         timeout: 3000
#         ssl_verify: false
```

**Label convention theo chuẩn team Observability:** `vnpaycloud_product:
gateway`, `vnpaycloud_service: apisix`, `vnpaycloud_team: Cloud`, `region`
(HCM/HNI theo `DC_PROFILE`), `node` (hostname VM, hiện đang comment sẵn —
chưa dùng), `job: apisix-log`.

**Nội dung log gửi lên (nếu bật lại):** đúng field JSON đã định nghĩa trong
`access_log_format` của `config-hcm.yaml` — `time`, `remote_addr`,
`route_id`, `service_id`, `consumer`, `status`, `request_method`,
`request_uri`, `host`, `akid`, `upstream_addr`, `upstream_status`,
`rt_limit`, `rt_remaining`, `rt_warning`, `request_time`, `bytes_sent`, `ua`.

**Batch/retry (nếu bật lại):** gom tối đa 1000 log hoặc mỗi 5 giây thì đẩy 1
lần; Loki không phản hồi → retry 3 lần, cách nhau 1 giây.

**Verify endpoint (tham khảo):**
```bash
curl -s -H "X-Scope-OrgID: vnpaycloud" \
  https://maas-service-logs.infiniband.vn/loki/api/v1/labels
```

**Khi nào cần bật lại file này:** chỉ khi **chủ động quay lại** chiến lược
push trực tiếp (bỏ Kafka) — không nên bật song song với Kafka trừ khi có lý
do rõ ràng (VD test A/B 2 pipeline), vì tốn thêm HTTP call mỗi request và có
nguy cơ log trùng lặp giữa 2 nguồn nếu consumer Kafka cũng ghi vào cùng Loki.

---

## apisix_routes/global_rules/global-prometheus.yaml:1-4 — Toàn file (ĐANG ACTIVE — thu metric cho TẤT CẢ route)

```yaml
global_rules:
  - id: global-prometheus
    plugins:
      prometheus: {}
```

**Đang active** — không có dòng nào bị comment. Nghĩa là **mọi** route/
service đều đang bị thu metric, kể cả route lab/debug không chủ động khai
`prometheus: {}` riêng.

**Mục đích:** thu metric tất cả route thay vì phải đặt `prometheus: {}` ở
từng route riêng lẻ.

**So sánh per-route vs global:**
- **Per-route** (chỉ route nào tự khai `prometheus: {}` mới bị thu): phù hợp
  khi muốn kiểm soát cardinality — bỏ qua route lab/debug không cần theo dõi.
- **Global** (file này, đang active): tất cả route đều bị thu, kể cả
  lab/debug → phù hợp khi ưu tiên visibility đầy đủ, chấp nhận đổi lại
  cardinality cao hơn (label `route` trong Prometheus có thêm cả các route
  lab/debug vốn không cần theo dõi lâu dài).

**⚠ Cần rà soát lại route hiện có:** vì `global_rules` chạy **song song**,
không đè plugin ở route/service, nên nếu route nào đang tự khai thêm
`prometheus: {}` riêng, metric của route đó **có thể bị tính 2 lần** (1 lần
từ global rule, 1 lần từ khai báo riêng ở route) — cần rà soát toàn bộ route
đang có `prometheus: {}` và cân nhắc xoá khai báo riêng đó đi, chỉ giữ lại
global rule này, để tránh trùng lặp metric làm sai lệch số liệu dashboard.

**Khi cần chỉnh:**
- Muốn tắt global → xoá file này hoặc thêm `status: 0` (theo đúng convention
  đang dùng ở `global-kafka-logger.yaml`/`global-http-logger.yaml`).
- Muốn quay về per-route → xoá/tắt file này, giữ nguyên `prometheus: {}` ở
  từng route cần theo dõi.

---

## 🔴 [SỰ CỐ — đọc trước khi sửa bất kỳ block `ip-restriction` nào trong `plugin_configs/`]

**RC outage 2026-07-03, 16:00 UTC — production outage cả HCM lẫn HNI**, root
cause do khai `ip-restriction.blacklist: []` (mảng rỗng) làm placeholder.
Plugin `ip-restriction` của APISIX yêu cầu schema `blacklist` có
`minItems: 1`; `lyaml` (thư viện parse YAML dùng trong pipeline) serialize
`[]` thành `{}` (sai type so với schema mong đợi), khiến toàn bộ **service**
gắn `plugin_config_id` liên quan **fail schema validation ngay tại
`init_worker`** — không phải lỗi runtime, mà lỗi ngay lúc APISIX nạp cấu
hình. Hệ quả: mọi route dùng chung service đó trả lỗi dạng "failed to fetch
service configuration" (giống 404), tức là **toàn bộ route** bị ảnh hưởng,
không chỉ riêng phần `ip-restriction`.

**Vì sao không bị chặn sớm hơn:** `merge-fragments.sh` Pass 1 chỉ kiểm tra
**YAML syntax** hợp lệ, không kiểm tra **APISIX plugin schema** — file `[]`
rỗng vẫn là YAML hợp lệ 100%, nên lọt qua toàn bộ pipeline CI cho tới khi
APISIX thật sự nạp config.

**Quy tắc bắt buộc rút ra từ sự cố này, áp dụng cho MỌI file trong
`plugin_configs/` (và bất kỳ nơi nào khác dùng `ip-restriction`):**
- **KHÔNG BAO GIỜ** khai `ip-restriction.blacklist`/`whitelist` với giá trị
  rỗng `[]` làm placeholder "để đó tính sau".
- Nếu chưa có IP cụ thể cần chặn/cho phép, **comment toàn bộ block**
  `ip-restriction` (như đang thấy ở cả `plugin-config-qos-auth.yaml` và
  `plugin-config-qos-internal-console.yaml`) thay vì khai với giá trị rỗng.

```yaml
# SAI — gây outage, KHÔNG BAO GIỜ làm vậy:
ip-restriction:
  blacklist: []
  message: "..."

# ĐÚNG — comment toàn bộ khi chưa có IP thật:
# ip-restriction:
#   blacklist: ["10.x.x.x/32"]
#   message: "Access denied"
```

---

## apisix_routes/plugin_configs/plugin-config-qos-auth.yaml:1-79 — Toàn file

**QoS profile cho traffic IAM / STS / SQS** (kiểm soát truy cập/xác thực,
khác hoàn toàn với traffic S3 SDK dữ liệu thật). Áp cho route
`iam.sds.infiniband.vn` (443 + 16443), `sts.sds.infiniband.vn` (443 + 16443),
`sqs.sds.infiniband.vn` (80) — gắn vào route bằng đúng 1 dòng
`plugin_config_id: "plugin-config-qos-auth"`.

**Vì sao traffic này cực kỳ critical dù volume thấp hơn S3 SDK:** IAM/STS
chết = mọi S3 SDK không lấy được token = **toàn hệ thống chết theo**, dù bản
thân route auth chỉ chiếm phần nhỏ tổng traffic.

**⚠ Bối cảnh khi viết file này — pre-GA:** 3 domain này đang **phơi ra
internet**, ở giai đoạn pre-GA (traffic thấp, chưa chính thức công bố). Traffic
thấp **không đồng nghĩa rủi ro thấp** — đây là giai đoạn rẻ nhất để siết cấu
hình an toàn, trước khi traffic tăng lên và noise từ log khó phân biệt spike
thật với baseline. Ngưỡng soft-limit trong file này (xem phần
`serverless-post-function`) đã **hạ thấp hơn baseline GA gốc (50%/70%)** để
bắt sớm mọi bất thường trong giai đoạn traffic gần như bằng 0.

### apisix_routes/plugin_configs/plugin-config-qos-auth.yaml:4-6 — `ip-restriction` (đang tắt)

Xem mục sự cố RC 2026-07-03 ở trên — lý do vì sao block này đang comment thay
vì khai `blacklist: []`.

### apisix_routes/plugin_configs/plugin-config-qos-auth.yaml:8-16 — `limit-count`

Giới hạn **5000 req/s**, key theo `remote_addr` (**không phải AKID**) — vì
lúc gọi auth (lấy credential/assume role), client **chưa có AKID** để dùng
làm key, nên buộc phải key theo IP.

**Nguyên tắc chọn ngưỡng:** "Auth chết = cả hệ thống chết" → limit vừa phải,
**không bóp nghẹt**. 500 req/s (ngưỡng warn cứng, xem bên dưới) được coi là đủ
cho auth traffic thực tế; nếu vượt mức đó thực sự là bất thường (retry storm,
bug SDK) chứ không phải traffic hợp lệ tăng đột biến.

### apisix_routes/plugin_configs/plugin-config-qos-auth.yaml:18-62 — `serverless-post-function` (soft-limit — cảnh báo sớm, KHÔNG chặn request)

Chạy ở `phase: header_filter`, đọc lại 2 header do `limit-count` đã set
(`X-RateLimit-Remaining` / `X-RateLimit-Limit`) để tính % quota đã dùng, từ đó
quyết định có ghi WARN/INFO hay không — **không** tự chặn request nào, chỉ
quan sát và log.

```lua
local remaining = tonumber(ngx.header["X-RateLimit-Remaining"])
local limit     = tonumber(ngx.header["X-RateLimit-Limit"])
if not remaining or not limit or limit == 0 then return end

local used     = limit - remaining
local used_pct = used / limit * 100
```

**Ngưỡng soft-limit — PRE-GA PHASE (đã hạ so với baseline GA gốc 50%/70%):**
- `INFO` ở `≥ 20%` = 100 req/s — bất kỳ traffic nào cũng đáng quan sát ở giai
  đoạn pre-GA vì baseline lẽ ra gần như bằng 0.
- `WARN` ở `≥ 50%` = 250 req/s — traffic bất thường, cần kiểm tra
  retry-loop/bug SDK ngay.

**⚠ Khi GA chính thức + có baseline p95 thật:** phải **nâng ngưỡng này lại**
(về hướng 50%/70% như baseline GA gốc), nếu không log sẽ spam liên tục ngay
cả khi traffic hợp lệ tăng lên đúng như kỳ vọng thiết kế ban đầu (500 req/s
hard-limit). Đây là việc cần làm chủ động, plugin không tự điều chỉnh.

**Cách điều tra khi thấy WARN trong `error.log`:**
```bash
grep '[rate-limit-warning] service=auth' logs/apisix-hcm/error.log
```
→ xem IP nào đang gọi auth nhiều → khả năng: SDK retry vô hạn, token cache bị
disable, credential đang rotate hàng loạt, hoặc brute-force dò AKID (đáng
chú ý hơn ở pre-GA vì traffic thật gần như bằng 0) → liên hệ team điều tra
**trước khi** chạm hard-limit 5000/s bị 429.

### apisix_routes/plugin_configs/plugin-config-qos-auth.yaml:64-79 — `api-breaker`

Circuit breaker — mục đích chính là **phân biệt nguồn lỗi**: `503` từ circuit
breaker (APISIX chủ động drop vì backend đang lỗi liên tục) ≠ `429` từ
rate-limit (client vượt quota) ≠ `5xx` thật từ backend (Cloudian IAM đang
lỗi). Nhờ vậy metric/log tách được rõ 3 loại lỗi này, không gộp chung.

```yaml
api-breaker:
  break_response_code: 503
  max_breaker_sec: 120
  unhealthy:
    http_statuses: [500, 502, 503]
    failures: 5
  healthy:
    http_statuses: [200, 201, 204]
    successes: 3
```

Sau 5 lần lỗi liên tiếp (500/502/503) → circuit mở, trả thẳng 503 có kiểm
soát trong tối đa 120s mà không gọi tới backend nữa → sau 120s hoặc 3 request
thử lại thành công → circuit tự đóng lại.

**⚠ Shared circuit/quota state — dễ hiểu nhầm khi debug:** route IAM/STS dùng
chung `upstream-iam`, route SQS dùng `upstream-sqs` riêng — nhưng **cả 5
route** (iam×2, sts×2, sqs×1) cùng gắn 1 `plugin_config_id` này, nên:
- `api-breaker` **KHÔNG** chia sẻ trạng thái theo service — tính riêng theo
  response thực tế của **từng route**, nên SQS lỗi mạnh gây breaker mở
  **không** ảnh hưởng IAM/STS.
- `limit-count` (đếm req/s theo IP) thì **ngược lại** — dùng chung 1 quota
  Redis giữa cả 5 route theo key `remote_addr`. 1 IP gọi cả IAM lẫn SQS sẽ
  **cộng dồn vào cùng 1 bucket 5000 req/s**, không tách riêng theo route.

Nếu sau này cần tách quota riêng IAM/STS vs SQS, cân nhắc tách thành 2
`plugin_config_id` riêng (VD `plugin-config-qos-auth-iam-sts` +
`plugin-config-qos-auth-sqs`) thay vì sửa số ở đây.

### apisix_routes/plugin_configs/plugin-config-qos-auth.yaml:74-79 — `policy: redis` (Redis tự dựng, single node — BLOCK 2/5 đang dùng)

APISIX 3.15 hỗ trợ nhiều chế độ lưu state cho `api-breaker`/`limit-count`,
chọn đúng **1 trong 5** theo tình huống hạ tầng:

| Block | Redis | Chế độ | Khi dùng |
|---|---|---|---|
| 1 | Không có Redis | `policy: local` (Lua shared dict node-local) | Single-node/lab/dev — multi-node sẽ đếm riêng từng node, quota hiệu lực = `count × số node` |
| 2 (**đang dùng**) | Tự dựng, single | `policy: redis` + `redis_host/port/password/database/timeout` | Có Redis tự triển khai, chạy 1 instance |
| 3 | Tự dựng, cluster | `policy: redis-cluster` + `redis_cluster_nodes` | Có Redis tự triển khai, chạy cluster (Redis cluster không hỗ trợ `redis_database`, chỉ db 0) |
| 4 | Ngoài (team khác quản lý), single | `policy: redis` + thêm `redis_ssl`/`redis_ssl_verify` | Dùng Redis managed (ElastiCache/Azure...) thường bắt buộc TLS |
| 5 | Ngoài, cluster | `policy: redis-cluster` + `redis_cluster_ssl`/`redis_cluster_ssl_verify` | Redis managed dạng cluster |

```yaml
policy: redis
redis_host: 127.0.0.1        # cùng VM — multi-VM thì đổi thành IP VM Redis
redis_port: 6379
redis_password: "$ENV://REDIS_PASSWORD"   # đọc từ .env, KHÔNG hardcode/commit
redis_database: 1            # tách namespace, tránh đụng DB khác dùng chung Redis
redis_timeout: 1000           # ms — gọi Redis quá 1s coi như lỗi (kích hoạt allow_degradation nếu có)
```

**⚠ Ràng buộc bắt buộc khi đổi block:** chỉ được để **đúng 1 block** không bị
comment tại 1 thời điểm. 2 block cùng active sẽ trùng key `policy:` trong
cùng 1 plugin config → yamllint (rule `key-duplicates`) báo lỗi, **chặn
merge**. Đổi sang block khác bắt buộc đồng bộ lại `docker-compose` +
`redis.conf` tương ứng, không chỉ sửa file YAML này.

**Khác biệt quan trọng dễ nhầm:** `policy: local` của plugin (Block 1) ≠
`policy: local` cấp APISIX nói chung — đây là tắt hẳn Redis, đếm riêng theo
từng node (per-node counting), không phải "chạy Redis local".

---

## apisix_routes/plugin_configs/plugin-config-qos-internal-console.yaml:1-19 — Toàn file

**QoS profile cho console quản trị nội bộ**: CMC, HyperIQ, S3-Admin
(`cmc.sds.infiniband.vn`, `hyperiq.sds.infiniband.vn`,
`s3-admin.sds.infiniband.vn` + port `19443`). Gắn vào route bằng
`plugin_config_id: "plugin-config-qos-internal-console"` — **không** khai
`limit-*` riêng lẻ ở từng route, tập trung toàn bộ tại đây.

**Rủi ro được đánh giá: THẤP** — cả 3 domain này **không** public ra
internet, đã bị chặn ở tầng network (Security Group/firewall/VPN-only)
**trước khi** request chạm tới APISIX.

**⚠ Quyết định thiết kế đáng chú ý — chủ động KHÔNG dùng nhiều plugin
phòng thủ:** file này **không có** `ip-restriction` whitelist,
`ua-restriction`, `referer-restriction`, `limit-req`, `cors` — vì network ACL
đã lo phần chặn truy cập trái phép rồi. Giữ thêm các plugin này ở tầng APISIX
cho mục đích tương tự là **defense-in-depth thừa**: tốn CPU mỗi request, tốn
công bảo trì whitelist, và rủi ro whitelist sai IP sẽ tự khoá luôn chính team
vận hành khỏi console quản trị — rủi ro tự gây ra lớn hơn lợi ích phòng thủ
thêm 1 lớp.

### apisix_routes/plugin_configs/plugin-config-qos-internal-console.yaml:4-11 — `limit-conn`

**Mục tiêu khác hẳn** so với `limit-conn` ở `qos-auth`/`qos-sdk`: ở đây
**không có ý định chống attacker** (vì đã có network ACL chặn từ ngoài), mà
chống chính **hệ thống nội bộ tự bắn nhầm** — script lỗi, cron job loop vô
hạn, dashboard cache-miss storm gọi console dồn dập. Vẫn có giá trị thực dù
100% traffic đến từ nội bộ.

```yaml
limit-conn:
  conn: 4500
  burst: 500
  default_conn_delay: 0.1
  key_type: var
  key: remote_addr
  rejected_code: 429
```

### apisix_routes/plugin_configs/plugin-config-qos-internal-console.yaml:13-15 — `ip-restriction` (đang tắt)

Xem mục sự cố RC 2026-07-03 ở trên. Giá trị thực tế khi cần dùng: **phản ứng
nhanh** khi phát hiện 1 client nội bộ (host/service bị lỗi) spam vào console
— thêm 1 IP vào `blacklist` ở đây **nhanh hơn nhiều** so với phải sửa lại
network ACL / xin duyệt lại security group qua quy trình chính thức.

### apisix_routes/plugin_configs/plugin-config-qos-internal-console.yaml:17-19 — `request-id`

Sinh `Request ID` cho mọi request qua console, set vào header
`X-Request-Id`, dùng để trace xuyên suốt `access.log` / `error.log` /
`file-logger` debug log — hữu ích khi cần truy vết 1 request cụ thể qua nhiều
tầng log khác nhau.

**Không có block Redis trong file này** — khác với `qos-auth`/`qos-sdk`: cả 2
plugin ở đây (`limit-conn`, `request-id`) đều **node-local**, không cần state
chia sẻ giữa các node.

---

## apisix_routes/plugin_configs/plugin-config-qos-sdk.yaml:1-211 — Toàn file — ⚠ ARCHIVED, FILE ĐÃ XOÁ KHỎI REPO

**File này đã bị xoá khỏi repo** — nội dung được gộp toàn bộ vào
`plugin-config-traffic-classifier.yaml` (xem mục ngay bên dưới), 3 route S3
Cloudian (`route-s3-hcm.infiniband.vn`, `route-s3-hcm.sds.infiniband.vn`,
`route-s3-hni.sds.infiniband.vn`) đã đổi `plugin_config_id` sang file mới,
xác nhận thật qua zip repo (không còn `plugin-config-qos-sdk.yaml` trong
`apisix_routes/plugin_configs/`). Giữ lại nguyên văn nội dung cuối cùng ở
đây **chỉ để tham khảo lịch sử/đối chiếu khi cần revert** — không còn phản
ánh cấu hình đang chạy thật, đừng copy-paste lại mà không kiểm tra trước.

<details>
<summary>Nguyên văn YAML cuối cùng trước khi xoá (211 dòng)</summary>

```yaml
plugin_configs:
  - id: "plugin-config-qos-sdk"
    plugins:

      custom.s3-accesskey-extractor: {}

      # ═══════════════════════════════════════════════════════════════════
      # KHOÁ AKID / IP — TẮT HOÀN TOÀN
      # ═══════════════════════════════════════════════════════════════════
      # limit-conn:
      #   conn: 4500
      #   burst: 500
      #   default_conn_delay: 0.1
      #   key_type: var
      #   key: remote_addr
      #   rejected_code: 429      # APISIX chặn, chưa tới backend
      #   rejected_msg: "S3 concurrency limit reached — too many parallel connections from your IP. Reduce concurrent uploads/downloads."
      #   # KHÔNG có policy/redis_* — chủ đích để NODE-LOCAL, không qua Redis.

      # limit-count:
      #   count: 5000
      #   time_window: 1
      #   key_type: var
      #   key: http_x_s3_access_key
      #   rejected_code: 429      # APISIX chặn, chưa tới backend
      #   rejected_msg: "S3 request rate limit exceeded (5000 req/s). Check X-RateLimit-* headers. If you are anonymous, use authenticated access for higher quota."
      #   allow_degradation: true
      #   show_limit_quota_header: true
      #   # ▼▼▼ BLOCK 2 — REDIS TỰ DỰNG (LOCAL) + SINGLE ── ĐANG DÙNG ▼▼▼
      #   policy: redis                             # CHƯA CÓ REDIS → 'local' + xóa redis_*
      #   redis_host: 127.0.0.1                     # cùng VM. Multi-VM → IP của VM Redis
      #   redis_port: 6379
      #   redis_password: "$ENV://REDIS_PASSWORD"   # đọc từ .env, KHÔNG hardcode/commit
      #   redis_database: 1                         # tách namespace
      #   redis_timeout: 1000                       # ms — gọi Redis quá 1s coi như lỗi

      # serverless-post-function:
      #   phase: header_filter
      #   functions:
      #     - |
      #       return function(conf, ctx)
      #         local remaining = tonumber(ngx.header["X-RateLimit-Remaining"])
      #         local limit     = tonumber(ngx.header["X-RateLimit-Limit"])
      #         if not remaining or not limit or limit == 0 then return end

      #         local used     = limit - remaining
      #         local used_pct = used / limit * 100

      #         local akid = ngx.req.get_headers()["X-S3-Access-Key"] or ""
      #         local is_anonymous = (akid:sub(1, 3) == "ip:")

      #         local msg = nil

      #         if is_anonymous then
      #           local warn_abs_anon = 50
      #           local info_abs_anon = 10
      #           local ip = akid:sub(4)

      #           if used >= warn_abs_anon then
      #             msg = string.format(
      #               "WARN [anon]: IP=%s rate=%d req/s exceeds %d req/s threshold. "
      #               .. "Possible scraper or flood. "
      #               .. "Use authenticated access (SigV4) for higher quota.",
      #               ip, used, warn_abs_anon)

      #             ngx.log(ngx.WARN,
      #               string.format("[rate-limit-warning] type=anon IP=%s "
      #                 .. "used=%d/s warn_threshold=%d/s "
      #                 .. "hard_limit=%d/s uri=%s",
      #                 ip, used, warn_abs_anon, limit,
      #                 ngx.var.request_uri or "-"))

      #           elseif used >= info_abs_anon then
      #             msg = string.format(
      #               "INFO [anon]: IP=%s rate=%d req/s. "
      #               .. "Monitor: threshold is %d req/s.",
      #               ip, used, warn_abs_anon)
      #           end

      #         else
      #           local warn_pct_auth = 20
      #           local info_pct_auth = 10

      #           if used_pct >= warn_pct_auth then
      #             msg = string.format(
      #               "WARN [auth]: AKID=%s used=%d req/s (%.0f%% of %d quota). "
      #               .. "Approaching rate limit — throttle requests.",
      #               akid, used, used_pct, limit)

      #             ngx.log(ngx.WARN,
      #               string.format("[rate-limit-warning] type=auth AKID=%s "
      #                 .. "used=%d/s used_pct=%.0f%% "
      #                 .. "warn_pct=%d%% hard_limit=%d/s",
      #                 akid, used, used_pct, warn_pct_auth, limit))

      #           elseif used_pct >= info_pct_auth then
      #             msg = string.format(
      #               "INFO [auth]: AKID=%s used=%d req/s (%.0f%% of %d quota).",
      #               akid, used, used_pct, limit)
      #           end
      #         end

      #         if msg then
      #           ngx.header["X-RateLimit-Warning"] = msg
      #         end
      #       end

      # ═══════════════════════════════════════════════════════════════════
      # KHOÁ BUCKET NAME — BẬT, thay thế AKID/IP hoàn toàn
      # ═══════════════════════════════════════════════════════════════════
      limit-conn:
        conn: 4500
        burst: 500
        default_conn_delay: 0.1
        rejected_code: 429
        key_type: var
        key: http_x_s3_bucket_name
        rejected_msg: "[APISIX-QOS:qos-sdk-bucket]: Rate limit exceeded for this bucket — too many parallel connections to your bucket. Not a Cloudian error — reduce concurrent uploads/downloads."

      limit-count:
        count: 5000
        time_window: 1
        key_type: var
        key: http_x_s3_bucket_name
        rejected_code: 429
        rejected_msg: "[APISIX-QOS:qos-sdk-bucket]: Rate limit exceeded for this bucket (5000 req/s). Not a Cloudian error — Check X-RateLimit-* headers. If you are anonymous, use authenticated access for higher quota."
        allow_degradation: true
        show_limit_quota_header: true
        policy: redis
        redis_host: 127.0.0.1
        redis_port: 6379
        redis_password: "$ENV://REDIS_PASSWORD"
        redis_database: 1
        redis_timeout: 1000

      serverless-post-function:
        phase: header_filter
        functions:
          - |
            return function(conf, ctx)
              local remaining = tonumber(ngx.header["X-RateLimit-Remaining"])
              local limit     = tonumber(ngx.header["X-RateLimit-Limit"])
              if not remaining or not limit or limit == 0 then return end

              local used     = limit - remaining
              local used_pct = used / limit * 100

              local bucket = ngx.req.get_headers()["X-S3-Bucket-Name"]
              local is_untagged = (bucket == nil or bucket == "")

              local msg = nil

              if is_untagged then
                -- Request không gắn bucket cụ thể (list-buckets, route lạ...)
                -- Dùng ngưỡng TUYỆT ĐỐI vì đây là traffic ít, không tỉ lệ
                -- theo hạn mức chung 5000 như traffic có bucket.
                local warn_abs_untagged = 50
                local info_abs_untagged = 10
                local ip = ctx.var.remote_addr or "unknown"

                -- nhánh không có bucket
                if used >= warn_abs_untagged then
                  msg = string.format(
                    "[APISIX-QOS:qos-sdk-bucket]: WARN: IP=%s rate=%d req/s exceeds %d req/s threshold. "
                    .. "Not a Cloudian message. Traffic không gắn bucket cụ thể (vd list-buckets) đang cao "
                    .. "bất thường từ 1 IP — khả năng scraper/flood.",
                    ip, used, warn_abs_untagged)

                  ngx.log(ngx.WARN,
                    string.format("[APISIX-QOS:qos-sdk-bucket] [rate-limit-warning] type=untagged IP=%s "
                      .. "used=%d/s warn_threshold=%d/s "
                      .. "hard_limit=%d/s uri=%s",
                      ip, used, warn_abs_untagged, limit,
                      ngx.var.request_uri or "-"))

                elseif used >= info_abs_untagged then
                  msg = string.format(
                    "[APISIX-QOS:qos-sdk-bucket]: INFO: IP=%s rate=%d req/s. Not a Cloudian message. "
                    .. "Monitor: threshold is %d req/s.",
                    ip, used, warn_abs_untagged)
                end

              else
                -- Request có bucket cụ thể — ngưỡng %, đổi nhãn AKID → bucket.
                local warn_pct_bucket = 20
                local info_pct_bucket = 10

                -- nhánh có bucket
                if used_pct >= warn_pct_bucket then
                  msg = string.format(
                    "[APISIX-QOS:qos-sdk-bucket]: WARN: bucket=%s used=%d req/s (%.0f%% of %d quota). "
                    .. "Not a Cloudian message. Approaching rate limit — throttle requests.",
                    bucket, used, used_pct, limit)

                  ngx.log(ngx.WARN,
                    string.format("[APISIX-QOS:qos-sdk-bucket] [rate-limit-warning] type=bucket bucket=%s "
                      .. "used=%d/s used_pct=%.0f%% "
                      .. "warn_pct=%d%% hard_limit=%d/s",
                      bucket, used, used_pct, warn_pct_bucket, limit))

                elseif used_pct >= info_pct_bucket then
                  msg = string.format(
                    "[APISIX-QOS:qos-sdk-bucket]: INFO: bucket=%s used=%d req/s (%.0f%% of %d quota).",
                    bucket, used, used_pct, limit)
                end
              end

              if msg then
                ngx.header["X-RateLimit-Warning"] = msg
              end
            end
```

</details>

**Diễn giải chi tiết bên dưới vẫn giữ nguyên giá trị tham khảo** (đúng với
bản cuối cùng trước khi xoá), chỉ khác là mọi tham chiếu "đang active" cần
hiểu là "đã từng active, tới trước ngày xoá file":

**QoS profile cho traffic S3 SDK thật** (PUT/GET/DELETE object, list bucket...
— traffic dữ liệu, khác hẳn traffic auth ở `qos-auth`). File này ghi lại **2
thế hệ thiết kế QoS** cho cùng 1 mục đích, thế hệ sau thay thế hoàn toàn thế
hệ trước chứ không chạy song song:

| Thế hệ | Trạng thái | Key rate-limit | Vấn đề của thế hệ trước |
|---|---|---|---|
| AKID / IP-based | **Đã tắt hoàn toàn** (dòng 7-106) | `remote_addr` (limit-conn) / `http_x_s3_access_key` (limit-count) | Không đại diện đúng cho "khách hàng" khi 1 bucket có thể có nhiều AKID cùng ghi, hoặc 1 AKID dùng cho nhiều bucket — quota lệch khỏi đơn vị nghiệp vụ thật là **bucket** |
| Bucket-name-based | **Active tới lúc xoá file** (dòng 111 trở đi) | `http_x_s3_bucket_name` (cả limit-conn lẫn limit-count) | Không phân biệt được Anonymous/SNAT — đây chính là lý do bị thay thế bởi `traffic-classifier` (xem mục ngay dưới) |

### apisix_routes/plugin_configs/plugin-config-qos-sdk.yaml:5 — `custom.s3-accesskey-extractor: {}`

Plugin custom extract AKID từ request (từ chữ ký SigV4 hoặc query param),
set vào `ctx`/header nội bộ (`X-S3-Access-Key`) để các plugin/route khác
dùng. **Xác nhận (Mercy, 2026-07-28):** đây là **chủ đích giữ lại**, không
phải sót — dù rate-limit theo AKID/IP đã tắt hoàn toàn ở file này (chuyển hẳn
sang key theo bucket), extractor vẫn cần chạy vì 2 lý do: (1) field `akid`
trong `access_log_format`/`log_format` của `kafka-logger` (xem
`plugin_metadata/log-format-kafka-logger.yaml:15`) đọc từ header
`X-S3-Access-Key` do đúng plugin này set ra — tắt extractor sẽ làm field
`akid` trong log luôn rỗng; (2) giữ sẵn đường cho khả năng dùng lại AKID
trong tương lai (VD revert rate-limit theo AKID, hoặc thêm tầng QoS mới dựa
trên AKID) mà không phải khai lại plugin từ đầu. **Đã mang nguyên si sang
`plugin-config-traffic-classifier.yaml` khi gộp** — lý do giữ lại không đổi.

### apisix_routes/plugin_configs/plugin-config-qos-sdk.yaml:7-106 — [KHOÁ AKID / IP] — toàn bộ đang tắt, KHÔNG mang sang file mới

Thế hệ thiết kế cũ, giữ nguyên khối trong file gốc (không xoá) để tham khảo
khi cần đối chiếu logic hoặc revert. Gồm `limit-conn` (key `remote_addr`,
**chủ đích node-local, không qua Redis** — khác hẳn cách làm ở `qos-auth`),
`limit-count` (key `http_x_s3_access_key`, có Redis single — xem bảng 5-block
ở mục `qos-auth` phía trên, cơ chế giống hệt), và `serverless-post-function`
soft-limit phân nhánh theo **anonymous** (AKID dạng `ip:<ip>`, dùng ngưỡng
tuyệt đối 50/10) vs **authenticated** (AKID thật, dùng ngưỡng % 20/10).

**Quyết định cuối:** khi gộp vào `plugin-config-traffic-classifier.yaml`
(xem mục dưới), khối này **không được mang sang** — đã bị thay thế 2 lần
(AKID/IP → bucket-only → giờ 3-nhóm Authen/SNAT/Anon), không còn giá trị kỹ
thuật để giữ trong file mới, nguyên văn đã lưu đầy đủ ở khối `<details>`
phía trên nếu cần đối chiếu.

### apisix_routes/plugin_configs/plugin-config-qos-sdk.yaml:111-118 — `limit-conn` (active tới lúc xoá — theo bucket, ĐÃ MANG SANG file mới nguyên vẹn)

```yaml
limit-conn:
  conn: 4500
  burst: 500
  default_conn_delay: 0.1
  rejected_code: 429
  key_type: var
  key: http_x_s3_bucket_name
```

Key đổi từ `remote_addr` (thế hệ cũ) sang `http_x_s3_bucket_name` — giới hạn
concurrent connection theo **bucket** thay vì theo IP, khớp đúng đơn vị
nghiệp vụ thật (1 bucket có thể có nhiều client/IP cùng ghi, quota nên tính
theo bucket chứ không theo từng IP riêng lẻ). **Lưu ý đã note khi gộp:**
`limit-conn` chỉ giới hạn connection cho nhóm Authenticated — nhóm
SNAT/Anonymous ở file mới **không có** giới hạn connection riêng, chỉ có
giới hạn request/60s qua `limit-count`.

### apisix_routes/plugin_configs/plugin-config-qos-sdk.yaml:120-134 — `limit-count` (active tới lúc xoá — theo bucket, có Redis, KHÔNG mang nguyên số sang file mới)

Cùng logic `key: http_x_s3_bucket_name`, ngưỡng 5000 req/s/bucket, dùng
`policy: redis` single-node (giống hệt cơ chế đã giải thích ở
`qos-auth.yaml:74-79`, không lặp lại chi tiết ở đây). **Khi gộp sang file
mới:** đổi hẳn sang `rules:` array 4 nhánh (Authen/SNAT-nhóm/SNAT-IP/Anon),
số `5000 req/s` KHÔNG được giữ — thay bằng số **test** thấp hơn nhiều (xem
mục `traffic-classifier.yaml` dưới), và `policy` đổi từ `redis` sang `local`
tạm thời cho cả 4 nhánh trong giai đoạn test.

### apisix_routes/plugin_configs/plugin-config-qos-sdk.yaml:136-211 — `serverless-post-function` (soft-limit theo bucket — ĐÃ THAY THẾ hoàn toàn bởi cơ chế 4-nhánh mới)

Cấu trúc y hệt bản AKID/IP cũ (đã tắt ở trên), chỉ đổi nhãn — thay vì phân
nhánh anonymous/authenticated theo AKID, phân nhánh theo **có gắn bucket hay
không**:

```lua
local bucket = ngx.req.get_headers()["X-S3-Bucket-Name"]
local is_untagged = (bucket == nil or bucket == "")
```

- **`is_untagged = true`** (request không gắn bucket cụ thể — VD
  `list-buckets`, route lạ): dùng ngưỡng **tuyệt đối** (`warn_abs_untagged =
  50`, `info_abs_untagged = 10` req/s) vì đây là traffic ít, không nên tính
  tỉ lệ theo hạn mức chung 5000 như traffic có bucket cụ thể — key log theo
  `IP` (vì không có bucket để gắn nhãn).
- **`is_untagged = false`** (có bucket cụ thể): dùng ngưỡng **%**
  (`warn_pct_bucket = 20`, `info_pct_bucket = 10`) — key log theo `bucket`
  thay vì AKID.

Cùng cơ chế warn/info, ghi `X-RateLimit-Warning` response header + `ngx.log`
như bản `qos-auth`, không lặp lại giải thích chi tiết ở đây (xem mục
`qos-auth.yaml:18-62` cho phần diễn giải `remaining`/`limit`/`used_pct`).

**⚠ Điểm mấu chốt dẫn tới quyết định thay thế:** `is_untagged` gộp **mọi**
request không có bucket vào **1 counter duy nhất**, không phân biệt IP nào —
`ctx.var.remote_addr` chỉ dùng để in vào message log, **không phải key đếm
thật**. Nghĩa là 4 IP văn phòng tin cậy (SNAT) và 1 con bot quét ngẫu nhiên
đều bị tính chung 1 hạn mức — đây chính là khoảng trống mà
`s3-traffic-classifier.lua` + `plugin-config-traffic-classifier.yaml` sinh
ra để lấp (tách SNAT có danh sách khỏi Anonymous thật, mỗi bên 1 counter
riêng theo đúng IP).

---

## apisix_routes/plugin_configs/plugin-config-traffic-classifier.yaml:1-134 — Toàn file

**🔴 Sự cố đã xảy ra và đã fix — file thiếu newline cuối gây 503 toàn bộ 3
route S3 (không phải "bật thừa plugin" như nghi ngờ ban đầu):** ngay sau khi
đổi `plugin_config_id` sang file này ở cả 3 route, traffic thật
(`172.25.155.245`, SDK client) nhận 503 liên tục. Log lỗi thật:
```
config_yaml.lua:339: failed to check item data of [plugin_configs]
err:failed to check the configuration of plugin serverless-post-function
err: failed to loadstring: [string "return function(conf, ctx)..."]:44:
'end' expected (to close 'function' at line 1) near '<eof>'
```
**Root cause:** file `.yaml` không kết thúc bằng ký tự newline sau dòng
`end` cuối cùng (`\ No newline at end of file` — xác nhận qua `diff`). Khi
`merge-fragments.sh` ghép file vào `apisix-hcm.yaml`, dòng `end` cuối bị
dính liền với nội dung merge kế tiếp, khiến khối YAML nhiều dòng (`- |`)
mất đúng dòng `end` khi APISIX parse lại → Lua thấy `function` mở nhưng
không có `end` đóng → `serverless-post-function` bị từ chối nạp → cả
`plugin_configs` entry `plugin-config-traffic-classifier` bị loại →
route tham chiếu không tìm thấy plugin config → 503. **Không liên quan gì
tới việc bật thừa plugin** — thuần lỗi định dạng file (thiếu 1 ký tự
newline).

**Fix:** `echo "" >> plugin-config-traffic-classifier.yaml` (đã verify lại
qua `od -c`, file hiện có `end\n` đúng chuẩn, 86 dòng). Bài học: mọi file
`.yaml` kết thúc bằng khối Lua nhiều dòng (`- |`) cần kiểm tra kỹ có
newline cuối file trước khi commit, đặc biệt khi tạo file qua công cụ có
thể không tự thêm EOF newline.

**Đã thay thế hoàn toàn `plugin-config-qos-sdk.yaml`** (xem mục ARCHIVED
ngay phía trên) — không còn là "file test riêng", đây giờ là file canonical
duy nhất cho QoS traffic S3 SDK, đã gắn thật vào cả 3 route Cloudian
(`route-s3-hcm.infiniband.vn`, `route-s3-hcm.sds.infiniband.vn`,
`route-s3-hni.sds.infiniband.vn` — đổi `plugin_config_id` từ
`"plugin-config-qos-sdk"` sang `"plugin-config-traffic-classifier"`, xác
nhận thật qua zip repo mới nhất). Mang sang nguyên vẹn từ `qos-sdk` lúc mới
gộp: `custom.s3-accesskey-extractor: {}`, `limit-conn` (lúc đó còn 1 rule
theo bucket), quy ước `rejected_msg` dạng `[APISIX-QOS:xxx]:` cho cả 2
plugin limit — 3 thứ này bản test ban đầu của `traffic-classifier` từng
thiếu. `limit-conn` sau đó đã tự nâng cấp tiếp lên 5 rule (K>S>Anon) — xem
mục ngay dưới, không còn giữ nguyên trạng thái "1 rule mang từ qos-sdk" nữa.

### apisix_routes/plugin_configs/plugin-config-traffic-classifier.yaml:5 — `custom.s3-accesskey-extractor: {}`

Mang nguyên xi từ `qos-sdk.yaml:5` — lý do giữ lại không đổi, xem mục
ARCHIVED phía trên.

### apisix_routes/plugin_configs/plugin-config-traffic-classifier.yaml:7-28 — `limit-conn` — ĐÃ NÂNG CẤP từ 1 rule (theo bucket) lên 5 rule (K>S>Anon)

**Lịch sử:** bản đầu mang nguyên từ `qos-sdk.yaml` chỉ có **1 rule duy nhất**
(`key: http_x_s3_bucket_name`, `conn: 4500`/`burst: 500`) — chỉ giới hạn
connection cho nhóm Authenticated-theo-bucket, nhóm SNAT/Anonymous/AkidOnly
hoàn toàn KHÔNG có giới hạn connection riêng, chỉ có `limit-count` (request/
60s). Đây từng là lỗ hổng treo — traffic SNAT/Anonymous có thể mở connection
đồng thời không giới hạn.

**Đã đóng bằng `rules:` array** (APISIX 3.16+, xác nhận đang chạy 3.17) —
`limit-conn` giờ có **5 rule độc lập**, mỗi rule tự `key`/`conn`/`burst`
riêng, đúng 5 nhóm của `s3-traffic-classifier`:

| Nhóm | `key` | `conn` | `burst` |
|---|---|---|---|
| Authenticated (bucket) | `${http_x_s3_bucket_name}` | 300 | 50 |
| Authenticated (AKID, không bucket) | `${http_x_s3_akid_only}` | 300 | 50 |
| SNAT cả dải | `${http_x_snat}` | 500 | 50 |
| SNAT từng IP | `${http_x_snat_ip}` | 300 | 50 |
| Anonymous | `${http_x_real_ip}` | 50 | 50 |

Toàn bộ số trên **vẫn là số test** (đã hạ từ đề xuất ban đầu 4500/7500/750
xuống khớp trực tiếp với `count` của `limit-count` cho dễ nhớ/dễ trigger tay
lúc verify cơ chế — KHÔNG dựa trên đo tải thật, xem mục "Đo tải thật — đã
backlog" bên dưới) — cần đo tải thật trước production.

**2 pitfall schema đã gặp thật khi chuyển sang `rules:`, mất khá nhiều vòng
debug mới ra — ghi lại để không lặp lại:**
1. `default_conn_delay` **vẫn bắt buộc ở top-level** (ngoài `rules`), dù mỗi
   rule đã tự có `conn`/`burst`. Thiếu field này → APISIX từ chối load toàn
   bộ `plugin_config` với lỗi `failed to check the configuration of plugin
   limit-conn err: value should match only one schema, but matches none`
   (do schema dùng `oneOf` giữa format cũ và format `rules:`, thiếu field
   bắt buộc khiến không khớp cả 2 nhánh). Bằng chứng chính thức: ví dụ trong
   blog "What's New in Apache APISIX 3.16" vẫn giữ `default_conn_delay` ở
   ngoài `rules`.
2. **Mỗi rule của `limit-conn` KHÔNG hỗ trợ `header_prefix`** — khác hẳn
   `limit-count` (có hỗ trợ, xác nhận qua docs chính thức: mỗi rule của
   `limit-count` có `count`/`time_window`/`key`/`header_prefix`). Ví dụ
   chính thức của `limit-conn` với `rules:` chỉ có `conn`/`burst`/`key`
   trong mỗi rule — thêm `header_prefix` vào rule `limit-conn` cũng gây
   lỗi validate y hệt lỗi #1. **Hệ quả thật:** response header của
   `limit-conn` (khi delay/reject) KHÔNG phân biệt được nhóm nào gây ra —
   hạn chế xác nhận có thật, không có cách khắc phục bằng config.

**Đã verify thật bằng traffic test:** batch `for i in 1..20; do curl ... &
done; wait` (20 request đồng thời, nhóm Anonymous, `conn=50/burst=50` lúc
test tạm hạ xuống `conn=2/burst=1`) — access log JSON xác nhận các request
bị chặn có `upstream_addr=""`, `upstream_status=""`, `request_time=0.000`
(chặn tại gateway, CHƯA từng chạm Cloudian) kèm dòng
`plugin.lua:1326: run_plugin(): limit-conn exits with http status code 429`
— khác hẳn các request lọt qua rồi bị Cloudian trả `403` thật (có
`upstream_addr`, `request_time` > 0). 2 loại reject phân biệt rõ ràng qua
access log.

### apisix_routes/plugin_configs/plugin-config-traffic-classifier.yaml:30-56 — `limit-count` — 5 rule, ngưỡng test theo tầng tin cậy

| Nhóm | `key` (đọc header) | `count`/60s | Vì sao |
|---|---|---|---|
| Anonymous | `${http_x_real_ip}` | 50 | Thấp nhất — rủi ro cao nhất, dùng IP đơn thuần |
| SNAT từng IP | `${http_x_snat_ip}` | 300 | = Authenticated — Mercy chủ đích cho phép SNAT rộng bằng hoặc hơn Authen |
| Authenticated (bucket) | `${http_x_s3_bucket_name}` | 300 | Cao theo **1 định danh đơn** — đã ký SigV4, đáng tin |
| Authenticated (AKID, không bucket) | `${http_x_s3_akid_only}` | 300 | Cùng độ tin cậy AKID như trên — dùng khi request không nhắm 1 bucket cụ thể (ListBuckets/account-op). Rule này **mới thêm sau khi chốt K>S>Anon**, không có ở bản gốc `qos-sdk` |
| SNAT cả dải | `${http_x_snat}` | 500 | **Cao hơn cả Authenticated** — có chủ đích, đại diện nhiều người dùng cùng lúc qua chung 1 NAT (đối chiếu `note-TỔNG KẾT...QoS...md` mục 2.1: *"SNAT... nhiều team/dịch vụ cùng lúc"*), không phải 1 định danh đơn lẻ |

**Lịch sử chỉnh ngưỡng (2 lần, trong cùng buổi, trước khi có rule AkidOnly):**
lần 1 đặt 10/50/120/200 — Anon=10 quá thấp, rủi ro chạm block thật do
traffic lạ vãng lai trong sandbox → Mercy nâng lần 2 lên 50/300/300/500 như
bảng trên, an toàn hơn hẳn với traffic nền thật (~5 req/phút). Rule
`AkidOnly` khi thêm sau này lấy thẳng `count=300`, ăn theo tier Authenticated
có sẵn, không tính lại từ đầu.

Toàn bộ 5 `count` này **vẫn là số test**, không phải số production thật của
Global — mục tiêu để `limit-count` không thật sự chặn trong lúc quan sát
soft-limit. `allow_degradation: true` — nếu counter backend lỗi (VD Redis
down khi sau này chuyển `policy: redis`), APISIX cho request đi qua thay vì
chặn cứng, tránh rate-limit tự trở thành điểm gây downtime. **Tương tác
quan trọng cần nhớ khi test:**
- Test từ **1 máy SNAT đơn lẻ**: counter riêng (`Snat-Ip`, 300) chạm ngưỡng
  **trước** counter nhóm (`Snat-Group`, 500) — vì 1 máy không đủ tải để
  nhóm tăng nhanh.
- Test từ **cả 4 máy SNAT đồng thời, chia đều tải**: ngược lại hoàn toàn —
  `Snat-Group` cộng dồn nhanh gấp 4 lần từng `Snat-Ip` riêng, nên **nhóm sẽ
  warn/block trước** khi bất kỳ IP riêng lẻ nào chạm ngưỡng của chính nó
  (warn nhóm ở ~63 request/máy so với warn riêng ở 150 request/máy).

`policy: local` (không Redis) cho cả `limit-count` lẫn `limit-conn` (cả 2
đều 5 rule) — đúng khuyến nghị *"nhóm truy cập rác (Anonymous scan) nên
dùng Local Cache"* trong note chiến lược, tạm áp cho cả 5 vì vẫn đang giai
đoạn test.

### ⚠️ CHƯA XÁC NHẬN XONG — nghi vấn `policy: local` đếm counter riêng theo từng node APISIX

Phát hiện qua chính traffic test batch: 5 request đồng thời (nhóm Anonymous,
`conn=2/burst=1` lúc test tạm) **không** trigger được `429`, nhưng 20 request
đồng thời **có** trigger — cùng 1 request/giây trung bình như nhau, chỉ khác
số lượng bắn cùng lúc. Giả thuyết: `s3-hcm.sds.infiniband.vn` có nhiều node
APISIX phía sau (đã thấy tên `apisix-node-dc1`/`dc2`, `sb-s3-lb-1`/`-2`
trong log thật) qua load balancer/DNS — `policy: local` lưu counter trong
`ngx.shared.DICT` **riêng từng node**, không chia sẻ giữa các node khác
nhau. 5 request rải ra nhiều node → mỗi node chỉ nhận 1-2 request, không
node nào riêng lẻ chạm `conn+burst=3` → không có request nào bị chặn dù
tổng cộng đã gửi 5. 20 request đủ dày để ít nhất vài request rơi trùng
node → bắt đầu thấy `429`.

**Cách verify (đã đưa cho Mercy, CHƯA có kết quả xác nhận):**
```bash
dig +short s3-hcm.sds.infiniband.vn   # đếm số IP thật đứng sau domain
# Nếu >1 IP — ép cùng 1 IP bằng --resolve, lặp lại đúng batch 5-request cũ
for i in 1 2 3 4 5; do
  curl -sk --resolve s3-hcm.sds.infiniband.vn:443:<IP_NODE> -o /dev/null \
    -w "req#${i}: status=%{http_code} time=%{time_total}s\n" \
    "https://s3-hcm.sds.infiniband.vn/thuyldx-cloud/ratelimit-strategy.html" &
done; wait
```
Nếu ép cùng 1 node mà 5 request vẫn ra `429` đều đặn (như batch 20 lúc
không ép node) → xác nhận đúng giả thuyết multi-node local-counter.

**Ý nghĩa nếu đúng:** không phải bug logic ở `s3-traffic-classifier`/`rules:`
vừa làm — đây là hạn chế đã biết trước của `policy: local` (docs APISIX có
ghi `policy: redis`/`redis-cluster` để counter dùng chung nhiều node), khớp
đúng tồn đọng *"`policy: local` cần tách `redis` cho nhóm Authenticated
trước production"* đã ghi nhận từ đầu dự án — chỉ khác là giờ có bằng chứng thực nghiệm cụ thể,
và phạm vi ảnh hưởng rộng hơn ban đầu nghĩ (không chỉ riêng Authenticated,
mà cả 5 rule của cả `limit-count` lẫn `limit-conn` đều dùng `local`).
**Việc cần làm tiếp:** Mercy chạy lệnh verify trên, xác nhận đúng/sai trước
khi coi ngưỡng rate-limit hiện tại đáng tin ở môi trường multi-node.

### apisix_routes/plugin_configs/plugin-config-traffic-classifier.yaml:58-134 — `serverless-post-function` — soft-limit + header layer

Cùng cơ chế `check_soft_limit()` đã dùng ở `qos-auth`/`qos-sdk` cũ (đọc lại
header `X-<prefix>-RateLimit-Remaining/Limit`, tính `used_pct`, chỉ
`ngx.log`/set `X-RateLimit-Warning` — **không** có khả năng chặn request vì
chạy ở `header_filter`, sau khi status code đã quyết định xong bởi
`limit-count` ở phase `access` — đã xác nhận rõ với Mercy, không phải suy
đoán).

**Ngưỡng `warn_pct: 50` / `info_pct: 20`** — số **test** để thấy log nhanh,
**không phải số production**. Theo đúng triết lý đã ghi trong
`note-TỔNG KẾT...QoS...md` (*"sử dụng Soft Limit ở mức 100-110% dung
lượng"*) và tiền lệ đã áp dụng ở `qos-auth` (hạ ngưỡng pre-GA, nâng lại khi
GA có baseline thật) — trước production cần nâng `warn_pct` lên gần sát
100% (không phải 50%), để soft-limit đúng vai trò "khoảng đệm ngay trước
khi chặn thật", không phải cảnh báo sớm nửa chừng.

**`X-RateLimit-Layer: 2`** — set cố định cho **mọi** response đi qua plugin
config này, không phụ thuộc có warn/block hay không — mục đích: nhìn 1
header là biết request đó đã đi qua QoS policy ở tầng Plugin Config/Route,
không cần lục log tìm plugin nào chạy. Nó **không tự chứng minh** request đã
đi qua `s3-traffic-classifier`: CMC dùng `plugin-config-qos-internal-console`
cũng trả header này (đã verify runtime 2026-08-25). Đặt tên `X-RateLimit-Layer`
(không phải `X-QoS-Layer`) để nằm liền kề alphabet với
`X-RateLimit-Limit/Remaining/Reset/Warning` khi dump toàn bộ header — trace
nhanh hơn. Giá trị là **số** (`"2"`), không phải chữ (`"traffic"`,
`"global"`...) — tái dùng đúng tên Layer chính thức đã dùng xuyên suốt hệ
thống, tránh tạo thêm 1 bộ thuật ngữ song song.

#### Bảng tra Layer → thành phần tham gia

Dùng để khi thấy `X-RateLimit-Layer: <N>` trong log/response, biết ngay cần
mở đúng thư mục nào để sửa, không phải đoán:

| Layer | Tên chính thức | Thành phần tham gia |
|---|---|---|
| 0 | Parsing & Validation | `plugins/custom/s3-normalizer-bucket-name.lua`, `plugins/custom/cmc-validator-bucket-name.lua`, `plugins/custom/s3-accesskey-extractor.lua`, `plugins/custom/s3-bucket-name-consumer.lua`, `plugins/custom/s3-traffic-classifier.lua`, `plugins/libraries/*.lua` |
| 1 | Global Protection | `apisix_routes/global_rules/*.yaml` |
| 2 | Dynamic Policy | `apisix_routes/plugin_configs/*.yaml`, `apisix_routes/routes/*.yaml`, `apisix_routes/plugin_metadata/*.yaml` |
| 3 | Custom/Scale-up | `apisix_routes/consumer_groups/*.yaml`, `apisix_routes/consumers/*.yaml` |

**Trạng thái đã verify (2026-08-25):** `plugin-config-qos-internal-console`
đã có `response-rewrite` set `X-RateLimit-Layer: "2"`; CMC trả header này
trong traffic thật. Đây là marker của policy CMC riêng, không phải evidence
cho Dynamic QoS S3. Khi debug S3, chỉ xem marker này cùng với header
`X-Authen-*`/`X-Snat-*`/`X-Anon-*` hoặc các header Consumer S3 để kết luận
đúng plugin nào đã thực thi.

---

## apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:1-34 — Toàn file

**Định nghĩa format log gửi lên Kafka cho plugin `kafka-logger`** — khai qua
`plugin_metadata`, nghĩa là cấu hình **global theo plugin**, không phải
per-route hay per-`global_rules`. Sửa 1 chỗ ở đây áp dụng cho **mọi nơi**
`kafka-logger` đang chạy — hiện tại chỉ có 1 nơi là `global_rules/
global-kafka-logger.yaml` (đang active, xem note phần `global_rules`).

**⚠ Ràng buộc bắt buộc để file này có tác dụng:** `meta_format` ở
`global-kafka-logger.yaml` **phải** = `"default"` (hiện đang đúng) thì block
`log_format` này mới được áp dụng — nếu đổi `meta_format: "origin"`,
`kafka-logger` sẽ **bỏ qua toàn bộ** `log_format` tuỳ biến ở đây, chỉ gửi raw
nginx log line mặc định.

**⚠ FLAT JSON — không phải cấu trúc lồng kiểu Filebeat ECS:** field ở đây là
1 tầng phẳng (`route_id`, `upstream_addr`, `rt_limit`...), **không** dựng
thành object lồng nhau kiểu ECS chuẩn (`nginx.access.*`, `http.*`...). Tên
field được đặt tương đương nội dung cho dễ đọc, nhưng nếu team Observability
cần đúng schema ECS cho dashboard cũ, việc reshape phải làm ở **consumer**
(Vector/Logstash đọc từ Kafka topic), **không phải sửa ở file này** — file
này chỉ định nghĩa APISIX gửi gì lên Kafka, không kiểm soát được consumer xử
lý lại ra sao.

### apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:4-9 — Nhóm field định danh request (`time`, `remote_addr`, `remote_user`, `route_id`, `service_id`, `consumer`)

`route_id` / `service_id` / `consumer` đọc qua `$http_x_route_id` /
`$http_x_service_id` / `$http_x_consumer` — 3 header này do
`global_rules/global-abuse-guard.yaml` inject vào **request** ở
`serverless-pre-function` (xem note chi tiết cơ chế + lý do không dùng thẳng
`$route_id`/`$consumer_name` ở mục `global-abuse-guard.yaml:13-25`). File
này chỉ là nơi **tiêu thụ** 3 header đó, không phải nơi sinh ra chúng.

### apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:15 — `akid: "$http_x_s3_access_key"`

Đọc từ header `X-S3-Access-Key` do plugin `custom.s3-accesskey-extractor` set
vào request (xem note `plugin-config-qos-sdk.yaml:5` — extractor được xác
nhận giữ lại có chủ đích một phần **chính vì** field log này cần nó). Route
nào không gắn `plugin_config_id` có `custom.s3-accesskey-extractor` (VD route
auth IAM/STS/SQS dùng `plugin-config-qos-auth`, không có extractor này) thì
field `akid` trong log của route đó sẽ luôn rỗng — đây là hành vi đúng theo
thiết kế (auth traffic không có AKID để log), không phải lỗi thiếu cấu hình.

### apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:18-20 — `x_forwarded_for` / `x_forwarded_proto` / `x_real_ip`

Đọc **request header** gốc do client hoặc proxy phía trước (nếu có) gửi lên
— **khác** với `remote_addr` (địa chỉ IP nhìn thấy ở tầng TCP, đã qua xử lý
`real_ip`/`X-Forwarded-*` của APISIX nếu có cấu hình `real_ip` tương ứng).
Giữ cả 2 loại (`remote_addr` và các header `x_forwarded_*`/`x_real_ip`) để
đối chiếu khi debug case IP bị nhận sai qua nhiều lớp proxy/LB.

### apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:21-25 — Nhóm field `upstream_*`

`upstream_addr`, `upstream_status`, `upstream_response_time`,
`upstream_connect_time`, `upstream_header_time` — toàn bộ là nginx variable
built-in chuẩn (không qua header inject như `route_id`/`consumer`), phản ánh
đúng hành vi kết nối tới backend Cloudian/Ceph thật: địa chỉ upstream nào
được chọn, mã trạng thái backend trả, thời gian connect/nhận header/tổng thời
gian response — hữu ích để tách bạch độ trễ do APISIX hay do backend khi
troubleshoot latency.

### apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:26-28 — Nhóm field `rt_limit` / `rt_remaining` / `rt_warning`

Đọc qua `$sent_http_x_ratelimit_*` — tiền tố `$sent_http_*` đọc **response
header** (khác `$http_*` đọc request header ở nhóm field định danh phía
trên). 3 header này do `limit-count` (`rt_limit`/`rt_remaining`, tự động khi
`show_limit_quota_header: true`) và `serverless-post-function` soft-limit
(`rt_warning`, tự set thủ công trong Lua — xem note các file
`plugin_configs/qos-*.yaml`) sinh ra, cho phép trace lại chính xác request
nào đã ở mức % quota bao nhiêu tại thời điểm xảy ra, không cần suy luận
ngược từ số liệu tổng hợp sau này.

### apisix_routes/plugin_metadata/log-format-kafka-logger.yaml:29-33 — Nhóm field kết nối/băng thông (`connection`, `connection_requests`, `request_length`, `body_bytes_sent`, `bytes_sent`)

Chuẩn nginx variable, phục vụ phân tích traffic/băng thông theo request —
`connection`/`connection_requests` hữu ích để thấy 1 kết nối TCP đang được
tái sử dụng (keepalive) qua bao nhiêu request, đối chiếu với cấu hình
`keepalive_requests: 1000` ở `config-hcm.yaml`.

---

## [Cơ chế chung] 3 cách nạp cert/key cho mọi file trong `apisix_routes/ssls/`

Cả 4 file domain `*.sds.infiniband.vn`/`*.infiniband.vn` (không tính riêng
`wildcard.thuyldx.yaml` — xem mục riêng bên dưới) dùng chung 1 pattern 3 lựa
chọn nguồn cert/key, chỉ được active **đúng 1 trong 3** tại một thời điểm:

1. **Raw PEM dán trực tiếp** (`cert: |` / `key: |`, đang active ở cả 4 file)
   — dùng khi Vault lỗi/chưa sẵn sàng. Đơn giản, không phụ thuộc thành phần
   ngoài, nhưng đổi cert phải sửa trực tiếp file YAML + commit Git (cert/key
   nằm thẳng trong Git history).
2. **Vault, đường dẫn ngắn** (đang comment) — ⚠️ **ĐÍNH CHÍNH 27/08/2026**: mô tả
   gốc bên dưới về cách APISIX "tự ghép `kv`/`prefix`" là **không chính xác**.
   Đã trace source thật (`apisix/secret/vault.lua`) + đối chiếu doc chính thức
   Apache APISIX, xem đầy đủ ở mục "Cert qua Vault — cơ chế đúng" cuối file.
   Mô tả gốc (SAI, giữ để đối chiếu lịch sử):
   ```yaml
   cert: "$secret://vault/vault-provider/infiniband.vn/cert"
   key:  "$secret://vault/vault-provider/infiniband.vn/key"
   ```
   Cú pháp `$secret://vault/<provider_id>/<key>` — `vault-provider` ở đây là
   `id` của secret provider khai trong `config-hcm.yaml` (`secret_providers`),
   APISIX tự ghép `kv`/`prefix` đã cấu hình sẵn ở provider đó vào path này.

   **Sự thật:** `prefix` khai trong provider **chỉ được là mount Vault** (vd
   `cloud/profile`), KHÔNG phải cả path cert. Toàn bộ phần path còn lại
   (`app/apisix/certs/<domain>`) phải nằm trong chính URI `$secret://`, dạng
   đúng: `$secret://vault/vault-provider/app/apisix/certs/<domain>/cert` — lý
   do: patch [3/5] (`vault.lua`) chèn `/data/` ngay sau `conf.prefix`, đúng
   chuẩn Vault KV v2 (`<mount>/data/<path>`) chỉ khi `prefix` dừng đúng ở
   mount, không sớm hơn không muộn hơn.
3. **Vault, đường dẫn đầy đủ có `/data/`** (đang comment) — ⚠️ **ĐÍNH CHÍNH**:
   option này như viết dưới đây **cấu trúc sai, không chạy được**, không phải
   "workaround hợp lệ" như note gốc mô tả:
   ```yaml
   cert: "$secret://vault/cloud/profile/data/app/apisix/certs/infiniband.vn/cert"
   key:  "$secret://vault/cloud/profile/data/app/apisix/certs/infiniband.vn/key"
   ```
   `secret.lua` (`parse_secret_uri`) tách URI theo đúng 4 phần
   `$secret://$manager/$id/$secret_name/$key` — với chuỗi trên, phần `$id`
   (dùng để lookup đúng provider) sẽ bị hiểu thành `"cloud"` (không phải
   `"vault-provider"` như ý định) → tra provider `id="cloud"` không tồn tại →
   lookup fail ngay từ bước đầu, không liên quan gì tới việc map `/data/` đúng
   hay sai. Không dùng dạng này trong bất kỳ trường hợp nào.

   Mô tả gốc (SAI, giữ để đối chiếu lịch sử): "Ghi thẳng path HTTP API thật
   của Vault KV v2 (yêu cầu chèn thêm segment `/data/` giữa tên mount và
   path)... Dùng khi cách 2 (qua provider abstraction) không tự map đúng
   `/data/` cho Vault Sandbox — đây là workaround thủ công."

**Trạng thái thực tế hiện tại — quan trọng:** cả 4 file đều đang dùng cách 1
(raw PEM), nhưng giá trị hiện tại **chỉ là placeholder** dạng
`<PASTE_CONTENT_OF_*.cert_HERE>` — nghĩa là **chưa có cert thật nào được nạp**
vào các file này. Ở trạng thái hiện tại, APISIX sẽ nhận `cert`/`key` là chuỗi
text `<PASTE_CONTENT_OF_...>` thay vì PEM hợp lệ → SSL object này **sẽ fail**
khi APISIX cố parse thành certificate thật (không phải "tạm thời chưa có SSL"
mà là "sẽ lỗi rõ ràng nếu bật status:1 mà chưa dán cert thật vào").

---

## [Cơ chế chung] Phạm vi phủ SNI giữa 4 file — vì sao không đè lên nhau

| File | SNI phủ | Mục đích |
|---|---|---|
| `ssl-infiniband.vn.yaml` | `*.infiniband.vn`, `infiniband.vn` | Domain gốc `infiniband.vn` — dùng cho `s3-hcm.infiniband.vn` (không có `.sds.`) |
| `ssl-sds.infiniband.vn.yaml` | `*.sds.infiniband.vn`, `sds.infiniband.vn` | Domain con `.sds.infiniband.vn` — cover **apex** (1 cấp subdomain) của hầu hết service: `cmc`, `hyperiq`, `iam`, `minio`, `s3-admin`, `sqs`, `sts`, và apex của `s3-hcm.sds`, `s3-hni.sds`, `s3-rgwhcm(-admin)`, `s3-rgwhni(-admin)` |
| `ssl-wildcard.s3.hcm.sds.infiniband.vn.yaml` | `*.s3-hcm.sds.infiniband.vn` (**không** có apex `s3-hcm.sds.infiniband.vn`) | Riêng cho **bucket-style virtual hosting** HCM — request dạng `<bucket>.s3-hcm.sds.infiniband.vn` |
| `ssl-wildcard.s3.hni.sds.infiniband.vn.yaml` | `*.s3-hni.sds.infiniband.vn` (**không** có apex) | Tương tự, cho HNI |

**Vì sao 2 file wildcard bucket-style cố tình bỏ apex:** apex
`s3-hcm.sds.infiniband.vn`/`s3-hni.sds.infiniband.vn` (không có subdomain
phía trước) đã được cover sẵn bởi `*.sds.infiniband.vn` ở
`ssl-sds.infiniband.vn.yaml` (wildcard 1 cấp của APISIX/NGINX SNI matching
khớp đúng apex 1-cấp-subdomain). 2 cert riêng này **chỉ** cần thiết cho
virtual-hosted-style request có **thêm** 1 cấp subdomain phía trước (tên
bucket), vì `*.sds.infiniband.vn` không khớp được 2 cấp subdomain trở lên
(`<bucket>.s3-hcm.sds.infiniband.vn` có 2 cấp trước `infiniband.vn`).

---

## apisix_routes/ssls/ssl-infiniband.vn.yaml:1-22 — Toàn file

Xem 2 mục cơ chế chung ở trên cho phần cert-source và SNI coverage. Domain
`infiniband.vn` (không có `.sds.`) — theo comment gốc dùng riêng cho
`s3-hcm.infiniband.vn`, tách biệt hoàn toàn khỏi nhánh `.sds.infiniband.vn`.

## apisix_routes/ssls/ssl-sds.infiniband.vn.yaml:1-22 — Toàn file

Cert dùng chung rộng nhất trong 4 file — cover apex của gần như toàn bộ
service nội bộ (CMC, HyperIQ, IAM, MinIO, S3-Admin, SQS, STS) và apex của các
domain S3/RGW. Đây là cert **quan trọng nhất** trong 4 file này về phạm vi
ảnh hưởng nếu hết hạn/lỗi — hỏng cert này ảnh hưởng nhiều service cùng lúc.

## apisix_routes/ssls/ssl-wildcard.s3.hcm.sds.infiniband.vn.yaml:1-21 — Toàn file

### apisix_routes/ssls/ssl-wildcard.s3.hcm.sds.infiniband.vn.yaml:3 — `status: 1`

Khai tường minh — so sánh với file HNI song song bên dưới (thiếu dòng này),
xem cảnh báo ngay sau đây.

## apisix_routes/ssls/ssl-wildcard.s3.hni.sds.infiniband.vn.yaml:1-20 — Toàn file

**⚠ Thiếu `status: 1` so với file HCM song song (cùng cấu trúc, cùng mục
đích, chỉ khác DC):** `ssl-wildcard.s3.hcm.sds.infiniband.vn.yaml` có khai
tường minh `status: 1` ở dòng 3; file HNI này **không có dòng `status` nào**.
Theo schema SSL object của APISIX, field `status` có giá trị mặc định là `1`
(enabled) nếu không khai — nên về lý thuyết hành vi runtime vẫn giống nhau
(cả 2 đều enabled). Tuy nhiên đây vẫn là 1 điểm **thiếu nhất quán giữa 2 file
lẽ ra phải giống hệt cấu trúc** (chỉ khác domain) — nên thêm `status: 1` vào
file này cho khớp file HCM, tránh gây nghi ngờ "có phải SSL HNI đang tắt
không" mỗi khi có người đọc lại sau này mà không nhớ rõ default schema.

---

## apisix_routes/ssls/wildcard.thuyldx.yaml:1-98 — Toàn file

**Cert lab/dev cá nhân** — domain `.thuyldx` (namespace lab riêng, **không**
thuộc `sds.infiniband.vn`/`infiniband.vn` production). Tự ký (self-signed),
issuer `CN = ThuyLDX Root CA` — **không** phải CA công cộng, client cần tự
import/trust root CA này thì mới hết cảnh báo "chứng chỉ không tin cậy" khi
truy cập.

**Xác nhận qua chính nội dung cert (đã decode bằng `openssl x509`):**
- Hiệu lực: `2026-03-01` → `2036-02-27` (10 năm).
- Subject: `CN = thuyldx`, `O = ThuyLDX Lab`.

### apisix_routes/ssls/wildcard.thuyldx.yaml:4-8 — `snis:` — ⚠ KHÔNG khớp đủ với SAN thật trong cert

Decode phần `X509v3 Subject Alternative Name` của chính cert trong file này
(dòng 9-45), cert thật sự cover **7** entry:

```
DNS:thuyldx, DNS:*.thuyldx, DNS:*.lab.thuyldx, DNS:*.hcm.lab.thuyldx,
DNS:*.hni.lab.thuyldx, DNS:*.internal.hcm.lab.thuyldx,
DNS:*.internal.hni.lab.thuyldx
```

Nhưng `snis:` (dòng 5-8) chỉ khai **4** entry:

```yaml
snis:
  - "*.thuyldx"
  - "*.lab.thuyldx"
  - "*.hcm.lab.thuyldx"
  - "*.hni.lab.thuyldx"
```

**Thiếu 3 entry** mà cert đã hỗ trợ sẵn nhưng APISIX sẽ **không chọn** SSL
object này cho các SNI đó (APISIX match theo `snis:` khai báo, không tự suy
ra từ nội dung cert):
- `thuyldx` (apex, không có wildcard) — nếu có nhu cầu truy cập domain trần
  không qua subdomain, sẽ **không** khớp được cert nào dù cert đã hỗ trợ.
- `*.internal.hcm.lab.thuyldx`
- `*.internal.hni.lab.thuyldx`

Không phải lỗi cấp thiết (4 SNI hiện có đủ dùng cho mục đích lab hiện tại),
nhưng nếu sau này cần dùng tới các domain "internal.*" hoặc domain trần
`thuyldx`, cần nhớ **thêm vào `snis:`** — cert **không cần cấp lại**, chỉ cần
sửa danh sách `snis:` trong file này là dùng được ngay (cert đã ký sẵn cho cả
7 domain từ đầu).

### apisix_routes/ssls/wildcard.thuyldx.yaml:9-98 — `cert` / `key` (PEM dán trực tiếp)

Không dùng phương án Vault như 4 file domain `sds.infiniband.vn` — hợp lý vì
đây là cert lab cá nhân, không cần quản lý qua Vault chung của team.

**⚠ Cảnh báo vận hành quan trọng (ghi lại từ comment gốc — dễ mắc lại nếu
không biết):** nếu về sau cert này từng được nạp vào etcd (APISIX chạy mode
etcd thay vì Standalone hiện tại) rồi lấy lại qua Admin API để đối chiếu/
backup, **giá trị `key` trả về từ etcd/Admin API lúc đó là ciphertext đã mã
hoá**, **không phải raw PEM** — etcd của APISIX mã hoá private key khi lưu
trữ. Copy nhầm ciphertext đó dán vào đây (thay vì lấy từ file `.key` gốc hoặc
nơi đã import cert ban đầu) sẽ tạo ra 1 file **trông hợp lệ về mặt YAML**
nhưng **TLS handshake sẽ fail hoàn toàn** vì `key` không phải PEM thật —
lỗi loại này khó phát hiện qua review thông thường (không có gì báo lỗi cho
tới khi client thật sự connect).

---

## [Cơ chế chung] Load balancing & health check strategy giữa các upstream Cloudian

**2 chiến lược load-balancing khác nhau, chọn theo đặc tính traffic:**

| Chiến lược | Dùng cho | Vì sao |
|---|---|---|
| `roundrobin` + `priority` (primary/backup) | `cmc`, `s3-hcm`, `s3-hni` | Không cần sticky-session bắt buộc theo IP; failover rõ ràng qua `priority` (10 = primary nhận 100% traffic khi healthy, 0 = backup chỉ nhận khi mọi node priority cao hơn unhealthy) |
| `chash` (consistent hashing theo `remote_addr`) | `iam`, `s3-admin`, `sqs` | Cần cùng 1 client luôn rơi vào cùng 1 node backend (session/cache affinity) — map trực tiếp từ `ip_hash` của NGINX cũ |

**`keepalive_pool` chỉ khai ở `iam` và `sqs`** (không có ở `cmc`/`s3-admin`/
`s3-hcm`/`s3-hni`) — 2 service này gọi tần suất cao, request nhỏ (auth token,
message queue), tái sử dụng connection TCP tới backend giúp giảm overhead
bắt tay TCP/TLS mỗi request. Các route data-path (S3 HCM/HNI) mỗi request đã
là 1 luồng dữ liệu lớn kéo dài (PUT/GET object), lợi ích của keepalive pool ở
tầng upstream không đáng kể bằng.

**Health check — 2 khái niệm khác nhau, dễ nhầm khi đọc `checks:`:**
- **`active`**: APISIX chủ động tự gửi probe request theo `http_path` định kỳ
  (`interval`), độc lập với traffic thật — luôn chạy trừ khi không khai
  `checks.active`.
- **`passive`**: APISIX quan sát **response của traffic thật** đi qua để suy
  ra tình trạng node — **im lặng không khai** ≠ **tắt**; xem chi tiết ở mục
  `upstream-s3-hcm.sds.infiniband.vn.yaml` bên dưới, đây là điểm gãy quan
  trọng nhất trong toàn bộ cụm upstream.

### [Giải thích cho người mới] Từng field `active`/`passive` nghĩa là gì — ví dụ minh hoạ bằng `upstream-cmc`

**Lỗi thường gặp khi tự viết `passive` — cần nhớ:** `passive` **KHÔNG có field
`interval`** ở bất cứ đâu (cả `healthy` lẫn `unhealthy`). Lý do: `interval`
nghĩa là "cứ bao lâu tự đi hỏi thăm 1 lần" — mà `passive` **không tự đi hỏi
thăm ai cả**, nó chỉ đứng yên nghe lén request thật của khách hàng đi ngang
qua. Không có "đi" thì không có "đi bao lâu 1 lần". Nếu thấy `passive.
unhealthy.interval` xuất hiện ở đâu đó trong file — đó là lỗi gõ nhầm, xoá
đi.

**PHẦN 1 — `active`: "nhân viên tự đi gõ cửa từng node hỏi thăm"**

Nhóm thông tin: gõ cửa kiểu gì —

| Field | Giải thích như nói chuyện |
|---|---|
| `type: "https"` | Khi đi hỏi thăm, dùng cổng khoá (TLS) — vì backend nghe ở cổng có khoá. |
| `host` | Khi gõ cửa, tự giới thiệu "tôi tìm đúng nhà `<domain>`" — để node biết trả lời đúng, không lẫn với nhà khác cùng dùng chung địa chỉ (SNI/vhost). |
| `http_path` | "Gõ cửa" nghĩa là gọi tới đúng đường dẫn này — giống việc gõ URL `https://<host><http_path>`. |
| `https_verify_certificate: false` | "Không cần kiểm tra giấy tờ tuỳ thân (chứng chỉ TLS) của node có hợp lệ hay không, cứ hỏi thăm thôi." |
| `req_headers` | Dán thêm 1 mảnh giấy nhỏ vào câu hỏi, ghi "đây là câu hỏi thăm sức khoẻ, không phải khách hàng thật" — để backend biết phân biệt trong log của nó. |
| `concurrency: 10` | Cho phép hỏi thăm tối đa 10 node **cùng lúc** trong 1 vòng. |
| `timeout` | Hỏi thăm xong, **chờ tối đa X giây** để nghe trả lời. Quá thời gian mà im lặng → coi là "gõ cửa mà không ai ra mở" — khác hẳn "ra mở cửa nhưng nói chuyện khó chịu" (2 cái này là 2 con đường riêng, xem bảng dưới). |

Nhóm "khi node đang khoẻ" (`healthy`) —

| Field | Giải thích |
|---|---|
| `http_statuses` | Nếu node trả lời đúng 1 trong các mã này → tính là "1 lần hỏi thăm, trả lời tốt". |
| `interval` | Khi node đang khoẻ, cứ bấy nhiêu giây ghé hỏi thăm 1 lần — không cần hỏi dồn dập vì đang yên tâm. |
| `successes` | Cần bấy nhiêu lần **liên tiếp** trả lời tốt mới thật sự yên tâm là "nó khoẻ" (áp dụng khi đang phục hồi từ bệnh → khoẻ). |

Nhóm "khi node đang bị nghi bệnh" (`unhealthy`) —

| Field | Giải thích |
|---|---|
| `http_statuses` | Nếu node trả lời 1 trong các mã "lỗi" này → tính là "1 lần hỏi thăm, trả lời KIỂU LỖI". |
| `interval` | Khi đang nghi bệnh, hỏi thăm **dồn dập hơn** `healthy.interval` — để sớm biết chắc. |
| `timeouts` | Cần bấy nhiêu lần **liên tiếp gõ cửa mà im lặng** (quá `timeout` không ai trả lời) → mới kết luận "nó bệnh thật rồi". |
| `tcp_failures` | Cần bấy nhiêu lần **liên tiếp cửa đóng thẳng thừng** (kết nối bị từ chối/bị ngắt ngang — lỗi tầng TCP, chưa chạm tới tầng HTTP) → kết luận bệnh. |
| `http_failures` | Cần bấy nhiêu lần **liên tiếp có người ra mở cửa nhưng nói lời khó nghe** (trả về 1 trong các mã lỗi ở trên) → kết luận bệnh. |

**⚠ QUAN TRỌNG NHẤT — dễ hiểu sai nhất:** `timeouts`, `tcp_failures`,
`http_failures` là **3 con đường HOÀN TOÀN TÁCH BIỆT, có bộ đếm riêng từng
cái** — chỉ cần **1 trong 3** đạt đủ số là node bị đánh bệnh ngay, không cần
cả 3 cùng đạt. Ví dụ: nếu node cứ liên tục "im lặng không trả lời" (timeout
thuần), chỉ cần đúng số lần khai ở `timeouts` là bị đánh bệnh — dù
`tcp_failures` và `http_failures` vẫn đang là 0, chưa hề nhúc nhích. Timeout
**không** tính vào TCP, cũng **không** tính vào HTTP — nó có bộ đếm của
riêng nó.

Bằng chứng thật từ chính APISIX (`docs.api7.ai`, ví dụ response thật của
`GET /v1/healthcheck` khi 1 service ngừng phản hồi):
```json
"counter": { "http_failure": 0, "tcp_failure": 0, "timeout_failure": 3, "success": 0 }
```
Node bị đánh unhealthy nhờ **`timeout_failure` chạm 3** — `tcp_failure` và
`http_failure` đứng yên ở 0.

**PHẦN 2 — `passive`: "đứng nghe lén khách hàng thật nói chuyện với node"**

Không tự đi đâu cả — chỉ đứng nghe. Mỗi khi có 1 khách hàng thật gọi tới
node đó, `passive` tự "nghe ké" xem kết quả ra sao, rồi tự đếm — không có
`interval`, không có `timeout` riêng (không tự gửi gì để mà chờ).

| Field | Giải thích |
|---|---|
| `type` | Không quan trọng với `passive` (`http`/`https` tương đương nhau) — vì nó không tự tạo kết nối nào cả, chỉ nghe lại kết nối có sẵn. |
| `healthy.http_statuses` | Nghe thấy khách hàng nhận được 1 trong các mã này → tính "1 lần nghe thấy tốt". Danh sách default dài hơn hẳn `active` (gồm cả 204/206...) vì traffic thật rất đa dạng. |
| `healthy.successes` | Cần nghe thấy bấy nhiêu lần **liên tiếp** tốt mới góp phần công nhận node khoẻ. |
| `unhealthy.http_statuses` | Nghe thấy khách hàng nhận 1 trong các mã này → tính "1 lần nghe thấy xấu kiểu HTTP". |
| `unhealthy.timeouts` | Nghe thấy bấy nhiêu lần **liên tiếp** request thật bị treo không có phản hồi → đánh bệnh. |
| `unhealthy.http_failures` | Nghe thấy bấy nhiêu lần **liên tiếp** request thật nhận mã lỗi (trong danh sách trên) → đánh bệnh. |
| `unhealthy.tcp_failures` | Nghe thấy bấy nhiêu lần **liên tiếp** request thật bị đứt kết nối/từ chối thẳng → đánh bệnh. |

**Tóm lại 1 câu cho mỗi phần:**
- `active` = tự đi hỏi → có `interval` (vì có "đi"), có `timeout` (vì có "chờ trả lời").
- `passive` = chỉ đứng nghe → KHÔNG có `interval`, KHÔNG có `timeout` riêng — chỉ có các con số **đếm bao nhiêu lần** (`successes`, `http_failures`, `tcp_failures`, `timeouts`).

### [Chốt số liệu — 2026-07-30] Bảng healthcheck cuối cùng đang chạy trên sandbox, kèm dòng thật + lý do từng con số

**Bối cảnh quyết định:** sandbox có 2 đặc tính khác hẳn production, đảo ngược
hướng tuning thường thấy — (1) false-positive gần như miễn phí (không có
khách hàng thật bị ảnh hưởng, chỉ dev chờ thêm vài giây), (2) traffic
dev-test tần suất cao chính là điều kiện lý tưởng để `passive` có dữ liệu
quan sát. Kết luận: **siết ngắn hơn** (phản ứng nhanh) thay vì kéo dài để
giảm tải Cloudian như tư duy production.

**⚠ Số dòng dưới đây lấy từ đúng file fragment gốc riêng lẻ trong
`apisix_routes/upstreams/`** (không phải file đã merge `apisix-hcm.yaml`) —
khớp đúng hệ đánh số mà toàn bộ note này dùng xuyên suốt. `s3-hcm` (4 node)
và `s3-hni` (3 node) lệch dòng nhau vì số node khác nhau; `iam`/`sqs` lệch
so với `s3-hcm`/`s3-hni` vì có thêm block `keepalive_pool`.

**Nhóm 1 — `s3-hcm`, `s3-hni`, `iam`, `sqs`: đã siết đồng nhất giá trị,
khác dòng theo từng file:**

| Field | Giá trị | `s3-hcm.yaml` | `s3-hni.yaml` | `iam.yaml` | `sqs.yaml` |
|---|---|---|---|---|---|
| `checks:` | — | 26 | 22 | 28 | 28 |
| `active:` | — | 27 | 23 | 29 | 29 |
| `active.timeout` | `2` | 35 | 31 | 37 | 37 |
| `active.healthy.interval` | `5` | 40 | 36 | 42 | 42 |
| `active.healthy.successes` | `2` | 41 | 37 | 43 | 43 |
| `active.unhealthy.interval` | `2` | 52 | 48 | 54 | 54 |
| `active.unhealthy.timeouts` | `2` | 53 | 49 | 55 | 55 |
| `active.unhealthy.tcp_failures` | `2` | 54 | 50 | 56 | 56 |
| `active.unhealthy.http_failures` | `3` | 55 | 51 | 57 | 57 |
| `passive:` | — | 57 | 53 | 59 | 59 |
| `passive.healthy.successes` | `3` | 80 | 76 | 82 | 82 |
| `passive.unhealthy.timeouts` | `7` (giữ default, xem lý do bên dưới) | 86 | 82 | 88 | 88 |
| `passive.unhealthy.tcp_failures` | `2` | 87 | 83 | 89 | 89 |
| `passive.unhealthy.http_failures` | `3` | 88 | 84 | 90 | 90 |

**Giải thích ý nghĩa từng con số (áp dụng chung cả 4 file, không lặp lại
theo từng cột):**
- `active.timeout: 2` — response thật đo ~20-30ms, 2s vẫn dư margin lớn,
  nhanh hơn hẳn 5s cũ.
- `active.healthy.interval: 5` — từ 10 → 5, dev restart node xong biết
  phục hồi nhanh hơn.
- `active.unhealthy.interval: 2` — phát hiện nhanh khi dev tắt node test.
- `active.unhealthy.timeouts: 2` — từ default 3 → 2, sandbox chấp nhận
  false-positive được.
- `active.unhealthy.tcp_failures: 2` — giữ default, đã đủ nhạy.
- `active.unhealthy.http_failures: 3` — từ default 5 → 3, đồng bộ tinh
  thần phản ứng nhanh.
- `passive.healthy.successes: 3` — từ default 5 → 3, traffic dev-test dồn
  dập, không cần chờ lâu để công nhận khoẻ lại.
- `passive.unhealthy.tcp_failures: 2`, `http_failures: 3` — cùng tinh thần
  siết nhanh như nhánh `active`.

**⚠ Vì sao `passive.unhealthy.timeouts` KHÔNG siết theo active (giữ `7`,
không phải `2`):** đây là số lần **traffic thật** (request của dev) bị treo
liên tiếp mới đánh unhealthy — khác hẳn `active.unhealthy.timeouts` (probe
tự APISIX tạo ra, sai thì chỉ ảnh hưởng chính probe đó, không ảnh hưởng ai).
Hạ xuống thấp như active sẽ dễ đánh sập node oan chỉ vì 2-3 request dev tự
gõ sai/máy dev mạng chậm — không phải do node thật sự bệnh. Giữ `7` (ngưỡng
cao nhất trong 3 loại passive) đúng tinh thần "timeout của traffic thật là
tín hiệu kém tin cậy nhất trong 3 loại" đã giải thích ở mục field phía trên.

**Nhóm 2 — `cmc`, `s3-admin`: CỐ Ý giữ nguyên số cũ/default, chưa siết.**
Lý do: traffic 2 service này thấp hơn hẳn (console quản trị, admin API) —
câu hỏi "có nên siết `http_failures` xuống 3 đồng nhất hay giữ `5` vì ít mẫu
dữ liệu hơn" **đang để ngỏ, chưa quyết định** — giữ nguyên cho tới khi chốt:

| Field | Giá trị | `cmc.yaml` | `s3-admin.yaml` |
|---|---|---|---|
| `checks:` | — | 24 | 24 |
| `active:` | — | 25 | 25 |
| `active.timeout` | `5` | 33 | 33 |
| `active.healthy.interval` | `10` | 38 | 39 |
| `active.unhealthy.interval` | `5` | 50 | 51 |
| `active.unhealthy.timeouts` | `3` | 51 | 52 |
| `active.unhealthy.tcp_failures` | `2` | 52 | 53 |
| `active.unhealthy.http_failures` | `5` | 53 | 54 |
| `passive.healthy.successes` | `5` | 78 | 80 |
| `passive.unhealthy.http_failures` | `5` | 86 | 88 |

**Riêng `s3-admin` — fix `401` đã áp thật, không còn ở dạng comment (lịch sử
điểm gãy: `401` rơi vùng xám, không nằm trong default `[200,302]` của cả
`active` lẫn `passive`, active healthcheck từng là no-op hoàn toàn qua nhánh
HTTP — xem chi tiết điều tra ở mục riêng `upstream-s3-admin` bên dưới):**

```yaml
# upstream-s3-admin.sds.infiniband.vn.yaml
active.healthy.http_statuses: [200, 302, 401]    # dòng 36-38
passive.healthy.http_statuses: [...308, 401]     # dòng 79 (401 thêm cuối list)
```

**Đã dọn xong lỗi lịch sử:** không còn upstream nào có field
`passive.unhealthy.interval` thừa (bug từng thấy ở bản `cmc` cũ — `passive`
không có khái niệm `interval` vì không tự tạo request để mà "chờ theo chu
kỳ", xem giải thích mục field phía trên) — đã verify grep lại cả 6 block
`passive`, sạch.

---

## apisix_routes/upstreams/upstream-cmc.sds.infiniband.vn.yaml:1-42 — Toàn file

CMC Portal (Cloudian Management Console) — 3 node HCM, port `8443`.

### apisix_routes/upstreams/upstream-cmc.sds.infiniband.vn.yaml:5,10-22 — `type: roundrobin` + `priority`

Trước đây (NGINX) dùng `ip_hash`; chuyển sang APISIX dùng
`roundrobin` + `priority` thay vì `chash`, **không** cần hash theo IP nữa —
`priority` tự quyết định node nào nhận traffic: node `.231` (`priority: 10`)
là **primary**, nhận 100% traffic khi healthy; `.232`/`.233` (`priority: 0`)
là **backup**, chỉ nhận khi **toàn bộ** node priority cao hơn unhealthy.

### apisix_routes/upstreams/upstream-cmc.sds.infiniband.vn.yaml:8-9 — `hash_on: "cookie"` / `key: "JSESSIONID"` (đang tắt — phương án thay thế tốt hơn)

CMC là ứng dụng Java (session-based), về lý thuyết nên sticky theo session
thật (`JSESSIONID`) thay vì theo IP nguồn — 1 IP có thể đại diện nhiều
session khác nhau (NAT, nhiều tab/user cùng mạng công ty), route theo IP
không đảm bảo đúng session dính đúng node. Đây là phương án **cải tiến chưa
áp dụng**, hiện tại đang dùng priority-based failover (primary/backup) thay
vì true sticky-session.

---

## apisix_routes/upstreams/upstream-hyperiq.sds.infiniband.vn.yaml:1-28 — Toàn file

HyperIQ (Grafana/Dashboard giám sát của Cloudian) — **single node**
(`172.26.29.153:3000`), HTTP thuần (không TLS nội bộ). Không có
`type`/`hash_on` phức tạp vì chỉ 1 node — không có gì để cân bằng tải hay
route theo session.

---

## apisix_routes/upstreams/upstream-iam.sds.infiniband.vn.yaml:1-37 — Toàn file

IAM — 3 node HCM, port `16443`. **Dùng chung cho cả route STS**
(`sts.sds.infiniband.vn` → cùng trỏ `upstream-iam.sds.infiniband.vn`, không
có upstream STS riêng) — đây là 1 trong 5 route cùng gắn
`plugin-config-qos-auth` đã note ở phần `plugin_configs` (shared quota/circuit
state).

`type: chash` + `key: remote_addr` — map trực tiếp từ `ip_hash` NGINX cũ.
`keepalive_pool` (size 12, idle 60s, requests 1000) — auth traffic tần suất
cao, giữ connection tái sử dụng giảm overhead handshake TCP/TLS lặp lại.

---

## apisix_routes/upstreams/upstream-s3-admin.sds.infiniband.vn.yaml:1-33 — Toàn file

S3 Admin console — 3 node HCM, port `19443`. Cấu trúc giống hệt `iam` (cùng
`chash` theo `remote_addr`) nhưng **không** có `keepalive_pool` — console
admin gọi tần suất thấp hơn nhiều so với auth traffic, không cần tối ưu tái
sử dụng connection.

---

## apisix_routes/upstreams/upstream-s3-hcm.sds.infiniband.vn.yaml:1-53 — Toàn file (S3 data-path HCM — nơi tập trung nhiều quyết định thiết kế nhất trong toàn bộ `upstreams/`)

**⚠ Kiểm tra chéo với memory hiện có — outstanding item chưa đóng:** 4 node
khai ở đây là `.231`/`.232`/`.233`/`.234` (dòng 9-12) — theo ghi nhận trước
đó, **node 3 & 4 (`172.26.29.233-234`) đang bị DISABLE trong Cloudian** nhưng
**vẫn còn** trong danh sách `nodes:` của upstream này. Nếu đúng, APISIX vẫn
coi 2 node này là ứng viên nhận traffic (trừ khi active/passive health check
tự phát hiện và loại ra) — cần rà soát lại và xoá khỏi `nodes:` nếu Cloudian
đã disable vĩnh viễn, không chỉ dựa vào health check để "che" node đã ngừng
vận hành.

### apisix_routes/upstreams/upstream-s3-hcm.sds.infiniband.vn.yaml:13 — `# retries: 0` (đang tắt — nghĩa là default 3 đang áp dụng)

**⚠ Cảnh báo quan trọng — dòng đang comment nghĩa là default 3 retry ĐANG ÁP
DỤNG, không phải "đã tắt retry":** không khai `retries` → APISIX mặc định
`retries = len(nodes) - 1 = 3`. Với S3 PUT (**không idempotent an toàn**),
1 request lỗi transport giữa chừng có thể bị thử lại trên **cả 3 peer còn
lại** — tức 1 client request chạm tới 4/4 node. Rủi ro: object có thể đã ghi
**một phần** lên peer đầu trước khi lỗi; retry sang peer khác không chỉ
khuếch đại lỗi mà còn có nguy cơ tạo dữ liệu không nhất quán giữa các peer.

```yaml
# retries: 0   # ← nếu bật dòng này: 1 request lỗi CHỈ chạm đúng 1 peer, dừng
                #   lại, trả lỗi thẳng cho client. Client (SDK/Warp) tự quyết
                #   định retry ở tầng application — đúng trách nhiệm của caller.
```

**Không tự ý bật `retries: 0`** cho route ghi (PUT/POST/DELETE) mà chưa tách
riêng upstream đọc/ghi (xem mục Roadmap bên dưới) — bật `retries: 0` chung
cho cả đọc lẫn ghi sẽ làm GET (vốn nên được retry tự do hơn để dễ điều tra
sự cố) cũng bị hạn chế theo, không phải chủ đích ban đầu.

### apisix_routes/upstreams/upstream-s3-hcm.sds.infiniband.vn.yaml:20 — `https_verify_certificate: false`

**TODO chưa đóng:** đổi `false` → `true` sau khi APISIX trust được internal
CA của Cloudian. Không nên để mãi ở chế độ không verify cho probe production
dài hạn — hiện tại chấp nhận tạm vì chưa có CA cert nội bộ đã trust.

### apisix_routes/upstreams/upstream-s3-hcm.sds.infiniband.vn.yaml:23-27 — `healthy.http_statuses` (đang comment `- 403`) — ⚠️ LỊCH SỬ, ĐÃ ĐÓNG (xem số liệu thật hiện tại ở mục `[Chốt số liệu]` phía trên)

**Bối cảnh lịch sử (khi `http_path` còn là `"/"`, trước khi đổi sang
`/.healthCheck`):** quan sát trước đây ghi nhận `GET /` không xác thực trả
`403 AccessDenied` (hành vi đúng thiết kế S3 cho request không có
credential, không phải lỗi backend) — **nguồn quan sát này không còn giữ
được log/output gốc trong repo để dẫn lại**, không có tài liệu nào đính kèm
để trỏ tới; nếu cần dùng lại kết luận này làm căn cứ cho quyết định mới,
phải tự chạy `curl` xác nhận lại, không suy đoán từ ghi chú cũ.

**Vì sao nguy hiểm nếu không khai `http_statuses` (vẫn đúng nguyên lý, chỉ
là ví dụ đã lỗi thời):** không khai → thư viện health-check mặc định chỉ
nhận `[200, 302]` là healthy → active check tự coi node "không khỏe" vĩnh
viễn dù backend hoàn toàn bình thường.

```yaml
healthy:
  interval: 10
  successes: 2
  # http_statuses:
  #   - 403     # DI TÍCH — chỉ đúng khi http_path còn là "/", nay là "/.healthCheck" nên vô nghĩa
```

**✅ Đã đóng:** `checks.active.http_path` đã đổi sang `"/.healthCheck"` —
verify thật bằng `curl` trực tiếp vào node trả về `200` sạch, khớp default
healthy list `[200, 302]`. Điểm gãy 403 không còn áp dụng với endpoint mới.
Dòng comment `# http_statuses: - 403` ở trên là di tích của giai đoạn dùng
`"/"` cũ, có thể xoá an toàn ở lần sửa kế tiếp.

### apisix_routes/upstreams/upstream-s3-hcm.sds.infiniband.vn.yaml:28-40 — `unhealthy.http_statuses`

Danh sách trạng thái "chắc chắn không khỏe" áp dụng cho **active probe**
(không phải traffic thật — xem `passive` để phân biệt). Giữ đầy đủ nhóm
4xx/5xx server-side thật của lỗi hạ tầng (`404, 429, 500, 501, 502, 503, 504,
505`).

### apisix_routes/upstreams/upstream-s3-hcm.sds.infiniband.vn.yaml:41-48 — `passive` — ⚠️ LỊCH SỬ, ĐÃ ĐÓNG (xem số liệu thật hiện tại ở mục `[Chốt số liệu]` phía trên)

**Bối cảnh lịch sử (giai đoạn `passive` còn để toàn bộ ngưỡng = 0, tức tắt
tường minh):** rủi ro từng được ghi nhận — Cloudian trả `503` theo đúng
thiết kế QoS rate-limit (chặn khi 1 client vượt quota, per-user/per-cluster,
không phải per-node) là response **hợp lệ, không phải lỗi backend**. Nhưng
`503` lại nằm sẵn trong danh sách `passive.unhealthy.http_statuses` MẶC ĐỊNH
của thư viện (`[429, 500, 503]`) — nếu bật `passive` mà không xử lý riêng
`503`, 1 đợt nhiều client cùng vượt quota gần như đồng thời có thể khiến
`passive` hiểu nhầm **nhiều node cùng "chết"** trong khi thực chất backend
hoàn toàn khoẻ mạnh, chỉ đang từ chối đúng theo chính sách. Đây là lý do
`passive` từng bị tắt tường minh (toàn bộ ngưỡng đặt `0`) thay vì để mặc
định của thư viện.

**Nguồn quan sát này cũng không còn giữ được log/trace gốc trong repo** —
không trỏ tới tài liệu nào để dẫn lại, chỉ còn đúng phần kết luận/nguyên lý
này được giữ lại bằng lời.

**✅ Đã đóng, nhưng theo hướng KHÁC với đề xuất ban đầu (quan trọng, cần
biết):** `passive` hiện đã bật thật với ngưỡng cụ thể (xem mục `[Chốt số
liệu]` phía trên) — **`503` vẫn giữ nguyên trong `unhealthy.http_statuses`
mặc định**, không loại bỏ như phương án từng cân nhắc ("bỏ hẳn 503 khỏi
passive.unhealthy — hướng sạch nhất về ý nghĩa"). Lý do đổi hướng: môi
trường hiện tại là **sandbox**, chấp nhận rủi ro false-positive (không có
khách hàng thật bị ảnh hưởng) đổi lấy phản ứng nhanh — nên `http_failures`
được **hạ xuống 3** (nhạy hơn) thay vì nâng lên 20-30 (ít nhạy hơn) như từng
đề xuất cho production. **Nếu áp dụng ra production sau này, phải quay lại
cân nhắc đúng hướng ban đầu** (loại `503` khỏi danh sách, hoặc nâng ngưỡng
cao — không dùng nguyên bộ số sandbox hiện tại), vì production không chấp
nhận được rủi ro đánh sập oan node chỉ vì QoS-503 hợp lệ của Cloudian.

**Việc còn để ngỏ, chưa làm — cân nhắc tách riêng upstream đọc/ghi:**
- `upstream-s3-hcm-write` → `retries: 0` **vĩnh viễn** (PUT/POST/DELETE
  không idempotent an toàn).
- `upstream-s3-hcm-read` → retries có giới hạn (VD 1-2) — GET nên được retry
  tự do hơn để dễ điều tra sự cố, không nên bị hạn chế chặt như write.
- Route hiện tại (`uri: "/*"`) match **tất cả** method — cần tách route
  theo method (VD `vars: ["request_method", "in", ["PUT","POST",
  "DELETE"]]`) trỏ 2 service/upstream khác nhau nếu muốn tách thật.

**⚠ Cập nhật trạng thái `retries` — khác với mô tả "đang comment" ở mục field
phía trên:** tại thời điểm chuẩn bị bộ test `passive on/off` dưới đây,
`retries` đã được **khai tường minh `retries: 3`** (không còn comment) —
cùng giá trị số với default cũ, chỉ khác là giờ hiện diện rõ ràng trong file
thay vì ẩn/ngầm định. Không đổi hành vi thực tế, chỉ đổi tính tường minh —
giữ nguyên đoạn giải thích "vì sao 3 retry nguy hiểm với PUT" ở trên, vẫn
đúng nguyên vẹn.

### [Kế hoạch test — 2026-08-04] So sánh `passive` custom vs `passive` tắt hẳn, với `retries: 3` đang bật

**Vì sao cần test này:** 6 run gốc đóng case QoS 503 (xem mục case-study
riêng) đều chạy với `retries: 0` — theo Finding A đã xác nhận qua
`balancer.lua`, điều kiện `ctx.balancer_try_count > 1` chưa từng đạt được
trong suốt 6 run đó, nên `passive` **chưa từng có cơ hội kích hoạt thật**,
bất kể cấu hình ngưỡng là gì. Giờ `retries: 3` đã bật thật (xem cảnh báo
ngay phía trên) — đây là lần đầu tiên `passive` có điều kiện cần để chạy,
nên cần đo lại từ đầu: khi 1 client bị quota-exceeded gây broken-pipe thật,
`passive` (nếu bật) có ngăn được cascade lan sang client khác không, và có
gây flapping (unhealthy↔healthy liên tục trong cùng cửa sổ test) không.

**Xác nhận trước khi test — cơ chế "đặt 0 = tắt hẳn category đó" (đối chiếu
2 nguồn, không chỉ đọc source 1 lần):**
1. Source thật trong container (`healthcheck.lua`, dòng ~1586): *"If any of
   the health counters above... is set to zero, the according category of
   checks is not taken into account. This way active or passive health
   checks can be disabled selectively."*
2. Đối chiếu tài liệu chính thức Kong (`api7/lua-resty-healthcheck` là fork
   trực tiếp APISIX dùng, cùng logic): *"Report a timeout failure. If
   `unhealthy.timeouts` is set to zero in the configuration, this function
   is a no-op and returns true."* — khớp hoàn toàn, không chỉ là comment
   trong code mà là hành vi runtime thật đã verify ở 2 nguồn độc lập.

**⚠ Ràng buộc quan trọng khi set 0 cho check kiểu `http`/`https`** (đúng
loại `passive.type: http` đang dùng) — đối chiếu changelog chính thức
`Kong/lua-resty-healthcheck` PR #55: *"BREAKING: `tcp_failures` can no
longer be 0 on http(s) checks (unless http(s)_failures are also set to
0)"*. Nghĩa là **không được zero riêng lẻ `tcp_failures`** khi
`http_failures` vẫn khác 0 cho check kiểu http — muốn tắt hẳn `passive`,
bắt buộc zero **cả 3 field cùng lúc** (`tcp_failures`, `http_failures`,
`timeouts`), không zero được từng phần.

**Xác nhận cơ chế Finding A không đổi trên bản đang chạy thật (APISIX
3.17, không phải suy luận từ 3.15 cũ):**
```bash
sudo -n docker exec apisix-standalone grep -n \
  'report_http_status\|report_tcp_failure\|balancer_try_count' \
  /usr/local/apisix/apisix/balancer.lua
```
Kết quả thật trên container 3.17 — khớp **y hệt** số dòng và cấu trúc đã
đọc trên bản 3.15 trước đó (dòng `ctx.balancer_try_count > 1` bao trọn cả
`report_tcp_failure`/`report_http_status`):
```
210:    ctx.balancer_try_count = (ctx.balancer_try_count or 0) + 1
211:    if ctx.balancer_try_count > 1 then
224:                    checker:report_tcp_failure(...)
227:                checker:report_http_status(...)
```
Kết luận: nâng cấp 3.15 → 3.17 **không đổi** cơ chế Finding A — đối chiếu
release note chính thức APISIX 3.16/3.17 cũng không có mục nào nhắc thay
đổi `healthcheck`/`balancer`. Yên tâm dùng lại nguyên lý cũ cho lần test
mới, không cần điều tra lại từ đầu.

**Cấu hình Run B — `passive` tắt hẳn (giữ nguyên mọi field khác, chỉ đổi
`unhealthy`):**
```yaml
passive:
  type: http
  healthy:
    http_statuses: [200,201,202,203,204,205,206,207,208,226,300,301,302,303,304,305,306,307,308]
    successes: 3          # giữ nguyên — không có gì để "khoẻ lại" nếu
                           # chưa từng bị đánh unhealthy
  unhealthy:
    http_statuses: [429, 500, 503]
    timeouts: 0            # ← đổi từ 7 (số Run A, xem [Chốt số liệu])
    tcp_failures: 0        # ← đổi từ 2
    http_failures: 0       # ← đổi từ 3
```

**Kịch bản 2 run, cùng tải, chỉ đổi `passive`:**
- **Run A** — giữ nguyên `passive` custom hiện tại (xem `[Chốt số liệu —
  2026-07-30]` phía trên: `successes:3`, `http_failures:3`,
  `tcp_failures:2`, `timeouts:7`).
- **Run B** — áp patch 0 ở trên, verify runtime đã nhận đúng (đọc trong
  container, không tin file host) trước khi bắn tải.
- Cùng offender (quota-exceeded, tạo broken-pipe thật) + canary (đọc song
  song) như 6 run gốc, cùng cường độ tải giữa 2 run để so sánh công bằng.

**Tiêu chí đọc kết quả:**
| Quan sát | Kết luận |
|---|---|
| Run A sạch (không flapping, canary không ảnh hưởng) | `passive` hoạt động đúng, không cần lo thêm |
| Cả A và B đều có vấn đề giống nhau | Không phải do `passive` — nghi ngờ `retries:3` tự nó đã đủ gây fan-out |
| Chỉ A hoặc chỉ B có vấn đề | `passive` chính là biến số gây khác biệt — kết luận rõ ràng |

**Việc phụ trước khi chạy — đổi tên file capture:** `file-logger` route
`s3-hcm` giờ ghi ra `s3-hcm-https-443.log` (đã đổi tên khỏi
`s3-hcm-https-debug-body.log` cũ) — script thu log (`qos-log-capture.sh`)
cần sửa lại tên file tương ứng trước khi chạy 2 run này, nếu không sẽ tìm
nhầm/thiếu file.

---

## apisix_routes/upstreams/upstream-s3-hni.sds.infiniband.vn.yaml:1-52 — Toàn file

**Cấu trúc giống hệt `upstream-s3-hcm.sds.infiniband.vn.yaml`** — toàn bộ
note ở file HCM phía trên (retries, https_verify_certificate, 403=healthy,
passive tắt tường minh, roadmap) áp dụng nguyên vẹn cho file này, chỉ khác:

- **3 node** (`172.25.171.24-26:443`) thay vì 4 — **HNI hiện KHÔNG có** vấn
  đề node "đã disable nhưng còn trong config" như HCM (`.233`/`.234`) — theo
  memory hiện có, outstanding item về node disabled chỉ ghi nhận ở **HCM**,
  chưa có ghi nhận tương tự ở HNI.
- Domain probe (`host:` trong `checks.active`) đổi thành
  `s3-hni.sds.infiniband.vn`.

Không lặp lại toàn bộ giải thích chi tiết ở đây — xem
`upstream-s3-hcm.sds.infiniband.vn.yaml:1-53` để tránh trùng lặp nội dung,
tránh 2 bản note lệch nhau theo thời gian khi 1 trong 2 được cập nhật mà bản
kia bị quên.

---

## apisix_routes/upstreams/upstream-s3.hcm.lab.thuyldx.yaml:1-47 — Toàn file (LAB — không phải production `sds.infiniband.vn`)

**File lab cá nhân**, domain `.thuyldx` (khớp với cert lab
`wildcard.thuyldx.yaml` đã note ở phần `ssls/`) — 3 upstream độc lập trong
cùng 1 file, phục vụ **mục đích test riêng biệt**, không phải 3 phần của
cùng 1 hệ thống:

### apisix_routes/upstreams/upstream-s3.hcm.lab.thuyldx.yaml:3-29 — `upstream-s3.hcm.lab.thuyldx` (test Ceph RGW lab)

Trỏ về Ceph RGW lab (`172.25.216.135:3950`), có node backup bị comment
(`172.25.216.130:3950`, `priority: 0`) — dự phòng chưa bật, khác cấu trúc
primary/backup của `cmc` (ở đó cả 2 node đều active, chỉ khác priority; ở
đây node backup **hoàn toàn không tồn tại** trong danh sách nodes cho tới khi
bỏ comment).

### apisix_routes/upstreams/upstream-s3.hcm.lab.thuyldx.yaml:31-38 — `ekyc-backend-dc1`

**Không có `checks:`/`timeout:`** — dùng toàn bộ default của APISIX (không
health check chủ động, timeout theo default nginx_config). Theo comment gốc,
đây là service **chỉ tồn tại ở DC1** — mục đích rõ ràng là **test case cho
tình huống 2 DC không đối xứng** (HCM có service này, HNI không có), dùng để
xác nhận pipeline GitOps xử lý đúng cấu hình lệch nhau giữa 2 DC thay vì bắt
buộc mọi file phải giống hệt nhau.

### apisix_routes/upstreams/upstream-s3.hcm.lab.thuyldx.yaml:40-47 — `fragments`

Cùng backend (`172.25.216.241:8080`) với `ekyc-backend-dc1` — **cùng mục đích
test DC bất đối xứng** như trên. Tên `fragments` không mô tả rõ chức năng
nghiệp vụ (khác hẳn convention đặt tên theo domain/service như các upstream
production khác trong repo) — vì đây thuần là **fixture test**, không phải
service thật, nên không cần tuân theo convention đặt tên production.

---

## apisix_routes/upstreams/upstream-sqs.sds.infiniband.vn.yaml:1-36 — Toàn file

SQS — 3 node HCM, port `18090`, **HTTP thuần** (không TLS nội bộ, khác với
`iam`/`s3-admin` cùng dùng `chash` nhưng chạy HTTPS). Cấu trúc giống hệt
`iam` (chash theo `remote_addr` + `keepalive_pool` cùng thông số size
12/idle 60s/requests 1000) — cùng lý do: traffic tần suất cao, request nhỏ
(message queue operation), hưởng lợi từ tái sử dụng connection.

---

## [Cơ chế chung] `apisix_routes/services/` — lớp service mỏng, tách hẳn khỏi QoS

Cả 7 file trong `services/` đều có cấu trúc **giống hệt nhau về hình dạng**:
chỉ 4 dòng, thuần tuý là **cầu nối 1:1** giữa `service` và `upstream` tương
ứng (`id`, `name`, `upstream_id`) — **không** khai bất kỳ plugin nào
(`plugin_config_id` hay `plugins:` trực tiếp) ở tầng service.

**Nguyên tắc phân tách trách nhiệm (SoC) rút ra từ comment gốc — áp dụng cho
tất cả 7 file:**
- Đổi **backend node / health-check** → sửa ở `upstreams/`, **không** sửa
  file `services/`.
- Đổi **QoS/rate-limit/blacklist** → sửa ở `plugin_configs/` tương ứng,
  **không** sửa file `services/`.
- File `services/` chỉ tồn tại để **đặt tên** và **trỏ** service → upstream;
  route sẽ gắn `service_id` (trỏ vào đây) + `plugin_config_id` (trỏ vào
  `plugin_configs/`) **riêng biệt** — QoS thực tế được gắn ở **route**, không
  nằm ở service hay upstream.

**🔴 Phát hiện — comment gốc bị copy-paste sai cho 4/7 file, trỏ nhầm nhóm
QoS:** cả 7 file `-cũ.yaml` đều mang **y hệt 1 dòng comment**:

> *"QoS/limit-conn/blacklist cho nhóm internal-console (CMC/HyperIQ/S3-Admin)
> nằm ở `plugin_configs/pc-qos-internal-console.yaml` (dùng chung)."*

Comment này **đúng** cho 3 file `cmc`/`hyperiq`/`s3admin` (đúng nhóm
internal-console như đã note ở `plugin_configs/plugin-config-qos-internal-
console.yaml`), nhưng **sai** khi xuất hiện y hệt ở 4 file còn lại:

| File | Comment gốc trỏ tới | QoS thật sự áp dụng (theo note `plugin_configs/` đã xác nhận trước đó) |
|---|---|---|
| `service-upstream-iam.yaml` | `pc-qos-internal-console.yaml` ❌ | `plugin-config-qos-auth.yaml` (route IAM/STS/SQS) |
| `service-upstream-sqs.yaml` | `pc-qos-internal-console.yaml` ❌ | `plugin-config-qos-auth.yaml` |
| `service-upstream-s3hcm.yaml` | `pc-qos-internal-console.yaml` ❌ | `plugin-config-traffic-classifier.yaml` (S3 data-path, key theo bucket) |
| `service-upstream-s3hni.yaml` | `pc-qos-internal-console.yaml` ❌ | `plugin-config-traffic-classifier.yaml` |

Rõ ràng đây là comment mẫu được copy nguyên khối sang cả 7 file khi tạo mới,
chỉ đổi phần đầu (`Service 1:1 với upstream-...`) mà **quên sửa** dòng nói về
QoS cho 4 file không thuộc nhóm internal-console. Vì file `services/` bản
sạch **đã bỏ hết comment** (đúng theo chuẩn chung của repo), lỗi này **không
còn tồn tại trong file kỹ thuật nữa** — nhưng ghi lại ở đây để nếu ai đó còn
giữ bản `-cũ.yaml` làm tài liệu tham khảo, biết rằng dòng đó **sai với 4 trên
7 file** và không nên tin theo.

---

## apisix_routes/services/ — Danh sách 7 file (đều 4 dòng, cấu trúc giống hệt nhau)

| File | `service.id` | `upstream_id` | Nhóm QoS gắn ở route (tham khảo) |
|---|---|---|---|
| `service-upstream-cmc.yaml` | `service-upstream-cmc` | `upstream-cmc.sds.infiniband.vn` | `plugin-config-qos-internal-console` |
| `service-upstream-hyperiq.yaml` | `service-upstream-hyperiq` | `upstream-hyperiq.sds.infiniband.vn` | `plugin-config-qos-internal-console` |
| `service-upstream-iam.yaml` | `service-upstream-iam` | `upstream-iam.sds.infiniband.vn` | `plugin-config-qos-auth` |
| `service-upstream-s3admin.yaml` | `service-upstream-s3admin` | `upstream-s3-admin.sds.infiniband.vn` | `plugin-config-qos-internal-console` |
| `service-upstream-s3hcm.yaml` | `service-upstream-s3hcm` | `upstream-s3-hcm.sds.infiniband.vn` | `plugin-config-traffic-classifier` |
| `service-upstream-s3hni.yaml` | `service-upstream-s3hni` | `upstream-s3-hni.sds.infiniband.vn` | `plugin-config-traffic-classifier` |
| `service-upstream-sqs.yaml` | `service-upstream-sqs` | `upstream-sqs.sds.infiniband.vn` | `plugin-config-qos-auth` |

**Về `service-upstream-iam.yaml` cụ thể:** file này **dùng chung cho cả route
STS** (`sts.sds.infiniband.vn`) — không có `service-upstream-sts` riêng, vì
STS và IAM trỏ cùng 1 backend vật lý (`upstream-iam.sds.infiniband.vn`, đã
note ở phần `upstreams/`). Route STS sẽ khai `service_id:
"service-upstream-iam"` trực tiếp thay vì có service riêng mang tên STS.

**Không có ghi chú riêng biệt cho từng file** ngoài bảng trên — 7 file này
không có logic gì để giải thích thêm ngoài việc trỏ đúng `upstream_id`, mọi
quyết định thiết kế thật sự (health-check, QoS, priority...) đã nằm ở
`upstreams/` và `plugin_configs/` tương ứng, tránh lặp lại note ở đây.

---

## [Cơ chế chung] `apisix_routes/routes/` — pattern lặp lại ở hầu hết mọi route

Toàn bộ 10 file route đều dùng chung 1 bộ khung — note 1 lần ở đây, các mục
riêng từng file bên dưới chỉ nói phần **khác biệt**.

### `plugin_config_id` — hệ thống 5 profile QoS (comment gốc lặp lại y hệt ở mọi route)

```
sdk               → S3 SDK/machine traffic, phơi internet, volume cao (4000 req/s)
auth              → IAM/STS/SQS, phơi internet (pre-GA), critical, có circuit breaker + blacklist
internal-console  → CMC/HyperIQ/S3-Admin, INTERNAL ONLY, không whitelist/UA/referer,
                    chỉ limit-conn (chống nội bộ tự flood) + blacklist (phản ứng nhanh)
ops               → Script/batch nội bộ + legacy domain, siết chặt (10 req/s)
ops-offpeak       → Ops off-peak ban đêm 2am-6am, nới rộng (200 req/s)
```

**⚠ Chỉ 3/5 profile đã thấy file thật** (`plugin-config-traffic-classifier.yaml`,
`plugin-config-qos-auth.yaml`, `plugin-config-qos-internal-console.yaml` —
đã note đầy đủ ở phần `plugin_configs/`). **`ops` và `ops-offpeak` chưa xuất
hiện trong bất kỳ batch file nào đã gửi** — không route nào trong 10 file lần
này thực tế dùng 2 profile đó. Cần xác nhận: 2 file này có tồn tại ở nơi khác
trong repo chưa gửi, hay đây là profile **dự kiến** (đặt tên sẵn trong tài
liệu để tham khảo tương lai) nhưng chưa tạo file thật.

### `RULE MERGE` — thứ tự override plugin

**Route > Plugin Config > Service** — plugin **cùng tên** khai ở route sẽ
**đè hoàn toàn** bản khai ở `plugin_config`/`service` (không merge field, đè
nguyên block). Hệ quả quan trọng: muốn override 1 field duy nhất của
`limit-count` đang khai trong `plugin_config` thì **phải khai lại toàn bộ
block** `limit-count` ở route, không thể chỉ ghi đè 1 field — nếu route
không khai plugin đó, bản ở `plugin_config` giữ nguyên tác dụng.

### `proxy-rewrite` forward IP thật — pattern lặp ở gần như mọi route

```yaml
proxy-rewrite:
  headers:
    set:
      X-Real-IP: "$remote_addr"
      X-Forwarded-For: "$proxy_add_x_forwarded_for"   # append, KHÔNG overwrite
      X-Cluster-Client-Ip: "$remote_addr"
      X-Forwarded-Proto: "$scheme"
```

`X-Forwarded-For` dùng `$proxy_add_x_forwarded_for` (nối thêm vào chain có
sẵn) — **không** gán thẳng `$remote_addr` (sẽ ghi đè mất chain proxy phía
trước nếu có, làm sai traceability khi có nhiều lớp proxy).

**Riêng route IAM/STS có thêm `X-Forwarded-Port: "$server_port"`** — đây
**chính là fix của sự cố IAM đã ghi nhận trước đó**: patch
`1-patch-template-lua.sh` từng xoá `X-Forwarded-Port` toàn cục để fix S3
SigV4, vô tình làm Jetty (`ForwardedRequestCustomizer`) mặc định port về 443
thay vì 16443 trên route IAM, gây `SignatureDoesNotMatch`. Fix đã áp dụng
đúng ở cấp **route** (chỉ IAM/STS, không áp dụng toàn cục) — thấy rõ trong
`route-iam...yaml` và `route-sts...yaml`, không xuất hiện ở các route khác
(CMC/HyperIQ/S3-Admin/S3-HCM/S3-HNI/SQS) vì các route đó không có vấn đề
SigV4-qua-Jetty tương tự.

### `file-logger` DEBUG TẠM — xuất hiện ở HẦU HẾT route, chưa route nào được dọn

```yaml
file-logger:
  path: "/usr/local/apisix/logs/services/<tên-route>.log"
  include_req_body: true
  include_resp_body: true
  log_format: { ... }
```

Comment gốc ghi rõ đây là **"DEBUG TẠM"**, cố ý dùng `file-logger` (không
phải `serverless-post-function`) để tránh rủi ro trùng key khi merge — nhưng
comment gốc của route S3-Admin còn ghi rõ hơn: *"Xoá sau khi điều tra xong
(2026-07-08)"*. Tính tới thời điểm các file "sạch" hiện tại, **block này vẫn
còn active ở gần như mọi route**, nghĩa là đợt điều tra ghi trong comment
**chưa được dọn theo đúng kế hoạch ban đầu**, hoặc vẫn đang cần dùng tiếp.

**🔴 Cần Mercy xác nhận — đặc biệt nghiêm trọng với 2 route S3 data-path**
(`route-s3-hcm.sds.infiniband.vn-https-443.yaml`,
`route-s3-hni.sds.infiniband.vn-https-443.yaml`, và cả route legacy
`route-s3-hcm.infiniband.vn-https-443.yaml` tuy route này không có
`file-logger`): `include_req_body: true` + `include_resp_body: true` trên
route nhận **PUT object tới 5GB** (theo giới hạn `client_max_body_size` đã
note ở `config-hcm.yaml`) nghĩa là APISIX có thể đang cố ghi **toàn bộ nội
dung object** vào file log mỗi request — rủi ro thật: dung lượng đĩa log
phình rất nhanh, I/O tăng đáng kể mỗi request, và nếu object chứa dữ liệu
nhạy cảm thì dữ liệu đó giờ nằm cả trong file log dạng plaintext. Cần xác
nhận: block này có thật sự cần giữ lại tới bây giờ, hay nên tắt/xoá theo
đúng kế hoạch "xoá sau khi điều tra xong" đã ghi trong comment gốc.

### Nguyên tắc gộp route port-variant (áp dụng cho `s3-hcm`, `s3-hni`, `iam`, `sts`)

Các route từng tách riêng theo port (VD `-http-443`, `-https-proxy`,
`-redirect` cũ của S3-HCM/HNI) đã được **gộp lại 1 route duy nhất**, xác
nhận bằng cách đối chiếu trực tiếp `nginx-full-config.txt` (file cấu hình
NGINX gốc trước khi migrate) — nếu NGINX gốc dùng **chung 1 server block**
cho nhiều port/scheme, không có `return 301` redirect nào, thì các route
APISIX tương ứng chỉ khác `vars` là **bản sao dư thừa**, gộp lại không mất
chức năng gì. Route `-redirect` (chưa từng active, `status: 0`) bị **xoá
hẳn** thay vì giữ lại — lý do: giữ lại dễ gây hiểu nhầm là "khôi phục hành vi
cũ" trong khi thực ra bật lên sẽ là **hành vi hoàn toàn mới** (nginx gốc
chưa từng redirect HTTP→HTTPS). Muốn enforce HTTPS thật trong tương lai →
tạo route mới, ghi rõ đây là thay đổi so với nginx gốc, không phải "bật lại".

### Sự cố route port 443 của IAM/STS/S3-Admin bị xoá nhầm (RC-9, phát hiện & fix 2026-07-14)

route IAM/STS (`-https-443`) và route S3-Admin (`-https-443`) từng bị **xoá
nhầm** trong đợt tái cấu trúc `plugin_configs` (2026-07) — nguyên nhân: NGINX
gốc nghe **cả 2 port** (443 và 16443/19443) trong **cùng 1 server block**,
cùng `proxy_pass` tới cùng backend, nên client gọi domain không chỉ định
port (mặc định 443) vẫn được proxy đúng vào service thật (port
16443/19443 phía sau) — mất route 443 nghĩa là client cũ quen không ghi port
sẽ không kết nối được nữa. Phát hiện và fix cùng đợt cho cả IAM, STS, S3-Admin
vào **2026-07-14**. Route 443 hiện tại chỉ để giữ **tương thích ngược** với
client cũ — không tự thêm route port khác nếu không có bằng chứng NGINX gốc
từng hỗ trợ port đó, luôn đối chiếu `nginx-full-config.txt` trước khi thêm.

---

## apisix_routes/routes/route-debug-dump-normalized.yaml:1-62 — 2 route debug, tách biệt production

### Dòng 2-26 — `route-debug-dump` (status: 0, tắt mặc định)

Dump request **gốc** (trước normalize), trigger qua header `X-Debug: 1`.
`status: 0` → hoàn toàn không match request thật cho tới khi ai đó chủ động
bật. `priority: 100` cao để chắc chắn match trước route S3 chính khi được
bật, tránh production route "nuốt mất" request debug.

### Dòng 28-62 — `route-debug-dump-normalized` (status: 1, đang bật)

Dump request **sau khi** `custom.s3-normalizer-bucket-name` xử lý — dùng để
verify plugin normalizer rewrite đúng chưa. **Đang bật** (`status: 1`)
nhưng **an toàn cho production** vì `vars: [["http_x_debug", "==", "2"]]`
(dòng 44) — chỉ match khi client tự thêm header `X-Debug: 2`, traffic thật
không có header này nên route không bao giờ được chọn. Cả 2 route đều
upstream về `127.0.0.1:9999` (local debug HTTP server, không phải Cloudian
thật) — an toàn tuyệt đối kể cả nếu vô tình match nhầm.

---

## apisix_routes/routes/route-cmc.sds.infiniband.vn-https-8443.yaml:1-76 — Toàn file

### Dòng 14-20 — `proxy-rewrite`

Theo pattern chung đã note ở trên (không có `X-Forwarded-Port` — CMC không
có vấn đề Jetty/SigV4 như IAM).

### Dòng 22-42 — `serverless-post-function` — strip `HttpOnly` khỏi cookie `JSESSIONID`

Tương đương `cmc-conf.lua: proxy_cookie_flags JSESSIONID nohttponly` của
NGINX cũ — đặc thù **riêng CMC**, không đưa lên `plugin_config` chung vì
HyperIQ/S3-Admin không có cookie `JSESSIONID` theo cấu trúc này.

```lua
local function strip_httponly(cookie)
  return cookie:gsub(";%s*[Hh]ttp[Oo]nly", "")
end
```

Xử lý cả 2 dạng `Set-Cookie` header APISIX có thể trả về: `table` (nhiều
cookie) và `string` (1 cookie) — chỉ strip đúng cookie chứa `JSESSIONID`,
không đụng cookie khác nếu CMC có set thêm.

### Dòng 43-53 — `serverless-pre-function` — DEBUG log JSESSIONID

Log tạm để trace, đọc `Cookie` header và tách giá trị `JSESSIONID` qua Lua
pattern `"JSESSIONID=([%w]+)"` — cùng thuộc nhóm DEBUG TẠM đã note ở mục cơ
chế chung.

### Dòng 54 — `custom.cmc-validator-bucket-name: {}`

Validate tên bucket khi tạo bucket **qua CMC UI** (khác
`custom.s3-normalizer-bucket-name` dùng cho route S3 data-path) — đã note ở
phần plugin custom trong `config-hcm.yaml`.

---

## apisix_routes/routes/route-hyperiq.sds.infiniband.vn-https-3000.yaml:1-41 — Toàn file

Route **đơn giản nhất** trong nhóm internal-console — không form upload
(khác CMC), không port-split (khác S3-Admin). Chỉ có `proxy-rewrite` (dòng
13-19, pattern chung) + `file-logger` DEBUG TẠM (dòng 21+). Toàn bộ QoS lấy
từ `plugin-config-qos-internal-console`, route không override gì thêm.

---

## apisix_routes/routes/route-s3-admin.sds.infiniband.vn-https-19443.yaml:1-104 — 2 route theo port (19443 + 443)

### Dòng 3-53 — `-https-19443` / Dòng 55-104 — `-https-443`

**Cấu trúc giống hệt nhau**, chỉ khác `vars: server_port` (dòng 11 vs 63) và
đường dẫn `file-logger` (dòng 33 vs 85). Lý do tồn tại route 443: xem mục
"Sự cố RC-9" ở phần cơ chế chung — NGINX gốc nghe chung 1 server block cho cả
443 và 19443, route 443 phục vụ client cũ không ghi port.

**Khác 1 chi tiết nhỏ so với CMC/HyperIQ:** `proxy-rewrite` ở đây (dòng
14-20/66-72) **không** có `X-Forwarded-Port` — S3-Admin không có vấn đề
Jetty/SigV4 như IAM/STS, chỉ IAM/STS mới cần header này.

`serverless-pre-function` (dòng 22-32/74-84) — DEBUG log riêng cho từng port
(`[DEBUG-S3ADMIN-REQ-19443]` vs `[DEBUG-S3ADMIN-REQ-443]`), cùng nhóm DEBUG
TẠM.

---

## apisix_routes/routes/route-s3-hcm.sds.infiniband.vn-https-443.yaml:1-51 — Toàn file (S3 data-path HCM)

`plugin_config_id: "plugin-config-traffic-classifier"` — QoS tập trung ở đó (key theo
bucket, đã note đầy đủ ở `plugin_configs/`). Route chỉ giữ phần **đặc thù
route này**:

- **Dòng 16-17** `proxy-control: request_buffering: false` — **bắt buộc**
  cho object lớn (tới 5GB); thiếu dòng này APISIX sẽ buffer cả object vào
  RAM trước khi forward → nguy cơ OOM. Đây là plugin ở tầng **route** (khác
  `proxy_request_buffering` đã khai ở tầng `nginx_config` trong
  `config-hcm.yaml` — 2 cơ chế khác nhau, cùng mục tiêu, nên **cả 2 nơi đều
  cần khai đúng**, thiếu 1 trong 2 không đủ).
- **Dòng 19-23** `custom.s3-normalizer-bucket-name` — chạy priority 10005
  (trước `limit-count` ở access phase), rewrite vhost→path + validate bucket
  name. `path_hosts` khớp path-style, `vhost_domains` dùng Lua pattern
  (phải escape `.`/`-` thành `%.`/`%-`) khớp vhost-style.
- **Dòng 25** `custom.s3-bucket-name-consumer: {}` — chạy priority 9500
  (sau normalizer), chỉ có tác dụng nếu bucket đã đăng ký thủ công trong
  `consumers.yaml` (prefix `bucket-`); bucket lạ → no-op, fallback policy
  mặc định của `plugin-config-traffic-classifier`.
- **Dòng 27-29** `custom.s3-accesskey-extractor` — chạy rewrite phase
  (priority 2510, trước `limit-count` ở access phase). Hỗ trợ SigV4 header,
  SigV2 header, presigned URL (`X-Amz-Credential`); anonymous → fallback
  `ip:<remote_addr>`.
- **Dòng 31+** `file-logger` DEBUG TẠM — xem cảnh báo riêng ở mục cơ chế
  chung (route S3 data-path là nơi rủi ro nhất nếu log cả body).

**Timeout khác với các route khác:** `connect: 60` (thay vì 30),
`read: 600` (thay vì 300) — dài hơn hẳn, phù hợp transfer object lớn thay vì
API call ngắn như CMC/IAM.

---

## apisix_routes/routes/route-s3-hni.sds.infiniband.vn-https-443.yaml:1-50 — Toàn file

**Cấu trúc giống hệt** `route-s3-hcm.sds.infiniband.vn-https-443.yaml` —
không lặp lại note, xem file HCM ở trên.

**⚠ Phát hiện — sai sót copy-paste, không phải vấn đề nghiêm trọng nhưng nên
sửa:** `file-logger.path` ở route HNI (dòng 31) vẫn ghi
`"/usr/local/apisix/logs/services/s3-hcm-https-443.log"` — **path của route
HCM**, không phải `s3-hni-https-443.log`. Hệ quả: log debug của route HNI
đang bị ghi lẫn vào cùng file với route HCM (nếu 2 node HCM/HNI dùng chung
ổ đĩa log, hoặc gây nhầm lẫn khi đọc log trên node HNI thấy tên file nói
"hcm"). Rõ ràng do copy từ file HCM sang rồi quên đổi tên file log.

---

## apisix_routes/routes/route-s3-hcm.infiniband.vn-https-443.yaml:1-32 — Toàn file (domain LEGACY, dùng chung backend với `s3-hcm.sds`)

Domain cũ `s3-hcm.infiniband.vn` (cert `ssl-infiniband.vn.yaml`, khác cert
`ssl-sds.infiniband.vn.yaml` của domain chính) — **cùng
`service_id: "service-upstream-s3hcm"`**, tức cùng backend vật lý với route
`s3-hcm.sds.infiniband.vn-https-443`, chỉ khác `host:` match và
`vhost_domains`/`path_hosts` của normalizer (dòng 17-21) đổi theo domain
legacy. Route này **không có** `file-logger` DEBUG TẠM (khác các route S3
data-path khác) — có thể là chưa được thêm vào cùng đợt debug, hoặc traffic
route legacy quá thấp nên không cần.

---

## apisix_routes/routes/route-iam.sds.infiniband.vn-https-16443.yaml:1-109 — 2 route theo port (16443 + 443)

### Dòng 3-55 — `-https-16443`

`vars: [["server_port","==","16443"]]` (dòng 11-12). `proxy-rewrite` (dòng
26-33) **có** `X-Forwarded-Port` — xem mục fix sự cố IAM ở phần cơ chế
chung. `serverless-pre-function` DEBUG (dòng 14-20) đang **comment sẵn**
(khác route 443 bên dưới — đang bật) — không cần log ở port chính (16443,
traffic thật nhiều hơn), chỉ bật khi cần trace cụ thể.

### Dòng 57-109 — `-https-443`

Route tương thích ngược (xem RC-9 ở mục cơ chế chung). **Khác route 16443 ở
1 điểm:** `serverless-pre-function` DEBUG (dòng 68-79) đang **active**
(không comment) — log chi tiết `http_host`/`host`/`server_port`/`request_uri`/
`authorization` mỗi request tới port 443. Vì port này chủ yếu phục vụ client
cũ (traffic thấp hơn 16443), bật log không ảnh hưởng nhiều tới performance,
hữu ích để xác nhận có client nào còn thật sự dùng port 443 hay không trước
khi cân nhắc gỡ bỏ route tương thích ngược này trong tương lai.

---

## apisix_routes/routes/route-sqs.sds.infiniband.vn-https-18090.yaml:1-42 — Toàn file

`plugin_config_id: "plugin-config-qos-auth"` (dùng chung IAM/STS). SQS
backend **HTTP thuần** (không TLS) — `proxy-rewrite` (dòng 14-20) theo
pattern chung, **không** có `X-Forwarded-Port` (SQS không có vấn đề
Jetty/SigV4 như IAM/STS — chỉ IAM/STS mới cần). Route này **không có**
`vars` (dòng 11 comment sẵn `["scheme","==","http"]` nhưng không active) —
domain chỉ nghe 1 scheme (HTTP, port 80 theo comment gốc), không cần điều
kiện phân biệt.

---

## apisix_routes/routes/route-sts.sds.infiniband.vn-https-16443.yaml:1-85 — 2 route theo port (16443 + 443), dùng chung backend IAM

**`service_id: "service-upstream-iam"`** ở cả 2 route (dòng 6, 48) — STS
**không có upstream/service riêng**, tái sử dụng hoàn toàn backend vật lý
của IAM (đã note ở `upstreams/upstream-iam...yaml`). Cấu trúc giống hệt
`route-iam...yaml` (cả 2 route, cả `X-Forwarded-Port`, cả pattern DEBUG) —
đây chính là ví dụ cụ thể của **shared circuit/quota state** đã note ở
`plugin_configs/plugin-config-qos-auth.yaml`: `api-breaker`/`limit-count`
của IAM và STS chia sẻ chung trạng thái Redis vì cùng `plugin_config_id`
**và** cùng backend vật lý — IAM lỗi mạnh gây circuit mở sẽ ảnh hưởng STS
theo, đây là hành vi **mong muốn** (không phải bug) vì bản chất là cùng 1
backend đang lỗi.

---

## apisix_routes/routes/route-s3.hcm.lab.thuyldx.yaml:1-74 — Toàn file (LAB — 5 route test, không phải production)

File lab cá nhân, domain `.lab.thuyldx`/`.thuyldx` — khớp cert
`wildcard.thuyldx.yaml` và upstream `upstream-s3.hcm.lab.thuyldx.yaml` đã
note trước đó. Khác các file production, file này **vẫn giữ nguyên comment**
(không bị dọn sạch) — chấp nhận được vì đây là fixture test cá nhân, không
phải file vận hành thật.

### apisix_routes/routes/route-s3.hcm.lab.thuyldx.yaml:5-26 — `route-s3.hcm.lab.thuyldx`

**🔴 Phát hiện — `upstream_id` tham chiếu sai, route này nhiều khả năng đang
BROKEN:** dòng 7 khai `upstream_id: "upstream-lab-ceph-rgw-dc1"`, nhưng theo
upstream file đã note trước đó
(`apisix_routes/upstreams/upstream-s3.hcm.lab.thuyldx.yaml`), `id` thật của
upstream đó là **`"upstream-s3.hcm.lab.thuyldx"`** (chỉ trùng `name:
"lab-ceph-rgw-hcm"`, không trùng `id`). APISIX resolve `upstream_id` theo
đúng field `id`, không phải `name` — nếu đúng như vậy, route này đang trỏ
tới 1 `upstream_id` **không tồn tại**, nhiều khả năng APISIX sẽ báo lỗi kiểu
"failed to fetch upstream configuration" cho route này (giống cơ chế lỗi đã
ghi nhận ở RC outage 2026-07-03, dù nguyên nhân khác nhau — cùng là lỗi
tham chiếu ID sai gây fail ở tầng nạp cấu hình).

**Cần Mercy xác nhận trực tiếp trên hệ thống** (đây là suy luận từ đối chiếu
2 file, chưa verify bằng log/Admin API thật): route này có đang trả lỗi thật
không, hay giữa 2 lần export có thêm 1 file upstream khác (`id:
upstream-lab-ceph-rgw-dc1`) chưa được gửi mà tôi chưa thấy. Nếu đúng là
tham chiếu sai, sửa bằng cách đổi dòng 7 thành
`upstream_id: "upstream-s3.hcm.lab.thuyldx"` để khớp đúng `id` thật.

`plugins` (dòng 15-22) dùng đúng pattern `proxy-control` (tắt buffering) +
`custom.s3-normalizer-bucket-name` giống route S3 production, nhưng
**không có** `custom.s3-accesskey-extractor`/`custom.s3-bucket-name-consumer`
(không cần AKID/bucket rate-limit cho traffic lab).

### apisix_routes/routes/route-s3.hcm.lab.thuyldx.yaml:30-34 — `ekyc-dc1`

`upstream_id: ekyc-backend-dc1` — **khớp đúng** với `id` thật trong upstream
file (`ekyc-backend-dc1`), khác với route S3 phía trên. Route đơn giản nhất
trong file — không `plugins`, không `timeout` riêng (dùng default). Comment
"Không phải S3 — không gắn normalizer" — nhắc rằng route này **cố tình**
không có `custom.s3-normalizer-bucket-name`, vì backend không phải Cloudian/
Ceph S3, không cần rewrite vhost→path.

### apisix_routes/routes/route-s3.hcm.lab.thuyldx.yaml:38-48 — `dc1-only-service`

`upstream` khai **inline** (không qua `upstream_id`) — khác 2 route trên,
không cần file upstream riêng vì chỉ dùng đúng 1 lần ở đây. `host:
test.dc1.lab` — domain giả lập, không thuộc bất kỳ cert nào đã note (không
`.thuyldx` cũng không `.sds.infiniband.vn`) — route này nếu truy cập qua
HTTPS sẽ **không match được SSL object nào**, chỉ dùng được qua HTTP thuần
hoặc test nội bộ không qua TLS. Mục đích theo comment: test case DC1-only
(HNI không có service tương ứng) — đã note khái niệm này ở phần `upstreams/`.

### apisix_routes/routes/route-s3.hcm.lab.thuyldx.yaml:52-74 — `fragment-1` / `fragment-2`

2 route **gần như giống hệt nhau**, chỉ khác `id` và `uri`
(`/fragment-1` vs `/fragment-2`), cùng trỏ 1 backend inline giống hệt
`dc1-only-service`. Theo comment "test merge fragments" — mục đích là kiểm
tra pipeline GitOps (`merge-fragments.sh`) xử lý đúng khi nhiều route nằm
trong **cùng 1 file fragment** hay khi bị tách thành **nhiều fragment khác
nhau** trỏ cùng 1 host — không phải service nghiệp vụ thật, thuần là fixture
kiểm thử cơ chế merge.

---

## [Cơ chế chung] `plugins/custom/` — 4 plugin Lua, thứ tự chạy trong `rewrite` phase

**Quy tắc priority của APISIX (xác nhận qua chính comment trong
`s3-bucket-name-consumer.lua`):** priority **CÀNG CAO chạy CÀNG SỚM** trong
cùng 1 phase — không phải ngược lại.

| Plugin | Priority | Phase | Thứ tự thực thi (rewrite phase) |
|---|---|---|---|
| `s3-normalizer-bucket-name` | 10005 | rewrite | 1 — chạy đầu tiên |
| `s3-bucket-name-consumer` | 9500 | rewrite | 2 — sau normalizer (cần đọc `ctx.s3_bucket_name`) |
| `cmc-validator-bucket-name` | 10004 | **access** (không phải rewrite) | route CMC không overlap route S3 nên thứ tự với 2 plugin trên không quan trọng |
| `s3-accesskey-extractor` | 2510 | rewrite | 3 — sau cả normalizer lẫn consumer (theo đúng priority) |

**🔴 Phát hiện — mâu thuẫn giữa 2 comment trong chính repo:**
`s3-accesskey-extractor.lua` (bản `-cũ.lua`) tự mô tả priority của mình:
*"priority = 2510, — cao, chạy sớm trong rewrite (trước/độc lập
normalizer)"*. Nhưng theo đúng quy tắc priority-cao-chạy-trước (đã xác nhận
bằng chính comment của `s3-bucket-name-consumer.lua`: *"Chỉ cần NHỎ HƠN
priority của s3-normalizer-bucket-name (10005) để chạy SAU"*), `2510` **nhỏ
hơn nhiều** so với `10005` của normalizer — nghĩa là **extractor thực chạy
SAU normalizer**, không phải "trước" như comment tự mô tả. 2 comment trong
cùng repo tự mâu thuẫn nhau về hướng priority.

**Có ảnh hưởng chức năng không?** Không — qua rà soát code, `extractor`
không đọc field nào do `normalizer` set (`ctx.s3_bucket_name`), và
`normalizer` cũng không đọc `ctx.s3_access_key` do `extractor` set — 2 plugin
độc lập dữ liệu với nhau nên thứ tự thực thi trước/sau giữa chúng **không
gây lỗi thật**. Đây thuần là **lỗi tài liệu** (comment sai), nhưng nên sửa
lại comment trong `s3-accesskey-extractor.lua` để không gây hiểu nhầm nếu
sau này có plugin mới thật sự cần phụ thuộc thứ tự với extractor.

---

## plugins/custom/cmc-validator-bucket-name.lua:1-180 — Toàn file

> Trục dữ liệu: **bucket name** (route CMC Portal, phase `access`) — xem
> [bảng so sánh 4 custom plugin & vì sao không gộp](#apisix_configconfig-dc_profileyaml207-210-so-sánh-4-custom-plugin-theo-trục-dữ-liệuroutephase-vì-sao-không-gộp).

Validate tên bucket khi user tạo bucket **qua CMC UI** (browser) — migrate từ
`cmc-conf.lua` (NGINX cũ). Phụ thuộc thư viện
`s3-validator-bucket-name-utils.lua` (qua `extra_lua_path`).

**So sánh với `s3-normalizer-bucket-name.lua`:**

| | `s3-normalizer` | `cmc-validator` |
|---|---|---|
| Đối tượng | S3 API (SDK/CLI) | Web portal (browser) |
| Validate khi nào | Mọi request | Chỉ `POST /s3/bucket/create.htm` |
| Lỗi trả về | 400 JSON | Redirect 302 (mặc định) hoặc 400 JSON |

### plugins/custom/cmc-validator-bucket-name.lua:87-93 — Vì sao chạy ở `access` phase (không phải `rewrite`)

Cần đọc **POST body** (`ngx.req.read_body()`) — body chỉ đọc được ổn định ở
`access` phase trở về sau; không cần rewrite URI/Host nên không cần chạy ở
`rewrite`; redirect phải xảy ra **trước khi** proxy forward request đi.

### plugins/custom/cmc-validator-bucket-name.lua:52-58, 155-164 — `REDIRECT_MAP` theo host

```lua
local REDIRECT_MAP = {
    ["sds.vnpaycloud.vn"]     = "/s3/storage?bucket-error=true",
    ["console.vnpaycloud.vn"] = "/entity/s3-storage?bucket-error=true",
    ["sds.infiniband.vn"]     = "/s3/storage?bucket-error=true",
    ["console.infiniband.vn"] = "/entity/s3-storage?bucket-error=true",
    ["cmc.sds.infiniband.vn"]  = "/s3/storage?bucket-error=true",
}
```

Giữ nguyên hành vi NGINX cũ (`cmc-conf.lua`): bucket name không hợp lệ →
redirect 302 về đúng trang lỗi theo domain đang truy cập. **Host không nằm
trong map** (domain mới chưa được thêm) → fallback trả `400 JSON` thay vì
silent fail (im lặng cho qua sẽ khiến user không biết vì sao tạo bucket thất
bại).

**Chế độ thay thế (JSON mode) đã bị xoá khỏi bản sạch:** bản `-cũ.lua` có 1
block comment mô tả cách chuyển sang trả `400 JSON` luôn thay vì redirect
(nhất quán với `s3-normalizer`) — đã dọn khỏi file hiện tại. Nếu cần đổi
sang JSON mode: bỏ đoạn `if redirect_path then ... else ... end` (dòng
76-83), thay bằng thẳng `return 400, { error_msg = "Invalid S3 bucket name
'" .. bucket_name .. "'" }`.

---

## plugins/custom/s3-accesskey-extractor.lua:1-106 — Toàn file

> Trục dữ liệu: **AKID** (khác hẳn trục bucket name của 3 file còn lại),
> priority 2510 độc lập — xem
> [bảng so sánh 4 custom plugin & vì sao không gộp](#apisix_configconfig-dc_profileyaml207-210-so-sánh-4-custom-plugin-theo-trục-dữ-liệuroutephase-vì-sao-không-gộp).

Trích AKID (AWS Access Key ID) từ request để dùng làm khoá rate-limit. Chạy
`rewrite` phase → **luôn** trước `limit-count` (chạy ở `access` phase).

### plugins/custom/s3-accesskey-extractor.lua:73-89 — Thứ tự trích AKID

```lua
local auth = core.request.header(ctx, "Authorization")
local akid = akid_utils.from_auth_header(auth)      -- 1. Header trước

if not akid then
    akid = akid_utils.from_query_args(core.request.get_uri_args(ctx))  -- 2. Query (presigned URL)
end

if not akid then
    if conf.anonymous_use_ip then
        akid = "ip:" .. (ctx.var.remote_addr or "unknown")  -- 3a. Fallback per-IP (mặc định)
    else
        akid = conf.anonymous_value                          -- 3b. Fallback giá trị cố định
    end
end
```

Ưu tiên header (đa số request đã ký SigV4/SigV2 qua `Authorization`), chỉ
parse query khi header không có AKID (tiết kiệm — chỉ presigned URL mới cần
query). `anonymous_use_ip: true` (mặc định) → mỗi IP vô danh tự thành 1 khoá
riêng, tránh mọi traffic anonymous dồn chung vào 1 bucket đếm.

**⚠ Giới hạn về bản chất — không phải chống abuse:** AKID lấy từ đây **có
thể bị client giả mạo** — gateway không verify chữ ký SigV4 thật (đó là việc
của Cloudian/Ceph backend). Đây là công cụ **đo đếm** cho traffic hợp lệ,
**không phải** cơ chế chống abuse. Guard theo IP (`global_rules/
global-abuse-guard.yaml` + `limit-conn` các tier) vẫn là lớp phòng thủ chính,
không thể bỏ qua chỉ vì có AKID-based rate-limit.

### plugins/custom/s3-accesskey-extractor.lua:40 — `set_header` an toàn với SigV4

Header `X-S3-Access-Key` **không nằm trong `SignedHeaders`** của SigV4 nên
**không** phá chữ ký khi gửi lên upstream — khác hẳn `X-Forwarded-Port` mà
Cloudian **có** dùng để ký (chính là nguyên nhân sự cố IAM đã note ở
`config-hcm.yaml`/`global-abuse-guard.yaml`: xoá `X-Forwarded-Port` toàn cục
làm Jetty hiểu sai port, gây `SignatureDoesNotMatch`). Comment này trong
chính file `.lua` xác nhận thêm 1 lần nữa: `X-Forwarded-Port` **là** 1 trong
các header Cloudian dùng để tính chữ ký, còn header tự thêm khác (như
`X-S3-Access-Key`) thì an toàn nếu không nằm trong danh sách `SignedHeaders`.

### plugins/custom/s3-accesskey-extractor.lua:57-66 — `register_var` bọc `pcall`

```lua
pcall(function()
    core.ctx.register_var("s3_access_key", function(ctx)
        return ctx.s3_access_key
    end)
end)
```

Đăng ký biến nội bộ 1 lần khi plugin load, bọc `pcall` để **không crash nếu
build APISIX không có `register_var`** — plugin vẫn nạp được, chỉ mất đường
truy cập qua biến `s3_access_key` (vẫn còn đường header
`http_x_s3_access_key` làm key thay thế cho `limit-count`).

---

## plugins/custom/s3-bucket-name-consumer.lua:1-135 — Toàn file (plugin phức tạp nhất, có lịch sử fix crash nghiêm trọng)

> Không phải plugin extraction — là **resolve Consumer** từ
> `ctx.s3_bucket_name` (phụ thuộc cứng vào `s3-normalizer`, chạy sau nó) —
> xem [bảng so sánh 4 custom plugin & vì sao không gộp](#apisix_configconfig-dc_profileyaml207-210-so-sánh-4-custom-plugin-theo-trục-dữ-liệuroutephase-vì-sao-không-gộp).

**⚠ Bản chất — ĐÂY KHÔNG PHẢI AUTHENTICATION THẬT:** plugin không verify chữ
ký, không verify secret nào cả. Tên bucket là thông tin **public** (nằm
thẳng trong URL), ai cũng "tự xưng" được. Plugin chỉ làm 1 việc: so khớp tên
bucket với 1 danh sách đã biết trước (đăng ký qua Git) để áp policy khác
nhau theo bucket — bản chất là **"named allowlist"**, không phải identity
verification. Muốn xác thực caller thật sự → đó là việc của AKID + backend
SigV4 (Cloudian/Ceph), không phải plugin này.

**Vì sao vẫn dùng `type = "auth"` dù không auth thật:** APISIX yêu cầu field
này để plugin được phép gọi `consumer_mod.attach_consumer()` và tham gia vào
thứ tự merge Consumer — đây là cách APISIX phân loại "plugin có quyền set
`ctx.consumer`", không bắt buộc plugin phải verify credential thật.

### plugins/custom/s3-bucket-name-consumer.lua:11-16 — Phụ thuộc bắt buộc vào `s3-normalizer-bucket-name`

Đọc `ctx.s3_bucket_name` do `s3-normalizer-bucket-name` export — **bắt buộc
chạy sau** plugin đó trong cùng route (đã đảm bảo qua priority 9500 < 10005,
xem mục cơ chế chung). Nếu route không có normalizer, hoặc normalizer bị bind
sai thứ tự, `ctx.s3_bucket_name` luôn `nil` → plugin này luôn no-op (an toàn
nhưng vô dụng — không gây lỗi, chỉ đơn giản là không hoạt động).

### plugins/custom/s3-bucket-name-consumer.lua:44-46, 109 — 🔴 Lịch sử fix bug nghiêm trọng: gọi sai chữ ký `find_consumer`

**⚠ Nội dung debug chi tiết dưới đây hiện CHỈ còn ở note này** — bản file
`.lua` mới đã rút gọn đoạn giải thích dài xuống còn đúng 1 dòng comment tại
dòng 109 (`-- Tự loop tìm theo .username — KHÔNG dùng
consumer_mod.find_consumer()`), không còn giữ nguyên văn essay debug như bản
`-cũ.lua` gốc — nếu cần đối chiếu lại "tại sao", tra ở đây thay vì tìm trong
file `.lua`.

**Đã đối chiếu trực tiếp với source code thật (2026-07-13)** —
`/usr/local/apisix/apisix/consumer.lua`,
`/usr/local/apisix/apisix/plugins/key-auth.lua`,
`/usr/local/apisix/apisix/plugins/consumer-restriction.lua`:

`consumer_mod.find_consumer(plugin_name, key, key_value)` — chữ ký **thật**
dùng để tìm consumer theo **giá trị 1 field bên trong `auth_conf`** (VD
`key-auth`: `find_consumer("key-auth", "key", <api-key-value>)` — so khớp
giá trị API key thật). **Không có khái niệm "tìm theo username"** trong hàm
này. Bản code trước đó gọi sai chữ ký (truyền bảng thay vì string) khiến hàm
**luôn trả `nil`**, bất kể bucket có đăng ký hay không — đã tái hiện đúng
qua log test: cả bucket đã đăng ký lẫn chưa đăng ký đều `nil` giống hệt
nhau.

**Fix:** không dùng `find_consumer` — tự loop `consumer_mod.plugin().nodes`,
so khớp field `.username`:

```lua
local plugin_conf = consumer_mod.plugin(CONSUMER_PLUGIN_KEY)
-- ...
local matched = nil
for _, c in ipairs(plugin_conf.nodes) do
    if c.username == lookup_username then
        matched = c
        break
    end
end
```

**`consumer_mod.plugin(name)` — "name" phải khớp y hệt key literal khai
trong `consumers.yaml`:** xem `consumer.lua`'s `plugin_consumer()`: `for
name, config in pairs(val.value.plugins) do ...` — "name" ở đây là **key
literal** trong YAML, không phải `_M.name` của plugin. Vì `consumers.yaml`
bắt buộc khai đầy đủ `custom.s3-bucket-name-consumer` (đã xác nhận qua bug
`check_single_plugin_schema` riêng — thiếu prefix `custom.` sẽ báo "unknown
plugin"), lookup cũng phải dùng đúng chuỗi đầy đủ này
(`CONSUMER_PLUGIN_KEY = "custom." .. plugin_name`, dòng 46) — `_M.name` (dòng
42) vẫn để trần vì đã xác nhận đúng cho **Route dispatch**, 2 mục đích khác
nhau, không đổi theo nhau.

### plugins/custom/s3-bucket-name-consumer.lua:126-130 — 🔴 Lịch sử fix crash nghiêm trọng: sai tham số `attach_consumer()`

**⚠ Cùng lưu ý như mục trên** — bản file `.lua` mới KHÔNG còn giữ đoạn
comment kể lại chi tiết lỗi crash gốc (message lỗi thật, dòng code gây lỗi),
chỉ còn 3 dòng mô tả **hành vi bình thường** của `attach_consumer()` (dòng
126-128). Đoạn lịch sử debug đầy đủ bên dưới hiện chỉ tồn tại ở note này.

**Version bump `0.3`** (dòng 57) chính là do fix bug này — đã ghi trong
memory trước đó, nay thấy rõ trong source: `attach_consumer(ctx, consumer,
conf)` — tham số thứ 3 **phải** là `conf` có field `.conf_version`, tức phải
là `plugin_conf` (kết quả `consumer_mod.plugin()`, có `conf_version` set sẵn
trong `consumer.lua`'s `plugin_consumer()`) — **không phải**
`matched.auth_conf` (config riêng của 1 plugin instance trên Consumer — ở
đây rỗng `{}` vì `consumers.yaml` khai `custom.s3-bucket-name-consumer: {}`,
bảng rỗng này không có field `conf_version` → `nil` → APISIX core nối chuỗi
để build cache key **crash toàn bộ request**, 500 cho **mọi** request tới
bucket đã resolve thành công — tức plugin càng "hoạt động đúng" (resolve
được bucket) thì càng chắc chắn crash, trước khi fix).

```lua
consumer_mod.attach_consumer(ctx, matched, plugin_conf)  -- ĐÚNG, plugin_conf có conf_version
```

### plugins/custom/s3-bucket-name-consumer.lua — ⚠ NAMESPACE COLLISION (phòng ngừa, chưa xảy ra thật)

`Consumer.username` **unique toàn instance**, không tách theo plugin/route.
`consumers.yaml` hiện dùng username **không prefix** cho control-plane (VD
`customer_acme`, `automation_reporting`, `internal_logcleaner`). Nếu 1
bucket tình cờ trùng tên 1 trong số đó, PUT consumer mới cùng username sẽ
**ghi đè toàn bộ object cũ** trong standalone mode (full-replace theo
username, không merge field) → mất credential `key-auth` của consumer
control-plane đó **mà không có cảnh báo rõ ràng**.

→ Bắt buộc prefix `"bucket-"` khi lookup (dòng 7, `USERNAME_PREFIX`), không
bao giờ dùng bucket name trần làm username. Prefix này **chỉ tồn tại nội bộ
trong lookup** — không áp lên bucket name thật; client vẫn tạo bucket qua S3
API bình thường theo đúng S3 naming convention, gateway tự nối prefix khi
tra Consumer, hoàn toàn vô hình với client.

> ⚠️ **ĐÃ LỖI THỜI (2026-08-12)** — plugin đã đổi tên `s3-bucket-name-consumer.lua`
> → `s3-qos-consumer.lua`, và toàn bộ naming Consumer/Consumer Group dưới đây
> (`consumer-group-s3bucket-restricted`, `consumers.yaml`) đã thay bằng bộ
> khung mới (8 Consumer Group cố định + 3 file consumer theo loại identity).
> Xem mục "[ĐÃ CHỐT — 2026-08-12] Khung cấu hình Consumer/Consumer Group cho
> QoS" ở cuối file — phần giải thích merge order/prefix bên dưới vẫn đúng
> nguyên lý, chỉ tên gọi thay đổi.

**Vận hành — thêm bucket mới vào policy riêng (LỊCH SỬ, xem bản mới ở cuối file):**
1. Thêm entry vào `consumers.yaml`: `username: "bucket-<tên-bucket>"`,
   `group_id:` trỏ đúng consumer group (VD
   `consumer-group-s3bucket-restricted`), `plugins: { custom.s3-bucket-name-
   consumer: {} }` (marker rỗng — **key phải có đủ prefix `custom.`**, thiếu
   sẽ bị `check_single_plugin_schema` báo "unknown plugin", Consumer coi như
   không có field này — bug thật đã gặp, 2026-07-13).
2. Commit, `gitsync` tự pull ≤30s, APISIX hot-reload.
3. **Không** cần restart container (khác sửa file `.lua` — luôn cần restart).
4. Verify: gọi request tới bucket đó, xem `error.log` có dòng `bucket=...
   resolved consumer=bucket-<tên-bucket>` (username luôn có prefix).

### plugins/custom/s3-bucket-name-consumer.lua:89,94,103,107,122,132 — 🟡 Cân nhắc hạ level log DEBUG

File hiện tại **vẫn giữ nguyên 6 dòng `core.log.warn(..., "[DEBUG]" ...)`**
chạy ở mọi nhánh, kể cả nhánh hoàn toàn bình thường (bucket chưa đăng ký
policy riêng — là trường hợp phổ biến nhất, đa số bucket). Vì plugin chạy ở
`rewrite` phase cho **mọi request** tới route S3 có bucket trong URL, mức
`WARN` cho log vốn chỉ mang tính debug sẽ tạo rất nhiều dòng `error.log` cấp
WARN cho hành vi hoàn toàn bình thường — dễ làm loãng log thật sự cần chú ý
(warn thật) và tăng I/O ghi log không cần thiết ở route traffic cao. Cân
nhắc hạ các dòng `[DEBUG]` xuống `core.log.info`/`core.log.debug`, chỉ giữ
`WARN` cho nhánh thật sự bất thường (nếu có) — hiện tại **mọi** nhánh đều
dùng `warn`, kể cả nhánh "bình thường, bucket chưa đăng ký".

### plugins/custom/s3-bucket-name-consumer.lua — ✅ Quyết định thiết kế: KHÔNG check K (AKID), đúng chủ đích

Đặt câu hỏi khi đối chiếu với cơ chế K>S>Anon vừa thêm ở
`s3-traffic-classifier.lua`: plugin này resolve Consumer chỉ dựa vào
`ctx.s3_bucket_name` (do `s3-normalizer-bucket-name` export), **không đọc
AKID** — dù chạy trước classifier (priority `9500` > `9000`) và Consumer
Group nó gán có thể **override toàn bộ** `limit-count`/`limit-conn` của
`plugin-config-traffic-classifier.yaml` (đúng thứ tự merge `Consumer >
Consumer Group > Route > Plugin Config > Service`). Đã kiểm tra 3 bucket
đăng ký thật trong `apisix_routes/consumers/consumer-bucket-name.yaml`
(`thuyldx-qos-internal`, `-partner`, `-restricted`) — cả 3 đều không cần K.

**Kết luận sau bàn bạc: đây là hành vi ĐÚNG chủ đích, không sửa.** Lý do —
plugin này là cơ chế **đặc cách theo bucket đã đăng ký thủ công** (qua Git
commit, có review), khác hẳn bản chất với bug gốc ở `s3-traffic-classifier`
(áp dụng tự động cho **mọi** bucket bất kỳ ai gõ vào URL, không curated):

- **Bucket public** — không cần K=1, đúng bản chất public.
- **"Mở gấp" quota cho 1 bucket không-public** — hành động **đăng ký bucket
  đó vào `consumers.yaml`** tự nó đã là bước xác thực (Mercy chủ động quyết
  định, qua GitOps có review) — không cần request tự chứng minh lại bằng K.
- **"Siết gấp" khi bucket có dấu hiệu bị tấn công** — đây là lý do quan
  trọng nhất để KHÔNG check K: nếu bắt buộc K=1 mới áp được rule siết,
  traffic tấn công (đa số không ký) sẽ né được rule siết, rơi tiếp xuống
  Anonymous/SNAT — vẫn tiêu vào pool dùng CHUNG với client anon/SNAT vô tội
  khác. Không check K, mọi request (ký hay không) tới bucket đó đều bị hút
  vào đúng 1 counter cô lập riêng — đúng mục đích cô lập tấn công ra khỏi 3
  pool chung, không lan thiệt hại sang người khác.

---

## plugins/custom/s3-normalizer-bucket-name.lua:1-139 — Toàn file

> Trục dữ liệu: **bucket name** (route S3 API, phase `rewrite`, priority
> 10005 — chạy trước `s3-bucket-name-consumer`) — xem
> [bảng so sánh 4 custom plugin & vì sao không gộp](#apisix_configconfig-dc_profileyaml207-210-so-sánh-4-custom-plugin-theo-trục-dữ-liệuroutephase-vì-sao-không-gộp).
> ⚠ Số dòng file thật hiện tại đã lên 327 (version 2.2) — xem đính chính ở
> mục cập nhật `139→328 dòng` bên dưới, phần "1-139" ở heading là mốc tài
> liệu hoá lần đầu, không phải số dòng file hiện tại.

**🔴 Đính chính — tên plugin không khớp hành vi thật hiện tại:** tên
"normalizer" (và mọi note trước đó ở `plugin_configs/`/`routes/` mô tả plugin
này là *"normalize vhost→path, validate bucket"*) ngụ ý plugin **rewrite**
URL vhost-style thành path-style. Nhưng đọc thẳng code (dòng 74-84): toàn bộ
logic rewrite thật (`ngx.req.set_uri(new_uri)`, đổi `Host` header) đã bị
**comment hết**, chỉ còn dòng `core.log.info(...,"(pass-through, không
rewrite)")` (dòng 92-93) — tự log rõ ràng là **không rewrite**. Hành vi thật
hiện tại của plugin: **chỉ extract + validate bucket name**, set
`ctx.s3_bucket_name` + header debug, **không đổi URI/Host** — response vẫn
đi theo request gốc (vhost-style vẫn giữ nguyên vhost-style tới tận
upstream, không bị rewrite thành path-style).

**Cần cập nhật lại mọi mô tả plugin này ở các phần note trước** (đã dùng
cụm "normalize vhost→path" trong note `config-hcm.yaml`/`routes/`) — hành vi
thật hiện tại là **chỉ validate + gắn nhãn bucket**, không rewrite. Có thể
tên file/plugin đang phản ánh **dự định thiết kế ban đầu** (từng có rewrite
thật, đã tắt) hơn là hành vi hiện tại.

### plugins/custom/s3-normalizer-bucket-name.lua:47-49 — Filter method (đang tắt)

```lua
-- if method ~= "PUT" then
--     return
-- end
```

Đang tắt → plugin chạy cho **mọi method** (GET, PUT, DELETE, HEAD...), không
chỉ riêng PUT như có thể từng thiết kế ban đầu (comment gợi ý từng có ý định
chỉ áp dụng cho PUT).

### plugins/custom/s3-normalizer-bucket-name.lua:60-94 — Nhánh vhost-style

```lua
if validator.isBucketInDomain(host_no_port, conf.vhost_domains) then
    local bucket = validator.extractBucketFromDomain(host_no_port, conf.vhost_domains)
    -- validate bucket, set ctx.s3_bucket_name + header, KHÔNG rewrite URI/Host
```

### plugins/custom/s3-normalizer-bucket-name.lua:95-136 — Nhánh path-style

Kiểm tra `host_no_port` có khớp `path_hosts` không → nếu không khớp cả
vhost lẫn path → pass through hoàn toàn (host lạ, không phải route S3 quản
lý). Nếu khớp path_host và `uri == "/"` → coi là `list-all-buckets`, pass
through không set `ctx.s3_bucket_name` (không có bucket cụ thể để gắn).
Ngược lại, extract bucket từ segment đầu URI (`extractBucketFromPath`),
validate, set `ctx.s3_bucket_name` + header.

---

## plugins/custom/s3-traffic-classifier.lua:1-257 — Toàn file

> Trục dữ liệu: **phân loại 3 nhóm** Authenticated/SNAT/Anonymous cho Layer 2
> (Dynamic Policy) — xem
> [bảng so sánh 4 custom plugin & vì sao không gộp](#apisix_configconfig-dc_profileyaml207-210-so-sánh-4-custom-plugin-theo-trục-dữ-liệuroutephase-vì-sao-không-gộp)
> (bảng đó viết trước khi có plugin này — vẫn đúng nguyên tắc, xem cập nhật
> thành 5 plugin ở đầu file).

Plugin thứ 5, ra đời sau khi 4 plugin gốc đã note xong (bổ sung cho kiến
trúc QoS/Rate-Limit 4 Layer — Layer 0 Parsing, Layer 1 Global, Layer 2
Dynamic Policy, Layer 3 Custom/Scale-up). Không extract dữ liệu mới — chỉ
**gắn nhãn nhóm** cho request đã đi qua Layer 0, dựa trên dữ liệu do
`s3-normalizer-bucket-name` (bucket) và cấu trúc IP request (remote_addr) đã
có sẵn, để Layer 2 có key rate-limit đúng theo 3 nhóm mà không cần if/else
thủ công ở tầng đó.

### plugins/custom/s3-traffic-classifier.lua:14-18 — Vì sao BẮT BUỘC chạy SAU `s3-normalizer-bucket-name`

**Lý do:** plugin đọc `ctx.s3_bucket_name` — biến này **chỉ tồn tại sau khi**
`s3-normalizer-bucket-name` đã chạy xong và set nó (xem CONTRACT trong chính
file `s3-normalizer-bucket-name.lua`). APISIX chạy các plugin cùng phase
(`rewrite`) theo thứ tự **priority giảm dần** — priority CÀNG CAO chạy CÀNG
SỚM (đã note tại mục priority order của `s3-bucket-name-consumer.lua`). Vì
vậy `s3-traffic-classifier` phải có priority **NHỎ HƠN** 10005
(`s3-normalizer-bucket-name`) — hiện đặt `9000`, cùng nguyên tắc priority
9500 của `s3-bucket-name-consumer` (một plugin khác cũng phụ thuộc
`ctx.s3_bucket_name`).

**Ví dụ cụ thể — request `PUT /my-bucket/file.jpg`, nếu đổi priority sai:**

| | Chạy ĐÚNG thứ tự (bây giờ) | Chạy SAI thứ tự (giả sử đặt priority = 11000, cao hơn normalizer) |
|---|---|---|
| 1. `s3-normalizer-bucket-name` (10005) chạy trước | Set `ctx.s3_bucket_name = "my-bucket"` | — (chưa tới lượt) |
| 2. `s3-traffic-classifier` (9000) chạy sau | Đọc `ctx.s3_bucket_name = "my-bucket"` → **có giá trị** → nhánh Authenticated → **không set** `X-SNAT`/`X-Real-Ip` (đúng thiết kế) | Đọc `ctx.s3_bucket_name` → **nil** (normalizer chưa chạy) → rơi nhầm vào nhánh SNAT/Anonymous → set `X-Real-Ip` hoặc `X-SNAT` cho 1 request **thực ra đã có bucket** |
| Hậu quả ở Layer 2 | Request tính đúng vào nhóm Authenticated (ngưỡng cao nhất theo bucket) | Request bị tính nhầm vào nhóm Anonymous/SNAT (ngưỡng thấp hơn hẳn) — client hợp lệ có thể bị 429 oan, sai hoàn toàn mục tiêu phân loại |

**Cách tự kiểm tra nếu nghi ngờ thứ tự bị sai:** gọi 1 request PUT vào bucket
có thật, xem log — nếu thấy dòng
`[s3-traffic-classifier]: [DEBUG] ctx.s3_bucket_name='...' — nhóm Authenticated`
là đúng thứ tự; nếu thấy request đó lại log ra nhánh SNAT/Anonymous dù chắc
chắn có bucket hợp lệ trong URL, tức priority đang bị đặt sai (hoặc route
thiếu bind `s3-normalizer-bucket-name`).

### plugins/custom/s3-traffic-classifier.lua:28-42 — 4 CIDR SNAT hiện tại là IP lẻ để test, KHÔNG phải dải NAT pool

Đã xác nhận với Mercy: 4 IP (`172.27.2.204`, `172.27.2.205`, `172.25.216.121`,
`172.25.216.168`) là **IP lẻ dùng để test trước khi lên production**, không
phải đại diện cho 1 dải NAT pool thật — khai `/32` cho từng IP là **đúng**,
không phải placeholder cần mở rộng CIDR. Khi triển khai production với dải
SNAT pool thật (nếu có), chỉ cần sửa lại `snat_cidrs` trong fragment
`plugin_metadata` (vd `/29`, `/30`...) — không đổi gì trong file `.lua` này.

### plugins/custom/s3-traffic-classifier.lua:59-66 — 🔴 Bug đã fix: `METADATA_ID` thiếu prefix `custom.` khiến `plugin_metadata` không load được

**Triệu chứng thật đã gặp:** deploy lần đầu, `curl .../v1/plugin_metadatas`
không trả entry nào cho plugin này dù fragment YAML đã merge đúng và
`gitsync` báo "active". **Bằng chứng — source chính thức**
(`apisix/admin/plugin_metadata.lua`, hàm `validate_plugin`):
```lua
local function validate_plugin(name)
    local pkg_name = "apisix.plugins." .. name
    local ok, plugin_object = pcall(require, pkg_name)
    ...
```
`id` khai trong `plugin_metadata` bị dùng trực tiếp để `require("apisix.plugins." .. id)`.
Ban đầu khai `id: s3-traffic-classifier` (không prefix) → APISIX thử
`require("apisix.plugins.s3-traffic-classifier")` — sai path, file thật ở
`apisix/plugins/custom/s3-traffic-classifier.lua` → require fail → metadata
bị coi "unknown plugin", không đăng ký.

**Cùng bản chất bug đã từng gặp** ở `s3-bucket-name-consumer.lua`
(`CONSUMER_PLUGIN_KEY = "custom." .. plugin_name`) — mọi lookup theo tên
plugin custom (dù qua Consumer hay qua `plugin_metadata`) đều cần full name
có prefix `custom.`, không phải tên rút gọn dùng nội bộ trong log.

**Fix:** thêm `METADATA_ID = "custom." .. plugin_name` (dòng 66), dùng
`METADATA_ID` khi gọi `apisix_plugin.plugin_metadata(...)` (dòng 115); đồng
thời sửa `id` trong fragment `apisix_routes/plugin_metadata/s3-traffic-classifier.yaml`
thành `custom.s3-traffic-classifier`. Đã verify lại bằng Control API — trả
đúng 4 CIDR sau fix.

⚠ Dòng 30 trong block comment ví dụ YAML (`- id: s3-traffic-classifier`)
**chưa được sửa theo fix này** — vẫn ghi thiếu prefix, dễ gây hiểu nhầm nếu
copy nguyên comment làm mẫu. Cần Mercy tự sửa lại comment cho khớp fix thật
khi tiện.

### plugins/custom/s3-traffic-classifier.lua — Route binding thật (đã deploy, 3 route S3 Cloudian)

| Route fragment | Dòng bind `custom.s3-traffic-classifier` |
|---|---|
| `apisix_routes/routes/hyperstore-cloudian/route-s3-hcm.infiniband.vn-https-443.yaml` | 30 |
| `apisix_routes/routes/hyperstore-cloudian/route-s3-hcm.sds.infiniband.vn-https-443.yaml` | 32 |
| `apisix_routes/routes/hyperstore-cloudian/route-s3-hni.sds.infiniband.vn-https-443.yaml` | 31 |

Không bind vào route CMC (`cmc-validator-bucket-name` không set
`ctx.s3_bucket_name`, phase khác — xem lý do đầy đủ ở mục "Vì sao BẮT BUỘC
chạy SAU" phía trên) và không bind vào `route-s3.hcm.lab.thuyldx` (Ceph lab,
ngoài phạm vi Cloudian QoS — câu hỏi còn treo, chưa chốt).

### plugins/custom/s3-traffic-classifier.lua — ✅ ĐÃ GIẢI QUYẾT: `error_log_level: debug` từng không phản ánh vào `nginx.conf` runtime

**Root cause thật sự (xác nhận bằng nguồn chính thức, không phải suy đoán):**
2 field `error_log`/`error_log_level` bị đặt sai vị trí — lồng trong
`nginx_config.http:` thay vì đúng vị trí cấp cao nhất của `nginx_config:`.
Chi tiết đầy đủ (bằng chứng đối chiếu `conf/config-default.yaml` chính thức
của `apache/apisix`, lý do đường dẫn log "tưởng vẫn đúng", diff fix đã áp
dụng) xem mục `apisix_config/config-{DC_PROFILE}.yaml:51-52` phía trên —
không lặp lại ở đây.

**Lịch sử điều tra sai hướng (giữ lại để tránh lặp lại nhầm lẫn tương
tự):** trước khi tìm ra root cause thật, đã loại các giả thuyết sau — trong
đó có 1 giả thuyết SAI cần đính chính:
- ~~Không phải do đặt sai vị trí field (`nginx_config.http.error_log_level`
  đúng chuẩn, đối chiếu GitHub thảo luận apache/apisix#7297)~~ — **kết luận
  này SAI**, đã dẫn nhầm 1 thảo luận cộng đồng thay vì nguồn chính thức.
  Đúng ra `nginx_config.http.error_log_level` chính là vị trí sai, xem mục
  trên.
- Không phải do volume giữ `nginx.conf` cũ qua restart (docs APISIX xác
  nhận `nginx.conf` render lại mỗi lần `apisix start`) — vẫn đúng.
- Không phải do dòng `error_log_level: debug` mới thêm sau lần restart gần
  nhất (`git log -p` xác nhận dòng này đã tồn tại từ trước) — vẫn đúng,
  nhưng không liên quan tới root cause thật.
- Không phải do `scripts/deploy/1-patch-template-lua.sh` (`grep -n
  "error_log"` trên toàn script → 0 kết quả) — vẫn đúng, không liên quan.

**Trạng thái hiện tại:** đã đổi lại `core.log.info` (bản gốc, đúng mức log
cho message không phải cảnh báo thật) — nay hiển thị đúng khi
`error_log_level` ở mức `info` trở lên (đặt đúng vị trí thì `debug`/`info`
đều thấy được, không chỉ `warn` như lúc còn lỗi vị trí).

### plugins/custom/s3-traffic-classifier.lua:109-138 — Cơ chế cache `matcher_cache` (TTL 60s)

`core_ip.create_ip_matcher()` build lại toàn bộ cấu trúc match từ đầu mỗi
lần gọi — tốn chi phí nếu gọi lại mỗi request. `matcher_cache` (TTL 60s) chỉ
build lại khi cache hết hạn, không phải mỗi request — đồng bộ tinh thần với
chu kỳ poll 30s của `gitsync`, không cần chính xác tuyệt đối theo từng giây
khi danh sách SNAT vừa đổi. Nếu vừa sửa `plugin_metadata.snat_cidrs` mà test
chưa thấy hiệu lực ngay, đợi tối đa 60s (TTL) + thời gian gitsync pull, KHÔNG
phải bug.

### ✅ ĐÃ XỬ LÝ: block comment mô tả 3 nhóm cũ (dòng 6-11 bản cũ) đã xoá

Bản `.lua` lúc mới thêm logic K>S>Anon (239 dòng) từng có **2 block comment
mô tả logic phân loại chồng nhau ở đầu file** — hệ quả patch tool chèn thêm
block mới thay vì thay thế block cũ. Đã áp diff xoá 6 dòng comment CŨ, xác
nhận qua file Mercy upload lại: còn đúng **232 dòng**, chỉ còn 1 block mô tả
duy nhất (K > S > Anon, dòng 6-23), `rewrite()` dịch lên còn dòng **172-230**
(mọi tham chiếu dòng trong note này đã cập nhật theo số mới).

## Quyết định thiết kế — nâng ưu tiên phân loại từ "có bucket" lên K > S > Anon

**Bối cảnh phát hiện vấn đề:** test thực tế `curl` không ký (`Authorization`
trống) tới `GET /thuyldx-cloud/` — bucket có thật, thuộc 1 khách hàng thật —
với logic CŨ (chỉ xét `ctx.s3_bucket_name`) vẫn bị xếp vào nhóm Authenticated,
dùng bucket name làm key rate-limit, **né hoàn toàn** 2 nhóm SNAT/Anonymous
vốn sinh ra để bắt đúng loại traffic không định danh được. Bằng chứng đối
chiếu `log.txt` (test 4 IP SNAT `GET /` ngày 2026-08-06): mọi request không
ký đều bị Cloudian trả `403`, `akid` log ra dạng fallback `"ip:<remote_addr>"`
(do `s3-accesskey-extractor.lua` dùng `anonymous_use_ip=true` khi không tìm
thấy AKID) — xác nhận Cloudian **luôn** đòi chữ ký hợp lệ bất kể request có
ghi đúng tên bucket hay không; gateway để lọt "có bucket = Authenticated" là
tự tạo ra 1 tier ưu đãi mà backend không hề công nhận.

### Bảng đơn — xét độc lập từng biến, không kết hợp

| Biến | Điều kiện | Nhóm (nếu chỉ xét biến này) |
|---|---|---|
| **B** — có bucket trong URL | `ctx.s3_bucket_name` khác `nil` | Authen-B |
| **B** — không có bucket | `ctx.s3_bucket_name` = `nil` | Anonymous |
| **K** — có AKID (ký được) | `Authorization`/presigned parse ra AKID | Authen-K |
| **K** — không có AKID | Không tìm thấy AKID ở cả 2 nguồn | Anonymous |
| **S** — IP ∈ danh sách SNAT | `remote_addr` khớp CIDR trong `plugin_metadata.snat_cidrs` | SNAT |
| **S** — IP ∉ danh sách SNAT | Không khớp CIDR nào | Anonymous |

3 nhánh đơn này không đủ để quyết định — 1 request luôn có **cả 3 giá trị**
B, K, S cùng lúc (VD: có bucket, có AKID, IP lại nằm trong dải SNAT), cần xét
kết hợp.

### Bảng đôi — vote theo từng cặp biến (mỗi cặp có 4 tổ hợp)

| B | K | Vote (cặp BK) | B | S | Vote (cặp BS) | K | S | Vote (cặp KS) |
|---|---|---|---|---|---|---|---|---|
| 1 | 1 | Authen | 1 | 1 | SNAT | 1 | 1 | *chưa xác định* |
| 1 | 0 | *chưa xác định* | 1 | 0 | *chưa xác định* | 1 | 0 | Authen |
| 0 | 1 | *chưa xác định* | 0 | 1 | SNAT | 0 | 1 | SNAT |
| 0 | 0 | Anonymous | 0 | 0 | Anonymous | 0 | 0 | Anonymous |

Ghép 3 cặp lại theo nguyên tắc "2/3 phiếu đồng thuận thắng" cho **6/8 tổ hợp**
B×K×S — còn đúng **2 tổ hợp hoà phiếu thật sự** (không giải được bằng vote,
chi tiết ở bảng ba bên dưới): `B=1,K=1,S=1` (BK bầu Authen, BS bầu SNAT, KS
hoà) và `B=0,K=1,S=0` (BK hoà, BS bầu Anon, KS bầu Authen).

### Bảng ba — bảng chân trị đầy đủ (8 lá B×K×S) + quyết định cuối theo K > S > Anon

| B | K | S | Vote (bảng đôi) | Quyết định cuối (K>S>Anon) | Key dùng ở Layer 2 | Ví dụ thực tế |
|---|---|---|---|---|---|---|
| 1 | 1 | 0 | Authen (2 phiếu) | **Authenticated** | `X-S3-Bucket-Name` (bucket) | `aws s3 cp` tới bucket, IP thường |
| 1 | 1 | 1 | ⚠️ Hoà (1-1) | **Authenticated** | `X-S3-Bucket-Name` (bucket) | `aws s3 cp` tới bucket, IP lại thuộc dải SNAT nội bộ — K thắng, không gộp vào pool SNAT |
| 1 | 0 | 1 | SNAT (2 phiếu) | **SNAT** | `X-SNAT` / `X-SNAT-Ip` | `curl` không ký `GET /<bucket>/`, IP nằm trong dải SNAT — case đã test thật (4 máy) |
| 1 | 0 | 0 | *(1 phiếu Anon, 2 chưa xđ)* | **Anonymous** | `X-Real-Ip` | `curl` không ký `GET /thuyldx-cloud/` — **case gốc phát hiện lỗ hổng** |
| 0 | 1 | 0 | ⚠️ Hoà (1-1) | **Authenticated** | `X-S3-Akid-Only` (AKID, mới thêm) | `aws s3 ls` (ListBuckets, không nhắm bucket cụ thể) |
| 0 | 1 | 1 | SNAT *(1 phiếu, 2 chưa xđ)* | **Authenticated** | `X-S3-Akid-Only` (AKID, mới thêm) | `aws s3 ls` từ IP thuộc dải SNAT — K vẫn thắng |
| 0 | 0 | 1 | SNAT (2 phiếu) | **SNAT** | `X-SNAT` / `X-SNAT-Ip` | `curl GET /` không ký, IP dải SNAT — đúng kết quả test 4 máy vừa chạy |
| 0 | 0 | 0 | Anonymous (3 phiếu) | **Anonymous** | `X-Real-Ip` | `curl GET /` không ký, IP thường |

**6/8 lá khớp nguyên trạng vote đa số** (không đổi gì so với trực giác ban
đầu). **2 lá hoà phiếu** (`111` và `010`) là đúng 2 chỗ luật `K > S > Anon`
phát huy tác dụng — nếu không có luật ưu tiên tường minh, code sẽ không biết
xử lý 2 case này thế nào (hoặc phải hardcode if/else tuỳ tiện, dễ sai khi mở
rộng).

### Giải thích — vì sao chọn `K > S > Anon`, không chọn `B > S > Anon`

**Cả B và K đều là claim CHƯA được gateway verify — không bên nào "chắc" hơn
bên nào ở tầng APISIX.** `s3-normalizer-bucket-name.lua` (dòng 300, 314) chỉ
parse cú pháp URL/host để set `ctx.s3_bucket_name` — không gọi Cloudian để
xác nhận bucket đó thật sự tồn tại. Tương tự, `s3-akid-utils.lua` (comment
đầu file) tự ghi rõ: *"Backend (Cloudian/Ceph) đã validate chữ ký SigV4 rồi;
gateway chỉ cần đọc AKID để làm khóa rate-limit"* — tức gateway không verify
chữ ký, chỉ trích AKID ra dùng làm key. Gõ 1 tên bucket bất kỳ vào URL dễ
như gõ 1 chuỗi `Authorization` giả — cả hai đều **chờ Cloudian xử lý mới biết
thật/giả**, không có bên nào gateway tự xác nhận được trước.

**Điểm khác biệt quyết định nằm ở: ai chịu thiệt khi tín hiệu đó là giả.**

| Tình huống sai | Nếu `B` thắng (ưu tiên bucket) | Nếu `K` thắng (ưu tiên AKID) |
|---|---|---|
| `curl` không ký, gõ đúng tên bucket khách hàng thật | Traffic rác **cộng dồn vào quota của chính khách hàng đó** — thiệt hại lan sang bên thứ ba không liên quan, đồng thời né được toàn bộ tầng chống-lạm-dụng SNAT/Anon | Rơi đúng SNAT/Anon theo IP — không đụng tới quota ai khác |
| `Authorization` giả, AKID bịa (không cần biết bucket thật) | (nếu không có bucket) rơi Anon/SNAT — không đụng ai | Nếu vô tình trùng có bucket: quota "rác" tự cô lập vào chính tên bucket bịa đó (không tồn tại thật) hoặc AKID bịa đó — không đụng khách hàng thật |

Sai ở `K` → thiệt hại tự khoanh vùng vào chính request đó (identity giả
không đụng tới ai). Sai ở `B` → thiệt hại **lan sang bên thứ ba thật** vì tên
bucket là thông tin công khai, đoán được, không cần biết gì về chủ bucket
cũng gõ được vào URL — đây chính là cơ chế của case gốc `curl
/thuyldx-cloud/`: chỉ cần biết 1 tên bucket public là né được toàn bộ tầng
SNAT/Anonymous.

Nhìn rộng hơn: mục đích tồn tại của 2 nhóm SNAT/Anonymous là bắt đúng
**"traffic gateway không quy được về danh tính trả phí nào"**. Một request
không ký tới bucket của người khác chính xác là loại traffic đó, bất kể URL
có ghi tên bucket hay không — cho `B` thắng tuyệt đối nghĩa là xoá luôn ý
nghĩa tồn tại của 2 nhóm kia.

**`B` không mất vai trò — chỉ đổi từ "điều kiện xếp tier" sang "điều kiện
chọn key" bên trong tier Authenticated (đã xác nhận `K=1`):** có bucket thì
dùng bucket làm key (per-bucket quota, per-bucket Consumer override qua
`s3-bucket-name-consumer.lua`), không có bucket thì fallback AKID
(`X-S3-Akid-Only`, case `ListBuckets`/account-op). Toàn bộ lợi ích
"bucket làm được nhiều việc ở tầng gateway" giữ nguyên 100% — chỉ khác là
phải có `K=1` đi kèm mới được hưởng, không phải chỉ cần gõ đúng tên bucket
là đủ.

### ✅ Đã test thật đủ 8/8 case (bảng ba) trên sandbox — khớp logic tuyệt đối

**Batch command test lại — chạy trực tiếp, dùng profile/bucket thật đang
có** (`thuyldx-cloud`). Case cần `S=1` PHẢI chạy trên 1 trong 4 máy SNAT
(`172.27.2.204`/`.205`/`172.25.216.121`/`.168`), case `S=0` chạy trên máy
thường. Toàn bộ đều read-only, chỉ đọc response header, không sửa gì trên
sandbox.

```bash
# ============================================================================
# Test đủ 8 case bảng chân trị B×K×S — s3-traffic-classifier.lua
# Đổi PROFILE/BUCKET nếu dùng khác thuyldx-cloud.
# ============================================================================
PROFILE=thuyldx-cloud
BUCKET=thuyldx-cloud
HOST=https://s3-hcm.sds.infiniband.vn
GREP='x-authen\|x-akidonly\|x-snat\|x-anon\|ratelimit'

# --- Case 1: B=1,K=1,S=0 — máy THƯỜNG ---
aws s3 ls "s3://${BUCKET}/" --endpoint-url "$HOST" --profile "$PROFILE" \
  --no-verify-ssl --debug 2>&1 | grep -i "$GREP"

# --- Case 2: B=1,K=1,S=1 — chạy TRÊN 1 máy SNAT (vd 172.27.2.204) ---
aws s3 ls "s3://${BUCKET}/" --endpoint-url "$HOST" --profile "$PROFILE" \
  --no-verify-ssl --debug 2>&1 | grep -i "$GREP"

# --- Case 3: B=1,K=0,S=1 — chạy TRÊN 1 máy SNAT, curl không ký ---
curl -sk -D - -o /dev/null "${HOST}/${BUCKET}/" | grep -i "$GREP"

# --- Case 4: B=1,K=0,S=0 — máy THƯỜNG, curl không ký (case gốc phát hiện lỗ hổng) ---
curl -sk -D - -o /dev/null "${HOST}/${BUCKET}/" | grep -i "$GREP"

# --- Case 5: B=0,K=1,S=0 — máy THƯỜNG, aws cli ListBuckets (không path bucket) ---
aws s3 ls --endpoint-url "$HOST" --profile "$PROFILE" \
  --no-verify-ssl --debug 2>&1 | grep -i "$GREP"

# --- Case 6: B=0,K=1,S=1 — chạy TRÊN 1 máy SNAT, aws cli ListBuckets ---
aws s3 ls --endpoint-url "$HOST" --profile "$PROFILE" \
  --no-verify-ssl --debug 2>&1 | grep -i "$GREP"

# --- Case 7: B=0,K=0,S=1 — chạy TRÊN 1 máy SNAT, curl không ký GET / ---
curl -sk -D - -o /dev/null "${HOST}/" | grep -i "$GREP"

# --- Case 8: B=0,K=0,S=0 — máy THƯỜNG, curl không ký GET / ---
curl -sk -D - -o /dev/null "${HOST}/" | grep -i "$GREP"
```

**Bảng kỳ vọng — header nào PHẢI xuất hiện, nhóm khác PHẢI vắng mặt hoàn
toàn** (2 nhóm header cùng lúc = match nhầm 2 rule, sai tính loại trừ):

| # | B K S | Header PHẢI thấy | Header PHẢI KHÔNG có |
|---|---|---|---|
| 1 | 1 1 0 | `X-Authen-RateLimit-*` | Akid-Only, Snat-*, Anon |
| 2 | 1 1 1 | `X-Authen-RateLimit-*` | Akid-Only, Snat-*, Anon (K thắng S) |
| 3 | 1 0 1 | `X-Snat-Group-*` + `X-Snat-Ip-*` | Authen, Akid-Only, Anon |
| 4 | 1 0 0 | `X-Anon-RateLimit-*` | Authen, Akid-Only, Snat-* |
| 5 | 0 1 0 | `X-AkidOnly-RateLimit-*` | Authen, Snat-*, Anon |
| 6 | 0 1 1 | `X-AkidOnly-RateLimit-*` | Authen, Snat-*, Anon (K thắng S) |
| 7 | 0 0 1 | `X-Snat-Group-*` + `X-Snat-Ip-*` | Authen, Akid-Only, Anon |
| 8 | 0 0 0 | `X-Anon-RateLimit-*` | Authen, Akid-Only, Snat-* |

Case 2 và 6 là 2 ô "hoà phiếu" trong bảng đôi mà luật `K > S > Anon` xử lý —
cần soi kỹ nhất nếu nghi ngờ logic sai.

Đợt test thật (2026-08-06) đối chiếu qua debug log `s3-traffic-classifier.lua`
(dòng `[DEBUG] AKID=...`/`remote_addr=... khớp SNAT CIDR`) khớp đúng access
log JSON theo `client` + `request_id`:

| # | B K S | Kết luận qua debug log | Khớp bảng chân trị? |
|---|---|---|---|
| 1 | 1 1 0 | Authenticated (key=bucket) | ✅ |
| 2 | 1 1 1 | Authenticated (key=bucket) | ✅ case hoà phiếu, K thắng S |
| 3 | 1 0 1 | SNAT | ✅ |
| 4 | 1 0 0 | Anonymous | ✅ case gốc phát hiện lỗ hổng ban đầu |
| 5 | 0 1 0 | Authenticated (key=AKID) | ✅ |
| 6 | 0 1 1 | Authenticated (key=AKID) | ✅ case hoà phiếu, K thắng S |
| 7 | 0 0 1 | SNAT | ✅ |
| 8 | 0 0 0 | Anonymous | ✅ |

Case 5→6 còn xác nhận thêm 1 điểm: counter `X-AkidOnly-RateLimit-Remaining`
giảm liên tục xuyên suốt (299→298) dù 2 request đến từ 2 IP khác nhau — đúng
tinh thần "định danh theo AKID, không phụ thuộc vị trí mạng client".

### 🔴 → ✅ Phát hiện & fix: Layer 2 double-count case B=1,K=0 (bucket có thật, không ký)

**Phát hiện qua chính đợt test 8 case ở trên** — dù `s3-traffic-classifier`
phân loại ĐÚNG (case 3/4 log ra SNAT/Anonymous), response header vẫn kèm
**cả `X-Authen-RateLimit-*` lẫn `X-Snat-*`/`X-Anon-*` cùng lúc**, tức 1
request bị 2 rule `limit-count` cùng tính — vi phạm nguyên tắc loại trừ lẫn
nhau. `X-Authen-RateLimit-Remaining` vẫn giảm đều 299→298 (case 1,2) →297
(case 3) →296 (case 4) dù case 3/4 KHÔNG có AKID, đáng lẽ không được đụng
tới rule Authen.

**Nguyên nhân gốc:** header `X-S3-Bucket-Name` (key của rule `Authen` ở
Layer 2) do `s3-normalizer-bucket-name.lua` set **VÔ ĐIỀU KIỆN**, chỉ cần
URL có bucket segment — file này ra đời trước khi có khái niệm K, không biết
gì về AKID. Khi thêm luật K>S>Anon, `s3-traffic-classifier.lua` chỉ thêm
header MỚI cho case B0K1 (`X-S3-Akid-Only`), nhưng không đụng tới
`X-S3-Bucket-Name` đã có sẵn cho case B1K0 — header đó tồn tại xuyên suốt
tới Layer 2, khiến rule Authen vẫn fire song song.

**Hậu quả trước fix:** case gốc Mercy phát hiện (`curl` không ký tới bucket
khách hàng thật) tuy đã bị chặn đúng ở SNAT/Anon (điểm tích cực của lần sửa
K>S>Anon), nhưng traffic đó **vẫn tiếp tục ăn vào quota của chính bucket
đó** — đúng vấn đề cốt lõi ban đầu chưa được đóng hoàn toàn, chỉ thêm 1 lớp
chặn chồng lên.

**Fix lần 1 (đã bị thay bằng fix lần 2 bên dưới) — thêm field
`bucket_name_header` (schema) + xoá header khi rơi vào nhánh K=0.** Cách này
tự khai 1 default riêng (`"X-S3-Bucket-Name"`) **trùng ngẫu nhiên** với
default thật của `s3-normalizer-bucket-name.lua` (`conf.set_header`) — tự
tạo ra rủi ro "2 default phải tự nhớ khớp nhau", đúng loại lỗi Mercy chỉ ra:
tự làm khó rồi tự đi vá cái khó tự tạo ra, trong khi thông tin cần dùng
(`set_header` thật của route) đã có sẵn trong `ctx.matched_route.value`,
không cần đoán/khai lại.

**Fix lần 2 (ĐANG DÙNG) — đọc thẳng `set_header` thật từ route object, không
khai default riêng:**

```diff
--- a/plugins/custom/s3-traffic-classifier.lua
+++ b/plugins/custom/s3-traffic-classifier.lua
@@ -203,6 +203,17 @@
         return
     end
 
+    -- Có bucket nhưng KHÔNG có AKID (K=0): PHẢI xoá header X-S3-Bucket-Name
+    -- (do s3-normalizer-bucket-name set VÔ ĐIỀU KIỆN) — nếu không rule
+    -- "Authen" ở Layer 2 vẫn fire song song với rule SNAT/Anon, double-count.
+    -- Đọc THẲNG conf.set_header thật của s3-normalizer-bucket-name từ route
+    -- object đang chạy (ctx.matched_route.value.plugins) — 1 nguồn sự thật
+    -- duy nhất, KHÔNG tự khai default riêng ở plugin này. Nếu route không
+    -- khai gì, APISIX đã tự điền default "X-S3-Bucket-Name" vào route object
+    -- lúc load (schema default), nên luôn đọc được giá trị thật đang áp
+    -- dụng, không phải giá trị đoán.
+    if ctx.s3_bucket_name then
+        local normalizer_conf = ctx.matched_route and ctx.matched_route.value
+            and ctx.matched_route.value.plugins
+            and ctx.matched_route.value.plugins["custom.s3-normalizer-bucket-name"]
+        local bucket_header = normalizer_conf and normalizer_conf.set_header
+        if bucket_header and bucket_header ~= "" then
+            core.request.set_header(ctx, bucket_header, "")
+        end
+    end
+
     -- Không có AKID → xét tiếp S (SNAT) rồi mới Anonymous, KHÔNG quan tâm có
     -- bucket hay không (bucket không kèm AKID không được tin làm định danh —
     -- xem lý do ở block comment đầu file).
```

**Guard `bucket_header ~= ""` không phải default thứ 2** — đây là xử lý 2
tình huống hợp lệ đã có sẵn trong `s3-normalizer-bucket-name.lua`: route cố
tình đặt `set_header: ""` để tắt export header, và phòng hờ
`ctx.matched_route` không tồn tại (an toàn hơn crash). Không có chuỗi mặc
định nào cần tự nhớ khớp nhau ở đây.

**Đã re-test sau fix, xác nhận đóng hoàn toàn:** case 3 (`curl` không ký,
IP SNAT) response chỉ còn `X-Snat-Group-*`/`X-Snat-Ip-*`; case 4 (`curl`
không ký, IP thường) response chỉ còn `X-Anon-*` — cả 2 case đều **không còn
`X-Authen-*`** trong response, đúng tính loại trừ lẫn nhau đã thiết kế từ
đầu (test này chạy trên fix lần 1, nhưng hành vi output không đổi ở fix lần
2 — chỉ đổi cách lấy giá trị header, không đổi logic xoá). File `.lua` sau
fix lần 2: **257 dòng**, `rewrite()` dịch xuống **172-255**.

---

**Giữ lại 1 đoạn comment ngắn (dòng 2-7)** liệt kê 4 dạng AKID mà thư viện hỗ
trợ (SigV4 header, SigV4 streaming, SigV2 header, presigned URL SigV4/SigV2)
— đây là dạng "chú thích tra cứu nhanh" (API cheatsheet), khác với sổ tay
debug 4 tầng đã bị xoá hẳn (xem mục bên dưới). Hợp lý để giữ vì đây là tham
chiếu về **hình dạng input** hàm này nhận diện, không phải lịch sử/giải
thích quyết định thiết kế — tương tự tinh thần giữ lại các toggle 1 dòng đã
thống nhất trước đó (VD `fallback_sni`), áp dụng cho comment tra cứu nhanh ở
thư viện thuần.

Không phụ thuộc `ngx`/`apisix` → test được bằng Lua thuần, không cần chạy
trong APISIX. Hỗ trợ 4 dạng lấy AKID: SigV4 header (`Credential=`), SigV2
header (`AWS <AKID>:<sig>`), SigV4 presigned (`X-Amz-Credential`), SigV2
presigned (`AWSAccessKeyId`).

**🟡 Phát hiện — `_M.extract()` (dòng 59-61) không được gọi ở đâu trong 4
plugin đã xem:** `s3-accesskey-extractor.lua` tự gọi `from_auth_header()` rồi
`from_query_args()` riêng lẻ (kèm logic anonymous-fallback chen giữa 2 bước),
**không** gọi hàm gộp `extract()` có sẵn trong thư viện này — hàm `extract()`
hiện là **API công khai không ai dùng** (dead code, không gây hại nhưng thừa,
có thể dọn hoặc để dành cho use-case khác trong tương lai).

**[ĐÃ GỠ KHỎI FILE] Sổ tay debug header 4 tầng — giá trị tham khảo cao, nên
giữ lại ở nơi khác:** bản `-cũ.lua` có 1 khối lớn ở cuối file (không phải
code, chỉ toàn comment) hướng dẫn debug header qua 4 tầng
(client→APISIX→upstream→APISIX→client), gồm 4 cách cụ thể:
1. `curl -v` / `curl -D -` — xem tầng 1 (client→APISIX) và tầng 4
   (APISIX→client), không cần setup gì thêm.
2. Dựng echo server tạm (`httpbin` qua Docker, hoặc `netcat` thủ công) +
   upstream/route debug tạm trỏ vào đó — xem chính xác tầng 2 (APISIX→
   upstream), tức thấy được APISIX **thực sự** forward gì lên backend
   (`X-S3-Access-Key`, `X-Real-IP`, `X-Forwarded-*`...).
3. Bật tạm `access_log_format` log cả header (**cảnh báo:** log
   `Authorization` = log credential, tuyệt đối không để trên production).
4. `serverless-pre-function` dump toàn bộ header ra `error.log` mức `WARN`
   — không cần restart container (hot-reload qua route YAML), che
   `Authorization` chỉ hiện AKID đã trích thay vì để lộ chữ ký thật.

Nội dung này **đã bị xoá hoàn toàn** khỏi bản sạch (đúng chuẩn "chỉ thuần
code" của thư viện) — nhưng đây là kiến thức debug thực dụng, mất đi sẽ phải
tự nghĩ lại từ đầu lần sau. Đề xuất: chuyển thành 1 runbook riêng (VD
`docs/runbook-debug-headers.md`) thay vì to trong file `.lua`, thay vì mất
hẳn.

### Tổng kết case Dynamic QoS (K>S>Anon) — đã Pass, 1 điểm chờ xác nhận riêng

**Đã giải quyết, xác nhận qua traffic thật:**
1. Lỗ hổng gốc (`curl` không ký gõ đúng tên bucket → ăn quota bucket, né
   SNAT/Anon) — fix bằng ưu tiên `K > S > Anon`.
2. Double-count (`X-S3-Bucket-Name` không bị xoá khi K=0) — fix bằng đọc
   trực tiếp `set_header` thật từ route object, không tự khai default riêng.
3. Case B=0,K=1 (ListBuckets/account-op có ký, không path bucket) — thêm
   nhánh key=AKID (`X-S3-Akid-Only`).
4. `limit-conn` mở rộng từ 1 rule (chỉ Authenticated-bucket) lên 5 rule
   (khớp đủ K>S>Anon) — xem mục
   `plugin-config-traffic-classifier.yaml:7-28` phía trên, gồm 2 pitfall
   schema đã gặp thật (`default_conn_delay` bắt buộc top-level,
   `header_prefix` không hỗ trợ per-rule).
5. Đủ 8/8 case bảng chân trị B×K×S đã test thật trên sandbox, khớp tuyệt
   đối, gồm cả 2 case "hoà phiếu" quan trọng nhất.
6. `s3-bucket-name-consumer.lua` (không check K) — xác nhận là quyết định
   thiết kế đúng, không phải bug (xem mục riêng phía trên).

**Còn 1 điểm CHƯA xác nhận xong, cần verify trước khi tin ngưỡng rate-limit
ở multi-node:** nghi vấn `policy: local` đếm counter riêng theo từng node
— xem mục `⚠️ CHƯA XÁC NHẬN XONG` ở phần `limit-count` phía trên, kèm lệnh
verify cụ thể (`dig` + `curl --resolve`).

**Việc còn treo, KHÔNG chặn việc coi case này Pass (đã ghi nhận từ trước,
không phát sinh mới từ đợt này):**
- Ngưỡng `count`/`conn`/`burst` toàn bộ vẫn là số test, chưa đo tải thật
  (backlog riêng, đã có hướng dẫn dùng `wrk` + Little's Law).
- 4 CIDR SNAT hiện là 4 IP `/32` test, chưa xác nhận dải NAT pool thật.
- Đặt tên chính thức Layer 3 consumer groups.
- CMC portal logging (bucket/IP/SNAT cho alert support).

---

## Cơ chế điều khiển log 2 tầng — `error_log_level` (nginx floor) + `custom.log-level` (plugin gate)

**Bối cảnh:** `nginx_config.error_log_level` trong `config-{DC_PROFILE}.yaml`
giữ cố định ở `warn` để hạn chế dung lượng log hệ thống (chi tiết đầy đủ,
kèm dẫn chứng nguồn chính thức, xem mục `config-{DC_PROFILE}.yaml:51-52`
phía trên). Nhưng khi cần debug 1 plugin/route cụ thể, không muốn phải đổi
`error_log_level` (ảnh hưởng TOÀN hệ thống, cần restart) — cần 1 cách bật
riêng lẻ, hot-reload, tự động tắt lại khi xong việc.

**Nguyên tắc cốt lõi — dễ hiểu sai nhất trong toàn bộ thiết kế này:**
`core_log_level`/`ngx_log_level` (trong `plugin_metadata: custom.log-level`)
**không phải mức Mercy muốn log hiện ra** — dòng log vật lý ghi ra LUÔN LUÔN
là `core.log.warn(...)`, cố định, không đổi. `core_log_level`/`ngx_log_level`
là **mức Mercy sẵn sàng CHO PHÉP thấy** — đúng ngữ nghĩa filter chuẩn của
mọi hệ thống log level (giống hệt cách `error_log_level` hoạt động): đặt
`warn` nghĩa là chỉ cho những gì **nghiêm trọng hơn hoặc bằng warn** đi qua,
tự động chặn `info`/`debug`/`notice`. Muốn thấy log `[DEBUG]` (bản chất gắn
`LEVEL_RANK.info = 7`) thì phải hạ `core_log_level`/`ngx_log_level` xuống
**`info` hoặc `debug`**, không phải giữ nguyên `warn`.

### Sơ đồ — đường đi thật của 1 dòng log `[DEBUG]` trong `s3-traffic-classifier.lua`

```
Code gọi:
  log_level_utils.emit("core", { SELF_ID, route_id }, LEVEL_RANK.info, "...")
              │
              ▼
┌─────────────────────────────────────────────────────────────────┐
│ TẦNG 2 — plugin_metadata "custom.log-level" (hot-reload, gitsync) │
│                                                                   │
│  core_log_level: warn (5)?  →  msg_rank(7) <= 5 ?  →  FALSE      │
│  ────────────────────────────────────────────────────           │
│  → DỪNG TẠI ĐÂY. Không gọi core.log.warn(). Log KHÔNG xuất hiện. │
│                                                                   │
│  core_log_level: info (7)?  →  msg_rank(7) <= 7 ?  →  TRUE       │
│  ────────────────────────────────────────────────────           │
│  → self_id có trong core_log_scope? → có → GỌI core.log.warn(...)│
└─────────────────────────────────────────────────────────────────┘
              │ (chỉ tới đây khi Tầng 2 = TRUE)
              ▼
┌─────────────────────────────────────────────────────────────────┐
│ TẦNG 1 — nginx floor, config-{DC_PROFILE}.yaml (restart)         │
│                                                                   │
│  error_log_level: warn  →  dòng vừa ghi ĐÃ LÀ warn  →  LUÔN qua  │
│  (không cần đổi gì ở tầng này — đây là lý do code luôn ép         │
│   core.log.warn(), để chắc chắn khớp đúng floor warn hiện tại)   │
└─────────────────────────────────────────────────────────────────┘
              │
              ▼
        logs/apisix/error.log  →  Mercy thấy dòng [warn] ... [DEBUG] ...
```

**Tóm lại — 2 điều kiện, cả 2 phải đúng, không thiếu cái nào:**
1. Tầng 2 (`core_log_level`/`ngx_log_level` ≥ mức của dòng log, VÀ `self_id`
   khớp `*_log_scope`) — Mercy chỉnh, hot-reload, đúng chỗ điều khiển hàng
   ngày.
2. Tầng 1 (`error_log_level` ≥ `warn`) — cố định, không cần đụng tới, vì
   code đã tự ép mọi log qua gate ở mức `warn`.

---

## plugins/custom/log-level.lua:1-72 — Toàn file

Plugin "neo" — **không có logic xử lý request**, không gắn vào route/
plugin_config nào. Tồn tại chỉ để `plugin_metadata` với `id: custom.log-level`
được `validate_plugin()` chấp nhận — cùng gốc bug đã gặp và fix ở
`s3-traffic-classifier` lúc thiếu prefix `custom.` (`validate_plugin()` gọi
`require("apisix.plugins." .. id)` để xác thực; id không phải 1 plugin thật
→ metadata bị coi "unknown plugin", không load được).

Đăng ký trong cả `config-hcm.yaml` và `config-han.yaml`:
```yaml
plugins:
  - custom.log-level
```

`metadata_schema` khai đủ `default`/`description` cho cả 4 field
(`core_log_level`, `core_log_scope`, `ngx_log_level`, `ngx_log_scope`) — dù
`example-plugin.lua` (file mẫu chính thức `apache/apisix`) không dùng 2
keyword này, nhưng đây là keyword JSON Schema chuẩn, `core.schema.check()`
hỗ trợ đầy đủ; thêm vào cho đúng quy ước comment/giải thích rõ ràng đang
giữ xuyên suốt hệ thống.

## plugins/libraries/log-level-utils.lua:1-61 — Toàn file

**Không phải plugin** — thư viện Lua thuần, `require("log-level-utils")`
(tên trần, không phải `apisix.plugins.libraries.log-level-utils`) — đúng
quy ước `extra_lua_path` trỏ thẳng `plugins/libraries/` đã dùng sẵn cho 2
thư viện khác (`s3-akid-utils`, `s3-validator-bucket-name-utils`), xác nhận
qua chính comment trong `s3-accesskey-extractor.lua`: `-- từ extra_lua_path
(plugins/libraries)`.

### `LEVEL_RANK` — 8 mức, đúng thứ tự hằng số nginx thật

```lua
local LEVEL_RANK = {
    emerg = 1, alert = 2, crit = 3, error = 4,
    warn  = 5, notice = 6, info = 7, debug = 8,
}
```
Nguồn xác nhận: comment gốc trong `conf/config.yaml.example` (repo chính
thức `apache/apisix`) — *"Logging level: info, debug, notice, warn, error,
crit, alert, or emerg"*. Thứ tự numeric khớp đúng hằng số `NGX_LOG_EMERG=1
... NGX_LOG_DEBUG=8` trong mã nguồn nginx — không phải tự sắp, đây là thứ
tự thật nginx dùng nội bộ, từ ít tốn dung lượng nhất (`emerg`) đến nhiều
nhất (`debug`).

### `_M.emit(field_prefix, self_ids, msg_rank, ...)`

- `field_prefix`: `"core"` (dùng trong `plugins/custom`) hoặc `"ngx"` (dùng
  trong `serverless-pre-function`/`serverless-post-function`) — quyết định
  đọc `core_log_level`/`core_log_scope` hay `ngx_log_level`/`ngx_log_scope`.
  **Không trộn 2 loại scope** — `core_log_scope` chỉ chứa tên plugin (vd
  `custom.s3-traffic-classifier`), `ngx_log_scope` chỉ chứa tên
  `plugin_config`/route (vd `plugin-config-traffic-classifier`,
  `route-s3-hni.sds.infiniband.vn-https-443`) — 2 trục khác bản chất, không
  thể dùng chung (xem lý do đầy đủ ở phần giải thích "tại sao ngx_log_scope
  không dùng được tên plugin" — bản thân `serverless-post-function` chỉ có
  **1** plugin tên duy nhất cho mọi route, không có "nhiều serverless-
  post-function" để phân biệt theo tên như phía `plugins/custom`).
- `self_ids`: 1 string hoặc 1 table nhiều string (vd `{SELF_ID, route_id}`)
  — khớp bất kỳ 1 phần tử nào trong scope là đủ để bật. Cho phép vừa bật
  theo tên plugin/plugin_config (áp cả cụm) vừa bật riêng theo route cụ
  thể, tùy Mercy khai gì vào `*_log_scope`.
- `msg_rank`: dùng `log_level.LEVEL_RANK.info`/`.debug`/... để gọi, không
  hardcode số.
- Bên trong: nếu qua được cả gate mức (Tầng 2) lẫn scope, **luôn** gọi
  `core.log.warn(...)` — bất kể `msg_rank` truyền vào là gì — để chắc chắn
  vượt qua nginx floor cố định (Tầng 1). Xem sơ đồ đầy đủ ở mục "Cơ chế
  điều khiển log 2 tầng" phía trên.

## apisix_routes/plugin_metadata/log-level.yaml:1-12 — Toàn file

```yaml
plugin_metadata:
  - id: custom.log-level
    core_log_level: warn
    core_log_scope:
      - custom.s3-traffic-classifier
    ngx_log_level: warn
    ngx_log_scope:
      - plugin-config-traffic-classifier
```
Đây là **chỗ Mercy chỉnh hàng ngày** khi cần bật/tắt debug — hot-reload qua
gitsync 30s, không cần restart. Mặc định giữ `warn` (im lặng, không bật gì)
— chỉ hạ xuống `info`/`debug` khi thật sự cần xem, xong việc trả lại `warn`
ngay, đúng nguyên tắc "chỉnh 1 chỗ, áp dụng hàng loạt, xong trả về mức vừa
đủ" đã thống nhất từ đầu tính năng này.

**Áp dụng thực tế cho `s3-traffic-classifier.lua`
(`plugins/custom/s3-traffic-classifier.lua:172-255`, phase `rewrite`)**: cả
4 lời gọi `log_level_utils.emit("core", ...)` (nhánh Authenticated key=bucket,
Authenticated key=AKID, SNAT, Anonymous — xem đủ 4 nhánh ở mục "Quyết định
thiết kế — nâng ưu tiên phân loại" phía trên) đều dùng `{ SELF_ID, route_id }`
làm `self_ids` — `route_id` lấy qua
`ctx.matched_route.value.id` (đúng mẫu chính thức `example-plugin.lua`,
`apache/apisix`) — cho phép `core_log_scope` bật theo tên plugin (áp cả 3
route) HOẶC bật riêng theo route id cụ thể. Riêng dòng `core.log.warn(...)`
báo `remote_addr rỗng` (tình huống bất thường thật) **không** đi qua
`log_level.emit()` — luôn log, không phụ thuộc cấu hình debug.

**Áp dụng thực tế cho `serverless-post-function`
(`apisix_routes/plugin_configs/plugin-config-traffic-classifier.yaml`)**:
tương tự, `log_level.emit("ngx", { SELF_ID, route_id }, ...)` cho nhánh
`[rate-limit-info]`. Riêng nhánh `[rate-limit-warning]` (đã vượt `warn_pct`
— cảnh báo nghiệp vụ thật) **không** qua gate, luôn `ngx.log(ngx.WARN, ...)`
trực tiếp.

---

## plugins/libraries/s3-validator-bucket-name-utils.lua:1-136 — Toàn file

Thư viện thuần Lua, không phụ thuộc `ngx`/`apisix`. Dùng chung cho cả 2
plugin `s3-normalizer-bucket-name` và `cmc-validator-bucket-name`.

### plugins/libraries/s3-validator-bucket-name-utils.lua:37-46 — `isBucket()` — quy ước đặt tên nội bộ, chặt hơn chuẩn S3 thật (chủ đích)

```lua
function _M.isBucket(name)
    if not name then return false end
    if string.match(name, "^%w+%-%w[%w%-]*%w$") then return true end  -- dạng dài
    if string.match(name, "^%w+%-%w$") then return true end            -- dạng ngắn
    return false
end
```

**Cả 2 pattern đều bắt buộc có ít nhất 1 dấu gạch ngang `-`.** Theo quy tắc
đặt tên bucket **thật** của S3 (AWS/Cloudian/Ceph), tên bucket **không bắt
buộc** phải có dấu gạch ngang — VD `"mybucket"` (không gạch ngang) vẫn là tên
hợp lệ theo chuẩn S3, nhưng bị hàm này từ chối là "invalid bucket name".

**Xác nhận (Mercy, 2026-07-28): đây là chủ đích**, không phải giới hạn ngoài
ý muốn — nội bộ áp quy ước đặt tên bucket bắt buộc dạng `word-word` (khớp
với mọi ví dụ bucket đã thấy xuyên suốt các file trước: `data-lake-01`,
`logs-hcm`...). `isBucket()` ở đây đang validate theo **quy ước đặt tên nội
bộ**, chặt hơn (không phải khác biệt tuỳ ý) so với giới hạn kỹ thuật thật sự
của S3 — bucket tên `"mybucket"` dù hợp lệ với Cloudian/Ceph vẫn sẽ bị
APISIX từ chối **trước khi** request chạm tới backend, đúng theo thiết kế.

### plugins/libraries/s3-validator-bucket-name-utils.lua:55-62, 25-27 — `isBucketInPath()` / `isMatch()` — 🟡 dead code

Cả 2 hàm này **không được gọi** ở bất kỳ đâu trong 4 plugin đã xem (
`s3-normalizer-bucket-name.lua` dùng `isBucketInDomain`,
`extractBucketFromDomain`, `isBucket`, `extractBucketFromPath` — không dùng
`isBucketInPath`/`isMatch`). Có thể là API dự phòng cho use-case tương lai,
hoặc tàn dư từ thiết kế cũ trước khi chuyển hẳn sang dùng
`extractBucketFromPath` + `isBucket` riêng lẻ.

### plugins/libraries/s3-validator-bucket-name-utils.lua:87-119 — `isBucketInDomain()` / `extractBucketFromDomain()`

Yêu cầu `domains` là **Lua pattern đã escape sẵn** (`.` → `%.`, `-` → `%-`)
— trách nhiệm escape thuộc về **caller** (route YAML khai `vhost_domains`),
thư viện không tự escape giúp. Đã note ở phần `routes/`/`config-hcm.yaml`
nhưng đây là nơi thực thi thật của quy tắc đó.

---

## scripts/deploy/1-patch-template-lua.sh:1-320 — Toàn file (script patch source code APISIX gốc, chạy 1 lần lúc setup)

**Đọc trực tiếp được từ file bạn upload dù nội dung không hiện trong tin
nhắn** — file này lớn (320 dòng) nên không hiện đầy đủ trong khung chat,
nhưng vẫn nằm trên đĩa nên tôi đọc thẳng để viết note. Không cần gửi lại nội
dung, chỉ cần xác nhận đây đúng là bản bạn muốn note.

**Cơ chế chung:** script `docker run --rm` image APISIX gốc (`apache/apisix:
3.15.0-debian`), `cat` file `.lua` gốc ra `<file>.orig` (bản chưa sửa, dùng
để diff), rồi tạo bản đã patch `<file>.lua` (không đè `.orig`) — 2 file này
sau đó được mount `:ro` đè lên đúng path gốc trong container qua
`docker-compose.yaml` (xem phần `volumes:` đã note bên dưới). Đây là cách
"patch" APISIX mà **không** sửa trực tiếp image hay rebuild — image gốc giữ
nguyên, chỉ có 5 file `.lua` bị ghi đè lúc container khởi động.

**⚠ Rủi ro cố hữu của cách patch này (áp dụng cho cả 5 patch):** patch dựa
trên `sed`/`grep -v`/Python string-replace khớp theo **nội dung source code
thật** của APISIX 3.15.0. Upgrade version APISIX → source code gốc có thể
đổi khác → pattern match có thể **không khớp nữa** (patch [4]/[5.a]/[5.b] đã
tự có bước verify sau patch để bắt sớm trường hợp này — xem bên dưới), hoặc
tệ hơn, **khớp nhầm chỗ khác** nếu code mới tình cờ chứa chuỗi tương tự.
Script tự nhận thức rủi ro này qua các dòng comment "Nhạy cảm với thay đổi
source code qua mỗi version — verify diff kỹ" ở patch [4] và [5.a].

### scripts/deploy/1-patch-template-lua.sh:32-38 — Patch [1/5] `ngx_tpl.lua` — xoá `proxy_set_header X-Forwarded-Port`

```bash
grep -v 'proxy_set_header.*X-Forwarded-Port' "${DEPLOY_DIR}/ngx_tpl.lua.orig" > "${DEPLOY_DIR}/ngx_tpl.lua"
```

**Đây chính là NGUYÊN NHÂN GỐC của sự cố IAM đã note nhiều lần trước đó**
(`config-hcm.yaml`, `global-abuse-guard.yaml`, `s3-accesskey-extractor.lua`):
xoá dòng này để fix S3 SigV4 (Cloudian dùng `X-Forwarded-Port` để tính chữ
ký, header do NGINX template mặc định set sai giá trị gây lệch chữ ký), *vô
tình* làm Jetty (`ForwardedRequestCustomizer`) mặc định port về 443 thay vì
16443 trên route IAM/STS → `SignatureDoesNotMatch`. Fix thật sự nằm ở
**route** (`route-iam.../route-sts...yaml` tự thêm lại `X-Forwarded-Port:
"$server_port"` qua `proxy-rewrite`), không phải revert patch này — patch
này **vẫn giữ nguyên xoá ở tầng template global**, chỉ IAM/STS tự bù lại ở
route riêng.

### scripts/deploy/1-patch-template-lua.sh:39-48 — Patch [2/5] `init.lua` — xoá `X-Forwarded-Port` khỏi `upstream_proxy_headers`

Cùng mục đích với patch [1] nhưng ở lớp khác (`init.lua` thay vì
`ngx_tpl.lua`) — comment ghi rõ khớp **cả 2 pattern** có thể tồn tại tuỳ
version APISIX (`set_header(api_ctx, "X-Forwarded-Port"` kiểu APISIX 3.16
core.request.set_header, và `var_x_forwarded_port...= 'X-Forwarded-Port'`
kiểu bảng cấu hình cũ) — patch cho 3.15.0 hiện tại nhưng viết dự phòng cho
khả năng APISIX 3.16 đổi cách set header.

### scripts/deploy/1-patch-template-lua.sh:50-77 — Patch [3/5] `vault.lua` — hỗ trợ Vault KV v2

**Patch này BẮT BUỘC GIỮ, không đụng vào.** `vault.lua` gốc trong APISIX chỉ
hỗ trợ path kiểu Vault KV **v1**; Vault team đang dùng KV **v2** — không patch
thì mọi request tới Vault sai path/sai field ngay từ bước build request, không
liên quan gì tới bug `PEM_read_bio` đã điều tra riêng (đó là do đặt
`secret_providers` sai file, xem mục "Cert qua Vault — cơ chế đúng"). Đính
chính bên dưới (27/08/2026) chỉ sửa 1 chi tiết cách DÙNG patch này cho đúng
(không viết tay `/data/` trùng lặp trong URI `$secret://...`), không phải sửa
hay bỏ patch.

3 patch nhỏ trong cùng file, dùng `sed -i` nối tiếp trên cùng bản đã copy
(không cat lại từ image gốc mỗi patch nhỏ):
1. Thêm `/data/` vào path Vault — patch tự chèn `/data/` **ngay sau
   `conf.prefix`** trong lúc build request tới Vault, đúng chuẩn Vault KV v2
   (`<mount>/data/<path>`). **Đính chính 27/08/2026:** vì patch đã tự chèn,
   KHÔNG được viết tay thêm `/data/` trong URI `$secret://...` nữa (đó chính
   là option 3 sai ở phần `ssls/` — viết tay `/data/` gây lệch cấu trúc parse
   URI, không liên quan gì tới việc "map /data/ đúng hay sai" như note gốc
   từng suy đoán). `prefix` khai trong provider chỉ được là mount Vault
   (vd `cloud/profile`) để patch chèn `/data/` đúng chỗ — xem đầy đủ ở mục
   "Cert qua Vault — cơ chế đúng" cuối file.
2. Điều kiện check thêm `ret.data.data` (KV v2 trả response lồng thêm 1 tầng
   `data` so với KV v1: `{data: {data: {...}, metadata: {...}}}` — code gốc
   chỉ check `ret.data`, không đủ cho KV v2).
3. Extract giá trị từ `ret.data.data[sub_key]` thay vì `ret.data[sub_key]` —
   khớp đúng cấu trúc response KV v2 ở bước 2.

**Có verify tự động sau patch** (dòng 72-77): `grep` lại 3 dấu hiệu patch đã
áp đúng (`"/data/"`, `ret.data.data then`, `ret.data.data[`) — `exit 1` nếu
bất kỳ dấu hiệu nào thiếu, tránh chạy tiếp với patch dở dang.

### scripts/deploy/1-patch-template-lua.sh:79-104 — Patch [4/5] `config_yaml.lua` — làm rõ warn message "reloaded"

**Patch thẩm mỹ** (tự ghi rõ "không ảnh hưởng chức năng") — message gốc
`"config file ... reloaded."` **gây hiểu nhầm nghiêm trọng**: dễ đọc thành
"mọi config đã reload", nhưng thực ra chỉ `apisix-${DC_PROFILE}.yaml`
(routes/plugin_configs/services/upstreams/consumers/ssls) hot-reload —
`config-${DC_PROFILE}.yaml` (nginx_config, plugin_attr...) **không bao giờ**
hot-reload, luôn cần restart container. Message mới nói rõ cả 2 vế trong 1
dòng log, giảm rủi ro ai đó tưởng sửa `config-hcm.yaml` xong tự áp dụng mà
không restart (đúng loại nhầm lẫn dễ xảy ra nếu không đọc kỹ tài liệu — đã
note ở `config-hcm.yaml`: "config.yaml KHÔNG hot-reload").

### scripts/deploy/1-patch-template-lua.sh:106-238 — Patch [5.a] + [5.b] `kafka-logger.lua` — thêm `ssl`/`ssl_verify`/`api_version`

**Patch hành vi chức năng thật** (tự phân biệt với patch [4] thẩm mỹ) —
chính là nguồn gốc của field `ssl`/`ssl_verify`/`api_version` đã note ở
`global-kafka-logger.yaml`. Dùng Python (không dùng `sed`) vì cần match
**block nhiều dòng chính xác** (schema field + broker_config field), kèm
kiểm tra `content.count(old) != 1` → `exit 1` nếu anchor không khớp đúng 1
lần (không khớp = source đổi; khớp nhiều lần = pattern không đủ đặc hiệu,
có thể patch nhầm chỗ) — an toàn hơn nhiều so với `sed` mù không kiểm tra.

**Patch [5.b] (dòng 170-227) phải chạy SAU [5.a] trên CÙNG 1 file đã patch**
(comment dòng 173-174 nhấn mạnh "KHÔNG cat lại từ image gốc") — 2 patch nối
tiếp cùng 1 file, không độc lập.

**Verify cuối cùng dùng chính `luajit` bên trong image APISIX** (dòng
233-236, 163-166) để kiểm tra **cú pháp Lua hợp lệ** sau patch — bắt được
lỗi syntax do patch string-replace gây ra (VD thiếu dấu ngoặc) trước khi
patch được mount vào container thật, tránh crash loop lúc APISIX khởi động.

**⚠ Patch chỉ MỞ KHẢ NĂNG dùng field, KHÔNG tự bật:** dòng 267-272 ghi rõ
vẫn phải tự khai `ssl: true` / `ssl_verify: false` / `api_version: 2` trong
`global_rules/global-kafka-logger.yaml` — patch này chỉ làm schema APISIX
**chấp nhận** field, không tự set giá trị.

**⚠ `api_version: 2` là bắt buộc, không phải mặc định** (dòng 271-272,
187-196 trong schema mới: `default = 1`) — quên set `api_version: 2` trong
YAML thì Kafka message vẫn dùng Message Format cũ, timestamp vẫn epoch-0 dù
đã patch xong field `ssl`. Cách verify dứt điểm (dòng 311-319): mở Redpanda
Console xem cột TIMESTAMP của message **mới** — phải ra giờ hiện tại, không
phải `1/1/1970`. **Message cũ ghi trước patch giữ epoch-0 vĩnh viễn, không
hồi tố được.**

**Ghi chú riêng — `plugin_metadata` KHÔNG thuộc patch này** (dòng 274-291):
field `log_format` của `kafka-logger` (đã note ở
`plugin_metadata/log-format-kafka-logger.yaml`) **có sẵn** trong schema gốc,
không cần patch. Khai ở file `plugin_metadata` riêng, hot-reload qua gitsync
bình thường, không cần chạy lại script patch này hay restart container.

---

## scripts/deploy/decrypt-cert-helper.sh:1-20 — Toàn file + `scripts/libraries/cert-list-domains.txt:1-25` (đi cùng cặp, phải sync 2 file)

`CERT_DOMAINS` (dòng 3-8) — danh sách domain dùng chung cho cả 2 file (dòng
22-25 của `cert-list-domains.txt`) — comment gốc nhấn mạnh **sửa domain phải
sửa cả 2 file cùng lúc**, không có cơ chế tự động đồng bộ giữa chúng (2 file
độc lập, không file nào generate ra file kia).

**🟡 Phát hiện — override `SRC_CERT_FILE`/`SRC_KEY_ENC_FILE` cho `cmc.sds.
infiniband.vn`/`minio.sds.infiniband.vn` (dòng 10-17) hiện đang KHÔNG được
dùng tới:** 2 domain này có override tên file nguồn (đuôi `-crt.pem`/
`-key.pem.enc`, khác convention chuẩn `<domain>.cert`/`<domain>.key.enc`) —
nhưng **không nằm trong `CERT_DOMAINS`** (chỉ có 4 entry: `infiniband.vn`,
`sds.infiniband.vn`, `s3-hcm.sds.infiniband.vn`, `s3-hni.sds.infiniband.vn`).
Vòng lặp xử lý cert chỉ chạy qua `CERT_DOMAINS`, nên 2 dòng override này
**hiện là dead config** — không gây lỗi gì, nhưng cũng không có tác dụng cho
tới khi `cmc.sds.infiniband.vn`/`minio.sds.infiniband.vn` được thêm vào
`CERT_DOMAINS`. Khớp với thực tế đã note ở `ssls/`: CMC hiện dùng chung cert
wildcard `*.sds.infiniband.vn` (`ssl-sds.infiniband.vn.yaml`), không có SSL
object riêng — 2 override này nhiều khả năng là chuẩn bị sẵn cho kịch bản
tương lai CMC cần cert riêng (khác nguồn, đặt tên kiểu nginx cũ), chưa tới
lúc dùng.

**Helper function (dòng 19-20)** — `${SRC_CERT_FILE[$1]:-$1.cert}`: có
override → dùng tên override; không có → fallback về convention chuẩn
`<domain>.cert`. Đây là pattern bash phổ biến (`${array[key]:-default}`),
cho phép hầu hết domain dùng convention mặc định, chỉ liệt kê ngoại lệ.

---

## scripts/deploy/profile-map.yaml:1-23 — Toàn file

Quy tắc: chỉ áp dụng cho `[routes]` và `[upstreams]` — `ssls/`, `services/`,
`global_rules/`, `consumer_groups/`, `consumers/` **luôn shared**, không lọc
theo DC profile, luôn include vào mọi profile.

**Đối chiếu với `upstreams/` đã note trước đó — khớp chính xác:**
- `hyperstore-cloudian-hcm`/`lab-ceph-rgw-hcm` → chỉ `hcm` (đúng — 2 upstream
  này chỉ tồn tại/có ý nghĩa cho DC HCM).
- `hyperstore-cloudian-hni` → `hni,han` — 2 tên gọi cho cùng 1 profile (đã
  note trước: file `global-kafka-logger.yaml` cũng cần verify region ra đúng
  `"hcm"`/`"han"` chứ không phải `"hni"` — tên profile thật dùng trong hệ
  thống là `han`, còn `hni` chỉ là alias tương thích, map cả 2 vào cùng
  route/upstream).
- Còn lại (`admin`, `cmc`, `hyperiq`, `iam`, `sqs`) → `*` (shared, đúng vì
  các service internal-console/auth này chạy chung cấu hình cho mọi DC).

**⚠ `[upstreams]` KHÔNG có dòng cho `hyperstore-cloudian-sts`** — **đúng**,
không phải thiếu sót: STS không có upstream riêng (dùng chung
`upstream-iam.sds.infiniband.vn`, đã note ở `upstreams/`/`routes/
route-sts...yaml`), nên không cần khai trong `[upstreams]`. Route `sts` vẫn
có mặt ở `[routes]` (dòng 12) vì route STS **có tồn tại** như 1 route riêng
dù share upstream.

**Cơ chế fallback an toàn (comment gốc, không phải bug):** subfolder không
khớp key nào → mặc định `*` (shared) + log WARNING trong `merge-fragments`,
**không** phải hard error — cho phép "adopt dần dần" map này mà không chặn
pipeline nếu quên khai 1 route/upstream mới.

---

## scripts/runtime/gitsync.sh:1-198 — Toàn file (exec hook chạy sau mỗi lần `git-sync` pull thành công)

**Chạy bởi `GITSYNC_EXECHOOK_COMMAND`** (khai trong `docker-compose.yaml`,
mỗi 30s theo `GITSYNC_PERIOD`) — không phải cron/service riêng, mà là hook
được `git-sync` container tự gọi sau mỗi lần pull commit mới thành công.

### scripts/runtime/gitsync.sh:35-42 — Lock chống chạy chồng (thêm sau đợt upgrade 3.17.0)

```bash
LOCK_DIR="/tmp/.gitsync.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log_err "ERROR: lần chạy gitsync.sh trước (PID ...) chưa xong — SKIP lần này để tránh ghi chồng lên STAGING đang dở"
  exit 1
fi
echo "$$" > "${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}"' EXIT
```

**Vì sao cần:** exechook của `git-sync` v4.2.1 chạy đồng bộ trong vòng lặp
sync (chưa xác nhận chắc chắn ở mức source code của binary git-sync, chỉ
suy luận từ tài liệu chung) — không nên tin tưởng tuyệt đối. Lock bằng
`mkdir` (atomic ở filesystem, không cần thêm dependency) tự bảo vệ bất kể
git-sync có tự serialize đúng hay không, đặc biệt quan trọng nếu sau này
`merge-fragments.sh` + `inject-certs.sh` chạy lâu hơn `GITSYNC_PERIOD` (30s)
— tránh 2 lần exechook ghi chồng lên cùng 1 file `STAGING`.

### scripts/runtime/gitsync.sh:63-111 — Layout "fragments" (đang dùng) — atomic swap qua STAGING

Điều kiện chọn layout: có đủ 4 thư mục `upstreams/`, `routes/`, `services/`,
`ssls/` (dòng 63-66) → gọi `merge-fragments.sh` rồi `inject-certs.sh`.

**🔧 Thay đổi kiến trúc quan trọng sau đợt upgrade 3.17.0 — atomic swap qua
file `STAGING`:**

```bash
STAGING="${OUTPUT}.staging"

if ! run_logged "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${STAGING}"; then
  ...
  rm -f "${STAGING}"
  exit 1
fi

INJECT_OK=1
if [ -f "${INJECT_SCRIPT}" ]; then
  if ! OUTPUT="${STAGING}" CERTS_DIR="/tmp/certs" DOMAINS_FILE="..." \
     run_logged sh "${INJECT_SCRIPT}"; then
    INJECT_OK=0
  fi
fi

if [ "${INJECT_OK}" -eq 0 ]; then
  log_err "ERROR: inject-certs.sh thất bại ... ABORT, KHÔNG promote STAGING vào file live."
  rm -f "${STAGING}"
  exit 1
fi

cp "${STAGING}" "${OUTPUT}"
rm -f "${STAGING}"
```

**Root cause dẫn tới thay đổi này — race giữa merge và inject trên chính
file live:** trước đây `merge-fragments.sh` ghi thẳng ra `OUTPUT` (file bind-
mount vào container) — vì source git chỉ chứa placeholder
`<PASTE_CONTENT_OF_...>`, không chứa cert thật, nên **ngay sau merge, file
live tạm thời chứa toàn placeholder**, rồi `inject-certs.sh` mới ghi đè lại
`OUTPUT` **nhiều lần liên tiếp** (1 lần `cp` cho mỗi domain × cert/key, tối
đa 8 lần cho 4 domain) để thay dần placeholder bằng PEM thật. Giữa các lần
ghi đó, `config_yaml.lua` (hot-reload watcher chạy trong worker APISIX,
timer riêng, đọc file độc lập với chu kỳ gitsync) có thể đọc trúng đúng lúc
file đang ở trạng thái dở dang → lỗi
`failed to check item data of [ssls] err:property "key" validation failed:
string too short, expected at least 64, got 42` (giá trị 42 ký tự khớp
chính xác độ dài chuỗi placeholder `<PASTE_CONTENT_OF_...key_HERE>\n`) —
**đây chính là nguyên nhân thật** của lỗi `failed to match any SSL
certificate by SNI` xuất hiện chập chờn, khác SNI mỗi lần gặp, tự hết khi
`docker compose up -d --force-recreate` (restart là hành động thời điểm
ngẫu nhiên, xác suất trúng đúng cửa sổ dở dang vài chục ms gần như bằng 0 —
**giảm xác suất**, không phải **loại bỏ** nguyên nhân).

**Fix bằng STAGING:** toàn bộ 9 lần ghi (1 merge + tối đa 8 inject) giờ chỉ
xảy ra trên `${OUTPUT}.staging` — file `config_yaml.lua` hoàn toàn không
biết tới, không đọc. File live (`OUTPUT`) chỉ nhận đúng **1 lệnh `cp` duy
nhất**, atomic ở mức filesystem (dữ liệu đã hoàn chỉnh 100% trước khi `cp`
chạy) — worker đọc file live vào bất kỳ thời điểm nào trong chu kỳ 30s chỉ
có thể thấy 1 trong 2 trạng thái: bản cũ hoàn chỉnh, hoặc bản mới hoàn
chỉnh — không còn trạng thái thứ 3 (dở dang) để đọc trúng. Đây là **fix cấu
trúc**, khác hẳn workaround "restart để giảm xác suất" — sau khi áp dụng,
không cần restart vì lý do race này nữa (vẫn cần restart cho các lý do khác
đã note — đổi `config.yaml`, `.env`, patch `.lua`, xem bảng tổng hợp ở mục
upgrade 3.17.0 phía trên).

Nếu `merge-fragments.sh` hoặc `inject-certs.sh` fail giữa chừng → `STAGING`
bị xoá (`rm -f`), `OUTPUT` **giữ nguyên bản cũ, không bị đụng tới** — đúng
tinh thần "1 lỗi cấu hình không kéo sập gateway" đã thống nhất trước đó,
lần này áp dụng đúng ở tầng deploy-time thay vì runtime validate.

**🟡 Phát hiện — điều kiện phát hiện layout ở đây KHÔNG khớp với yêu cầu bắt
buộc của `merge-fragments.sh`:** `gitsync.sh` chỉ check tồn tại 3 thư mục
(`upstreams`, `routes`, `ssls`) để quyết định "đây là layout fragments",
nhưng `merge-fragments.sh` (dòng 16) coi **`services/`** cũng là thư mục
**bắt buộc** (hard error nếu thiếu). Nếu ai đó có đủ `upstreams/`/`routes/`/
`ssls/` nhưng lỡ xoá/quên tạo `services/`, `gitsync.sh` vẫn nghĩ layout hợp
lệ và gọi `merge-fragments.sh` — script đó sẽ tự `exit 1` (an toàn, không
sinh output sai), nhưng log lỗi chỉ nói chung chung "merge-fragments.sh thất
bại" (dòng 65) chứ không tự nói rõ ngay là do thiếu `services/`. Không gây
hỏng dữ liệu (fail an toàn), nhưng debug sẽ mất thêm 1 bước đọc log của
`merge-fragments.sh` mới ra nguyên nhân thật.

### scripts/runtime/gitsync.sh:130-152 — Layout "legacy" (dự phòng, không phải layout đang dùng)

Nhánh `elif` xử lý trường hợp **không** có cấu trúc fragment (`upstreams/`+
`routes/`+`ssls/`), mà có sẵn 1 file `apisix-${DC_PROFILE}.yaml` viết tay —
copy thẳng file đó thành output, kèm cảnh báo nếu route template đổi mà
quên chạy lại `inject-certs.sh`. **Đây là đường dự phòng/tương thích ngược**
— không phải cách đang vận hành thật (toàn bộ note trước đó đều dựa trên
layout fragments), giữ lại để không breaking nếu ai đó revert về cách cũ.

### scripts/runtime/gitsync.sh:160-174 — Sync `plugins/` và `scripts/`

Copy toàn bộ `plugins/` (custom + libraries) và `scripts/` từ git clone vào
`/tmp/plugins`/`/tmp/scripts` — đây là cách `plugins/custom/*.lua` đã note
trước đó **thực sự cập nhật vào container đang chạy**: dù bind-mount `:ro`
từ thư mục trên host (`docker-compose.yaml`), nội dung thư mục đó **chính
là** nơi `gitsync` ghi vào mỗi 30s — plugin `.lua` do đó **cũng hot-reload
theo gitsync** (khác hẳn 5 file bị patch ở `1-patch-template-lua.sh`, vốn
mount thẳng từ file cố định ngoài git, không đổi theo gitsync).

### scripts/runtime/gitsync.sh:176-185 — `apisix_config/` — CỐ TÌNH tắt tự động sync

```bash
# echo "[gitsync] Syncing apisix_config/..."
# if [ -d "${SYNC_SRC}/apisix_config" ]; then
#   cp -r "${SYNC_SRC}/apisix_config/." "/tmp/apisix_config/"
```

**Toàn bộ block bị comment chủ đích** — `apisix_config/config-${DC_PROFILE}.
yaml` (nginx_config, plugin_attr...) do **admin quản lý tay**, không để
gitsync tự động ghi đè, đúng với nguyên tắc đã note nhiều lần: file này
**không hot-reload**, đổi phải restart container — tự động sync mà admin
không biết sẽ gây lệch giữa file trên đĩa và trạng thái container đang chạy
(container vẫn chạy config cũ cho tới khi restart, nhưng git đã có version
mới) — im lặng comment sẵn để bật thủ công khi cần, tránh rủi ro auto-sync
âm thầm.

---

## scripts/runtime/inject-certs.sh:1-123 — Toàn file

Chạy sau `merge-fragments.sh` mỗi lần gitsync (không phải chạy riêng lẻ) —
thay các placeholder `<PASTE_CONTENT_OF_<domain>.<ext>_HERE>` (đã note ở
phần `ssls/`) bằng nội dung PEM thật đọc từ `${CERTS_DIR}`. Từ đợt upgrade
3.17.0, script này luôn được `gitsync.sh` gọi với `OUTPUT="${OUTPUT}.
staging"` (không phải file live trực tiếp) — xem mục "Layout fragments —
atomic swap qua STAGING" ở section `gitsync.sh` phía trên.

### scripts/runtime/inject-certs.sh:45-86 — Cơ chế inject — dùng `sed` phối hợp 3 bước để tránh vấn đề multi-line

```bash
sed 's/^/      /' "${CERT_FILE}" > "${TEMP_PEM}"                    # 1. Indent PEM 6 space
MARKER="__INJECT_${PID}_...__"                                       # 2. Marker duy nhất
sed "s|      ${PLACEHOLDER}|${MARKER}|" "${OUTPUT}" \
| sed "/${MARKER}/r ${TEMP_PEM}" \                                    # 3a. Đọc file PEM chèn sau marker
| sed "/${MARKER}/d" > "${TEMP_OUT}"                                  # 3b. Xoá dòng marker
```

`sed` gốc không thay thế 1 dòng bằng **nội dung nhiều dòng** trực tiếp — kỹ
thuật chuẩn là thay placeholder bằng 1 **marker duy nhất** (có PID + hash để
tránh trùng giữa các domain/lần chạy song song), rồi dùng `r` (read file)
chèn nội dung PEM ngay sau dòng marker, cuối cùng xoá dòng marker đi.

**`PID=$$` trong tên file tạm** (`/tmp/pem-${PID}-...`) — tránh xung đột nếu
script này (về lý thuyết) chạy đồng thời nhiều lần, dù thực tế chỉ có 1
gitsync hook chạy tại 1 thời điểm.

**Không dùng `sed -i`** (dòng 76-77 comment giải thích) — cố tình ghi ra
`TEMP_OUT` rồi `cp` đè lên `OUTPUT` thay vì sửa in-place, để **giữ nguyên
inode** của file `OUTPUT` — quan trọng vì file này đang bind-mount vào
container Docker; `sed -i` thường tạo file mới rồi rename (đổi inode),
có thể làm container không thấy thay đổi nếu bind-mount theo inode thay vì
theo path (tuỳ Docker storage driver).

### scripts/runtime/inject-certs.sh:56-65 — Domain không dùng cert riêng → tự động OK, không phải lỗi

```bash
if ! grep -qF "${PLACEHOLDER}" "${OUTPUT}" 2>/dev/null; then
    continue  # placeholder không có → domain này không dùng cert riêng → OK
fi
```

Domain có trong `cert-list-domains.txt` nhưng placeholder không xuất hiện
trong output (VD SSL object dùng Vault thay vì raw PEM) → bỏ qua êm, không
tính là lỗi/thiếu. Chỉ báo `MISSING` khi **có** placeholder nhưng **không**
tìm thấy file cert nguồn tương ứng trong `${CERTS_DIR}`.

### scripts/runtime/inject-certs.sh:92-102 — Đếm placeholder còn lại sau inject — 🔧 ĐÃ ĐỔI từ chỉ-báo sang HARD FAIL (Tầng 0 validate)

```bash
REMAINING=$(grep "PASTE_CONTENT_OF_" "${OUTPUT}" 2>/dev/null | wc -l | tr -d ' ')

if [ "${REMAINING}" -gt 0 ]; then
    echo "[inject-certs] WARN: ${REMAINING} placeholder(s) còn lại — APISIX SSL sẽ fail cho domain tương ứng" >&2
    echo "[inject-certs] FATAL: ABORT — không cho phép file có placeholder chưa inject được promote vào live..." >&2
    exit 1
fi
```

**Hành vi cũ (trước đợt upgrade 3.17.0):** `REMAINING > 0` chỉ in `WARN`,
không `exit 1` — script vẫn kết thúc "thành công" dù còn placeholder chưa
inject. Đây chính là lỗ hổng cho phép `gitsync.sh` (bản cũ, ghi thẳng ra
`OUTPUT` không qua `STAGING`) tiếp tục coi file live là "hợp lệ" ngay cả khi
vẫn còn placeholder — góp phần vào root cause của lỗi
`failed to check item data of [ssls]` đã note ở mục STAGING phía trên.

**Hành vi mới:** `REMAINING > 0` → `exit 1` ngay — đây là "Tầng 0" của thiết
kế validate 2 tầng (nhẹ, chạy ngay trong pipeline, không cần thêm
dependency/container, bắt đúng lớp bug placeholder). Kết hợp với `gitsync.
sh` gọi script này trên `STAGING` (không phải `OUTPUT` trực tiếp), `exit 1`
ở đây khiến `gitsync.sh` set `INJECT_OK=0` → **không chạy `cp` swap** → file
live giữ nguyên bản cũ, không bao giờ nhận 1 bản có placeholder.

**Trường hợp domain chưa có cert thật (khác lỗi placeholder tạm thời do
race):** nếu 1 domain trong `cert-list-domains.txt` chưa từng có file cert
tại `${CERTS_DIR}` (chưa chạy `3-decrypt-certs.sh`, không phải do race) —
`MISSING` sẽ tăng cùng lúc với `REMAINING` (cùng domain), script vẫn `exit
1` như trên. Đây là thay đổi hành vi có chủ đích: **thà chặn cả lần deploy
đó lại** để admin biết ngay và bổ sung cert, còn hơn để APISIX chạy với 1
`ssls` entity chứa placeholder rồi tự fail âm thầm lúc handshake — đánh đổi
"1 domain thiếu cert chặn deploy toàn bộ" lấy "không còn silent failure",
chấp nhận được vì tần suất thêm domain mới thấp, không phải thao tác hàng
ngày.

**Tầng 1 (đầy đủ hơn, dùng `apisix test` thật qua container Docker
ephemeral) — chưa triển khai, chỉ mới thiết kế, để dành cho bước gate thủ
công trước khi rollout production thật (khác sandbox), không chạy tự động
mỗi 30s vì chi phí tạo/xoá container không đáng cho tần suất đó.**

---

## scripts/runtime/merge-fragments.sh:1-302 — Toàn file (script lõi của toàn bộ pipeline GitOps)

Nhận 2 tham số: `ROUTES_SRC` (thư mục fragment nguồn) và `OUTPUT` (file
`apisix-${DC_PROFILE}.yaml` đích) — chạy 3 pass tuần tự.

### scripts/runtime/merge-fragments.sh:16-21 — Thư mục core bắt buộc

```bash
for d in upstreams routes services ssls; do
  if [ ! -d "${ROUTES_SRC}/${d}" ]; then
    echo "[merge-fragments] ERROR: Thiếu thư mục bắt core ${ROUTES_SRC}/${d}" >&2
    exit 1
```

4 thư mục **bắt buộc phải tồn tại**: `upstreams`, `routes`, `services`,
`ssls` — thiếu 1 trong 4 là hard error, dừng ngay (xem phát hiện về
`gitsync.sh` không check `services/` ở mục trên). `plugin_configs`,
`global_rules`, `consumer_groups`, `consumers` là **tuỳ chọn** — thiếu chỉ
skip êm (`validate_block_dir`/`append_block` tự return sớm nếu thư mục
không tồn tại), cho phép "adopt dần dần" từng loại tài nguyên.

### scripts/runtime/merge-fragments.sh:113-186 — Pass 1: Validate (hard error nếu sai cấu trúc)

Mỗi file `.yaml` trong mỗi thư mục phải có **key đầu tiên** (dòng không phải
comment/blank đầu tiên) khớp đúng **tên thư mục chứa nó** — VD file trong
`routes/` phải bắt đầu bằng `routes:`, không được là `upstreams:` hay bất kỳ
key nào khác. Đây chính là cơ chế đã note thấy hiệu ứng ở `plugin_configs/`
(mọi file `.yaml` đều bắt đầu đúng `plugin_configs:`) và `global_rules/`
(đều bắt đầu `global_rules:`) — validate này là **lý do** các file phải giữ
đúng key gốc dù đã dọn sạch comment.

**File bị comment TOÀN BỘ nội dung** (VD `global-loki-logger.yaml`,
`global-http-logger.yaml` đã note trước đó — toàn bộ file kể cả dòng
`global_rules:` đầu tiên đều bị `#`) → `get_file_key` trả rỗng → **không**
coi là lỗi, chỉ log `WARN "Bỏ qua file bị comment toàn bộ (disabled
template)"` rồi skip. Đây chính là cơ chế cho phép "tắt" 1 file hoàn toàn
bằng cách comment hết, đã thấy áp dụng thực tế ở 2 file loki/http-logger.

### scripts/runtime/merge-fragments.sh:188-241 — Pass 2: Gộp nội dung — thứ tự append theo chiều phụ thuộc

```
upstream → service → plugin_config → route → global_rule → consumer_group → consumer → ssl
```

Đúng thứ tự phụ thuộc dữ liệu thật (service cần upstream đã tồn tại, route
cần service+plugin_config, consumer_group cần được route/consumer reference
tới...) — dù APISIX parse toàn bộ YAML nên thứ tự này **không bắt buộc về
mặt kỹmặt kỹ thuật** (YAML không thực thi tuần tự như code), nhưng giữ thứ
tự này giúp file output dễ đọc theo đúng luồng tư duy khi debug thủ công.

**Mỗi file được prefix comment `# ── src: <path gốc>`** (dòng trong
`append_block`) trước khi nội dung được append — đây chính là dòng `# ──
src: consumer_groups/consumer-group-s3bucket-internal.yaml` đã thấy trong
bản `-cũ.yaml` của `consumer_groups/` ở note trước đó — **tự động sinh ra
bởi script này**, không phải comment thủ công của Mercy. Giúp truy ngược
1 block trong file output đã merge về đúng file fragment nguồn.

**Strip dòng key header** (`strip_key_header`, gọi trong `append_block`) —
bỏ dòng đầu (`routes:`/`upstreams:`...) của từng file fragment trước khi
nối, vì `append_block` đã tự in `%s:\n` (dòng key) **1 lần duy nhất** ở đầu
mỗi block gộp — nếu không strip, file output sẽ có key `routes:` lặp lại N
lần (1 lần/file fragment), là YAML không hợp lệ (duplicate key ở cùng cấp).

### scripts/runtime/merge-fragments.sh:243-269 — Pass 3: Check duplicate `id`/`username` — chỉ WARNING, không chặn merge

```bash
DUP_IDS=$(grep -E '^[[:space:]]+-[[:space:]]+id:' "${TMP_OUTPUT}" | ... | uniq -d)
```

Quét toàn bộ output đã merge tìm `id:` trùng nhau (áp dụng chung cho
upstreams/services/routes/global_rules/consumer_groups/ssls — mọi resource
dùng `id` làm định danh) và `username:` trùng (dành riêng cho `consumers`,
vì consumer định danh bằng `username` chứ không phải `id`). **Chỉ log
WARN, không exit 1** — merge vẫn hoàn tất, output vẫn được ghi. Nghĩa là
**duplicate ID không tự động bị chặn ở tầng GitOps** — nếu APISIX runtime tự
xử lý được duplicate (VD lấy bản cuối cùng), lỗi này có thể trôi qua âm thầm
cho tới khi ai đó đọc kỹ log `merge-fragments` hoặc gặp hành vi lạ (route
không như mong đợi vì bị 1 định nghĩa khác cùng `id` ghi đè).

### scripts/runtime/merge-fragments.sh:271-284 — Atomic replace + copy sang `samples/runtime/`

`cp "${TMP_OUTPUT}" "${OUTPUT}"` thay vì `mv` — cùng lý do giữ inode đã note
ở `inject-certs.sh` (bind-mount Docker). Đồng thời copy thêm 1 bản ra
`samples/runtime/apisix-${DC_PROFILE}.yaml` nếu thư mục đó tồn tại — mục
đích cho **admin xem trên host** mà không cần `docker exec` vào container.

---

## docker-compose.yaml:1-217 — Toàn file (5 service: `gitsync`, `redis`, `redis-exporter`, `prometheus`, `apisix-standalone`, `dashboard`)

### docker-compose.yaml:135-179 — Service `apisix-standalone`

**Volume mount 5 file patch** (dòng 152-156) — khớp chính xác 5 file sinh ra
bởi `1-patch-template-lua.sh` (`ngx_tpl.lua`, `init.lua`, `vault.lua`,
`config_yaml.lua`, `kafka-logger.lua`), tất cả `:ro` — container **đọc**
file đã patch trên host, không tự sửa. Đổi patch → phải chạy lại script
patch **rồi** `docker compose up -d --force-recreate apisix-standalone`
(đã note ở `1-patch-template-lua.sh`) — mount `:ro` không hot-reload như
route YAML, cần recreate container để container đọc lại file mount.

**`depends_on: gitsync: condition: service_healthy`** (dòng 138-140) —
`apisix-standalone` **chờ** `gitsync` healthy (tức đã có file
`apisix-${DC_PROFILE}.yaml` — xem healthcheck dòng 55-56 của service
`gitsync`) trước khi khởi động, tránh APISIX start với file route rỗng/chưa
tồn tại ở lần deploy đầu tiên.

**`network_mode: host`** cho hầu hết service (trừ `dashboard` cũng host) —
không khai `ports:` — mọi port APISIX listen (`config-hcm.yaml`
`apisix.ssl.listen`: 443/8443/16443/19443, cộng port 80 `node_listen`, cộng
9091 Prometheus export) tự động accessible trên host, không cần map port
thủ công. Đánh đổi: **không cô lập network** giữa các container — mọi
service trong file này (kể cả `redis`) đều thấy nhau qua `127.0.0.1`.

### docker-compose.yaml:5-64 — Service `gitsync`

`GITSYNC_PERIOD: "30s"` — khớp con số "≤30s" đã nhắc tới rất nhiều lần
xuyên suốt các note trước (gitsync tự pull, APISIX hot-reload trong vài
giây tới sau đó). `GITSYNC_EXECHOOK_COMMAND` trỏ đúng `gitsync.sh` đã note ở
trên — đây là dây chuyền đầy đủ: `git-sync` pull → gọi `gitsync.sh` →
`merge-fragments.sh` → `inject-certs.sh` → APISIX tự detect file đổi
(`config_yaml.lua`, đã patch [4] để log rõ hơn) → hot-reload.

`GITSYNC_MAX_FAILURES: "3"` — cho phép tối đa 3 lần pull lỗi liên tiếp
trước khi `git-sync` tự coi là failure nghiêm trọng (hành vi cụ thể khi vượt
ngưỡng phụ thuộc image `git-sync` gốc, không nằm trong phạm vi file này).

### docker-compose.yaml:112-134 — Service `prometheus`

`entrypoint` tự `sed` thay `${DC_PROFILE}` vào `prometheus.yaml` trước khi
khởi động Prometheus thật — cùng cơ chế substitute biến môi trường theo DC
đã thấy ở YAML APISIX (`${{DC_PROFILE}}`), nhưng ở đây làm thủ công bằng
`sed` vì Prometheus không có cơ chế resolve biến môi trường trong file
config như APISIX. `--storage.tsdb.retention.time=2h` — retention rất ngắn
(2 giờ) — Prometheus ở đây nhiều khả năng chỉ phục vụ **debug/lab ngắn hạn**
tại chỗ, không phải nơi lưu trữ metric dài hạn (nơi đó nên là hệ thống
Observability tập trung khác, ngoài phạm vi compose này).

---

## 🔧 Cập nhật cấu trúc thư mục — `apisix_routes/routes/` chuyển sang subfolder theo backend

```bash
cd apisix_routes/routes
mkdir -p hyperstore-cloudian ceph-rados
git mv hyperstore-cloudian-hcm/route-s3-hcm.sds.infiniband.vn-https-443.yaml hyperstore-cloudian/
git mv hyperstore-cloudian-hni/route-s3-hni.sds.infiniband.vn-https-443.yaml hyperstore-cloudian/
git mv hyperstore-cloudian-cmc/route-cmc.sds.infiniband.vn-https-8443.yaml hyperstore-cloudian/
git mv ceph-rados-hcm/route-s3-rgwhcm.sds.infiniband.vn-https-443.yaml ceph-rados/
git mv ceph-rados-hni/route-s3-rgwhni.sds.infiniband.vn-https-443.yaml ceph-rados/
rmdir hyperstore-cloudian-hcm hyperstore-cloudian-hni hyperstore-cloudian-cmc ceph-rados-hcm ceph-rados-hni
```

**Đường dẫn note cũ cần đọc lại theo path mới:**

| File | Path cũ (note trước đó) | Path mới |
|---|---|---|
| `route-s3-hcm.sds.infiniband.vn-https-443.yaml` | `apisix_routes/routes/route-s3-hcm...yaml` | `apisix_routes/routes/hyperstore-cloudian/route-s3-hcm...yaml` |
| `route-s3-hni.sds.infiniband.vn-https-443.yaml` | `apisix_routes/routes/route-s3-hni...yaml` | `apisix_routes/routes/hyperstore-cloudian/route-s3-hni...yaml` |
| `route-cmc.sds.infiniband.vn-https-8443.yaml` | `apisix_routes/routes/route-cmc...yaml` | `apisix_routes/routes/hyperstore-cloudian/route-cmc...yaml` |

Toàn bộ nội dung note trước đó (dòng cụ thể trong từng file) **vẫn đúng nguyên vẹn** — chỉ đường dẫn thư mục cha thay đổi, không phải nội dung file. 5 route còn lại đã note trước đó (`route-s3-admin`, `route-hyperiq`, `route-iam`, `route-sqs`, `route-sts`, `route-s3.hcm.lab.thuyldx`, `route-debug-dump-normalized`, `route-s3-hcm.infiniband.vn` legacy) **không nằm trong đợt di chuyển này** — vẫn ở thẳng `apisix_routes/routes/*.yaml` (depth 1), không có subfolder.

**🆕 2 route mới xuất hiện lần đầu qua lệnh `git mv` — chưa có nội dung để note chi tiết:**
`route-s3-rgwhcm.sds.infiniband.vn-https-443.yaml` và
`route-s3-rgwhni.sds.infiniband.vn-https-443.yaml`, đặt trong
`apisix_routes/routes/ceph-rados/`. Đây là backend **Ceph RGW** (Rados
Gateway) — trước đó chỉ được nhắc gián tiếp trong note `ssls/
ssl-sds.infiniband.vn.yaml` ("VÀ apex của:... s3-rgwhcm(-admin),
s3-rgwhni(-admin)") mà chưa có route/upstream cụ thể nào được xem — nay xác
nhận đây là backend S3 **thứ hai** trong hệ thống, song song với Cloudian
HyperStore (`hyperstore-cloudian/`), không phải cùng 1 loại. **Cần gửi nội
dung 2 file này (+ upstream/service tương ứng nếu có) để note đầy đủ** — hiện
tại chỉ biết tên file và vị trí, chưa biết cấu hình thật.

**Cách đặt tên subfolder khớp đúng `profile-map.yaml`:** subfolder mới
`hyperstore-cloudian/` và `ceph-rados/` là tên **gộp nhóm theo backend**,
khác hẳn key trong `profile-map.yaml` hiện tại (`hyperstore-cloudian-hcm`,
`hyperstore-cloudian-hni`, `hyperstore-cloudian-cmc` — vốn khớp theo route
`name:` field, không phải tên thư mục — xem lại note `profile-map.yaml`: map
lọc theo `name:` của route, **không** theo thư mục chứa nó, nên việc gộp
subfolder này **không** ảnh hưởng logic phân DC, chỉ là tổ chức file vật lý
gọn hơn).

---

## 🔧 Cập nhật `scripts/runtime/gitsync.sh` (151→174 dòng) và `scripts/runtime/merge-fragments.sh` (302→329 dòng)

Cả 2 file có bản mới, sửa đúng 2 điểm tôi đã flag trong note trước — cập
nhật lại, không phải nội dung hoàn toàn mới.

### ✅ Đã fix: `gitsync.sh` giờ check đủ 4 thư mục core, khớp đúng `merge-fragments.sh`

```bash
if [ -d "${ROUTES_SRC}/upstreams" ] && \
   [ -d "${ROUTES_SRC}/routes" ]    && \
   [ -d "${ROUTES_SRC}/services" ] && \
   [ -d "${ROUTES_SRC}/ssls" ]; then
```

Đã thêm `services/` vào điều kiện (trước đây chỉ check 3: `upstreams`/
`routes`/`ssls`) — khớp chính xác với `for d in upstreams routes services
ssls` ở `merge-fragments.sh`. Comment mới còn tự ghi chú rõ **lý do** phải
khớp 2 bên (đúng nội dung phát hiện đã note trước đó): *"Sửa 1 bên mà quên
bên kia sẽ tái diễn đúng lỗi: gitsync tưởng layout hợp lệ, gọi
merge-fragments.sh, script hard-error vì thiếu core dir mà gitsync không
biết để báo trước"*.

### ✅ Đã fix: log lỗi merge cụ thể hơn thay vì chung chung

```bash
MERGE_LOG_START=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
if ! run_logged "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${OUTPUT}"; then
  MERGE_ERRORS=$(tail -n +"$((MERGE_LOG_START + 1))" "${LOG_FILE}" | grep '\[merge-fragments\] ERROR' || true)
  log_err "ERROR: merge-fragments.sh thất bại — output không thay đổi"
  printf '%s\n' "${MERGE_ERRORS}" | while IFS= read -r eline; do
    log_err "  → nguyên nhân: ${eline}"
  done
```

Đánh dấu vị trí log **trước khi** gọi `merge-fragments.sh`, sau đó chỉ trích
đúng phần log **sinh ra bởi lần chạy này** (không lẫn log lần chạy trước) —
in thẳng dòng `[merge-fragments] ERROR: ...` gốc ra `gitsync.log` kèm nhãn
"→ nguyên nhân:", thay vì chỉ nói chung chung "thất bại" rồi phải tự mở log
dò ngược. Đúng theo hướng khắc phục đã đề xuất ở note trước.

### 🆕 Mới — `plugin_metadata/` giờ là thư mục có kiểm tra riêng (cả 2 script)

**`merge-fragments.sh`:** `VALID_KEYS` thêm `plugin_metadata` (đặt đầu danh
sách, cùng `global_rules`); có thêm `validate_block_dir "plugin_metadata"
"1"`; và đặc biệt — **allowlist tên plugin hợp lệ**:

```bash
KNOWN_PLUGIN_METADATA_IDS="http-logger kafka-logger tcp-logger udp-logger clickhouse-logger elasticsearch-logger loki-logger loggly splunk-hec-logging rocketmq-logger sls-logger skywalking-logger google-cloud-logging datadog opentelemetry"
```

Với mỗi file trong `plugin_metadata/`, script đọc `id:` và so với danh sách
trên — không khớp → `WARN`: *"kiểm tra lại đúng tên plugin thật chưa..., nếu
không plugin sẽ KHÔNG đọc được metadata này (silent no-op)"*. Đây là validate
**rất đáng giá**: `plugin_metadata.id` phải khớp **chính xác tên plugin
thật** (VD `kafka-logger`, không phải `kafka_logger` hay tên gợi nhớ khác) —
gõ sai 1 ký tự sẽ khiến cả block `log_format` bị APISIX âm thầm bỏ qua,
không có lỗi nào hiện ra, chỉ đơn giản là log vẫn theo format mặc định. Đã
note field này ở `plugin_metadata/log-format-kafka-logger.yaml:1`
(`id: kafka-logger`) — giờ có thêm 1 lớp bảo vệ tự động ở tầng merge, không
chỉ dựa vào review thủ công.

**Thứ tự `append_block` cũng đổi** — `global_rules` và `plugin_metadata`
chuyển lên **đầu** (trước đây `global_rules` ở gần cuối, `plugin_metadata`
chưa tồn tại):

```
global_rules → plugin_metadata → upstreams → services → plugin_configs → routes → consumer_groups → consumers → ssls
```

**`gitsync.sh` — log INFO plugin_metadata đang active, đọc đúng theo thứ tự
mới:**

```bash
if grep -q "^plugin_metadata:" "${OUTPUT}" 2>/dev/null; then
  PM_IDS=$(sed -n '/^plugin_metadata:/,/^upstreams:/p' "${OUTPUT}" | grep -E '^\s+-\s+id:' | ...)
  log "INFO: plugin_metadata đang active cho plugin: ${PM_IDS:-?} — áp dụng GLOBAL cho mọi route/service dùng plugin đó, không phải chỉ route gắn global_rules."
```

**⚠ Điểm dễ vỡ đã được chính comment trong file cảnh báo trước:** range
`sed -n '/^plugin_metadata:/,/^upstreams:/p'` chỉ đúng vì thứ tự output HIỆN
TẠI là `... → plugin_metadata → upstreams → ...` (liền kề nhau). Nếu sau này
đổi thứ tự `append_block` trong `merge-fragments.sh` mà **quên sửa** pattern
range này trong `gitsync.sh`, dòng log INFO sẽ trích sai/rỗng — comment gốc
đã tự ghi chú rõ rủi ro này, nhưng vẫn là 1 điểm cần nhớ nếu sau này refactor
tiếp thứ tự merge.

---

## 🔧 Cập nhật `plugins/custom/s3-normalizer-bucket-name.lua` (139→328 dòng, version 2.1→2.2) — bổ sung quan trọng, đính chính thêm 1 lần nữa

Bản trước tôi note plugin này "không còn rewrite, chỉ extract+validate" —
**vẫn đúng**, nhưng bản đầy đủ lần này cho biết thêm 2 việc quan trọng:

### 🔴 RC-8 — lý do THẬT SỰ vì sao rewrite bị tắt (không chỉ là "chưa dùng")

```lua
-- Export bucket name cho plugin downstream (vd: s3-bucket-name-consumer).
-- KHÔNG rewrite URI/Host — Cloudian tự hỗ trợ vhost-style native, giữ
-- nguyên hành vi pass-through hiện tại (xem RC-8 trong runbook: rewrite
-- Host/URI ở đây từng phá SigV4 signature validation của client).
```

Khác với suy đoán trước đó ("có thể là dự định ban đầu, chưa chắc là bug") —
nay có bằng chứng cụ thể: đã từng **thật sự bật** đoạn rewrite (đổi URI +
Host header trước khi forward), và điều đó **phá vỡ SigV4 signature
validation phía client** — đúng theo cơ chế SigV4: client ký (sign) request
dựa trên Host/URI **client tự gửi** (vhost-style); nếu gateway rewrite lại
Host/URI thành path-style trước khi tới Cloudian, backend sẽ tính lại chữ ký
trên giá trị đã bị đổi, không khớp với chữ ký client đã tính trên giá trị
gốc → `SignatureDoesNotMatch`. Vì Cloudian **tự hỗ trợ vhost-style native**
(không cần path-style), rewrite là **không cần thiết** lẫn **có hại** — giữ
nguyên comment, không xoá code rewrite (để tham khảo), nhưng tắt vĩnh viễn.

### 🆕 v2.2 — Export bucket name qua request header, KHÔNG dùng `kafka-logger` `log_format`

Bổ sung field `set_header` (default `"X-S3-Bucket-Name"`) vào schema, set ở
**cả 2 case** (vhost + path) — đây là cơ chế đã note trước ở
`plugin_metadata/log-format-kafka-logger.yaml` nhưng giờ mới thấy rõ **vì
sao chọn cách này**:

**Lý do KHÔNG dùng `core.ctx.register_var` + thêm field vào
`kafka-logger.log_format`:** `log_format` của `kafka-logger` (khai ở
`plugin_metadata/`) là **THAY THẾ TOÀN BỘ** cấu trúc log mặc định, không
**merge** thêm field — khai `log_format` nghĩa là phải tự liệt kê lại **mọi**
field cần thiết bằng nginx variable (`$...`), mà `headers`/`querystring` là
kiểu **dict**, không có `$var` tương đương để liệt kê lại toàn bộ. Đây là
**giới hạn cố định của `kafka-logger`**, đã kiểm tra không đổi giữa APISIX
3.15 và bản mới hơn — không phải bug riêng version nào.

**Giải pháp:** set request **header** thay vì biến nội bộ — log mặc định
(`get_full_log()` trong `log-util.lua` của APISIX) **tự động** log toàn bộ
`ngx.req.get_headers()`, nên header mới **tự lộ diện** trong
`request.headers` của log, không cần sửa gì ở `kafka-logger`/`plugin_metadata`.
An toàn với SigV4 — cùng lý do `X-S3-Access-Key` an toàn (không nằm trong
`SignedHeaders`).

**Query Loki sau khi có field này (LogQL, đã ghi trong file):**
```logql
sum by (request_headers_x_s3_bucket_name) (rate({...} | json [1m]))
```
Loki tự flatten dấu `-` trong tên field JSON thành `_` khi auto-extract qua
`| json`.

### 🆕 Làm rõ khái niệm `priority` — 3 namespace độc lập, đừng suy luận chéo

```lua
-- ⚠ Đây là plugin EXECUTION priority trong 1 phase (rewrite) — KHÔNG liên
--   quan gì đến route-level "priority" field (dùng cho thứ tự match route,
--   vd route-debug-dump priority:100) hay port của upstream node
--   (vd 127.0.0.1:9999 trong route debug-dump). 3 khái niệm trùng từ khóa
--   "priority"/số nhưng là 3 namespace độc lập — đừng suy luận chéo.
```

Comment mới tự làm rõ điều dễ nhầm: `priority: 10005` của plugin (thứ tự
chạy trong 1 phase) ≠ `priority: 100` của `route-debug-dump` (thứ tự APISIX
thử match route nào trước khi nhiều route cùng khớp URI) ≠ số port
`127.0.0.1:9999` (không liên quan priority gì cả, chỉ trùng là số). Hữu ích
để không nhầm khi đọc nhanh nhiều file cùng lúc.

---

## 🔧 5 file Lua còn lại (`cmc-validator-bucket-name.lua`, `s3-accesskey-extractor.lua`, `s3-bucket-name-consumer.lua`, `s3-akid-utils.lua`, `s3-validator-bucket-name-utils.lua`) — khôi phục lại comment vận hành, không đổi logic

Cả 5 file lần gửi này đều **khôi phục lại phần lớn comment gốc** (docstring
đầu file, giải thích field schema, hướng dẫn vận hành) so với bản "sạch"
(không comment) đã note trước đó — **không có thay đổi logic/hành vi nào**,
chỉ khác độ dài do comment. Toàn bộ tham chiếu `file:line` ở các mục phía
trên **đã được tính lại chính xác theo bản mới này** (không phải bản "sạch"
cũ nữa) — nội dung giải thích giữ nguyên như đã note trước đó, chỉ số dòng
được cập nhật khớp đúng file hiện tại.

**Riêng `s3-bucket-name-consumer.lua`:** khối debug-history dài (giải thích
chi tiết bug `find_consumer`/`attach_consumer`) đã được **rút gọn thành
comment ngắn 1 dòng** tại đúng chỗ code (`-- Tự loop tìm theo .username —
KHÔNG dùng consumer_mod.find_consumer()`) thay vì giữ nguyên cả đoạn dài như
bản `-cũ.lua` gốc — đúng tinh thần đã note trước: giữ đủ để hiểu **quyết
định**, chuyển phần **lịch sử điều tra chi tiết** sang note kỹ thuật này
(đã có sẵn, không mất thông tin).
---

## 🔧 Upgrade APISIX 3.15.0 → 3.17.0 (qua 3.16.0) — 3 lỗi crash-loop đã xử lý

**Bối cảnh:** upgrade image `apache/apisix:3.15.0-debian` → `3.17.0-debian`
cho cả 2 node (`hcm`, `han`). 5 file core-patch trong
`1-patch-template-lua.sh` (`ngx_tpl.lua`, `init.lua`, `vault.lua`,
`config_yaml.lua`, `kafka-logger.lua`) đã đối chiếu diff thật giữa source
3.15.0/3.16.0/3.17.0 — cả 5 anchor patch vẫn khớp, không cần sửa. 4 custom
plugin Lua cũng không cần sửa (API `apisix.consumer`/`core.request` không
đổi). Toàn bộ lỗi phát sinh nằm ở **hành vi mới của core APISIX** và
**tương thích native dependency của image chuẩn**, không phải ở code/patch
của mình.

### Lỗi 1 — `can't find environment variable VAR` (container không start được)

**Nguyên nhân:** APISIX 3.17.0 đổi cách đọc `apisix-${DC_PROFILE}.yaml`
(standalone data-plane config) — `apisix/core/config_yaml.lua` gọi
`file.resolve_conf_var_in_text(raw_config)` (bản chất là hàm
`var_sub()` trong `apisix/cli/file.lua`, dùng `gsub` pattern
`%$%{%{%s*([%w_]+[%:%=]?.-)%s*%}%}`) chạy **trên toàn bộ raw text** —
**TRƯỚC KHI** `yaml.load()` chạy. Ở 3.15.0/3.16.0, thứ tự ngược lại: parse
YAML trước (comment bị strip) → mới resolve biến trên table đã parse, nên
comment luôn an toàn. Từ 3.17.0, vì còn là raw text, **comment cũng bị quét
chung với giá trị thật**.

Root cause cụ thể: dòng comment trong
`apisix_routes/global_rules/global-kafka-logger.yaml` dùng literal
`"${{VAR}}"` để minh hoạ cơ chế (không phải biến thật) → CLI init tìm biến
môi trường tên `VAR`, không có → lỗi ngay ở bước `apisix.lua init`, trước
khi nginx kịp start.

**Fix:** xoá literal `${{VAR}}` khỏi comment, viết tách thành "cú pháp
dollar-double-brace" bằng chữ. Đã rà soát toàn bộ `apisix_routes/` — không
còn chỗ nào khác dùng `${{...}}` mà không phải biến thật đã set trong
`.env` (`DC_PROFILE`, `KAFKA_SASL_USER`, `KAFKA_SASL_PASSWORD`,
`VAULT_ADDR`, `VAULT_TOKEN`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`).

**Nguyên tắc mới cho mọi file trong `apisix_routes/`:** không viết literal
`${{TÊN_GÌ_ĐÓ}}` trong comment, kể cả để minh hoạ, trừ khi `TÊN_GÌ_ĐÓ` là
biến thật đã set trong `.env`.

**Bẫy vận hành liên quan (không phải bug APISIX):** sau khi sửa source
fragment, phải đợi **gitsync container tự pull + merge lại** (chu kỳ 30s,
hoặc trigger tay bằng `docker exec gitsync <path>/gitsync.sh`) rồi mới
`docker compose up -d --force-recreate apisix-standalone`. Sửa fragment
nguồn xong mà recreate container ngay lập tức vẫn ăn phải file merged cũ —
vì `git pull` ở thư mục operator (`/opt/apisix/standalone/sandbox`) và clone
riêng của container `gitsync` (`GITSYNC_ROOT`) là **2 checkout độc lập**,
không tự đồng bộ với nhau.

### Lỗi 2 — `invalid number of arguments in "lua_shared_dict" directive` (nginx.conf render sai)

**Nguyên nhân:** so sánh trực tiếp 2 bản `nginx.conf` thật (3.15.0 vs
3.17.0) — `lua_shared_dict upstream-healthcheck` đều nằm cùng vị trí trong
khối `http {}` ở cả 2 bản (không đổi kiến trúc/vị trí field như từng nghi
ngờ ban đầu). Khác biệt duy nhất: 3.15.0 render ra `10m` (default), 3.17.0
render ra **rỗng** — default value cho riêng key này không được áp dụng dù
vẫn tồn tại trong `apisix/cli/config.lua` (`meta.lua_shared_dict["upstream-
healthcheck"] = "10m"`) — nghi vấn regression thật của APISIX 3.17.0 ở tầng
merge default config cho standalone deployment role, chưa xác định được
chính xác đoạn code gây mất giá trị.

**Fix:** set tường minh, không phụ thuộc default:
```yaml
nginx_config:
  http:
    lua_shared_dict:
      upstream-healthcheck: "10m"
      internal-status: "10m"
      plugin-limit-req: "10m"
      plugin-limit-count: "10m"
      prometheus-metrics: "15m"
```

**Đính chính field name:** field đúng để override size dict built-in là
`nginx_config.http.lua_shared_dict` (số ít, KHÔNG có "custom"). Field cũ
từng dùng (`lua_shared_dicts` — số nhiều) là tên sai/deprecated từ bản
3.0.0, chưa từng có tác dụng dù ở 3.15.0. `custom_lua_shared_dict` (khác
field, dễ nhầm) chỉ dùng để khai dict MỚI tự đặt tên, không override được
size dict built-in.

### Lỗi 3 — Plugin `gm` sập toàn bộ `init_worker`, `saml-auth` chỉ tự nó fail

**`gm`:** cần thư viện Tongsuo (OpenSSL biến thể SM2/SM3/SM4, chuẩn mật mã
Trung Quốc) — không có sẵn trong image chuẩn `apache/apisix:3.17.0-debian`.
`gm.lua:138` gọi `error()` thẳng trong `init()`, **không bọc `pcall`** → lỗi
lan lên tận `init_worker_by_lua`, khiến toàn bộ phần code còn lại của
`init_worker()` không chạy được — kể cả phần không liên quan gì đến `gm`:
`plugin_metadatas` không init được (`plugin.lua:925`), `router_ssl` không
init được (`init.lua:211` → **mọi TLS handshake trên port 443 fail 100%**),
Prometheus exporter cũng không init được (`exporter.lua:685`). Đây là
outage thật, không phải lỗi thẩm mỹ.

**`saml-auth`:** cần `libxml2.so.2` — cũng không có sẵn trong image chuẩn.
Nhưng `plugin.lua:210 load_plugin()` có bọc `pcall` quanh bước `require()`
module `.so` → chỉ riêng `saml-auth` không dùng được, phần còn lại của
gateway (kể cả các worker khác cùng lúc) hoàn toàn không bị ảnh hưởng.

**Nguyên tắc rút ra:** mức độ nguy hiểm của 1 plugin thiếu native dependency
**không đoán được chỉ nhìn tên** — phụ thuộc plugin đó có tự bọc `pcall`
quanh code khởi tạo hay không (đặc thù implementation riêng từng plugin).
Cách duy nhất biết chắc: **test riêng từng plugin lạ trên sandbox trước khi
đưa production** — bật 1 plugin, restart, xem log sạch không, rồi mới thêm
plugin tiếp theo, không thêm nguyên khối nhiều chục plugin mới cùng lúc.

**Fix:** comment out cả 2 khỏi `plugins:` trong `config-hcm.yaml` và
`config-han.yaml`:
```yaml
  # - gm
  ...
  # - saml-auth
```

**Danh sách plugin cần native dependency ngoài — theo dõi khi bật:**

| Plugin | Phụ thuộc ngoài | Mức nguy hiểm đã xác nhận |
|---|---|---|
| `gm` | Tongsuo | **Crash toàn bộ `init_worker`** — không bọc `pcall`, sập SSL/metrics. KHÔNG bật lại trừ khi image có Tongsuo. |
| `saml-auth` | libxml2 | An toàn ở mức gateway — chỉ riêng plugin fail, có `pcall`. Vẫn nên tắt vì không dùng SAML. |
| `chaitin-waf`, `ocsp-stapling`, `dubbo-proxy` | Chưa xác định | Đã load được, chưa gặp lỗi trong log — nhưng CHƯA test route thật kích hoạt các plugin này. Theo dõi thêm trước khi tin tưởng hoàn toàn. |

### Lỗi KHÔNG cần fix — cảnh báo vô hại, đã verify bằng chính runtime code

`healthcheck.lua:1385: array headers is deprecated` (xuất hiện cho các
upstream dùng `checks.active.req_headers`) — đã đối chiếu `schema_def.lua`
(APISIX, `req_headers` vẫn `type: array`, không đổi giữa 3.15.0/3.17.0) và
đọc trực tiếp file `resty/healthcheck.lua` thật trong container: nhánh
`is_array(req_headers)` chỉ log `WARN` rồi vẫn `table.concat()` build header
string bình thường, không có nhánh nào return sớm hay raise error, và có
cache `_headers_str` nên chỉ log 1 lần/checker. Không có cú pháp thay thế
nào được APISIX schema chấp nhận — giữ nguyên `req_headers` dạng mảng ở tất
cả file `upstream-*.yaml`, không sửa gì.
---

## 🔧 Debug `scripts/debug/verify-apisix.sh` sau upgrade 3.17.0 — 2 sự cố độc lập, đừng gộp chung

### Sự cố 1 — SNI `cmc.sds.infiniband.vn`/`s3-admin.sds.infiniband.vn` báo `failed to match any SSL certificate by SNI`

**Triệu chứng:** toàn bộ route non-S3 trả `HTTP=000`, `openssl s_client --servername` cho 2 host này báo `TLS alert internal error (80)`, `no peer certificate available`. Trong khi đó `sqs`/`sts` — **cùng ăn theo 1 wildcard cert `*.sds.infiniband.vn`** — vẫn hoạt động bình thường ở cùng thời điểm.

**Loại trừ từng nghi vấn theo thứ tự đã điều tra:**
1. Không phải lỗi network/firewall — TCP connect tới port 443 luôn thành công (`ss -tlnp` xác nhận openresty bind đúng cả 80/443), lỗi xảy ra ngay ở tầng TLS Lua handshake.
2. Không phải crash kiểu `gm` (xem section upgrade 3.17.0 ở trên) — `error.log` **không có** `init_worker error` hay `attempt to index field 'router_ssl'`, plugin load sạch 100%.
3. Không phải lỗi cấu hình `ssls` entity — `cmc`/`s3-admin` **không có entity SSL riêng** (`grep -rln "cmc\|s3-admin" apisix_routes/ssls/*.yaml` → rỗng), cả 2 dùng chung entity wildcard `ssl-sds.infiniband.vn.yaml` y hệt `sqs`/`sts` (không lỗi). Nếu bug nằm ở entity/cert, cả 4 host phải lỗi như nhau — nhưng chỉ 2/4 lỗi.
4. Không có `failed to check item data of [ssls]` (lỗi schema validate quen thuộc từ đợt upgrade) tái phát trong log.

**Fix đã xác nhận hiệu quả:** `docker compose up -d --force-recreate apisix-standalone` — không sửa bất kỳ file YAML/cert nào, lỗi biến mất hoàn toàn (verify lại bằng `openssl s_client`, cả 2 host trả đúng `subject=CN = *.sds.infiniband.vn`, `Verify return code: 0`).

**Giả thuyết nguyên nhân (chưa xác nhận ở mức source code, chỉ suy luận từ log/hành vi):** bảng tra SNI→cert (`router_ssl`) được từng **worker process** tự hot-reload độc lập theo timer riêng, không đồng bộ giữa các worker. Nếu 1 chu kỳ hot-reload cập nhật không đầy đủ cho vài SNI cụ thể ở một số worker (race giữa lúc gitsync ghi đè file và lúc worker đọc), triệu chứng khớp chính xác: 1 số SNI lỗi trong khi SNI khác cùng cert vẫn OK, không log lỗi rõ ràng ở thời điểm xảy ra, chỉ hết khi restart toàn bộ worker (`force-recreate` = router_ssl được xây lại từ đầu, đồng bộ 100%).

**Vận hành:** nếu gặp lại `failed to match any SSL certificate by SNI` cho 1 SNI cụ thể **trong khi SNI khác cùng chung cert vẫn hoạt động** (dấu hiệu phân biệt: không phải lỗi cert thật, không phải lỗi cấu hình — 2 tín hiệu trên đã loại trừ) → mitigation: `docker compose up -d --force-recreate apisix-standalone`, không cần sửa YAML. Nếu tái diễn thường xuyên, cân nhắc báo upstream APISIX (nghi vấn edge case hot-reload SSL entity theo từng worker độc lập ở standalone mode).

**Lưu ý phụ:** IP client lạ (`10.158.40.25`, `10.158.23.25`) gọi sai SNI trong log — xác nhận là traffic test/scan từ phía dev nội bộ, không phải sự cố hệ thống, bỏ qua khi debug.

### Sự cố 2 — kcat trong `verify-apisix.sh` báo `SSL handshake failed: certificate verify failed`

**Không phải lỗi CA bundle** — dễ hiểu nhầm nhất trong lần debug này. Test sai: so `fingerprint` của `certs/ca-certificates.crt` (chỉ đọc **cert đầu tiên** trong bundle nhiều CA nối tiếp) với leaf cert thật của broker — 2 cert khác nhau về bản chất theo thiết kế PKI (1 bên là CA ký cấp, 1 bên là cert server được ký), diff luôn lệch bất kể bundle đúng hay sai. **Không dùng cách so fingerprint kiểu này để verify CA bundle nữa.**

**Root cause thật:** `librdkafka` (nền của `kcat`) mặc định bật **endpoint identification** (so khớp hostname/IP dùng để connect với SAN trong cert broker). Test/script dùng **IP NodePort** (`172.26.24.80:31421`) để connect, trong khi cert Strimzi cấp cho broker chỉ liệt SAN dạng DNS nội bộ Kubernetes, không có IP → chain CA đúng (đã verify bằng `openssl s_client -CAfile` pass từ đầu) nhưng hostname/IP không khớp SAN → `librdkafka` reject ở bước cuối handshake. `openssl s_client` mặc định không kiểm tra hostname nên không phát hiện được vấn đề này — đây là lý do 3 check TLS trước đó trong script đều `[OK]` mà kcat vẫn fail.

**Fix — thêm `ssl.endpoint.identification.algorithm=none`** vào lệnh kcat trong `scripts/debug/verify-apisix.sh` (giữ nguyên `ssl.ca.location` để vẫn verify chain CA, chỉ tắt riêng phần so khớp hostname/SAN):

```bash
# ssl.endpoint.identification.algorithm=none: broker cert SAN của Strimzi chỉ cover
# DNS nội bộ K8s, KHÔNG cover IP NodePort ($KAFKA_BROKER dùng IP để test từ ngoài
# cluster) — tắt hostname verify, vẫn giữ chain-CA verify qua ssl.ca.location.
# Đã verify thực nghiệm: broker thật hoạt động đúng SCRAM-SHA-512, không phải lỗi
# credential/mechanism — chỉ là đặc thù connect qua IP thay vì DNS.
KCAT_OUT=$(timeout 10 kcat -b "$KAFKA_BROKER" -X security.protocol=SASL_SSL \
  -X sasl.mechanisms="$KAFKA_SASL_MECHANISM" -X sasl.username="$KAFKA_SASL_USERNAME" \
  -X sasl.password="$KAFKA_SASL_PASSWORD" -X ssl.ca.location="$KAFKA_CA_CERT" \
  -X ssl.endpoint.identification.algorithm=none \
  -C -t "$KAFKA_TOPIC" -o -5 -e 2>&1)
```

**Đính chính 1 nhầm lẫn trong lúc debug:** ban đầu nghi ngờ `sasl.mechanisms` trong script bị sai/thiếu (gây lỗi `Unsupported SASL mechanism`) — **sai**, script đã default đúng `KAFKA_SASL_MECHANISM="${KAFKA_SASL_MECHANISM:-SCRAM-SHA-512}"` từ đầu và dùng biến (không hardcode PLAIN). Lỗi mechanism đó chỉ xảy ra ở lệnh kcat gõ tay để cô lập test (thiếu cờ `-X sasl.mechanism=`, rơi về default PLAIN của chính `kcat`), không tồn tại trong script thật. **Pipeline log thật của APISIX → Kafka (`global-kafka-logger.yaml`) chưa bao giờ bị lỗi này** — mechanism đã đúng `SCRAM-SHA-512` ở cả 3 chỗ config từ trước.

**Kết luận chung:** cả 2 sự cố đều **không phải lỗi cấu hình hệ thống**, chỉ là (1) 1 edge-case hot-reload cần restart để tự phục hồi, và (2) thiếu 1 cờ verify trong chính script test. Pipeline production (route SSL thật, log Kafka thật) hoạt động đúng trong suốt quá trình — không có tác động thật tới traffic hay log ngoài lúc đang điều tra.
---

## 🔧 `scripts/debug/verify-apisix.sh` — mục "Worker restart lag" báo FAIL sai (false negative), đã fix

### Root cause 1 — hardcode số dòng source code, dễ vỡ theo version APISIX

Script gốc detect worker restart bằng cách grep đúng chuỗi
`"plugin.lua:223: load(): new plugins"` trong `logs/apisix/error.log` —
**số dòng `:223` bị hardcode theo bản 3.15.0**. Đối chiếu log thật thu thập
được từ 3.17.0 (phiên debug plugin `gm`/`saml-auth`):

```
[warn] 55#55: *1 [lua] plugin.lua:288: load(): new plugins: {...}
```

Dòng thật là `plugin.lua:288`, không phải `:223` — số dòng source code
`apisix/plugin.lua` dịch chuyển giữa các minor version (refactor nội bộ,
không phải breaking change chính thức nào được công bố). Kết quả: pattern
cũ **không bao giờ match** trên 3.17.0, `RESTART_COUNT` luôn = 0 dù worker
thực tế đã chạy bình thường từ lúc container start — **false negative**, dễ
gây hoang mang tưởng nhầm là APISIX chưa từng init xong.

**Fix — match độc lập số dòng:**
```bash
grep -oE "plugin\.lua:[0-9]+: load\(\): new plugins" logs/apisix/error.log
```
`[0-9]+` thay cho số cố định — sống sót qua các lần upgrade sau, không cần
sửa lại tay mỗi lần đổi minor version. **Bài học chung áp dụng cho toàn bộ
`verify-apisix.sh`:** bất kỳ chỗ nào match log theo số dòng source code cụ
thể (`file.lua:NNN`) đều là điểm dễ vỡ ngầm khi upgrade APISIX — nên ưu tiên
match theo nội dung message + regex số dòng thay vì hardcode.

### Root cause 2 — cách tiếp cận qua log lịch sử tự nó không đáng tin khi log bị rotate

Dù đã sửa pattern đúng, `RESTART_COUNT` vẫn ra `0` ở lần chạy tiếp theo —
verify trực tiếp:
```bash
grep -c "load(): new plugins" logs/apisix/error.log   # → 0
wc -l logs/apisix/error.log                            # → 413 (rất ngắn so với 18h uptime)
docker logs apisix-standalone --since 24h 2>&1 | grep -c "load(): new plugins"   # → 0
```
Cả 2 nguồn log (`error.log` file bind-mount lẫn `docker logs` — stdout/
stderr) đều **không còn giữ** dòng log ghi tại thời điểm container start
(cách đó 18 tiếng) — log đã bị rotate/truncate (Docker json-file log driver
có giới hạn size mặc định; `error.log` cũng vậy tuỳ cấu hình logrotate).
**Kết luận quan trọng: cách tiếp cận "grep log lịch sử để suy ra sự kiện
quá khứ" tự nó không đáng tin cậy** cho các sự kiện xảy ra đã lâu, bất kể
pattern đúng hay sai — cần đổi hẳn nguồn dữ liệu, không chỉ sửa pattern.

**Fix — đọc trực tiếp process state qua `/proc`, không phụ thuộc log:**

```bash
WORKER_AGE=$(docker exec apisix-standalone sh -c '
  UPTIME=$(cut -d" " -f1 /proc/uptime 2>/dev/null)
  CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
  OLDEST_AGE=""
  for pid_dir in /proc/[0-9]*; do
    [ -r "${pid_dir}/cmdline" ] || continue
    cmdline=$(tr "\0" " " < "${pid_dir}/cmdline" 2>/dev/null)
    case "${cmdline}" in
      *"worker process"*)
        stat_line=$(cat "${pid_dir}/stat" 2>/dev/null) || continue
        after_comm="${stat_line#*) }"
        set -- ${after_comm}
        starttime="${20}"
        [ -z "${starttime}" ] && continue
        age=$(( ${UPTIME%.*} - starttime / CLK_TCK ))
        if [ -z "${OLDEST_AGE}" ] || [ "${age}" -gt "${OLDEST_AGE}" ]; then
          OLDEST_AGE="${age}"
        fi
        ;;
    esac
  done
  echo "${OLDEST_AGE:-}"
' 2>/dev/null)
NEWPLUGIN_EPOCH=$(( $(date +%s) - WORKER_AGE ))
```

**Cơ chế:** `/proc/[pid]/stat` field 22 (`starttime`, đơn vị clock-tick kể từ
lúc hệ thống boot) kết hợp `/proc/uptime` (tổng thời gian hệ thống đã chạy)
→ tính ra tuổi thật (giây) của từng worker process tại đúng thời điểm chạy
lệnh — không đọc lại lịch sử, không thể "mất" như log. Lấy giá trị **lớn
nhất** trong các worker (worker sống lâu nhất = mốc lần restart gần nhất,
vì toàn bộ worker respawn đồng loạt cùng lúc khi nginx reload). Đã verify
thực nghiệm: `worker_age_seconds=64077` khớp gần như tuyệt đối với "Up 18
hours" của container tại cùng thời điểm.

**Phát hiện phụ — image `apache/apisix:3.17.0-debian` KHÔNG có `ps`:**
```
sh: 1: ps: not found
```
Thiếu gói `procps` dù build trên nền Debian — không dùng được `ps -eo
etimes,args` như cách tiếp cận thông thường trên host/VM khác, buộc phải tự
đọc `/proc` bằng shell thuần (`cat`/`cut`/`tr`/`getconf` — các binary cơ bản
gần như chắc chắn có sẵn). Lưu ý này áp dụng chung cho mọi lần cần debug
process bên trong container `apisix-standalone` sau này — đừng giả định
`ps`/`grep -P`/các tool "thường có" khác cũng có sẵn, kiểm tra trước.
---

## 🔧 `logs/apisix/access.log`/`error.log` tự động rotate theo giờ — root cause là plugin `log-rotate`, không phải bug

### Triệu chứng

Sau khi enable full 116+4 plugin (đợt "load sẵn toàn bộ plugin của image, cần
dùng plugin nào thì bật ở route" — xem section liệt kê plugin phía trên),
`logs/apisix/` xuất hiện hàng loạt file mới không có ở 3.15.0:
```
2026-07-31_09-00-00__access.log
2026-07-31_09-00-00__error.log
```
File `access.log`/`error.log` (không timestamp) vẫn tồn tại song song và
**luôn là bản đang ghi hiện tại** — cảm giác "log biến mất" khi tail thực ra
là bị rotate sang file mới mỗi giờ tròn, không phải APISIX ngừng ghi log.

### Root cause — plugin `log-rotate`, nằm trong 12 plugin "không bật mặc định"

Đối chiếu source thật `apisix/plugins/log-rotate.lua` (GitHub, nhánh
`master`, khớp 3.17.0):
```lua
local plugin_name = "log-rotate"
local INTERVAL = 60 * 60      -- rotate mỗi giờ — khớp đúng bằng chứng
local MAX_KEPT = 24 * 7       -- giữ 7 ngày (168 file) — khớp đúng
local MAX_SIZE = -1           -- KHÔNG giới hạn size mỗi file — RỦI RO
local _M = {
    ...
    scope = "global",         -- chỉ cần liệt kê trong plugins:, KHÔNG cần
                               -- gắn route/global_rule, tự chạy background
                               -- timer ngay khi worker init
}
```
Ở 3.15.0, `log-rotate` chưa từng nằm trong `plugins:` (chỉ 85 plugin gốc) →
không rotate. Sau khi bật full-plugin ở 3.17.0, `log-rotate` tự kích hoạt —
**đúng chức năng thiết kế**, không phải bug.

**Rủi ro thật đã phát hiện:** `MAX_SIZE=-1` mặc định → 1 file
`error.log` từng phình tới **410MB trong đúng 1 giờ** đúng lúc debug
crash-loop `gm`/`${{VAR}}` (`error_log_level: debug`, log dồn dập) — vì
log-rotate chỉ cắt theo mốc giờ, không cắt theo dung lượng.

### Đính chính quan trọng — `log-rotate` dùng `plugin_attr`, KHÔNG dùng `plugin_metadata`

Nhầm lẫn ban đầu: đề xuất set config qua `plugin_metadata` (giống cách
`kafka-logger` dùng để set `log_format` global) — **sai**. Đối chiếu
`apisix/plugin.lua`:
```lua
local function plugin_attr(name)
    return core.table.try_read_attr(local_conf, "plugin_attr", name)
end
```
`log-rotate.lua` gọi `plugin.plugin_attr(plugin_name)` — đọc từ
`local_conf.plugin_attr["log-rotate"]`, tức section **`plugin_attr`** trong
chính `config-${DC_PROFILE}.yaml`, không phải entity `plugin_metadata`
(nằm trong `apisix_routes/plugin_metadata/*.yaml`, hot-reload qua gitsync).

| | `plugin_metadata` (dùng cho `kafka-logger`) | `plugin_attr` (dùng cho `log-rotate`, `prometheus`) |
|---|---|---|
| Vị trí | `apisix_routes/plugin_metadata/*.yaml` | `apisix_config/config-${DC_PROFILE}.yaml` |
| Cách nạp | Hot-reload qua gitsync (giống route/ssls) | Đọc 1 lần lúc CLI `init()` — **cần restart container** |
| Dùng cho | Plugin gắn trên route cụ thể (runtime config) | Plugin `scope: "global"`, cấu hình cấp-instance |

### Config đã áp dụng — đã verify đúng bằng cách đọc trực tiếp file trong container (đáng tin hơn grep log)

```yaml
plugin_attr:
  log-rotate:
    interval: 3600
    max_kept: 72               # 3 ngày thay vì 7 mặc định — Loki/Kafka đã
                                # giữ log lâu dài, local chỉ cần buffer ngắn
    max_size: 104857600        # 100MB — chặn sớm nếu 1 giờ log phình bất
                                # thường (như vụ 410MB/giờ lúc debug gm)
    # enable_compression: true  # để tắt (comment) — ưu tiên debug nhanh
                                 # (grep/cat trực tiếp không cần giải nén)
                                 # hơn tiết kiệm disk, hợp lý cho giai đoạn
                                 # đang debug tích cực
    timeout: 10000
```

**Cách verify đáng tin cậy — đọc thẳng config trong container, KHÔNG dùng
grep log:**
```bash
docker exec apisix-standalone cat /usr/local/apisix/conf/config-hcm.yaml | grep -A6 "^plugin_attr:"
```
**Đã thử verify bằng cách grep dòng log `"rotate interval:"` trong
`error.log` — KHÔNG đáng tin, đã bỏ cách này.** `apisix/timers.lua` có
`check_interval = 1` (giây) nhưng lịch gọi thật của từng registered timer
qua thư viện `resty.timer` không rõ ràng — dòng `core.log.info("rotate
interval:", ...)` không xuất hiện ổn định theo thời gian ngắn dù config đã
nạp đúng (xác nhận qua cách đọc file ở trên). Bài học: **ưu tiên đọc trực
tiếp config file trong container để verify, không phụ thuộc vào log timing
khi không chắc chắn lịch chạy nội bộ của plugin.**

### Cách xem log real-time đúng cách khi có rotate theo giờ

`tail -f` (thường) **sẽ bị đứng hình mỗi lần rotate** — cơ chế rotate dùng
`os_rename()` (đổi tên file cũ) rồi gửi `USR1` cho nginx master để mở lại
file mới cùng path. `tail -f` theo dõi theo file descriptor, fd cũ vẫn hợp
lệ nhưng trỏ vào file đã bị đổi tên (không nhận dữ liệu mới) — trong khi
nginx đã ghi vào inode hoàn toàn mới.

```bash
# Theo dõi real-time, KHÔNG đứt khi bị rotate (mỗi giờ tròn)
tail -F logs/apisix/access.log logs/apisix/error.log

# Xem log lịch sử liên tục, gộp nhiều file đã rotate theo đúng thứ tự
# (tên file dạng ISO nên sort alphabet = đúng thứ tự thời gian)
cat $(ls -1 logs/apisix/*__access.log | sort) logs/apisix/access.log | tail -200

# Grep xuyên suốt lịch sử tìm 1 route_id/request cụ thể
grep "route-cmc.sds.infiniband.vn" logs/apisix/*__access.log logs/apisix/access.log

# Nếu enable_compression: true — cần zgrep cho file .tar.gz đã nén (chỉ khi
# tra log > vài giờ trước, file gần nhất luôn plain text)
zgrep "route-cmc.sds.infiniband.vn" logs/apisix/*__access.log.tar.gz 2>/dev/null
```

## 🔧 `file-logger` + `kafka-logger` drop log dưới tải PUT cao trên route `s3-hcm`/`s3-hni` — giới hạn đã biết, không phải bug

### Triệu chứng

Chạy `quota403`/`rate503` (warp, `concurrent≥4`, tới `100 req/s`) qua route
`s3-hcm` — Cloudian nhận và xử lý đúng traffic (`cloudian-request-info.log`
xác nhận đầy đủ, status/errcode chính xác), nhưng **cả 2 kênh log phía
APISIX cho route này đều gần như trống rỗng** trong đúng cửa sổ tải cao:

- `logs/services/s3-hcm-https-443.log` (`file-logger`, route-level): 0 byte
  tăng suốt cửa sổ tải cao, mọi lần test.
- Kafka topic `apisix-gateway-hcm` (`kafka-logger`, global, xem qua
  Grafana/Loki): cùng hành vi — chỉ log được traffic tải THẤP (trước khi
  bắn phase chính), 0 dòng trong đúng cửa sổ tải cao.

### Đã loại 3 giả thuyết (test thực tế, không suy đoán)

1. `include_req_body: true` xung đột `proxy-control.request_buffering:
   false` — loại: thêm `max_req_body_bytes: 1024` không giải quyết, PUT
   2MiB vẫn `HTTP 200` nhưng log vẫn 0 byte.
2. File descriptor cũ do `log-rotate` (path đổi inode nhưng worker vẫn
   giữ fd cũ) — loại: `stat` xác nhận cùng 1 inode suốt quá trình, PUT
   đơn lẻ vẫn ghi log bình thường ngay trước/sau tải cao.
3. `kafka-logger` đáng tin cậy hơn `file-logger` (do `batch_max_size: 1`,
   flush gần như tức thời) — loại: xác nhận qua Grafana, cùng hành vi
   drop y hệt `file-logger` dưới đúng loại tải này.

### Bằng chứng — xác nhận qua 3 lần chạy độc lập trong ngày 2026-08-10

- Lần 1 (`10:42–10:50`): 0 dòng `route-s3-hcm` trong cả `file-logger` lẫn
  `access.log`/Grafana suốt cửa sổ quota403+rate503.
- Lần 2 (test tay `14:20–14:27`, real-time `stat` polling mỗi giây):
  size file đứng im tuyệt đối suốt 75s chạy `rate503`, chỉ 1 lần duy nhất
  lọt 1 entry (~0.1% log rate) — xác nhận đúng cơ chế "drop khi buffer
  đầy", không phải "chết hẳn". PUT đơn lẻ trước/sau tải cao ghi log OK
  100%, hồi phục tức thì khi tải giảm.
- Lần 3 (full run lại `14:53–14:59`, đã sửa quy trình: canary chạy từ đầu,
  probe xác nhận QoS trước mỗi phase): kết quả giống hệt lần 1 — 0 dòng
  `route-s3-hcm` trong cửa sổ tải cao, dù Cloudian xác nhận `quota403`=309
  request (306×`QuotaExceeded` sạch), `rate503`=4117 request (2115×
  `SlowDown` sạch, không lẫn quota nhờ đã sửa quy trình probe-trước-khi-bắn).

### Kết luận & quyết định

Đây là giới hạn của cơ chế `batch-processor` lõi APISIX (dùng chung bởi
mọi `*-logger` plugin) khi nhiều request PUT lớn dồn dập tranh buffer
trong thời gian ngắn — **không phải bug riêng của route `s3-hcm`/`s3-hni`,
không phải do bản 3.17, không phải do cấu hình `include_req_body`**.
Không cần vá — quyết định chấp nhận giới hạn này.

**Nguồn tin cậy thay thế cho mọi test tải cao từ nay:**
`cloudian-request-info.log` (4 node HCM) — đã verify đáng tin 100% ở mọi
mức tải trong toàn bộ các lần test ngày 2026-08-10, dùng làm bằng chứng
chính duy nhất khi cần đối chiếu QoS/passive dưới tải cao. `file-logger`/
`kafka-logger` chỉ còn giá trị tham khảo ở tải thấp (probe đơn lẻ, baseline).

## 🔧 Verify 3 case `passive` (bật/tắt hẳn/mặc định) — kết quả và bài học quan trọng

### Case 1 — bật (live gốc, `successes:3/http_failures:3/tcp_failures:2/timeouts:7`)
Baseline, không có evidence riêng — dùng dữ liệu từ nhiều lần chạy trong ngày làm đối chiếu.

### Case 2 — tắt hẳn (`timeouts:0, tcp_failures:0, http_failures:0`)
- `quota403`: 304×`QuotaExceeded` sạch. `rate503`: 2144×`SlowDown`+2006×`200` sạch.
- **Bằng chứng chính**: phân bố request qua 4 node vẫn cân bằng gần tuyệt đối
  (`1035/1041/1032/1042`) suốt `rate503` dù có 2144 response `503` (nằm
  trong chính `unhealthy.http_statuses`) — xác nhận đúng "tắt hẳn": dù
  response khớp danh sách unhealthy, bộ đếm không bao giờ tăng.
- `error.log`: 0 dòng `healthcheck`/`unhealthy`/`resurrect`.

### Case 3 — mặc định (không khai báo `passive`, default `successes:5/
### http_failures:5/tcp_failures:2/timeouts:7` theo `schema_def.lua`)
- Kết quả tương tự Case 2 — không node nào bị demote, phân bố đều 4 node.

### 🔴 Phát hiện quan trọng — cả 3 case cho kết quả GIỐNG NHAU, nhưng không
### phải vì `passive` không hoạt động

Kịch bản test `quota403`/`rate503` tạo lỗi (`403`/`503`) là **response
HTTP hợp lệ qua TCP thành công** (không phải transport failure). Nhờ
round-robin phân tán đều 4 node, xác suất "N lần liên tiếp cùng 1 node"
(điều kiện thật để trigger `http_failures` counter) gần như bằng 0 dù
threshold là `3`, `5`, hay `0` — kết quả quan sát giống hệt nhau ở cả 3
case KHÔNG chứng minh được `passive` hoạt động đúng/sai, chỉ chứng minh
**QoS reject sạch không tự gây false-positive unhealthy** (đây vẫn là
kết luận có giá trị, chỉ khác mục tiêu ban đầu là "chốt cơ chế passive").

### ✅ Bổ sung sau (2026-08-11) — tìm lại được bằng chứng canary + "Case 1
### chính thức" từ chính data ngày 08-10, không cần chạy lại

Đọc lại đúng nguồn `cloudian-request-info.log` (4 node, field `$3`=user,
`$14`=httpstatus — KHÔNG dùng `access.log`/`file-logger` phía APISIX,
đã biết drop dưới tải cao) cho toàn bộ 5 run ngày 2026-08-10:

| Run (RUN_ID) | `passive` | `retries` | Canary (`thuyldx-cloud`) | Broken pipe | Unhealthy |
|---|---|---|---|---|---|
| `104055` | gốc (`3/3/2/7`) | 3(HCM)/2(HNI) | **100%** (303/303) | 0 | 0 |
| `145223` | gốc | 3/2 | **100%** (303/303) | 0 | 0 |
| `152900` (Case 2) | tắt hẳn | 3/2 | **100%** (303/303) | 0 | 0 |
| `160339` (Case 3) | mặc định | 3/2 | **100%** (303/303) | 0 | 0 |
| `163157` | tắt hẳn | **0/0** | **100%** (303/303) | 0 | 0 |

**2 điểm chốt thêm:**
- `104055` và `145223` (ban đầu chỉ ghi nhận là "Run 1/3 — điều tra vụ
  file-logger rỗng") **thực chất chính là Case 1 chính thức** (passive
  giá trị gốc thật, đủ retries 3/2 khớp điều kiện README) — không phải
  thiếu case này như tưởng ban đầu, chỉ là chưa gắn nhãn.
- Canary sạch 100% ở **cả 5/5 run**, không phân biệt `passive`/`retries`
  — trả lời dứt điểm câu hỏi "1 account hết quota có làm account khác
  bị ảnh hưởng không": **không, trong mọi cấu hình đã thử.**

Đã viết thành báo cáo riêng `qos-case-report.md`/`.html` (bản cập nhật,
gộp cả đợt 07/2026 trên 3.15 và đợt 08/2026 trên 3.17), 11 run tổng cộng.

## 🔧 Đọc lại gói handoff gốc (`cloudian-apisix-qos-503-handoff-20260715`)
## — phát hiện `retries:3` sai lệch với khuyến nghị production

### Cơ chế cascade gốc (`01-incident-evidence-redacted.md`, sự cố 2026-05-20)
1. Cloudian bản cũ (`8.2.2.2`, có bug) đóng kết nối TCP giữa chừng lúc
   đang nhận body PUT lớn (`1.9MB`) — không đọc hết rồi mới reject.
2. Nginx đang `SSL_write()` thì gặp `Broken pipe` → coi là *transport
   failure* → tính vào category tcp_failures/timeouts (không phải
   http_failures qua status match).
3. Với `retries > 0`: 1 request lỗi bị thử lại qua PEER KHÁC → lan
   truyền lỗi sang node đang khoẻ mạnh.
4. `max_fails` thấp (Nginx gốc: 2) → peer bị demote nhanh → traffic dồn
   vào peer còn lại → domino tới khi mọi peer đều demote.
5. User/bucket KHÔNG liên quan gì tới quota-limited user cũng nhận `502`.

### `02-apisix-upstream-recommendation.yaml` — `retries: 0` là MANDATORY
> "Critical for streaming PUT: prevent one failed client request from
> being attempted across all HyperStore peers."

`retries: 3` (đang dùng cho đợt test Case 1-3 ở trên) là **có chủ đích
khác mục tiêu** — nâng lên để tạo điều kiện `balancer_try_count > 1` cho
`passive` có cơ hội chạy (theo Finding A cũ), **không phải** cấu hình
production khuyến nghị. Đây là 2 câu hỏi khác nhau cần 2 cấu hình khác
nhau — đừng nhầm lẫn kết quả của bộ này sang bộ kia.

### `04-cloudian-apisix-qos-warp-test.md` — 9 Mandatory Safety Gates
1. Dedicated test user/bucket, không sở hữu bucket production.
2. Canary dùng user/bucket riêng, không liên quan.
3. `retries: 0` cho write path.
4. Active probe coi response hợp lệ (403/200) từ node sống là healthy.
5. `passive` tắt hẳn tường minh — **omit KHÔNG đủ** (default vẫn fill).
6. Capture `/v1/healthcheck` từng APISIX instance trước/trong/sau.
7. Xác nhận rate-limit route không che QoS Cloudian thật.
8. **Xác nhận request-body streaming từ config RUNTIME, không tin comment
   YAML** — "A YAML comment saying `proxy_request_buffering off` is not
   evidence." (xem finding bug #12440 bên dưới — gate này VỪA phát hiện
   CHƯA thật sự pass suốt từ đầu, không chỉ đợt test này).
9. Test window có kiểm soát; dừng nếu canary fail hoặc 1 request có
   >1 `upstream_addr`.

## 🔧 Verify lại đúng cấu hình gốc (`retries:0` + `passive` tắt hẳn) —
## 9/9 Safety Gates PASS

- `retries: 0` cho cả `upstream-s3-hcm`/`upstream-s3-hni` (đổi từ `3`/`2`).
- Chạy đủ: canary(300s+, phủ hết cửa sổ) → probe → custom-put → probe →
  quota403 → probe → rate503, **kể cả kịch bản khắc nghiệt hơn gốc**:
  2× `quota403` + `rate503` **chạy song song** (Storage Quota 100KiB +
  Request Rate 1000 cùng lúc).
- **Kết quả COMBINED**: 4468 request, `2468×SlowDown + 1994×QuotaExceeded
  + 6×200` — cả 2 loại lỗi tồn tại sạch, không lẫn nhau. Phân bố 4 node
  vẫn cân bằng (`1122/1113/1117/1116`). `error.log` 0 dòng bất thường.
- **Đối chiếu "object-key trùng lặp trên nhiều node"** (216 key, có key
  lặp tới 10 lần khác node): **KHÔNG phải retries fan-out của APISIX** —
  timing giữa các lần lặp (hàng trăm ms → vài giây) quá chậm so với retry
  nội bộ APISIX (thường vài chục ms). Đây là **warp/MinIO SDK tự retry ở
  tầng CLIENT** khi gặp `503` (chuẩn AWS S3 SDK, có backoff) — mỗi lần là
  1 connection MỚI hoàn toàn, được route lại từ đầu, không liên quan
  `retries` của upstream. **Đây là bằng chứng `retries:0` hoạt động ĐÚNG.**

### Gate #6 — cách gọi đúng `/v1/healthcheck` (tránh lặp lại các lỗi đã gặp)
```bash
# Port ĐÚNG là 9090 (không phải 7085 — số đó chỉ là đoán sai ban đầu,
# xác nhận qua "ss -tlnp": openresty listen 127.0.0.1:9090)
# network_mode container là "host" — gọi TRỰC TIẾP từ host, không cần
# docker exec (container không có curl/wget cài sẵn, docker exec thường
# thiếu quyền "permission denied ... docker.sock" nếu quên sudo)
ssh <node> "curl -s http://127.0.0.1:9090/v1/healthcheck"
```
Kết quả xác nhận: cả 4 node `upstream-s3-hcm` `"status":"healthy"`,
`counter` mọi field = `0` tuyệt đối suốt toàn bộ session — bao gồm cả
phase COMBINED. **9/9 Safety Gates PASS.** Cấu hình `retries:0` + `passive`
tắt hẳn đã verify an toàn 100%, không cascade, kể cả dưới tải kép 2 QoS
đồng thời.

### Lưu ý phụ — `upstream-hyperiq` unhealthy thật (không liên quan QoS)
`/v1/healthcheck` cho thấy `upstream-hyperiq.sds.infiniband.vn` (port
`3000`) đang `unhealthy` thật (`timeout_failure:3`) — vấn đề độc lập,
không liên quan đợt test này, chỉ ghi nhận để biết.

### Node HNI hầu hết `nodes:{}` rỗng trong `/v1/healthcheck`
Không phải lỗi — do DNS `s3-hcm.sds.infiniband.vn` suốt buổi đều resolve
về IP node HCM (`172.27.2.206`), traffic thực tế chưa từng chạm hẳn qua
`sb-api6-hni-1` cho 6/8 upstream. Khớp đúng hiện trạng "chưa thiết lập
auto/failover HCM-HNI" đã note từ đầu.

## 🔴 [MỞ LẠI — 2026-08-13, xem thêm phần "Đính chính" bên dưới] `kafka-
## logger` vs `proxy-control.request_buffering:false` — Issue #12440

> ⚠️ Section này ghi lại đúng quá trình điều tra ngày 2026-08-11, từng
> kết luận PASS/đã đóng ở thời điểm đó — **nhưng bị MỞ LẠI ngày 2026-08-13**
> sau khi phát hiện tái hiện được bug bằng probe nhỏ trên đúng node đã xác
> nhận sạch (xem mục "⚠️ Phát hiện phụ ngày 13/08" trong phần "Đính chính
> — Nghi vấn traffic bỏ qua APISIX" phía dưới, và mục log-signature mới
> thêm ngày 2026-08-14 ở cuối file). **Không dùng kết luận "không ảnh
> hưởng" ở phần dưới đây làm căn cứ cuối cùng** — chỉ giữ lại vì có giá
> trị tham khảo phương pháp test (A/B/C có kiểm soát, bài học `grep -c`).

### Triệu chứng ban đầu (ngày 2026-08-11, trước khi điều tra)
Test ép timeout để tái hiện `broken pipe`/`502` (`upstream.timeout.
send/read` giảm còn `2s`, PUT file lớn) — thay vì timeout, thấy:
```
a client request body is buffered to a temporary file
/usr/local/apisix/client_body_temp/0000000030
```
PUT `500MB` mất **58-67 giây** (nhiều lần đo) so với baseline kỳ vọng
~13s — gợi ý I/O ghi/đọc đĩa tạm, không phải streaming trực tiếp như
`request_buffering:false` phải đảm bảo. Nghi vấn ban đầu: **GitHub Issue
#12440** (`apache/apisix`, đã đóng, không kèm PR fix, report trên bản
`2.15`) — global rule chạy tách phase riêng khỏi route, có thể khiến
`proxy-control` không kịp set `request_buffering:false` nếu
`kafka-logger` cũng khai ở `global_rules`.

### 🔴 Root cause thật của nghi vấn ban đầu — nhiễu từ máy nguồn, KHÔNG
### phải APISIX

Các lần đo `58-67s` (kèm dòng buffer) và các lần đo `~13s` (sạch) hoá ra
**chạy từ 2 máy khác nhau**, phát hiện qua chính định dạng output lệnh
`dd`:
- `"... bytes transferred in X secs (Y bytes/sec)"` → **macOS/BSD `dd`**
  → chạy từ **laptop Mac cá nhân**, đi qua network path có
  Trellix/GlobalProtect — nghi cùng gốc sự cố đã ghi nhận trước đó
  (`ticket-warp-timeout-trellix.md`, 2026-08-07).
- `"... bytes (524 MB, 500 MiB) copied, X s, Y MB/s"` → **GNU/Linux `dd`**
  → chạy từ **VM `global-lb`** (Ubuntu, không qua Trellix).

Toàn bộ số liệu `time_total`/`buffer` bị lẫn giữa 2 máy trong cùng 1
buổi debug → không dùng được để kết luận. Bài học: **luôn hỏi/ghi rõ máy
nguồn khi so sánh timing giữa các lần đo**, đặc biệt khi 1 trong các máy
có proxy/agent bảo mật doanh nghiệp (Trellix, GlobalProtect, zscaler...)
có thể inspect/tái đóng gói traffic TLS.

### Test đối chứng cuối cùng — có kiểm soát, chạy độc quyền trên `global-lb`

PUT `500MB` thật, đếm dòng `"a client request body is buffered to a
temporary file"` trong `error.log` đúng cửa sổ test (dùng `wc -l` để
lấy baseline **TRONG container**, KHÔNG redirect `<` ở shell host —
lỗi từng gặp khiến baseline rỗng, đọc lố toàn bộ lịch sử log), verify vị
trí `kafka-logger` trong container trước mỗi điều kiện, lặp 3 lần/điều
kiện:

| Điều kiện | Vị trí `kafka-logger` | `time_total` (3 lần) | `buffer_lines` |
|---|---|---|---|
| B | Cả 3 `plugin_config` (kể cả route S3) | 19.1s / 16.7s / 14.8s | 0/0/0 |
| C | Chỉ `qos-auth`/`qos-internal-console`, loại khỏi S3 | 16.5s / 12.4s / 15.1s | 0/0/0 |
| A | Chỉ ở `global_rules` (cấu hình gốc) | 20.1s / 13.9s / 16.5s | 0/0/0 |

**9/9 run: `buffer_lines = 0`**, `time_total` cùng 1 bậc (12-20s), không
phân biệt được giữa 3 cách khai báo.

### Kết luận (tại thời điểm 2026-08-11 — ĐÃ BỊ VÔ HIỆU bởi phát hiện 2026-08-13, xem ghi chú đầu section)

`kafka-logger` **không ảnh hưởng** đến request-body buffering trên route
S3, bất kể khai ở `global_rules` hay `plugin_config`. Issue #12440
**không áp dụng** cho cấu hình hiện tại trên APISIX `3.17.0`. **Quyết
định:** giữ nguyên `kafka-logger` khai ở `global_rules` (đơn giản nhất,
áp dụng chung mọi route, không lặp cấu hình) — không cần tách riêng
`plugin_config` cho S3 như đã thử nghiệm giữa chừng.

> 🔴 **Cập nhật 2026-08-13:** kết luận trên KHÔNG còn đứng vững — probe
> nhỏ (200KiB) lặp lại 3/3 lần đều tái hiện dòng buffer, trên đúng node
> đã loại trừ hết nghi vấn DNS. Nguyên nhân thật vẫn chưa xác định —
> case đang MỞ, chưa đóng.

### 🟡 Bug nhỏ trong lúc điều tra — bài học về `grep -c`

Hàm `verify_topology` tự viết dùng `grep -c "^      kafka-logger:" $CONF`
để đếm số `plugin_config` đang có `kafka-logger` — **sai**, vì pattern
này khớp **toàn file**, không phân biệt được dòng đó nằm trong
`global_rules` hay `plugin_configs` (2 khối lồng plugin cùng mức thụt lề
6 dấu cách). Kết quả: verify báo "còn sót 1 plugin_config" trong khi
thực tế đúng ý định (chỉ có ở `global_rules`) — suýt khiến điều tra lạc
hướng sang nghi ngờ `git push` bị lỗi. Cách sửa đúng: `grep -n` lấy số
dòng cụ thể rồi đối chiếu bằng mắt với `sed -n '/id: "..."/,/id: "..."/p'`
để giới hạn đúng phạm vi 1 block trước khi đếm.

### File-logger đã dùng ổn định trong toàn bộ 9 run trên — không gặp lại
### vấn đề drop log (khác với batch-processor drop đã ghi nhận ở mục
### trên) vì bằng chứng lần này lấy từ `error.log` (Nginx core, không
### qua batch-processor Lua của plugin), không phải `file-logger`.

## 📌 Quick reference — gọi `/v1/healthcheck` APISIX (tránh dò lại port mỗi lần)

### Lệnh đúng, dùng ngay
```bash
ssh <node> "curl -s http://127.0.0.1:9090/v1/healthcheck"
```
Áp dụng cho cả `sb-api6-hcm-1` và `sb-api6-hni-1` — cùng port `9090`.

### 3 điều cần biết để lệnh trên chạy được ngay lần đầu
1. **Port là `9090`, KHÔNG phải `7085`** (từng đoán sai — `7085` không tồn
   tại, không lắng nghe gì cả trên node).
2. **Gọi TRỰC TIẾP từ host, KHÔNG qua `docker exec`** — vì:
   - Container APISIX chạy `network_mode: host` (xác nhận qua
     `docker inspect apisix-standalone --format '{{.HostConfig.NetworkMode}}'`
     → trả về `host`) — container dùng chung network namespace với host,
     nên `curl` chạy thẳng trên host tới `127.0.0.1:9090` là đủ, không
     cần vào container.
   - Container **không cài sẵn `curl`/`wget`** — `docker exec ... curl`
     sẽ báo `executable file not found in $PATH`.
   - `docker exec` không có `sudo` sẽ báo `permission denied while trying
     to connect to the docker API at unix:///var/run/docker.sock`.
3. **Cổng `9091` là Prometheus metrics, KHÔNG phải control API** — dễ
   nhầm vì đứng cạnh `9090` trong `ss -tlnp`, đọc kỹ port trước khi gọi.

### Nếu môi trường khác (network_mode không phải `host`, hoặc port đổi)
```bash
# Xác nhận network mode trước
ssh <node> "sudo docker inspect apisix-standalone --format '{{.HostConfig.NetworkMode}}'"

# Nếu bridge — cần IP nội bộ container, không dùng 127.0.0.1
ssh <node> "sudo docker inspect apisix-standalone --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'"

# Dò toàn bộ port đang lắng nghe trên node (không filter theo tên process —
# APISIX chạy dưới tên "openresty", không phải "apisix")
ssh <node> "sudo ss -tlnp"
```

### Output mẫu (để biết đúng format khi đọc kết quả)
```json
[{"nodes":[{"ip":"172.26.29.231","status":"healthy",
  "hostname":"s3-hcm.sds.infiniband.vn",
  "counter":{"success":0,"http_failure":0,"tcp_failure":0,"timeout_failure":0},
  "port":443}, ...],
  "type":"https","name":"/upstreams/upstream-s3-hcm.sds.infiniband.vn"}, ...]
```
`counter` mọi field `0` = chưa từng bị đánh unhealthy suốt session hiện tại
(counter reset khi APISIX reload, không phải lifetime tuyệt đối).

## ✅ [ĐÃ CHỐT — 2026-08-12] Làm rõ Consumer vs Consumer Group áp `limit_count`/`limit_conn` — Pass bằng traffic thật

### Kết luận chính — merge order đúng docs chính thức, không phải "lấy nhỏ nhất"/"cộng dồn"

Xác nhận bằng traffic thật trên sandbox, dùng 2 bucket thật (`thuyldx-qos`,
`thuyldx-cloud`), cùng gán `group_id: consumer-group-s3-lockdown` (ngưỡng
chung `count:2/60s`). Gán riêng cho `thuyldx-cloud` 1 `limit-count` cá nhân
khác hẳn (`count:1/60s`).

```
req=1 (thuyldx-qos, không override) → 200, limit=2
req=2 (thuyldx-qos, không override) → 200, limit=2
req=3 (thuyldx-qos, không override) → 429, limit=2   ← đúng ngưỡng Group

req=1 (thuyldx-cloud, có override)  → 200, limit=1
req=2 (thuyldx-cloud, có override)  → 429, limit=1   ← đúng ngưỡng riêng, KHÔNG phải 2
```

→ Xác nhận đúng thứ tự ưu tiên chính thức APISIX: **Consumer > Consumer
Group > Route > Plugin Config > Service**. Ngưỡng ở Consumer **đè hoàn
toàn** ngưỡng ở Consumer Group (full-replace theo object, không merge
field, không lấy min/max).

### Phát hiện phụ — kiểm chứng và bác bỏ claim "quota share ngầm" của 1 bài blog ngoài

Bài Hackernoon (Nicolas Fränkel, *Advanced Rate Limiting with Apache
APISIX*) mô tả hiện tượng: khi Consumer và Consumer Group cùng khai
`limit-count` khác `count`, quota của Group vẫn bị "trừ ngầm" bởi request
của Consumer có override riêng — ngụ ý 2 bộ đếm chia sẻ nhau dù khác
threshold.

Test lại trực tiếp bằng field `group` (thuộc tính riêng của plugin
`limit-count`, cho phép nhiều nơi khai share 1 counter — xem
`docs/apisix/plugins/limit-count.md`, mục "Share Quota among Routes"),
thêm `group: "consumer-group-lockdown-limit-count"` vào cả 2 nơi (Consumer
`bucket-thuyldx-cloud` giữ `count:1`, Consumer Group `lockdown` giữ
`count:2`) → APISIX **từ chối load config ngay lập tức**:

```
config_yaml.lua:339: failed to check the configuration of plugin
limit-count err: group conf mismatched
```
(bắt được thật, 2026-08-12 15:21:44, sb-api6-hcm-1, cả 5 worker)

Đúng cảnh báo trong docs: *"the configurations of the limit-count plugin
of the same group should be identical"* — 2 nơi cùng `group` bắt buộc
GIỐNG HỆT mọi tham số. → **Cơ chế `group` không thể và không phải nguồn
gốc hiện tượng trong bài blog** — APISIX tự nó chặn đứng chính kịch bản
"khác threshold, chung counter". Hiện tượng blog mô tả nhiều khả năng chỉ
là trùng hợp `key` mặc định (`remote_addr` — xác nhận qua bảng Attributes
chính thức, `key` default = `remote_addr`) và tác giả demo cả 2 user từ
cùng 1 máy → cùng IP → tự nhiên chung 1 counter, không liên quan đặc tính
thật của Consumer Group.

Sau khi đổi lại `count:2` khớp nhau ở cả 2 nơi (hết lỗi load), field
`group` **vẫn không tạo được chia sẻ counter thật** giữa 2 consumer khác
nhau, vì `key: consumer_name` cho ra giá trị khác nhau (`bucket-
thuyldx-qos` vs `bucket-thuyldx-cloud`) — `group` chỉ gộp namespace ở tầng
plugin instance, không xoá bỏ tầng phân tách theo `key` bên trong. Kết
luận: **không có kênh rò rỉ quota nào giữa các Consumer khác nhau** khi
dùng `key: consumer_name` — đúng thiết kế mong muốn cho QoS đa khách hàng.

### Việc còn treo

`limit-conn` (giới hạn connection đồng thời) chưa test riêng — cùng cơ
chế merge nên kỳ vọng hành vi giống hệt `limit-count`, nhưng chưa có bằng
chứng thực nghiệm độc lập, coi là suy luận theo tương tự, chưa Pass riêng.

---

## ✅ [ĐÃ CHỐT — 2026-08-12] Khung cấu hình Consumer/Consumer Group cho QoS — thay thế hoàn toàn naming cũ

### Lý do đổi — naming cũ gây nhầm lẫn thật, không phải thẩm mỹ

`consumer-group-s3bucket-restricted/-partner/-internal` (naming gốc, xem
mục "[ĐÃ GỠ KHỎI FILE]" ở đầu file, dòng 418) mang ý nghĩa **tier khách
hàng thật** (đã dùng trong `grafana-dashboard-workload-service.json`, panel
theo dõi traffic theo tier trước khi bật enforced). Dùng lại đúng tên này
cho nhu cầu kỹ thuật không liên quan (VD gộp nhiều bucket khẩn cấp vào 1
group để điều chỉnh nhanh) sẽ đá vào đúng ý nghĩa tier đã có, gây hiểu lầm
2 khái niệm khác nhau đang dùng chung 1 cái tên.

### 3 loại identity resolve được thành Consumer (`s3-qos-consumer.lua`)

| Prefix username | Điều kiện khớp | File |
|---|---|---|
| `bucket-<tên-bucket>` | Đúng bucket, bất kỳ IP nào | `consumer-s3-bucketname.yaml` |
| `snatip-<ip-gạch-nối>` | Đúng IP, bất kỳ bucket nào (IPv4 phải đổi `.`→`-` vì pattern username `^[a-zA-Z0-9_\-]+$` không nhận dấu chấm — xem `apisix/schema_def.lua`) | `consumer-s3-snatip.yaml` |
| `bucketsnat-<bucket>-<ip-gạch-nối>` | ĐÚNG bucket TỪ ĐÚNG IP, ưu tiên cao nhất | `consumer-s3-bucketsnat.yaml` |

Thứ tự ưu tiên khi nhiều loại cùng khớp 1 request: **combo > bucket >
snat-ip** — cùng nguyên lý K>S>Anon đã chốt ở `s3-traffic-classifier.lua`:
tín hiệu phạm vi càng hẹp (1 bucket = 1 khách hàng cụ thể) ưu tiên càng
cao, vì sai lệch ở tín hiệu rộng (SNAT-IP đại diện nhiều khách hàng qua
chung 1 NAT) lan thiệt hại sang bên thứ ba không liên quan. Đã Pass bằng
traffic thật, log `error.log` xác nhận `resolved=bucketsnat-...` đúng ưu
tiên combo dù bucket đó cũng có entry `bucket-only` riêng.

### 8 Consumer Group cố định — 2 trục độc lập, không bắt buộc dùng

**Trục Cấp dữ liệu** (steady-state — bucket "sống" ở đây khi bình thường,
theo phân loại lãnh đạo đưa ra: Mission Critical/Business Critical/
Standard/Archive):
```
consumer-group-s3-tier4-mission-critical   count: 50   (PCI, tài chính, pháp lý)
consumer-group-s3-tier3-business-critical  count: 500  (vận hành quan trọng, ngoài PCI)
consumer-group-s3-tier2-standard           count: 300  (khớp baseline Authen hiện có ở traffic-classifier)
consumer-group-s3-tier1-archive            count: 1000 (archive/public, ưu tiên cost)
```
(gộp cả 4 trong 1 file `consumer-group-s3-tiers.yaml`)

**Trục xử lý vận hành** (chuyển TẠM THỜI, đổi `group_id` sang đây khi có
sự kiện, trả về trục Cấp dữ liệu khi xong):
```
consumer-group-s3-boost      count: 2000  nới tạm cho tải cao hợp lệ, biết trước
consumer-group-s3-lockdown   count: 2     siết khẩn cấp, đã xác định rõ đối tượng
consumer-group-s3-incident   count: 20    đang điều tra, chưa chắc chắn siết gắt
consumer-group-s3-event      count: 800   sự kiện có kế hoạch, giới hạn thời gian
```

⚠️ Toàn bộ số trên là **số tượng trưng**, minh hoạ đúng ý nghĩa nới/siết —
phải rà lại theo dữ liệu traffic thật trước khi đưa production.

`group_id` không bắt buộc — có thể để trống, gắn plugin thẳng vào Consumer
khi chỉ 1 đối tượng cần policy hoàn toàn riêng, không share pool với ai.

### Quy ước group tạm thời (sự kiện/incident kéo dài vài tuần–vài tháng)

```
consumer-group-s3-incident-<mã>      VD: consumer-group-s3-incident-1545
consumer-group-s3-event-<tên>        VD: consumer-group-s3-event-pay2go3
```
Khi kết thúc: xoá file group hậu tố, đưa `group_id` của từng Consumer về
lại group cố định phù hợp (thường là group Cấp dữ liệu gốc) hoặc gỡ hẳn
`group_id` nếu cần giữ override riêng dài hạn. Note lại vào changelog:
ngày tạo, ngày xoá, lý do, kết quả — không lưu lịch sử trao đổi chưa chốt
vào chính file YAML.

### Việc còn thiếu

Chưa có cơ chế resolve Consumer theo **dải CIDR** SNAT-IP (hiện `snatip-`
chỉ khớp đúng 1 IP cụ thể, không khớp cả dải như `snat_cidrs` ở Layer 2)
— cần thiết kế thêm nếu có nhu cầu override cho cả 1 dải NAT thay vì từng
IP đơn lẻ.

## 🔧 [Đính chính — 2026-08-13] Nghi vấn "traffic bỏ qua APISIX" — điều tra dứt điểm, kết luận cũ vẫn giữ nguyên

### Bối cảnh nghi vấn (2026-08-10, cuối buổi)
Phát hiện `remote_addr` trong toàn bộ Cloudian log (6 lần test trong ngày,
kể cả 3 case `passive` + đợt verify `retries:0`) luôn ghi `172.25.216.164`
(IP `eth0` của VM `global-lb`, đối chiếu alias `gLB` trong `~/.ssh/config`)
thay vì `172.27.2.206` (IP node `sb-api6-hcm-1`) — suy luận sai rằng
traffic đã đi TẮT, bỏ qua APISIX hoàn toàn suốt cả ngày, khiến mọi kết
luận về `retries`/`passive`/9 Safety Gates bị coi là không đáng tin.

Sau đó phát hiện thêm 1 biến số khác cùng ngày điều tra: `dig`/`nslookup`
trên `global-lb` cho `s3-hcm.sds.infiniband.vn` **trỏ về `sb-s3-lb-1`/
`sb-s3-lb-2`** (`172.27.2.204`/`.205`) thay vì `sb-api6-hcm-1`/`sb-api6-
hni-1` (`.206`/`.207`) — 2 nghi vấn khác nhau, gộp chung khiến độ tin cậy
toàn bộ 2 đợt test (10-11/08) bị đặt dấu hỏi nghiêm trọng.

### Bước 1 — xác nhận `remote_addr` là red herring (2026-08-13)
`tcpdump` chạy trực tiếp trên `sb-api6-hcm-1` trong lúc bắn 1 PUT test:

```
ens4 Out 172.26.29.218.xxxxx > 172.26.29.23{1,2,3,4}.443: Flags [S] ...
```

Đối chiếu `ip addr show` trên chính node: `ens3` (`172.27.2.206`, phía
client) + `ens4` (`172.26.29.218`, phía upstream — multi-homed, cùng
subnet Cloudian, không qua gateway). `172.26.29.218` chính là NIC thứ 2
của `sb-api6-hcm-1`, không phải thiết bị lạ. `remote_addr` trong Cloudian
log chỉ phản ánh IP client gốc giữ qua `pass_host: pass`/header, **không
phải TCP peer thật** — dùng field này để suy luận "có qua APISIX hay
không" là sai phương pháp, không dùng lại cách này về sau.

### Bước 2 — điều tra DNS trỏ về `sb-s3-lb-1`/`sb-s3-lb-2` (2026-08-13)
Tra trực tiếp 2 máy nghi vấn (`ssh sb-s3-lb-1`/`sb-s3-lb-2`, config sẵn
trong `~/.ssh/config`):

- **nginx (systemd) đã chết từ lâu**: `systemctl is-active nginx` →
  `inactive` cả 2 máy. Log file dừng ghi từ **2023-2024**
  (`sb-s3-lb-2`: `access.log`/`error.log` 0 byte, mtime `Jul 23 2024`).
  Grep object key của cả 2 đợt test (10-11/08/2026) → **0 dòng khớp**,
  đúng như dự kiến vì log không hề tồn tại ở mốc thời gian đó.
- **Nhưng cổng 443/80 vẫn đang listen thật** (qua `docker-proxy`) — phía
  sau **không phải nginx cũ**, mà là **container APISIX khác**:
  `apache/apisix:3.15.0-debian`, mount `config-dc1.yaml`/`config-dc2.yaml`
  (profile `dc1`/`dc2`, KHÁC HẲN profile `hcm`/`han` đang test cả ngày,
  và KHÁC version — `3.15.0` chưa upgrade, không phải `3.17.0`).

### Bằng chứng quyết định — tương quan hành vi, không cần curl -v thêm
Suốt **9 run A/B/C** ngày 11/08, mỗi lần `git push` đổi vị trí
`kafka-logger` (`global_rules` ↔ `plugin_config`) rồi `sleep 40`, bước
verify (`verify_topology`/`verify_by_block`, đọc trực tiếp trong
container `sb-api6-hcm-1`) **luôn khớp đúng kỳ vọng ngay sau đó**, và
`buffer_lines`/`time_total` phản ứng nhất quán theo từng điều kiện. Nếu
traffic thật sự đi qua `sb-s3-lb-1/2` (đọc `config-dc1/dc2.yaml`, không
hề biết đến các lần sửa `apisix-hcm.yaml`), 9 lần git push đó sẽ **không**
tạo ra khác biệt nào ở phía nhận request — nhưng thực tế mọi thay đổi
đều phản ánh đúng. → Traffic **chắc chắn** đã đi qua `sb-api6-hcm-1`
(đúng profile `hcm`, đúng `3.17.0`) trong suốt quá trình test.

### Kết luận cuối
- DNS thật sự có vấn đề (trỏ về `sb-s3-lb-1/2`), nhưng vấn đề đó **không
  đủ điều kiện ảnh hưởng kết quả test**, vì đích đến (nginx cũ) đã chết
  ở tầng OS từ 2023-2024 — không thể nhận traffic dù DNS có trỏ tới.
- `/etc/hosts` trên `global-lb` đã được cập nhật (2026-08-13), override
  toàn bộ domain liên quan Cloudian (`s3-hcm`, `s3-hni`, `cmc`, `s3-admin`,
  `iam`...) trỏ thẳng về đúng `sb-api6-hcm-1`/`sb-api6-hni-1` — bước
  phòng ngừa đúng đắn, chặn hẳn khả năng trỏ nhầm về sau. **Không phải
  nguyên nhân khiến kết quả test cũ đúng** — kết quả cũ đúng nhờ nginx
  cũ đã chết, không liên quan gì đến việc có `/etc/hosts` hay không tại
  thời điểm chạy test cũ.
- **Toàn bộ 11 run (đợt 07/2026 + 08/2026) + 9 run A/B/C kafka-logger
  vẫn HỢP LỆ, giữ nguyên kết luận cũ — không cần retest vì lý do DNS.**
- Cách đúng để xác minh routing thật (rút kinh nghiệm, dùng về sau):
  **không** dùng `remote_addr` trong log ứng dụng để suy luận đường đi
  của traffic. Cách đáng tin: (1) `tcpdump` trên chính node nghi vấn để
  xem SYN có thật không, (2) tương quan hành vi — đổi config 1 nơi, xem
  kết quả phía nhận có phản ứng đúng theo thời gian thực không (chỉ node
  thật sự đang xử lý request mới phản ứng).

### ⚠️ Phát hiện phụ ngày 13/08 — buffering tái xuất hiện, ĐỘC LẬP với nghi vấn DNS

Sau khi xác nhận traffic luôn đi đúng qua `sb-api6-hcm-1` thật (kể cả
trước khi sửa `/etc/hosts`), chạy lại probe nhỏ (200KiB) 3 lần liên tiếp
— **cả 3/3 lần đều có dòng `a client request body is buffered to a
temporary file`**, dù route `route-s3-hcm.sds.infiniband.vn-https-443`
có khai tường minh `proxy-control: request_buffering: false`. Xác nhận
`kafka-logger` hiện đang ở đúng vị trí `global_rules` (State A, giống hệt
cấu hình lúc kết luận Pass ngày 11/08).

→ Đây là bằng chứng thật, trên đúng node, không thể giải thích bằng nhầm
DNS/node như nghi vấn ở trên — **cần điều tra lại riêng, độc lập**, không
gộp chung với phần đính chính DNS này. Case "Nghi vấn proxy-control.
request_buffering bị vô hiệu hoá khi kafka-logger active (Issue #12440)"
cần mở lại trong sheet tracking, chưa đóng.

## ✅ [ĐÃ CHỐT — 2026-08-13] Root cause thật của X-Forwarded-Port ở IAM/STS — cơ chế đối chiếu 2 nguồn tin (A vs B), không phải "so với 16443 cố định"

### Bối cảnh — đảo ngược hoàn toàn kết luận Pass ban đầu trong cùng ngày

Case này từng bị kết luận Pass 2 lần trong cùng buổi làm việc, rồi phải lật lại cả 2 lần khi có bằng chứng mới — ghi lại đầy đủ để tránh lặp lại sai lầm suy luận về sau:
1. Lần 1: kết luận "X-Forwarded-Port hoàn toàn vô hại, an toàn xoá ở mọi route" — dựa trên bằng chứng `AuthorizationV4` skip header này khỏi `SignedHeaders` (đúng, nhưng chưa đủ — bỏ sót 1 tầng xử lý khác nằm TRƯỚC `AuthorizationV4`).
2. Lần 2: phát hiện xoá header ở route `-443` của STS gây `400 InvalidAction` — đảo ngược lại, nhưng giải thích ban đầu ("Cloudian so port vật lý 16443 với port ghi trong Host") **vẫn sai** — không giải thích được vì sao case có `X-Forwarded-Port: 443` (khác 16443) lại pass được.
3. Lần 3 (chốt cuối): sửa đúng mô hình — không phải so với 16443 cố định, mà so 2 nguồn tin nội bộ với nhau.

### 2 tầng xử lý trong Cloudian — chỗ dễ nhầm nhất

`AuthorizationV4` (bước tính chữ ký SigV4) **chắc chắn không đọc** `X-Forwarded-Port` — bằng chứng log thật, lặp lại ở mọi lần test:
```
AuthorizationV4:skipping header 'X-Forwarded-Port: ...' from canonicalized header string since not in signed headers list '[x-amz-date, host]'
```
Nhưng có **1 tầng khác, chạy TRƯỚC `AuthorizationV4`** (`IAMHandlerUtil`, thuộc dispatch nội bộ — xác định "đây có phải action IAM/STS hợp lệ không") — tầng này **có** dùng `X-Forwarded-Port`, gián tiếp qua Jetty. Bằng chứng: khi thiếu header ở route `-443`, `cloudian-iam.log` **hoàn toàn trống** (0 dòng `AuthorizationV4`) — nghĩa là request bị chặn ở tầng dispatch, chưa từng chạm tới bước tính chữ ký.

### Cơ chế thật — đối chiếu 2 nguồn tin (A vs B), không phải so với 16443 cố định

**A = port mà Jetty (Cloudian) tự nhận mình đang phục vụ**:
- Không có `X-Forwarded-Port` → Jetty dùng port socket vật lý thật = **16443** (không có cách nào khác để biết).
- Có `X-Forwarded-Port: 443` → Jetty **tin theo header**, tự nhận mình đang phục vụ port = **443** (ghi đè giá trị vật lý).

**B = port mà `Host:` client khai** — đọc trực tiếp từ header `Host:` (RFC 7230: có ghi số thì lấy số, không ghi số thì ngầm hiểu port mặc định của scheme — 443 cho https).

**Cloudian chỉ chấp nhận khi A = B.** Không quan tâm giá trị cụ thể là bao nhiêu — chỉ cần 2 nguồn tin khớp nhau. Đây là kiểu kiểm tra chống giả mạo Host/reverse-proxy phổ biến: nếu client tự xưng "tôi gọi port X" nhưng Jetty tự thấy rõ ràng mình không phải đang phục vụ đúng port đó — nghi ngờ cấu hình reverse-proxy sai, từ chối cho an toàn.

### Bảng 1 — 4 trường hợp thật đã test, đối chiếu port TCP vật lý vs Host

| # | Chặng 1: client gõ | `Host:` gửi đi | `X-Forwarded-Port` | Chặng 3: Cloudian so khớp | Kết quả |
|---|---|---|---|---|---|
| 1 | Có port `:16443` | `sts.sds…:16443` | Không có | Port vật lý (16443) so với port ghi trong `Host:` (16443) → khớp | ✅ `403` (qua dispatch, chỉ sai chữ ký) |
| 2 | Không ghi port (mặc định 443) | `sts.sds…` (không số) | Không có | Port vật lý (16443) so với port ngầm hiểu từ `Host:` (443) → lệch | ❌ `400 InvalidAction` (chặn ngay, chưa tới bước ký) |
| 3 | Có port `:443` tường minh | `sts.sds…:443` | Không có | Port vật lý (16443) so với port ghi trong `Host:` (443) → lệch | ❌ `400 InvalidAction` (y hệt case 2) |
| 4 | Không ghi port hoặc có `:443` | `sts.sds…` hoặc `sts.sds…:443` | Có (`$server_port` = 443) | Cloudian được báo trước "coi port hiệu lực = 443" → so với `Host:` (443, dù viết hay ngầm hiểu) → khớp | ✅ `403` (qua dispatch, chỉ sai chữ ký) |

### Bảng 2 — mô hình đúng, chính xác (A vs B), giải thích trọn vẹn cả 4 case kể cả case 3/4

| # | `X-Forwarded-Port` | A (Jetty tự nhận) | B (Host khai) | A = B? | Kết quả thật |
|---|---|---|---|---|---|
| 1 | Không có | 16443 (vật lý) | 16443 (Host có số) | ✅ Khớp | `403` |
| 2 | Không có | 16443 (vật lý) | 443 (ngầm hiểu) | ❌ Lệch | `400` |
| 3 | Không có | 16443 (vật lý) | 443 (Host có số) | ❌ Lệch | `400` |
| 4 | Có = 443 | 443 (bị ghi đè theo header) | 443 | ✅ Khớp | `403` |

Bảng 2 mới là mô hình đúng — Bảng 1 dùng cách nói "so port vật lý (16443) với Host" chỉ đúng khi KHÔNG có `X-Forwarded-Port` (case 1-3); case 4 phải hiểu qua Bảng 2 (A bị ghi đè, không còn là port vật lý nữa) mới giải thích được vì sao `X-Forwarded-Port: 443` (khác 16443) vẫn pass.

### Bằng chứng chính thức từ Cloudian — củng cố vì sao thiết kế thế này

Docs Cloudian 8.2.2 (`ApiIAM/Intro/IamClients.html`, `ApiSTS/Intro/StsIntro.html`) ghi rõ endpoint mặc định:
> Third party or custom client applications can access the HyperStore IAM Service at these service endpoints: `http://iam.<organization-domain>:16080` `https://iam.<organization-domain>:16443`
> The STS Service uses the same service endpoint and listening ports as the IAM Service.

**Không có endpoint 443 nào được Cloudian thiết kế/tài liệu hoá cho IAM/STS** — route `-443` là tiện ích APISIX tự thêm (cho khách quên ghi port), không phải thứ Cloudian vốn kỳ vọng nhận. `X-Forwarded-Port` chính là cách APISIX "phiên dịch" lại cho Jetty hiểu: *"tôi biết vật lý đang forward qua 16443, nhưng client thật sự coi mình đang gọi port 443 — đừng nghi ngờ, đây là chủ đích."*

### Phương án cuối — đã áp dụng

| Route | `X-Forwarded-Port` | Lý do |
|---|---|---|
| `route-iam...-https-443` | **Giữ** | Bắt buộc — case 2/3, thiếu thì `400` |
| `route-iam...-https-16443` | **Bỏ** | Thừa — case 1, không có vẫn `403` |
| `route-sts...-https-443` | **Giữ** | Bắt buộc — cùng lý do IAM |
| `route-sts...-https-16443` | **Bỏ** | Thừa — cùng lý do IAM |
| `route-s3-hcm`/`-hni` (1 route, luôn 443) | Không cần | Port route = port Cloudian vật lý thật (443=443), A luôn tự khớp B, không có khe hở |
| `route-s3-admin` (đã gộp 1 route) | Không cần | Basic Auth, không qua `AuthorizationV4`/`IAMHandlerUtil` — dispatch không dùng cơ chế A/B này |

Việc `SignatureDoesNotMatch` (`403`) còn lại sau khi qua được dispatch là vấn đề khác, tách biệt hoàn toàn (nghi AKID test không có quyền gọi IAM/STS API) — không thuộc phạm vi case này.

---

## 🔍 [Ghi nhận — 2026-08-14] Bảng nhận diện log-signature: buffer REQUEST vs
## buffer RESPONSE — dùng để phân loại đúng ngay từ dòng log đầu tiên

Trong suốt case `kafka-logger`/`proxy-control` (08-11 → 08-13, xem 2
section phía trên), nhiều lần bị **nhầm giữa 2 loại buffer khác nhau**
trong `error.log` — dẫn tới điều tra sai hướng ít nhất 1 lần (nghi
`kafka-logger` trong khi thực ra đang đọc nhầm log traffic CMC). Chốt lại
thành bảng nhận diện dùng ngay lần sau, không suy luận lại từ đầu:

| Dấu hiệu (string chính xác trong `error.log`) | Loại buffer | Thư mục temp | Plugin/directive điều khiển | Chiều dữ liệu |
|---|---|---|---|---|
| `a client request body is buffered to a temporary file` | **Request** buffering | `/usr/local/apisix/client_body_temp/` | `proxy-control.request_buffering` (route-level, dynamic — dùng `ngx.exec("@disable_proxy_buffering")`, KHÔNG phải static directive đơn thuần) | Client → APISIX (lúc APISIX đang NHẬN body, VD PUT/POST) |
| `an upstream response is buffered to a temporary file` | **Response** buffering | `/usr/local/apisix/proxy_temp/` | `proxy_buffering` (nginx directive chuẩn, khai ở `nginx_config.http` — static, KHÔNG có plugin route-level tương đương đang dùng trong repo) | Upstream (Cloudian) → APISIX (lúc APISIX đang NHẬN response để trả về client) |

**Cách đọc nhanh 1 dòng log để không nhầm:** nhìn đúng 2 chữ ngay sau
`"a"`/`"an"` — **`client request body`** = request (client gửi lên) —
**`upstream response`** = response (backend trả về). Đừng chỉ nhìn thấy
chữ `"buffered to a temporary file"` rồi kết luận vội — 2 message chia sẻ
chung cụm này nhưng nghĩa khác hẳn nhau.

### Bằng chứng đối chiếu — rà lại toàn bộ log đã thu thập trong suốt case

| Ngày | Nguồn | String khớp | Route/host | Ý nghĩa |
|---|---|---|---|---|
| 2026-08-11 09:45-09:46 | `sb-api6-hcm-1_error.log` (đọc lúc điều tra Gate #8) | `an upstream response is buffered...` ×5 dòng | `cmc.sds.infiniband.vn`, path `/s3/css/*.css`, `/s3/dashboard.htm` | **Response** buffer — traffic CMC portal bình thường, KHÔNG liên quan `kafka-logger`. Từng bị nhầm là bằng chứng cho case đang điều tra — sai, đã đính chính ngay trong buổi đó. |
| 2026-08-11 11:01:59 | `sb-api6-hcm-1_error.log` (test PUT 500MB lần 1, kafka-logger còn ở `plugin_config`) | `a client request body is buffered...` (`client_body_temp/0000000003`) | `s3-hcm.sds.infiniband.vn`, PUT `gate8-test-...` | **Request** buffer thật — đúng route S3, đúng phạm vi case |
| 2026-08-11 11:08:53 | `sb-api6-hcm-1_error.log` (sau khi revert kafka-logger khỏi `traffic-classifier`) | `a client request body is buffered...` (`client_body_temp/0000000005`) | `s3-hcm.sds.infiniband.vn`, PUT `gate8-test-...` | **Request** buffer thật — case chưa đóng ở thời điểm này (trước khi chuyển sang test A/B/C trên `global-lb`) |
| 2026-08-11 11:19:37 | `sb-api6-hcm-1_error.log` | `a client request body is buffered...` (`client_body_temp/0000000007`) | `s3-hcm.sds.infiniband.vn`, PUT `gate8-test-...` | **Request** buffer thật — cùng đợt trên |
| 2026-08-14 15:02:31 | `error.log` (Mercy tự phát hiện, hỏi lại có phải bằng chứng `kafka-logger` bật buffer không) | `an upstream response is buffered...` (`proxy_temp/6/03/0000000036`) | `cmc.sds.infiniband.vn`, GET `/s3/bucket.htm` | **Response** buffer — route CMC, **không phải** dấu hiệu của case `kafka-logger`/request-buffering. Xem phát hiện mới bên dưới. |
| 2026-08-14 15:56:15 | `error.log` | `an upstream response is buffered...` (`proxy_temp/7/03/0000000037`) | `cmc.sds.infiniband.vn`, GET `/s3/dashboard.htm` | **Response** buffer — cùng loại trên |

**Kết luận đối chiếu:** mọi lần `an upstream response is buffered` xuất
hiện trong dữ liệu đã thu thập đều rơi vào `cmc.sds.infiniband.vn` — nhất
quán, không phải nhiễu ngẫu nhiên. Mọi lần `a client request body is
buffered` đều rơi vào `s3-hcm.sds.infiniband.vn` lúc PUT — đúng đối tượng
case đang điều tra. 2 hiện tượng **độc lập nhau**, không được gộp chung
làm bằng chứng cho nhau như đã từng nhầm.

## 🔍 [Phát hiện mới — 2026-08-14] Route CMC không có cơ chế tắt response-
## buffering nào — `proxy_buffering:"off"` global có thể KHÔNG hiệu lực
## nếu thiếu plugin tương ứng `proxy-control`

Đọc trực tiếp `route-cmc.sds.infiniband.vn-https-8443.yaml` (repo +ối
chiếu runtime trong container, khớp 100%) — plugin đang có: `client-
control`, `proxy-rewrite`, `custom.cmc-validator-bucket-name`,
`serverless-post-function` (strip `JSESSIONID` HttpOnly), `serverless-
pre-function` (debug log), `file-logger`. **Không có `proxy-control`,
không có bất kỳ plugin nào điều khiển `proxy_buffering`.**

Route hoàn toàn dựa vào global `nginx_config.http.proxy_buffering:
"off"` (`config-hcm.yaml`/`config-han.yaml`) — nhưng log thực tế cho
thấy response VẪN bị buffer ra `proxy_temp/`. Giả thuyết mạnh nhất (chưa
verify sâu, ghi nhận để điều tra tiếp nếu cần): **`proxy-control` không
chỉ là 1 trong nhiều cách tắt buffering, mà là cách DUY NHẤT thật sự có
hiệu lực** — cơ chế của nó dùng `ngx.exec("@disable_proxy_buffering")`
(redirect nội bộ sang named-location riêng đã patch sẵn `proxy_buffering
off`/`proxy_request_buffering off`), khác hẳn việc chỉ đọc static
directive trong `nginx_config.http`. Route nào không có `proxy-control`
→ nhiều khả năng đang chạy dưới hành vi mặc định của Nginx (`proxy_
buffering on`), bất kể `nginx_config.http` khai gì.

**Mức độ nghiêm trọng:** thấp cho route CMC (UI portal, response
HTML/asset nhỏ — buffer response không gây chậm rõ rệt như PUT file lớn
ở S3). **Không xử lý gấp**, nhưng cần nhớ nguyên tắc này nếu sau này có
route nào cần đảm bảo tắt response-buffering thật sự (VD portal có
download file lớn) — phải thêm `proxy-control` tường minh, không thể
trông chờ global setting.

**Việc cần làm nếu muốn xác nhận chắc chắn giả thuyết trên:** thêm tạm
`proxy-control: { }` (chỉ cần khai plugin, không cần set field nào) vào
route CMC, xem log còn dòng `upstream response is buffered` không. Chưa
làm — ghi nhận hướng điều tra, không tự ý đổi route CMC khi chưa xác
nhận với Mercy (route đang phục vụ UI thật, rủi ro cao hơn route test).

## 🔍 [Bổ sung — 2026-08-14] Đối chiếu lại 5 evidence GỐC ngày 08-10 (Case 2,
## Case 3, `retries:0`) — chưa từng grep 2 loại buffer signature trước đây

Trong suốt case `kafka-logger`/`proxy-control` (điều tra 08-11 → 08-14),
chưa từng quay lại grep 2 string buffer trên chính 5 bộ evidence gốc đã
thu thập ngày `2026-08-10` (Case 2 tắt hẳn, Case 3 mặc định, `retries:0`
+ 9 Safety Gates). Grep lại đầy đủ:

| File evidence (`sb-api6-hcm-1_error.log`) | `a client request body is buffered` | `an upstream response is buffered` |
|---|---|---|
| `qos-warp-20260810-104055` | 0 | 0 |
| `qos-warp-20260810-145223` | 0 | 0 |
| `qos-warp-20260810-152900` (Case 2) | 0 | 0 |
| `qos-warp-20260810-160339` (Case 3) | 0 | 0 |
| `qos-warp-20260810-163157` (`retries:0`) | 0 | 0 |

**0/5 file có bất kỳ dòng buffer nào** — đáng chú ý vì `quota403` dùng
object `2MiB` (PUT lớn, đáng lẽ dễ trigger buffer nhất nếu bug tồn tại
lúc đó, vì `client_body_buffer_size` mặc định Nginx chỉ `8k`-`16k`, một
PUT `2MiB` chắc chắn vượt ngưỡng và phải spill-to-disk NGAY nếu
`request_buffering` không thật sự tắt).

**Ý nghĩa quan trọng:** thu hẹp được mốc thời gian bug bắt đầu xuất hiện
— **KHÔNG tồn tại ngày `2026-08-10`**, chỉ bắt đầu thấy từ `2026-08-11`
(theo bảng đối chiếu evidence đã có ở section trên, dòng đầu tiên ghi
nhận lúc `2026-08-11 11:01:59`). Hướng điều tra tiếp nên tập trung vào
**thứ gì đã đổi giữa 2 mốc `08-10` cuối ngày và `08-11` đầu ngày** (diff
config, restart container, thay đổi hạ tầng khác) thay vì coi đây là bug
luôn tồn tại từ đầu.

## 🔍 [Bổ sung — 2026-08-14] Vị trí dòng (line number) hiện tại — cập nhật
## theo repo mới nhất, dùng để tra nhanh không phải tìm lại

```
apisix_routes/global_rules/global-kafka-logger.yaml       (34 dòng, toàn bộ)
  dòng 3:  # status: 0                    ← comment, nghĩa là ĐANG BẬT
  dòng 26: kafka_topic: "apisix-gateway-${{DC_PROFILE}}"
  dòng 28: batch_max_size: 1
  dòng 31-32: ssl: true / ssl_verify: false

apisix_routes/plugin_metadata/log-format-kafka-logger.yaml
  dòng 1-3: plugin_metadata / id: kafka-logger / log_format: (bắt đầu)

apisix_routes/routes/hyperstore-cloudian/route-cmc.sds.infiniband.vn-https-8443.yaml
  dòng 58: file-logger:
  dòng 60: include_req_body: true
  dòng 61: include_resp_body: true
  → KHÔNG có proxy-control ở bất kỳ dòng nào trong file (xác nhận lại
    phát hiện "Route CMC không có cơ chế tắt response-buffering" ở
    section trên — đối chiếu trực tiếp với output Mercy vừa chạy
    `docker exec ... sed -n '/id: "route-cmc/,/^ - id:/p'` trên
    `sb-s3-lb-api6-hcm-1`, khớp 100% với file trong repo).

apisix_routes/routes/hyperstore-cloudian/route-s3-hcm.sds.infiniband.vn-https-443.yaml
  dòng 17-18: proxy-control: / request_buffering: false
  dòng 34: file-logger:
  dòng 36: include_req_body: true   ← 🔴 XEM PHÁT HIỆN MỚI BÊN DƯỚI
  dòng 37: include_resp_body: true

apisix_routes/routes/hyperstore-cloudian/route-s3-hni.sds.infiniband.vn-https-443.yaml
  dòng 16-17: proxy-control: / request_buffering: false
```

## 🔴 [Nghi vấn MỚI — 2026-08-14, CHƯA verify] `file-logger.include_req_body`
## trên chính route S3 — ứng viên khác ngoài `kafka-logger`

Route `s3-hcm` (và nhiều khả năng `s3-hni`, cùng cấu trúc) có **CẢ 2**
cùng lúc, cùng route:
```yaml
proxy-control:
  request_buffering: false      # dòng 18 — ép KHÔNG buffer
file-logger:
  include_req_body: true        # dòng 36 — ép PHẢI đọc toàn bộ req body
```

Toàn bộ điều tra `08-11`→`08-13` (9 run A/B/C) chỉ tập trung vào
`kafka-logger` (đã xác nhận qua PR #5501: schema mặc định
`include_req_body: false`, và cấu hình hiện tại **không** set field này
cho `kafka-logger` → plugin này không đọc request body) — nhưng **chưa
từng kiểm tra `file-logger` cùng route có field `include_req_body: true`
tường minh**, và bản chất cơ chế đọc request body của `file-logger` để
phục vụ field này rất có thể **cùng gốc xung đột** với
`request_buffering: false` như nghi vấn ban đầu ở Issue #12440 (khác
plugin, nhưng cùng nhu cầu "cần buffer body để log lại nội dung").

**Chưa verify** — cần 1 test tách biệt: tắt tạm `include_req_body` (và/
hoặc cả `include_resp_body`) trên `file-logger` của route `s3-hcm` (giữ
nguyên `kafka-logger`), test lại probe nhỏ 3 lần liên tiếp như đã làm ở
Bước xác nhận `08-13`, xem còn dòng `a client request body is buffered`
không. Đây là hướng điều tra ưu tiên tiếp theo — **cụ thể hơn hẳn** nghi
vấn `kafka-logger` gốc, vì field gây nghi ngờ (`include_req_body`) nằm
**ngay trên chính route đang test**, không phải suy luận gián tiếp qua
`global_rules` như trước.

**Lưu ý quan trọng:** đây cũng chính là field đã bị nghi ngờ và **tắt
hẳn** ở route `s3-hcm` trong 1 đợt điều tra khác cùng ngày `2026-08-10`
(mục "file-logger + kafka-logger drop log dưới tải PUT cao" ở section
trên, đã đề xuất diff comment `include_req_body: true` → nhưng **diff đó
CHƯA được merge/áp dụng thật** — file hiện tại (`2026-08-14`) vẫn còn
nguyên `include_req_body: true` ở dòng `36`). Nếu merge lại đúng diff đã
đề xuất trước đó (tắt `include_req_body` trên `file-logger` route S3),
rất có thể giải quyết được LUÔN cả 2 vấn đề cùng lúc: (1) log rỗng dưới
tải cao, (2) buffering nghi vấn đang điều tra — nên làm đúng thứ tự: áp
diff cũ trước, test lại, mới kết luận có cần điều tra `kafka-logger`
tiếp hay không.


### Bảng nhận diện log-signature — dùng ngay khi đọc `error.log`, không suy luận lại

| Dấu hiệu (string chính xác) | Loại buffer | Thư mục temp | Plugin/directive | Chiều dữ liệu |
|---|---|---|---|---|
| `a client request body is buffered to a temporary file` | **Request** | `/usr/local/apisix/client_body_temp/` | `proxy-control.request_buffering` (route-level, dynamic, dùng `ngx.exec("@disable_proxy_buffering")`) | Client → APISIX (lúc nhận body, VD PUT/POST) |
| `an upstream response is buffered to a temporary file` | **Response** | `/usr/local/apisix/proxy_temp/` | `proxy_buffering` (nginx static directive, `nginx_config.http` — KHÔNG có plugin route-level tương đương đang dùng) | Cloudian → APISIX (lúc nhận response trả về client) |

**Cách đọc nhanh, không nhầm:** nhìn đúng 2 chữ ngay sau `"a"`/`"an"` —
`client request body` = request (client gửi lên) — `upstream response`
= response (backend trả về). 2 message dùng chung cụm `"buffered to a
temporary file"` nhưng nghĩa khác hẳn nhau — đã từng bị nhầm 1 lần trong
quá trình điều tra (08-14, tưởng response-buffer của route CMC là bằng
chứng cho case `kafka-logger`/route S3 — sai, 2 hiện tượng độc lập).

### Đối chiếu nhanh — route nào ra loại buffer nào (theo dữ liệu đã thu thập)

| Route | Loại buffer từng thấy | Có `proxy-control`? |
|---|---|---|
| `s3-hcm.sds.infiniband.vn` (PUT) | Request (`client request body`) | Có — nhưng vẫn buffer (đang điều tra) |
| `cmc.sds.infiniband.vn` (GET UI) | Response (`upstream response`) | **Không có** — dựa hoàn toàn vào `nginx_config.http.proxy_buffering:"off"` global, nghi ngờ KHÔNG đủ hiệu lực nếu thiếu plugin |

### Nơi chỉnh buffer cho từng chiều (đối chiếu repo apache/apisix + docs chính thức):

| Chiều | Directive/Plugin |	Cấp cấu hình | Cách áp dụng |
|---|---|---|---|
|Request (client → APISIX) |	client_body_buffer_size |	nginx_config.http_configuration_snippet (static)	| Restart container
|Request (client → APISIX)	| proxy-control.request_buffering: false	| Route/Service (dynamic, per-route) | Hot-reload, không restart
|Response (upstream → APISIX)	| proxy_buffer_size / proxy_buffers / proxy_busy_buffers_size / proxy_buffering	| nginx_config.http_configuration_snippet (static, toàn cục)	| Restart container
|Response (upstream → APISIX)	| (không có field trong plugin nào của repo mã nguồn mở)	| —	| Không có cơ chế per-route động


| Phân loại | Cấu hình |	Plugin |
|---|---|---|
| REQUEST | on/off	| proxy-control.request_buffering |
| RESPONSE | on/off	| proxy-buffering.disable_proxy_buffering |
| RESPONSE | on/off	| nginx_config.http.proxy_buffering |
| REQUEST | on/off	| nginx_config.http.proxy_request_buffering |
| REQUEST | size | nginx_config.http_configuration_snippet.client_body_buffer_size |
| RESPONSE | size | nginx_config.http_configuration_snippet.proxy_buffer_size/proxy_buffers/proxy_busy_buffers_size |

### Đơn vị — k/K, m/M, g/G: không phân biệt hoa thường, đơn vị nhị phân (1024)

Xác nhận bằng chính bằng chứng thực tế: file config của Mercy dùng lẫn "5120m" (thường) và "16k" (thường) và trước đó có "100G" (hoa) — cả 3 dạng đều hợp lệ trong cùng 1 file, đây là bằng chứng trực tiếp mạnh nhất, không cần tra thêm nguồn nào khác: Nginx parser chấp nhận cả hoa lẫn thường, và:

k/K = 1024 bytes (KiB, dù ký hiệu chỉ viết k)
m/M = 1024k = 1,048,576 bytes (MiB)
g/G = 1024m (GiB)
## 🔧 [Chốt — 2026-08-18] Case buffer body — root cause thật: `client_body_buffer_size`

Đóng hẳn case "Nghi vấn `proxy-control.request_buffering` bị vô hiệu hoá" —
đã trải qua 2 lần "Pass rồi Mở lại" (`08-11`→`08-13`) trước khi tìm đúng.

**Root cause thật**: `client_body_buffer_size` (mặc định Nginx `8k`/`16k`)
quyết định request có bị ghi tạm ra đĩa hay không — **cơ chế độc lập hoàn
toàn** với `request_buffering`/`proxy-control` (2 directive khác nhau).
Field này **không có schema riêng** trong `apisix/cli/config.lua` (khác
`client_max_body_size`) → set trong `nginx_config.http` bị APISIX âm thầm
bỏ qua. Phải dùng `nginx_config.http_configuration_snippet`, và field này
**chỉ có tác dụng khi đặt NGANG CẤP `nginx_config`, không lồng trong
`http:`** (xác nhận qua nhiều vòng thử sai thực nghiệm).

**Đã sửa** (`config-hcm.yaml`/`config-han.yaml`):
```yaml
nginx_config:
  http_configuration_snippet: |
    client_body_buffer_size 32k;
    proxy_buffer_size 16k;
    proxy_buffers 8 16k;
    proxy_busy_buffers_size 32k;
  http:
    proxy_buffering: "on"
    proxy_request_buffering: "on"
```
Global giờ **bật mặc định** (Kịch bản A) — 3 route S3 (`s3-hcm` ×2 domain,
`s3-hni`) tự tắt riêng qua `proxy-control`/`proxy-buffering` trong
`plugin-config-traffic-classifier.yaml`. `cmc`/`hyperiq`/`s3-admin`
(dùng chung `plugin-config-qos-internal-console.yaml`) **giữ nguyên
buffering mặc định** — đúng theo nghiệp vụ (console/API nội bộ, response
nhỏ, không cần streaming), không phải thiếu sót cần xử lý.

**Verify — `3/3` lần PUT `500MB`**: `time_total` = `19.3s / 22.1s / 16.0s`
(cùng bậc baseline "sạch" cũ, cách xa pattern lỗi gốc `58-67s`), Cloudian
xác nhận nhận đủ `524288000` byte mỗi lần.

**Đính chính tiêu chí đánh giá quan trọng** (nguyên nhân khiến case bị
Pass sai 2 lần trước): dòng log `"a client request body is buffered..."`
**KHÔNG PHẢI bằng chứng lỗi** — bình thường khi object vượt buffer, độc
lập với `request_buffering`. Từ nay **chỉ dùng `time_total` của PUT lớn
(≥500MB) làm bằng chứng, không đếm dòng log buffer**.

## 🔧 [Chốt — 2026-08-19] `file-logger.include_req_body` trên route S3 —
## xác nhận đúng là 1 phần nguyên nhân "log rỗng dưới tải cao" (finding
## gốc 08-10) — đã tắt, đã gỡ hẳn `file-logger` khỏi route S3

**Test**: tắt `include_req_body` (giữ `include_resp_body`), bắn lại
`rate503` (concurrent=16, 100 req/s, 75s) — same điều kiện gốc `08-10`.

**Kết quả**: `file-logger` route `s3-hcm` tăng `2,124,645 byte`
(`24,152,093` → `26,276,738`) trong đúng cửa sổ test — **khác hẳn**
finding gốc `08-10` (`0 byte` tăng, `~0.1%` lọt qua). Đếm chính xác theo
`grep -c '<timestamp>-rate503'`: **4170 dòng log** ghi được.

**Đối chiếu quan trọng — 4170 (APISIX) > 1996 (tổng Cloudian 4 node)**:
không mâu thuẫn — APISIX ghi MỌI request qua route kể cả bị chặn ngay
tại gateway (chưa từng tới Cloudian), Cloudian chỉ thấy request thật sự
forward tới nó. Chênh lệch `2174` khớp với số request bị Dynamic QoS
Layer 2 chặn (`[APISIX-QOS:traffic-classifier]`, xem case mới bên dưới).

**Kết luận: `include_req_body:true` xác nhận là nguyên nhân góp phần**
(đọc toàn bộ request body để log → tăng áp lực buffer). `include_resp_body`
KHÔNG phải nguyên nhân (chỉ đọc XML lỗi nhỏ, không đọc data object thô).

**Đã merge — gỡ hẳn `file-logger` khỏi 3 route S3** (không chỉ tắt
`include_req_body`), chuyển hoàn toàn sang `kafka-logger` — đúng mục
tiêu ban đầu case "Không dùng file logger mà dùng kafka logger" (`08-12`).

## 🔴 [Backlog, chưa verify — 2026-08-19] `kafka-logger.include_resp_body`
## đã bật, CHƯA xác nhận có nội dung thật (test bằng response 200, sai
## kịch bản)

**Đã merge**: `global-kafka-logger.yaml` thêm `include_resp_body: true`.
Đồng thời phát hiện `batch_max_size` đã đổi `1` → `100` (không phải đề
xuất — Mercy tự thêm, **cần xác nhận có chủ đích hay nhầm**, có thể ảnh
hưởng độ trễ hiển thị Grafana do gom batch, không ảnh hưởng nội dung).

**Verify lần 1 (`Explore-logs-2026-08-19_15_30_59.txt`)**: `resp_body`
vẫn rỗng — **nhưng đây là ĐÚNG bản chất giao thức**, không phải chưa
fix: request test (`offender probe`) trả `200` (PUT thành công), và
theo chuẩn S3 API, response `PutObject` thành công **luôn có body rỗng**
(chỉ header). Chưa test đúng kịch bản (response lỗi, có XML).

**Việc cần làm tiếp**: bắn 1 request LỖI thật (set quota thấp rồi
`probe`, hoặc `rate503`) → kiểm tra lại Grafana, field `resp_body` phải
có nội dung XML lỗi S3 mới coi là verify xong. Nếu Pass → có thể cân
nhắc gỡ luôn `file-logger` khỏi `route-cmc` (đồng bộ hoàn toàn về
`kafka-logger`, không còn phụ thuộc local disk ở bất kỳ route nào).

## 🔴 [Backlog, mới phát hiện — 2026-08-19] Bộ test `rate503` đang đo lẫn
## 2 tầng QoS cùng lúc — cần tách riêng để đo đúng ý định gốc

`rate503` (`qos-warp-run.sh`) thiết kế ban đầu (`08-10`) chỉ để tái hiện
**Cloudian's own rate-limit** (`503 SlowDown`) — lúc đó **Dynamic QoS
Layer 2 của APISIX chưa tồn tại** (phát triển sau, case "Tính năng mới").

Giờ 2 tầng chạy song song:
```
APISIX Dynamic QoS (Layer 2, plugin-config-traffic-classifier)
  → ngưỡng 300 req/60s (~5 req/s) cho nhóm Authenticated
  → lỗi: [APISIX-QOS:traffic-classifier]
Cloudian's own rate-limit (storage backend)
  → ngưỡng riêng của Cloudian
  → lỗi: 503 SlowDown
```

`rate503` gửi `100 req/s` (`concurrent=16`) — gấp `~20 lần` ngưỡng Layer
2 → **luôn dính Layer 2 trước**, không còn đo được thuần Cloudian's
`503` như thiết kế gốc. Xác nhận qua số liệu `08-19`: `4170` request qua
APISIX nhưng chỉ `1996` tới được Cloudian — `2174` bị Layer 2 chặn sớm.

**Đề xuất, chưa làm**: tạm nới ngưỡng Layer 2 rất cao (hoặc tắt tạm
`plugin-config-traffic-classifier` riêng route `s3-hcm` lúc test) để
tách lại đúng 2 kịch bản độc lập. Đây cũng là case "nới/siết QoS" Mercy
từng đề xuất muốn làm — có thể gộp thực hiện cùng lúc.

## 💡 [Ý tưởng, chưa triển khai — 2026-08-20] Dùng biến động (`${...}` trong
## `count`/`conn`, APISIX 3.16+) thay override per-consumer bằng file riêng

Nguồn: blog chính thức apache/apisix — "What's New in Apache APISIX
3.16: Dynamic Rate Limiting" (https://apisix.apache.org/blog/2026/04/14/apisix-3.16-dynamic-rate-limiting/).
Cộng đồng 3.17, không phải API7 Enterprise.

**Vấn đề hiện tại**: mỗi khi cần override quota riêng cho 1 consumer
(bucket/snat-ip) khác với `consumer_group` gốc, phải tạo nguyên 1 khối
`limit-count` đầy đủ (`rules`, `rejected_msg`, `header_prefix`,
`allow_degradation`, `policy`...) trong file consumer đó — như
`consumer-s3-bucket-thuyldx-qos-group-limit-count-2.yaml` (30 req/60s)
và `consumer-s3-bucket-thuyldx-qos-restricted.yaml` (100 req/60s) đang
làm. Copy nguyên khối chỉ để đổi 1 con số.

**Cơ chế biến động**: từ 3.16, field `count`/`time_window` (limit-count)
và `conn`/`burst` (limit-conn) trong `rules[]` chấp nhận APISIX variable,
kèm cú pháp fallback `?? <default>` (lua-resty-expr) khi biến không tồn
tại. Tách biệt với `key` (quyết định đếm theo AI) — `count` biến động chỉ
quyết định ngưỡng cho phép của đúng key đó.

**Cách áp dụng cho Tầng 3**:
1. `serverless-pre-function` (rewrite phase, chạy trước access phase nơi
   `limit-count` thực thi — đảm bảo header có sẵn kịp lúc) set 1 header
   theo consumer, vd `ngx.req.set_header("X-S3-Qos-Quota", "30")`.
2. Rule chung ở `consumer_group` (viết đúng 1 lần) đổi:
   ```yaml
   limit-count:
     rules:
       - key: "${consumer_name}"
         count: "${http_x_s3_qos_quota ?? 50}"   # 50 = mặc định group gốc
         time_window: 60
         header_prefix: "Lockdown"
   ```
3. Consumer không set header → dùng mặc định `50` của group. Consumer có
   set header → dùng đúng số riêng, không cần khối `limit-count` riêng.

**Trade-off**: đổi 1 số giờ phải sửa đúng chỗ set header (thường trong
`s3-qos-consumer.lua` hoặc file consumer riêng) thay vì đọc thẳng trong
`limit-count` — khó dò hơn khi debug lần đầu nếu không biết cơ chế này.

**Trạng thái**: chưa quyết định triển khai — hiện chỉ có 2-3 case override
(chưa đủ nhiều để đáng đổi kiến trúc). Cân nhắc lại khi số lượng override
per-consumer tăng lên đáng kể.

## ✅ [ĐÃ CHỐT — 2026-08-20] Tầng 1 (global-abuse-guard) đổi từ đếm theo IP
## sang đúng 1 counter global/node — verify bằng traffic thật, PASS

**Vấn đề gốc**: `global-abuse-guard.yaml` dùng `key: remote_addr` — đếm
theo IP, KHÔNG phải "global toàn Instance" như tên gọi và như ý định
thiết kế ghi trong note dòng ~269 ("Global: khóa ở đây là chính Instance
đó, đếm tổng, không phân biệt đối tượng"). Đây là mismatch giữa ý định
thiết kế và implementation thật, tồn tại từ trước.

**Fix — key đổi sang `http_x_node_id`, cả `limit-count` lẫn `limit-conn`
chuyển sang `rules:` (APISIX 3.16+):**
```yaml
global_rules:
  - id: global-abuse-guard
    plugins:
      limit-count:
        rules:
          - key: "${http_x_node_id}"
            count: 50000
            time_window: 60
            header_prefix: "Global"
        rejected_code: 429
        allow_degradation: true
        show_limit_quota_header: true
        policy: local

      limit-conn:
        rules:
          - key: "${http_x_node_id}"
            conn: 49500
            burst: 500
        rejected_code: 429
        default_conn_delay: 0.1
        only_use_default_delay: true
        allow_degradation: true
        policy: local

      serverless-pre-function:
        phase: rewrite
        functions:
          - |
            return function(conf, ctx)
              ngx.req.set_header("X-Node-Id", os.getenv("NODE_ID") or "-")
            end
```

**Vì sao không dùng `$hostname` (nginx core var)** — cách "sạch" hơn về
lý thuyết — **container chạy `network_mode: host`**, và Docker **từ chối**
khai `hostname:` cùng lúc với `network_mode: host` (`conflicting options:
hostname and the network mode`, lỗi tái hiện ở Docker hiện tại, không phải
version cũ). Dùng biến môi trường `NODE_ID` (`docker-compose.yaml`:
`NODE_ID=apisix-standalone-${DC_PROFILE}-${ORDER_NUM}`) qua
`serverless-pre-function` (rewrite phase, priority 10000 — luôn chạy
trước `limit-conn`/`limit-count` ở access phase, đảm bảo header set kịp)
để né hoàn toàn giới hạn này.

**`limit-conn` không có `header_prefix`** (khác `limit-count`) — theo
đúng bảng attributes chính thức (`rules.conn`/`rules.burst`/`rules.key`
only). Không sao vì `limit-conn` vốn không xuất header quota nào ra
response — không có gì để đè/trùng.

### Bug phụ phát hiện giữa chừng — header collision xuyên 3 tầng

`limit-count` không khai `header_prefix` → sinh header phẳng
`X-RateLimit-Limit/Remaining/Reset`. Vì Tầng 1 (`global_rules`) luôn
chạy **cộng dồn** cùng Tầng 3 (`consumer_group`) trên 1 request (không
phải merge/thay thế — 2 plugin instance riêng biệt), tầng nào chạy sau
**ghi đè** header tầng chạy trước — im lặng, không lỗi. Bằng chứng thật:
lúc test global counter, node `apisix-node-dc1` (IP `172.25.216.121`,
resolve thành `snatip-172-25-216-121` → group `incident`) trả về
`X-RateLimit-Remaining: 99` — ban đầu tưởng nhầm là "node khác" (chẩn
đoán sai), sau xác nhận đúng là header Tầng 3 (`incident`, count=100)
đè lên Tầng 1.

**Fix**: thêm `header_prefix` cho **toàn bộ** nơi dùng `limit-count`
không riêng Tầng 1:
- Tầng 1: `header_prefix: "Global"`
- Tầng 2 (`plugin-config-traffic-classifier.yaml`, đã đúng từ trước):
  `Authen`/`AkidOnly`/`Snat-Group`/`Snat-Ip`/`Anon`
- Tầng 3 — 8 consumer_group: `Tier4`/`Tier3`/`Tier2`/`Tier1`/`Boost`/
  `Event`/`Incident`/`Lockdown`
- `plugin-config-qos-auth.yaml`: `QoS-auth` — kèm sửa lại
  `serverless-post-function` đọc đúng tên header có prefix (trước đó
  đọc tên phẳng `X-RateLimit-Remaining`, khi đổi `header_prefix` mà
  quên sửa Lua sẽ làm tính năng warning 50%/20% quota **ngừng hoạt
  động âm thầm**, không log lỗi)
- Consumer override lẻ (`consumers/*.yaml`): mỗi file 1 `header_prefix`
  riêng không trùng ai (`Custom-redis`, `Custom-bucket-thuyldx-qos-restricted`...)

**KHÔNG cần header_prefix** cho `plugin-config-qos-internal-console.yaml`
— `limit-conn` (không xuất header) và `X-RateLimit-Layer: "2"` set qua
`response-rewrite`/Lua thô ở 3 `plugin_config` khác nhau — an toàn vì
`plugin_config` chỉ gắn 1/route, không bao giờ 2 cái chạy chung 1 request
(khác `global_rules`, luôn cộng dồn). `X-RateLimit-Layer` xác nhận là
thiết kế có chủ đích (đặt tên liền kề alphabet `X-RateLimit-*` để dễ
trace khi dump header), không phải bug — giữ nguyên.

**Verify cuối (2026-08-20)** — bắn traffic thật từ 4 nguồn hoàn toàn
khác nhau (`sb-s3-lb-api6-hcm-1`, `sb-s3-lb-api6-hni-1`, `global-lb`,
`apisix-node-dc1`) cùng gọi `s3-hcm.sds.infiniband.vn`:
- `X-Global-RateLimit-Remaining` giảm liên tục **1 dải số duy nhất**
  (`49999 → 49980`) xuyên suốt cả 4 nguồn — đúng 1 counter global/node.
- `apisix-node-dc1` (đã resolve `incident`) hiện đúng `X-Incident-RateLimit-*`,
  không còn đè lên `X-Global-*` nữa.
- `X-Request-Id` (global, xem section trước) mỗi request 1 UUID khác
  nhau, không xung đột gì với header_prefix.

**Case coi như đã đóng** — cả cơ chế đếm lẫn cơ chế header đều đúng
thiết kế, verify bằng traffic thật trên nhiều node/nguồn khác nhau.

### Việc còn treo, chưa xử lý trong case này

- `plugin-config-qos-auth.yaml`: đổi `key` từ `remote_addr` sang
  `"${consumer_name}"` cùng lúc đổi `header_prefix` — khiến rule bị
  **skip hoàn toàn** với request chưa resolve được identity (do
  `rules.key` không tồn tại → rule không chạy, theo đúng docs chính
  thức). Traffic anonymous hiện KHÔNG còn được lưới an toàn 5000 req/s
  này bảo vệ nữa. Chưa xác nhận với Mercy đây có phải chủ đích hay cần
  thêm rule fallback theo `remote_addr`/`real_ip`.
- `plugin-config-qos-internal-console.yaml`: `limit-conn` vẫn giữ format
  cũ (`key_type`/`key`), chưa chuyển `rules:` — không phải bug (không có
  header để đè), chỉ là chưa đồng bộ 100% cách viết với Tầng 1.
- `consumer-s3-snatip-172.27.2.204.yaml`: không có `group_id` → identity
  này hiện không bị áp bất kỳ rate-limit Tầng 3 nào — chưa xác nhận có
  phải whitelist chủ ý hay thiếu sót khi tạo file.

## ✅ [ĐÃ VERIFY — 2026-08-25] Static S3 Consumer không ảnh hưởng route khác

### Phạm vi và cơ chế đã xác nhận

`custom.s3-qos-consumer` là custom auth plugin của riêng S3 dataplane. Route
khai plugin sẽ đọc `ctx.var.remote_addr` và `ctx.s3_bucket_name`, build một
username theo thứ tự `bucketsnat-*` → `bucket-*` → `snatip-*`, rồi gọi
`consumer_mod.attach_consumer()`. Chính lời gọi này mới đặt
`ctx.consumer`/`ctx.consumer_group_id` và làm Consumer hoặc Consumer Group
tham gia merge plugin. Nó không phải policy IP toàn cục và không đến từ
`key-auth`/JWT trong nhánh S3 này.

Vì Route CMC không khai `custom.s3-qos-consumer`, nó không thể attach một
Consumer `snatip-*` chỉ vì request có cùng IP nguồn. Quy tắc này cũng áp dụng
cho mọi route VCR/MAAS sau này, miễn là không bind custom S3 plugin vào route
đó. Tên plugin và namespace `bucket-*`/`snatip-*`/`bucketsnat-*` đã biểu đạt
rõ ownership S3; chưa cần thêm guard label trong Lua ở hiện trạng.

### Bằng chứng runtime

Gateway test: `172.27.2.206`. Từ `sb-s3-lb-1`, APISIX quan sát
`remote_addr=172.27.2.204` ở cả hai request:

| Route gọi | Dấu vết response | Kết luận |
|---|---|---|
| `https://s3-hcm.sds.infiniband.vn/qos-probe-123456789/` | `X-Debug-Consumer-Resolved: snatip-172-27-2-204`; `X-Custom-snatip-172.27.2.204-RateLimit-Limit: 100` | Consumer S3 được resolve và quota override active |
| `https://cmc.sds.infiniband.vn:8443/` | `200`; không có hai header Consumer/Custom rate-limit | Không bị policy `snatip-*` của S3 ảnh hưởng |

Test từ `global-lb` không match `snatip-172-27-2-204` vì APISIX thực tế quan
sát `remote_addr=172.25.216.164`; đây là expected. `ctx.var.remote_addr` hiện
là peer/source IP APISIX quan sát; repo chỉ load `real-ip` trong danh sách
plugin, chưa bind cấu hình `real-ip` trên Route/Plugin Config/Global Rule.
Chỉ khi bind `real-ip` với `trusted_addresses` đúng, giá trị này mới được
rewrite theo header/proxy source được tin cậy.

### Quy tắc đọc header và log (tránh retest/suy luận sai)

- `X-Global-RateLimit-*` có ở cả S3 và CMC là đúng: `global-abuse-guard` áp
  cho mọi route như ceiling của gateway node.
- `X-RateLimit-Layer: 2` trên CMC không phải Layer 2 S3. Nó do
  `plugin-config-qos-internal-console` tự set; profile này có `limit-conn`
  độc lập theo `remote_addr` với ngưỡng 4500 connections/IP. `ip-restriction`
  trong profile CMC vẫn comment.
- Access log hiện có thể ghi `consumer:"-"` ngay cả request S3 đã resolve.
  Global `serverless-pre-function` ghi request header `X-Consumer` trước khi
  plugin local `s3-qos-consumer` gọi `attach_consumer()`, nên giá trị log bị
  chốt sớm. Bằng chứng authoritative cho Static S3 Consumer là
  `X-Debug-Consumer-Resolved` và `X-Custom-...-RateLimit-*`, không phải field
  `consumer` trong access log hiện tại.

### Vận hành

`snatip-*` khớp chính xác một địa chỉ đã chuẩn hóa, không match CIDR. Nó vẫn
có thể bao phủ nhiều người dùng nếu chính IP đó là một SNAT/LB shared. Khi
cần siết/nới đúng một bucket từ một egress cụ thể, ưu tiên
`bucketsnat-<bucket>-<ip>`; không dùng `snatip-*` để đại diện một khách hàng
trong NAT shared.

Runbook kiểm chứng tối thiểu: từ source IP đã đăng ký, gọi một S3 route và
một non-S3 route cùng gateway; Consumer headers chỉ được phép xuất hiện tại
S3. Không cần tạo tải để ép 429. Nếu một non-S3 route xuất hiện
`X-Debug-Consumer-Resolved` hoặc `X-Custom-snatip-...-RateLimit-*`, coi là
regression: kiểm tra ngay plugin binding của route đó.

---

## Cert qua Vault — cơ chế đúng (đính chính toàn bộ, 27/08/2026)

> Mục này viết SAU khi test thật trên cụm ProxyHub (repo
> `apisix-standalone-vnpay-proxyhub`, cùng version APISIX 3.17.0-debian) —
> đính chính 3 chỗ sai ở trên (`secret_providers` sai file, option 2/3 sai
> cách hiểu). Cụm S3-storage **chưa kích hoạt Vault cho SSL thật** (4 file
> `ssls/` vẫn dùng placeholder `<PASTE_CONTENT_OF_...>`), nên đây là đính
> chính **phòng ngừa** — tránh lặp lại đúng bug đã tốn thời gian điều tra ở
> ProxyHub khi cụm này bật Vault thật sau này.

### Root cause bug `PEM_read_bio_X509_AUX() failed` — không phải bug APISIX/version

Đã trace source `apisix/core/config_yaml.lua` (dòng 491-494, 228) + đối chiếu
doc chính thức Apache APISIX
(`docs/en/latest/terminology/secret.md`, mục Standalone mode):

- APISIX Standalone chỉ đọc cơ chế Secret từ top-level key **`secrets:`**
  (số nhiều) trong file **dynamic resources** (`apisix-{DC_PROFILE}.yaml`) —
  KHÔNG phải `config-{DC_PROFILE}.yaml`.
- Đặt `secret_providers:` trong `config.yaml` (như note gốc ở trên từng mô
  tả) → object `/secrets` nội bộ luôn rỗng → `$secret://vault/...` không
  resolve được → APISIX fallback lấy CHÍNH CHUỖI LITERAL làm giá trị field →
  chuỗi đó (không phải PEM) bị đưa thẳng vào `ngx_ssl.parse_pem_cert()` →
  `PEM_read_bio_X509_AUX() failed`.

### Cách khai đúng

Tạo file mới `apisix_routes/secrets/vault-provider.yaml` (cùng cấp
`ssls/`, `routes/`, `upstreams/` — resource type mới, `merge-fragments.sh`
**chưa hỗ trợ sẵn**, phải patch thêm `secrets` vào `VALID_KEYS`/
`validate_block_dir`/`append_block`, xem patch mẫu ở RUNBOOK.md):

```yaml
secrets:
  - id: "vault/vault-provider"
    uri: "${{VAULT_ADDR}}"
    prefix: "cloud/profile"
    token: "${{VAULT_TOKEN}}"
```

`prefix` **chỉ được là mount** (`cloud/profile`), không phải cả path — patch
[3/5] (`vault.lua`, đã có sẵn trong `1-patch-template-lua.sh` của cụm này)
chèn `/data/` ngay sau `conf.prefix`, đúng chuẩn Vault KV v2
(`<mount>/data/<path>`) chỉ khi `prefix` dừng đúng ở mount.

SSL object (`apisix_routes/ssls/ssl-*.yaml`) tham chiếu:
```yaml
cert: "$secret://vault/vault-provider/app/apisix/certs/<domain>/cert"
key:  "$secret://vault/vault-provider/app/apisix/certs/<domain>/key"
```
Format chuẩn `$secret://$manager/$id/$secret_name/$key` — `app/apisix/certs`
đúng namespace của cụm S3-storage (khác `app/apisix-proxyhub/certs` của
ProxyHub — 2 cluster, 2 namespace riêng, đã tách từ đầu).

### Call chain thật (đã trace, xác nhận resolve TRONG `ssl_phase`)

```
apisix/init.lua:182-190 ssl_phase()  (bind vào nginx ssl_certificate_by_lua_block)
  → router.router_ssl.set()
apisix/ssl/router/radixtree_sni.lua:246
  → secret.fetch_secrets(matched_ssl.value, true)
  → dispatch qua apisix/secret.lua → apisix/secret/vault.lua (đã patch KV v2)
```

### Refresh cert mới — KHÔNG cần restart

`apisix/secret.lua` có lrucache riêng (biến `secrets_cache`), **2 loại TTL
khác nhau**:
```lua
local ttl = ... or 300        -- cache khi fetch THÀNH CÔNG (mặc định 300s)
local neg_ttl = ... or 60     -- cache khi fetch THẤT BẠI (mặc định 60s)
```
Đã đo thật trên ProxyHub (bơm cert hỏng lên Vault, đối chiếu timestamp Vault
vs log APISIX): refresh tự động trong **~60s–300s**, không có kịch bản nào
cần thao tác thủ công/restart trên VM để nhận cert mới sau khi cập nhật trên
Vault.

### Vận hành — xem RUNBOOK.md

Toàn bộ lệnh check/fix/renew cert qua Vault (kể cả script
`push-cert-to-vault.sh` đầy đủ) nằm ở `RUNBOOK.md`, mục "Cert qua Vault" —
không lặp lại ở đây (note này là tài liệu giải thích/quyết định, không phải
runbook thao tác).
