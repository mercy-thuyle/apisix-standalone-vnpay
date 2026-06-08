GIAI ĐOẠN ĐẦU
2 DC, DC1 và DC2. Đã và đang chạy các dịch vụ (container k8s, on-host/bare metal/VM) -> HAProxy, LB và DNS.
Hiện tại sẽ triển Ceph S3 với mô hình multisite zone DC1 (ubuntu 22.04, cephadm tentacle, podman) và zone DC2 (ubuntu 22.04, cephadm tentacle, podman) tại 2 DC. Chỉ dịch vụ Ceph S3 này sẽ Sử dụng APISIX thay cho HAProxy và LB.
có 2 APISIX tại 2 DC, gồm apisix1 (ubuntu 22.04) và apisix2 (ubuntu 22.04) và 1 etcd hoặc cụm raft tối thiểu 3 etcd được dùng để lưu config-database.

Có 3 trường hợp chia mô hình như sau:
trường hợp 1: decouple với cụm raft 3 etcd, apisix1 có CP (Admin API và Dashboard), DP1 và etcd1 và etcd3. apisix2 có DP2 và etcd2
```
┌─────────────────────────────────────┐   ┌─────────────────────────────┐
│              DC1                    │   │            DC2              │
│                                     │   │                             │
│  ┌─────────────┐  ┌──────────────┐  │   │  ┌──────────────────────┐   │
│  │     CP      │  │    etcd-1    │  │   │  │       etcd-2         │   │
│  │(Admin API + │──│   :2379      │◄─┼───┼─►│      :2379           │   │
│  │ Dashboard)  │  └──────────────┘  │   │  └──────────────────────┘   │
│  └──────┬──────┘         ▲          │   │            ▲                │
│         │         Raft   │          │   │    watch   │                │
│         │          sync  │          │   │            │                │
│  ┌──────┴──────┐  ┌──────┴───────┐  │   │  ┌─────────┴────────────┐   │
│  │    DP1      │  │    etcd-3    │  │   │  │        DP2           │   │
│  │(Data Plane) │  │   :2381      │  │   │  │    (Data Plane)      │   │
│  └──────▲──────┘  └──────────────┘  │   │  └──────────────────────┘   │
│  watch  │                           │   │            ▲                │
│         │  [etcd-1 & etcd-3 cùng    │   │            │                │
└─────────┼── DC1 → vi phạm Raft! ❌]─┘   └────────────┼────────────────┘
          │                                            │
    S3 Client                                   S3 Client
                    Admin ──► CP (chỉ DC1)
```
ưu: 
- chỉ duy nhất 1 điểm write là CP ở DC1, các DP ở 2 DC sẽ watch và láy config về -> mang tính quản lý/vận hành tập trung. 
- chịu được 1 etcd lỗi.
- CP chỉ làm 1 việc: nhận Admin API request → ghi vào etcd
- DP tách hoàn toàn khỏi CP → scale DP độc lập không ảnh hưởng CP
- Security tốt hơn: DP không expose Admin API → Attack surface nhỏ hơn Traditional mode
- Khi mở rộng thêm DP (DC3, K8s): chỉ cần trỏ etcd, không cần deploy thêm CP
- CP die:
  ├─ DP1 vẫn xử lý S3 traffic bình thường ✅
  ├─ DP2 vẫn xử lý S3 traffic bình thường ✅
  ├─ Không thể thay đổi config (route/plugin/upstream) ⚠️ cho đến khi CP sống lại
  └─ etcd vẫn sống → DP vẫn có config cũ trong memory
  Khác với DP die:
    ├─DP die → S3 request fail ngay lập tức ❌ → CẦN HA
    └─CP die → Chỉ mất khả năng config change ⚠️ → Không cần HA gấp
nhược: 
- Độ phức tạp cao khi triển khai và vận hành cần có nhiều cost hơn trong giai đoạn đầu với scale nhỏ chỉ dùng trước cho Ceph S3. với raft 3 etcd cần monitor health 3 etcd này và check leader.
- Độ trễ latency khi write etcd DC1 và đợi cross qua etcd ở DC2 nhưng chấp nhận được hay không
- etcd-1 và etcd-3 cùng trên DC1 VM:
  ├─ DC1 die → mất 2/3 etcd → mất quorum ❌
  ├─→ CP die + etcd mất quorum → DP không nhận config mới dù etcd2 sống
  └─→ Toàn bộ Raft 3 node trở nên vô nghĩa
- CP là SPOF của tầng control: DC1 die → CP chết, không có CP nào thay thế (Decoupled không có CP tại DC2)
  ├─→ Khác Case 2/4: không có CP dự phòng ở DC2
  └─→ MTTR config change = thời gian DC1 recover hoàn toàn

- Không có tiebreaker thực sự: etcd-3 tại DC1 không phải tiebreaker độc lập
  ├─ Network partition DC1 vs DC2:
  ├─→ etcd-1+etcd-3 (DC1) giữ quorum
  └─→ etcd-2 (DC2) bị kick → DC2 DP không sync được


trường hợp 2: traditional với cụm raft 3 etcd, apisix1 có CP1 (Admin API và Dashboard), DP1 và etcd1 và etcd3. apisix2 có CP2 (Admin API và Dashboard), DP2 và etcd2
```
┌──────────────────────────────────────┐   ┌──────────────────────────────────┐
│               DC1                    │   │              DC2                 │
│                                      │   │                                  │
│  ┌──────────────┐  ┌──────────────┐  │   │  ┌──────────────┐  ┌──────────┐  │
│  │     CP1      │  │   etcd-1     │  │   │  │     CP2      │  │ etcd-2   │  │
│  │ (Admin API + │──│   :2379      │◄─┼───┼─►│ (Admin API + │──│  :2379   │  │
│  │  Dashboard)  │  └──────┬───────┘  │   │  │  Dashboard)  │  └────▲─────┘  │
│  └──────┬───────┘         │Raft      │   │  └──────┬───────┘  Raft │        │
│         │          ┌──────┴───────┐  │   │         │               │        │
│         │          │   etcd-3     │  │   │         │               │        │
│         │          │   :2381      │  │   │         │               │        │
│         │          └──────────────┘  │   │         │               │        │
│  ┌──────┴───────┐                    │   │  ┌──────┴───────┐       │        │
│  │     DP1      │◄── watch etcd-1    │   │  │     DP2      │◄── watch etcd-2│
│  │ (Data Plane) │                    │   │  │ (Data Plane) │                │
│  └──────▲───────┘                    │   │  └──────▲───────┘                │
└─────────┼────────────────────────────┘   └─────────┼────────────────────────┘
          │                                           │
    S3 Client                                   S3 Client
  Admin ──► CP1                               Admin ──► CP2
  [etcd-1+etcd-3 cùng DC1 → Raft quorum risk ❌]
```
ưu:
- cả 2 DC đều có CP và khi có sự cố tại 1 DC thì DC còn lại vẫn còn CP để sử dụng và update -> đảm bảo SLA
- Đáp ứng đc push config liên tục (CI/CD)
- DP vẫn serve traffic khi 1 DC die (config cũ trong memory — không bị crash ngay)
- Traditional mode đơn giản hơn Decoupled để debug (1 process, 1 log stream, không phân biệt CP/DP process)
- Không cần học Decoupled mode phức tạp
nhược: 
- etcd-1 và etcd-3 cùng trên DC1 VM — vấn đề: DC1 die → mất 2/3 etcd → mất quorum ❌
  ├─→ Cluster mất quorum ngay lập tức ❌
  ├─→ etcd-2 tại DC2 còn lại 1/3 → không đủ quorum
  ├─→ Toàn bộ cluster tê liệt dù DC2 vẫn sống
  └─→ Raft 3 node nhưng bố trí sai DC

- etcd-3 đặt ở DC1 thay vì VM riêng: Nếu DC1 có etcd-1 + etcd-3: tổng 2 Raft node tại 1 failure domain
  ├─→ Failure domain của DC1 = 2 etcd node
  └─→ Vi phạm nguyên tắc cơ bản: 1 failure domain = 1 etcd node

- Quản lý 2 etcd process trên cùng 1 VM phức tạp: 2 etcd instance cần 2 data-dir riêng, 2 port riêng
  ├─→ etcd-1: :2379/:2380
  ├─→ etcd-3: :2381/:2382 (hoặc port khác)
  ├─→ Config phức tạp hơn, dễ nhầm lẫn khi vận hành
  └─→ Khi DC1 VM resource đầy: 2 etcd cạnh tranh disk I/O

- etcd yêu cầu disk I/O thấp latency (SSD): 2 etcd trên cùng 1 disk → I/O contention
  └─→ Raft write performance giảm khi cả 2 etcd đang fsync

- Không có tiebreaker thực sự:
  ├─ Tiebreaker phải là node ĐỘCLẬP với 2 DC
  ├─→ etcd-3 tại DC1 không phải tiebreaker
  ├─→ Nếu DC1-DC2 network partition: etcd-1+etcd-3 (DC1) = quorum
  ├─  etcd-2 (DC2) = minority → bị kick ra
  └─→ DC2 luôn thua trong partition scenario dù CP2 vẫn sống


trường hợp 3: decouple với apisix1 có CP (Admin API và Dashboard), DP1 và 1 etcd. apisix2 có DP2.
```
┌──────────────────────────────────────┐   ┌──────────────────────────────────┐
│               DC1                    │   │              DC2                 │
│                                      │   │                                  │
│  ┌──────────────┐  ┌──────────────┐  │   │  ┌──────────────────────────┐    │
│  │      CP      │  │    etcd      │  │   │  │           DP2            │    │
│  │ (Admin API + │──│  (single)    │  │   │  │       (Data Plane)       │    │
│  │  Dashboard)  │  │  :2379  ◄────┼──┼───┼──│── watch cross-DC         │    │
│  └──────────────┘  └──────────────┘  │   │  └──────────────────────────┘    │
│         │                 ▲          │   │                                  │
│  ┌──────┴───────┐   watch │          │   │  [DP2 phụ thuộc etcd DC1 ❌]     │
│  │     DP1      │─────────┘          │   │                                  │
│  │ (Data Plane) │                    │   │                                  │
│  └──────▲───────┘                    │   │                                  │
└─────────┼────────────────────────────┘   └──────────────────────────────────┘
          │
    S3 Client                                   S3 Client ──► DP2
  Admin ──► CP
  [DC1 die = mất hết: CP + etcd + DP1 ❌ | DP2 chỉ dùng config cũ ⚠️]
```
ưu:
- không bao giờ bị spilt brain.
- có thể triển khai etcd là bare-metal/VM onhost, backup volume hoặc snapshot là dễ dàng.
- Đơn giản nhất để setup và vận hành ban đầu → Phù hợp giai đoạn đầu team chưa quen APISIX
- Không cần monitor etcd cluster, không cần hiểu Raft
- Chi phí resource thấp nhất (1 etcd, 1 CP process)
- DP2 vẫn serve traffic khi DC1 die (config cũ trong memory — S3 read vẫn hoạt động)
- Khi DC1 recover: DP2 tự động sync lại không cần can thiệp
nhược: 
- DC1 die = mất hết cùng lúc:
  ├─ CP die → không config được ❌
  ├─ etcd die → DP1 và DP2 không nhận config mới ❌
  ├─ DP1 die → mất 1/2 traffic capacity ❌
  └─ Chỉ còn DP2 sống, dùng config cũ từ memory → đọc được, ghi có thể lỗi
