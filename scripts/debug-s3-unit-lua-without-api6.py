#!/usr/bin/env python3
"""
Tầng 1  →  chạy ngay, offline, confirm không có logic bug
debug-s3-unit-lua-without-api6.py -> Xác nhận plugin logic không có bug
=========================
Unit test thuần Python — mirror chính xác logic Lua trong:
  - s3-validator-bucket-name-utils.lua  (isBucket, isBucketInDomain, extractBucketFromDomain, extractBucketFromPath)
  - s3-normalizer-bucket-name.lua       (rewrite phase: CASE1 vhost, CASE2 path, CASE3 passthrough)

Chạy:
  python3 debug-s3-unit-lua-without-api6.py
  python3 debug-s3-unit-lua-without-api6.py -v    # verbose

Không cần APISIX đang chạy — test offline logic thuần.

Verify rằng: "Nếu logic Lua được viết đúng như tôi đọc hiểu, thì các pattern match hoạt động đúng".
Đây là kiểm tra lý thuyết của plugin, không phải kiểm tra hệ thống
Nếu PASS → logic Lua không có bug về pattern matching. Nếu FAIL → có bug trong isBucket() hoặc isBucketInDomain().

"""

import re
import sys
import unittest

# =============================================================================
# Python reimplementation of s3-validator-bucket-name-utils.lua
# (Mirror chính xác từng function để test logic, không phải test Python)
# =============================================================================

class S3ValidatorUtils:
    """
    Mirror của s3-validator-bucket-name-utils.lua
    Lua pattern → Python re (đã chuyển đổi):
      %w  → [a-zA-Z0-9_]   (Lua word char)
      %-  → -               (escaped hyphen trong Lua pattern)
      %.  → [.]             (escaped dot trong Lua pattern)
    Chú ý: Lua %w bao gồm underscore (_), Python \w cũng vậy → dùng \w
    """

    @staticmethod
    def isBucket(name: str) -> bool:
        """
        isBucket: validate S3 bucket name
        Lua: ^%w+%-%w[%w%-]*%w$  (dạng dài: word-w[w-]*w)
             ^%w+%-%w$           (dạng ngắn: word-w)
        
        Hợp lệ:   my-bucket, data-lake-01, tx-1, s3-a
        Lỗi:      bucket (không có -), -bad (bắt đầu -), bad- (kết thúc -),
                  bad--name (-- liên tiếp), "" (rỗng), None
        """
        if not name:
            return False
        # Dạng dài: \w+-\w[\w-]*\w
        if re.fullmatch(r'\w+-\w[\w-]*\w', name):
            return True
        # Dạng ngắn: \w+-\w  (vd: tx-1, s3-a)
        if re.fullmatch(r'\w+-\w', name):
            return True
        return False

    @staticmethod
    def isBucketInPath(uri: str) -> bool:
        """
        isBucketInPath: URI path-style có bucket hợp lệ
        Lua: ^/%w+%-%w[%w%-]*%w+/?$     (trailing slash, không có key)
             ^/%w+%-%w[%w%-]*%w+/.+$    (có key)
        """
        if not uri:
            return False
        if re.fullmatch(r'/\w+-\w[\w-]*\w+/?', uri):
            return True
        if re.fullmatch(r'/\w+-\w[\w-]*\w+/.+', uri):
            return True
        return False

    @staticmethod
    def isBucketInDomain(hostname: str, domains: list) -> bool:
        """
        isBucketInDomain: vhost-style hostname <bucket>.<domain-suffix>
        domains là Lua pattern suffix (đã escape) — ở Python ta dùng plain string
        vì ta tự build pattern.
        
        Lua pattern: ^%w+%-%w[%w%-]*%w+%.<suffix>$   (dạng dài)
                     ^%w+%-%w%.<suffix>$              (dạng ngắn)
        
        Trong Python: suffix đã là plain string (converted từ Lua escape → real chars)
                      nên ta cần re.escape suffix khi build pattern.
        """
        if not hostname or not domains:
            return False
        for suffix_lua in domains:
            # Convert Lua escaped pattern → real domain string
            # "s3%-hcm%.sds%.infiniband%.vn" → "s3-hcm.sds.infiniband.vn"
            suffix_plain = suffix_lua.replace('%-', '-').replace('%.', '.')
            suffix_re = re.escape(suffix_plain)
            # Dạng dài: bucket-name.domain-suffix
            if re.fullmatch(r'\w+-\w[\w-]*\w+\.' + suffix_re, hostname):
                return True
            # Dạng ngắn: bk-1.domain-suffix
            if re.fullmatch(r'\w+-\w\.' + suffix_re, hostname):
                return True
        return False

    @staticmethod
    def extractBucketFromDomain(hostname: str, domains: list) -> str | None:
        """
        extractBucketFromDomain: trích xuất bucket từ vhost hostname
        Lua: string.match(hostname, "^([%w%-]+)%." .. suffix .. "$")
        """
        if not hostname or not domains:
            return None
        for suffix_lua in domains:
            suffix_plain = suffix_lua.replace('%-', '-').replace('%.', '.')
            suffix_re = re.escape(suffix_plain)
            m = re.fullmatch(r'([\w-]+)\.' + suffix_re, hostname)
            if m:
                return m.group(1)
        return None

    @staticmethod
    def extractBucketFromPath(uri: str) -> str | None:
        """
        extractBucketFromPath: trích xuất bucket từ path-style URI
        Lua: string.match(uri, "^/([^/?]+)")
        """
        if not uri or uri in ('/', ''):
            return None
        m = re.match(r'^/([^/?]+)', uri)
        return m.group(1) if m else None


