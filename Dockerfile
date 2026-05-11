# syntax=docker/dockerfile:1.7

# --- build stage ----------------------------------------------------------
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci

COPY tsconfig.json tsdown.config.ts ./
COPY src ./src
# Sentry telemetry is disabled in the runtime via SENTRY_DSN="" (set in the
# K8s Deployment). The build itself doesn't need SENTRY_AUTH_TOKEN — the
# rollup plugin skips sourcemap upload when the token is absent.
RUN npm run build

RUN npm prune --omit=dev

# --- runtime stage --------------------------------------------------------
FROM node:24-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8000 \
    SENTRY_DSN=""

# Non-root user (uid 1001).
RUN addgroup -S -g 1001 app && adduser -S -u 1001 -G app app

COPY --from=build --chown=app:app /app/node_modules ./node_modules
COPY --from=build --chown=app:app /app/dist ./dist
COPY --chown=app:app package.json ./

USER app
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/healthz || exit 1

CMD ["node", "dist/http-server.mjs"]
