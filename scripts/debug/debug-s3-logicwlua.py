#!/usr/bin/env python3
"""
debug-s3-logicwlua.py
================
Integration test dùng boto3 để test toàn bộ S3 operations qua APISIX gateway.
Test cả path-style VÀ vhost-style (virtual-hosted addressing).

Test class quan trọng nhất là TestVhostStyleHCM
    dùng addressing_style='virtual' để boto3 tự gửi Host: <bucket>.s3-hcm.sds.infiniband.vn, 
    đây là case thực tế nhất vì đây chính xác là những gì AWS SDK native gửi. 
Test test_04_roundtrip_consistency cross-upload giữa vhost client và path client để confirm plugin rewrite không làm corrupt data.
Nếu plugin rewrite sai (URI hoặc Host) → Cloudian trả 403/404 → test FAIL.

Cách chạy:
  # Minimal
  python3 debug-s3-logicwlua.py           # chạy tất cả
  python3 debug-s3-logicwlua.py -v        # verbose

  # Full config
  AWS_ACCESS_KEY_ID=68c526776d67b2d6da51 AWS_SECRET_ACCESS_KEY=Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10 APISIX_HCM=https://s3-hcm.sds.infiniband.vn APISIX_HNI=https://s3-hni.sds.infiniband.vn BUCKET=tes-thuyldx BUCKET_HNI=test-thuyldx python3 debug-s3-logicwlua.py
  # Hoặc
  export AWS_ACCESS_KEY_ID=68c526776d67b2d6da51 && export AWS_SECRET_ACCESS_KEY="Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10" && export BUCKET_NAME="test-thuyldx" && python3 debug-s3-logicwlua.py
"""

# ── Credentials & target ──────────────────────────────────────────────────────
AWS_ACCESS_KEY_ID     = "68c526776d67b2d6da51"
AWS_SECRET_ACCESS_KEY = "Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10"
BUCKET_NAME           = "test-thuyldx"          # bucket phải tồn tại trên Cloudian
OBJECT_KEY            = "apisix-test/hello.txt"  # object để PUT/GET/DELETE trong test

# ── APISIX endpoints (không đổi trừ khi thay DC) ─────────────────────────────
APISIX_HCM = "https://s3-hcm.sds.infiniband.vn"
APISIX_HNI = "https://s3-hni.sds.infiniband.vn"
AWS_REGION = "us-east-1"

import os, sys, time, uuid, hashlib, unittest, concurrent.futures
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# env override — admin có thể export thay vì sửa file
AWS_ACCESS_KEY_ID     = os.environ.get("AWS_ACCESS_KEY_ID",     AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", AWS_SECRET_ACCESS_KEY)
BUCKET_NAME           = os.environ.get("BUCKET_NAME",           BUCKET_NAME)
OBJECT_KEY            = os.environ.get("OBJECT_KEY",            OBJECT_KEY)
APISIX_HCM            = os.environ.get("APISIX_HCM",            APISIX_HCM)
APISIX_HNI            = os.environ.get("APISIX_HNI",            APISIX_HNI)

# Prefix ngẫu nhiên để tránh conflict giữa các lần chạy đồng thời
RUN_ID = f"apisix-test/{int(time.time())}"

# =============================================================================
# Client factory
# =============================================================================

def make_client(endpoint: str, addressing_style: str = "path"):
    """
    addressing_style="path"    → Host: s3-hcm.sds.infiniband.vn
                                  URI: /bucket/key         ← CASE 2 plugin
    addressing_style="virtual" → Host: bucket.s3-hcm.sds.infiniband.vn
                                  URI: /key                ← CASE 1 plugin → rewrite
    """
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        region_name=AWS_REGION,
        config=Config(
            s3={"addressing_style": addressing_style},
            retries={"max_attempts": 1},
        ),
        verify=False,
    )

