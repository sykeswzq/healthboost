#!/usr/bin/env python3
"""
Build HealthBoost roothide deb package.
This creates a complete deb with:
1. LaunchDaemon plist (roothide compatible)
2. Configuration plist
3. Postinst/prerm scripts with roothide path rewriting
4. Source code (will need compilation on macOS)
"""

import gzip
import lzma
import os
import hashlib
import tarfile
import io
import time

BASE = r"C:\Users\Administrator\Desktop\1\HealthBoost"
OUT_DIR = os.path.join(BASE, "out")
os.makedirs(OUT_DIR, exist_ok=True)

PACKAGE_NAME = "com.sykes.healthboost"
VERSION = "1.0.0-1"
ARCH = "iphoneos-arm64e"

print(f"=== Building {PACKAGE_NAME} {VERSION} ({ARCH}) ===")

# Read source files
with open(os.path.join(BASE, "src/HealthBoostDaemon.m"), "rb") as f:
    source_code = f.read()
with open(os.path.join(BASE, "com.sykes.healthboost.plist"), "rb") as f:
    plist_content = f.read()
with open(os.path.join(BASE, "HealthBoost.entitlements.plist"), "rb") as f:
    entitlements = f.read()
with open(os.path.join(BASE, "debian/control"), "rb") as f:
    control = f.read()
with open(os.path.join(BASE, "debian/postinst"), "rb") as f:
    postinst = f.read()
with open(os.path.join(BASE, "debian/prerm"), "rb") as f:
    prerm = f.read()

# Create default config
config_content = b"""<?xml version="1.0" encoding="UTF-8"?>
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

# --- Create data.tar.gz ---
# roothide installs to /var/jb/... paths
data_io = io.BytesIO()
with tarfile.open(fileobj=data_io, mode="w:gz") as tf:
    # LaunchDaemon plist
    info = tarfile.TarInfo(name="./var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist")
    info.size = len(plist_content)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(plist_content))
    
    # Config directory and default config
    info = tarfile.TarInfo(name="./var/jb/Library/HealthBoost/")
    info.size = 0
    info.isdir()
    info.mode = 0o755
    tf.addfile(info, None)
    
    info = tarfile.TarInfo(name="./var/jb/Library/HealthBoost/config.plist")
    info.size = len(config_content)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(config_content))
    
    # Source code (for reference/debugging)
    info = tarfile.TarInfo(name="./var/jb/Library/HealthBoost/HealthBoostDaemon.m")
    info.size = len(source_code)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(source_code))

data_tar = data_io.getvalue()
print(f"  data.tar.gz: {len(data_tar)} bytes")

# --- Create control.tar.gz ---
control_io = io.BytesIO()
with tarfile.open(fileobj=control_io, mode="w:gz") as tf:
    info = tarfile.TarInfo(name="control")
    info.size = len(control)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(control))
    
    info = tarfile.TarInfo(name="postinst")
    info.size = len(postinst)
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(postinst))
    
    info = tarfile.TarInfo(name="prerm")
    info.size = len(prerm)
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(prerm))

control_tar = control_io.getvalue()
print(f"  control.tar.gz: {len(control_tar)} bytes")

# --- Assemble AR archive ---
def ar_entry(name, data):
    """Create an AR archive entry"""
    name_bytes = name.encode("ascii")[:16].ljust(16)
    size_str = str(len(data)).encode("ascii").ljust(10)
    footer = b"`\n"
    header = name_bytes + b"14200000000.00" + b"0     " + b"0     " + b"100644  " + size_str + footer
    return header + data

debian_binary = b"2.0\n"

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
pos = 0
while pos < len(deb_data) - 60:
    if deb_data[pos:pos+8] != b"!<arch>\n":
        break
    hdr = deb_data[pos+8:pos+68]
    name = hdr[:16].rstrip(b" /\x00").decode("ascii", errors="replace")
    try:
        size = int(hdr[48:58].strip())
    except:
        break
    content_start = pos + 60
    content = deb_data[content_start:content_start+size]
    print(f"  {name}: {size} bytes")
    pos = content_start + ((size + 1) // 2) * 2

# Copy to desktop
desktop_deb = os.path.join(r"C:\Users\Administrator\Desktop\1", f"{PACKAGE_NAME}_{VERSION}_{ARCH}.deb")
import shutil
shutil.copy2(deb_path, desktop_deb)
print(f"\nCopied to desktop: {desktop_deb}")
print(f"Size: {os.path.getsize(desktop_deb)} bytes")
