# Chiến lược Rate-Limit / QoS đa layer — APISIX Gateway

*APISIX 3.15.0 · Standalone · HCM & HAN*

Bản đồ đầy đủ 7 layer cấu hình ảnh hưởng tới rate-limit/quota trong gateway, theo **đúng thứ tự merge thật
của APISIX** — không phải sơ đồ lý thuyết, mà lấy từ cấu hình đang chạy thật của hệ thống S3 gateway
(Cloudian HyperStore + Ceph) tại 2 datacenter.

- **Nguồn:** `apisix-hcm.yaml` / `apisix-han.yaml`
- **Cơ chế merge:** `apisix/plugin.lua`
- **Cập nhật:** 2026-07-22 (xác nhận qua bộ test request thật, xem mục 03)

---

## 00 — Mối quan hệ giữa các đối tượng
### Nguyên tắc tham chiếu, bảng ma trận 9 đối tượng, và schema YAML đầy đủ

#### Nguyên tắc: chỉ tham chiếu 1 chiều — con giữ ID trỏ lên cha, không cha nào giữ danh sách ID con

APISIX không có entity nào lưu "danh sách ID con". Chỉ **3 đối tượng** giữ field trỏ ra ngoài — mọi đối
tượng còn lại là **lá** (được trỏ tới, hoặc hoạt động độc lập không cần liên kết gì):

- **Route** giữ 3 ID: `service_id`, `upstream_id`, `plugin_config_id` — cả 3 optional, dùng cái nào cũng
  được, không loại trừ nhau (Route override thắng Service nếu khai cả hai).
- **Service** giữ 1 ID: `upstream_id`.
- **Consumer** giữ 1 ID: `group_id`.
- **Plugin Config, Upstream, Consumer Group, SSL, Global Rule** — không entity nào trong 5 cái này có field
  trỏ ra ngoài. Chúng chỉ *được trỏ tới*, hoặc hoạt động độc lập hoàn toàn (SSL match qua SNI, Global Rule
  áp tự động mọi request).

#### Bảng ma trận tham chiếu (FROM → TO)

| FROM \ TO | Route | Service | Upstream | Plugin Config | Consumer | Consumer Group | SSL |
|---|---|---|---|---|---|---|---|
| **Route →** | — | N:1 qua `service_id` | N:1 qua `upstream_id` (bỏ qua Service) | N:1 qua `plugin_config_id` | — không có field | — không có field | — (SNI độc lập, không FK) |
| **Service →** | *(được Route trỏ tới)* | — | N:1 qua `upstream_id` | — | — | — | — |
| **Upstream →** | *(được trỏ tới)* | *(được trỏ tới)* | — | — | — | — | — |
| **Plugin Config →** | *(được trỏ tới)* | — | — | — | — | — | — |
| **Consumer →** | — | — | — | — | — | N:1 qua `group_id` | — |
| **Consumer Group →** | — | — | — | — | *(được trỏ tới)* | — | — |
| **SSL →** | — | — | — | — | — | — | — |

#### `plugins` — không phải entity có ID riêng, mà là "khả năng đính kèm"

6 đối tượng có field `plugins: {}` để đính kèm plugin instance: **Route, Service, Consumer, Consumer Group,
Plugin Config, Global Rule**. Riêng **Upstream** và **SSL** — schema không có field này, không bao giờ chạy
plugin được.

---

### Schema YAML đầy đủ — 9 cấu hình, ghi rõ bắt buộc/optional và mảng/duy nhất

#### 1. Consumer
```yaml
consumers:
  - username: "string"          # BẮT BUỘC · duy nhất · pattern ^[a-zA-Z0-9_-]+$ — khóa chính, unique toàn instance
    desc: "string"              # optional · duy nhất
    labels:                     # optional · object (key-value map, KHÔNG phải mảng)
      team: "platform"
    group_id: "string"          # optional · duy nhất · FK -> consumer_group.id
    plugins:                    # optional · object — map { <plugin_name>: <config> }, nhiều plugin cùng lúc
      key-auth:
        key: "string"
```

