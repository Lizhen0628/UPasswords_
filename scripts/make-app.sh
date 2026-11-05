#!/bin/bash
# Bundle the macOS SPM executable into a runnable UPasswords.app.
# Usage: ./scripts/make-app.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
CONFIG="${CONFIG:-release}"
APP_PKG="Apple/macOS"

echo "==> swift build -c $CONFIG ($APP_PKG)"
(cd "$APP_PKG" && swift build -c "$CONFIG")

# Credential Provider is an Xcode application extension and must be built with
# the macOS app target so it can be embedded in the distributable app bundle.
MACOS_DERIVED="${TMPDIR:-/tmp}/UPasswordsMacOSDerived"
XCODE_CONFIGURATION="Release"
if [ "$CONFIG" = "debug" ]; then XCODE_CONFIGURATION="Debug"; fi
echo "==> xcodebuild $XCODE_CONFIGURATION (macOS app + Credential Provider)"
xcodebuild -quiet -allowProvisioningUpdates \
  -workspace UPasswords.xcworkspace -scheme UPasswords-macOS \
  -configuration "$XCODE_CONFIGURATION" -derivedDataPath "$MACOS_DERIVED" clean build

# Safari 扩展独立容器 App(不依赖桌面完整版):扩展数据通路在 JS 内直连
# relay API,容器仅承载 appex。失败仅告警(主 App 打包不受影响)。
# -allowProvisioningUpdates:让已登录 Apple ID 的机器自动补描述文件;
# CI 无账号时照样失败走告警路径。
echo "==> xcodebuild Release (standalone Safari container)"
SAFARI_DERIVED="${TMPDIR:-/tmp}/UPasswordsSafariDerived"
SAFARI_APP=""
if xcodebuild -quiet -allowProvisioningUpdates \
      -workspace UPasswords.xcworkspace -scheme UPasswordsSafari \
      -configuration Release -derivedDataPath "$SAFARI_DERIVED" build 2>/dev/null; then
  SAFARI_APP="$SAFARI_DERIVED/Build/Products/Release/UPasswordsSafari.app"
else
  echo "    WARNING: standalone Safari app build failed — skipping it"
fi
if [ -n "$SAFARI_APP" ] && [ -d "$SAFARI_APP" ]; then
  DEST="$OUT_DIR/UPasswords for Safari.app"
  rm -rf "$DEST"
  cp -R "$SAFARI_APP" "$DEST"
  # xcodebuild 已整包签名(含 appex 的 sandbox/app-group entitlements),不再重签
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  echo "==> packaged standalone Safari app ($(du -sh "$DEST" | cut -f1))"
else
  echo "    WARNING: standalone Safari app not found in build products"
fi

BIN="$APP_PKG/.build/$CONFIG/UPasswords"
APP="$OUT_DIR/UPasswords.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> copying binary + module bundle"
cp "$BIN" "$CONTENTS/MacOS/UPasswords"
# SPM 资源 bundle 落在 .build/<config>/ 下:应用自身的 UPasswords_UPasswords.bundle
# (菜单栏图标)与依赖包的 UPasswordsCore_UPasswordsCore.bundle(lproj 字符串表)——
# 必须全部拷入,漏掉 Core bundle 会在首次取词时 fatalError 崩溃。
# 拷贝目标必须是 Contents/Resources/:Xcode 27 工具链的 SPM 访问器只探测
# Bundle.main.resourceURL(历史上把 bundle 放 MacOS/ 的做法已不再被找到)。
for bundle in "$APP_PKG/.build/$CONFIG/"*.bundle; do
  [ -d "$bundle" ] || continue
  cp -R "$bundle" "$CONTENTS/Resources/"
done

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>UPasswords</string>
    <key>CFBundleDisplayName</key>
    <string>UPasswords</string>
    <key>CFBundleIdentifier</key>
    <string>com.upasswords.UPasswords</string>
    <key>CFBundleVersion</key>
    <string>$(date +%y%m%d%H%M)</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>UPasswords</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# 应用图标(程序坞/Finder/锁屏展示用)
if [ -f "$APP_PKG/Resources/AppIcon.icns" ]; then
  cp "$APP_PKG/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
# The SPM executable above is retained for the local distribution layout;
# embed the Xcode-built Credential Provider into that same app bundle.
XCODE_APP="$MACOS_DERIVED/Build/Products/$XCODE_CONFIGURATION/UPasswords.app"
XCODE_CREDENTIAL_PROVIDER="$XCODE_APP/Contents/PlugIns/UPasswordsCredentialProvider.appex"
if [ -d "$XCODE_CREDENTIAL_PROVIDER" ]; then
  mkdir -p "$CONTENTS/PlugIns"
  cp -R "$XCODE_CREDENTIAL_PROVIDER" "$CONTENTS/PlugIns/"
else
  echo "ERROR: Credential Provider extension was not produced" >&2
  exit 1
fi
# 菜单栏三钥匙 template 图随 SPM 资源打入 UPasswords_UPasswords.bundle(见上),
# 由 StatusItemController 经 AppResources.bundle 加载。