- etcd là SPOF nghiêm trọng nhất:
  ├─ Mọi thứ phụ thuộc vào 1 etcd duy nhất
  ├─ etcd disk full / corrupt → CP không ghi được → toàn bộ tê liệt
  └─ Không có Raft → không tự recover, phải restore từ backup thủ công
- DP2 hoàn toàn phụ thuộc DC1:
  ├─ DP2 chỉ là "bình chứa" nhận config từ CP qua etcd ở DC1
  ├─ DC1 network flap → DP2 không sync được config mới
  └─ (DP2 vẫn serve traffic với config cũ — nhưng không update được)
- Scalability kém:
  ├─ Muốn thêm DP3 → vẫn phải kết nối về etcd DC1
  └─ Cross-DC etcd write latency tăng theo số DP
- Thời gian recovery khi etcd die:
  ├─Phải restore từ snapshot thủ công
  ├─→ Downtime Admin API trong suốt thời gian restore
  └─→ MTTR phụ thuộc hoàn toàn vào backup schedule và kỹ năng vận hành

trường hợp 4: traditional với apisix1 có CP1 (Admin API và Dashboard), DP1 và 1 etcd. apisix2 có CP2 (Admin API và Dashboard), DP2.
```
┌──────────────────────────────────────┐   ┌──────────────────────────────────┐
│               DC1                    │   │              DC2                 │
│                                      │   │                                  │
│  ┌──────────────┐  ┌──────────────┐  │   │  ┌──────────────────────────┐    │
│  │     CP1      │  │    etcd      │  │   │  │           CP2            │    │
│  │ (Admin API + │──│  (single)    │  │   │  │       (Admin API +       │    │
│  │  Dashboard)  │  │  :2379       │  │   │  │        Dashboard)        │    │
│  └──────────────┘  └──────┬───────┘  │   │  └──────────────┬───────────┘    │
│         │                 │ watch    │   │          write  │                │
│  ┌──────┴───────┐         │          │   │  cross-DC ──────┘                │
│  │     DP1      │◄────────┘          │   │  watch cross-DC                  │
│  │ (Data Plane) │                    │   │  ┌──────────────────────────┐    │
│  └──────▲───────┘                    │   │  │           DP2            │    │
└─────────┼────────────────────────────┘   │  │       (Data Plane) ◄─────┼────┘
          │                                │  └──────────────────────────┘    │
    S3 Client                              └──────────────────────────────────┘
  Admin ──► CP1 (fast)                         S3 Client
                                               Admin ──► CP2 (slow, cross-DC RTT)
  [DC1 die → etcd die → CP2 vô dụng dù sống ❌]
```
ưu:
- không bao giờ bị spilt brain.
- có thể triển khai etcd là bare-metal/VM onhost, backup volume hoặc snapshot là dễ dàng.
- CP2 luôn active — không cần promote, không cần failover thủ công
- Đơn giản hơn Case 1 và Case 2 (không cần Raft)
- CP2 active hữu dụng khi DC1 sống nhưng chậm/bận: → Admin có thể dùng CP2 để config thay thế tạm thời
- Dashboard tại DC2 luôn available khi DC1 sống
- DP2 vẫn serve traffic khi DC1 die (config cũ)
nhược:
- etcd vẫn là SPOF — vấn đề gốc rễ không được giải quyết:
  ├─ DC1 die → etcd die
  ├─→ CP1 die ❌
  ├─→ CP2 còn sống nhưng MẤT etcd → CP2 không nhận được Admin API request ❌ (không có etcd để đọc/ghi)
  ├─→ DP1 die ❌
  ├─→ DP2 còn sống nhưng không sync được config mới ⚠️ (chỉ serve với config cũ trong memory)
  └─ CP2 "active" nhưng vô dụng khi etcd chết — vì CP APISIX bắt buộc cần etcd để xử lý mọi Admin API request

- Cross-DC latency cho mọi write operation:
  ├─ Admin gọi CP2 (DC2) → CP2 write vào etcd (DC1)
  ├─→ Mọi config change qua CP2 đều có RTT DC2→DC1
  ├─→ Nếu RTT cao: Admin API response chậm khi dùng CP2
  └─→ Bình thường dùng CP1 là fast, CP2 là slow

- CP2 phụ thuộc network DC2 → DC1 liên tục:
   Network partition giữa DC1 và DC2:
  ├─→ CP2 mất kết nối etcd → CP2 không dùng được ❌
  ├─→ Dù cả 2 DC đều physically sống
  └─→ Đây là partial failure khó debug hơn DC die hoàn toàn

- DP2 phụ thuộc etcd DC1 để sync config: Network DC1→DC2 flap → DP2 không nhận config mới
  └─→ Config drift giữa DP1 và DP2 nếu flap kéo dài

- Backup etcd đơn giản nhưng restore phức tạp hơn Case 3: DC1 die → restore etcd lên đâu?
  ├─→ Restore lên DC2: phải update config CP2 và DP2trỏ sang etcd mới tại DC2 → restart services
  └─→ MTTR: 20–45 phút

- Không tốt hơn Case 3 về HA thực chất:
  ├─ Case 3: DC1 die → DP2 chạy config cũ, không config được
  ├─ Case 4: DC1 die → DP2 chạy config cũ, không config được
  ├─ (CP2 có sống nhưng cũng không config được)
  └─→ Outcome giống nhau, Case 4 chỉ thêm CP2 process tốn RAM

trường hợp 5: decouple với apisix1 có CP (Admin API và Dashboard), DP1 và 1 cluster k8s etcd (3 pod). apisix2 có DP2.
```
┌──────────────────────────────────────┐   ┌──────────────────────────────────┐
│               DC1                    │   │              DC2                 │
│                                      │   │                                  │
│  ┌──────────────┐  ┌──────────────┐  │   │  ┌──────────────────────────┐    │
│  │      CP      │  │    etcd      │  │   │  │           DP2            │    │
│  │ (Admin API + │──│  (cluster)   │  │   │  │       (Data Plane)       │    │
│  │  Dashboard)  │  │  :2379  ◄────┼──┼───┼──│── watch cross-DC         │    │
│  └──────────────┘  └──────────────┘  │   │  └──────────────────────────┘    │
│         │                 ▲          │   │                                  │
│  ┌──────┴───────┐   watch │          │   │  [DP2 phụ thuộc etcd DC1 ❌]     │
│  │     DP1      │─────────┘          │   │                                  │
│  │ (Data Plane) │                    │   │                                  │
│  └──────▲───────┘                    │   │                                  │
└─────────┼────────────────────────────┘   └──────────────────────────────────┘
          │
    S3 Client                                   S3 Client ──► DP2
  Admin ──► CP
  [DC1 die = mất hết: CP + etcd + DP1 ❌ | DP2 chỉ dùng config cũ ⚠️]
```
ưu:
- etcd cluster K8s (3 pod) chịu được 1 pod lỗi mà không mất quorum → bền hơn Case 3 (single etcd SPOF).
- K8s tự restart etcd pod khi crash (liveness probe + restart policy) → MTTR etcd thấp hơn so với single etcd VM phải restore thủ công.
- etcd cluster trong cùng DC1 → không có cross-DC Raft latency → write etcd nhanh hơn Case 1/2.
- Không bao giờ bị split brain (etcd cluster trong 1 DC, không bị network partition giữa các etcd node).
- CP chỉ làm 1 việc: nhận Admin API request → ghi vào etcd → DP tách hoàn toàn, scale DP độc lập không ảnh hưởng CP.
- Security tốt hơn Traditional: DP không expose Admin API (:9180) → attack surface nhỏ hơn.
- Khi mở rộng thêm DP (DC3, K8s node mới): chỉ trỏ etcd DC1, không cần deploy thêm CP.
- CP die:
  ├─ DP1 vẫn xử lý S3 traffic bình thường ✅
  ├─ DP2 vẫn xử lý S3 traffic bình thường ✅
  ├─ Không thể thay đổi config ⚠️ cho đến khi CP sống lại
  └─ etcd K8s cluster vẫn sống → DP vẫn có config trong memory

nhược:
- DC1 die = mất hết cùng lúc — không khắc phục được so với Case 3:
  ├─ CP die → không config được ❌
  ├─ etcd cluster 3 pod đều trên DC1 → DC1 die → mất toàn bộ quorum ❌
  ├─ DP1 die → mất 1/2 traffic capacity ❌
  └─ Chỉ còn DP2 sống, dùng config cũ từ memory → đọc được, ghi S3 có thể lỗi

- etcd cluster K8s chịu pod-level failure ✅ nhưng KHÔNG chịu DC-level failure ❌:
  ├─ 3 pod etcd cùng DC1 = 1 failure domain
  ├─ DC1 die → mất quorum ngay lập tức, K8s không thể cứu được
  └─ Khác Case 1/2: ở đây không có etcd node nào ở DC2 để duy trì quorum khi DC1 die

- DP2 hoàn toàn phụ thuộc etcd DC1 — giống Case 3:
  ├─ DC1 network flap → DP2 không sync config mới
  ├─ DP2 vẫn serve traffic với config cũ nhưng không update được ⚠️
  └─ Config drift giữa DP1 và DP2 nếu flap kéo dài

- K8s etcd cluster thêm dependency và ops layer so với bare-metal etcd (Case 3):
  ├─ Cần K8s cluster đang chạy để host etcd pods (thêm 1 failure domain mới: K8s control plane)
  ├─ etcd pod cần PersistentVolume (PVC) → storage class, provisioner → thêm ops layer
  ├─ K8s scheduler có thể reschedule etcd pod sang node khác → IP thay đổi → cần headless Service để stable endpoint
  └─ Snapshot/restore phức tạp hơn bare-metal: phải exec vào pod hoặc dùng CronJob backup

- CP vẫn là SPOF của tầng control:
  ├─ DC1 die → CP chết, không có CP nào thay thế tại DC2
  └─ MTTR config change = thời gian DC1 recover hoàn toàn

- So sánh thực chất với Case 3: Case 5 chỉ cải thiện etcd ở mức pod-level failure (K8s auto-restart khi 1 pod crash). Về DC-level failure outcome giống hệt Case 3. Chi phí ops tăng (K8s + PVC + headless Service) nhưng HA thực chất ở 2-DC không cải thiện đáng kể cho giai đoạn đầu.

