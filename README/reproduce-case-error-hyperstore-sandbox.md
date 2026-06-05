# BÁO CÁO PHÂN TÍCH HỆ THỐNG: ĐÁNH GIÁ SỰ KHÁC BIỆT CẤU HÌNH GIỮA PRODUCTION VÀ SANDBOX
**Mã sự cố tham chiếu:** HyperStore Early Connection Close on User QuotaExceeded causing Nginx Upstream Cascade Failure.
**Hệ thống ảnh hưởng:** Lớp Nginx (OpenResty) Load Balancer & Cụm S3 Cloudian HyperStore.
**Tập tin đối chiếu vật lý:** `hni-01.conf`, `hni-02.conf` (Prod) vs `sb-01.conf`, `sb-02.conf` (Sandbox).
**Trạng thái kiểm thử hiện tại:** Sandbox chưa thể tái hiện (reproduce) được lỗi 502 chuỗi của Production.
**Ngày lập báo cáo:** 05/06/2026
**Tác giả:** CloudOps Team / System Administrator

---

## 1. Tổng quan DIỄN BIẾN SỰ CỐ TRÊN PRODUCTION (HNI)
Vào ngày 20/05/2026, môi trường Production gặp sự cố sập dây chuyền (Cascade Failure) lớp Nginx Reverse Proxy, trả về lỗi `502 Bad Gateway` diện rộng cho toàn bộ S3 client. 

**Cơ chế lỗi gốc (Root Cause):** Khi một tài khoản người dùng (User) trên môi trường Production vượt quá dung lượng lưu trữ cho phép (`QuotaExceeded`), cụm S3 Cloudian HyperStore kích hoạt cơ chế bảo vệ: đọc phần HTTP Headers của request `PUT` trước, phát hiện hết hạn mức và lập tức **Đóng kết nối TCP/TLS sớm (Early Connection Close)**.

Do kích thước payload thực tế từ các workload (Loki Ingester, APM Trace) khá lớn (~1.9MB), Nginx vẫn đang trong tiến trình đẩy nốt phần Request Body xuống Backend. Việc socket bị ngắt đột ngột từ phía Cloudian khiến Nginx sinh lỗi hệ thống mạng: `SSL_write() failed (32: Broken pipe)`. 

Do cơ chế quản lý Upstream trên Production nhạy cảm, trận lụt lỗi mạng này đã đánh lừa Nginx, khiến nó hiểu nhầm toàn bộ các Node Cloudian vật lý (12 Node) đều bị sập, kích hoạt vòng lặp cô lập chuỗi (Cascade Lockout) và trả về lỗi `502 Bad Gateway` toàn hệ thống.

---

## 2. Môi trường Reproduce

### 2.1 Cloudian HyperStore

| Item | Giá trị |
|---|---|
| Version | 8.2.2.2 (Compiled: 2025-10-29) |
| Region HCM | 4 nodes: `sb-hyperstore-hcm-node-1~4` |
| Region HNI | 3 nodes: `172.25.171.31~33` |
| Cassandra | port 9160/9042 |
| Redis QoS | port 6379/6380 |

### 2.2 Nginx Load Balancer Sandbox

| Item | Giá trị |
|---|---|
| Host | `sb-s3-lb-1` (172.27.2.204) |
| Container | `cloudian-nginx-with-prometheus` |
| Domain S3 HNI | `s3-hni.sds.infiniband.vn` |
| Upstream nodes | 3 nodes (172.25.171.31~33:443) |

### 2.3 Load Generator (Client VMs)

| VM | IP | Concurrent jobs |
|---|---|---|
| test-1 | 172.27.x.x | ~323 |
| test-2 | 172.27.x.x | ~300 |
| test-3 | 172.27.x.x | ~283 |
| sb-s3-lb-api6-hcm-1 | 172.27.x.x | ~124 |
| sb-s3-lb-api6-hni-1 | 172.27.x.x | ~300 |
| **Tổng** | | **~1330 concurrent** |

---

## 3. Phân tích Behavior

### 3.1 Cơ chế gây cascade

