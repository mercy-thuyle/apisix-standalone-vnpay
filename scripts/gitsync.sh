#!/bin/sh
# gitsync.sh -> test gitsync
## DC_PROFILE: dc1 | dc2 (từ .env)

SYNC_SRC="/tmp/sync/current"

# cp ${SYNC_SRC}docker-compose.yaml /tmp/docker-compose.yaml
# cp ${SYNC_SRC}conf_system/config-${DC_PROFILE}.yaml /tmp/apisix_config/config-${DC_PROFILE}.yaml

# ── Routes ─────────────────────────────────────────────────
# cp "${SYNC_SRC}/conf_routes/apisix-${DC_PROFILE}.yaml" "/tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml"
src_route="${SYNC_SRC}/conf_routes/apisix-${DC_PROFILE}.yaml"
dst_route="/tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml"

if grep -q "PASTE_CONTENT" "${dst_route}" 2>/dev/null; then
  # dst vẫn là template chưa inject → cp bình thường
  cp "${src_route}" "${dst_route}"
  echo "[gitsync] Routes updated (template, pending cert inject)"
elif ! diff -q "${src_route}" "${dst_route}" > /dev/null 2>&1; then
  # template trên GitLab thay đổi thật (route mới, config mới...)
  # cert bị overwrite bởi placeholder → cần admin inject lại
  cp "${src_route}" "${dst_route}"
  echo "[gitsync] WARNING: Route template changed — admin cần chạy lại 3-inject-certs.sh"
else
  echo "[gitsync] Routes unchanged, skip"
fi

# ── Scripts ────────────────────────────────────────────────
cp "${SYNC_SRC}/scripts/gitsync.sh" "/tmp/scripts/gitsync.sh"

# ── Certs ──────────────────────────────────────────────────
# Chỉ sync .cert (plaintext public) và .key.enc (encrypted private key)
# KHÔNG sync .key (plaintext private key — không tồn tại trong repo)
if [ -d "${SYNC_SRC}/certs_enc" ]; then
  for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
    for ext in "cert" "key.enc"; do
      src_f="${SYNC_SRC}/certs_enc/${domain}.${ext}"
      dst_f="/tmp/certs_enc/${domain}.${ext}"
      if [ -f "${src_f}" ]; then
        if ! diff -q "${src_f}" "${dst_f}" > /dev/null 2>&1; then
          cp "${src_f}" "${dst_f}"
          echo "[gitsync] Updated: ${domain}.${ext}"
        else
          echo "[gitsync] Unchanged, skip: ${domain}.${ext}"
        fi
      else
        echo "[gitsync] WARNING: Missing in repo: ${domain}.${ext}"
      fi
    done
  done
fi

# # ── Plugins ────────────────────────────────────────────────
# if [ -d "${SYNC_SRC}/plugins" ]; then
#   cp -r "${SYNC_SRC}/plugins/*.lua" "/tmp/sync/plugins/"
# fi
