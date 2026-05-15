FROM node:20-slim AS frontend-builder

WORKDIR /app/frontend

# Copy only what's needed - explicit paths avoid stale directory issues
COPY frontend/package.json ./package.json
COPY frontend/vite.config.js ./vite.config.js
COPY frontend/tailwind.config.js ./tailwind.config.js
COPY frontend/postcss.config.js ./postcss.config.js
COPY frontend/index.html ./index.html
COPY frontend/src ./src

RUN npm install
RUN npm run build

# ── Production image ──────────────────────────────────────────────────────────
FROM node:20-slim

LABEL description="AsBuiltReport Manager - API + Frontend"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend
COPY backend/package.json ./package.json
RUN npm install --omit=dev

COPY backend/src ./src
COPY --from=frontend-builder /app/frontend/dist /app/frontend/dist

# Verify the build actually worked
RUN test -f /app/frontend/dist/index.html || (echo "ERROR: Frontend dist missing!" && exit 1)

EXPOSE 3001
ENV NODE_ENV=production
ENV REPORTS_DIR=/var/www/reports
CMD ["node", "src/server.js"]
