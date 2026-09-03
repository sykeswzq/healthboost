# -*- coding: utf-8 -*-
import tarfile, gzip, io, os, re, sys

BASE = r"C:\Users\Administrator\Desktop\1\HealthBoost\ci_dl\extracted"

def read_ar_data_tgz(path):
    """从 .deb (ar) 中提取 data.tar.gz 的内容为 {name: bytes}"""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    off = 8
    members = {}
    while off < len(data):
        if data[off:off+1] == b"\n" or off >= len(data):
            off += 1
            continue
        header = data[off:off+60]
        if len(header) < 60:
            break
        name = header[0:16].decode().strip().strip("/")
        size = int(header[48:58].decode().strip() or "0")
        content = data[off+60:off+60+size]
        members[name] = content
        off += 60 + size
        if size % 2 == 1:
            off += 1
    # 找 data.tar.gz
    tarname = [n for n in members if n.startswith("data.tar")]
    if not tarname:
        raise SystemExit("no data.tar in " + path)
    raw = members[tarname[0]]
    out = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
        for m in tf.getmembers():
            if m.isfile():
                out[m.name] = tf.extractfile(m).read()
    return out

def show(title, files):
    print("\n===== %s =====" % title)
    for k in sorted(files):
        print("  ", k, "(%d bytes)" % len(files[k]))

# ---- App deb ----
app_deb = [f for f in os.listdir(BASE) if f.startswith("com.sykes.ucs_")][0]
app_files = read_ar_data_tgz(os.path.join(BASE, app_deb))
show("APP deb: " + app_deb, app_files)

plist = app_files.get("./Applications/UCS.app/Info.plist") or app_files.get("Applications/UCS.app/Info.plist")
if plist:
    txt = plist.decode("utf-8", "replace")
    for key in ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"]:
        m = re.search(r"<%s>(.*?)</%s>" % (key, key), txt)
        print("  %s = %s" % (key, m.group(1) if m else "(not found)"))

# ---- Tweak deb ----
tw_deb = [f for f in os.listdir(BASE) if f.startswith("com.sykes.stepfaker_")][0]
tw_files = read_ar_data_tgz(os.path.join(BASE, tw_deb))
show("TWEAK deb: " + tw_deb, tw_files)

# filter plist
flt = None
for k in tw_files:
    if k.endswith("StepFaker.plist"):
        flt = tw_files[k].decode("utf-8","replace")
if flt:
    print("  filter has com.tencent.xin:", "com.tencent.xin" in flt)
    print("  filter has com.alipay.iphoneclient:", "com.alipay.iphoneclient" in flt)

# dylib strings
dylib = None
for k in tw_files:
    if k.endswith("StepFaker.dylib"):
        dylib = tw_files[k]
if dylib:
    s = dylib.decode("latin1")
    for needle in ["APStepInfo", "numberOfSteps", "com.tencent.xin", "com.alipay.iphoneclient",
                   "HOOKED APStepInfo", "CMPedometerData", "Alipay APStepInfo called"]:
        print("  dylib contains %-26s : %s" % (needle, needle in s))
    print("  dylib magic:", dylib[:4].hex())