trường hợp 6: traditional với apisix1 có CP1 (Admin API và Dashboard), DP1 và 1 cluster k8s etcd (3 pod). apisix2 có CP2 (Admin API và Dashboard), DP2.
```
┌──────────────────────────────────────┐   ┌──────────────────────────────────┐
│               DC1                    │   │              DC2                 │
│                                      │   │                                  │
│  ┌──────────────┐  ┌──────────────┐  │   │  ┌──────────────────────────┐    │
│  │     CP1      │  │    etcd      │  │   │  │           CP2            │    │
│  │ (Admin API + │──│  (cluster)   │  │   │  │       (Admin API +       │    │
│  │  Dashboard)  │  │  :2379       │  │   │  │        Dashboard)        │    │
│  └──────────────┘  └──────┬───────┘  │   │  └──────────────┬───────────┘    │
│         │                 │ watch    │   │          write  │                │
│  ┌──────┴───────┐         │          │   │  cross-DC ──────┘                │
│  │     DP1      │◄────────┘          │   │  watch cross-DC                  │
│  │ (Data Plane) │                    │   │  ┌──────────────────────────┐    │
│  └──────▲───────┘                    │   │  │           DP2            │    │
└─────────┼────────────────────────────┘   │  │       (Data Plane) ◄─────┼────┘
          │                                │  └──────────────────────────┘    │
    S3 Client                              └──────────────────────────────────┘
  Admin ──► CP1 (fast)                         S3 Client
                                               Admin ──► CP2 (slow, cross-DC RTT)
  [DC1 die → etcd die → CP2 vô dụng dù sống ❌]
```
ưu:
- etcd cluster K8s (3 pod) chịu được 1 pod lỗi mà không mất quorum → bền hơn Case 4 (single etcd SPOF).
- K8s tự restart etcd pod khi crash → MTTR etcd thấp hơn so với single etcd VM phải restore thủ công.
- CP2 luôn active tại DC2 — không cần promote, không cần failover thủ công.
- CP2 hữu dụng khi DC1 sống nhưng chậm/bận: Admin có thể dùng CP2 config thay thế tạm thời (chấp nhận cross-DC RTT).
- Dashboard tại DC2 luôn available khi DC1 sống — không bị single-region admin lockout.
- Đáp ứng được push config liên tục (CI/CD) từ cả 2 DC khi DC1 sống.
- Traditional mode đơn giản hơn Decoupled để debug (1 process, 1 log stream, không phân biệt CP/DP process).
- DP2 vẫn serve traffic khi DC1 die (config cũ trong memory).
- etcd cluster trong DC1 → không có cross-DC Raft latency → write nhanh hơn Case 1/2.
- Không bao giờ bị split brain trong etcd (cluster trong 1 DC, không bị network partition giữa etcd nodes).

nhược:
- etcd cluster K8s vẫn là SPOF ở DC-level — vấn đề gốc rễ không được giải quyết, giống Case 4:
  ├─ DC1 die → etcd cluster 3 pod die toàn bộ → mất quorum ❌
  ├─→ CP1 die ❌
  ├─→ CP2 còn sống nhưng MẤT etcd → CP2 không nhận được Admin API request ❌
  ├─→ DP1 die ❌
  ├─→ DP2 còn sống nhưng không sync config mới ⚠️ (chỉ serve config cũ trong memory)
  └─ CP2 "active" nhưng vô dụng khi etcd chết — CP APISIX bắt buộc cần etcd để xử lý mọi Admin API request

- K8s chịu pod-level failure ✅ nhưng KHÔNG chịu DC-level failure ❌:
  ├─ 3 pod etcd cùng 1 failure domain (DC1) → DC1 die = mất quorum ngay lập tức
  └─ Không có etcd node nào ở DC2 → không thể duy trì quorum khi DC1 die (khác Case 1/2)

- Cross-DC latency cho mọi write operation qua CP2 — giống Case 4:
  ├─ Admin gọi CP2 (DC2) → CP2 write vào etcd (DC1) → có RTT DC2→DC1
  ├─→ Admin API response chậm khi dùng CP2 nếu RTT cao
  └─→ Bình thường ưu tiên dùng CP1 (fast), CP2 là fallback (slow)

- CP2 phụ thuộc network DC2→DC1 liên tục:
  ├─ Network partition DC1↔DC2 (dù cả 2 DC physically sống):
  ├─→ CP2 mất kết nối etcd → CP2 không dùng được ❌
  └─→ Partial failure này khó debug hơn DC die hoàn toàn

- K8s etcd cluster thêm dependency vận hành so với Case 4 bare-metal etcd:
  ├─ Cần K8s cluster đang chạy để host etcd pods (thêm dependency layer)
  ├─ etcd pod cần PersistentVolume (PVC) → storage class, provisioner → thêm ops layer
  ├─ K8s scheduler có thể reschedule etcd pod → cần headless Service để stable endpoint
  └─ Snapshot/restore phức tạp hơn VM bare-metal: phải exec vào pod hoặc dùng CronJob backup

- DP2 phụ thuộc etcd DC1 để sync config:
  ├─ Network DC1→DC2 flap → DP2 không nhận config mới
  └─ Config drift giữa DP1 và DP2 nếu flap kéo dài

- Không tốt hơn Case 4 về HA thực chất ở DC-level:
  ├─ Case 4: DC1 die → DP2 chạy config cũ, CP2 vô dụng
  ├─ Case 6: DC1 die → DP2 chạy config cũ, CP2 vô dụng
  └─→ Outcome giống nhau ở DC failure scenario, Case 6 chỉ cải thiện pod-level etcd resilience, chi phí ops tăng thêm

- Backup etcd qua K8s phức tạp hơn bare-metal Case 4:
  ├─ Cần CronJob hoặc manual: kubectl exec etcd-pod -- etcdctl snapshot save
  └─ MTTR khi restore: phải apply lại StatefulSet, re-attach PVC → 30–60 phút

trường hợp 7: decouple với apisix1 có CP (Admin API và Dashboard), DP1 và 1 cluster k8s etcd (3 pod). apisix2 có DP2 và 1 cluster k8s (3 pod)
```
┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│                   DC1                    │   │                   DC2                    │
│                                          │   │                                          │
│  ┌──────────────┐  ┌────────────────┐    │   │  ┌────────────────────────────────────┐  │
│  │      CP      │  │  etcd-cluster1 │    │   │  │          etcd-cluster2             │  │
│  │ (Admin API + │──│  (3 pods K8s)  │    │   │  │          (3 pods K8s)              │  │
│  │  Dashboard)  │  │  :2379         │    │   │  │          :2379                     │  │
│  └──────┬───────┘  └───────┬────────┘    │   │  └──────────────┬───────────────────  ┘  │
│         │                  │             │   │                 │                        │
│         │           watch  │             │   │          watch  │                        │
│  ┌──────┴───────┐          │             │   │  ┌─────────────┴──────────────────────┐  │
│  │     DP1      │◄─────────┘             │   │  │                DP2                 │  │
│  │ (Data Plane) │                        │   │  │            (Data Plane)            │  │
│  └──────▲───────┘                        │   │  └────────────────▲───────────────────┘  │
└─────────┼────────────────────────────────┘   └─────────────────────────────────────────┘
          │                                                        │
    S3 Client                                               S3 Client
                      Admin ──► CP (chỉ DC1)
  [CP write → etcd-cluster1 (DC1) | DP2 watch etcd-cluster2 (DC2)]
  [Cần cơ chế đồng bộ config giữa etcd-cluster1 ↔ etcd-cluster2 ⚠️]

Vấn đề cốt lõi: 2 etcd cluster độc lập 
   → CP chỉ ghi vào 1 cluster
   → DP2 watch cluster2 → KHÔNG tự nhận config từ cluster1
Giải pháp bắt buộc phải chọn 1 trong 2: 
    Option A — CP ghi vào CẢ 2 etcd cluster (fan-out write):
       CP ──write──► etcd-cluster1 (DC1)
       CP ──write──► etcd-cluster2 (DC2)
       DP1 watch etcd-cluster1
       DP2 watch etcd-cluster2
       → Config đồng nhất ✅ | CP phải maintain 2 etcd connection ⚠️

    Option B — etcd mirror/replication tool (etcdctl mirror):
       etcd-cluster1 ──mirror──► etcd-cluster2
       CP chỉ ghi vào cluster1, mirror sync sang cluster2
       → Thêm 1 component mirror phải monitor ⚠️
```
ưu:
- Mỗi DC có etcd cluster riêng → DC isolation thực sự ở tầng config storage:
  ├─ DC1 die → etcd-cluster1 die, nhưng etcd-cluster2 (DC2) vẫn sống ✅
  ├─ DP2 vẫn có etcd-cluster2 → vẫn có thể nhận config mới nếu dùng Option A hoặc mirror ✅
  └─ Khắc phục hoàn toàn nhược điểm của Case 5: DP2 không còn phụ thuộc etcd DC1

- Mỗi etcd cluster K8s (3 pod) chịu được 1 pod lỗi mà không mất quorum:
  ├─ K8s auto-restart pod khi crash → MTTR thấp, không cần can thiệp thủ công
  └─ Cả 2 cluster đều resilient ở pod-level

- DC1 die — scenario được cải thiện rõ rệt so với mọi case trước (trừ Case 9):
  ├─ CP die → không thể thay đổi config ⚠️ (nhưng DP vẫn chạy)
  ├─ etcd-cluster1 die, nhưng etcd-cluster2 (DC2) vẫn nguyên vẹn ✅
  ├─ DP1 die → mất 1/2 traffic capacity ❌
  └─ DP2 vẫn serve traffic với config hiện tại từ etcd-cluster2 ✅ (không còn chỉ dùng memory)

- CP/DP decoupled hoàn toàn → scale DP độc lập, security tốt hơn Traditional:
  ├─ DP không expose Admin API (:9180) → attack surface nhỏ hơn
  └─ Thêm DP mới ở bất kỳ DC nào: chỉ cần trỏ etcd cluster local

- Không có cross-DC Raft latency (mỗi etcd cluster nằm gọn trong DC riêng):
  └─ Write etcd nhanh hơn Case 1/2, không bị ảnh hưởng bởi inter-DC RTT

nhược:
- CP vẫn là SPOF của tầng control plane:
  ├─ Chỉ có 1 CP tại DC1 → DC1 die → không thể thay đổi config từ bất kỳ đâu ❌
  ├─ Không có CP tại DC2 → không có failover admin
  └─ MTTR config change = thời gian DC1 recover hoàn toàn (giống Case 3/5)

- Đồng bộ config giữa 2 etcd cluster là vấn đề kỹ thuật phức tạp nhất:
  ├─ Option A (fan-out write): CP phải maintain 2 etcd connection đồng thời
  │  ├─ Nếu write cluster1 thành công nhưng write cluster2 fail → config inconsistent
  │  ├─ Không có atomic 2-phase commit trong etcd → partial write là risk thực
  │  └─ APISIX CP hiện tại không native support fan-out write → cần custom hoặc proxy layer
  │
  ├─ Option B (etcd mirror): thêm 1 component mirror phải vận hành, monitor
  │  ├─ Mirror lag → DP2 có thể nhận config cũ hơn DP1 (eventual consistency)
  │  ├─ Mirror fail → DP2 không sync được config mới dù cluster2 vẫn sống
  │  └─ etcdctl mirror không phải production-grade replication tool
  │
  └─→ Thực tế: hầu hết team chọn Option A với APISIX config để CP ghi song song 2 etcd endpoint

- K8s dependency nhân đôi — vận hành 2 etcd K8s cluster:
  ├─ Gấp đôi PVC, gấp đôi headless Service, gấp đôi CronJob backup so với Case 5
  ├─ Gấp đôi K8s node cần để schedule etcd pods (cần nodeAffinity/anti-affinity đúng)
  └─ Monitoring phải cover cả 2 cluster: etcd_server_has_leader, etcd_disk_wal_fsync_duration

- Config consistency window giữa DP1 và DP2:
  ├─ Dù Option A hay B: luôn có một khoảng thời gian 2 DP chạy config khác nhau
  ├─ DP1 nhận config mới trước (watch etcd-cluster1, local DC1)
  ├─ DP2 nhận config mới sau (mirror lag hoặc network RTT)
  └─→ Với Ceph S3 use case: window này chấp nhận được, nhưng cần document rõ