# =============================================================================
# T1 — Path-style, HCM
# Mục tiêu : verify CASE 2 plugin (path-style passthrough + bucket validation)
# Expected : mọi S3 operation cơ bản đều HTTP 200/204
# =============================================================================

class T1_PathStyle_HCM(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.s3 = make_client(APISIX_HCM, "path")
        cls._cleanup = []

    @classmethod
    def tearDownClass(cls):
        for key in cls._cleanup:
            try: cls.s3.delete_object(Bucket=BUCKET_NAME, Key=key)
            except: pass

    def _put(self, content: bytes = b"test") -> str:
        key = f"{RUN_ID}/{uuid.uuid4().hex}.txt"
        self.s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=content)
        self.__class__._cleanup.append(key)
        return key

    # ── T1.1 ─────────────────────────────────────────────────────────────────
    def test_01_list_buckets(self):
        """
        Request : GET https://s3-hcm.sds.infiniband.vn/
        Plugin  : URI="/", is_path_host=True → list-all-buckets passthrough
        Expected: HTTP 200, response có key "Buckets"
        """
        resp = self.s3.list_buckets()
        self.assertEqual(resp["ResponseMetadata"]["HTTPStatusCode"], 200)
        self.assertIn("Buckets", resp)

    # ── T1.2 ─────────────────────────────────────────────────────────────────
    def test_02_list_objects(self):
        """
        Request : GET https://s3-hcm.sds.infiniband.vn/test-thuyldx/
        Plugin  : extractBucketFromPath("/test-thuyldx/") → "test-thuyldx"
                  isBucket("test-thuyldx") → True (word-word pattern)
                  → passthrough
        Expected: HTTP 200
        """
        resp = self.s3.list_objects_v2(Bucket=BUCKET_NAME, MaxKeys=5)
        self.assertIn(resp["ResponseMetadata"]["HTTPStatusCode"], [200, 204])

    # ── T1.3 ─────────────────────────────────────────────────────────────────
    def test_03_put_object(self):
        """
        Request : PUT https://s3-hcm.sds.infiniband.vn/test-thuyldx/apisix-test/<id>.txt
        Plugin  : bucket="test-thuyldx" → valid → passthrough
        Expected: HTTP 200 (ETag trong response)
        """
        key = self._put(b"hello from apisix plugin test")
        self.assertIsNotNone(key)

    # ── T1.4 ─────────────────────────────────────────────────────────────────
    def test_04_get_object_content_match(self):
        """
        Request : GET .../test-thuyldx/<key>
        Plugin  : passthrough
        Expected: HTTP 200, body == nội dung đã PUT (không bị corrupt bởi plugin)
        """
        original = b"content integrity check - " + uuid.uuid4().bytes
        key = self._put(original)
        body = self.s3.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
        self.assertEqual(body, original, "Content bị thay đổi qua APISIX — plugin bug!")

    # ── T1.5 ─────────────────────────────────────────────────────────────────
    def test_05_head_object(self):
        """
        Request : HEAD .../test-thuyldx/<key>
        Expected: HTTP 200, ContentLength đúng
        """
        content = b"x" * 512
        key = self._put(content)
        resp = self.s3.head_object(Bucket=BUCKET_NAME, Key=key)
        self.assertEqual(resp["ContentLength"], 512)

    # ── T1.6 ─────────────────────────────────────────────────────────────────
    def test_06_delete_object(self):
        """
        Request : DELETE .../test-thuyldx/<key>
        Expected: HTTP 204, sau đó HEAD → 404
        """
        key = self._put()
        self.s3.delete_object(Bucket=BUCKET_NAME, Key=key)
        with self.assertRaises(ClientError) as cm:
            self.s3.head_object(Bucket=BUCKET_NAME, Key=key)
        self.assertEqual(
            cm.exception.response["ResponseMetadata"]["HTTPStatusCode"], 404
        )

    # ── T1.7 ─────────────────────────────────────────────────────────────────
    def test_07_invalid_bucket_name_no_hyphen(self):
        """
        Request : GET .../nobucket/file.txt
                  bucket="nobucket" → isBucket() = False (không có hyphen)
        Plugin  : return 400
        Expected: ClientError HTTP 400
        """
        with self.assertRaises(ClientError) as cm:
            self.s3.list_objects_v2(Bucket="nobucket")
        http = cm.exception.response["ResponseMetadata"]["HTTPStatusCode"]
        self.assertEqual(http, 400, f"Plugin phải trả 400 cho bucket không hợp lệ, got {http}")

    # ── T1.8 ─────────────────────────────────────────────────────────────────
    def test_08_object_with_nested_key(self):
        """
        Request : PUT/GET .../test-thuyldx/a/b/c/deep.txt
        Plugin  : extractBucketFromPath → "test-thuyldx" (chỉ lấy segment đầu)
        Expected: HTTP 200, nested key hoạt động bình thường
        """
        key = f"{RUN_ID}/a/b/c/{uuid.uuid4().hex}.txt"
        content = b"nested key test"
        self.s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=content)
        self.__class__._cleanup.append(key)
        body = self.s3.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
        self.assertEqual(body, content)

