#!/usr/bin/env python3
# 从 v84 deb 生成一个【只含 App、不含任何 dylib】的干净包。
# - 删除 HealthBoost.dylib / Scout.dylib 及其 plist（双路径都要删）
# - 纯 roothide 越狱：App 直接放进 ./Applications/HealthBoost.app
#   （roothide 上 /var/roothide 就是根，dpkg 不认 ./var/roothide/Applications，会报 No such file）
# - 复用原始 deb 的 60 字节 ar 头，仅替换 data.tar.gz 内容/长度，dpkg 可正常解包
# - 把版本号从 1.0.124-1 改成 1.0.124-2，方便 Sileo 直接"升级"覆盖旧包
import io, os, tarfile, re, struct

SRC = r'C:\Users\Administrator\Desktop\1\HealthBoost\v84_artifact\com.sykes.healthboost_1.0.124-1_iphoneos-arm64e.deb'
OUT = r'C:\Users\Administrator\Desktop\1\HealthBoost\v84_artifact\com.sykes.healthboost_1.0.124-2-APPONLY_iphoneos-arm64e.deb'

DROP = {'HealthBoost.dylib', 'HealthBoost.plist', 'Scout.dylib', 'Scout.plist'}

def parse_ar(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'!<arch>\n', 'not a deb/ar'
    off = 8
    members = []
    while off < len(data):
        hdr = data[off:off+60]
        name = hdr[:16].decode('latin1').strip()
        size = int(hdr[48:58].decode('latin1').strip() or 0)
        body = data[off+60:off+60+size]
        members.append({'name': name, 'size': size, 'body': body, 'hdr': hdr})
        off += 60 + size
        if size % 2 == 1:
            off += 1
    return members

def make_ar_header(name, size, orig_hdr):
    hdr = bytearray(orig_hdr)
    hdr[48:58] = f"{size:10d}".encode('latin1')
    return bytes(hdr)

members = parse_ar(SRC)
data_m = next(m for m in members if m['name'].startswith('data.tar.gz'))
control_m = next(m for m in members if m['name'].startswith('control.tar.gz'))
binary_m = next(m for m in members if m['name'].startswith('debian-binary'))

# ---- 处理 control.tar.gz：版本号 1.0.124-1 -> 1.0.124-2 ----
ctl_io = io.BytesIO(control_m['body'])
ctl = tarfile.open(fileobj=ctl_io)
ctl_new = io.BytesIO()
ctl_out = tarfile.open(fileobj=ctl_new, mode='w:gz')
app_src = []   # (orig_name, content, TarInfo)
for m in ctl.getmembers():
    if m.isfile():
        content = ctl.extractfile(m).read()
        if os.path.basename(m.name) == 'control':
            content = re.sub(rb'Version:\s*[\d.+-]+', b'Version: 1.0.124-2', content)
        ti = tarfile.TarInfo(m.name)
        ti.size = len(content); ti.mode = m.mode; ti.mtime = m.mtime
        ti.uid = m.uid; ti.gid = m.gid; ti.type = m.type
        ctl_out.addfile(ti, io.BytesIO(content))
    else:
        ctl_out.addfile(m)
ctl_out.close()
new_control_body = ctl_new.getvalue()

# ---- 处理 data.tar.gz：删 dylib，把 App 移到 ./Applications/HealthBoost.app ----
tf = tarfile.open(fileobj=io.BytesIO(data_m['body']))
new_io = io.BytesIO()
out = tarfile.open(fileobj=new_io, mode='w:gz')

# 先写 roothide 根下 Applications 父目录
for d in ['./Applications', './Applications/HealthBoost.app']:
    di = tarfile.TarInfo(d)
    di.type = tarfile.DIRTYPE
    di.mode = 0o755
    out.addfile(di)

# 兜底：不输出 ./var（原 deb 带进，roothide 上无用）
var_skip = {'./var', './var/jb', './var/roothide'}

removed = []
for m in tf.getmembers():
    base = os.path.basename(m.name)
    # 删除所有 /var 下内容（原 deb 双路径给 rootless/roothide，纯 roothide 上 /var/jb /var/roothide 路径 dpkg 会报 No such file）
    if m.name == './var' or m.name.startswith('./var/'):
        # 但把原 App 文件内容保留下来，稍后重命名到 ./Applications
        if m.name.startswith('./var/jb/Applications/HealthBoost.app/') and m.isfile():
            content = tf.extractfile(m).read()
            app_src.append((m.name, content, m))
        continue
    # 删除所有 dylib / plist（双路径，兜底）
    if 'MobileSubstrate/DynamicLibraries' in m.name and base in DROP:
        removed.append(m.name)
        continue
    # 其余目录/文件原样保留
    if m.isfile():
        content = tf.extractfile(m).read()
        ti = tarfile.TarInfo(m.name)
        ti.size = len(content); ti.mode = m.mode; ti.mtime = m.mtime
        ti.uid = m.uid; ti.gid = m.gid; ti.type = m.type
        out.addfile(ti, io.BytesIO(content))
    else:
        out.addfile(m)

# 把 App 复制到 ./Applications/HealthBoost.app
for name, content, m in app_src:
    # ./var/jb/Applications/HealthBoost.app/xxx -> ./Applications/HealthBoost.app/xxx
    prefix = './var/jb/Applications/HealthBoost.app'
    newname = name[len(prefix):]   # 保留 '/xxx' 或 ''
    if not newname or newname == '/':
        newname = './Applications/HealthBoost.app'
    else:
        newname = './Applications/HealthBoost.app' + newname
    ti = tarfile.TarInfo(newname)
    ti.size = len(content); ti.mode = m.mode; ti.mtime = m.mtime
    ti.uid = m.uid; ti.gid = m.gid; ti.type = m.type
    out.addfile(ti, io.BytesIO(content))

out.close()
new_data = new_io.getvalue()

# ---- 重新拼装 deb（复用原始 60 字节 ar 头，只换 data.tar.gz 与 control.tar.gz）----
result = bytearray(b'!<arch>\n')
for m in [binary_m, None, control_m, None, data_m, None]:
    if m is None:
        continue
    if m is control_m:
        body = new_control_body
    elif m is data_m:
        body = new_data
    else:
        body = m['body']
    result += make_ar_header(m['name'], len(body), m['hdr']) + body
    if len(body) % 2 == 1:
        result += b'\n'

with open(OUT, 'wb') as f:
    f.write(result)

print("=== 已生成 App-only deb ===")
print("输出:", OUT, len(result), "bytes")
print("删除的 dylib/plist:")
for r in removed:
    print("   ", r)
print("复制 App 到 roothide 的文件数:", len(app_src))
