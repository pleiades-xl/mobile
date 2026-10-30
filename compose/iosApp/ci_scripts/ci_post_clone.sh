#!/bin/sh
# Xcode Cloud (self-build): a JDK for the Kotlin build (gradlew reads ~/.raft-java-home, since
# Xcode's build phases see no shell profile), the shared framework placeholder, and CocoaPods.
set -e
brew install openjdk@17 cocoapods
echo "$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home" > "$HOME/.raft-java-home"
# The Release link of the shared framework needs more than the project's 6g.
mkdir -p "$HOME/.gradle"
echo 'org.gradle.jvmargs=-Xmx12g -Xss4m -Dfile.encoding=UTF-8 -Dkotlin.daemon.jvm.options\="-Xmx12g,-Xss4m"' >> "$HOME/.gradle/gradle.properties"
cd "$CI_PRIMARY_REPOSITORY_PATH/compose"
./gradlew :shared:generateDummyFramework --no-daemon --console=plain
cd iosApp
pod install
