#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Inspect, verify and re-sign iOS tweak .deb dylibs (roothide/Dopamine rootless).
Handles ar archive + gzip tar + thin/fat Mach-O + adhoc code signature.
"""
import struct, zlib, hashlib, sys, os

PAGE = 4096
LC_CODE_SIGNATURE = 0x1d
MH_MAGIC_64 = 0xfeedfacf      # big-endian stored magic
MH_MAGIC_32 = 0xfeedface
FAT_MAGIC   = 0xcafebabe
LE = '<'                      # Mach-O header/load commands: CIGAM (little-endian)
BE = '>'                      # code-signature superblob/CodeDirectory: big-endian (cs_blobs.h)

# ---------- ar (deb) parsing ----------
def parse_ar(deb):
    assert deb[:8] == b'!<arch>\n', "not a deb/ar"
    off = 8
    members = []
    while off < len(deb):
        if deb[off:off+8] == b'\x00'*8:  # padding at end
            break
        hdr = deb[off:off+60]
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode('latin1').strip().rstrip('/')
        size = int(hdr[48:58].decode('latin1').strip() or '0')
        data_start = off + 60
        data = deb[data_start:data_start+size]
        members.append({'name': name, 'header': hdr, 'data': data})
        off = data_start + size
        if size % 2 == 1:   # 2-byte alignment padding
            off += 1
    return members

def repack_deb(members, out_path):
    # Reuse each member's ORIGINAL 60-byte ar header; only the data.tar.gz
    # member has its data replaced, with its size field (offset 48..57) rewritten.
    out = bytearray(b'!<arch>\n')
    for m in members:
        hdr = bytearray(m['header'])        # original 60-byte header
        data = m['data']
        if m['name'].endswith('.tar.gz'):
            # rewrite the 10-byte decimal size field at header offset 48
            hdr[48:58] = f"{len(data):10d}".encode('latin1')
        out += hdr + data
        if len(data) % 2 == 1:
            out += b'\n'
    with open(out_path, 'wb') as f:
        f.write(out)
    return len(out)

# ---------- tar.gz ----------
def extract_tar(tar_bytes):
    import gzip, io, tarfile
    tf = tarfile.open(fileobj=io.BytesIO(tar_bytes))
    items = []
    for m in tf.getmembers():
        if m.isfile():
            items.append((m.name, tf.extractfile(m).read()))
        else:
            items.append((m.name, None))
    return items

def pack_tar(items):
    import gzip, io, tarfile
    buf = io.BytesIO()
    tf = tarfile.open(fileobj=buf, mode='w:gz')
    for name, data in items:
        if data is None:
            info = tarfile.TarInfo(name=name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tf.addfile(info)
        else:
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.mode = 0o644
            tf.addfile(info, io.BytesIO(data))
    tf.close()
    return buf.getvalue()

# ---------- Mach-O ----------
def find_lc_sig(macho):
    """Return (offset_of_signature_blob, size) or (None,None) for a thin 64-bit macho."""
    magic = struct.unpack(LE+'I', macho[0:4])[0]
    assert magic == MH_MAGIC_64, f"unexpected thin magic {hex(magic)}"
    ncmds = struct.unpack(LE+'I', macho[16:20])[0]
    off = 32  # sizeof mach_header_64
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack(LE+'II', macho[off:off+8])
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack(LE+'II', macho[off+8:off+16])
            return dataoff, datasize
        off += cmdsize
    return None, None

def verify_macho(macho):
    """Verify a thin 64-bit dylib's adhoc signature. Returns dict."""
    try:
        dataoff, datasize = find_lc_sig(macho)
        if dataoff is None:
            return {'has_sig': False, 'valid': False, 'reason': 'no LC_CODE_SIGNATURE'}
        blob = macho[dataoff:dataoff+datasize]
        # superblob magic 0xfade0cc0
        smagic, slen, scount = struct.unpack(BE+'III', blob[0:12])
        if smagic != 0xfade0cc0:
            return {'has_sig': True, 'valid': False, 'reason': f'not superblob {hex(smagic)}'}
        # find CodeDirectory blob (type 0)
        cd = None
        for i in range(scount):
            boff = 12 + i*8
            btype, bofs = struct.unpack(BE+'II', blob[boff:boff+8])
            if btype == 0x0:  # CD
                bmagic, blen = struct.unpack(BE+'II', blob[bofs:bofs+8])
                cd = blob[bofs:bofs+blen]
                break
        if cd is None:
            return {'has_sig': True, 'valid': False, 'reason': 'no CodeDirectory'}
        cdmagic, cdlen, version, flags, hashOffset, identOffset, nSpecial, nCode, codeLimit = struct.unpack(BE+'IIIIIIIII', cd[0:36])
        hashSize = cd[36]; hashType = cd[37]; pageSize = cd[39]
        if hashSize == 0 or hashType == 0:
            return {'has_sig': True, 'valid': False, 'reason': f'EMPTY CD hashSize={hashSize} hashType={hashType}',
                    'hashSize': hashSize, 'hashType': hashType, 'codeLimit': codeLimit, 'npages': nCode}
        # verify page hashes
        hashes = cd[hashOffset:]  # after identifier
        npages = (codeLimit + PAGE - 1) // PAGE
        if len(hashes) < npages * hashSize:
            return {'has_sig': True, 'valid': False, 'reason': f'hash array too short {len(hashes)} < {npages*hashSize}'}
        for pg in range(npages):
            start = pg*PAGE
            end = min(start+PAGE, codeLimit)
            page = macho[start:end]
            if len(page) < PAGE:
                page = page + b'\x00'*(PAGE-len(page))
            h = hashlib.sha1(page).digest()
            if h != hashes[pg*hashSize:(pg+1)*hashSize]:
                return {'has_sig': True, 'valid': False, 'reason': f'page {pg} hash mismatch'}
        return {'has_sig': True, 'valid': True, 'hashType': hashType, 'hashSize': hashSize,
                'codeLimit': codeLimit, 'npages': npages}
    except Exception as e:
        return {'has_sig': False, 'valid': False, 'reason': f'exception {e}'}

