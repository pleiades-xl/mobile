# 自己编 Raft iOS 版（Xcode 27.1，iPhone Duo 全屏）

基于 botiverse/mobile @ 6382c30。和官方的区别：
- 包名 dev.vgent.raft（官方是 build.raft.app，可以和官方 app 同时装）
- 去掉了免费账号开不了的权限：推送、Apple 登录、通用链接
- 第三方库最低版本统一到 iOS 15（Xcode 27.1 要求）
- Gradle 内存 4g → 6g

连的是官方服务器。能用：Google、GitHub、邮箱密码登录。不能用：Apple 登录、推送。

## 准备（一次）

    brew install --cask temurin@17
    brew install cocoapods
    mkdir -p ~/.gradle && echo "org.gradle.java.home=$(/usr/libexec/java_home -v 17)" >> ~/.gradle/gradle.properties

Xcode 27.1 从 App Store 装。

## 编译、安装

    git clone https://github.com/pleiades-xl/raft-ios-selfbuild.git
    cd raft-ios-selfbuild/compose
    ./gradlew :shared:generateDummyFramework
    cd iosApp && pod install
    open iosApp.xcworkspace

Xcode 里：
1. Settings → Accounts → + 登录 Apple ID。
2. 左边点 iosApp 项目 → TARGETS 选 iosApp → Signing & Capabilities → Team 选 "(Personal Team)"。提示包名被占用就把 dev.vgent.raft 改成别的。
3. iPhone 用线连 Mac，点"信任"。iPhone 设置 → 隐私与安全性 → 开发者模式 → 打开，重启。
4. Xcode 顶上选你的 iPhone，按 ⌘R。第一次要编十几到几十分钟。
5. 第一次打开前：iPhone 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。

免费账号签的 app 7 天后打不开，连上 Mac 再按一次 ⌘R 就行。

## Mac 太老、装不了 Xcode 27.1 时

Xcode 27.1 要 macOS Tahoe 26.6 以上。系统更老的话，用云上编好的 app，自己签名安装：

1. 从 Releases 下载 Raft-Debug.zip（正式版云上内存不够，暂时编不出来）。
2. 生成免费签名：Xcode → File → New → Project → iOS App，Team 选 Personal Team，
   Organization Identifier 填 dev.vgent，Product Name 填 raft（包名就是 dev.vgent.raft）。
   iPhone 连上 Mac、打开开发者模式，选 iPhone，⌘R 装一次。
3. 终端里：

       ./install-on-iphone.sh ~/Downloads/Raft-Debug.zip

   包名改过的话加在后面：`./install-on-iphone.sh ~/Downloads/Raft-Debug.zip dev.vgent.raft.xl`
4. 第一次打开前：iPhone 设置 → 通用 → VPN 与设备管理 → 信任。

7 天后过期：先在 Xcode 里把那个空项目再装一次（续签名），再跑一次脚本。