- Complexity vận hành cao nhất trong các Decoupled case (7 > 5 > 3):
  ├─ 2 etcd K8s cluster + fan-out write hoặc mirror tool
  ├─ Backup/restore: phải đảm bảo 2 cluster consistent trước khi restore
  └─ Troubleshoot: khi DP2 có config sai, phải check etcd-cluster2, mirror status, network

trường hợp 8: traditional với apisix1 có CP1 (Admin API và Dashboard), DP1 và 1 cluster k8s etcd (3 pod). apisix2 có CP2 (Admin API và Dashboard), DP2 và 1 cluster k8s (3 pod)
```
┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│                   DC1                    │   │                   DC2                    │
│                                          │   │                                          │
│  ┌──────────────┐  ┌────────────────┐    │   │  ┌──────────────┐  ┌────────────────┐    │
│  │     CP1      │  │  etcd-cluster1 │    │   │  │     CP2      │  │  etcd-cluster2 │    │
│  │ (Admin API + │──│  (3 pods K8s)  │    │   │  │ (Admin API + │──│  (3 pods K8s)  │    │
│  │  Dashboard)  │  │  :2379         │    │   │  │  Dashboard)  │  │  :2379         │    │
│  └──────┬───────┘  └───────┬────────┘    │   │  └──────┬───────┘  └───────┬────────┘    │
│         │           watch  │             │   │         │           watch  │             │
│  ┌──────┴───────┐          │             │   │  ┌──────┴───────┐          │             │
│  │     DP1      │◄─────────┘             │   │  │     DP2      │◄─────────┘             │
│  │ (Data Plane) │                        │   │  │ (Data Plane) │                        │
│  └──────▲───────┘                        │   │  └──────▲───────┘                        │
└─────────┼────────────────────────────────┘   └─────────┼────────────────────────────────┘
          │                                               │
    S3 Client                                       S3 Client
  Admin ──► CP1 (fast, local)                  Admin ──► CP2 (fast, local)
  [Mỗi DC hoàn toàn độc lập về etcd ✅ | Cần đồng bộ config CP1 ↔ CP2 ⚠️]

Vấn đề cốt lõi: 2 CP ghi vào 2 etcd cluster độc lập
     → Config thay đổi trên CP1 KHÔNG tự động xuất hiện trên CP2/DP2
     → Nguy cơ SPLIT BRAIN config nếu không có sync mechanism

Giải pháp bắt buộc phải chọn 1 trong 2:
    Option A — Active/Passive CP (chỉ 1 CP write tại 1 thời điểm):
       CP1 = Active (write) ──fan-out──► cluster1 + cluster2
       CP2 = Passive (read-only hoặc standby)
       → Không split brain ✅ | CP2 không dùng được khi DC1 sống ⚠️

    Option B — Config sync tool (adc export/import hoặc etcd mirror):
       CP1 ghi cluster1 ──mirror──► cluster2 (sync định kỳ)
       CP2 ghi cluster2 ──mirror──► cluster1 (sync định kỳ)
       → Eventual consistency, có conflict window ⚠️
       → Nếu cả 2 CP ghi đồng thời: conflict resolution phức tạp ❌
```
ưu:
- Mỗi DC hoàn toàn tự chủ về tầng etcd — DC isolation tốt nhất trong tất cả Traditional case:
  ├─ DC1 die → etcd-cluster1 die, nhưng etcd-cluster2 (DC2) vẫn sống ✅
  ├─ CP2 vẫn có etcd-cluster2 → CP2 vẫn nhận và xử lý Admin API request ✅
  ├─ DP2 vẫn watch etcd-cluster2 → DP2 vẫn nhận config mới (nếu CP2 write) ✅
  └─ Đây là điểm khác biệt lớn nhất so với Case 4/6: CP2 THỰC SỰ dùng được khi DC1 die

- Mỗi etcd cluster K8s (3 pod) chịu được 1 pod lỗi:
  ├─ K8s auto-restart pod → MTTR thấp, không cần can thiệp thủ công
  └─ Cả 2 DC đều resilient ở pod-level

- Admin API local → latency thấp tại cả 2 DC:
  ├─ CP1 ghi etcd-cluster1: local DC1 → latency thấp ✅
  ├─ CP2 ghi etcd-cluster2: local DC2 → latency thấp ✅
  └─ Không còn cross-DC RTT khi dùng CP2 (khác Case 4/6 nơi CP2 ghi vào etcd DC1)

- Traditional mode quen thuộc — không cần học Decoupled architecture:
  ├─ 1 process per node (CP+DP bundle), 1 log stream → debug đơn giản hơn
  └─ Admin workflow không thay đổi so với Case 2/4/6

- CP2 thực sự active và hữu ích ngay cả khi DC1 die:
  ├─ DC1 die → CP2 vẫn ghi được vào etcd-cluster2 ✅
  ├─ DP2 nhận config mới từ CP2 → đáp ứng được CI/CD emergency config change ✅
  └─ Hoàn toàn khác Case 4/6 nơi CP2 chỉ là "active nhưng vô dụng" khi etcd DC1 chết

nhược:
- Split brain config là rủi ro lớn nhất — vấn đề không có trong Case 1–6:
  ├─ 2 CP độc lập ghi vào 2 etcd cluster riêng biệt
  ├─ Admin gọi CP1 thay đổi route A → chỉ có DP1 nhận config mới
  ├─ Admin gọi CP2 thay đổi route A khác → chỉ có DP2 nhận config mới
  ├─→ DP1 và DP2 chạy route A khác nhau → S3 client nhận response không nhất quán
  └─→ Đây là split brain config thực sự, nguy hiểm hơn mọi vấn đề ở các case trước

- Sync mechanism là bắt buộc nhưng không trivial:
  ├─ Option A (Active/Passive): lãng phí CP2 khi DC1 sống, phức tạp khi failover
  ├─ Option B (mirror/sync): có eventual consistency window, conflict resolution khó
  ├─ Không có built-in solution trong APISIX cho multi-etcd cluster sync
  └─→ Team phải tự thiết kế và vận hành sync mechanism → ops burden cao

- K8s dependency nhân đôi — vận hành 2 etcd K8s cluster:
  ├─ Gấp đôi PVC, gấp đôi headless Service, gấp đôi CronJob backup so với Case 6
  ├─ Gấp đôi K8s node cần schedule etcd pods (cần nodeAffinity/anti-affinity đúng)
  └─ Monitoring phải cover cả 2 cluster: etcd_server_has_leader, disk_wal_fsync_duration

- Config consistency window luôn tồn tại:
  ├─ Dù sync mechanism nào: luôn có khoảng thời gian DP1 và DP2 chạy config khác nhau
  ├─ Mirror lag hoặc sync interval → eventual consistency, không phải strong consistency
  └─→ Với Ceph S3: window này phải được document rõ để ops team không nhầm lẫn khi debug

- Complexity vận hành cao nhất trong tất cả 9 case (cùng với Case 7):
  ├─ 2 etcd K8s cluster + 2 CP + sync mechanism + conflict resolution policy
  ├─ Backup/restore: phải đảm bảo 2 cluster consistent trước khi restore production
  ├─ Rollback: phải rollback đồng thời cả 2 etcd cluster để tránh config drift
  └─ Runbook phải cover: "CP1 và CP2 bị modify config khác nhau đồng thời → xử lý thế nào"

- So sánh với Case 7 (Decouple): Case 8 có CP2 thực sự hữu ích hơn khi DC1 die, nhưng đổi lại là rủi ro split brain cao hơn vì 2 CP đều có thể write độc lập.
  
