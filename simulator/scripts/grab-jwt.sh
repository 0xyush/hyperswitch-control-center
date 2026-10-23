#!/usr/bin/env bash
# Reads the Hyperswitch dashboard login token from your logged-in Chrome tab
# (localStorage USER_INFO) and writes it into simulator/proxy/.env as HS_DASHBOARD_JWT.
# Never prints the token. Run it yourself:  bash simulator/scripts/grab-jwt.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/simulator/proxy/.env"
mkdir -p "$(dirname "$ENV_FILE")"

INFO=$(osascript -l JavaScript -e '
const chrome = Application("Google Chrome");
let tab = null;
for (const w of chrome.windows()) for (const t of w.tabs()) {
  const u = t.url();
  if (u.includes("app.hyperswitch.io") || u.includes("sandbox.hyperswitch.io")) { tab = t; break; }
}
if (!tab) { JSON.stringify({err:"no hyperswitch dashboard tab open in Chrome"}); } else {
  const js = `(function(){ try {
    const raw = localStorage.getItem("USER_INFO");
    if (!raw) return JSON.stringify({err:"no USER_INFO in localStorage (not logged in?)"});
    const j = JSON.parse(raw);
    return JSON.stringify({token:j.token||"", merchant_id:j.merchant_id||"", profile_id:j.profile_id||"", org_id:j.org_id||"", email:j.email||""});
  } catch(e) { return JSON.stringify({err:String(e)}); } })()`;
  chrome.execute(tab, {javascript: js});
}')

python3 - "$INFO" "$ENV_FILE" <<'PY'
import json, sys, re, os
info, env_file = sys.argv[1], sys.argv[2]
try:
    j = json.loads(info)
except Exception:
    sys.exit("Chrome returned something unexpected: " + info[:120])
if j.get("err"):
    sys.exit("Error: " + j["err"])
tok = j.get("token")
if not tok:
    sys.exit("No token in USER_INFO. Log in to the dashboard in Chrome first.")
env = open(env_file).read() if os.path.exists(env_file) else ""
def setk(env, k, v):
    if re.search(r"^%s=" % k, env, re.M):
        return re.sub(r"^%s=.*$" % k, "%s=%s" % (k, v), env, flags=re.M)
    sep = "" if (not env or env.endswith("\n")) else "\n"
    return env + sep + "%s=%s\n" % (k, v)
env = setk(env, "HS_DASHBOARD_JWT", tok)
env = setk(env, "HS_MERCHANT_ID", j.get("merchant_id", ""))
env = setk(env, "HS_DASHBOARD_PROFILE_ID", j.get("profile_id", ""))
env = setk(env, "HS_DASHBOARD_EMAIL", j.get("email", ""))
open(env_file, "w").write(env)
os.chmod(env_file, 0o600)
print("OK: wrote HS_DASHBOARD_JWT (%d chars), merchant %s, profile %s to %s" % (len(tok), j.get("merchant_id"), j.get("profile_id"), env_file))
PY
