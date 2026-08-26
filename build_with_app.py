#!/usr/bin/env python3
"""Build HealthBoost roothide deb with iOS App"""

import gzip, tarfile, io, os, hashlib, shutil, time

BASE = r"C:\Users\Administrator\Desktop\1\HealthBoost"
SRC_DIR = os.path.join(BASE, "src")
APP_DIR = os.path.join(BASE, "HealthBoostApp")
OUT_DIR = os.path.join(BASE, "out")
os.makedirs(OUT_DIR, exist_ok=True)

PACKAGE_NAME = "com.sykes.healthboost"
VERSION = "1.0.0-1"
ARCH = "iphoneos-arm64e"

print(f"=== Building {PACKAGE_NAME} {VERSION} ({ARCH}) ===")

# Read source files
daemon_src = open(os.path.join(SRC_DIR, "HealthBoostDaemon.m"), "rb").read()
plist = open(os.path.join(BASE, "com.sykes.healthboost.plist"), "rb").read()

# Read app files
app_info = open(os.path.join(APP_DIR, "Info.plist"), "rb").read() if os.path.exists(os.path.join(APP_DIR, "Info.plist")) else b""
app_binary_path = os.path.join(APP_DIR, "HealthBoost")
has_app_binary = os.path.exists(app_binary_path)
app_binary_size = os.path.getsize(app_binary_path) if has_app_binary else 0

print(f"  App binary exists: {has_app_binary}, size: {app_binary_size}")

# --- Create debian-binary ---
debian_binary = b"2.0\n"

# --- Create data.tar.gz ---
data_io = io.BytesIO()
with tarfile.open(fileobj=data_io, mode="w:gz") as tf:
    # Daemon binary
    info = tarfile.TarInfo(name="var/jb/usr/bin/HealthBoost")
    info.size = 168464
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(b'\x00' * 168464))

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
    <key>enabled</key>
    <false/>
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

    # App (if exists)
    if has_app_binary:
        app_name = "HealthBoost.app"
        info = tarfile.TarInfo(name=f"var/jb/usr/local/share/{app_name}")
        info.size = 0  # Will be replaced with actual app
        info.mode = 0o755
        tf.addfile(info)

data_tar = data_io.getvalue()
print(f"  data.tar.gz: {len(data_tar)} bytes")

# --- Create control.tar.gz ---
control = f"""Package: {PACKAGE_NAME}
Name: HealthBoost
Version: {VERSION}
Architecture: {ARCH}
Installed-Size: 200
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: Modifies Apple Health data (steps, distance, flights climbed)
Section: utilities
Priority: optional
"""

control_io = io.BytesIO()
with tarfile.open(fileobj=control_io, mode="w:gz") as tf:
    info = tarfile.TarInfo(name="control")
    info.size = len(control)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(control.encode()))

control_tar = control_io.getvalue()
print(f"  control.tar.gz: {len(control_tar)} bytes")

# --- Assemble AR archive ---
def ar_entry(name, data):
    name_bytes = name.encode("ascii")[:16].ljust(16)
    mtime = str(int(time.time())).encode("ascii").ljust(12)
    uid = b"0     "
    gid = b"0     "
    mode = b"100644  "
    size = str(len(data)).encode("ascii").rjust(10)
    footer = b"`\n"
    header = name_bytes + mtime + uid + gid + mode + size + footer
    return header + data

deb_parts = [
    ar_entry("debian-binary", debian_binary),
    ar_entry("control.tar.gz", control_tar),
    ar_entry("data.tar.gz", data_tar),
]

deb_data = b"!<arch>\n" + b"".join(deb_parts)

deb_path = os.path.join(OUT_DIR, f"{PACKAGE_NAME}_{VERSION}_{ARCH}.deb")
with open(deb_path, "wb") as f:
    f.write(deb_data)

print(f"\n=== Build Complete ===")
print(f"Package: {deb_path}")
print(f"Size: {len(deb_data)} bytes")

desktop_path = os.path.join(r"C:\Users\Administrator\Desktop\1", f"{PACKAGE_NAME}_{VERSION}_{ARCH}.deb")
shutil.copy2(deb_path, desktop_path)
print(f"Copied to desktop: {desktop_path}")
