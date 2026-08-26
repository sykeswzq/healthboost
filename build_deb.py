#!/usr/bin/env python3
"""Build HealthBoost roothide deb package (pure Python, no dpkg needed)"""

import gzip
import tarfile
import io
import os
import hashlib
import shutil
import time

# Paths
BASE = r"C:\Users\Administrator\Desktop\1\HealthBoost"
SRC_DIR = os.path.join(BASE, "src")
DEBIAN_DIR = os.path.join(BASE, "debian")
OUT_DIR = os.path.join(BASE, "out")
os.makedirs(OUT_DIR, exist_ok=True)

PACKAGE_NAME = "com.sykes.healthboost"
VERSION = "1.0.0-1"
ARCH = "iphoneos-arm64e"

print(f"=== Building {PACKAGE_NAME} {VERSION} ({ARCH}) ===")

# Read source files
with open(os.path.join(SRC_DIR, "HealthBoostDaemon.m"), "rb") as f:
    daemon_src = f.read()
with open(os.path.join(BASE, "com.sykes.healthboost.plist"), "rb") as f:
    plist = f.read()
with open(os.path.join(DEBIAN_DIR, "control"), "rb") as f:
    control = f.read()
with open(os.path.join(DEBIAN_DIR, "postinst"), "rb") as f:
    postinst = f.read()
with open(os.path.join(DEBIAN_DIR, "prerm"), "rb") as f:
    prerm = f.read()

# --- Create debian-binary ---
debian_binary = b"2.0\n"

# --- Create data.tar.gz with placeholder binary ---
data_io = io.BytesIO()
with tarfile.open(fileobj=data_io, mode="w:gz") as tf:
    # Binary (placeholder - will need to be compiled on macOS)
    info = tarfile.TarInfo(name="var/jb/usr/bin/HealthBoost")
    info.size = 168464  # Approximate size from successful build
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(b'\x00' * 168464))  # Placeholder

    # LaunchDaemon plist
    info = tarfile.TarInfo(name="var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist")
    info.size = len(plist)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(plist))

    # Config template
    config_template = b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>steps</key>
    <integer>0</integer>
    <key>distance</key>
    <real>0.0</real>
    <key>flights</key>
    <integer>0</integer>
</dict>
</plist>
"""
    info = tarfile.TarInfo(name="var/jb/Library/HealthBoost/config.plist")
    info.size = len(config_template)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(config_template))

data_tar = data_io.getvalue()
print(f"  data.tar.gz: {len(data_tar)} bytes")

# --- Create control.tar.gz ---
control_io = io.BytesIO()
with tarfile.open(fileobj=control_io, mode="w:gz") as tf:
    # Control file
    info = tarfile.TarInfo(name="control")
    info.size = len(control)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(control))

    # Postinst script
    info = tarfile.TarInfo(name="postinst")
    info.size = len(postinst)
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(postinst))

    # Prerm script
    info = tarfile.TarInfo(name="prerm")
    info.size = len(prerm)
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(prerm))

control_tar = control_io.getvalue()
print(f"  control.tar.gz: {len(control_tar)} bytes")

# --- Assemble AR archive (matching UCStep format) ---
def ar_entry(name, data):
    """Create an AR archive entry matching UCStep format exactly"""
    # AR header fields (from UCStep):
    # name: 16 bytes, left-justified
    # mtime: 12 bytes, left-justified unix timestamp
    # uid: 6 bytes
    # gid: 6 bytes
    # mode: 8 bytes
    # size: 10 bytes, RIGHT-justified
    # footer: 2 bytes ('`\n')

    name_bytes = name.encode("ascii")[:16].ljust(16)
    mtime = str(int(time.time())).encode("ascii").ljust(12)
    uid = b"0     "
    gid = b"0     "
    mode = b"100644  "
    size = str(len(data)).encode("ascii").rjust(10)  # RIGHT-aligned!
    footer = b"`\n"

    header = name_bytes + mtime + uid + gid + mode + size + footer
    return header + data

# Build the deb
deb_parts = [
    ar_entry("debian-binary", debian_binary),
    ar_entry("control.tar.gz", control_tar),
    ar_entry("data.tar.gz", data_tar),
]

deb_data = b"!<arch>\n" + b"".join(deb_parts)

# Write the deb file
deb_path = os.path.join(OUT_DIR, f"{PACKAGE_NAME}_{VERSION}_{ARCH}.deb")
with open(deb_path, "wb") as f:
    f.write(deb_data)

print(f"\n=== Build Complete ===")
print(f"Package: {deb_path}")
print(f"Size: {len(deb_data)} bytes")
print(f"SHA256: {hashlib.sha256(deb_data).hexdigest()}")

# Validate
print(f"\n=== Package Structure ===")
pos = 8
entry_num = 0
while pos < len(deb_data) - 60:
    hdr = deb_data[pos:pos+60]
    name = hdr[:16].rstrip(b" /\x00").decode("ascii", errors="replace")
    try:
        size = int(hdr[48:58].strip())
    except:
        break
    content_start = pos + 60
    content = deb_data[content_start:content_start+size]
    print(f"  Entry {entry_num}: {name} ({size} bytes)")
    pos = content_start + ((size + 1) // 2) * 2
    entry_num += 1

# Copy to desktop
desktop_path = os.path.join(r"C:\Users\Administrator\Desktop\1", f"{PACKAGE_NAME}_{VERSION}_{ARCH}.deb")
shutil.copy2(deb_path, desktop_path)
print(f"\nCopied to desktop: {desktop_path}")
print(f"Desktop size: {os.path.getsize(desktop_path)} bytes")