```
[Client] PUT request
    → Nginx nhận request
    → proxy_request_buffering off → Nginx bắt đầu stream body đến HyperStore
    → HyperStore check quota → QuotaExceeded
    → HyperStore đóng TLS connection SỚM (trước khi gửi HTTP headers)
    → Nginx đang SSL_write() → nhận Broken Pipe
    → Nginx không nhận được HTTP response headers
    → Nginx tính là upstream failure → tăng max_fails counter
    → max_fails=2 đạt → node bị mark DOWN
    → 3 nodes lần lượt bị mark DOWN
    → "no live upstreams" → 502 cho toàn bộ client
```

### 3.2 Dấu hiệu xác nhận từ log

**Nginx error log (production):**
```
SSL_write() failed (32: Broken pipe) while sending request to upstream,
upstream: "https://10.16.58.29:443/hni-prod-obs-loki/..."
```

**Nginx access log (production):**
```
upstream_status=502
header_time="-"      ← HyperStore đóng conn trước khi gửi headers
body_sent=150        ← Chỉ là Nginx tự trả 502, không có data từ HyperStore
connection_requests=1 ← Xảy ra trên fresh connection
```

**Cloudian request-info log:**
```
httpstatus=403
errorcode=QuotaExceeded
durationmicrosecs=926   ← Reject rất nhanh (~1ms)
requestbodysize=1925333 ← HyperStore không đọc hết body
```

---

## 4. Trạng thái User Quota khi Reproduce

### 4.1 User dùng để reproduce

| Item | Giá trị |
|---|---|
| userId | `user` |
| groupId | `thuyldx` |
| canonicalUserId | `94ef58b910fb9a687bfbe45e93f944f6` |

### 4.2 Quota config

```bash
curl -k -u $(hsctl config get admin.auth.username):$(hsctl config get admin.auth.password) \
  "https://localhost:19443/qos/limits?userId=user&groupId=thuyldx"
```

| Type | Value | Quy đổi |
|---|---|---|
| `STORAGE_QUOTA_KBYTES` | 10,485,760 KB | **10 GiB** (hard limit) |
| `STORAGE_QUOTA_KBYTES_LH` | 10,485,760 KB | 10 GiB |
| `STORAGE_QUOTA_KBYTES_LW` | 8,388,608 KB | 8 GiB (warning) |

### 4.3 Usage tại thời điểm reproduce

```bash
curl -k -u $(hsctl config get admin.auth.username):$(hsctl config get admin.auth.password) \
  "https://localhost:19443/system/bytecount?groupId=thuyldx&userId=user"
```

| Metric | Giá trị |
|---|---|
| Bytes đã dùng | 9,092,021,145 bytes |
| GiB đã dùng | **~8.47 GiB** |
| Quota hard limit | 10 GiB |
| Còn trống | ~1.53 GiB |

**Bucket breakdown:**

| Bucket | Size | Objects |
|---|---|---|
| test-macbook | ~2.7 GiB | 3 |
| test-zephyrus | ~2.7 GiB | 3 |
| test-dell | ~2.4 GiB | 2 |

---

## 5. Cloudian HyperStore Thread Config

```bash
hsctl config get s3.threads.max        # 500/node
hsctl config get s3.threads.min        # 100/node
hsctl config get s3.threads.idleTimeout    # 60000ms
hsctl config get s3.lowRes.idleTimeout     # 5000ms
```

| Parameter | Value | Ý nghĩa |
|---|---|---|
| `s3.threads.max` | **500/node** | Max concurrent S3 requests/node |
| `s3.lowRes.idleTimeout` | **5000ms** | ⚠️ Nghi phạm early close khi low resource |
| `hyperstore.threads.maxWrite` | **100/node** | Max concurrent PUT — bottleneck thực sự |
| **Tổng write threads HNI** | **300** | 3 nodes × 100 |

---

## 6. Nguyên nhân Sandbox chưa thể tái hiện (Reproduce) được lỗi

Hiện tại, môi trường Sandbox đã được giả lập trạng thái `QuotaExceeded` và chạy kịch bản ép tải bằng `xargs/aws-cli` nhưng hệ thống **vẫn hoạt động bình thường, không xảy ra lỗi 502 dây chuyền**. Qua đối soát hệ thống, chúng tôi xác định các nguyên nhân cốt lõi sau:

### 6.1. Lý do hàng đầu: Sự bất đối xứng về cấu hình Nginx Upstream (Trọng tâm)
Cấu hình định tuyến và quản lý trạng thái Upstream giữa Sandbox và Production đang có sự khác biệt rất lớn, làm mất đi "phản ứng dây chuyền" dẫn đến sập cụm proxy.
- Toàn bộ cấu hình trên Production HNI: 
  - [hni-1](../nginx/production/hni/hni-01.conf)
  - [hni-2](../nginx/production/hni/hni-02.conf)
- Toàn bộ cấu hình trên sandbox: 
  - [sb-1](../nginx/sandbox/sb-s3-lb-1/sb-01.conf)
  - [sb-2](../nginx/sandbox/sb-s3-lb-2/sb-02.conf)

#### MA TRẬN ĐỐI CHIẾU CHI TIẾT 4 TẬP TIN CẤU HÌNH
Qua phân tích sâu cấu hình thô từ các file dump hệ thống (`nginx -T`), chúng tôi xác định các điểm bất đối xứng chí mạng nằm tại khối `upstream {}` điều hướng traffic:

| Tham số cấu hình | Production (`hni-01.conf` / `hni-02.conf`) | Sandbox (`sb-01.conf` / `sb-02.conf`) | Đánh giá mức độ ảnh hưởng |
| :--- | :--- | :--- | :--- |
| **Shared Memory (`zone`)** | **Có cấu hình** (`zone upstream_name 128k;`) | **KHÔNG CÓ** | **Cực kỳ chí mạng.** Prod đồng bộ trạng thái lỗi tức thì trên toàn bộ các Worker Processes. |
| **Thuật toán cân bằng tải** | **`least_conn;`** (Ít kết nối nhất) | **Round Robin** (Mặc định - Chia đều) | **Cực kỳ chí mạng.** Prod tự động tống tải lỗi vào duy nhất Node vừa bị ngắt mạng. |
| **Quy mô Backend Pool** | **12 Node Cloudian** (Dải IP `10.16.58.x`) | **3 Node Cloudian** (Dải IP `172.26.29.x`) | Quy mô pool lớn làm gia tăng tốc độ sập chuỗi khi dính hiệu ứng domino. |
| **Thông số cô lập Node** | `max_fails=2 fail_timeout=5s;` | `max_fails=2 fail_timeout=10s;` | Prod có thời gian nhả block ngắn hơn nhưng tần suất quét cấu hình dày hơn. |
| **Keepalive Pool Upstream**| `keepalive 60;` | `keepalive 60;` | Giống nhau, nhưng chịu áp lực connection lớn hơn trên môi trường Prod. |
| **HTTP/2 & Gzip** | `http2 on;` / `gzip off;` | `http2 on;` / `gzip off;` | Đồng bộ về mặt tối ưu hóa hạ tầng S3 API traffic. |
| **Lớp Scripting xử lý** | `access_by_lua_file` | `access_by_lua_file` | Cả hai đều đi qua OpenResty Lua Engine. |

### 6.1 Upstream `hyperstore-cloudian-s3-hni`

| Parameter | hni-01 (Prod) | hni-02 (Prod — case bị lỗi) | sb-01 (Sandbox) | sb-02 (Sandbox) |
|---|---|---|---|---|
| `zone` | ✅ `128k` | ✅ `128k` | ❌ **THIẾU** | ❌ **THIẾU** |
| `least_conn` | ✅ có | ✅ có | ❌ **THIẾU** | ❌ **THIẾU** |
| `fail_timeout` | **15s** | **5s** | **10s** | **10s** |
| `keepalive` | 60 | 60 | 60 ✅ | 60 ✅ |
| `keepalive_timeout` | **45s** | **45s** | ❌ **THIẾU** | ❌ **THIẾU** |
| `keepalive_requests` | **200** | **200** | ❌ **THIẾU** | ❌ **THIẾU** |
| Số upstream nodes | **12** | **12** | **3** | **3** |

### 6.2 `proxy_options_s3.conf`

