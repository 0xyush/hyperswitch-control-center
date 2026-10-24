# Deploy · Rev Rec Simulator on Cloud Run (M4 prep, not deployed yet)

GCP project `hs-selfhost-0928-x825`. Two Cloud Run services: the proxy (this repo's `simulator/proxy`) and the dashboard (the fork's own server). Secrets live in Secret Manager only. Do not run these commands until Aayush says go.

## 1. One-time setup

```sh
export PROJECT=hs-selfhost-0928-x825 REGION=us-central1 REPO=revrec-sim   # region: to confirm
gcloud config set project $PROJECT
gcloud services enable run.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com
gcloud artifacts repositories create $REPO --repository-format=docker --location=$REGION
gcloud iam service-accounts create revrec-sim-proxy --display-name="Rev Rec simulator proxy"
export SA=revrec-sim-proxy@$PROJECT.iam.gserviceaccount.com
```

## 2. Secrets (names only; values come from `simulator/proxy/.env` and are never typed or printed)

| Secret Manager name           | Proxy env var      | What it is                                                     |
| ----------------------------- | ------------------ | -------------------------------------------------------------- |
| `revrec-sim-hs-api-key`       | `HS_API_KEY`       | Hyperswitch sandbox API key of the Rev Rec merchant            |
| `revrec-sim-stripe-test-key`  | `STRIPE_TEST_KEY`  | Stripe test-mode secret key (`sk_test_…` only)                 |
| `revrec-sim-hs-dashboard-jwt` | `HS_DASHBOARD_JWT` | Dashboard token; the proxy switches it to the Rev Rec merchant |

```sh
for pair in HS_API_KEY:revrec-sim-hs-api-key STRIPE_TEST_KEY:revrec-sim-stripe-test-key \
            HS_DASHBOARD_JWT:revrec-sim-hs-dashboard-jwt; do
  key=${pair%%:*}; name=${pair#*:}
  grep "^$key=" simulator/proxy/.env | cut -d= -f2- | tr -d '\n' \
    | gcloud secrets create $name --replication-policy=automatic --data-file=-
  gcloud secrets add-iam-policy-binding $name \
    --member=serviceAccount:$SA --role=roles/secretmanager.secretAccessor
done
```

To rotate a value (for example the dashboard token, which expires about every 2 days): pipe the new value into `gcloud secrets versions add <name> --data-file=-`, then make a new revision with `gcloud run services update revrec-sim-proxy --region $REGION --update-secrets HS_DASHBOARD_JWT=revrec-sim-hs-dashboard-jwt:latest`. Automatic login and renewal is M4 work.

The non-secret settings (base URL, profile, connector and merchant ids, origins, limits) are in `simulator/deploy/proxy.env.yaml`.

## 3. The proxy service

```sh
export IMAGE=$REGION-docker.pkg.dev/$PROJECT/$REPO/proxy:$(git rev-parse --short HEAD)
gcloud builds submit simulator/proxy --tag $IMAGE
gcloud run deploy revrec-sim-proxy --image $IMAGE --region $REGION \
  --service-account $SA --allow-unauthenticated \
  --min-instances 1 --max-instances 1 --no-cpu-throttling \
  --concurrency 80 --timeout 60 --port 8080 \
  --env-vars-file simulator/deploy/proxy.env.yaml \
  --set-secrets HS_API_KEY=revrec-sim-hs-api-key:latest,STRIPE_TEST_KEY=revrec-sim-stripe-test-key:latest,HS_DASHBOARD_JWT=revrec-sim-hs-dashboard-jwt:latest
curl -s "$(gcloud run services describe revrec-sim-proxy --region $REGION --format='value(status.url)')/healthz"
```

Why these flags:

- `--min-instances 1 --max-instances 1`: stories, portfolio runs, rate limits and the call queue live in memory. A second instance would split them; zero instances would lose them and stop the timers.
- `--no-cpu-throttling`: story starts, portfolio ticks and the hourly contract test run after the HTTP response. With CPU only during requests, they would stall.
- `TRUST_PROXY=1` is set in the image: behind Cloud Run the client IP comes from `X-Forwarded-For`.
- `--allow-unauthenticated`: the simulator is a public link (PRD §13). Operator pages behind Google sign-in come later.

**Known limits of this first cut:** stories and portfolio runs are lost on each new revision (the `data/` folder is in the instance). The dashboard token must be rotated by hand.

**Monitoring:**