# 稳定签名:优先用开发证书,找不到才回退 ad-hoc。
# ad-hoc 签名按代码哈希生效——每次重打包哈希都变,钥匙串把新包当陌生程序,
# 周期性钥匙串访问(如云同步令牌)会被 macOS 逐次弹指纹/密码授权;
# 开发证书身份跨构建稳定,授权一次永久生效。
# entitlements 只带应用组:应用组容器(Group Containers)在 TCC 里属
# 「其他 App 的数据」,不带该授权时 SafariSnapshotBridge 每次推送快照都会弹窗。
# 注意:不加 --deep——appex 的 sandbox/app-group entitlements 必须保持
# xcodebuild 给它的独立签名,父包的 entitlements 覆盖上去会毁掉沙盒配置。
XCODE_CONFIGURATION="Release"
if [ "$CONFIG" = "debug" ]; then XCODE_CONFIGURATION="Debug"; fi
XCODE_APP="$MACOS_DERIVED/Build/Products/$XCODE_CONFIGURATION/UPasswords.app"
if [ ! -d "$XCODE_APP/Contents/PlugIns/UPasswordsCredentialProvider.appex" ]; then
  echo "ERROR: signed Credential Provider app was not produced" >&2
  exit 1
fi
echo "==> preserving Xcode app signature and AutoFill entitlements"
rm -rf "$APP"
cp -R "$XCODE_APP" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"

echo "==> $APP"
du -sh "$APP"

# /Applications 已有安装拷贝时同步替换(同 bundle id,Dock/LaunchServices 会优先
# 打开 /Applications 那份——不同步的话用户点开的永远是旧版本)。
if [ -d "/Applications/UPasswords.app" ] && [ "$OUT_DIR" != "/Applications" ]; then
  rm -rf "/Applications/UPasswords.app"
  cp -R "$APP" "/Applications/UPasswords.app"
  xattr -dr com.apple.quarantine "/Applications/UPasswords.app" 2>/dev/null || true
  echo "==> synced to /Applications/UPasswords.app"
fi

# 独立 Safari 容器 App 同步安装(Safari 扩展的稳定宿主,替代 DerivedData)
if [ -n "$SAFARI_APP" ] && [ -d "$OUT_DIR/UPasswords for Safari.app" ] && [ "$OUT_DIR" != "/Applications" ]; then
  rm -rf "/Applications/UPasswords for Safari.app"
  cp -R "$OUT_DIR/UPasswords for Safari.app" "/Applications/UPasswords for Safari.app"
  xattr -dr com.apple.quarantine "/Applications/UPasswords for Safari.app" 2>/dev/null || true
  echo "==> synced to /Applications/UPasswords for Safari.app"
fi

# 扩展注册锚定到成品包位置(独立容器 App);DerivedData 注册易被 clean 清掉。
if [ -n "$SAFARI_APP" ] && [ -d "$OUT_DIR/UPasswords for Safari.app" ]; then
  BUILT_SAFARI_EXTENSION="$SAFARI_APP/Contents/PlugIns/UPasswordsSafariWebExtension.appex"
  PACKAGED_SAFARI_EXTENSION="$OUT_DIR/UPasswords for Safari.app/Contents/PlugIns/UPasswordsSafariWebExtension.appex"
  REGISTRATION_SAFARI_EXTENSION="$PACKAGED_SAFARI_EXTENSION"
  pluginkit -r "$BUILT_SAFARI_EXTENSION" 2>/dev/null || true
  pluginkit -r "$PACKAGED_SAFARI_EXTENSION" 2>/dev/null || true
  if [ -d "/Applications/UPasswords for Safari.app" ]; then
    REGISTRATION_SAFARI_EXTENSION="/Applications/UPasswords for Safari.app/Contents/PlugIns/UPasswordsSafariWebExtension.appex"
  fi
fi

# Credential Provider is embedded in the main app and should remain registered
# against the stable installed copy when one exists.
if [ -d "$OUT_DIR/UPasswords.app/Contents/PlugIns/UPasswordsCredentialProvider.appex" ]; then
  BUILT_CREDENTIAL_PROVIDER="$OUT_DIR/UPasswords.app/Contents/PlugIns/UPasswordsCredentialProvider.appex"
  XCODE_CONFIGURATION="Release"
  if [ "$CONFIG" = "debug" ]; then XCODE_CONFIGURATION="Debug"; fi
  XCODE_CREDENTIAL_PROVIDER="$MACOS_DERIVED/Build/Products/$XCODE_CONFIGURATION/UPasswords.app/Contents/PlugIns/UPasswordsCredentialProvider.appex"
  CREDENTIAL_PROVIDER="$BUILT_CREDENTIAL_PROVIDER"
  if [ -d "/Applications/UPasswords.app" ]; then
    CREDENTIAL_PROVIDER="/Applications/UPasswords.app/Contents/PlugIns/UPasswordsCredentialProvider.appex"
  fi
  pluginkit -r "$XCODE_CREDENTIAL_PROVIDER" 2>/dev/null || true
  pluginkit -r "$BUILT_CREDENTIAL_PROVIDER" 2>/dev/null || true
  if [ "$CREDENTIAL_PROVIDER" != "$BUILT_CREDENTIAL_PROVIDER" ]; then
    pluginkit -r "$CREDENTIAL_PROVIDER" 2>/dev/null || true
  fi
  pluginkit -a "$CREDENTIAL_PROVIDER"
  echo "==> Credential Provider registered"
fi

if [ -n "${REGISTRATION_SAFARI_EXTENSION:-}" ] && [ -d "$REGISTRATION_SAFARI_EXTENSION" ]; then
  /usr/bin/pluginkit -a -v "$REGISTRATION_SAFARI_EXTENSION"
  SAFARI_REGISTRATIONS=$(
    /usr/bin/pluginkit -m -A -D -v -i com.upasswords.UPasswords.Safari.Extension 2>/dev/null || true
  )
  if [[ "$SAFARI_REGISTRATIONS" == *"$REGISTRATION_SAFARI_EXTENSION"* ]]; then
    echo "==> Safari extension registered at stable app path"
  else
    echo "    WARNING: Safari extension registration was not confirmed"
  fi
fi