#### 2. Consumer Group
```yaml
consumer_groups:
  - id: "string"                # optional (auto-gen nếu bỏ trống) · duy nhất
    desc: "string"               # optional · duy nhất
    labels: {}                   # optional · object
    plugins:                     # optional theo schema, nhưng là LÝ DO TỒN TẠI của entity — de facto bắt buộc
      limit-count:
        count: 4000
        time_window: 1
```

#### 3. Route
```yaml
routes:
  - id: "string"                 # optional (auto-gen) · duy nhất
    uri: "string"                 # 1-trong-2 với uris, BẮT BUỘC · duy nhất
    uris: ["string", "string"]    # 1-trong-2 với uri · MẢNG — khớp nhiều URI cho cùng 1 route
    name: "string"                # optional · duy nhất
    desc: "string"                # optional · duy nhất
    host: "string"                 # 1-trong-2 với hosts, optional · duy nhất
    hosts: ["a.com", "b.com"]      # 1-trong-2 với host, optional · MẢNG
    methods: ["GET", "POST"]       # optional · MẢNG
    priority: 0                    # optional · duy nhất (int) — route matching priority, số CAO match trước khi trùng uri
    vars:                          # optional · MẢNG CỦA MẢNG — [[var, operator, val], ...]
      - ["arg_name", "==", "value"]
    service_id: "string"           # optional · duy nhất · FK -> service.id (N:1)
    upstream_id: "string"          # optional · duy nhất · FK -> upstream.id, bỏ qua Service (N:1)
    upstream: {}                   # optional · object inline — thay thế upstream_id, không dùng đồng thời
    plugin_config_id: "string"     # optional · duy nhất · FK -> plugin_config.id (N:1)
    plugins: {}                    # optional · object
    labels: {}                     # optional · object
    enable_websocket: false        # optional · duy nhất (bool)
    status: 1                      # optional · duy nhất (int, 1=enable/0=disable)
    timeout:                       # optional · object — override timeout của upstream
      connect: 15
      send: 15
      read: 15
    filter_func: "string"          # optional · duy nhất — Lua function tùy biến điều kiện match
```

#### 4. Plugin Config
```yaml
plugin_configs:
  - id: "string"                # optional (auto-gen) · duy nhất
    desc: "string"               # optional · duy nhất
    labels: {}                   # optional · object
    plugins:                     # de facto BẮT BUỘC (lý do tồn tại entity) · object
      ip-restriction:
        whitelist: ["127.0.0.0/24"]
```

#### 5. Service
```yaml
services:
  - id: "string"                # optional (auto-gen) · duy nhất
    name: "string"                # optional · duy nhất
    desc: "string"                # optional · duy nhất
    upstream_id: "string"         # optional · duy nhất · FK -> upstream.id (N:1)
    upstream: {}                  # optional · object inline — thay thế upstream_id
    plugins: {}                   # optional · object
    labels: {}                    # optional · object
    hosts: ["a.com"]               # optional · MẢNG
    enable_websocket: false        # optional · duy nhất (bool)
```

#### 6. Upstream
```yaml
upstreams:
  - id: "string"                 # optional (auto-gen) · duy nhất
    nodes:                        # BẮT BUỘC (trừ khi dùng service_name+discovery_type) · object HOẶC mảng — 2 format tương đương
      "10.0.0.1:8080": 1          #   format object: key = "host:port", value = weight
    # nodes:                      #   HOẶC format mảng — dùng khi cần field port/weight tường minh:
    #   - host: "10.0.0.1"
    #     port: 8080
    #     weight: 1
    type: "roundrobin"            # optional · duy nhất (enum roundrobin/chash/ewma/least_conn)
    hash_on: "vars"                # optional · duy nhất — bắt buộc nếu type=chash
    key: "remote_addr"             # optional · duy nhất — bắt buộc nếu type=chash
    scheme: "http"                 # optional · duy nhất (default http)
    pass_host: "pass"              # optional · duy nhất (enum pass/node/rewrite)
    upstream_host: "string"        # optional · duy nhất — dùng khi pass_host=rewrite
    retries: 1                     # optional · duy nhất (int)
    timeout:                       # optional · object
      connect: 15
      send: 15
      read: 15
    checks:                        # optional · object — health check (active/passive)
      active: {}
    tls:                           # optional · object — mTLS lên upstream
      client_cert: "string"
      client_key: "string"
    name: "string"                 # optional · duy nhất
    desc: "string"                 # optional · duy nhất
    labels: {}                     # optional · object
    # ⚠ KHÔNG có field `plugins` — schema không hỗ trợ, entity "lá" thuần LB/TLS/health-check
```

