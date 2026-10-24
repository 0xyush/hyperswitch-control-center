# Rev Rec Simulator proxy. Node 24 runs the TypeScript sources directly: no build step.
# Cloud Run: see simulator/deploy/README.md. Secrets come from the environment, never from the image.
FROM node:24-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8080 \
    TRUST_PROXY=1

# No runtime dependencies today; the dev tools (typescript, @types/node) are not installed.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

COPY src ./src
# Stories and portfolio runs are kept here. On Cloud Run this is lost on every new instance.
RUN mkdir -p /app/data && chown node:node /app/data

USER node
EXPOSE 8080
CMD ["node", "src/server.ts"]