- A Cloud Monitoring uptime check on `/healthz`. It answers `"ok": false` when the sandbox, Stripe, the config or the hourly contract test fails.
- A log-based alert on the text `contract test FAILED`.

## 4. The dashboard: where the static build is served from

The dashboard needs more than static files. Its own server (`src/server/Server.res`, `npm run serve`, port 9000) also answers `/config/feature`, `/config/merchant` and `/config/theme` from `config.toml`, with env overrides named `default__<table>__<key>`. It rewrites every other path to `index.html` (`serve-handler`, rewrite `**` → `index.html`), so a page refresh on `/dashboard/v2/recovery/...` returns the app. B's refresh bug came from the hosted sandbox's ingress, not from this server.

| Option                                          | How                                                                                                                                                                                                                                 | For                                                                                                                                                | Against                                                                                                                                           |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| A. The proxy serves the build                   | Copy `dist/hyperswitch` into the proxy image. The proxy serves files, falls back to `index.html`, and answers `/config/*`.                                                                                                          | One service, same origin, no CORS                                                                                                                  | The proxy must re-implement the `/config/*` handlers (the dashboard's server starts listening when imported, so it cannot be reused). Fork drift. |
| **B. A second Cloud Run service (recommended)** | `simulator/deploy/dashboard.Dockerfile` (`npm run build:prod` on Node 24, then the dashboard's own server on 9000). Config by env: `default__endpoints__api_url=https://<proxy>/api`, `default__simulator__sim_url=https://<proxy>` | No new code. The dashboard's own fallback and config. The same topology as local dev today (9000 → 8787), which B has tested. Independent deploys. | Two URLs; the browser calls the proxy cross-origin (CORS is already in place: `ALLOWED_ORIGINS` = the dashboard URL).                             |
| C. One service, two containers (sidecar)        | The proxy is the ingress (8080) and forwards page paths to the dashboard server on `localhost:9000`.                                                                                                                                | Same origin, both images unchanged                                                                                                                 | A multi-container service YAML, and a forward rule in the proxy.                                                                                  |

**Recommendation: B for M4.** It needs no code and runs the dashboard the way it already runs. Move to C later only if the simulator needs one origin. That would be the case if the proxy has to write the visitor's leased profile into `index.html`. Even then, a call from the dashboard to the proxy (`GET /sim/session`) does the same job.

```sh
export DASH_IMAGE=$REGION-docker.pkg.dev/$PROJECT/$REPO/dashboard:$(git rev-parse --short HEAD)
gcloud builds submit . --config simulator/deploy/cloudbuild.dashboard.yaml \
  --substitutions _IMAGE=$DASH_IMAGE,_GIT_COMMIT=$(git rev-parse HEAD)
gcloud run deploy revrec-sim-dashboard --image $DASH_IMAGE --region $REGION \
  --allow-unauthenticated --port 9000 --min-instances 0 \
  --set-env-vars "^@^default__endpoints__api_url=https://<proxy-url>/api@default__simulator__sim_url=https://<proxy-url>@default__features__simulator_demo_session=true@default__features__dev_recovery_simulator=true@default__features__dev_recovery_v2_product=true@default__simulator__org_id=<org>@default__simulator__merchant_id=<merchant>@default__simulator__profile_id=<profile>"
# Then put the dashboard URL in proxy.env.yaml (ALLOWED_ORIGINS) and redeploy the proxy.
```

- **Keys checked by B** with the dashboard's own config handler: `api_url`, `sim_url` (no `/api`; the dashboard calls `/sim/*` there), the three feature flags and the simulator ids. The flags and ids are already in the committed `config.toml`, so only `api_url` and `sim_url` are strictly needed.
- **Why not the repo-root `Dockerfile`:**
  - Its `npm i` runs the postinstall `git config core.hooksPath`, which fails without `.git`, and Cloud Build uploads no `.git`.
  - `webpack.server.js` runs `git rev-parse HEAD`.
  - Its image is Node 18.
  - `dashboard.Dockerfile` fixes all three without touching upstream files: Node 24, `npm ci --ignore-scripts` then `patch-package`, and a git stand-in that prints the commit passed as `GIT_COMMIT_HASH`. Its own ignore file keeps `node_modules`, `.git` and every `.env` out of the build context.
- **Tested locally on 23 Oct, partly:** `npm ci` without the git hook, `patch-package`, the ReScript build (4,367 files) and the webpack config load (with the git stand-in) all passed. The webpack production build was then killed for lack of memory in the 6 GB local Docker VM, so the last step is not verified. `cloudbuild.dashboard.yaml` uses a 32 GB machine.
