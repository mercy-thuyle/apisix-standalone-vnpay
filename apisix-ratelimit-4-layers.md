# Bốn tầng Rate-Limit của APISIX đang bảo vệ hệ thống S3

Giải thích chi tiết từng tầng chặn — tầng nào đứng ở đâu, chặn cái gì, giá trị hiện tại là bao nhiêu, tại
sao con số đó được chọn — kèm ví dụ thật lấy từ bộ test QoS 403/503 (17–20/07/2026). Bản HTML song hành:
`apisix-ratelimit-4-layers.html` (có highlight, giao diện trực quan hơn).

---

## 00. Trước tiên — vì sao cần tới 4 tầng, không phải 1?

Hệ thống S3 giống một toà nhà văn phòng nhiều lớp bảo vệ: bảo vệ cổng khu (chặn người lạ hoàn toàn), bảo
vệ sảnh mỗi công ty (chỉ cho đúng người vào, giới hạn mang đồ), bảo vệ riêng trước phòng họp VIP (quy tắc
riêng theo khách). Nhưng trước khi ba lớp bảo vệ đó làm việc được, phải có **lễ tân** đứng ở cửa hỏi "anh/chị
tới gặp ai" — không có quyền từ chối, chỉ ghi nhận thông tin để chuyển cho các lớp phía sau.

Bốn lớp này bổ sung cho nhau, không thay thế: **Global Rules** (mọi request, mọi route), **Plugin Config**
(gán cho nhiều route, dùng chung chính sách), **Consumer/Consumer Group** (theo danh tính — ở đây là tên
bucket), và **plugin khai tại Route** (vai trò lễ tân — trích xuất thông tin, không tự chặn). Thứ tự merge
của APISIX: **Consumer > Consumer Group > Route > Plugin Config > Service** — càng cụ thể, càng ưu tiên cao.

---

## 00b. Khái niệm nền — "connection" khác "request" ở chỗ nào

Trước khi đọc tiếp, cần phân biệt rạch ròi hai đại lượng mà mọi tầng chặn phía dưới đều đo — vì chúng trả lời
hai câu hỏi hoàn toàn khác nhau.

**`limit-conn` — đếm connection đang mở đồng thời (concurrency, "song song").** Giống một quầy phục vụ: đếm
"ngay bây giờ có bao nhiêu người đang đứng trước quầy", không quan tâm họ đứng bao lâu. Với object storage,
đây là con số đặc biệt quan trọng: khi client PUT một object 5GB, connection đó **giữ mở suốt thời gian
truyền** — có thể vài phút. Nếu 50 client cùng lúc upload file lớn, dù throughput nhìn có vẻ thấp (1-2
request/giây vì mỗi request kéo dài), hệ thống vẫn đang gánh **50 connection mở song song** — con số phản ánh
đúng mức độ bão hoà tài nguyên thật (CPU, RAM, file descriptor, băng thông) tại một thời điểm.

**`limit-count` — đếm số request hoàn tất trong một khoảng thời gian (throughput, "lưu lượng").** Vẫn quầy
phục vụ đó, nhưng đếm "trong 1 giây qua, tổng cộng bao nhiêu người đã được phục vụ xong". Hai object nhỏ 1KB
xử lý xong trong 1ms mỗi cái đóng góp 2 vào con số này; một object 5GB mất 3 phút chỉ đóng góp đúng 1, dù nó
"chiếm chỗ" (connection) lâu hơn rất nhiều.

Vì hai đại lượng đo hai chiều rủi ro khác nhau — `limit-conn` bắt được "quá nhiều connection treo cùng lúc
làm cạn tài nguyên" (kể cả khi throughput thấp), còn `limit-count` bắt được "quá nhiều request dồn dập trong
thời gian ngắn" (kể cả khi mỗi request rất nhẹ) — mọi plugin_config trong hệ thống này (Tầng 1, 2, `auth`,
`internal-console`) đều khai **cả hai plugin song song**. Thiếu `limit-conn`, một cuộc tấn công kiểu "mở
connection rồi treo đó không gửi gì" (slowloris) sẽ lọt qua vì không tạo request nào để đếm. Thiếu
`limit-count`, một client gửi hàng nghìn request rất nhỏ rất nhanh (đóng connection ngay sau khi xong) sẽ lọt
qua vì tại bất kỳ thời điểm nào cũng chỉ có 1 connection đang mở.

---

## 00c. Mô hình tổng quan — 4 tầng đồng tâm, giá trị thật