# =============================================================================
# APISIX Plugin logic mirror (rewrite phase)
# =============================================================================

class S3NormalizerSimulator:
    """
    Simulate rewrite() phase của s3-normalizer-bucket-name.lua.
    Return: (status_code, new_uri, new_host) hoặc (error_code, error_msg)
    """

    def __init__(self, path_hosts: list, vhost_domains: list):
        self.path_hosts = path_hosts
        self.vhost_domains = vhost_domains
        self.utils = S3ValidatorUtils()

    def rewrite(self, host: str, uri: str) -> dict:
        """
        Simulate plugin rewrite phase.
        Returns dict:
          { 'action': 'vhost_rewrite'|'path_passthrough'|'passthrough'|'error',
            'new_uri': str, 'new_host': str, 'error': str, 'status': int }
        """
        if not host:
            return {'action': 'error', 'status': 400, 'error': 'Missing Host header'}

        host_no_port = host.split(':')[0]

        # CASE 1: vhost-style
        if self.utils.isBucketInDomain(host_no_port, self.vhost_domains):
            bucket = self.utils.extractBucketFromDomain(host_no_port, self.vhost_domains)
            if not bucket:
                return {'action': 'error', 'status': 400, 'error': f'Invalid vhost format: {host}'}
            if not self.utils.isBucket(bucket):
                return {'action': 'error', 'status': 400, 'error': f"Invalid S3 bucket name '{bucket}'"}
            path_host = self.path_hosts[0]
            new_uri = '/' + bucket + uri
            return {'action': 'vhost_rewrite', 'new_uri': new_uri, 'new_host': path_host, 'status': 200}

        # CASE 2: path-style
        is_path_host = host_no_port in self.path_hosts
        if not is_path_host:
            return {'action': 'passthrough', 'status': 200, 'reason': 'not in path_hosts or vhost_domains'}

        if uri in ('/', ''):
            return {'action': 'path_passthrough', 'status': 200, 'reason': 'list-all-buckets'}

        bucket = self.utils.extractBucketFromPath(uri)
        if not bucket:
            return {'action': 'path_passthrough', 'status': 200, 'reason': 'no bucket segment'}

        if not self.utils.isBucket(bucket):
            return {'action': 'error', 'status': 400, 'error': f"Invalid S3 bucket name '{bucket}'"}

        return {'action': 'path_passthrough', 'status': 200, 'bucket': bucket}


# =============================================================================
# Test Cases
# =============================================================================

