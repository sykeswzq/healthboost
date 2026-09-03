# -*- coding: utf-8 -*-
# 用法: python ci_log_dl.py <run_id> [step_substring]
import io, json, sys, urllib.request, zipfile, os
TOKEN=os.environ.get("GITHUB_PAT", "")
API="https://api.github.com/repos/sykeswzq/healthboost"
HEAD={"Authorization":"Bearer %s"%TOKEN,"User-Agent":"wb","Accept":"application/vnd.github+json"}
RUN=int(sys.argv[1])
sub = sys.argv[2] if len(sys.argv)>2 else None
req=urllib.request.Request("%s/actions/runs/%s/logs"%(API,RUN),headers=HEAD)
data=urllib.request.urlopen(req,timeout=120).read()
out=os.path.join(os.getcwd(),"ci_logs","run%d"%RUN)
os.makedirs(out,exist_ok=True)
with zipfile.ZipFile(io.BytesIO(data)) as z:
    z.extractall(out)
    for n in z.namelist():
        if sub and sub not in n: continue
        print("==== %s ====" % n)
        print(open(os.path.join(out,n),encoding="utf-8",errors="replace").read())
