#!/bin/bash
# 把云上用 Xcode 27.1 编好的 Raft（Raft-Release.zip 或 Raft-Debug.zip）
# 用你自己的免费签名重新签名，装到用线连着的 iPhone 上。
#
# 用法: ./install-on-iphone.sh Raft-Release.zip [包名，默认 dev.vgent.raft]
#
# 先决条件：用 Xcode 建过一个同包名的空项目，并往这台 iPhone 上装过一次
# （这样 Xcode 才会生成你的签名证书和签名文件）。
set -euo pipefail

zip="${1:?用法: $0 Raft-Release.zip [包名]}"
bundle="${2:-dev.vgent.raft}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ditto -x -k "$zip" "$work"
app="$work/iosApp.app"
[ -d "$app" ] || { echo "zip 里没有 iosApp.app"; exit 1; }

# 找 Xcode 给这个包名生成的签名文件，取出签名证书和权限
cat > "$work/profile.py" <<'PY'
import datetime, glob, hashlib, os, plistlib, shutil, subprocess, sys
bundle, work = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
best = None
for p in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*")) + \
         glob.glob(os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles/*")):
    raw = subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True).stdout
    if not raw:
        continue
    d = plistlib.loads(raw)
    if d["Entitlements"].get("application-identifier", "").split(".", 1)[-1] != bundle:
        continue
    if d["ExpirationDate"] < now:
        continue
    if best is None or d["CreationDate"] > best[1]["CreationDate"]:
        best = (p, d)
if not best:
    sys.exit(f"没找到包名 {bundle} 的签名文件。先用 Xcode 建一个包名是 {bundle} 的空项目，往这台 iPhone 上装一次。")
path, d = best
team = d["TeamIdentifier"][0]
shutil.copy(path, os.path.join(work, "iosApp.app", "embedded.mobileprovision"))
with open(os.path.join(work, "ent.plist"), "wb") as f:
    plistlib.dump({
        "application-identifier": f"{team}.{bundle}",
        "com.apple.developer.team-identifier": team,
        "get-task-allow": d["Entitlements"].get("get-task-allow", True),
        "keychain-access-groups": [f"{team}.{bundle}"],
    }, f)
installed = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
for cert in d["DeveloperCertificates"]:
    h = hashlib.sha1(cert).hexdigest().upper()
    if h in installed:
        print(h)
        break
else:
    sys.exit("钥匙串里没有这个签名文件对应的证书。在 Xcode 里把那个空项目再往手机上装一次。")
PY
identity="$(/usr/bin/python3 "$work/profile.py" "$bundle" "$work")"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$app/Info.plist"

# 先签里面的库，再签 app
find "$app/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null |
  while IFS= read -r -d '' f; do codesign -f -s "$identity" "$f"; done
codesign -f -s "$identity" --entitlements "$work/ent.plist" "$app"
codesign --verify --deep --strict "$app"
echo "签名完成"

# 找用线连着的 iPhone，装上去
xcrun devicectl list devices --json-output "$work/devices.json" >/dev/null
cat > "$work/device.py" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("pairingState") == "paired":
        print(d["identifier"])
        break
else:
    sys.exit("没找到 iPhone。用线连上 Mac，在手机上点“信任”，再试一次。")
PY
device="$(/usr/bin/python3 "$work/device.py" "$work/devices.json")"
xcrun devicectl device install app --device "$device" "$app"
echo "装好了。第一次打开前：iPhone 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。"