def build_cd(code, identifier):
    ident = identifier.encode('utf-8') + b'\x00'
    npages = (len(code) + PAGE - 1) // PAGE
    # hashes
    hashes = b''
    for pg in range(npages):
        start = pg*PAGE; end = min(start+PAGE, len(code))
        page = code[start:end]
        if len(page) < PAGE:
            page = page + b'\x00'*(PAGE-len(page))
        hashes += hashlib.sha1(page).digest()
    # CodeDirectory header (44 bytes)
    cd = bytearray()
    cd += struct.pack(BE+'I', 0xfade0c02)      # magic
    cd += struct.pack(BE+'I', 0)               # length (fill later)
    cd += struct.pack(BE+'I', 0x00020000)      # version
    cd += struct.pack(BE+'I', 0)               # flags
    cd += struct.pack(BE+'I', 44)              # hashOffset (after 44-byte header)
    cd += struct.pack(BE+'I', 44 + len(hashes))# identOffset (after header+hashes)
    cd += struct.pack(BE+'I', 0)               # nSpecialSlots
    cd += struct.pack(BE+'I', npages)          # nCodeSlots
    cd += struct.pack(BE+'I', len(code))       # codeLimit
    cd += struct.pack('>B', 20)              # hashSize (sha1)
    cd += struct.pack('>B', 1)               # hashType (sha1)
    cd += struct.pack('>B', 0)               # spare1
    cd += struct.pack('>B', 12)              # pageSize (2^12=4096)
    cd += struct.pack(BE+'I', 0)               # spare2
    cd += hashes
    cd += ident
    # fix length
    cd[4:8] = struct.pack(BE+'I', len(cd))
    # superblob
    sb = bytearray()
    sb += struct.pack(BE+'I', 0xfade0cc0)      # magic
    sb += struct.pack(BE+'I', 0)               # length
    sb += struct.pack(BE+'I', 1)               # count
    sb += struct.pack(BE+'II', 0x0, 20)        # blob_index: type 0 (CD), offset 20 (after 12-byte sb hdr + 8-byte index)
    sb += cd
    sb[4:8] = struct.pack(BE+'I', len(sb))
    return bytes(sb)

def resign_macho(macho, identifier):
    """Replace the dylib's code-signature blob and its LC in place, keeping all
    segment file offsets valid. Returns resigned bytes."""
    magic = struct.unpack(LE+'I', macho[0:4])[0]
    if magic != MH_MAGIC_64:
        raise ValueError(f"unsupported magic {hex(magic)} (fat not handled here)")
    ncmds = struct.unpack(LE+'I', macho[16:20])[0]
    sizeofcmds = struct.unpack(LE+'I', macho[20:24])[0]
    lc_region = macho[32:32+sizeofcmds]
    # locate existing LC_CODE_SIGNATURE
    sig_lc_off = None
    dataoff = None
    o = 0
    while o < sizeofcmds:
        cmd, cmdsize = struct.unpack(LE+'II', lc_region[o:o+8])
        if cmd == LC_CODE_SIGNATURE:
            sig_lc_off = o
            dataoff, datasize = struct.unpack(LE+'II', lc_region[o+8:o+16])
            break
        o += cmdsize
    if sig_lc_off is None:
        # no existing sig: sign whole file, append LC after existing LCs
        code = macho
        newlc = bytearray(lc_region)
        sig = build_cd(code, identifier)
        lc = struct.pack(LE+'IIII', LC_CODE_SIGNATURE, 16, len(code), len(sig))
        out = bytearray(macho[:32]) + newlc + lc + macho[32+sizeofcmds:] + sig
        out[16:20] = struct.pack(LE+'I', ncmds+1)
        out[20:24] = struct.pack(LE+'I', sizeofcmds+16)
        return bytes(out)
    # strip the old sig LC out of the load-command region
    newlc = bytearray(lc_region[:sig_lc_off] + lc_region[sig_lc_off+16:])
    code_region = macho[32+sizeofcmds : dataoff]   # original code/segment region, offsets preserved
    # pre-signature bytes (without the sig blob), with the sig LC location reserved
    pre = macho[:32] + newlc + code_region
    sig_lc_off2 = 32 + len(newlc)                  # where the new sig LC will sit
    dataoff_final = len(pre) + 16                  # pre length + 16-byte sig LC
    # first pass: learn the sig blob length (independent of the datasize field)
    placeholder_lc = struct.pack(LE+'IIII', LC_CODE_SIGNATURE, 16, dataoff_final, 0)
    code0 = pre[:sig_lc_off2] + placeholder_lc + pre[sig_lc_off2:]
    sig_len = len(build_cd(code0, identifier))
    # second pass: hash the REAL pre-signature bytes (with correct datasize)
    real_lc = struct.pack(LE+'IIII', LC_CODE_SIGNATURE, 16, dataoff_final, sig_len)
    code = pre[:sig_lc_off2] + real_lc + pre[sig_lc_off2:]
    sig = build_cd(code, identifier)
    # assemble: header + newlc + new sig LC + code_region + sig blob
    out = bytearray()
    out += macho[:32]
    out += newlc
    out += real_lc
    out += code_region
    out += sig
    # header ncmds/sizeofcmds unchanged (removed 1 LC, added 1 LC, same 16-byte size)
    return bytes(out)

