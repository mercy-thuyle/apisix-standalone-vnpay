# BÁO CÁO PHÂN TÍCH HỆ THỐNG: ĐÁNH GIÁ SỰ KHÁC BIỆT CẤU HÌNH GIỮA PRODUCTION VÀ SANDBOX
**Mã sự cố tham chiếu:** HyperStore Early Connection Close on User QuotaExceeded causing Nginx Upstream Cascade Failure.
**Ngày lập báo cáo:** 05/06/2026
**Tác giả:** CloudOps Team / System Administrator

---

## 1. Tổng quan sự cố trên Production
Vào ngày 20/05/2026, môi trường Production gặp sự cố sập dây chuyền (Cascade Failure) lớp Nginx Reverse Proxy, trả về lỗi `502 Bad Gateway` diện rộng cho toàn bộ S3 client. 

**Cơ chế lỗi gốc (Root Cause):** Một tài khoản người dùng bị hết hạn mức lưu trữ (`QuotaExceeded`). Khi client gửi request `PUT` với dữ liệu lớn (~1.9MB), cụm Cloudian Hyperstore đọc phần Headers trước, phát hiện hết hạn mức nên chủ động **Đóng kết nối sớm (Early Connection Close)** để từ chối nhận File. Do Nginx vẫn đang trong tiến trình đẩy nốt Body dữ liệu, việc socket bị đóng đột ngột sinh ra lỗi mạng `SSL_write() failed (32: Broken pipe)`. 

Trận lụt lỗi này đã kích hoạt cơ chế cô lập Upstream của Nginx, khóa chặn toàn bộ 12 Node S3 Cloudian vật lý trên Production mặc dù các Node này hoàn toàn khỏe mạnh.

---

## 2. Nguyên nhân Sandbox chưa thể tái hiện (Reproduce) được lỗi

Hiện tại, môi trường Sandbox đã được giả lập trạng thái `QuotaExceeded` và chạy kịch bản ép tải bằng `xargs/aws-cli` nhưng hệ thống **vẫn hoạt động bình thường, không xảy ra lỗi 502 dây chuyền**. Qua đối soát hệ thống, chúng tôi xác định các nguyên nhân cốt lõi sau:

### 2.1. Lý do hàng đầu: Sự bất đối xứng về cấu hình Nginx Upstream (Trọng tâm)
Cấu hình định tuyến và quản lý trạng thái Upstream giữa Sandbox và Production đang có sự khác biệt rất lớn, làm mất đi "phản ứng dây chuyền" dẫn đến sập cụm proxy.
- Toàn bộ cấu hình trên Production HNI: 
  - [hni-1](../nginx/production/hni/hni-01.conf)
  - [hni-2](../nginx/production/hni/hni-02.conf)
- Toàn bộ cấu hình trên sandbox: 
  - [sb-1](../nginx/sandbox/sb-s3-lb-1/sb-01.conf)
  - [sb-2](../nginx/sandbox/sb-s3-lb-2/sb-02.conf)

| Tính năng Nginx | Môi trường Production | Môi trường Sandbox (Hiện tại) | Ảnh hưởng đến việc Tái hiện lỗi |
| :--- | :--- | :--- | :--- |
| **Vùng nhớ chia sẻ (`zone`)** | **Có kích hoạt** (`zone upstream_name 128k;`) | **Không kích hoạt** | **Mất đồng bộ trạng thái lỗi:** Trên Prod, tất cả Worker Processes dùng chung vùng nhớ này nên chỉ cần tổng số lỗi của các Worker đạt ngưỡng `max_fails`, Node sẽ bị block trên toàn diện rộng ngay lập tức. Ở Sandbox, bộ đếm lỗi nằm rời rạc ở từng Worker, tải lỗi bị xé nhỏ nên không chạm được ngưỡng khóa Node. |
| **Thuật toán cân bằng tải** | **`least_conn`** (Ít kết nối nhất) | **Round Robin** (Mặc định - Chia đều) | **Mất hiệu ứng bẫy dòng tải:** Khi Node Cloudian đóng socket sớm, số lượng kết nối hoạt động của nó tụt về `0`. Thuật toán `least_conn` trên Prod hiểu nhầm đây là Node rảnh nhất nên **tống toàn bộ request tiếp theo vào Node lỗi này**, làm tràn bộ đếm `max_fails` trong micro-giây. Sandbox dùng Round Robin nên tải vẫn chia đều sang các Node khác, che lấp đi lỗ hổng. |
| **Cấu hình chặn Node** | `max_fails=2; fail_timeout=5s;` | Không đồng bộ thông số | Tần số khóa Node trên Sandbox bị chậm hơn, khiến hệ thống tự phục hồi trước khi kịp sập dây chuyền. |

### 2.2. Khác biệt về đặc tính tải (Traffic Profile) và kích thước Object
* **Kích thước file test:** Trên Sandbox đang thử nghiệm với file dung lượng quá lớn (10MB - 100MB) hoặc quá nhỏ. File trên Production bị lỗi có kích thước đặc thù là **~1.9MB**. 
* **Cơ chế truyền tải:** Lệnh `aws s3 cp` trên Sandbox mở kết nối tuần tự hoặc bị nghẽn I/O ngay tại ổ đĩa Client (do ghi log `--debug` xuống đĩa quá nặng), không tạo ra tốc độ bắn request đồng thời (Concurrent High PUT Rate) như SDK của Loki và APM Trace trên Production (vốn đẩy dữ liệu trực tiếp từ RAM ra Network).

---

## 3. Kịch bản tác động (Cascade Lockout Scenario trên Production)
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

## 4. Hành động yêu cầu để Đồng bộ và Tái hiện thành công lỗi trên Sandbox

Để Sandbox có thể "gọi lỗi" thành công phục vụ cho việc kiểm thử bản vá, bộ phận CloudOps cần thực hiện ngay các bước sau:

1. **Đồng bộ file cấu hình Nginx Upstream:** Sửa đổi cấu hình Upstream của Sandbox, thêm từ khóa `zone` và chuyển thuật toán sang `least_conn` giống hệt Production:
   ```nginx
   upstream hyperstore-cloudian-s3-hcm {
       zone upstream_hyperstore-cloudian-s3-hcm 128k;
       least_conn;

       server 172.26.29.231:443 max_fails=2 fail_timeout=5;
       server 172.26.29.232:443 max_fails=2 fail_timeout=5;
       server 172.26.29.233:443 max_fails=2 fail_timeout=5;
       keepalive 60;
   }