Trước khi đi vào chi tiết từng tầng, đây là toàn cảnh: request đi từ ngoài vào trong — dải ngoài cùng lỏng
nhất, áp cho tất cả (chung); dải trong cùng chặt nhất, chỉ áp cho identity đã đăng ký riêng (cụ thể). Mô hình
đồng tâm này mô tả đúng **phạm vi áp dụng** (bao nhiêu request bị ảnh hưởng): Tầng 1 rộng nhất (100% request),
Tầng 2 hẹp hơn (mọi request S3 dataplane, nhưng phân theo hành vi), Tầng 3 hẹp nhất (chỉ identity đã đăng ký
thủ công). Request nào **không lọt vào được dải trong** (Tầng 3 — không đăng ký) thì tự nhiên vẫn được xử lý
bởi dải ngoài nó đang đứng trong đó (Tầng 2 — chính sách mặc định) — đúng bản chất "vòng ngoài luôn phủ vòng
trong chưa với tới". Trước khi chạm dải nào, mọi request đều qua Tầng 0 — không chặn, chỉ chuẩn bị dữ liệu.

> ⚠️ Lưu ý: sơ đồ này mô tả **phạm vi/độ cụ thể** (khái niệm), không phải **thứ tự thực thi** (runtime).
> Thứ tự thực thi thật (Tầng 3 kiểm tra trước, thay thế Tầng 2 nếu khớp) — xem mô hình tuần tự riêng ở mục 05.

```
              Tầng 0 — rewrite (không chặn ai): trích bucket + AKID, set X-Node-Id, resolve Consumer
                                            │
                                            ▼
        ╔═══════════════════════════════════════════════════════════════╗
        ║  TẦNG 1 · Global Abuse Guard                                   ║
        ║  khoá đếm: X-Node-Id · 1 counter/node · 50.000 req/60s · 429   ║
        ║                                                                 ║
        ║   ┌─────────────────────────────────────────────────────┐     ║
        ║   │  TẦNG 2 · Dynamic QoS (5 nhóm B×K×S)                 │     ║
        ║   │  chính sách MẶC ĐỊNH cho phần chưa đăng ký Tầng 3    │     ║
        ║   │  Authen 1000 · AkidOnly 800 · Snat-Group 1000 ·      │     ║
        ║   │  Snat-Ip 300 · Anon 50 (req/60s) · mã 429            │     ║
        ║   │                                                       │     ║
        ║   │   ┌─────────────────────────────────────────┐       │     ║
        ║   │   │  TẦNG 3 · Consumer Group (8 nhóm)        │       │     ║
        ║   │   │  chỉ identity đã đăng ký (combo>bucket>  │       │     ║
        ║   │   │  snat-ip) — THAY THẾ Tầng 2 khi khớp     │       │     ║
        ║   │   │   tier1-4 (Cấp dữ liệu, steady-state)    │       │     ║
        ║   │   │   boost/event/incident/lockdown (tạm)    │       │     ║
        ║   │   │                                           │       │     ║
        ║   │   │        ┌───────────────────────┐         │       │     ║
        ║   │   │        │      CLOUDIAN          │         │       │     ║
        ║   │   │        │  403 / 503 / 404 / 200 │         │       │     ║
        ║   │   │        └───────────────────────┘         │       │     ║
        ║   │   └─────────────────────────────────────────┘       │     ║
        ║   └─────────────────────────────────────────────────────┘     ║
        ╚═══════════════════════════════════════════════════════════════╝
              Tầng 1 (mọi request) ⊃ Tầng 2 (mặc định) ⊃ Tầng 3 (đã đăng ký, thay thế Tầng 2)
```

Dải ngoài lỏng nhất, áp cho mọi request · dải trong chặt nhất, chỉ áp identity đã đăng ký · không đăng ký =
ở lại dải ngoài (Tầng 2) · có đăng ký = chuyển hẳn vào dải trong (Tầng 3), không cộng dồn cả hai.

---

## 01. Tầng 1 — Global Abuse Guard
`global_rules/global-abuse-guard.yaml`

Lưới an toàn ngoài cùng — nhưng khác điều nhiều người mặc định nghĩ: **không đếm theo IP**. Phạm vi thật của
tầng này là **toàn bộ Instance/node APISIX** — 1 counter DUY NHẤT cho tất cả traffic (mọi IP, mọi bucket, mọi
domain: s3-hcm/s3-hni/cmc/s3-admin/iam) chạm vào đúng node đó, không phân biệt đối tượng. Ý niệm đúng: cầu dao
tổng của **cả dãy nhà** (1 node), không phải cầu dao riêng từng phòng (từng IP) — đếm theo IP là việc của Tầng
2/3, không phải Tầng 1.

