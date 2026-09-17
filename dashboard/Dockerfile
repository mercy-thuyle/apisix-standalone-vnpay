# =============================================================================
# dashboard/Dockerfile — APISIX Standalone Config Dashboard
# Multi-stage: build frontend (Vite, Monaco bundle offline) → runtime Python.
# Build:  docker compose build dashboard: docker build --build-arg HTTP_PROXY=http://10.2.31.88:3128 --build-arg HTTPS_PROXY=http://10.2.31.88:3128 --build-arg http_proxy=http://10.2.31.88:3128 --build-arg https_proxy=http://10.2.31.88:3128 --build-arg NO_PROXY=.vnpaycloud.vn --build-arg no_proxy=.vnpaycloud.vn --tag registry-hcm.vnpaycloud.vn/apisix/dashboard:3.17.0-debian --file dashboard/Dockerfile dashboard
# =============================================================================

# ── Stage 1: build frontend ───────────────────────────────────────────────────
FROM registry-hcm.vnpaycloud.vn/apisix/dashboard-node:20-alpine AS frontend
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./
# npm ci: cài ĐÚNG theo package-lock.json (reproducible build trên mọi node)
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM registry-hcm.vnpaycloud.vn/apisix/dashboard-python:3.12-slim

# git: GitPython/pull/push · lua5.1: luac -p cho lint plugin (Phase 2)
RUN apt-get update \
    && apt-get install -y --no-install-recommends git lua5.1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ /app/backend/
COPY --from=frontend /build/dist /app/frontend-dist

# HOME=/app → git tự đọc /app/.netrc (mount từ secrets/.netrc-dashboard)
ENV HOME=/app \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/backend \
    LOG_DIR=/app/logs \
    FRONTEND_DIST=/app/frontend-dist

EXPOSE 18080
CMD ["python", "/app/backend/run.py"]