#### 7. SSL
```yaml
ssls:
  - id: "string"                 # optional (auto-gen) · duy nhất
    cert: "string"                # BẮT BUỘC · duy nhất — PEM public cert
    key: "string"                  # BẮT BUỘC · duy nhất — PEM private key
    sni: "string"                   # 1-trong-2 với snis, BẮT BUỘC · duy nhất
    snis: ["a.com", "*.b.com"]      # 1-trong-2 với sni · MẢNG — 1 cert phủ nhiều SNI
    certs: ["string"]               # optional · MẢNG — multi-cert cùng SNI (vd cặp RSA+ECC)
    keys: ["string"]                # optional · MẢNG — đi kèm certs
    client:                         # optional · object — bật mTLS (verify client cert)
      ca: "string"
      depth: 10
      skip_mtls_uri_regex: ["string"]
    type: "server"                  # optional · duy nhất (enum server/client, default server)
    ssl_protocols: ["TLSv1.2", "TLSv1.3"]   # optional · MẢNG
    status: 1                       # optional · duy nhất
    labels: {}                      # optional · object
    # ⚠ KHÔNG có field `plugins` — không chạy plugin, chỉ phục vụ TLS handshake
    # ⚠ KHÔNG có field trỏ route_id/service_id — match độc lập qua snis so khớp SNI thật
```

#### 8. Global Rule
```yaml
global_rules:
  - id: "string"                 # optional (auto-gen) · duy nhất
    plugins:                      # de facto BẮT BUỘC (lý do tồn tại entity) · object
      limit-conn:
        conn: 10000
        burst: 500
        key: "remote_addr"
    # ⚠ KHÔNG có field nào trỏ route/service cụ thể — áp TỰ ĐỘNG cho MỌI request, chạy song song (không merge)
```

#### 9. Plugins (field đính kèm — không phải entity độc lập có ID riêng)
```yaml
# Cấu trúc CHUNG lặp lại trên 6 entity: Route, Service, Consumer, Consumer Group, Plugin Config, Global Rule
plugins:                          # object — map { <tên-plugin>: <config riêng của plugin> }
  <tên-plugin-1>:                  # key = tên plugin (string), PHẢI khớp tên đã đăng ký trong config.yaml
    <field riêng của plugin>: ...  # nội dung do schema riêng từng plugin quyết định
    _meta:                         # optional · object — field chung, áp được cho MỌI plugin
      disable: false               #   optional · duy nhất (bool) — tắt tạm plugin mà không xóa config
      priority: 1020                #   optional · duy nhất (int) — override execution priority mặc định
      filter:                       #   optional · MẢNG — điều kiện chạy plugin (cú pháp giống vars của route)
        - ["arg_name", "==", "value"]
      error_response: {}            #   optional · object — response tùy biến khi plugin lỗi
  <tên-plugin-2>: {}
# ⚠ KHÔNG BAO GIỜ xuất hiện trên: Upstream, SSL
```

---

## 01 — Nguyên tắc nền
### Thứ tự override khi 2 layer cùng khai 1 plugin

Khi cùng một tên plugin (vd `limit-count`) xuất hiện ở nhiều layer, APISIX chỉ chạy **một bản duy nhất** —
bản ở layer có precedence cao nhất thắng. Đây là chuỗi 5 layer tham gia merge:

```
Consumer  >  Consumer Group  >  Route  >  Plugin Config  >  Service
                                                    (trái thắng phải, cùng tên plugin)
```

Hai thành phần **không** nằm trong chuỗi này:
- **Global Rules** — chạy *song song*, không bị đè, cùng tên plugin thì **cả hai đều chạy tuần tự** (không
  phải merge).
