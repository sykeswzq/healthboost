# -*- coding: utf-8 -*-
import io, json, base64, os, urllib.request, urllib.error

TOKEN = os.environ.get("GITHUB_PAT", "")
OWNER = "sykeswzq"
REPO = "healthboost"
BRANCH = "main"
API = "https://api.github.com/repos/%s/%s" % (OWNER, REPO)
HEADERS = {
    "Authorization": "Bearer %s" % TOKEN,
    "User-Agent": "workbuddy-deploy",
    "Accept": "application/vnd.github+json",
    "Content-Type": "application/json",
}

# repo-relative path -> local path
FILES = {
    "tweak/StepFaker.m": r"C:\Users\Administrator\Desktop\1\HealthBoost\tweak\StepFaker.m",
    "tweak/StepFaker.plist": r"C:\Users\Administrator\Desktop\1\HealthBoost\tweak\StepFaker.plist",
    "HealthBoostApp/HealthBoostApp.m": r"C:\Users\Administrator\Desktop\1\HealthBoost\HealthBoostApp\HealthBoostApp.m",
    "HealthBoostApp/AppDelegate.m": r"C:\Users\Administrator\Desktop\1\HealthBoost\HealthBoostApp\AppDelegate.m",
    "HealthBoostApp/HealthBoost/Info.plist": r"C:\Users\Administrator\Desktop\1\HealthBoost\HealthBoostApp\HealthBoost\Info.plist",
    "build.sh": r"C:\Users\Administrator\Desktop\1\HealthBoost\build.sh",
    "debian/control": r"C:\Users\Administrator\Desktop\1\HealthBoost\debian\control",
    ".github/workflows/build.yml": r"C:\Users\Administrator\Desktop\1\HealthBoost\.github\workflows\build.yml",
}

def api(method, url, data=None):
    req = urllib.request.Request(url, data=(json.dumps(data).encode() if data is not None else None), headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise RuntimeError("HTTP %s on %s: %s" % (e.code, url, body[:500]))

# 1) get current commit + tree
st, ref = api("GET", "%s/git/refs/heads/%s" % (API, BRANCH))
base_commit_sha = ref["object"]["sha"]
st, commit = api("GET", "%s/git/commits/%s" % (API, base_commit_sha))
base_tree_sha = commit["tree"]["sha"]
print("base commit", base_commit_sha, "tree", base_tree_sha)

# 2) create blobs
entries = []
for repopath, localpath in FILES.items():
    with io.open(localpath, "rb") as f:
        raw = f.read()
    b64 = base64.b64encode(raw).decode("ascii")
    st, blob = api("POST", "%s/git/blobs" % API, {"content": b64, "encoding": "base64"})
    entries.append({"path": repopath, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print("blob", repopath, blob["sha"][:10])

# 3) create tree
st, tree = api("POST", "%s/git/trees" % API, {"base_tree": base_tree_sha, "tree": entries})
new_tree_sha = tree["sha"]
print("new tree", new_tree_sha)

# 4) create commit
msg = "v1.0.169 fix: Alipay injection failure - remove Executables filter (only Bundle ID), add P0.5 diag to log all running Alipay/WeChat exe names; fixes '支付宝卡死不注入' root cause"
st, newcommit = api("POST", "%s/git/commits" % API, {
    "message": msg,
    "tree": new_tree_sha,
    "parents": [base_commit_sha],
})
new_commit_sha = newcommit["sha"]
print("new commit", new_commit_sha)

# 5) update ref
st, _ = api("PATCH", "%s/git/refs/heads/%s" % (API, BRANCH), {"sha": new_commit_sha, "force": False})
print("ref updated ->", new_commit_sha)
print("DONE")
