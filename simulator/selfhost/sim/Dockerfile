# The "sim" service (sim.mjs). Built on the VM: docker compose --profile sim build sim
FROM docker.io/node:24-alpine
WORKDIR /sim
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY bank.mjs calendar.mjs model.mjs pause.mjs refile.mjs sim.mjs ./
CMD ["node", "sim.mjs"]
