# HealthBoost - Apple Health Data Modifier

roothide deb package for modifying Apple Health data on jailbroken iOS devices.

## Features

- Modify **step count** (步数)
- Modify **walking/running distance** (步行距离)
- Modify **flights climbed** (已爬楼层数)

## Installation

1. Install the `.deb` package via Sileo/Zebra
2. Configure using `config.plist` at `/var/jb/Library/HealthBoost/config.plist`

## Configuration

Edit `/var/jb/Library/HealthBoost/config.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>steps</key>
    <integer>10000</integer>
    <key>distance</key>
    <real>7500.0</real>
    <key>flights</key>
    <integer>50</integer>
</dict>
</plist>
```

| Key | Type | Description |
|-----|------|-------------|
| `steps` | integer | Number of steps to add |
| `distance` | real | Distance in meters to add |
| `flights` | integer | Number of flights to add |

## Technical Details

- **Architecture**: iphoneos-arm64e (roothide compatible)
- **Minimum iOS**: 13.0
- **Daemon**: Runs on install via LaunchDaemon
- **HealthKit Entitlement**: Embedded for authorization bypass

## Building

Requires macOS with Xcode command line tools:

```bash
bash build.sh
```

## License

MIT