# =============================================================================
# T2 — Vhost-style, HCM
# Mục tiêu : verify CASE 1 plugin (vhost → path rewrite)
# Expected : boto3 dùng virtual addressing → plugin rewrite → Cloudian nhận đúng
# =============================================================================

class T2_VhostStyle_HCM(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        # vhost client: boto3 gửi Host: test-thuyldx.s3-hcm.sds.infiniband.vn
        cls.vhost = make_client(APISIX_HCM, "virtual")
        # path client: để cross-verify
        cls.path  = make_client(APISIX_HCM, "path")
        cls._cleanup = []

    @classmethod
    def tearDownClass(cls):
        for key in cls._cleanup:
            try: cls.path.delete_object(Bucket=BUCKET_NAME, Key=key)
            except: pass

    # ── T2.1 ─────────────────────────────────────────────────────────────────
    def test_01_put_via_vhost(self):
        """
        boto3 (virtual) gửi:
          Host: test-thuyldx.s3-hcm.sds.infiniband.vn
          PUT  /apisix-test/<id>.txt
 
        Plugin CASE 1 rewrite thành:
          Host: s3-hcm.sds.infiniband.vn
          PUT  /test-thuyldx/apisix-test/<id>.txt
 
        Expected: HTTP 200 — Cloudian nhận đúng path-style
        """
        key = f"{RUN_ID}/vhost-put-{uuid.uuid4().hex}.txt"
        self.vhost.put_object(Bucket=BUCKET_NAME, Key=key, Body=b"vhost upload")
        self.__class__._cleanup.append(key)
        # Verify tồn tại bằng path client
        resp = self.path.head_object(Bucket=BUCKET_NAME, Key=key)
        self.assertEqual(resp["ResponseMetadata"]["HTTPStatusCode"], 200)

    # ── T2.2 ─────────────────────────────────────────────────────────────────
    def test_02_get_via_vhost(self):
        """
        Upload path-style → GET vhost-style → bytes phải identical
        Verify plugin không làm corrupt response khi rewrite.
        """
        key = f"{RUN_ID}/vhost-get-{uuid.uuid4().hex}.txt"
        original = b"get via vhost - " + uuid.uuid4().bytes
        self.path.put_object(Bucket=BUCKET_NAME, Key=key, Body=original)
        self.__class__._cleanup.append(key)
 
        body = self.vhost.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
        self.assertEqual(body, original, "Content bị thay đổi khi GET qua vhost rewrite!")

    # ── T2.3 ─────────────────────────────────────────────────────────────────
    def test_03_roundtrip_vhost_upload_path_download(self):
        """
        QUAN TRỌNG NHẤT:
        Upload vhost → Download path → bytes identical
        Upload path  → Download vhost → bytes identical

        Đây là test thực tế nhất vì production app có thể mix cả 2 style.
        Nếu plugin rewrite sai URI hoặc Host → Cloudian 403/404 → test FAIL.
        """
        # vhost upload → path download
        c1  = b"vhost-to-path-" + uuid.uuid4().bytes
        k1  = f"{RUN_ID}/rt-vp-{uuid.uuid4().hex}.bin"
        self.vhost.put_object(Bucket=BUCKET_NAME, Key=k1, Body=c1)
        self.__class__._cleanup.append(k1)
        b1 = self.path.get_object(Bucket=BUCKET_NAME, Key=k1)["Body"].read()
        self.assertEqual(c1, b1, "vhost upload → path download: content mismatch")

        # path upload → vhost download
        c2  = b"path-to-vhost-" + uuid.uuid4().bytes
        k2  = f"{RUN_ID}/rt-pv-{uuid.uuid4().hex}.bin"
        self.path.put_object(Bucket=BUCKET_NAME, Key=k2, Body=c2)
        self.__class__._cleanup.append(k2)
        b2 = self.vhost.get_object(Bucket=BUCKET_NAME, Key=k2)["Body"].read()
        self.assertEqual(c2, b2, "path upload → vhost download: content mismatch")

    # ── T2.4 ─────────────────────────────────────────────────────────────────
    def test_04_list_via_vhost(self):
        """
        LIST objects qua vhost-style
        Plugin rewrite: Host + URI → path-style
        Expected: HTTP 200
        """
        resp = self.vhost.list_objects_v2(Bucket=BUCKET_NAME, Prefix=RUN_ID, MaxKeys=10)
        self.assertIn(resp["ResponseMetadata"]["HTTPStatusCode"], [200, 204])

# =============================================================================
# T3 — Content integrity (binary, MD5)
# Mục tiêu : verify proxy_request_buffering off không làm corrupt data
# Expected : MD5 upload == MD5 download cho mọi kích thước
# =============================================================================

class T3_ContentIntegrity(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.s3 = make_client(APISIX_HCM, "path")
        cls._cleanup = []

    @classmethod
    def tearDownClass(cls):
        for key in cls._cleanup:
            try: cls.s3.delete_object(Bucket=BUCKET_NAME, Key=key)
            except: pass

    def _roundtrip(self, data: bytes) -> bool:
        key = f"{RUN_ID}/integrity-{uuid.uuid4().hex}.bin"
        self.s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=data)
        self.__class__._cleanup.append(key)
        body = self.s3.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
        return hashlib.md5(data).hexdigest() == hashlib.md5(body).hexdigest()

    def test_01_binary_all_bytes(self):
        """
        Data: bytes(0..255) × 100 = 25.6KB, bao gồm null bytes
        Expected: MD5 match — APISIX không transform binary data
        """
        self.assertTrue(self._roundtrip(bytes(range(256)) * 100))

    def test_02_1mb_random(self):
        """
        Data: 1MB random bytes
        Expected: MD5 match — streaming không bị truncate/corrupt
        """
        self.assertTrue(self._roundtrip(os.urandom(1 * 1024 * 1024)))

    def test_03_content_type_preserved(self):
        """
        PUT với Content-Type: image/jpeg
        Expected: HEAD trả đúng Content-Type (APISIX không strip header)
        """
        key = f"{RUN_ID}/ct-{uuid.uuid4().hex}.jpg"
        self.s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=b"fake jpeg",
                           ContentType="image/jpeg")
        self.__class__._cleanup.append(key)
        resp = self.s3.head_object(Bucket=BUCKET_NAME, Key=key)
        self.assertEqual(resp["ContentType"], "image/jpeg")