| Parameter | Production | sb-01 | sb-02 |
|---|---|---|---|
| `proxy_request_buffering` | `off` ✅ | `off` ✅ | `off` ✅ |
| `proxy_send_timeout` | **300s** | **60s** ⚠️ | **60s** ⚠️ |
| `proxy_read_timeout` | **300s** | **60s** ⚠️ | **60s** ⚠️ |
| `proxy_connect_timeout` | 10s ✅ | 10s ✅ | 10s ✅ |

### 6.3 `nginx.conf` (http block)

| Parameter | hni-01/02 (Prod) | sb-01 | sb-02 |
|---|---|---|---|
| `keepalive_timeout` | **650s** | **650s** ✅ | **60s** ⚠️ |
| `worker_connections` | 8192 ✅ | 8192 ✅ | 8192 ✅ |
| Active healthcheck | ❌ không | ❌ không ✅ | ✅ **CÓ** ⚠️ |

> **sb-02 có active healthcheck** (`resty.upstream.healthcheck`, fall=3, rise=2) — **KHÔNG phù hợp** để reproduce vì sẽ tự recover upstream sau 2 lần success check, override passive `max_fails`.

---

#### PHÂN TÍCH BA NÚT THẮT CHÍ MẠNG KHIẾN SANDBOX CHƯA THỂ REPRODUCE LỖI

Lý do kịch bản stress test 1500+ connection với file 2MB trên Sandbox hiện tại vẫn trả về lỗi `403` hoặc `200` ổn định, không sập chuỗi `502` là vì file `sb-01.conf` và `sb-02.conf` đang thiếu đi 3 cơ chế phối hợp độc hại sau:

### Nút thắt 1: Sự vắng mặt của vùng nhớ chia sẻ `zone` trên Sandbox
* **Hành vi tại Sandbox (`sb-01.conf`):** Nginx chạy đa tiến trình Worker độc lập. Do không khai báo `zone`, mỗi Worker sở hữu một bộ đếm `max_fails=2` riêng trên RAM cục bộ của nó. Khi bạn bắn tải từ máy Client, các request lỗi mạng `Broken pipe` bị chia nhỏ và rải đều cho các Worker khác nhau. Không có Worker nào tích lũy đủ 2 lỗi mạng trên một Node Cloudian cụ thể $\rightarrow$ Các node trên Sandbox không bao giờ bị cách ly.
* **Hành vi tại Production (`hni-01.conf`):** Khi có cờ `zone`, một bảng trạng thái chung được thiết lập. Worker số 1 dính 1 lỗi mạng, Worker số 2 dính thêm 1 lỗi mạng $\rightarrow$ Hệ thống ghi nhận đủ `max_fails=2`. Node Cloudian đó ngay lập tức bị block trên **toàn diện rộng**, áp dụng cho mọi Worker.

### Nút thắt 2: Thuật toán `least_conn` biến Node lỗi thành "Hố đen hút Request"
* **Hành vi tại Sandbox (Mặc định Round Robin):** Khi một kết nối bị Cloudian đóng sớm, Nginx nhận diện lỗi mạng nhưng request tiếp theo vẫn được phân bổ đều sang các Node khác theo vòng tròn, giúp giảm áp lực cục bộ.
* **Hành vi tại Production (`least_conn`):** Đây là điểm bẫy tải nghiêm trọng nhất. Khi Node Cloudian 1 đóng socket sớm để từ chối nhận file, số lượng kết nối đang hoạt động (Active Connections) của Node 1 trên Nginx **lập tức tụt thẳng về 0**. Thuật toán `least_conn` thấy Node 1 có `0 connections`, liền hiểu sai rằng đây là node đang rảnh nhất hệ thống. Nginx lập tức chuyển hướng toàn bộ làn sóng các request PUT tiếp theo tống sạch vào Node 1 lỗi này. Sự kết hợp này đẩy tốc độ tăng bộ đếm lỗi `max_fails` lên mức micro-giây.