trường hợp 9: standalone với apisix1 có DP1 và gitops folder config (yaml/json file). apisix2 có DP2 và pull gitop folder config (yaml/json file)
```
             ┌────────────────────────────────────────────────────────┐
             │          Git Repository (Source of Truth)              │
             │          (GitLab / GitHub / Gitea)                     │
             │                                                        │
             │ /apisix-config/                                         │
             │ ├── custom_plugins/        (Chứa logic Lua chung)      │
             │ │   └── ceph-s3-regex.lua                              │
             │ │                                                      │
             │ ├── fragments/             (Chia nhỏ theo Cụm Dịch vụ) │
             │ │   ├── service-s3/                                    │
             │ │   │   ├── routes.yaml                                │
             │ │   │   └── upstreams.yaml                             │
             │ │   └── service-ekyc/                                  │
             │ │       ├── routes.yaml                                │
             │ │       └── upstreams.yaml                             │
             │ │                                                      │
             │ └── profiles/              (Topology/Môi trường)        │
             │     ├── dc1-base.yaml      (Import: s3, ekyc)          │
             │     └── dc2-base.yaml      (Import: s3 only)           │
             └───────────────────────────┬────────────────────────────┘
                                         │ git push / trigger
             ┌───────────────────────────▼────────────────────────────┐
             │                   CI/CD Pipeline                       │
             │                                                        │
             │ [STEP 1: COMPILE/MERGE]                                │
             │ -> Gộp (yq/python): dc1-base + fragments/s3 + ekyc     │
             │    Thành phẩm: apisix-dc1.yaml                         │
             │ -> Gộp (yq/python): dc2-base + fragments/s3            │
             │    Thành phẩm: apisix-dc2.yaml                         │
             │                                                        │
             │ [STEP 2: CHECK & DRY-RUN]                              │
             │ -> adc lint apisix-dc1.yaml                            │
             │ -> adc lint apisix-dc2.yaml                            │
             │ (NẾU LỖI: CI Đỏ ❌ -> Dừng ngay, alert cho Admin)      │
             │                                                        │
             │ [STEP 3: DEPLOY]                                       │
             │ -> SCP/Ansible đẩy yaml & lua xuống server tương ứng   │
             └─────────────┬───────────────────────────┬──────────────┘
                           │                           │
              ┌────────────┘                           └────────────┐
              │ Push apisix-dc1.yaml                                │ Push apisix-dc2.yaml
              │ Push ceph-s3-regex.lua                              │ Push ceph-s3-regex.lua
              ▼                                                     ▼
┌───────────────────────────┐                         ┌───────────────────────────┐
│           DC1             │                         │           DC2             │
│                           │                         │                           │
│  ┌─────────────────────┐  │                         │  ┌─────────────────────┐  │
│  │        DP1          │  │                         │  │        DP2          │  │
│  │  (Standalone Mode)  │  │                         │  │  (Standalone Mode)  │  │
│  │ docker-compose.yaml │  │                         │  │ docker-compsoe.yaml │  │
│  │ Start -e dc1        │  │                         │  │ Start -e dc2        │  │
│  └──────────┬──────────┘  │                         │  └──────────┬──────────┘  │
│             │ watch       │                         │             │ watch       │
│  ┌──────────▼──────────┐  │                         │  ┌──────────▼──────────┐  │
│  │ Local Configs        │  │                         │  │ Local Configs        │  │
│  │ - apisix-dc1.yaml   │◄─┤                         │  │ - apisix-dc2.yaml   │◄─┤
│  │ - ceph-s3-regex.lua │◄─┤                         │  │ - ceph-s3-regex.lua │◄─┤
│  │                     │  │                         │  │                     │  │
│  │ (No etcd, No CP)    │  │                         │  │ (No etcd, No CP)    │  │
│  └─────────────────────┘  │                         │  └─────────────────────┘  │
└─────────────┬─────────────┘                         └─────────────┬─────────────┘
              │                                                     │
       S3 Traffic (DC1)                                      S3 Traffic (DC2)

────────────────────────────────────────────────────────────────────────────────────────────────
Quy trình: Admin ──► Git Commit ──► CI/CD Merge & Validate ──► Auto Deploy ──► APISIX Hot-Reload
────────────────────────────────────────────────────────────────────────────────────────────────


┌──────────────────────────────────────────────────┐
│           Git Repository                         │
│   (GitLab / GitHub / Gitea self-hosted)          │
│                                                  │
│  /apisix-config/                                 │
│  ├── base/                                       │
│  │   ├── config.yaml                             │
│  │   ├── apisix.yaml                             │
│  │   ├── globals/                                │
│  │   │   └── global-rules.yaml                   │
│  │   └── scripts/                                │
│  │       └── cloudian-regex.lua                  │
│  │                                               │
│  ├── profiles/                                   │
│  │   ├── dc1/                                    │
│  │   │   ├── profile.env                         │
│  │   │   ├── overlays/                           │
│  │   │   │   ├── s3/                             │
│  │   │   │   │   └── s3-route.yaml               │
│  │   │   │   ├── ekyc/                           │
│  │   │   │   │   └── ekyc-route.yaml             │
│  │   │   │   └── services/                       │
│  │   │   │       ├── s3-service.yaml             │
│  │   │   │       └── ekyc-service.yaml           │
│  │   │   └── tenant-map.yaml                     │
│  │   │                                           │
│  │   └── dc2/                                    │
│  │       ├── profile.env                         │
│  │       ├── overlays/                           │
│  │       │   ├── s3/                             │
│  │       │   │   └── s3-route.yaml               │
│  │       │   └── services/                       │
│  │       │       └── s3-service.yaml             │
│  │       └── tenant-map.yaml                     │
│  │                                               │
│  ├── validators/                                 │
│  │   ├── dry-run.sh                              │
│  │   ├── render.sh                               │
│  │   └── merge-by-id.sh                          │
│  │                                               │
│  └── manifests/                                  │
│      ├── dc1/                                    │
│      │   └── apisix.yaml                         │
│      └── dc2/                                    │
│          └── apisix.yaml                         │
│                                                  │
│  Policy:                                         │
│  - merge overlays by service-id                  │
│  - dry-run before commit/rollout                 │
│  - only promote if validation passes             │
└──────────────────────┬───────────────────────────┘
                       │
                       │  git commit / merge request
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│             CI/CD Pipeline / GitOps                              │
│                                                                  │
│  1) Load base + dc profile overlay                                │
│  2) Merge resources by id                                        │
│  3) Run dry-run / syntax validation                              │
│  4) Run Lua script checks (bucket syntax, tenant rules, etc.)    │
│  5) Render final artifact per DC                                  │
│  6) Promote only the validated artifact                          │
│                                                                  │
│  Output:                                                         │
│  - dc1 artifact                                                  │
│  - dc2 artifact                                                  │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                  ┌─────────────┴─────────────┐
                  │                           │
                  ▼                           ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│             DC1              │   │             DC2              │
│                              │   │                              │
│  ┌────────────────────────┐  │   │  ┌────────────────────────┐  │
│  │ APISIX DP standalone   │  │   │  │ APISIX DP standalone   │  │
│  │ - APISIX_PROFILE=dc1   │  │   │  │ - APISIX_PROFILE=dc2   │  │
│  │ - no etcd              │  │   │  │ - no etcd              │  │
│  │ - local file reload     │  │   │  │ - local file reload     │  │
│  │ - custom Lua script    │  │   │  │ - custom Lua script    │  │
│  │   cloudian-regex.lua   │  │   │  │   cloudian-regex.lua   │  │
│  └───────────┬────────────┘  │   │  └───────────┬────────────┘  │
│              │               │   │              │               │
│  ┌───────────▼────────────┐  │   │  ┌───────────▼────────────┐  │
│  │ /usr/local/apisix/conf │  │   │  │ /usr/local/apisix/conf │  │
│  │ apisix.yaml            │  │   │  │ apisix.yaml            │  │
│  │ config.yaml             │  │   │  │ config.yaml             │  │
│  │ scripts/               │  │   │  │ scripts/               │  │
│  │ overlays/dc1           │  │   │  │ overlays/dc2           │  │
│  └────────────────────────┘  │   │  └────────────────────────┘  │
└──────────────────────────────┘   └──────────────────────────────┘
           │                                       │
           ▼                                       ▼
      S3 Client / App                          S3 Client / App
           │                                       │
           └───────────────► Ceph Rados S3 ◄───────┘


===================================================================================
                       [ TẦNG GITOPS & CI/CD - SOURCE OF TRUTH ]
===================================================================================
               Git Repository (GitLab/GitHub)
               
  [Level 1: DC/Infra Config]                 [Level 2: Service/Routing Config]
  (Platform Team - Require Restart)          (Service Team - Hot Reload Zero-Downtime)
  /system-configs/                           /service-fragments/
  ├── config-dc1.yaml (worker: 2)            ├── global-rules.yaml
  └── config-dc2.yaml (worker: 1)            ├── s3-hcm-routes.yaml
                                            ├── s3-hni-routes.yaml
                                            └── ekyc-routes.yaml  (Chỉ áp dụng DC1)
                                                       │
               ┌───────────────────────────────────────┴─────────────────┐
               │ CI/CD Pipeline (Build & Validate Phase)                 │
               │ 1. Merge rule DC1 = global + s3-hcm + s3-hni + ekyc     │
               │ 2. Merge rule DC2 = global + s3-hni                     │
               │ 3. Dry-run `adc lint` cho các file đã merge              │
               └───────────────────────┬─────────────────────────────────┘
                                       │ Push Artifact (scp/rsync/atomic cp)
=======================================│===========================================
                                       ▼
  [ DC 1 - APISIX Node ]                                [ DC 2 - APISIX Node ]
  ENV: APISIX_PROFILE=dc1                               ENV: APISIX_PROFILE=dc2
  
  (Host OS File System)                                 (Host OS File System)
  /opt/apisix/conf/                                     /opt/apisix/conf/
  ├── config-dc1.yaml <──(deploy Infra)                 ├── config-dc2.yaml <──(deploy Infra)
  └── apisix-dc1.yaml <──(deploy Service)               └── apisix-dc2.yaml <──(deploy Service)
           │                                                      │
           │ (Docker Bind Mount - KHỚP TÊN FILE)                  │ (Docker Bind Mount)
           ▼                                                      ▼
  ┌──────────────────────────┐                          ┌──────────────────────────┐
  │ Docker Container DP1     │                          │ Docker Container DP2     │
  │ /usr/local/apisix/conf/  │                          │ /usr/local/apisix/conf/  │
  │  - config-dc1.yaml        │                          │  - config-dc2.yaml        │
  │  - apisix-dc1.yaml       │                          │  - apisix-dc2.yaml       │
  │                          │                          │                          │
  │ Watch Inode/mtime change │                          │ Watch Inode/mtime change │
  │ -> Auto Reload apisix-*  │                          │ -> Auto Reload apisix-*  │
  └─────────┬────────────────┘                          └─────────┬────────────────┘
            │ 200 OK / 404 Ceph                                   │ 200 OK / 404 APISIX (nếu gọi eKYC)
            ▼                                                     ▼
     [ Ceph RGW DC1 ]                                      [ Ceph RGW DC2 ]


Tooling để sync Git config → APISIX standalone:
    Option A: apisix-cli (built-in)
       apisix start -c /path/to/config.yaml
    Option B: ADC (APISIX Declarative CLI) — recommended
       adc sync --config apisix-config/
    Option C: CI/CD pipeline (GitLab CI / GitHub Actions)
       on: push → adc sync → DP1, DP2
    Option D: apisix-seed (watch Git → push to standalone)
```
ưu:
- Loại bỏ hoàn toàn etcd dependency:
  ├─ Không có SPOF etcd — component gây ra mọi vấn đề ở Case 3/4/5/6
  ├─ DC1 die → DP2 vẫn sống và chạy bình thường với config hiện tại ✅
  ├─ DC2 die → DP1 vẫn sống và chạy bình thường ✅
  └─ Mỗi DP hoàn toàn độc lập — không phụ thuộc DC còn lại

- Không có CP là SPOF:
  ├─ Không cần CP process → không có "CP die → mất khả năng config" scenario
  ├─ Config thay đổi qua Git commit → apply qua ADC CLI → không phụ thuộc node nào
  └─ Rollback config = git revert → CI/CD re-apply → nhanh và có audit trail

- Git là Source of Truth rõ ràng và có history:
  ├─ Mọi thay đổi config đều có commit history, author, timestamp → full audit log
  ├─ Config review qua Merge Request / Pull Request trước khi apply → peer review
  ├─ Rollback: git revert commit → CI/CD push lại → rollback toàn bộ chỉ trong vài phút
  └─ Diff config giữa các version rõ ràng bằng git diff → không cần compare etcd keys

- GitOps CI/CD tích hợp tự nhiên:
  ├─ Merge → Pipeline → adc sync → DP1 + DP2 → không cần human intervention
  ├─ Staging / Production promotion: branch-based config (branch main = prod, dev = staging)
  ├─ Config validation trong pipeline (adc lint) trước khi deploy → catch lỗi trước prod
  └─ Team làm việc trên config như code — familiar workflow cho dev/ops

- Resource thấp nhất trong tất cả các case:
  ├─ Chỉ cần 2 APISIX process (DP1 + DP2) + 1 Git server (thường đã có sẵn)
  ├─ Không cần VM riêng cho CP, không cần etcd cluster, không cần K8s cho etcd
  └─ RAM footprint: standalone APISIX ~150-200MB/node vs traditional ~300-400MB/node (có etcd)

- Phù hợp với Ceph S3 static topology:
  ├─ Ceph S3 multisite upstream ít thay đổi → config ổn định, không cần real-time config push
  ├─ Routes, upstreams, plugins cho S3 thường được define một lần và ít sửa
  └─ GitOps sync interval 1-5 phút là hoàn toàn chấp nhận được cho loại traffic này

- Dễ vận hành cho team nhỏ:
  ├─ Không cần monitor etcd cluster health, không cần check Raft leader
  ├─ Không cần hiểu CP/DP split architecture
  ├─ Debug đơn giản: config lỗi → git log → tìm commit gây lỗi ngay
  └─ Onboarding mới: hiểu Git + YAML là đủ để vận hành

nhược:
- Không có real-time config propagation:
  ├─ Config thay đổi phải qua Git commit → CI/CD trigger → adc sync → DP apply
  ├─ Thời gian từ commit đến có hiệu lực: 30 giây (webhook) đến 5 phút (polling)
  ├─→ Nếu cần emergency block IP ngay lập tức: không thể instant như Admin API
  └─→ Workaround: emergency branch + fast CI pipeline, nhưng vẫn có độ trễ tối thiểu

