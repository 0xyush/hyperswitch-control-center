# The fork's dashboard for Cloud Run (README.md §4). Build context: the repo root.
# Why not the repo-root Dockerfile:
# - its `npm i` runs the postinstall `git config core.hooksPath`, which fails without .git,
#   and Cloud Build uploads no .git;
# - webpack.server.js runs `git rev-parse HEAD`;
# - its image is Node 18, and we build and test on Node 24.
FROM node:24-bookworm-slim AS build
WORKDIR /app
ENV NODE_OPTIONS=--max-old-space-size=4096
# A stand-in for git: the build only asks it for the commit hash.
ARG GIT_COMMIT_HASH=unknown
RUN printf '#!/bin/sh\necho "%s"\n' "$GIT_COMMIT_HASH" > /usr/local/bin/git \
 && chmod +x /usr/local/bin/git
# Install without the postinstall (git hooks), then apply the repo's patches as it would.
COPY package.json package-lock.json ./
COPY patches ./patches
RUN npm ci --ignore-scripts && npx patch-package
COPY . .
RUN npm run build:prod

# Runtime: the dashboard's own server (static files, index.html fallback, /config/*), port 9000.
# Like the upstream image, it needs only dist/ and package.json.
FROM node:24-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
ARG GIT_COMMIT_HASH=unknown
ENV GIT_COMMIT_HASH=$GIT_COMMIT_HASH
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build /app/package.json ./
USER node
EXPOSE 9000
CMD ["node", "dist/server/server.js"]
