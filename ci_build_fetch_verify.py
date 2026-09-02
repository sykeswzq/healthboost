# -*- coding: utf-8 -*-
# 轮询最新 commit 的 CI 运行 -> curl 下载产物 -> 校验 dylib 含 HOOKED APStepInfo 日志 + App 为 UCS
import io, json, os, sys, time, tarfile, subprocess, re, urllib.request
TOKEN=os.environ.get("GITHUB_PAT", "")
OWNER,REPO="sykeswzq","healthboost"
API="https://api.github.com/repos/%s/%s"% (OWNER,REPO)
HEAD={"Authorization":"Bearer %s"%TOKEN,"User-Agent":"wb","Accept":"application/vnd.github+json"}
SHA=sys.argv[1] if len(sys.argv)>1 else "18f02f0e795e0b72c64669d0eced26dbc2954284"
OUT=os.path.join(os.getcwd(),"ci_dl")
os.makedirs(OUT,exist_ok=True)

def api(method,u):
    req=urllib.request.Request(u,headers=HEAD,method=method) if method!="GET" else urllib.request.Request(u,headers=HEAD)
    with urllib.request.urlopen(req,timeout=60) as r:
        return json.loads(r.read().decode() or "{}")

# 找 run
for i in range(40):
    runs=api("GET","%s/actions/runs?head_sha=%s"%(API,SHA)).get("workflow_runs",[])
    if runs:
        run=runs[0]; print("run",run["id"],run["status"],run.get("conclusion"))
        if run["status"]=="completed": break
    time.sleep(15)
else:
    raise SystemExit("run 未结束")
if run.get("conclusion")!="success":
    raise SystemExit("构建失败: "+str(run.get("conclusion")))

# 取 artifact id
arts=api("GET","%s/actions/runs/%s/artifacts"%(API,run["id"])).get("artifacts",[])
if not arts: raise SystemExit("无 artifact")
aid=arts[0]["id"]
print("artifact",aid)
zip_path=os.path.join(OUT,"artifact.zip")
# 用 curl 下载（绕过 urllib 重定向 401）
r=subprocess.run(["curl","-sL","-H","Authorization: Bearer %s"%TOKEN,"-o",zip_path,
                  "%s/actions/artifacts/%s/zip"%(API,aid)],check=True)
ext=os.path.join(OUT,"extracted")
subprocess.run(["rm","-rf",ext]); os.makedirs(ext)
subprocess.run(["unzip","-o",zip_path,"-d",ext],check=True,capture_output=True)
debs=[f for f in os.listdir(ext) if f.endswith(".deb")]
print("debs:",debs)

def deb_files(path):
    data=open(path,"rb").read(); off=8; m={}
    while off<len(data):
        if data[off:off+1]==b"\n": off+=1; continue
        h=data[off:off+60]; sz=int(h[48:58].decode().strip() or "0")
        m[h[0:16].decode().strip().strip("/")]=data[off+60:off+60+sz]; off+=60+sz+(sz%2)
    tn=[n for n in m if n.startswith("data.tar")][0]
    tf=tarfile.open(fileobj=io.BytesIO(m[tn]),mode="r:gz"); out={}
    for mem in tf.getmembers():
        if mem.isfile(): out[mem.name]=tf.extractfile(mem).read()
    return out

ok=True
for d in debs:
    files=deb_files(os.path.join(ext,d))
    print("\n--",d)
    for k in sorted(files): print("   ",k,len(files[k]))
    if d.startswith("com.sykes.ucs_"):
        pl=files.get("./Applications/UCS.app/Info.plist",b"")
        for key in ["CFBundleIdentifier","CFBundleDisplayName"]:
            mm=re.search(r"<key>%s</key>\s*<string>(.*?)</string>"%key,pl.decode("utf-8","replace"))
            print("   %s=%s"%(key,mm.group(1) if mm else "MISSING"))
    if d.startswith("com.sykes.stepfaker_"):
        dy=files.get("./Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib",b"")
        for s in [b"ALIPAY_HOOK_INSTALLED", b"ALIPAY_SETTER_HOOKED", b"MSHookMessageEx", b"APStepInfo", b"numberOfSteps", b"setNumberOfSteps:", b"CMPedometerData",
                  b"P0_ENTER dylib constructor entered", b"P1_SAFEMODE=", b"P2_PROG=", b"P3_SUBSTRATE=",
                  b"P4_ALIPAY minimal footprint", b"P9_DONE_ALIPAY", b"/var/mobile/hb_nohook", b"hb_probe_raw.log"]:
            has=s in dy; print("   dylib has %-24s %s"%(s.decode(),has)); ok=ok and has
        print("   dylib magic",dy[:4].hex())
        # 过滤串在 plist 里、不在二进制里 —— 之前的 VERIFY_FAIL 就是查错了文件
        pt=files.get("./Library/MobileSubstrate/DynamicLibraries/StepFaker.plist",b"").decode("utf-8","replace")
        for s in ["AlipayWallet","com.alipay.iphoneclient","com.tencent.xin","WeChat"]:
            has=s in pt; print("   plist has %-24s %s"%(s,has)); ok=ok and has
        wrong = re.search(r"<string>Alipay</string>",pt) is not None
        print("   plist 旧错误值 'Alipay'(不含Wallet) %s"%wrong); ok=ok and (not wrong)
print("\nVERIFY_OK" if ok else "\nVERIFY_FAIL")