### Nút thắt 3: Hiệu ứng Domino sập chuỗi toàn hệ thống (Cascade Lockout)
Trên Production (`hni-01.conf`), ngay sau khi Node 1 bị khóa cứng 5 giây do tràn bộ đếm lỗi tập trung, `least_conn` lập tức chuyển hướng dòng thác request sang Node 2 (vì lúc này Node 2 có ít kết nối nhất). Quy trình đóng socket sớm $\rightarrow$ tụt kết nối về 0 $\rightarrow$ dồn tải $\rightarrow$ tràn `max_fails` lặp lại tuần tự từ Node 2, Node 3... cho đến Node 12. 
Hệ quả là toàn bộ Upstream Pool bị vô hiệu hóa, Nginx không còn backend nào để chuyển tiếp và trả về lỗi `502 No live upstreams` cho mọi Client khác trong hệ thống (kể cả các client hợp lệ không hết quota).

---

| Tính năng Nginx | Môi trường Production | Môi trường Sandbox (Hiện tại) | Ảnh hưởng đến việc Tái hiện lỗi |
| :--- | :--- | :--- | :--- |
| **Vùng nhớ chia sẻ (`zone`)** | **Có kích hoạt** (`zone upstream_name 128k;`) | **Không kích hoạt** | **Mất đồng bộ trạng thái lỗi:** Trên Prod, tất cả Worker Processes dùng chung vùng nhớ này nên chỉ cần tổng số lỗi của các Worker đạt ngưỡng `max_fails`, Node sẽ bị block trên toàn diện rộng ngay lập tức. Ở Sandbox, bộ đếm lỗi nằm rời rạc ở từng Worker, tải lỗi bị xé nhỏ nên không chạm được ngưỡng khóa Node. |
| **Thuật toán cân bằng tải** | **`least_conn`** (Ít kết nối nhất) | **Round Robin** (Mặc định - Chia đều) | **Mất hiệu ứng bẫy dòng tải:** Khi Node Cloudian đóng socket sớm, số lượng kết nối hoạt động của nó tụt về `0`. Thuật toán `least_conn` trên Prod hiểu nhầm đây là Node rảnh nhất nên **tống toàn bộ request tiếp theo vào Node lỗi này**, làm tràn bộ đếm `max_fails` trong micro-giây. Sandbox dùng Round Robin nên tải vẫn chia đều sang các Node khác, che lấp đi lỗ hổng. |
| **Cấu hình chặn Node** | `max_fails=2; fail_timeout=5s;` | Không đồng bộ thông số | Tần số khóa Node trên Sandbox bị chậm hơn, khiến hệ thống tự phục hồi trước khi kịp sập dây chuyền. |

### 6.2. Khác biệt về đặc tính tải (Traffic Profile) và kích thước Object
* **Kích thước file test:** Trên Sandbox đang thử nghiệm với file dung lượng quá lớn (10MB - 100MB) hoặc quá nhỏ. File trên Production bị lỗi có kích thước đặc thù là **~1.9MB**. 
* **Cơ chế truyền tải:** Lệnh `aws s3 cp` trên Sandbox mở kết nối tuần tự hoặc bị nghẽn I/O ngay tại ổ đĩa Client (do ghi log `--debug` xuống đĩa quá nặng), không tạo ra tốc độ bắn request đồng thời (Concurrent High PUT Rate) như SDK của Loki và APM Trace trên Production (vốn đẩy dữ liệu trực tiếp từ RAM ra Network).

---

## 7. Ảnh hưởng của `zone` + `least_conn` đến Reproduce

### 7.1 Không có `zone` (sandbox hiện tại)

```
worker-1: node-1 fails=1, node-2 OK,     node-3 OK
worker-2: node-1 OK,      node-2 fails=1, node-3 OK
worker-3: node-1 OK,      node-2 OK,      node-3 fails=1

→ Không worker nào tích lũy đủ max_fails=2 trên 1 node
→ Cascade KHÔNG xảy ra dù có 1300+ concurrent jobs
```

### 7.2 Có `zone 128k` (production behavior)

```
shared memory — tất cả workers đọc/ghi chung:
  worker-1 thấy node-1 fail → ghi: node-1 fails=1
  worker-2 thấy node-1 fail → ghi: node-1 fails=2 ← đạt max_fails
  → TẤT CẢ workers đồng loạt mark node-1 DOWN
```

### 7.3 Ảnh hưởng của `least_conn`

