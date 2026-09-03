#!/usr/bin/env python3
# 对 App-only deb 里的 HealthBoostApp（胖二进制 arm64+arm64e 双 slice）做：
#   1) 移除每个 slice 里旧的（坏的、无 entitlements 的）LC_CODE_SIGNATURE
#   2) 重建合法 adhoc 签名（SHA1 CodeDirectory）+ 嵌入 healthkit 私有权限 entitlements blob
#   3) 重新拼回胖二进制，再重新打包 deb（复用原始 ar 头）
# 目的：让 App 的 source_override / authorization_bypass 私有权限真正被系统认可，
#       从而能以"设备源"身份写入步数（覆盖而非叠加），并修掉 App 自身的无效签名。
import io, tarfile, struct, hashlib, os

PAGE = 4096
DEB = r'C:\Users\Administrator\Desktop\1\HealthBoost\v84_artifact\com.sykes.healthboost_1.0.124-2-APPONLY_iphoneos-arm64e.deb'
ENT = r'C:\Users\Administrator\Desktop\1\HealthBoost\HealthBoost.entitlements.plist'

def parse_ar(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'!<arch>\n'
    off = 8; members = []
    while off < len(data):
        hdr = data[off:off+60]
        name = hdr[:16].decode('latin1').strip()
        size = int(hdr[48:58].decode('latin1').strip() or 0)
        body = data[off+60:off+60+size]
        members.append({'name': name, 'size': size, 'body': body, 'hdr': hdr})
        off += 60 + size
        if size % 2 == 1: off += 1
    return members

def make_ar_header(name, size, orig_hdr):
    hdr = bytearray(orig_hdr)
    hdr[48:58] = f"{size:10d}".encode('latin1')
    return bytes(hdr)

# ---- 签名构件（superblob / CodeDirectory / Entitlements 永远大端 cs_blobs 规范）----
def build_cd(code, ident):
    ident_b = ident.encode('utf-8') + b'\x00'
    npages = (len(code) + PAGE - 1) // PAGE
    hashes = b''
    for pg in range(npages):
        s = pg * PAGE; e = min(s + PAGE, len(code))
        page = code[s:e]
        if len(page) < PAGE: page = page + b'\x00' * (PAGE - len(page))
        hashes += hashlib.sha1(page).digest()
    cd = bytearray()
    cd += struct.pack('>I', 0xfade0c02)
    cd += struct.pack('>I', 0)
    cd += struct.pack('>I', 0x00020000)
    cd += struct.pack('>I', 0)
    cd += struct.pack('>I', 44)
    cd += struct.pack('>I', 44 + len(hashes))
    cd += struct.pack('>I', 0)
    cd += struct.pack('>I', npages)
    cd += struct.pack('>I', len(code))
    cd += struct.pack('>B', 20)
    cd += struct.pack('>B', 1)   # SHA1
    cd += struct.pack('>B', 0)
    cd += struct.pack('>B', 12)  # 2^12 = 4096
    cd += struct.pack('>I', 0)
    cd += hashes
    cd += ident_b
    cd[4:8] = struct.pack('>I', len(cd))
    return bytes(cd)

def build_entitlements(xml):
    ent = xml.encode('utf-8')
    blob = bytearray()
    blob += struct.pack('>I', 0xfade7171)
    blob += struct.pack('>I', 0)
    blob += ent
    while len(blob) % 4 != 0: blob += b'\x00'
    blob[4:8] = struct.pack('>I', len(blob))
    return bytes(blob)

def build_superblob(items):
    sb = bytearray()
    sb += struct.pack('>I', 0xfade0cc0)
    sb += struct.pack('>I', 0)
    sb += struct.pack('>I', len(items))
    offset = 12 + len(items) * 8
    for (t, b) in items:
        sb += struct.pack('>II', t, offset)
        offset += len(b)
    for (t, b) in items:
        sb += b
    sb[4:8] = struct.pack('>I', len(sb))
    return bytes(sb)

def resign_thin(raw, ent_xml):
    magic = struct.unpack('>I', raw[0:4])[0]
    E = '>' if magic == 0xfeedfacf else '<'
    ncmds = struct.unpack(E+'I', raw[16:20])[0]
    sizeofcmds = struct.unpack(E+'I', raw[20:24])[0]
    lc_end = 32 + sizeofcmds
    sig_off = None
    lcs = []
    o = 32
    while o < lc_end:
        cmd, cmdsize = struct.unpack(E+'II', raw[o:o+8])
        if cmd == 0x1d:
            sig_off, _ = struct.unpack(E+'II', raw[o+8:o+16])
        lcs.append((o, cmd, cmdsize))
        o += cmdsize
    # 去掉旧的 sig LC，重建 LC 区（不含 sig LC）
    new_lc = bytearray()
    for (o, cmd, cmdsize) in lcs:
        if cmd == 0x1d: continue
        new_lc += raw[o:o+cmdsize]
    code_region = raw[lc_end:sig_off]
    # ---- 先算长度，消除循环依赖（sig LC 16 字节夹在 code 区与 blob 之间）----
    # dataoff = 签名 blob 在文件中的真实偏移 = header + (new_lc + 16字节sigLC) + code_region
    dataoff = 32 + len(new_lc) + 16 + len(code_region)
    npages = (dataoff + PAGE - 1) // PAGE
    cd_len = 44 + npages * 20 + len(b'com.sykes.healthboost.app\x00')  # CodeDirectory 固定开销+分页哈希+ident
    ent_len = 8 + ((len(ent_xml.encode('utf-8')) + 3) // 4) * 4        # Entitlements blob（4字节对齐）
    sb_len = 12 + 2 * 8 + cd_len + ent_len                            # superblob: 头12 + 2个index*8 + cd + ent
    # sig LC 放回【load command 区末尾】（ncmds/typeofcmds 净变化 0）
    sig_lc = struct.pack(E+'IIII', 0x1d, 16, dataoff, sb_len)
    new_lc_full = bytes(new_lc) + sig_lc
    # 待签内容 = header + 新 LC 区（含 sig LC）+ code 区，长度恰为 dataoff
    code = raw[:32] + new_lc_full + code_region
    assert len(code) == dataoff, f"code len {len(code)} != dataoff {dataoff}"
    cd = build_cd(code, 'com.sykes.healthboost.app')
    ent = build_entitlements(ent_xml)
    sb = build_superblob([(0x0, cd), (0x4, ent)])
    out = bytearray()
    out += raw[:32]
    out += new_lc_full
    out += code_region
    out += sb
    # header ncmds / sizeofcmds 不变（删 16 字节旧 sig LC，加 16 字节新 sig LC）
    out[16:20] = struct.pack(E+'I', ncmds)
    out[20:24] = struct.pack(E+'I', sizeofcmds)
    return bytes(out)

def resign_fat(fat, ent_xml):
    narch = struct.unpack('>I', fat[4:8])[0]
    archs = []
    off = 8
    for _ in range(narch):
        cputype, cpusub, so, si, al = struct.unpack('>IIIII', fat[off:off+20])
        off += 20
        archs.append((cputype, cpusub, so, si, al))
    new_slices = []
    for (cputype, cpusub, so, si, al) in archs:
        new_slices.append((cputype, cpusub, al, resign_thin(fat[so:so+si], ent_xml)))
    align_pow = 14
    header = bytearray()
    header += struct.pack('>I', 0xcafebabe)
    header += struct.pack('>I', narch)
    entries = bytearray()
    cur = 8 + narch * 20
    out = bytearray()
    for (cputype, cpusub, al, sl) in new_slices:
        pad = (2**align_pow - (cur % 2**align_pow)) % 2**align_pow
        if pad:
            out += b'\x00' * pad
            cur += pad
        entries += struct.pack('>IIIII', cputype, cpusub, cur, len(sl), al)
        out += sl
        cur += len(sl)
    return bytes(header) + bytes(entries) + bytes(out)

def resign_blob(raw, ent_xml):
    magic = struct.unpack('>I', raw[0:4])[0]
    if magic == 0xcafebabe:
        return resign_fat(raw, ent_xml)
    return resign_thin(raw, ent_xml)

# ---- 主流程 ----
ent_xml = open(ENT, 'rb').read().decode('utf-8')
members = parse_ar(DEB)
data_m = next(m for m in members if m['name'].startswith('data.tar.gz'))
control_m = next(m for m in members if m['name'].startswith('control.tar.gz'))
binary_m = next(m for m in members if m['name'].startswith('debian-binary'))

tf = tarfile.open(fileobj=io.BytesIO(data_m['body']))
new_io = io.BytesIO()
out = tarfile.open(fileobj=new_io, mode='w:gz')
app_paths = []
for m in tf.getmembers():
    if m.isfile():
        content = tf.extractfile(m).read()
        if m.name.endswith('HealthBoostApp'):
            new = resign_blob(content, ent_xml)
            app_paths.append((m.name, len(content), len(new)))
            content = new
            ti = tarfile.TarInfo(m.name)
            ti.size = len(content); ti.mode = m.mode; ti.mtime = m.mtime
            ti.uid = m.uid; ti.gid = m.gid; ti.type = m.type
            out.addfile(ti, io.BytesIO(content))
            continue
        ti = tarfile.TarInfo(m.name)
        ti.size = len(content); ti.mode = m.mode; ti.mtime = m.mtime
        ti.uid = m.uid; ti.gid = m.gid; ti.type = m.type
        out.addfile(ti, io.BytesIO(content))
    else:
        out.addfile(m)
out.close()
new_data = new_io.getvalue()

result = bytearray(b'!<arch>\n')
for m in [binary_m, control_m, data_m]:
    body = new_data if m is data_m else m['body']
    result += make_ar_header(m['name'], len(body), m['hdr']) + body
    if len(body) % 2 == 1: result += b'\n'

with open(DEB, 'wb') as f:
    f.write(result)

print("=== App 重签完成 ===")
for p, old, new in app_paths:
    print(f"  {p}: {old} -> {new} bytes")
print("deb 已覆盖写回:", DEB)
