# -*- coding: utf-8 -*-
"""
二进制体检：对比「参考插件 dylib」与「自己构建的 dylib」
目的：定位支付宝 arm64e 进程闪退 + 无探针日志的根因
"""
import struct, io, os, re, tarfile, gzip, bz2, lzma

BASE = r"C:\Users\Administrator\Desktop\1\HealthBoost"
REF  = os.path.join(BASE, "_bygsrc", "ext")

MH_NAME = {1:"OBJECT",2:"EXECUTE",6:"DYLIB",8:"BUNDLE",9:"DYLIB_STUB",
           10:"DSYM",11:"KEXT_BUNDLE",0xa:"DYLIB_STUB"}
SUBNAME = {0:"arm64", 1:"arm64v8", 2:"arm64e"}

LOAD_DYLIB_CMDS = {0x0c:"LC_LOAD_DYLIB", 0x80000018:"LC_LOAD_WEAK_DYLIB",
                   0x8000001c:"LC_RPATH?", 0x8000001f:"LC_REEXPORT_DYLIB",
                   0x80000020:"LC_LAZY_LOAD_DYLIB", 0x80000023:"LC_LOAD_UPWARD_DYLIB",
                   0x1c:"LC_SUB_FRAMEWORK", 0x20:"LC_LAZY_LOAD_DYLIB"}


def parse_ar(p):
    d = open(p, "rb").read(); off = 8; m = {}
    while off < len(d):
        if d[off:off+1] == b"\n":
            off += 1; continue
        h = d[off:off+60]
        if len(h) < 60: break
        name = h[0:16].decode(errors="replace").strip().rstrip("/")
        try: sz = int(h[48:58].decode().strip() or "0")
        except Exception: break
        m[name] = d[off+60:off+60+sz]; off += 60 + sz + (sz % 2)
    return m


def detar(b):
    if b[:2] == b"\x1f\x8b": return tarfile.open(fileobj=io.BytesIO(gzip.decompress(b)))
    if b[:2] == b"BZ":       return tarfile.open(fileobj=io.BytesIO(bz2.decompress(b)))
    if b[:2] == b"\xfd7":    return tarfile.open(fileobj=io.BytesIO(lzma.decompress(b)))
    return tarfile.open(fileobj=io.BytesIO(b))


def fat_slices(d):
    m = struct.unpack(">I", d[:4])[0]; out = []
    if m == 0xcafebabe:
        n = struct.unpack(">I", d[4:8])[0]
        for i in range(n):
            ct, cs, off, sz, al = struct.unpack(">iiIII", d[8+i*20:28+i*20])
            out.append((ct & 0xffffffff, cs & 0xffffffff, d[off:off+sz]))
    elif m == 0xcafebabf:
        n = struct.unpack(">I", d[4:8])[0]
        for i in range(n):
            ct, cs = struct.unpack(">ii", d[8+i*32:16+i*32])
            off, sz = struct.unpack(">QQ", d[16+i*32:32+i*32])
            out.append((ct & 0xffffffff, cs & 0xffffffff, d[off:off+sz]))
    else:
        out.append((None, None, d))
    return out


def macho_info(sl):
    d = sl
    if struct.unpack("<I", d[:4])[0] != 0xfeedfacf: return None
    cputype = struct.unpack("<i", d[4:8])[0]
    cpusub  = struct.unpack("<i", d[8:12])[0]
    ftype   = struct.unpack("<I", d[12:16])[0]
    ncmds   = struct.unpack("<I", d[16:20])[0]
    flags   = struct.unpack("<I", d[24:28])[0]
    off = 32; libs = []; undef = set()
    for _ in range(ncmds):
        cmd, cs2 = struct.unpack("<II", d[off:off+8])
        if cmd in LOAD_DYLIB_CMDS:
            try:
                noff = struct.unpack("<I", d[off+8:off+12])[0]
                end = d.index(b"\x00", off + noff)
                nm = d[off+noff:end].decode("utf-8", "replace")
            except Exception:
                nm = "?"
            libs.append((LOAD_DYLIB_CMDS[cmd], nm, bool(cmd & 0x80000000)))
        if cmd == 0x2:  # LC_SYMTAB
            so, ns, st, ss = struct.unpack("<IIII", d[off+8:off+24])
            for i in range(ns):
                e = so + i * 16
                nstrx, ntype, nsect, ndesc, nval = struct.unpack("<IBBHQ", d[e:e+16])
                if nstrx and (ntype & 0x0e) == 0 and nval == 0:
                    end = d.index(b"\x00", st + nstrx)
                    undef.add(d[st+nstrx:end].decode("ascii", "replace"))
        off += cs2
    return dict(cputype=cputype, cpusub=cpusub, ftype=ftype, flags=flags,
                libs=libs, undef=undef)