# =============================================================================
# T4 — HNI endpoint
# Mục tiêu : verify route HNI (route id 21/22) hoạt động độc lập với HCM
# Expected : cùng behavior như HCM nhưng qua upstream 101
# =============================================================================

class T4_PathStyle_HNI(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.s3 = make_client(APISIX_HNI, "path")
        cls._cleanup = []

    @classmethod
    def tearDownClass(cls):
        for key in cls._cleanup:
            try: cls.s3.delete_object(Bucket=BUCKET_NAME, Key=key)
            except: pass

    def test_01_list_buckets_hni(self):
        """
        HNI endpoint → route id 21/22 → upstream 101 (172.25.171.24-26)
        Expected: HTTP 200 (xác nhận HNI upstream healthy)
        """
        resp = self.s3.list_buckets()
        self.assertEqual(resp["ResponseMetadata"]["HTTPStatusCode"], 200)

    def test_02_put_get_delete_hni(self):
        """
        Roundtrip PUT→GET→DELETE qua HNI
        Expected: content match, không bị route nhầm sang HCM upstream
        """
        content = b"HNI endpoint test - " + uuid.uuid4().bytes
        key = f"{RUN_ID}/hni-{uuid.uuid4().hex}.txt"
        self.s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=content)
        self.__class__._cleanup.append(key)
        body = self.s3.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
        self.assertEqual(body, content)