```yaml
global_rules:
  - id: global-abuse-guard
    plugins:
      limit-count:
        rules:
          - key: "${http_x_node_id}"
            count: 50000                # trần: 50.000 request/60s — TOÀN NODE, không phải /IP
            time_window: 60
            header_prefix: "Global"
        rejected_code: 429
        allow_degradation: true
        show_limit_quota_header: true
        policy: local

      limit-conn:
        rules:
          - key: "${http_x_node_id}"
            conn: 49500                 # trần: 49.500 connection đồng thời — TOÀN NODE
            burst: 500
        rejected_code: 429 # KHÔNG BAO GIỜ 503 — 503 dành riêng cho Cloudian
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

**Cơ chế "1 counter/node" hoạt động thế nào:**
- `key: "${http_x_node_id}"` — mọi request (bất kỳ IP/bucket/domain nào) đều mang cùng 1 giá trị header
  `X-Node-Id`, do `serverless-pre-function` (rewrite phase, chạy trước cả `limit-conn`/`limit-count` ở access
  phase) set từ biến môi trường `NODE_ID` (`docker-compose.yaml`: `NODE_ID=apisix-standalone-${DC_PROFILE}-${ORDER_NUM}`)
  → APISIX chỉ giữ đúng 1 entry trong shared-dict cho toàn node → đúng nghĩa "1 biến global".
- **Không dùng `$hostname`** (nginx core variable) vì container chạy `network_mode: host`, và Docker **không
  cho phép** khai `hostname:` cùng lúc với `network_mode: host` (lỗi `conflicting options: hostname and the
  network mode` khi recreate container) — dùng biến môi trường `NODE_ID` qua `serverless-pre-function` để né
  hạn chế này, không phụ thuộc container UTS namespace.
- **`limit-conn` không hỗ trợ `header_prefix`** (khác `limit-count`) — theo đúng bảng attributes chính thức
  (`rules.conn`/`rules.burst`/`rules.key`, không có `rules.header_prefix`) — nên `limit-conn` ở tầng này
  không xuất `X-*-RateLimit-*` header nào, chỉ `limit-count` mới có.
- `header_prefix: "Global"` → header trả về là `X-Global-RateLimit-Limit/Remaining/Reset` — **không trùng
  tên** với header của Tầng 2 (`X-Authen-*`/`X-Anon-*`/...) hay Tầng 3 (`X-Boost-*`/`X-Tier4-*`/...). Nếu để
  mặc định (không có `header_prefix`), `limit-count` sinh header phẳng `X-RateLimit-Remaining` — tầng nào
  chạy sau trong cùng request sẽ **ghi đè** tầng chạy trước, khiến client đọc nhầm số liệu của tầng khác
  (đã từng xảy ra thật với Tầng 3 trước khi thêm `header_prefix` cho toàn bộ 8 consumer_group).

Ngưỡng cao có chủ đích: mục tiêu là chặn tình huống cực đoan (DDoS, client lỗi loop connection), không phải
quản lý công bằng thường ngày (đó là việc Tầng 2/3). **Mã lỗi 429** (không phải 503) là quy ước quan trọng
để phân biệt "gateway tự chặn" khỏi "Cloudian từ chối".

**Verify thật (2026-08-20):** bắn request liên tiếp từ 4 nguồn hoàn toàn khác nhau (2 node APISIX HCM/HNI,
1 VM `global-lb`, 1 node ngoài `apisix-node-dc1`) cùng nhắm `s3-hcm.sds.infiniband.vn` — `X-Global-RateLimit-Remaining`
giảm liên tục **1 dải số duy nhất** (`49999 → 49980`) xuyên suốt cả 4 nguồn, không nguồn nào bị reset về gần
50000 — xác nhận đúng 1 counter global/node, không tách theo IP.

---

> 🔄 **[Đồng bộ — 2026-08-20]** Toàn bộ tài liệu bên dưới (Tầng 2/3/0, sơ đồ luồng, bảng tổng kết) đã rà lại
> khớp hiện trạng thật (`RUNBOOK.md` mục 3.1–3.6, cấu hình `apisix-standalone-main.zip` mới nhất) — mô hình
> 5-nhóm B×K×S ở Tầng 2, 8 consumer_group (2 trục) ở Tầng 3. Riêng mục 06 (bộ test QoS gốc) giữ nguyên làm
> hồ sơ lịch sử, có chú thích rõ không còn đại diện cho kiến trúc hiện tại.

## 02. Tầng 2 — Dynamic QoS (phân loại theo hành vi, không cần đăng ký trước)
`plugin_configs/plugin-config-traffic-classifier.yaml`

### Đơn vị chiếm dụng tài nguyên là gì — và vì sao không chỉ có 1 khoá duy nhất

Kiến trúc đã đổi khác hẳn giai đoạn đầu (xem "Lịch sử" bên dưới): thay vì gộp mọi request vào 1 khoá đếm duy
nhất (AKID hoặc bucket), tầng này giờ **tự phân loại mỗi request vào 1 trong 5 nhóm hành vi**, dựa trên 3 tín
hiệu độc lập tự khai trong chính request đó — **không cần tra bảng đăng ký nào** (đó là việc của Tầng 3, mục
03 — nếu request khớp 1 identity đã đăng ký ở đó, chính sách của Tầng 3 sẽ **thay thế** chính sách ở đây, xem
khung cảnh báo cuối mục 03):

| Tín hiệu | Ký hiệu | Ý nghĩa |
|---|---|---|
| Có bucket trong URL | **B** | Request nhắm tới 1 bucket cụ thể |
| Có AKID hợp lệ về cú pháp | **K** | Đã ký (SigV4/SigV2/presigned), dù chưa verify chữ ký thật (việc đó Cloudian làm) |
| IP thuộc dải SNAT nội bộ | **S** | Traffic đi qua NAT nội bộ đã biết, không phải Internet công cộng |

Luật quyết định: **`K > S > Anon`** — có AKID hợp lệ luôn thắng SNAT, SNAT luôn thắng anonymous. 8 tổ hợp
B×K×S đầy đủ, lý do chọn `K` làm tín hiệu tin cậy hơn `B`, và ví dụ thực tế từng nhánh — xem đầy đủ tại
`RUNBOOK.md` mục 3.1 (không lặp lại ở đây để tránh 2 tài liệu lệch nhau khi 1 bên được cập nhật mà bên kia quên).

**Kết quả phân loại → 5 rule độc lập, mỗi rule 1 ngưỡng + 1 khoá đếm riêng:**

```yaml
plugin_configs:
  - id: "plugin-config-traffic-classifier"
    plugins:
      custom.s3-accesskey-extractor: {}

      limit-count:
        rules:
          - key: "${http_x_s3_bucket_name}"
            count: 1000
            time_window: 60
            header_prefix: "Authen"        # B=1,K=1 (có bucket, có AKID)
          - key: "${http_x_s3_akid_only}"
            count: 800
            time_window: 60
            header_prefix: "AkidOnly"      # B=0,K=1 (có AKID, không nhắm bucket cụ thể — vd ListBuckets)
          - key: "${http_x_snat}"
            count: 1000
            time_window: 60
            header_prefix: "Snat-Group"    # SNAT cả dải — đại diện NHIỀU user qua chung 1 NAT
          - key: "${http_x_snat_ip}"
            count: 300
            time_window: 60
            header_prefix: "Snat-Ip"       # SNAT từng IP riêng
          - key: "${http_x_real_ip}"
            count: 50
            time_window: 60
            header_prefix: "Anon"          # không AKID, không SNAT — traffic lạ nhất
        rejected_code: 429
        allow_degradation: true
        show_limit_quota_header: true
        policy: local