def strings_of(d, minlen=4):
    return [s.decode("ascii") for s in re.findall(rb"[ -~]{%d,}" % minlen, d)]


JB_KEYS = ["cydia", "Cydia", "jail", "Jail", "bash", "sshd", "Substrate",
           "substrate", "MobileSubstrate", "sandbox", "Sandbox", "ptrace",
           "Shadow", "shadow", "Bypass", "bypass", "FlyJB", "A-Bypass",
           "fileExistsAtPath", "canOpenURL", "dyld", "image", "stat",
           "access", "fopen", "fork", "system", "hb_", "ssm_", "com."]


def report(tag, data, show_jb=False):
    print("=" * 78)
    print("### %s   (%d bytes)" % (tag, len(data)))
    slices = fat_slices(data)
    if len(slices) > 1 or slices[0][0] is not None:
        print("  FAT 切片数: %d" % len(slices))
    for ct, cs, sl in slices:
        info = macho_info(sl)
        if not info:
            print("   [切片] 非 64-bit Mach-O, magic=%s" % sl[:4].hex()); continue
        sub = info["cpusub"] & 0x00ffffff
        caps = (info["cpusub"] >> 24) & 0xff
        print("   [切片] cpu=0x%08x sub=0x%02x(%s) caps=0x%02x  type=%s(%d) flags=0x%x"
              % (info["cputype"] & 0xffffffff, sub, SUBNAME.get(sub, "?"), caps,
                 MH_NAME.get(info["ftype"], "?"), info["ftype"], info["flags"]))
        print("          依赖 (%d):" % len(info["libs"]))
        for c, nm, weak in info["libs"]:
            print("            %-26s %s%s" % (c, nm, "   [WEAK]" if weak else ""))
        print("          未定义符号: %d" % len(info["undef"]))
    if show_jb:
        S = strings_of(data)
        seen = set(); hits = []
        for s in S:
            if s in seen: continue
            seen.add(s)
            if any(k in s for k in JB_KEYS):
                hits.append(s)
        print("  --- 越狱检测/偏好相关字符串 (%d) ---" % len(hits))
        for s in hits[:90]:
            print("      ", s)


def dylib_from_deb(debpath, suffix=".dylib"):
    m = parse_ar(debpath)
    ct = [n for n in m if n.startswith("control.tar")]
    if ct:
        t = detar(m[ct[0]])
        for x in t.getmembers():
            if x.isfile() and os.path.basename(x.name) == "control":
                print("--- control ---")
                print(t.extractfile(x).read().decode("utf-8", "replace").strip())
    dt = [n for n in m if n.startswith("data.tar")][0]
    t = detar(m[dt])
    out = []
    for x in t.getmembers():
        if x.isfile() and x.name.endswith(suffix):
            out.append((x.name, t.extractfile(x).read()))
    print("  dylib 成员:", [n for n, _ in out])
    return out


if __name__ == "__main__":
    # 1) 参考插件 2976（ylr，rootless，firmware>=14，持续更新）
    p2976 = os.path.join(REF, "2976", "var_jb_Library_MobileSubstrate_DynamicLibraries_StepCount.dylib")
    if os.path.exists(p2976):
        report("参考插件 2976 StepCount.dylib (ylr 支付宝修改步数)", open(p2976, "rb").read(), show_jb=True)

    # 2) 参考插件 58（Netskao，老 rootful）
    p58 = os.path.join(REF, "58", "Library_MobileSubstrate_DynamicLibraries_AlipaySteps.dylib")
    if os.path.exists(p58):
        report("参考插件 58 AlipaySteps.dylib (Netskao)", open(p58, "rb").read(), show_jb=False)

    # 3) 自己的产物
    mine = os.path.join(BASE, "ci_dl", "extracted")
    cands = [f for f in sorted(os.listdir(mine)) if f.startswith("com.sykes.stepfaker") and f.endswith(".deb")]
    if cands:
        deb = os.path.join(mine, cands[-1])
        print("=" * 78)
        print("### 自己的产物: %s" % cands[-1])
        for nm, data in dylib_from_deb(deb):
            report("  我的 %s" % os.path.basename(nm), data, show_jb=False)
