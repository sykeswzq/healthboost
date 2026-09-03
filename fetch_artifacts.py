# -*- coding: utf-8 -*-
import io, json, time, urllib.request, urllib.error, zipfile, os

TOKEN = os.environ.get("GITHUB_PAT", "")
OWNER, REPO = "sykeswzq", "healthboost"
API = "https://api.github.com/repos/%s/%s" % (OWNER, REPO)
HEAD = {"Authorization": "Bearer %s" % TOKEN, "User-Agent": "wb", "Accept": "application/vnd.github+json"}

HEAD_SHA = "6e0824cbdecf1f5bc8aca16ecbe096412cc5c1a0"
OUT = r"C:\Users\Administrator\Desktop\1\HealthBoost\ci_dl"
os.makedirs(OUT, exist_ok=True)

def api(method, url):
    req = urllib.request.Request(url, headers=HEAD, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, json.loads(r.read().decode() or "{}")

# find run
st, runs = api("GET", "%s/actions/runs?head_sha=%s" % (API, HEAD_SHA))
run = runs.get("workflow_runs", [{}])[0]
run_id = run.get("id")
print("run_id", run_id, "status", run.get("status"), "conclusion", run.get("conclusion"))
if not run_id:
    raise SystemExit("no run found")

# poll
for i in range(60):
    st, info = api("GET", "%s/actions/runs/%s" % (API, run_id))
    print("poll %d: %s / %s" % (i, info.get("status"), info.get("conclusion")))
    if info.get("status") == "completed":
        break
    time.sleep(15)

if info.get("conclusion") != "success":
    # dump logs link
    print("RUN FAILED. html_url:", info.get("html_url"))
    st, art = api("GET", "%s/actions/runs/%s/artifacts" % (API, run_id))
    print("artifacts:", json.dumps(art)[:500])
    raise SystemExit("build not successful: " + str(info.get("conclusion")))

# download artifact
st, art = api("GET", "%s/actions/runs/%s/artifacts" % (API, run_id))
arts = art.get("artifacts", [])
if not arts:
    raise SystemExit("no artifacts")
aid = arts[0]["id"]
print("downloading artifact", aid)
req = urllib.request.Request("%s/actions/artifacts/%s/zip" % (API, aid), headers=HEAD)
with urllib.request.urlopen(req, timeout=120) as r:
    data = r.read()
zip_path = os.path.join(OUT, "artifact.zip")
with open(zip_path, "wb") as f:
    f.write(data)
print("saved", zip_path, len(data), "bytes")

# extract
with zipfile.ZipFile(zip_path) as z:
    z.extractall(os.path.join(OUT, "extracted"))
print("extracted to", os.path.join(OUT, "extracted"))
for root, dirs, files in os.walk(os.path.join(OUT, "extracted")):
    for f in files:
        print("  ", os.path.join(root, f))
print("DONE")