- Config drift giữa DP1 và DP2 nếu CI/CD fail một phần:
  ├─ CI/CD apply thành công DP1 nhưng fail DP2 → 2 DP chạy config khác nhau
  ├─ Cần idempotent sync script và atomic apply (apply cả 2 hoặc rollback cả 2)
  ├─→ adc sync không tự đảm bảo 2-phase commit giữa 2 node
  └─→ Cần CI/CD pipeline thiết kế kỹ: verify health sau sync từng DP trước khi proceed

- Runtime config change không được persist nếu dùng Admin API trực tiếp:
  ├─ Standalone mode vẫn có Admin API (:9180) → có thể dùng để change config tạm
  ├─→ NHƯNG: lần sync CI/CD tiếp theo sẽ overwrite lại từ Git → config thay đổi bị mất
  ├─→ Đây là anti-pattern nguy hiểm: "Config drift" giữa Git và runtime
  └─→ Phải có rule: MỌI config change đều phải qua Git, KHÔNG dùng Admin API trực tiếp

- Không có centralized config state:
  ├─ Không có etcd làm single source of runtime truth → không thể query "config hiện tại là gì"
  ├─ Phải query từng DP riêng (curl DP1:9180/apisix/admin/routes, curl DP2:9180/...) để verify
  └─→ Nếu CI/CD pipeline có bug: Git đúng nhưng runtime khác → khó detect nếu không có monitoring

- Git server là dependency mới:
  ├─ Git server down → CI/CD không pull được → không apply config mới được
  ├─ NHƯNG: DP vẫn chạy với config cũ → traffic không bị ảnh hưởng ✅
  ├─ Git server là dependency của config pipeline, KHÔNG phải của traffic serving path
  └─→ Khác với etcd down (ảnh hưởng config sync ngay) — Git down chỉ ảnh hưởng config change

- Không phù hợp nếu config thay đổi thường xuyên và cần instant:
  ├─ Dynamic rate limiting per-user (thay đổi realtime theo load) → không phù hợp
  ├─ A/B testing traffic split thay đổi liên tục theo metrics → không phù hợp
  ├─ Emergency security response yêu cầu block trong <10 giây → không phù hợp
  └─→ Với Ceph S3 giai đoạn đầu: config ổn định → vấn đề này ít xảy ra

- ADC tooling learning curve:
  ├─ Cần học adc CLI hoặc viết sync script (curl Admin API từ CI/CD)
  ├─ adc schema YAML/JSON phải đúng format APISIX → cần validate trong pipeline
  └─→ Workaround: dùng adc lint trong CI/CD để validate trước khi sync

- Standalone mode giới hạn một số plugin cần shared state:
  ├─ limit-count với policy=redis: vẫn dùng được nếu có Redis riêng ✅
  ├─ limit-count với policy=local: mỗi DP count riêng → DP1 và DP2 không share counter
  ├─→ Nếu rate limit cần global (tổng 2 DP = 100 req/s): phải dùng Redis làm shared counter
  └─→ Với S3 use case thông thường: local rate limit per-DP là đủ

Cả Case 1 và Case 2 đều có cùng vấn đề gốc rễ: etcd-3 đặt tại DC1 thay vì VM riêng biệt
→ Chỉ có ý nghĩa thực sự khi:
  DC1: [etcd-1]
  DC2: [etcd-2]
  VM-3 (riêng): [etcd-3] ← tiebreaker thực sự
Nếu không có VM-3: Case 1 và Case 2 về bản chất không tốt hơn Case 3 và Case 4 về etcd HA

==> Phân vân giữa case 5 và case 9

GIAI ĐOẠN SAU:
--- Trong tương lai khi dịch vụ Ceph S3 đã ổn định với APISIX, chiến lược upgrade/migrate mô hình phù hợp với các dịch vụ còn lại (container k8s on-host)
Cluster raft 3 etcd được triển khai từ đầu -> có thể dùng chung cho mô hình hiện tại case và mô hình mới decouple . Cả hai đều dùng chung etcd cluster hiện tại làm config store. Chiến lược migrate parallel là production-grade, zero-downtime standard, đã được nhiều case lớn áp dụng (như Tencent). 
Traditional CP ghi vào etcd → Decoupled CP cũng ghi vào etcd
  ├─→ Trong giai đoạn parallel: 2 CP (traditional) + 1/3 CP (decouple mới) -> đều ghi vào CÙNG etcd cluster
  ├─→ Không có conflict VÌ etcd là single source of truth
  ├─→ Config thay đổi từ CP nào cũng được sync đến TẤT CẢ DP (cả traditional DP lẫn decouple DP mới)
  └─→ Đây chính là lý do parallel run an toàn

- Xác nhận Compatibility
  ├─ Shared etcd: Traditional và decouple cùng watch etcd (prefix /apisix), config sync real-time qua etcd events, không conflict.
  └─ Parallel run: Deploy decouple (CP 3 nodes + DP mới) bên cạnh traditional, cả hai đọc/ghi etcd bình thường, verify bằng etcdctl get /apisix --prefix.

Có 2 trường hợp cho việc upgrade mới như sau:

trường hợp 1: Chuyển từ traditional case 2 sang decouple không cần HAProxy ngoài, vì admin API/dashboard expose trực tiếp từ CP cluster (3 nodes) qua internal LB K8s/VM round-robin hoặc VIP. Nhưng quá trình migrate có impact nhất định, chủ yếu downtime thấp nếu plan tốt.
ưu:
- CP HA full (LB 3 nodes), admin/dashboard 99.99% uptime.
- Scale DP K8s/VM dễ (etcd shared).
- Security cao, CP private.
nhược: 
- Parallel: 5 CP + 4+ DP → resource cao tạm thời (~+6GB RAM).
- Ops complex: monitor CP sync lag.
- Migrate impact: +3 CP nodes, test LB health check.
- CP cluster 3 nodes cần LB/VIP để expose Admin API:
   - Đề cập "internal LB K8s/VM round-robin hoặc VIP" nhưng ghi nhận đây là NHƯỢC vì:
     → Thêm 1 dependency mới (VIP Keepalived hoặc K8s Service)
     → Nếu LB fail → toàn bộ Admin API không truy cập được dù 3 CP node vẫn sống
     → Đây là điểm phức tạp cần plan kỹ
- 3 CP nodes cần đồng bộ hóa session/state:
   → APISIX CP stateless với etcd → không có vấn đề session
   → NHƯNG: Dashboard login state lưu browser-side
     → Nếu LB round-robin: browser hit CP1 lần này, CP2 lần sau
     → Admin API key giống nhau → không vấn đề ✅
     → Cần document rõ để team không bị nhầm

- Trong giai đoạn parallel (2 mô hình cùng chạy để shift traffic), tổng cộng có 5 CP và 4 DP (giả sử mỗi DC traditional có 1 DP hiện tại). Etcd 3 nodes shared, không thay đổi.
    Hiện tại (traditional, 2 DC):
        CP: 2 (1 CP/DC, bundled trong CP+DP).
        DP: 2 (1 DP/DC).
    Parallel decouple mới:
        CP mới: +3 (cluster HA khuyến nghị).
        DP mới: +2 (1/DC hoặc theo scale cần, ít nhất match current).
    Tổng (overlap shift):
    | Component | Traditional (old) | Decouple (new) | Tổng cộng |
    | --------- | ----------------- | -------------- | --------- |
    | CP        | 2                 | 3              | 5         |
    | DP        | 2                 | 2+ (scale)     | 4+        |

- Trade-offs Decouple so với Traditional: Decouple ưu tiên scale/security, nhưng tăng complexity ops.
| Aspect     | Traditional (hiện tại)        | Decouple (sau)                      |
| ---------- | ----------------------------- | ----------------------------------- |
| Scale      | Thêm cặp CP+DP, kém linh hoạt | Chỉ scale DP, CP fixed 3 nodes HA   |
| Security   | CP+DP cùng, risk cao hơn      | CP isolate (private net), DP public |
| Perf       | CP overhead traffic path      | DP pure proxy, latency thấp hơn     |
| Complexity | Đơn giản, 1 config type       | 2 roles, config riêng, sync etcd    |
| HA         | Single failure toàn bộ        | CP cluster + DP stateless           |

- Impact & Khó khăn Migrate
  ├─ Zero-downtime migrate: Deploy CP mới (3 nodes) parallel traditional, config sync etcd real-time, cutover bằng DNS/CNAME sang DP mới (deploy data_plane connect etcd/CP). Traditional vẫn run đến khi traffic 0%.
  ├─ Config change: Traditional dùng enable_admin: off sau migrate (DP không expose 9180), export routes nếu cần: curl http://admin:9180/apisix/admin/routes -X GET.
  ├─ Impact:
  │  ├─ Ops: Học curve role config, monitor riêng (CP: etcd sync lag; DP: traffic metrics).
  │  ├─ Resource: +2-3 CP nodes (~1-2GB RAM total).
  │  ├─ Latency: +microseconds DP-CP poll, negligible.
  │  └─ Rollback: Giữ traditional làm backup, switch DNS nhanh.
  └─ Pitfalls: Etcd prefix conflict (dùng namespace nếu multi-tenant), CP không HA → admin down tạm (như query bạn), test sync trước prod.

- Step-by-step migrate:
  ├─ Snapshot etcd trước khi thực hiện migrate ngay thời điểm ổn định nhất -> Rollback point an toàn nhất -> etcdctl snapshot save backup-before-migrate.db
  ├─ Deploy 3 CP decouple (VMs connect etcd) -> Verify CP mới đọc được config từ etcd → Phải trả về đúng routes đang có → Nếu không: DỪNG, kiểm tra etcd connectivity trước
  ├─ Deploy DP mới parallel, verify health -> Verify DP mới nhận đủ config từ etcd -> Gửi test request qua DP mới → verify response đúng -> KHÔNG shift traffic nếu bước này fail
  ├─ Update DNS load balancer sang DP mới.
  └─ Disable admin trên traditional cũ.
- Khuyến nghị: Migrate khi traffic tăng hoặc cần scale, tránh over-engineer hiện tại.

- Thực hiện Blue-Green Migrate
    1. Deploy decouple parallel:
        ├─ CP cluster (3 nodes): role: control_plane, connect etcd.
        ├─ DP mới (scale theo nhu cầu): role: data_plane.
        └─ Verify CP nhận đúng config từ etcd:
           curl http://new-CP:9180/apisix/admin/routes \
             -H "X-API-KEY: <key>"
           → Phải trả về đúng routes đang có trên production
           Verify DP mới nhận config từ etcd (KHÔNG dùng Admin API vì DP Decoupled không expose :9180):
           curl http://new-dp:9080/healthz
           → Hoặc gửi S3 request thật qua new-DP để verify response đúng
           → KHÔNG shift traffic nếu bước này fail

    2. Traffic shift dần:
    | Phase   | Action                       | Impact               |
    | ------- | ---------------------------- | -------------------- |
    | Prep    | DNS/LB add new-DP endpoints  | 0% downtime          |
    | Shift   | Weight 10% → 100% new-DP     | Gradual, monitor 5xx |
    | Cutover | Remove traditional endpoints | <1min, rollback DNS  |

    3. Cleanup: Sau stable (1-2 tuần), stop traditional (docker stop hoặc uninstall), giữ config backup etcd dump.

- Config ví dụ DP decouple:
```
deployment:
  role: data_plane
etcd:
  host: ["http://etcd1:2379", "http://etcd2:2379", "http://etcd3:2379"]
```