# ---------- high level ----------
def inspect_deb(path):
    print(f"\n===== {os.path.basename(path)} =====")
    deb = open(path, 'rb').read()
    members = parse_ar(deb)
    print("ar members:", [m['name'] for m in members])
    for m in members:
        if m['name'].endswith('.tar.gz'):
            items = extract_tar(m['data'])
            for name, data in items:
                if name.endswith('.dylib') or name.endswith('.plist'):
                    if data is None:
                        print(f"  [dir] {name}")
                        continue
                    if name.endswith('.dylib'):
                        try:
                            info = verify_macho(data)
                            print(f"  {name}: has_sig={info['has_sig']} valid={info['valid']} {info.get('reason','')} "
                                  f"hashType={info.get('hashType')} codeLimit={info.get('codeLimit')} npages={info.get('npages')}")
                        except Exception as e:
                            print(f"  {name}: parse error {e}")
                    else:
                        print(f"  {name}: {len(data)} bytes")
        elif m['name'] in ('control', 'preinst', 'postinst', 'prerm', 'postrm'):
            print(f"  [{m['name']}] {m['data'][:400].decode('latin1')}")

def resign_deb(in_path, out_path):
    deb = open(in_path, 'rb').read()
    members = parse_ar(deb)
    new_members = []
    signed = 0
    for m in members:
        if m['name'].endswith('.tar.gz'):
            items = extract_tar(m['data'])
            new_items = []
            for name, data in items:
                if name.endswith('.dylib') and data is not None:
                    ident = 'com.sykes.' + os.path.basename(name).split('.')[0].lower()
                    new_data = resign_macho(data, ident)
                    v = verify_macho(new_data)
                    status = 'OK' if v['valid'] else 'FAIL'
                    print(f"  resigned {name}: {status} hashType={v.get('hashType')} codeLimit={v.get('codeLimit')} npages={v.get('npages')}")
                    new_items.append((name, new_data))
                    signed += 1
                else:
                    new_items.append((name, data))
            new_data_tar = pack_tar(new_items)
            new_members.append({'name': m['name'], 'header': m['header'], 'data': new_data_tar})
        else:
            new_members.append(m)
    size = repack_deb(new_members, out_path)
    print(f"  wrote {out_path} ({size} bytes), signed dylibs={signed}")
    return size

if __name__ == '__main__':
    base = r'C:\Users\Administrator\Desktop\1\HealthBoost\v84_artifact'
    hb_v84   = os.path.join(base, 'com.sykes.healthboost_1.0.124-1_iphoneos-arm64e.deb')
    scout_v84= os.path.join(base, 'com.sykes.scout_1.0.124-1_iphoneos-arm64e.deb')
    hb_out   = os.path.join(base, 'com.sykes.healthboost_1.0.124-1-SIGNED_iphoneos-arm64e.deb')
    scout_out= os.path.join(base, 'com.sykes.scout_1.0.124-1-SIGNED_iphoneos-arm64e.deb')

    print("########## INSPECT ORIGINALS ##########")
    inspect_deb(hb_v84)
    inspect_deb(scout_v84)

    print("\n########## RESIGN BOTH ##########")
    resign_deb(hb_v84, hb_out)
    resign_deb(scout_v84, scout_out)

    print("\n########## RE-VERIFY SIGNED DEBS ##########")
    inspect_deb(hb_out)
    inspect_deb(scout_out)
    print("\nDONE.")