class TestIsBucket(unittest.TestCase):
    """Test isBucket() — bucket name validation"""

    def test_valid_standard(self):
        cases = ['my-bucket', 'data-lake-01', 'logs-hcm', 'test-bucket-abc',
                 'a-b', 'x-1', 'backup-2024']
        for name in cases:
            with self.subTest(name=name):
                self.assertTrue(S3ValidatorUtils.isBucket(name), f"Expected valid: {name}")

    def test_valid_short(self):
        # Dạng ngắn: word-single_char (khớp ^%w+%-%w$)
        cases = ['tx-1', 's3-a', 'bk-z']
        for name in cases:
            with self.subTest(name=name):
                self.assertTrue(S3ValidatorUtils.isBucket(name), f"Expected valid short: {name}")

    def test_invalid_no_hyphen(self):
        # Không có dấu gạch ngang → invalid
        cases = ['bucket', 'mybucket', 'logs', 'abc123']
        for name in cases:
            with self.subTest(name=name):
                self.assertFalse(S3ValidatorUtils.isBucket(name), f"Expected invalid: {name}")

    def test_invalid_leading_hyphen(self):
        cases = ['-bucket', '-bad-name']
        for name in cases:
            with self.subTest(name=name):
                self.assertFalse(S3ValidatorUtils.isBucket(name))

    def test_invalid_trailing_hyphen(self):
        cases = ['bucket-', 'my-name-']
        for name in cases:
            with self.subTest(name=name):
                self.assertFalse(S3ValidatorUtils.isBucket(name))

    def test_invalid_double_hyphen(self):
        # Lua pattern không cho -- liên tiếp vì \w[\w-]*\w không match chuỗi rỗng
        # "bad--name" → segment giữa 2 hyphen là rỗng → pattern thực ra khớp nếu không check
        # Kiểm tra lại: "bad--name" → regex \w+-\w[\w-]*\w → b-a-d- không match \w+
        # thực ra "bad--name": b-a-d -- n-a-m-e => \w+ = "bad", - , \w = ""-  KHÔNG match vì
        # sau - phải là \w (single char bắt đầu). "bad--name": after first "-" is "-" which is not \w
        cases = ['bad--name', 'a--b']
        for name in cases:
            with self.subTest(name=name):
                self.assertFalse(S3ValidatorUtils.isBucket(name))

    def test_invalid_empty_none(self):
        self.assertFalse(S3ValidatorUtils.isBucket(''))
        self.assertFalse(S3ValidatorUtils.isBucket(None))


class TestIsBucketInDomain(unittest.TestCase):
    """Test isBucketInDomain() — vhost match"""

    def setUp(self):
        self.domains_sandbox = [
            "s3%-hcm%.sds%.infiniband%.vn",
            "s3%-hni%.sds%.infiniband%.vn"
        ]
        self.domains_lab = ["s3%.hcm%.lab%.thuyldx"]

    def test_valid_vhost_sandbox(self):
        cases = [
            'my-bucket.s3-hcm.sds.infiniband.vn',
            'data-lake.s3-hcm.sds.infiniband.vn',
            'backup-01.s3-hni.sds.infiniband.vn',
            'tx-1.s3-hcm.sds.infiniband.vn',   # short bucket
        ]
        for host in cases:
            with self.subTest(host=host):
                self.assertTrue(
                    S3ValidatorUtils.isBucketInDomain(host, self.domains_sandbox),
                    f"Expected vhost match: {host}"
                )

    def test_valid_vhost_lab(self):
        cases = [
            'my-bucket.s3.hcm.lab.thuyldx',
            'data-lake.s3.hcm.lab.thuyldx',
        ]
        for host in cases:
            with self.subTest(host=host):
                self.assertTrue(
                    S3ValidatorUtils.isBucketInDomain(host, self.domains_lab)
                )

    def test_invalid_path_style_host(self):
        # path-style host (no bucket prefix) → NOT vhost
        cases = [
            's3-hcm.sds.infiniband.vn',
            's3-hni.sds.infiniband.vn',
            's3.hcm.lab.thuyldx',
        ]
        for host in cases:
            with self.subTest(host=host):
                self.assertFalse(
                    S3ValidatorUtils.isBucketInDomain(host, self.domains_sandbox + self.domains_lab)
                )

    def test_invalid_bucket_no_hyphen(self):
        # bucket không có hyphen → isBucketInDomain trả false
        cases = [
            'mybucket.s3-hcm.sds.infiniband.vn',
            'logs.s3-hni.sds.infiniband.vn',
        ]
        for host in cases:
            with self.subTest(host=host):
                self.assertFalse(
                    S3ValidatorUtils.isBucketInDomain(host, self.domains_sandbox)
                )

    def test_cross_domain_no_match(self):
        # hcm domain không match hni pattern
        self.assertFalse(
            S3ValidatorUtils.isBucketInDomain(
                'my-bucket.s3-hcm.sds.infiniband.vn',
                ["s3%-hni%.sds%.infiniband%.vn"]
            )
        )