```
Khi QuotaExceeded reject nhanh (~1ms):
  node-1: 0 active conn (vừa reject xong)
  node-2: 50 active conn (đang upload)
  node-3: 48 active conn (đang upload)

least_conn → chọn node-1 (ít conn nhất)
→ node-1 lại reject → về 0 conn
→ least_conn lại chọn node-1
→ node-1 nhận traffic nhiều hơn → fail nhanh hơn
→ Cascade xảy ra nhanh hơn nhiều so với round-robin
```

---

## 8. Config Cần Update trên sb-01 để Match Production

### 8.1 File `s3-hcm.sds.infiniband.vn.conf`

```nginx
upstream hyperstore-cloudian-s3-hcm {
        zone upstream_hyperstore-cloudian-s3-hcm 128k;          # thêm
        least_conn;                                             # thêm
        server 172.26.29.231:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        server 172.26.29.232:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        server 172.26.29.233:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        server 172.26.29.234:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        keepalive 60;
        keepalive_timeout 45s;                                  # thêm
        keepalive_requests 200;                                 # thêm
}
```

### 8.2 File `s3-hni.sds.infiniband.vn.conf`

```nginx
upstream hyperstore-cloudian-s3-hni {
        zone upstream_hyperstore-cloudian-s3-hni 128k;          # thêm
        least_conn;                                             # thêm
        server 172.25.171.24:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        server 172.25.171.25:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        server 172.25.171.26:443 max_fails=2 fail_timeout=5s;   # 10 → 5s
        keepalive 60;
        keepalive_timeout 45s;                                  # thêm
        keepalive_requests 200;                                 # thêm
}
```

### 8.3 File `proxy_options_s3.conf`

```nginx
proxy_send_timeout 300s;   # 60s → 300s
proxy_read_timeout 300s;   # 60s → 300s
```

### 8.4 Apply config

```bash
# Test và reload
docker exec cloudian-nginx-with-prometheus nginx -t && docker exec cloudian-nginx-with-prometheus nginx -s reload
```

---

## 9. Kịch bản tác động (Cascade Lockout Scenario trên Production)
Để hiểu rõ tại sao sự bất đối xứng cấu hình làm Sandbox không bị lỗi, đây là quy trình sập chuỗi diễn ra trên Production nhờ có `zone` và `least_conn`:

```txt
[Client PUT Request] 
      │
      ▼
[Nginx Layer] ──(least_conn định tuyến vào Node lỗi phản hồi nhanh)──► [Cloudian Node 1 (Quota Exceeded)]
      │                                                                      │
      ◄──(Đóng socket sớm / Broken Pipe - Bộ đếm lỗi tập trung tăng +1)──────┘
```

> **Bước 1:** Client bắn loạt request `PUT` 1.9MB của User hết Quota vào Nginx.
> 
> **Bước 2:** Nginx chuyển tiếp vào Node Cloudian 1. Node 1 trả lỗi 403 và đóng socket sớm $\rightarrow$ Sinh lỗi mạng `Broken Pipe` $\rightarrow$ Active Connection của Node 1 về `0`.
> 
> **Bước 3:** Thuật toán `least_conn` thấy Node 1 có `0` connection, lập tức điều hướng các request tiếp theo vào tiếp Node 1.
> 
> **Bước 4:** Vùng nhớ chia sẻ `zone` cập nhật biến tổng, kích hoạt `max_fails=2`. Toàn bộ các Worker chung lòng **Khóa Node 1 trong 5 giây**.
> 
> **Bước 5:** Node 1 bị khóa, dòng tải dồn sang Node 2. Quy trình lặp lại khiến Node 2, Node 3... cho đến Node 12 bị khóa sạch trong tích tắc. Nginx cắt đứt kết nối hoàn toàn và trả về `502 No live upstreams`.

---

## 10. Hành động yêu cầu để Đồng bộ và Tái hiện thành công lỗi trên Sandbox

Để Sandbox có thể "gọi lỗi" thành công phục vụ cho việc kiểm thử bản vá, bộ phận CloudOps cần thực hiện ngay các bước sau:

1. **Đồng bộ file cấu hình Nginx Upstream:** Sửa đổi cấu hình Upstream của Sandbox, thêm từ khóa `zone` và chuyển thuật toán sang `least_conn` giống hệt Production:
```nginx
upstream hyperstore-cloudian-s3-hcm {
    # 1. Kích hoạt vùng nhớ chia sẻ chung giữa các Worker để đồng bộ bộ đếm lỗi
    zone upstream_hyperstore-cloudian-s3-hcm 128k;

    # 2. Bật thuật toán ít kết nối nhất để giả lập hiệu ứng hố đen hút request
    least_conn;

    # 3. Danh sách các Backend Node Sandbox hiện tại
    server 172.26.29.231:443 max_fails=2 fail_timeout=5;
    server 172.26.29.232:443 max_fails=2 fail_timeout=5;
    server 172.26.29.233:443 max_fails=2 fail_timeout=5;

    # Giữ nguyên thông số keepalive của hệ thống
    keepalive 60;
}
```

2. Nạp lại cấu hình và thực hiện Kịch bản ép tải

```bash
# Thực hiện reload lại Nginx trong container Docker:
docker exec cloudian-nginx-with-prometheus nginx -s reload

# Sử dụng file test dữ liệu giả lập có kích thước chuẩn ~1.9MB (Tránh dùng file quá nhỏ hoặc quá lớn 10MB/100MB để đảm bảo xuất hiện lỗi Broken pipe đúng thời điểm gửi body):
dd if=/dev/urandom of=./filetest.bin bs=1 count=1925333

# Chạy script kiểm thử với lệnh exec tối ưu hóa tiến trình và lưu log vào RAM Disk /dev/shm để tránh nghẽn I/O máy client:
seq 1 300 | xargs -n 1 -P 300 -I {} bash -c "exec aws s3 cp ./filetest.bin s3://test-thuyldx/file_{}.bin --no-verify-ssl --debug 2> /dev/shm/1/debug_job_{}_\$(date +%Y%m%d_%H%M%S).log"
```

## 11. Reproduce Workflow

### Bước 1 — Đảm bảo user vượt quota

```bash
# Upload thêm để vượt quota 10GiB
aws s3 cp testfile-500mb.bin s3://test-thuyldx/fill-1.bin --no-progress
time (export AWS_ACCESS_KEY_ID=68c526776d67b2d6da51 && export AWS_SECRET_ACCESS_KEY=Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10 && export AWS_DEFAULT_REGION=us-east-1 && export AWS_ENDPOINT_URL="https://s3-hcm.sds.infiniband.vn:443" && export AWS_MAX_ATTEMPTS=1 && aws s3 cp debug_log_s3/testfile-100mb.bin s3://test-thuyldx/testfile.bin --debug 2> debug_$(date +%Y%m%d_%H%M%S).log)
time (export AWS_ACCESS_KEY_ID=7d03846abab4d2e10e3b && export AWS_SECRET_ACCESS_KEY=H3w3W4kTWApvV7TxZTft9iFwuAnCC/XJQXD47q1C && export AWS_DEFAULT_REGION=us-east-1 && export AWS_ENDPOINT_URL="https://s3-hcm.sds.infiniband.vn:443" && export AWS_MAX_ATTEMPTS=1 && aws s3 cp debug_log_s3/testfile-100mb.bin s3://thuyldx-hni/testfile-4.bin --debug 2> debug_$(date +%Y%m%d_%H%M%S).log)
# Lặp lại đến khi usage > 10GiB
```

### Bước 2 — Tạo concurrent upload (file 1GB để duy trì connection)

```bash
# Chạy trên 5 test VM cùng lúc
#!/bin/bash
export AWS_ACCESS_KEY_ID="68c526776d67b2d6da51"
export AWS_SECRET_ACCESS_KEY="Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ENDPOINT_URL="https://s3-hcm.sds.infiniband.vn:443"
export AWS_MAX_ATTEMPTS=1
LOGFILE="1"

#1. Tạo file dummy 1925333 byte ~ 1.9MB nếu chưa tồn tại
if [ ! -f ./testfile-10mb.bin ]; then
   dd if=/dev/urandom of=/tmp/filetest.bin bs=1 count=1925333
fi

seq 1 300 | xargs -n 1 -P 300 -I {} bash -c "aws s3 cp ./filetest.bin s3://test-thuyldx/file_{}.bin --debug 2> /dev/shm/${LOGFILE}/debug_job_{}_\$(date +%Y%m%d_%H%M%S).log"
```

