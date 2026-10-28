#!/bin/bash
# 把云上用 Xcode 27.1 编好的 Raft（Raft-Debug.zip，或解压出来的 iosApp.app）
# 用你自己的免费签名重新签名，装到用线连着的 iPhone 上。
#
# 用法: bash install-on-iphone.sh Raft-Debug.zip [包名，默认 dev.vgent.raft]
# 连着好几台 iPhone 时，用 IPHONE=手机名或 Identifier 指定，例如
#   IPHONE=1F3F2623-6A98-5ABC-ADAA-5C6B0A90F99C bash install-on-iphone.sh Raft-Debug.zip
#
# 先决条件：用 Xcode 建过一个同包名的空项目，并往这台 iPhone 上装过一次
# （这样 Xcode 才会生成你的签名证书和签名文件）。
set -euo pipefail

zip="${1:?用法: bash $0 Raft-Debug.zip [包名]}"
bundle="${2:-dev.vgent.raft}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Safari 可能已经自动解压成 iosApp.app，两种都收
if [ -d "$zip" ]; then ditto "$zip" "$work/iosApp.app"; else ditto -x -k "$zip" "$work"; fi
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
with open(os.path.join(work, "udids.txt"), "w") as f:
    f.write("\n".join(d.get("ProvisionedDevices", [])))
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
mkdir -p "$work/Payload" && ditto "$app" "$work/Payload/iosApp.app"
ipa="$HOME/Downloads/Raft-signed.ipa"
(cd "$work" && rm -f "$ipa" && zip -qry "$ipa" Payload)
echo "签名完成：$ipa"

# 找用线连着的 iPhone，装上去
xcrun devicectl list devices --json-output "$work/devices.json" >/dev/null
cat > "$work/device.py" <<'PY'
import json, os, sys
devices, udids_file, want = sys.argv[1], sys.argv[2], os.environ.get("IPHONE", "")
udids = open(udids_file).read().split()
phones = [d for d in json.load(open(devices))["result"]["devices"]
          if d["hardwareProperties"].get("platform") == "iOS"
          and d["connectionProperties"].get("pairingState") == "paired"]
name = lambda d: d["deviceProperties"].get("name", "?")
if want:
    picked = [d for d in phones if want in (d["identifier"], name(d))]
else:
    picked = [d for d in phones if d["connectionProperties"].get("tunnelState") == "connected"] or phones
if len(picked) != 1:
    listing = "\n".join(f"  {name(d)}  {d['identifier']}" for d in phones) or "  （一台都没有）"
    sys.exit(f"不确定装到哪台 iPhone。现在连着的：\n{listing}\n用 IPHONE=<Identifier> bash install-on-iphone.sh ... 指定一台。")
d = picked[0]
if udids and d["hardwareProperties"].get("udid") not in udids:
    sys.exit(f"签名文件里没有 {name(d)} 这台手机。在 Xcode 里选这台手机按一次 ⌘B（或 ⌘R），让 Xcode 把它登记上，再跑脚本。")
print(f"装到：{name(d)}", file=sys.stderr)
print(d["identifier"])
PY
device="$(/usr/bin/python3 "$work/device.py" "$work/devices.json" "$work/udids.txt")"
xcrun devicectl device install app --device "$device" "$app" || {
  echo "直接安装失败。打开 Finder，左边点你的 iPhone，把 $ipa 拖进右边的窗口里装。"
  exit 1
}
echo "装好了。第一次打开前：iPhone 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。"