class TestExtractBucketFromDomain(unittest.TestCase):
    """Test extractBucketFromDomain()"""

    def setUp(self):
        self.domains = [
            "s3%-hcm%.sds%.infiniband%.vn",
            "s3%-hni%.sds%.infiniband%.vn"
        ]

    def test_extract_valid(self):
        cases = [
            ('my-bucket.s3-hcm.sds.infiniband.vn', 'my-bucket'),
            ('data-lake.s3-hni.sds.infiniband.vn', 'data-lake'),
            ('backup-01.s3-hcm.sds.infiniband.vn', 'backup-01'),
        ]
        for host, expected_bucket in cases:
            with self.subTest(host=host):
                result = S3ValidatorUtils.extractBucketFromDomain(host, self.domains)
                self.assertEqual(result, expected_bucket)

    def test_extract_no_match(self):
        # path-style → không extract được
        result = S3ValidatorUtils.extractBucketFromDomain(
            's3-hcm.sds.infiniband.vn', self.domains
        )
        self.assertIsNone(result)

    def test_extract_wrong_domain(self):
        result = S3ValidatorUtils.extractBucketFromDomain(
            'my-bucket.s3-prod.other.com', self.domains
        )
        self.assertIsNone(result)


class TestExtractBucketFromPath(unittest.TestCase):
    """Test extractBucketFromPath()"""

    def test_extract_with_key(self):
        cases = [
            ('/my-bucket/photos/img.jpg', 'my-bucket'),
            ('/data-lake/2024/log.gz', 'data-lake'),
            ('/backup-01/file.txt', 'backup-01'),
        ]
        for uri, expected in cases:
            with self.subTest(uri=uri):
                self.assertEqual(S3ValidatorUtils.extractBucketFromPath(uri), expected)

    def test_extract_bucket_only(self):
        # /bucket/ hoặc /bucket (không có key)
        self.assertEqual(S3ValidatorUtils.extractBucketFromPath('/my-bucket/'), 'my-bucket')
        self.assertEqual(S3ValidatorUtils.extractBucketFromPath('/my-bucket'), 'my-bucket')

    def test_extract_root(self):
        self.assertIsNone(S3ValidatorUtils.extractBucketFromPath('/'))
        self.assertIsNone(S3ValidatorUtils.extractBucketFromPath(''))
        self.assertIsNone(S3ValidatorUtils.extractBucketFromPath(None))

    def test_extract_query_string(self):
        # Query string không làm ảnh hưởng bucket extraction
        self.assertEqual(
            S3ValidatorUtils.extractBucketFromPath('/my-bucket?prefix=data'),
            'my-bucket'
        )


