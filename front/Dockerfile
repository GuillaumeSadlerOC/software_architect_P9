# syntax=docker/dockerfile:1.7
# =============================================================================
# MicroCRM — Frontend (Angular 17)
# Multi-stage build: Node 20 (Alpine) to produce the static bundle, then
# nginx-unprivileged to serve it. Image runs as UID 101 (nginx-unprivileged)
# — no root, no setcap — compliant with restrictive Kubernetes PodSecurity.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — Build the Angular bundle
# -----------------------------------------------------------------------------
FROM node:20-alpine AS builder

WORKDIR /app

# Layer-cache friendly: install deps only when manifest changes.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# Build the app. outputPath per angular.json is dist/microcrm/browser.
COPY . .
RUN npx ng build --configuration production

# -----------------------------------------------------------------------------
# Stage 2 — Static serving
# -----------------------------------------------------------------------------
# nginxinc/nginx-unprivileged runs as UID 101 by default and listens on 8080
# (no CAP_NET_BIND_SERVICE needed, no setuid binary). Best practice for
# non-root container runtimes.
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

LABEL org.opencontainers.image.title="orion-microcrm-front" \
      org.opencontainers.image.description="Orion MicroCRM frontend (Angular 17 via Nginx)" \
      org.opencontainers.image.vendor="Orion" \
      org.opencontainers.image.source="https://github.com/OpenClassrooms-Student-Center/P7-FSJA" \
      org.opencontainers.image.licenses="MIT"

# Replace default config with our hardened one (security headers, gzip, SPA fallback).
COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf

# The Angular build emits into dist/microcrm/browser (see angular.json outputPath).
COPY --from=builder --chown=nginx:nginx /app/dist/microcrm/browser /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/ || exit 1

# Image's default CMD ["nginx", "-g", "daemon off;"] is inherited.
