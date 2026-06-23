#!/usr/bin/env bash
# scripts/debug/curl-route.sh
#
# Usage:
#   Compare NGINX vs APISIX (default)
#       ./scripts/debug/curl-route.sh
#
#   APISIX only — sau khi cut-over DNS
#       ./scripts/debug/curl-route.sh --apisix-only

NGINX_HCM="172.27.2.204"
NGINX_HNI="172.27.2.205"
APISIX_HCM="172.27.2.206"
APISIX_HNI="172.27.2.207"

# ── Compare NGINX vs APISIX ───────────────────────────────────────────────
compare() {
  local domain=$1 path=${2:-/} port=${3:-443} scheme=${4:-https}
  local nginx_ip=$5 apisix_ip=$6

  nginx_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "${domain}:${port}:${nginx_ip}" \
    "${scheme}://${domain}:${port}${path}")

  apisix_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "${domain}:${port}:${apisix_ip}" \
    "${scheme}://${domain}:${port}${path}")

  local mark="✅"; [ "$nginx_code" != "$apisix_code" ] && mark="❌"
  printf "%s %-50s NGINX=%-3s APISIX=%-3s\n" \
    "$mark" "${domain}:${port}${path}" "$nginx_code" "$apisix_code"
}

# ── APISIX only (không so sánh) ──────────────────────────────────────────
check() {
  local domain=$1 path=${2:-/} port=${3:-443} scheme=${4:-https}
  local apisix_ip=$5

  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "${domain}:${port}:${apisix_ip}" \
    "${scheme}://${domain}:${port}${path}")

  # Color: 2xx=green, 3xx=yellow, 4xx=blue, 5xx/000=red
  local mark
  case "$code" in
    2*) mark="✅" ;;
    3*) mark="↪️ " ;;
    4*) mark="🔒" ;;
    *)  mark="❌" ;;
  esac
  printf "%s %-50s %s\n" "$mark" "${domain}:${port}${path}" "$code"
}

# ════════════════════════════════════════════════════════════════════
echo "━━━ COMPARE: NGINX vs APISIX ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "── DC HCM (NGINX=$NGINX_HCM → APISIX=$APISIX_HCM) ──"
compare s3-hcm.sds.infiniband.vn          /       443   https  $NGINX_HCM $APISIX_HCM
compare cmc.sds.infiniband.vn             /       443   https  $NGINX_HCM $APISIX_HCM
compare hyperiq.sds.infiniband.vn         /       443   https  $NGINX_HCM $APISIX_HCM
compare iam.sds.infiniband.vn             /       443   https  $NGINX_HCM $APISIX_HCM
compare iam.sds.infiniband.vn             /       16443 https  $NGINX_HCM $APISIX_HCM
compare s3-admin.sds.infiniband.vn        /       443   https  $NGINX_HCM $APISIX_HCM
compare s3-admin.sds.infiniband.vn        /       19443 https  $NGINX_HCM $APISIX_HCM
compare sqs.sds.infiniband.vn             /       80    http   $NGINX_HCM $APISIX_HCM
compare s3-rgwhcm.sds.infiniband.vn       /admin/ 443   https  $NGINX_HCM $APISIX_HCM
compare s3-rgwhcm-admin.sds.infiniband.vn /       443   https  $NGINX_HCM $APISIX_HCM
compare s3-rgwhcm-admin.sds.infiniband.vn /d/     443   https  $NGINX_HCM $APISIX_HCM
compare s3-rgwhcm-admin.sds.infiniband.vn /admin/ 443   https  $NGINX_HCM $APISIX_HCM

echo ""
echo "── DC HNI (NGINX=$NGINX_HNI → APISIX=$APISIX_HNI) ──"
compare s3-hcm.sds.infiniband.vn          /       443   https  $NGINX_HNI $APISIX_HNI
compare cmc.sds.infiniband.vn             /       443   https  $NGINX_HNI $APISIX_HNI
compare hyperiq.sds.infiniband.vn         /       443   https  $NGINX_HNI $APISIX_HNI
compare iam.sds.infiniband.vn             /       443   https  $NGINX_HNI $APISIX_HNI
compare iam.sds.infiniband.vn             /       16443 https  $NGINX_HNI $APISIX_HNI
compare s3-admin.sds.infiniband.vn        /       443   https  $NGINX_HNI $APISIX_HNI
compare s3-admin.sds.infiniband.vn        /       19443 https  $NGINX_HNI $APISIX_HNI
compare sqs.sds.infiniband.vn             /       80    http   $NGINX_HNI $APISIX_HNI
compare s3-rgwhcm.sds.infiniband.vn       /admin/ 443   https  $NGINX_HNI $APISIX_HNI
compare s3-rgwhcm-admin.sds.infiniband.vn /       443   https  $NGINX_HNI $APISIX_HNI
compare s3-rgwhcm-admin.sds.infiniband.vn /d/     443   https  $NGINX_HNI $APISIX_HNI
compare s3-rgwhcm-admin.sds.infiniband.vn /admin/ 443   https  $NGINX_HNI $APISIX_HNI

# ════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ APISIX ONLY (post-migration / smoke test) ━━━━━━━━━━━━━━━━━━━━━━"
echo "── DC HCM (APISIX=$APISIX_HCM) ──"
check s3-hcm.sds.infiniband.vn          /       443   https  $APISIX_HCM
check cmc.sds.infiniband.vn             /       443   https  $APISIX_HCM
check hyperiq.sds.infiniband.vn         /       443   https  $APISIX_HCM
check iam.sds.infiniband.vn             /       443   https  $APISIX_HCM
check iam.sds.infiniband.vn             /       16443 https  $APISIX_HCM
check s3-admin.sds.infiniband.vn        /       443   https  $APISIX_HCM
check s3-admin.sds.infiniband.vn        /       19443 https  $APISIX_HCM
check sqs.sds.infiniband.vn             /       80    http   $APISIX_HCM
check s3-rgwhcm.sds.infiniband.vn       /admin/ 443   https  $APISIX_HCM
check s3-rgwhcm-admin.sds.infiniband.vn /       443   https  $APISIX_HCM
check s3-rgwhcm-admin.sds.infiniband.vn /d/     443   https  $APISIX_HCM
check s3-rgwhcm-admin.sds.infiniband.vn /admin/ 443   https  $APISIX_HCM

echo ""
echo "── DC HNI (APISIX=$APISIX_HNI) ──"
check s3-hcm.sds.infiniband.vn          /       443   https  $APISIX_HNI
check cmc.sds.infiniband.vn             /       443   https  $APISIX_HNI
check hyperiq.sds.infiniband.vn         /       443   https  $APISIX_HNI
check iam.sds.infiniband.vn             /       443   https  $APISIX_HNI
check iam.sds.infiniband.vn             /       16443 https  $APISIX_HNI
check s3-admin.sds.infiniband.vn        /       443   https  $APISIX_HNI
check s3-admin.sds.infiniband.vn        /       19443 https  $APISIX_HNI
check sqs.sds.infiniband.vn             /       80    http   $APISIX_HNI
check s3-rgwhcm.sds.infiniband.vn       /admin/ 443   https  $APISIX_HNI
check s3-rgwhcm-admin.sds.infiniband.vn /       443   https  $APISIX_HNI
check s3-rgwhcm-admin.sds.infiniband.vn /d/     443   https  $APISIX_HNI
check s3-rgwhcm-admin.sds.infiniband.vn /admin/ 443   https  $APISIX_HNI