class TestNormalizerRewriteHCM(unittest.TestCase):
    """Test rewrite phase — HCM route (route id 11/12 trong apisix-dc1.yaml)"""

    def setUp(self):
        self.plugin = S3NormalizerSimulator(
            path_hosts=["s3-hcm.sds.infiniband.vn"],
            vhost_domains=["s3%-hcm%.sds%.infiniband%.vn"]
        )

    # ── CASE 1: vhost-style rewrite ────────────────────────────────────────

    def test_vhost_object_get(self):
        """GET vhost-style → rewrite URI, set Host"""
        result = self.plugin.rewrite('my-bucket.s3-hcm.sds.infiniband.vn', '/photos/img.jpg')
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/my-bucket/photos/img.jpg')
        self.assertEqual(result['new_host'], 's3-hcm.sds.infiniband.vn')

    def test_vhost_object_put(self):
        """PUT vhost-style upload"""
        result = self.plugin.rewrite('data-lake.s3-hcm.sds.infiniband.vn', '/2024/log.gz')
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/data-lake/2024/log.gz')

    def test_vhost_root_uri(self):
        """GET vhost-style / → rewrite thành /<bucket>/"""
        result = self.plugin.rewrite('my-bucket.s3-hcm.sds.infiniband.vn', '/')
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/my-bucket/')

    def test_vhost_with_port(self):
        """Host header có port → strip port rồi match"""
        result = self.plugin.rewrite('my-bucket.s3-hcm.sds.infiniband.vn:443', '/file.txt')
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/my-bucket/file.txt')

    def test_vhost_invalid_bucket_in_host(self):
        """Bucket name không hợp lệ trong vhost → 400"""
        # "mybucket" (không có hyphen) → isBucketInDomain trả false → fall to CASE2/CASE3
        # Nhưng nếu domain match thì extractBucket trả "mybucket" → isBucket false → 400
        # Thực ra isBucketInDomain cũng check pattern nên sẽ trả false trước → CASE3 passthrough
        # Đây là test để document behavior
        result = self.plugin.rewrite('mybucket.s3-hcm.sds.infiniband.vn', '/file.txt')
        # isBucketInDomain requires hyphen in bucket → false → CASE3 passthrough (host not in path_hosts)
        self.assertIn(result['action'], ['passthrough', 'error'])

    # ── CASE 2: path-style passthrough ────────────────────────────────────

    def test_path_valid_bucket(self):
        """path-style với bucket hợp lệ → passthrough"""
        result = self.plugin.rewrite('s3-hcm.sds.infiniband.vn', '/my-bucket/photos/img.jpg')
        self.assertEqual(result['action'], 'path_passthrough')
        self.assertEqual(result.get('bucket'), 'my-bucket')

    def test_path_list_all_buckets(self):
        """GET / trên path host → list-all-buckets, passthrough"""
        result = self.plugin.rewrite('s3-hcm.sds.infiniband.vn', '/')
        self.assertEqual(result['action'], 'path_passthrough')
        self.assertIn('list-all-buckets', result.get('reason', ''))

    def test_path_invalid_bucket_name(self):
        """path-style nhưng bucket name invalid → 400"""
        # "mybucket" không có hyphen → isBucket = False → 400
        result = self.plugin.rewrite('s3-hcm.sds.infiniband.vn', '/mybucket/file.txt')
        self.assertEqual(result['action'], 'error')
        self.assertEqual(result['status'], 400)

    # ── CASE 3: passthrough (không match) ─────────────────────────────────

    def test_unknown_host_passthrough(self):
        """Host không thuộc route → passthrough"""
        result = self.plugin.rewrite('other.domain.com', '/any/path')
        self.assertEqual(result['action'], 'passthrough')

    def test_missing_host(self):
        """Không có Host header → 400"""
        result = self.plugin.rewrite('', '/file.txt')
        self.assertEqual(result['action'], 'error')
        self.assertEqual(result['status'], 400)


class TestNormalizerRewriteHNI(unittest.TestCase):
    """Test rewrite phase — HNI route (route id 21/22 trong apisix-dc1.yaml)"""

    def setUp(self):
        self.plugin = S3NormalizerSimulator(
            path_hosts=["s3-hni.sds.infiniband.vn"],
            vhost_domains=["s3%-hni%.sds%.infiniband%.vn"]
        )

    def test_vhost_hni(self):
        result = self.plugin.rewrite('backup-01.s3-hni.sds.infiniband.vn', '/db/dump.sql')
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/backup-01/db/dump.sql')
        self.assertEqual(result['new_host'], 's3-hni.sds.infiniband.vn')

    def test_path_hni(self):
        result = self.plugin.rewrite('s3-hni.sds.infiniband.vn', '/backup-01/db/dump.sql')
        self.assertEqual(result['action'], 'path_passthrough')

    def test_hcm_vhost_not_match_hni_route(self):
        """HCM vhost không được match trên HNI route"""
        result = self.plugin.rewrite('my-bucket.s3-hcm.sds.infiniband.vn', '/file.txt')
        # isBucketInDomain với hni domains → false; host not in hni path_hosts → passthrough
        self.assertEqual(result['action'], 'passthrough')


class TestNormalizerRewriteLab(unittest.TestCase):
    """Test rewrite phase — Lab route (s3.hcm.lab.thuyldx trong apisix-dc1.yaml)"""

    def setUp(self):
        self.plugin = S3NormalizerSimulator(
            path_hosts=["s3.hcm.lab.thuyldx"],
            vhost_domains=["s3%.hcm%.lab%.thuyldx"]
        )

    def test_vhost_lab(self):
        result = self.plugin.rewrite('my-bucket.s3.hcm.lab.thuyldx', '/test/file.txt')
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/my-bucket/test/file.txt')
        self.assertEqual(result['new_host'], 's3.hcm.lab.thuyldx')

    def test_path_lab(self):
        result = self.plugin.rewrite('s3.hcm.lab.thuyldx', '/my-bucket/test/file.txt')
        self.assertEqual(result['action'], 'path_passthrough')


