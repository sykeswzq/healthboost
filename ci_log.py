# -*- coding: utf-8 -*-
import io, json, urllib.request, zipfile, os

TOKEN = os.environ.get("GITHUB_PAT", "")
OWNER, REPO = "sykeswzq", "healthboost"
API = "https://api.github.com/repos/%s/%s" % (OWNER, REPO)
HEAD = {"Authorization": "Bearer %s" % TOKEN, "User-Agent": "wb", "Accept": "application/vnd.github+json"}
RUN = 33599670596
OUT = r"C:\Users\Administrator\Desktop\1\HealthBoost\ci_logs"
os.makedirs(OUT, exist_ok=True)

def api(method, url):
    req = urllib.request.Request(url, headers=HEAD, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode() or "{}")

st, jobs = api("GET", "%s/actions/runs/%s/jobs" % (API, RUN))
for j in jobs.get("jobs", []):
    print("JOB:", j.get("name"), j.get("conclusion"))
    for s in j.get("steps", []):
        print("  -", s.get("name"), "|", s.get("conclusion"), "|", s.get("number"))
        if s.get("conclusion") == "failure":
            print("     ^ FAILURE")

# download logs
req = urllib.request.Request("%s/actions/runs/%s/logs" % (API, RUN), headers=HEAD)
with urllib.request.urlopen(req, timeout=120) as r:
    data = r.read()
zp = os.path.join(OUT, "logs.zip")
with open(zp, "wb") as f:
    f.write(data)
with zipfile.ZipFile(zp) as z:
    z.extractall(OUT)
for root, dirs, files in os.walk(OUT):
    for f in files:
        if f.endswith(".txt"):
            p = os.path.join(root, f)
            with io.open(p, "r", encoding="utf-8", errors="replace") as fh:
                txt = fh.read()
            print("\n==== %s (last 4000 chars) ====" % f)
            print(txt[-4000:])
