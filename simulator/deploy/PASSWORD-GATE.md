# Password gate for the public deploy (26 Oct, Aayush's ask)

One shared password in front of everything, so the link can be sent to a few people.

## Proxy (A)
- New env `SIM_PASSWORD` (from Secret Manager `revrec-sim-password`). When set:
  - `POST /gate` with form field `password`; on match set cookie `sim_gate=<hmac of password+day>` (HttpOnly, Secure,
    SameSite=Lax, 7 days) and redirect to `/`. Rate limit 10 tries per minute per IP.
  - Every other request without a valid cookie: HTML page (dashboard look: logo, one password field, button) with
    status 401. `/healthz` stays open. `/api/*` and `/sim/*` without the cookie answer 401 JSON.
- **The proxy also serves the dashboard build** (option A from README section 4) so one origin and one cookie cover
  both: copy `dist/hyperswitch` into the proxy image; serve static files; answer `/config/feature`, `/config/merchant`,
  `/config/theme` the way `src/server/Server.res` does (read config.toml + `default__<table>__<key>` env overrides);
  every other non-/api non-/sim path → `index.html`. Set `default__endpoints__api_url=/api` and
  `default__simulator__sim_url=` (empty = same origin) in the served config.
- Dockerfile: multi-stage; stage 1 builds the dashboard (`npm ci --ignore-scripts && npx patch-package && npm run build:prod`,
  Node 24, needs memory: `--machine-type=e2-highcpu-32` on Cloud Build), stage 2 = proxy image + `dist/`.
- CORS can stay but is no longer needed for the public link.

## Operator (orchestrator)
- Secrets: `revrec-sim-password` (set by Aayush), plus the three from README section 2.
- Deploy ONE service `revrec-sim` with the proxy flags from README section 3.