class TestEdgeCases(unittest.TestCase):
    """Edge cases và boundary conditions"""

    def test_bucket_name_with_numbers(self):
        self.assertTrue(S3ValidatorUtils.isBucket('data-2024'))
        self.assertTrue(S3ValidatorUtils.isBucket('backup-20240101'))

    def test_bucket_name_with_underscore(self):
        # Lua %w bao gồm underscore
        self.assertTrue(S3ValidatorUtils.isBucket('my_bucket-01'))  # _ trong \w

    def test_deep_nested_key(self):
        """URI với key nhiều cấp thư mục"""
        result = S3ValidatorUtils.extractBucketFromPath('/my-bucket/a/b/c/d/file.tar.gz')
        self.assertEqual(result, 'my-bucket')

    def test_uri_with_query_params(self):
        """S3 list objects: /bucket?prefix=logs/&delimiter=/"""
        result = S3ValidatorUtils.extractBucketFromPath('/my-bucket?prefix=logs/')
        self.assertEqual(result, 'my-bucket')

    def test_vhost_multipart_upload(self):
        """Multipart upload URI pattern"""
        plugin = S3NormalizerSimulator(
            path_hosts=["s3-hcm.sds.infiniband.vn"],
            vhost_domains=["s3%-hcm%.sds%.infiniband%.vn"]
        )
        result = plugin.rewrite(
            'my-bucket.s3-hcm.sds.infiniband.vn',
            '/large-file.dat?uploadId=abc123&partNumber=1'
        )
        self.assertEqual(result['action'], 'vhost_rewrite')
        self.assertEqual(result['new_uri'], '/my-bucket/large-file.dat?uploadId=abc123&partNumber=1')

    def test_route_id98_debug_normalized(self):
        """
        route id=98 (debug-dump-normalized) dùng cả 2 domain trong 1 plugin instance
        Simulate: path_hosts có cả hcm lẫn hni
        """
        plugin = S3NormalizerSimulator(
            path_hosts=["s3-hcm.sds.infiniband.vn", "s3-hni.sds.infiniband.vn"],
            vhost_domains=["s3%-hcm%.sds%.infiniband%.vn", "s3%-hni%.sds%.infiniband%.vn"]
        )
        # hcm vhost
        r1 = plugin.rewrite('my-bucket.s3-hcm.sds.infiniband.vn', '/file.txt')
        self.assertEqual(r1['action'], 'vhost_rewrite')
        self.assertEqual(r1['new_host'], 's3-hcm.sds.infiniband.vn')  # path_hosts[0]

        # hni path
        r2 = plugin.rewrite('s3-hni.sds.infiniband.vn', '/my-bucket/file.txt')
        self.assertEqual(r2['action'], 'path_passthrough')


# =============================================================================
# Main
# =============================================================================

if __name__ == '__main__':
    # Colorized output
    PASS = '\033[92m✓\033[0m'
    FAIL = '\033[91m✗\033[0m'

    loader = unittest.TestLoader()
    suite  = loader.discover('.', pattern='test_s3_validator_unit.py')

    class ColorResult(unittest.TextTestResult):
        def addSuccess(self, test):
            super().addSuccess(test)
            if self.showAll:
                self.stream.writeln(f'  {PASS} {test._testMethodDoc or test._testMethodName}')
        def addFailure(self, test, err):
            super().addFailure(test, err)
            if self.showAll:
                self.stream.writeln(f'  {FAIL} {test._testMethodDoc or test._testMethodName}')
        def addError(self, test, err):
            super().addError(test, err)
            if self.showAll:
                self.stream.writeln(f'  {FAIL} ERROR: {test._testMethodDoc or test._testMethodName}')

    runner = unittest.TextTestRunner(
        verbosity=2,
        resultclass=ColorResult
    )

    print("\n" + "="*65)
    print("  s3-normalizer-bucket-name — Unit Test Suite")
    print("  Mirror logic: s3-validator-bucket-name-utils.lua")
    print("="*65 + "\n")

    result = runner.run(
        unittest.TestLoader().loadTestsFromModule(
            __import__('__main__')
        )
    )

    print("\n" + "="*65)
    total  = result.testsRun
    passed = total - len(result.failures) - len(result.errors)
    print(f"  Total: {total} | Passed: {passed} | Failed: {len(result.failures)} | Errors: {len(result.errors)}")
    print("="*65)

    sys.exit(0 if result.wasSuccessful() else 1)