- **Upstream** — schema không có field `plugins`, chỉ thuần LB/health-check/TLS, không tham gia rate-limit
  ở layer này.

---

## 02 — Chi tiết 7 layer
### Từ Global Rules xuống Upstream

Mỗi layer: cơ chế đang dùng thật, ví dụ thật trong hệ thống, và trạng thái (đang enforce hay chỉ quan sát).

### ∞ Global Rules — *song song, mọi route* — **ĐANG ENFORCE**

Trần cứng bảo vệ toàn hệ thống — áp cho **mọi** request, kể cả route không có plugin_config riêng (vd 2
route LAB Ceph).

| Plugin | Giá trị |
|---|---|
| `global-abuse-guard` → `limit-conn` | key=`remote_addr` · conn=10000 · burst=500 |
| `global-abuse-guard` → `serverless-pre-function` | rewrite phase |
| `global-kafka-logger` | audit trail, không phải QoS |

### 1️⃣ Consumer — *precedence cao nhất* — 3 bucket đã đăng ký

Resolve qua **tên bucket** (không phải AKID/SigV4 — backend Cloudian/Ceph đã tự lo phần đó). Chỉ bucket đã
đăng ký thủ công mới có Consumer, còn lại rơi xuống layer dưới.

| Bucket | Group |
|---|---|
| `bucket-thuyldx-qos-restricted` | → `s3bucket-restricted` |
| `bucket-thuyldx-qos-partner` | → `s3bucket-partner` |
| `bucket-thuyldx-qos-internal` | → `s3bucket-internal` |

### 2️⃣ Consumer Group — *policy dùng chung theo nhóm* — **ĐANG ENFORCE — xác nhận qua test thật**

3 nhóm theo **mức độ tin cậy** của bucket. **Đã chuyển sang enforcement thật** — xác nhận qua 2 lần chạy đối
chứng trước/sau bật (22/07): trước bật, mọi request qua bình thường (200/204); sau bật, đúng hành vi chặn
xuất hiện, có bằng chứng log Cloudian lẫn APISIX.

| Nhóm | Cơ chế |
|---|---|
| `s3bucket-restricted` | `ip-restriction` (blacklist IP) — chặn TUYỆT ĐỐI, kể cả request ẩn danh, không giới hạn tốc độ |
| `s3bucket-partner` | `limit-conn/count` 4 / 4 req/s theo `consumer_name` |
| `s3bucket-internal` | `limit-conn/count` 2 / 2 req/s theo `consumer_name` — thấp nhất, dễ chạm nhất |
| cả 3 nhóm | `response-rewrite` → header `X-Debug-Consumer-Resolved` (vẫn giữ, dùng debug/verify resolve đúng bucket) |

> ⚠ Ngưỡng partner/internal (4 và 2 req/s) đặt **rất thấp có chủ đích** — phục vụ quan sát hành vi chặn
> trong 1 lần test ngắn, khác hẳn con số "dự kiến" ban đầu (4000/20000). **Chưa phải ngưỡng production cuối
> cùng** — cần hiệu chỉnh lại theo traffic thật trước khi coi là chính thức.

### 3️⃣ Route — *plugin custom bind ở đây* — 3 route dataplane × 2 DC

Route quyết định request có được **resolve consumer hay không** — plugin chỉ chạy nếu bind đúng ở đây, đăng
ký trong `config.yaml` thôi chưa đủ.

**Quy tắc priority (khác hẳn quy tắc override ở mục 01):** đây là plugin execution priority trong CÙNG 1
route/phase, không phải merge — **số càng CAO chạy càng TRƯỚC** (10005 chạy trước 9500, chạy trước 2510),
không liên quan gì tới precedence Consumer > Route ở trên.