```bash
#!/bin/bash
export AWS_ACCESS_KEY_ID="68c526776d67b2d6da51"
export AWS_SECRET_ACCESS_KEY="Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ENDPOINT_URL="https://s3-hcm.sds.infiniband.vn:443"
#export AWS_MAX_ATTEMPTS=1
LOGDIR="/dev/shm/hyperstore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"
END=$((SECONDS + ))   # 1m=60s,2m=120s,3m=180s,...
i=0
while [ $SECONDS -lt $END ]; do
    i=$((i + 1))
    aws s3 cp ./filetest.bin "s3://test-thuyldx/file_${RANDOM}_${i}.bin" --no-progress --debug 2> "${LOGDIR}/debug_${i}.log" &

    # Giữ đúng 300 concurrent
    while [ $(jobs -r | wc -l) -ge 500 ]; do
        sleep 0.05
    done
done
wait
echo ">>> Done: $i total jobs"
```

```bash
#!/bin/bash
export AWS_ACCESS_KEY_ID="68c526776d67b2d6da51"
export AWS_SECRET_ACCESS_KEY="Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ENDPOINT_URL="https://s3-hcm.sds.infiniband.vn:443"
#export AWS_MAX_ATTEMPTS=1
LOGFILE="1"
# Tạo stream số liên tục trong 3 phút
timeout 180 bash -c '
  i=0
  while true; do
    echo $((++i))
  done
' | xargs -n 1 -P 300 -I {} bash -c "aws s3 cp ./filetest.bin s3://test-thuyldx/file_{}.bin --no-progress --debug 2> /dev/shm/${LOGFILE}/debug_job_{}_\$(date +%Y%m%d_%H%M%S).log"
```


### Bước 3 — Monitor

```bash
# Terminal 1: QuotaExceeded trên HyperStore
tail -f /var/log/cloudian/cloudian-request-info.log \
  | grep --line-buffered "QuotaExceeded"

# Terminal 2: Nginx error log
tail -f /var/log/nginx/error.log \
  | grep --line-buffered -iE "SSL_write|Broken pipe|no live upstreams"

# Terminal 3: Nginx access log
tail -f /var/log/nginx/s3-hni.sds.infiniband.vn.access.log \
  | grep --line-buffered "502"

# Terminal 4: ESTABLISHED connections
watch -n 1 'hsctl cmd run "netstat -an | grep :443 | grep ESTABLISHED | wc -l" --regions=hni'

# Terminal 5: Concurrent jobs
watch -n 0.5 'ps aux | grep "[a]ws s3 cp" | wc -l'
```

---

## 12. Câu hỏi gửi Cloudian Team

1. **Expected behavior?** HyperStore đóng TLS connection trước khi gửi HTTP response headers khi QuotaExceeded dưới high load — có phải là behavior dự kiến không? Có configurable không?

2. **Config recommendation?** Có setting nào trên HyperStore đảm bảo HTTP response (bao gồm status line và headers) luôn được gửi về upstream proxy trước khi đóng connection, kể cả trong điều kiện quota hay error?

3. **Related settings?** Các setting `s3.threads.idleTimeout`, `s3.lowRes.idleTimeout` có ảnh hưởng đến early connection termination behavior này không?

4. **Deployment pattern?** Có recommended pattern nào khi deploy HyperStore sau Nginx upstream proxy để tránh cascade failure khi user-level quota events xảy ra?

---

## 11. Files đính kèm

| File | Nội dung |
|---|---|
| `hni-01.conf` | Nginx production node 1 — full config (`nginx -T`) |
| `hni-02.conf` | Nginx production node 2 — full config (`nginx -T`) |
| `sb-01.conf` | Nginx sandbox node 1 — full config (`nginx -T`) |
| `sb-02.conf` | Nginx sandbox node 2 — full config (`nginx -T`) |