- Best Practices & Monitoring
  ├─ Rollback: Giữ traditional ready (script restart <5min), switch DNS back.
  ├─ Metrics: Prometheus scrape cả old/new (apisix_config_sync_time, apisix_http_requests_total), alert etcd lag >500ms.
  ├─ Pitfalls: Duplicate nodes LB gây inconsistent routing (fix: unique node_id), admin API chỉ dùng CP mới sau cutover.
  └─ Perf gain: Decouple DP stateless scale horizontal, CP không ảnh hưởng traffic.

==> Approach này an toàn 100%, đã test ở scale lớn.

trường hợp 2: Chuyển từ traditional case 2 sang decouple không cần HAProxy ngoài, vì admin API/dashboard expose trực tiếp từ CP (1 nodes) qua internal LB K8s/VM round-robin hoặc VIP. Và quá trình migrate có impact nhất định, vẫn có thể downtime thấp nếu plan tốt.
ưu:
- Parallel minimal: chỉ +1 CP + 2 DP → resource thấp (~+1GB).
- Migrate nhanh, ít change (DNS shift DP).
- Vẫn scale DP độc lập.
nhược: 
- 1 CP SPOF (DC1 die → admin down đến recover).
- Recommend upgrade 3 CP sau stable.
- Parallel tổng: 3 CP | 4+ DP (traditional 2 CP + new 1 CP).
- Expose CP Admin API phức tạp hơn Case traditional:
  ├─ Traditional: CP+DP cùng VM → Admin API accessible tại DC1_IP:9180
  ├─ Decouple 1 CP: CP separate VM → cần định tuyến rõ
  ├─→ Nếu dùng Keepalived VIP: VIP die = admin down
  ├─→ Nếu dùng iptables DNAT: cần maintain rule khi IP thay đổi
  └─→ Không thêm dependency nhưng cần document endpoint mới

Với decouple mới: 1 CP minimum (nhưng recommend 3), giả sử bạn chọn 1 CP để minimal:
Tổng (overlap shift):
| Component | Traditional (2 DC) | Decouple mới | Tổng (shift phase) |
| --------- | ------------------ | ------------ | ------------------ |
| CP        | 2                  | 1            | 3                  |
| DP        | 2                  | 2+           | 4+                 |

- Trade-offs Decouple vs Traditional: Decouple ưu tiên scale dài hạn cho Ceph S3 + future services, nhưng tăng ops ban đầu.
| Aspect     | Traditional (case 2)    | Decouple (1 CP)               |
| ---------- | ----------------------- | ----------------------------- |
| Scale      | Thêm CP+DP đôi          | Chỉ +DP, CP fixed             |
| Security   | Admin expose cả 2 DP/CP | Chỉ CP expose admin (isolate) |
| Perf       | CP overhead proxy       | DP pure data path             |
| Complexity | Đơn giản (1 role)       | 2 roles, sync monitor         |
| HA         | CP mỗi DC               | CP SPOF (recommend 3 sau)     |

- Impact & Khó khăn Migrate
  ├─ Downtime: 0 nếu DNS/LB shift gradual; <5min cutover.
  ├─ Resource: +1 CP (~500MB) +2 DP (~1GB total).
  ├─ Ops: Học role config, monitor sync (etcd lag >1s alert).
  ├─ Rollback: DNS back traditional <1min.
  └─ Pitfalls: Config drift nếu etcd flap (test prefix /apisix); disable admin old sai → expose risk.

- Step-by-step migrate:
    1. Deploy 1 CP decouple (DC1 VM): role: control_plane, etcd cluster.
    2. Deploy 2+ DP mới (DC1/DC2): role: data_plane. 
        -> Verify DP mới nhận config từ CP qua etcd:
            ├─ Tạo 1 test route trên CP mới
            ├─ Kiểm tra test route xuất hiện trên DP mới
            ├─ Gửi request qua DP mới → verify hit đúng upstream
            └─→ KHÔNG shift traffic nếu bước này fail
    3. Verify: curl new-dp:9080/healthz (config sync).
    4. DNS/LB shift: add new-DP (weight 10%) → 100%.
    5. Disable admin old: enable_admin: off.
        ├─ Xác nhận KHÔNG còn CI/CD pipeline nào gọi old CP
        ├─ Xác nhận không còn alert rule nào scrape old CP admin port
        └─ Sau đó mới disable
    6. Cleanup traditional sau 1 tuần.

- Thực hiện Blue-Green Migrate
    1. Deploy decouple parallel (etcd cluster shared):
        Prep-1: Deploy CP (DC1 VM): role: control_plane, connect etcd cluster.
                Deploy DP1/DC1, DP2/DC2: role: data_plane, connect etcd cluster.
                Verify internal health:
                  curl http://new-CP:9180/apisix/admin/routes \
                    -H "X-API-KEY: <key>"
                  → Phải trả về đúng routes đang có
                  Tạo 1 test route trên CP mới → kiểm tra xuất hiện trên DP mới
                  curl http://new-dp:9080/healthz
                  → KHÔNG chuyển sang Prep-2 nếu bước này fail

        Prep-2: Expose CP Admin API ra ngoài (chọn 1 trong 2):
                  Option A - Keepalived VIP:
                    Gán VIP cho VM chạy CP, trỏ apisix-admin.internal → VIP:9180
                  Option B - iptables DNAT:
                    iptables -t nat -A PREROUTING -d <gateway_IP> -p tcp \
                      --dport 9180 -j DNAT --to-destination <CP_IP>:9180
                Verify accessible từ admin workstation:
                  curl http://apisix-admin.internal:9180/apisix/admin/routes \
                    -H "X-API-KEY: <key>"

        Prep-3: Add new-DP endpoints vào DNS/LB (weight thấp ban đầu).
                Verify new-DP nhận S3 request đúng trước khi shift traffic.

    2. Traffic shift dần:
    | Phase   | LB/DNS Action               | Monitor                    |
    | ------- | --------------------------- | ---------------------------|
    | Prep    | Add new-DP endpoints        | Healthz 200, config sync OK |
    | Shift   | Weight old 90%→new 10%→100% | 5xx <0.1%, latency         |
    | Cutover | Remove old-DP               | Rollback ready             |

    3. Cleanup: Stable 1-2 tuần → systemctl stop apisix old, etcd dump: etcdctl snapshot save backup.db.
        ├─ Xác nhận không còn CI/CD pipeline nào gọi old CP Admin API
        ├─ Xác nhận không còn alert rule nào scrape old CP :9180
        ├─ Sau đó: systemctl stop apisix (old traditional)
        └─ Backup etcd: etcdctl snapshot save backup-post-migrate.db

- Best Practices & Monitoring
  ├─ Expose CP: VIP Keepalived (no HAProxy), K8s NodePort nếu hybrid.
  ├─ Monitoring: Alert: apisix_etcd_sync_time > 1s, up{job="apisix"} == 0.
  ├─ Rollback script: dns-update-old.sh + restart traditional.
  └─ Perf: DP poll etcd 1s, memory config cache → low overhead cross-DC.

Chọn Migrate Case 1 (3 CP) khi:
  - Có >= 3 VM available cho CP
  - SLA yêu cầu Admin API 99.9%+
  - CI/CD pipeline config change tần suất cao (>10 lần/ngày)
  - Team đã quen vận hành APISIX trên traditional ổn định

Chọn Migrate Case 2 (1 CP) khi:
  - Resource hạn chế, muốn minimal footprint
  - Config change tần suất thấp (vài lần/tuần)
  - Chấp nhận CP SPOF tạm thời
  - Dùng như bước đệm trước khi nâng lên 3 CP
  → Không nên là trạng thái cuối cùng — plan upgrade 3 CP rõ ràng



==> Chọn case 2





TEST CASE:
Giai đoạn 0 — Chuẩn bị môi trường lab (local)
Mục tiêu: team làm quen APISIX trước khi chạm vào production. Dùng môi trường nhẹ, dễ reset.
Phương thức triển khai phù hợp: docker-compose, minikube, hoặc k3s trên 1 máy

Test case:
TC-00-1: Cài APISIX + etcd single bằng docker-compose
TC-00-2: Gọi Admin API → tạo route đơn giản → verify DP proxy request
TC-00-3: Cài APISIX Dashboard → login, tạo route qua UI
TC-00-4: Simulate etcd die → verify DP còn serve config cũ từ memory
TC-00-5: Thử standalone mode (Case 9 preview) → adc sync config YAML
         → verify DP nhận config không cần etcd




Giai đoạn 1 — Traditional + 1 etcd (Case 3 / Case 4 — VM/bare-metal)
Mục tiêu: verify kiến trúc đơn giản nhất hoạt động đúng trên môi trường thực, nắm rõ behavior trước khi thêm Raft.
Phương thức triển khai: VM / bare-metal — Ubuntu 22.04, cephadm + podman (đúng môi trường production)

Test case:
TC-01-1: Deploy Traditional + 1 etcd tại DC1 (VM onhost)
TC-01-2: Deploy DP2 tại DC2, trỏ cross-DC về etcd DC1
TC-01-3: Tạo S3 route → verify DP1 và DP2 proxy đúng Ceph S3 upstream
TC-01-4: Đo RTT cross-DC etcd: DC1 → DC2 (baseline latency)
TC-01-5: Simulate DC1 network flap
         → DP2 không sync config mới
         → verify DP2 vẫn serve traffic với config cũ từ memory
TC-01-6: Kill etcd → CP không ghi được → verify toàn bộ tê liệt
TC-01-7: Restore etcd từ snapshot → đo MTTR
TC-01-8: (Case 4) Deploy CP2 tại DC2
         → verify CP2 write cross-DC
         → đo latency Admin API qua CP2 vs CP1
         → Simulate DC1 die → verify CP2 vô dụng dù sống



Giai đoạn 2 — K8s etcd cluster trong 1 DC (Case 5 & 6)
Mục tiêu: verify Raft cluster hoạt động đúng, nắm rõ quorum behavior, etcd leader election.
Phương thức triển khai: K8s cluster (k3s hoặc on-host K8s) tại DC1 — etcd chạy dưới dạng StatefulSet/pod

Test case:
TC-02-1: Deploy etcd StatefulSet 3 pod K8s (headless Service, PVC)
         → verify etcdctl endpoint health --cluster
         → verify 1 leader, 2 follower, ERRORS empty

TC-02-2: Verify Raft leader election
         → kill leader pod → đo thời gian election mới (target < 5s)
         → verify APISIX Admin API vẫn hoạt động trong election window

TC-02-3: Kill 1/3 etcd pod → K8s auto-restart
         → verify quorum 2/3 vẫn duy trì, Admin API write OK
         → verify pod rejoin cluster sau restart, data sync đúng

TC-02-4: Kill 2/3 etcd pod → verify mất quorum
         → verify Admin API write fail: "no healthy etcd endpoint"
         → verify DP vẫn serve S3 từ config cũ trong memory
         → verify K8s auto-restart → quorum recover tự động khi đủ 2/3 pod up

TC-02-5: (Case 5 Decoupled) Deploy CP + DP1 (DC1) + DP2 (DC2)
         → verify CP ghi etcd K8s cluster
         → verify DP2 watch cross-DC về etcd K8s DC1
         → Kill CP → verify DP1+DP2 vẫn serve traffic (CP SPOF chỉ mất config change)