| Thứ tự | Plugin | Priority | Vai trò |
|---|---|---|---|
| 1️⃣ đầu tiên (số cao nhất) | `custom.s3-normalizer-bucket-name` | 10005 | parse bucket từ URI |
| 2️⃣ sau đó | `custom.s3-bucket-name-consumer` | 9500 | resolve Consumer (cần bucket đã parse ở bước trên) |
| 3️⃣ cuối cùng (số thấp nhất) | `custom.s3-accesskey-extractor` | 2510 | trích AKID, giờ chỉ add-on (khoá limit-count thật đã đổi sang bucket) |

### 4️⃣ Plugin Config — *QoS bundle theo workload* — 3 bundle theo workload

Policy **mặc định** áp cho **bucket** chưa đăng ký Consumer riêng — đa số traffic thật đi qua layer này.
Nhiều route dùng chung 1 bundle. **Đã đổi khoá đếm từ AKID sang tên bucket** — AKID giờ chỉ còn vai trò
add-on phân loại anonymous/authenticated trong log.

| Bundle | Giá trị |
|---|---|
| `plugin-config-qos-sdk` | `limit-count/conn` 5.000 / 5.000 theo TÊN BUCKET · AKID chỉ add-on (đổi từ 4000/s theo AKID) |
| `plugin-config-qos-auth` | dùng chung IAM/STS/SQS — giữ shared-quota Redis, khoá theo `remote_addr` |
| `plugin-config-qos-internal-console` | CMC/S3-Admin — traffic nội bộ |

### 5️⃣ Service — *precedence thấp nhất* — không mang QoS plugin

1:1 với upstream vật lý (đổi từ kiến trúc cũ gộp nhiều upstream theo QoS-tier). **Không chứa QoS plugin**
trong thiết kế hiện tại — mọi rate-limit đã chuyển hết lên Plugin Config để tách rõ trách nhiệm.

| Service | Vai trò |
|---|---|
| `service-upstream-s3hcm / s3hni / cmc / iam / sqs / hyperiq / s3admin` | thuần routing → `upstream_id` |

### ∅ Upstream — *ngoài chuỗi merge*

Schema không có field `plugins` — không thể gắn rate-limit ở đây dù muốn. Chỉ load balancing,
health-check, TLS tới backend.

**Chú giải màu (bản HTML):** Consumer · Consumer Group · Route · Plugin Config · Service · Global Rules
(song song) · Upstream (không có plugin).

---

## 03 — Ví dụ thật, đã kiểm chứng bằng log
### 1 request đi qua bao nhiêu layer?

`PUT /thuyldx-qos-restricted/.../sample.txt-restricted` tới `s3-hcm.sds.infiniband.vn` — chạy thật ngày
22/07 (RUN `qos-warp-20260722-100603`), SAU khi bật enforcement. Thứ tự thực thi thật (rewrite phase theo
priority, sau đó access phase merge).

| # | Layer | Diễn biến |
|---|---|---|
| 01 | **GLOBAL** | `limit-conn` theo `remote_addr`, ngưỡng `10000` — chạy trước tiên, độc lập route nào. → **PASS**, ngưỡng rất rộng, hầu như không bao giờ chạm |
| 02 | **ROUTE** | `s3-normalizer-bucket-name` (priority 10005) parse URI → `ctx.s3_bucket_name = "thuyldx-qos-restricted"` |
| 03 | **CONSUMER** | `s3-bucket-name-consumer` (priority 9500) lookup `bucket-thuyldx-qos-restricted` → match → `attach_consumer()` → `ctx.consumer_group_id = "consumer-group-s3bucket-restricted"`. → merge nhảy lên nhánh Consumer/Consumer Group cho các plugin trùng tên |
| 04 | **ROUTE** | `s3-accesskey-extractor` (priority 2510) đọc AKID từ SigV4 header → `ctx.s3_access_key` (chỉ add-on debug/log — **không** dùng làm key cho limit-count nữa) |
| 05 | **MERGE** | `plugin-config-qos-sdk` có `limit-count/conn` theo **bucket** (5000/5000) — nhưng đây là plugin **khác tên** với `ip-restriction` của Consumer Group, nên **không xảy ra override** — cả hai cùng chạy. limit-count theo bucket PASS (traffic thấp), nhưng `ip-restriction` từ Consumer Group (bước 06) mới là bên quyết định cuối. → 2 cơ chế chạy song song, không phải "cái sau đè cái trước" |
| 06 | **CONSUMER GROUP** | `ip-restriction` của `consumer-group-s3bucket-restricted` so khớp `remote_addr = 10.3.14.41` với blacklist → **khớp** → chặn ngay, trả `403`, response chứa `X-Debug-Consumer-Resolved: bucket-thuyldx-qos-restricted`. Song song, `response-rewrite` (không trùng tên plugin nào khác → luôn cộng dồn) vẫn gắn header debug đó bất kể pass hay chặn. → Kết quả thật: **403**, chưa từng chạm Cloudian (grep 4 node Cloudian → 0 dòng) |