# =============================================================================
# T5 — Concurrent requests
# Mục tiêu : verify không có race condition trong plugin (Lua module-level state)
# Expected : tất cả concurrent request thành công, không lẫn lộn bucket/key
# =============================================================================

class T5_Concurrent(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.s3 = make_client(APISIX_HCM, "path")
        cls._cleanup = []

    @classmethod
    def tearDownClass(cls):
        for key in cls._cleanup:
            try: cls.s3.delete_object(Bucket=BUCKET_NAME, Key=key)
            except: pass

    def test_01_concurrent_uploads(self):
        """
        10 concurrent PUT requests
        Expected: tất cả HTTP 200, content của từng object không bị lẫn lộn
        """
        n = 10
        payloads = {
            f"{RUN_ID}/concurrent-{i}-{uuid.uuid4().hex}.txt": f"payload-{i}".encode()
            for i in range(n)
        }
        for key in payloads:
            self.__class__._cleanup.append(key)
 
        def upload(item):
            key, content = item
            self.s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=content)
            return key, content

        with concurrent.futures.ThreadPoolExecutor(max_workers=n) as ex:
            results = list(ex.map(upload, payloads.items()))
 
        self.assertEqual(len(results), n)
 
        # Verify từng object đúng content
        for key, expected in results:
            body = self.s3.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
            self.assertEqual(body, expected, f"Content mismatch for key={key}")

# =============================================================================
# MAIN
# =============================================================================

import os

def main():
    print()
    print("━" * 60)
    print("  APISIX s3-normalizer-bucket-name — Integration Tests")
    print(f"  Endpoint HCM : {APISIX_HCM}")
    print(f"  Endpoint HNI : {APISIX_HNI}")
    print(f"  Bucket       : {BUCKET_NAME}")
    print(f"  Object key   : {OBJECT_KEY}")
    print(f"  Run ID       : {RUN_ID}")
    print("━" * 60)
    print()

    loader = unittest.TestLoader()
    suite  = unittest.TestSuite()
    for cls in [T1_PathStyle_HCM, T2_VhostStyle_HCM, T3_ContentIntegrity,
                T4_PathStyle_HNI, T5_Concurrent]:
        suite.addTests(loader.loadTestsFromTestCase(cls))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
 
    total  = result.testsRun
    failed = len(result.failures) + len(result.errors)
    passed = total - failed - len(result.skipped)

    print()
    print("━" * 60)
    print(f"  Total {total} | Passed {passed} | Failed {failed} | Skipped {len(result.skipped)}")
    print("━" * 60)
    sys.exit(0 if result.wasSuccessful() else 1)

if __name__ == "__main__":
    main()