TC-02-6: (Case 6 Traditional) Deploy CP1+DP1 (DC1) + CP2+DP2 (DC2)
         → verify CP2 write cross-DC về etcd K8s DC1
         → verify route sync 2 chiều CP1 ↔ CP2
         → đo latency write CP1 (local) vs CP2 (cross-DC)

TC-02-7: Simulate DC1 die hoàn toàn
         → verify etcd cluster 3 pod die toàn bộ, mất quorum
         → verify DP2 DC2 vẫn serve config cũ (outcome giống TC-01-8B)
         → restore DC1 → K8s auto-restart pod + PVC giữ data → cluster recover tự động

TC-02-8: So sánh MTTR: etcd K8s pod crash vs etcd VM crash (GD1)
         → K8s auto-restart (~1 phút) vs restore thủ công từ snapshot (~3 phút)
         → DP downtime = 0 trong cả 2 scenario

TC-02-9: Backup etcd qua K8s
         → kubectl exec etcd-pod -- etcdctl snapshot save /tmp/backup.db
         → kubectl cp etcd-pod:/tmp/backup.db ./backup.db
         → simulate PVC loss → restore → verify pod rejoin cluster, data integrity

TC-02-10: etcd leader pod die → đo election time + Admin API downtime
          → force delete leader pod (--grace-period=0)
          → đo thời gian từ delete đến leader mới (target < 5s)
          → đo Admin API downtime trong election window (target < 5s)
          → verify S3 traffic DP: 0 downtime trong suốt quá trình


Giai đoạn 2 (cũ) — Raft 3 etcd cross-DC (Case 1 & 2)
Mục tiêu: verify behavior CP/DP tách biệt, DP không expose Admin API.
Phương thức triển khai: VM bare-metal Ubuntu 22.04, 2 DC thực — etcd-1 DC1, etcd-2 DC2, etcd-3 DC1 (port 2381)

Test case:
TC-02-1: Deploy etcd-1 (DC1 :2379), etcd-2 (DC2 :2379), etcd-3 (DC1 :2381)
         → verify Raft healthy: etcdctl endpoint health --cluster
TC-02-2: Verify leader election: etcdctl endpoint status --cluster
TC-02-3: (Case 2 Traditional) Deploy CP1+DP1 (DC1), CP2+DP2 (DC2)
TC-02-4: Tạo route từ CP1 → verify sync sang CP2 và cả 2 DP
TC-02-5: Tạo route từ CP2 → verify sync sang CP1 và cả 2 DP
TC-02-6: Kill etcd-2 (DC2) → verify cluster vẫn hoạt động (2/3 quorum)
TC-02-7: Kill etcd-1 (DC1) → verify cluster vẫn hoạt động (etcd-2+3 quorum)
TC-02-8: Kill etcd-1 + etcd-3 (cùng DC1) → verify mất quorum ❌
         → document rõ placement risk này
TC-02-9: Simulate DC1 die hoàn toàn
         → CP2 còn sống nhưng mất quorum → CP2 không ghi được
         → verify DP2 vẫn serve traffic với config cũ
TC-02-10: Đo disk I/O contention: 2 etcd cùng VM DC1 dưới tải cao
          → fio benchmark + etcd wal fsync latency
TC-02-11: etcd leader failover → đo thời gian election + config sync lag
TC-02-12: (Case 1 Decoupled) Deploy chỉ 1 CP tại DC1, DP2 tại DC2
          → verify DP2 watch etcd-2
          → Kill CP → verify DP1+DP2 vẫn serve (CP SPOF chỉ mất config change)

Giai đoạn 3 — 2 etcd K8s cluster độc lập cross-DC (Case 7 & 8)
Mục tiêu: verify zero-downtime migration, Blue-Green traffic shift.
Phương thức triển khai: K8s cluster tại cả DC1 và DC2 — mỗi DC có etcd cluster 3 pod riêng
Test case:
TC-03-1: Deploy etcd-cluster1 (K8s DC1, 3 pod) + etcd-cluster2 (K8s DC2, 3 pod)
         → verify mỗi cluster healthy độc lập
TC-03-2: (Case 7 Decoupled - Option A fan-out write)
         CP ghi đồng thời vào cả 2 etcd cluster
         → verify DP1 (watch cluster1) và DP2 (watch cluster2) nhận cùng config
TC-03-3: (Case 7 Decoupled - Option B mirror)
         Setup etcd mirror: cluster1 → cluster2
         → verify config propagation lag (eventual consistency window)
TC-03-4: Simulate write cluster1 thành công, write cluster2 fail (Option A)
         → verify config inconsistent giữa DP1 và DP2 → document risk
TC-03-5: DC1 die → etcd-cluster1 die
         → verify etcd-cluster2 vẫn sống ✅
         → verify DP2 vẫn nhận config từ cluster2 (cải thiện so với Case 5)
TC-03-6: (Case 8 Traditional) CP1 ghi cluster1, CP2 ghi cluster2
         → trigger split brain: CP1 và CP2 ghi route khác nhau đồng thời
         → verify DP1 và DP2 nhận config khác nhau → document split brain risk
TC-03-7: Test sync mechanism (Option A/B) dưới tải
         → đo consistency window giữa DP1 và DP2
TC-03-8: Backup/restore 2 cluster đồng thời → verify consistency sau restore



Giai đoạn 4 — GitOps Standalone (Case 9)
Mục tiêu: đạt Admin API HA 99.9%+, CP không còn SPOF.
Phương thức triển khai: VM bare-metal DC1 + DC2, không etcd, không CP — dùng ADC CLI + Git
Test case:
TC-04-1: Deploy APISIX standalone (không etcd) tại DC1 và DC2
         → verify APISIX khởi động với local config file
TC-04-2: Tạo S3 route bằng adc sync từ Git repo
         adc sync --config apisix-config/
         → verify DP1 và DP2 nhận đúng config
TC-04-3: Git commit thay đổi route → CI/CD trigger adc sync
         → đo thời gian từ commit đến config có hiệu lực (target < 5 phút)
TC-04-4: adc sync thành công DP1 nhưng fail DP2 (network flap)
         → verify config drift giữa 2 DP
         → verify idempotent re-sync sửa được drift
TC-04-5: DC1 die → DP2 vẫn chạy với config cũ ✅ (không phụ thuộc etcd)
         → DC1 recover → CI/CD re-sync → verify config đồng bộ lại
TC-04-6: Dùng Admin API trực tiếp thay đổi route trên DP1
         → CI/CD sync lần tiếp theo → verify config bị overwrite (anti-pattern)
         → document quy tắc: mọi change phải qua Git
TC-04-7: Git server down → verify DP vẫn serve traffic (Git không phải traffic path)
         → verify không thể apply config mới khi Git down
TC-04-8: Rollback: git revert commit → CI/CD re-apply → đo MTTR rollback
         so sánh với etcd snapshot restore ở giai đoạn trước
TC-04-9: rate limiting plugin (limit-count local vs Redis shared)
         → verify DP1 và DP2 count riêng khi dùng policy=local

Giai đoạn 5 — Vận hành & Failure Scenarios (tất cả case)
Phương thức triển khai: Production VM — áp dụng cho case đã chọn (Case 2 hoặc Case 9)
Test case:
TC-05-1: Quản trị tập trung — thao tác config/cài đặt qua Admin API hoặc Dashboard
         → tạo/sửa/xóa route, upstream, plugin
         → verify áp dụng đúng trên DP1 và DP2

TC-05-2: Impact khi DP die
         → S3 request fail ngay lập tức ❌
         → verify LB loại DP khỏi pool
         → đo thời gian detect + failover

TC-05-3: Impact khi CP die (Traditional/Decoupled)
         → DP vẫn serve traffic với config cũ ✅
         → không thể thay đổi config ⚠️
         → verify MTTR config change = thời gian CP recover

TC-05-4: Impact khi etcd die
         → CP không ghi được mới ❌
         → DP vẫn serve config cũ từ memory ✅
         → verify: DP restart khi etcd chết → DP KHÔNG load được config mới
         (xác nhận: mất etcd + DP restart = mất config ❌)

TC-05-5: Impact khi Ceph S3 upstream die
         → APISIX DP nhận 5xx từ upstream
         → verify health check upstream loại node Ceph lỗi
         → verify retry/failover sang Ceph node còn lại

TC-05-6: HA cho Control Plane
         → Case 2: CP2 failover khi CP1 chết (verify manual/auto)
         → Case 9: không cần CP failover (GitOps)

TC-05-7: DR giữa các APISIX DC1 ↔ DC2
         → DNS failover khi DC1 hoàn toàn down
         → verify DP2 nhận toàn bộ traffic
         → verify S3 multisite Ceph vẫn hoạt động qua DC2

TC-05-8: Khả năng hồi phục etcd
         → etcd corrupt → restore từ snapshot
         → đo MTTR từng case (bare-metal vs K8s pod)
         → verify config sau restore đồng nhất với trước khi corrupt

TC-05-9: DP restart sau khi etcd đã die
         → verify DP không load được config mới từ etcd ❌
         → verify DP chạy với config rỗng hoặc fail start
         (đây là scenario nguy hiểm nhất cần document rõ)


- Vận hành APISIX với các hành vi trong quản trị tập trung.
- Các thao tác về cấu hình/cài đặt, chỉnh sửa khi có thay đổi với controlplane và dataplane.
- Impact khi có lỗi xảy ra tại controlplane và dataplane (cụm APISIX và hệ thống Ceph phía sau)
- Impact khi có lỗi xảy ra tại Database.
- Cơ chế bảo vệ của APISIX khi có lỗi là gì? (HA cho controlplane, có DR qua lại giữa các APISIX hay không?)
- Khả năng hồi phục etcd khi có lỗi là gì?
- Xác nhận việc mất etcd và Data Plane vẫn chạy nhưng không thể recover config sau restart ?


| Giai đoạn | Môi trường                                                                   | Case tương ứng   | Mục tiêu chính                                                                           |
| --------- | ---------------------------------------------------------------------------- | ---------------- | ---------------------------------------------------------------------------------------- |
| 0         | VM bare-metal, 1 DC · docker-compose                                         | Tất cả (preview) | Làm quen, baseline behavior · etcd single, standalone mode                               |
| 1         | VM bare-metal, 2 DC · docker-compose                                         | Case 3, 4        | Baseline cross-DC single etcd · CP/DP split, etcd SPOF confirm                           |
| 2         | K8s/k3s DC1 + VM DC2 · etcd StatefulSet 3 pod · APISIX Traditional/Decoupled | Case 5, 6        | etcd Raft 3 node trong K8s · Pod-level HA, quorum behavior · etcd pod restart/reschedule |
| 2 - cũ    | VM bare-metal Raft                                                           | Case 1, 2        | etcd cross-DC Raft                                                                       |
| 3         | K8s 2 DC độc lập · etcd cluster riêng mỗi DC                                 | Case 7, 8        | etcd DC-isolation · Split brain risk, consistency · Fan-out write vs Mirror              |
| 4         | VM bare-metal hoặc K8s · no-etcd + Git + ADC CLI                             | Case 9           | GitOps, zero etcd dependency · adc sync, config drift, rollback                          |
| 5         | Production VM                                                                | Case được chọn   | Failure scenarios thực tế · DP die, CP die, etcd corrupt · DR DC1↔DC2, vận hành          |