**Kết luận:** request này đi qua **5/7 layer** có tác động thật (Service/Upstream không có plugin nên không
tính). Khác bản case study cũ (13/07, lúc Consumer Group còn soft-mode) — lần chạy này `ip-restriction` đã
**thật sự chặn**, xác nhận bằng đối chứng trước/sau: cùng request y hệt, TRƯỚC khi bật trả `200` (ghi thành
công), SAU khi bật trả `403`. Đây chính là giá trị thiết kế Consumer/Consumer Group nằm trên Plugin Config:
cho phép **override/bổ sung có chủ đích** cho một tập nhỏ bucket, không đụng gì tới policy mặc định của
phần còn lại.

---

## 04 — Đã va vào thực tế
### 6 cạm bẫy khi thiết kế đa layer

Rút ra trong quá trình build/debug hệ thống này — không phải lý thuyết chung chung.

**1. Global Rules — Double-apply là thiết kế, không phải bug**
Cùng `limit-conn` ở cả Global (10000, trần cứng toàn hệ thống) và Plugin Config (500, dial riêng từng
service) — cả hai chạy song song thật sự, không merge. Có chủ đích: global bảo vệ những route *không có*
plugin_config riêng (vd route LAB).

**2. Đăng ký ≠ Kích hoạt — Khai trong `config.yaml` chưa chắc plugin đã chạy**
Plugin đăng ký trong `plugins:` list của `config.yaml` chỉ nghĩa là APISIX *load được* file. Phải bind rõ
ràng vào `plugins:` của route thì `rewrite()` mới thật sự thực thi mỗi request.

**3. Priority ≠ Port ≠ Route priority — 3 khái niệm trùng tên, độc lập nhau**
Plugin execution priority (thứ tự trong 1 phase), route matching priority (thứ tự match route), và số port
của upstream node — 3 con số hoàn toàn khác namespace, dễ nhầm khi đọc log/config nhanh.

**4. Consumer namespace — `username` unique toàn instance**
Không tách theo plugin/route. Consumer sinh từ tên bucket bắt buộc prefix (`bucket-<tên>`) để không đè nhầm
consumer control-plane cùng tên — full-replace theo username trong standalone mode, không merge field.

**5. `attach_consumer()` — Tham số thứ 3 phải là config gộp, không phải config riêng lẻ**
Truyền nhầm config của 1 plugin instance (rỗng, không có `conf_version`) thay vì cấu trúc gộp từ
`consumer_mod.plugin()` → APISIX core crash 500 ở bước merge, chỉ lộ ra khi Consumer resolve thành công —
im lặng lúc test case chưa match.

**6. YAML — dấu ngoặc kép thừa — `message":` thay vì `message:`, key bị hiểu sai, không lỗi cú pháp**
Dòng `message": "..."` (dư 1 dấu `"` ngay sau tên field) không làm APISIX từ chối merge — YAML hợp lệ về cú
pháp, chỉ là tên field bị hiểu thành `message"` (kèm dấu ngoặc kép), khác field `message` thật plugin đọc.
Hậu quả: client luôn nhận message MẶC ĐỊNH của plugin, message tuỳ biến âm thầm không bao giờ được dùng —
chỉ phát hiện được bằng cách đọc response body thật, không thể thấy qua review YAML hay qua log lỗi.

---

*APISIX Standalone · sandbox HCM/HAN · tài liệu nội bộ, không phục vụ mục đích public-facing*