```

`header_prefix` riêng cho mỗi rule (từ APISIX 3.16, `rules:` array) → mỗi nhóm trả về đúng header riêng
(`X-Authen-RateLimit-*`, `X-Anon-RateLimit-*`...), không đè lên nhau và không đè lên Tầng 1/3 — xem chi tiết
cơ chế collision này ở Tầng 1 phía trên.

**Vai trò AKID trong tổ hợp `B=1,K=1`:** không mất hẳn — chỉ đổi từ "điều kiện xếp tier" sang "điều kiện chọn
khoá bên trong tier Authenticated": có bucket → dùng bucket làm khoá; không có bucket → fallback AKID.

### Lịch sử — vì sao ban đầu chọn AKID/bucket đơn-khoá rồi mới đổi sang mô hình 5-nhóm

Bộ test QoS đối chứng cascade đầu tiên (17–20/07/2026) chạy khi tầng này còn ở dạng đơn-khoá (AKID, 500
conn/4000 req/s, sau đó đổi sang bucket 5000/5000). Nhận ra đơn-khoá không phân biệt được traffic anonymous
nguy hiểm khỏi traffic SNAT nội bộ hợp lệ hay traffic đã xác thực — mô hình 5-nhóm B×K×S ra đời để giải quyết
đúng lỗ hổng đó (case gốc phát hiện: `curl` không ký `GET /<bucket-công-khai>/` lọt qua như traffic bình
thường). Đây là bước tiến hoá kiến trúc, không phải chỉnh số đơn thuần.

> ⚠️ Ngưỡng trong bảng trên là **số test riêng cho workload này**, không phải số production chính thức của
> Global — xem `RUNBOOK.md` mục 3.3 để có ngưỡng đang áp dụng thật.

---

## 03. Tầng 3 — Consumer Group theo Identity đã đăng ký
`consumers/*.yaml` + `consumer_groups/*.yaml`

Tầng cụ thể nhất — chỉ áp dụng cho identity **đã đăng ký thủ công**; phần lớn traffic không nằm trong danh
sách này thì Tầng 3 hoàn toàn không tồn tại, rơi thẳng về Tầng 2 (5-nhóm B×K×S ở trên) mặc định.

Plugin `s3-qos-consumer` (rewrite phase, priority **9500**) tự động resolve request thành 1 trong 3 loại
identity, **không cần client khai gì thêm**:

| Loại | Format `username` | Khớp khi nào |
|---|---|---|
| Theo bucket | `bucket-<tên-bucket>` | Đúng bucket, bất kỳ IP nào |
| Theo IP cụ thể | `snatip-<ip-đổi-chấm-thành-gạch>` | Đúng IP, bất kỳ bucket nào |
| Kết hợp cả 2 | `bucketsnat-<bucket>-<ip-đổi-chấm-thành-gạch>` | ĐÚNG bucket này TỪ ĐÚNG IP này — ưu tiên cao nhất |

Thứ tự ưu tiên khi nhiều loại cùng khớp: **`combo > bucket > snat-ip`** (tín hiệu càng hẹp — càng ít đối
tượng bị ảnh hưởng nếu đăng ký sai — càng ưu tiên cao).

**8 consumer_group cố định, thiết kế theo 2 trục** (đầy đủ ngưỡng + khi nào dùng — xem `RUNBOOK.md` mục 3.3):

- **Trục Cấp dữ liệu** (steady-state): `tier4-mission-critical` → `tier3-business-critical` → `tier2-standard`
  (baseline) → `tier1-archive`.
- **Trục xử lý vận hành** (chuyển tạm thời khi có sự kiện, trả về trục Cấp dữ liệu khi xong): `boost` (nới
  tạm), `event` (sự kiện có kế hoạch), `incident` (đang điều tra), `lockdown` (siết khẩn cấp).

```yaml
consumers:
  - username: "bucket-doi-tac-abc"    # PHẢI có tiền tố đúng loại identity
    group_id: "consumer-group-s3-tier2-standard"
    plugins:
      custom.s3-qos-consumer: {}
```

```yaml
consumer_groups:
  - id: consumer-group-s3-tier2-standard
    plugins:
      limit-count:
        rules:
          - key: "${consumer_name}"
            count: 300
            time_window: 60
            header_prefix: "Tier2"        # riêng cho từng group — không đè Tầng 1/2
        rejected_code: 429
        allow_degradation: true
        show_limit_quota_header: true
        policy: local
```

Tiền tố username bắt buộc đúng loại (`bucket-`/`snatip-`/`bucketsnat-`): namespace **dùng chung toàn instance**
APISIX — sai/thiếu tiền tố có thể **ghi đè mất** 1 identity khác trùng tên.

**Redis cho tier khẩn cấp:** `lockdown`/`incident`/`tier4-mission-critical` về nguyên tắc cần `policy: redis`
(enforce cross-node, vì lockdown 1 identity ở node HCM mà node HNI không biết thì vô nghĩa) — **hiện tại đang
default `local`**, chưa enforce đúng thiết kế (xem việc còn treo trong `note-ky_-thua__t-apisix.md`).

### ⚠ Không phải "cộng dồn cả 2 tầng" — Tầng 3 THAY THẾ hoàn toàn Tầng 2 khi resolve được, và được xét TRƯỚC

Hai điểm dễ hiểu nhầm, cả hai đều quan trọng khi đọc log/debug:

1. **Thứ tự thực thi thật ngược với thứ tự trình bày ở đây:** `s3-qos-consumer` (Tầng 3, priority 9500) chạy
   **trước** `s3-traffic-classifier` (Tầng 2, priority 9000) trong rewrite phase — nghĩa là hệ thống luôn thử
   khớp identity cụ thể (Tầng 3) trước, mô hình 5-nhóm hành vi (Tầng 2) chỉ là **chính sách mặc định cho phần
   còn lại không đăng ký**. Mục lục trình bày Tầng 2 trước Tầng 3 (đúng mạch "chung → cụ thể" của toàn bộ tài
   liệu, khớp số hiệu cố định trong `RUNBOOK.md`) — không phản ánh thứ tự chạy thật. Xem mục 05 "Đường đi của
   một request" để có đúng thứ tự thực thi dạng tuần tự.
2. **Không phải cộng dồn:** khi Consumer đã resolve, `limit-count` của Consumer Group (Tầng 3) là thứ **DUY
   NHẤT thực thi** — theo đúng quy tắc merge plugin APISIX (Consumer Group ghi đè full-replace Plugin Config
   cùng tên plugin, không gộp). `limit-count` 5-nhóm B×K×S của Tầng 2 **hoàn toàn không chạy** cho request đó.

---
## 00d. Tầng 0 — Plugin khai trực tiếp tại Route
`routes/route-s3-hcm.sds.infiniband.vn-https-443.yaml`

Khác hẳn 3 tầng trên về bản chất — **không thêm ngưỡng chặn nào**. Tầng 0 trả lời "trước khi quyết định, hệ
thống cần biết gì về request này" — tên bucket, có AKID không, IP có thuộc SNAT không, identity nào đã đăng
ký. Đây là nơi các plugin "trinh sát" chạy trước, tất cả ở giai đoạn `rewrite` — **trước** giai đoạn `access`
(nơi `limit-conn`/`limit-count` của Tầng 1/2/3 hoạt động).

**Thứ tự chạy thật trong rewrite phase (priority giảm dần):**

| Plugin | Priority | Vai trò |
|---|---|---|
| `custom.s3-normalizer-bucket-name` | 10005 | Export `ctx.s3_bucket_name` + header `X-S3-Bucket-Name` (tín hiệu **B**) |
| `serverless-pre-function` (global rule) | 10000 | Set `X-Node-Id` từ ENV `NODE_ID` — nguồn khoá đếm Tầng 1 |
| `custom.s3-qos-consumer` | 9500 | Resolve Consumer (Tầng 3) theo combo>bucket>snat-ip |
| `custom.s3-traffic-classifier` | 9000 | Tính B/K/S, set header `X-S3-*`/`X-SNAT*`/`X-Real-Ip` (Tầng 2) |
| `custom.s3-accesskey-extractor` | 2510 | Trích AKID (tín hiệu **K**), set `X-S3-Access-Key` |

Ba plugin đầu tiên chính là **nguồn phát sinh** dữ liệu cho toàn bộ Tầng 1/2/3: thiếu `s3-normalizer-bucket-name`
chạy đúng, khoá đếm Tầng 2 luôn rỗng, mọi bucket dồn chung vào rổ "untagged".

### ⚠ Quy tắc merge quan trọng nhất — vì sao Tầng 0 nguy hiểm nếu dùng sai

Route file ghi lại quy tắc nền tảng của APISIX: **Route > Plugin Config > Service** — hai cấp cùng khai một
plugin trùng tên, cấp cao hơn **ghi đè hoàn toàn**, không phải gộp thêm. Nếu ai đó vô tình thêm thẳng khối
`limit-conn`/`limit-count` vào route này (Tầng 0), toàn bộ cấu hình Tầng 2 sẽ bị **vô hiệu hoá âm thầm**,
không một cảnh báo nào hiện ra. Lưu ý riêng: `global_rules` (Tầng 1) **không nằm trong quy tắc merge này** —
nó luôn chạy cộng dồn thêm, không bị Route/Plugin Config/Service ghi đè.

---

## 05. Đường đi của một request qua cả 4 tầng — mô hình tuần tự (thứ tự thực thi thật)

Khác với sơ đồ đồng tâm ở mục 00c (mô tả *phạm vi*), đây là **thứ tự chạy thật theo thời gian** khi 1 request
đi qua gateway — đúng theo priority plugin (mục 00d), không phải theo số hiệu tầng:

```
Client PUT (SigV4)
    │
    ▼
Tầng 0 (rewrite) — Trích bucket/AKID, set X-Node-Id, resolve Consumer — KHÔNG chặn, chỉ chuẩn bị dữ liệu
    │
    ▼
Tầng 1 (access) — 1 counter DUY NHẤT/node (key: X-Node-Id) — trần 50.000 req/60s + 49.500 conn
    │
    ▼
Tầng 3 (access) — Consumer đã resolve? → CÓ: áp 1 trong 8 consumer_group, DỪNG (không chạy Tầng 2 nữa)
    │
    ▼ (KHÔNG resolve được Consumer nào)
Tầng 2 (access) — 5 nhóm B×K×S (Authen/AkidOnly/Snat-Group/Snat-Ip/Anon) — chính sách mặc định
    │
    ▼
Cloudian — Kiểm tra quota lưu trữ + QoS request-rate riêng
```

Tầng 3 kiểm tra **trước** Tầng 2 (đúng thứ tự resolve thật: `s3-qos-consumer` priority 9500 chạy trước
`s3-traffic-classifier` priority 9000) — và khi Tầng 3 khớp, nó **thay thế hoàn toàn** Tầng 2 cho request đó
(merge precedence Consumer Group > Plugin Config), không phải cộng dồn cả hai. Tầng 2 chỉ thực thi cho phần
traffic **không** khớp bất kỳ Consumer nào — đúng nghĩa "chính sách mặc định".

Bị chặn ở Tầng 1/2/3 → mã lỗi **429**, không bao giờ chạm Cloudian — khác hẳn 403 (quota) hoặc 503
(request-rate) mà Cloudian tự trả. Phân biệt đúng các loại mã lỗi (429/403/503) là chìa khoá chẩn đoán sự cố
đúng chỗ.

---

## 06. Vì sao trong bộ test QoS gốc (17–20/07/2026), các tầng này im lặng suốt?

> ⚠️ Mục này ghi lại đúng nguyên trạng bộ test **lịch sử**, chạy dưới kiến trúc Tầng 2/3 **cũ** (đơn-khoá
> AKID/bucket, 3 consumer_group) — số liệu/kết luận bên dưới **không đại diện** cho hành vi dưới mô hình
> 5-nhóm + 8-group hiện tại. Giữ lại vì vẫn đúng về mặt phương pháp luận (nguyên tắc thiết kế thí nghiệm),
> chưa có bộ test tương đương chạy lại trên kiến trúc mới.

Toàn bộ 6 run: **không request nào bị bất kỳ tầng nào của APISIX từ chối** — mọi lỗi quan sát được (403, 503,
một vài 502) đều từ Cloudian hoặc lỗi kết nối tới Cloudian. Đây là điều kiện **bắt buộc** để bài test có ý
nghĩa: mục tiêu là đo hành vi tầng kết nối-tới-backend, không phải hành vi rate-limit của APISIX. Nguyên tắc
thiết kế thí nghiệm: muốn đo chính xác một biến số, giữ mọi biến số khác đứng yên.

---

## 07. Bảng tổng kết & khuyến nghị

| | Tầng 1 — Global Guard | Tầng 2 — Dynamic QoS (5 nhóm, mặc định) | Tầng 3 — Consumer Group (8 nhóm, thay thế Tầng 2 nếu khớp) | Tầng 0 — Route Plugins |
|---|---|---|---|---|
| **Áp dụng cho** | Mọi request, mọi route, mọi node | Phần chưa đăng ký Tầng 3 | Chỉ identity đăng ký thủ công — resolve trước, thay thế Tầng 2 | Route S3 dataplane — chạy trước Tầng 1 |
| **Khoá đếm** | `X-Node-Id` (1 counter/node) | bucket / AKID-only / SNAT-group / SNAT-IP / real-IP tuỳ nhóm | `consumer_name` | KHÔNG chặn — trích tín hiệu, resolve Consumer |
| **Ngưỡng** | 50.000 req/60s + 49.500 conn | 1000/800/1000/300/50 req/60s tuỳ nhóm | tuỳ group (50–2000 req/60s) | — (giai đoạn: rewrite, trước access) |
| **Mã lỗi** | 429 | 429 | 429 | — |
| **Header trace** | `X-Global-RateLimit-*` | `X-Authen/AkidOnly/Snat-Group/Snat-Ip/Anon-RateLimit-*` | `X-Tier1-4/Boost/Event/Incident/Lockdown-RateLimit-*` | `X-S3-*`/`X-SNAT*`/`X-Node-Id` |
| **Rủi ro** | `header_prefix` thiếu → đè header tầng khác | `header_prefix` thiếu → đè header tầng khác; chỉ chạy khi Tầng 3 không khớp | `header_prefix` thiếu → đè header tầng khác; Redis chưa enforce cho tier khẩn cấp | Plugin trùng tên ở đây đè hoàn toàn Plugin Config |

**Khuyến nghị:**

1. **Giữ chiến lược "chế độ cảnh báo" ở Tầng 2/3** cho tới khi có đủ số liệu p95/p99 theo từng nhóm — đừng
   hạ/nâng ngưỡng khi chưa có dữ liệu traffic thật.
2. **Chạy lại 1 bộ test tải tương đương bộ test gốc (mục 06)** trên kiến trúc 5-nhóm + 8-group hiện tại —
   số liệu cũ không còn đại diện, cần baseline mới trước khi đưa production.
3. **Enforce `policy: redis` cho `lockdown`/`incident`/`tier4-mission-critical`** — hiện đang default `local`,
   không cross-node, sai với thiết kế "khẩn cấp phải chặn được ở cả 2 DC cùng lúc".
4. **Thêm bước review vào checklist PR** cho mọi thay đổi đụng route (Tầng 0): kiểm tra không có
   `limit-conn`/`limit-count` khai trực tiếp trong `plugins:` ở route, và mọi `limit-count` mới (bất kỳ tầng
   nào) đều có `header_prefix` riêng, không trùng tầng khác.

---

## 08. Cân nhắc — tách QoS Read vs Write
*(chưa triển khai — đề xuất roadmap)*

Đây là một khoảng trống thật trong thiết kế hiện tại, chưa phải một lỗi: cả 4 tầng ở trên đều áp đúng một
ngưỡng chung cho mọi phương thức HTTP — PUT, GET, DELETE đều bị đếm và giới hạn như nhau, không phân biệt
"ghi" (write) hay "đọc" (read).

### Đặc thù workload — vì sao ghi và đọc xứng đáng có chính sách riêng

Thói quen sử dụng thực tế của cả sản phẩm nội bộ lẫn đối tác hiện nay **thiên hẳn về ghi** — tỉ lệ write:read
rơi vào khoảng **70:30 đến 80:20**, xuyên suốt hầu hết thời gian vận hành. Đây không phải quan sát tạm thời
mà là bản chất các luồng nghiệp vụ đang chạy qua hệ thống: ghi log liên tục, lưu dữ liệu giao dịch, upload
định kỳ — hành vi "viết vào rồi để đó", hiếm khi cần đọc lại ngay. Đọc chỉ tăng đột biến trong những sự kiện
có thể lường trước: **di dời dữ liệu giữa các trung tâm dữ liệu (migrate DC)** hoặc **sao lưu định kỳ
(backup)** — cả hai đều cần tải dữ liệu cũ về, tạo đợt đọc dồn dập khác hẳn ngày thường. Điểm quan trọng:
những sự kiện này **luôn được lên kế hoạch trước**, không phải rủi ro bất ngờ — nên hoàn toàn có thể chuẩn bị:
tạm thời nới ngưỡng QoS cho luồng đọc trước khi sự kiện bắt đầu, đưa trở lại bình thường ngay sau khi kết
thúc.

Hệ quả của dùng chung một ngưỡng cho cả hai chiều: ngưỡng phải đủ cao để không cản trở luồng ghi (luồng quan
trọng nhất) — nhưng cùng ngưỡng đó, áp cho luồng đọc, lại rộng hơn hẳn mức cần thiết trong điều kiện bình
thường (đọc chỉ 20-30% traffic). Hệ thống đang "hào phóng" hơn mức cần thiết với luồng đọc suốt phần lớn thời
gian, chỉ để dự phòng cho một tỉ lệ nhỏ thời gian còn lại (các đợt migrate/backup).

### Hướng triển khai khả thi — dùng phương thức HTTP làm trục phân loại thứ hai

APISIX cho phép route match theo điều kiện `vars` (đã có sẵn ví dụ dạng comment trong route hiện tại, dùng
cho mục đích khác). Cùng cơ chế áp dụng được cho bài toán này: tách route S3 dataplane hiện tại thành 2 route
khớp cùng host nhưng khác điều kiện `request_method`, mỗi route gắn một `plugin_config_id` riêng:

```yaml
# Route ghi — PUT/POST/DELETE, gắn profile QoS riêng cho write
- id: "route-s3-hcm-write"
  vars: [["request_method", "in", ["PUT", "POST", "DELETE"]]]
  hosts: ["s3-hcm.sds.infiniband.vn", "*.s3-hcm.sds.infiniband.vn"]
  plugin_config_id: "plugin-config-traffic-classifier-write"
  plugins: { ... }   # giữ nguyên Tầng 0 (normalizer/consumer/extractor)

# Route đọc — GET/HEAD, gắn profile QoS riêng cho read
- id: "route-s3-hcm-read"
  vars: [["request_method", "in", ["GET", "HEAD"]]]
  hosts: ["s3-hcm.sds.infiniband.vn", "*.s3-hcm.sds.infiniband.vn"]
  plugin_config_id: "plugin-config-traffic-classifier-read"
  plugins: { ... }   # giữ nguyên Tầng 0
```

Cách này giữ nguyên toàn bộ Tầng 0 (không đổi cách trích bucket/AKID) và Tầng 3 (Consumer Group không đổi),
chỉ nhân đôi Tầng 2 thành 2 profile độc lập — tương thích với quy tắc "mỗi route chỉ nhận 1
`plugin_config_id`" đã nêu ở Tầng 0. Ngưỡng gợi ý ban đầu — phản ánh đúng tỉ lệ 70-80% write / 20-30% read —
là đặt profile write ở mức tương đương hiện tại (hoặc cao hơn), còn profile read đặt thấp hơn hẳn trong điều
kiện bình thường, có quy trình vận hành riêng để nới rộng tạm thời khi cần.

### Quy trình vận hành cho các đợt migrate/backup đã lên kế hoạch

1. **Trước sự kiện** — xác định thời gian bắt đầu/kết thúc, ước lượng tải đọc dự kiến, cập nhật ngưỡng
   `plugin-config-traffic-classifier-read` (cả hard lẫn soft) lên mức phù hợp qua gitsync, verify runtime trước giờ G.
2. **Trong sự kiện** — theo dõi log `rate-limit-warning` của riêng profile read để xác nhận ngưỡng mới đủ
   rộng, không có cảnh báo giả do đặt quá sát.
3. **Sau sự kiện** — đưa ngưỡng read trở lại mức bình thường, verify runtime, ghi lại vào lịch sử thay đổi
   (giống cách `plugin-config-qos-auth.yaml` đã ghi "INCIDENT HISTORY" — nên áp dụng cùng kỷ luật ghi chép
   cho các đợt nới ngưỡng tạm thời này).

**Trạng thái:** đây là đề xuất, chưa triển khai — cần đánh giá thêm: chi phí duy trì 2 route thay vì 1 (double
route + double plugin_config cho mỗi domain S3), và liệu tách theo method đã đủ hay cần tách sâu hơn (ví dụ
theo Content-Length để phân biệt object lớn/nhỏ trong chính luồng ghi). Có thể bắt đầu bằng **soft-limit riêng
theo method** trước (đo lường, không chặn) — cùng cách tiếp cận "đo trước khi cắt" đã áp dụng thành công cho
việc chuyển khoá đếm từ AKID sang bucket — trước khi quyết định tách hẳn thành 2 route.

---

*Tài liệu tham chiếu cấu hình thật đang chạy trên sandbox `sds.infiniband.vn`, đối chiếu kết quả bộ test QoS
403/503 (6 lần chạy, 17–20/07/2026). Xem thêm: `qos-case-report.html` / `qos-case-report.md`.*
