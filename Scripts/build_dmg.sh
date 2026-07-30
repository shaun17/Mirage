#!/bin/zsh

set -euo pipefail

# 始终从脚本所在位置解析工程根目录，避免调用方当前目录影响产物路径。
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/build"
ARCHIVE_PATH="${BUILD_DIRECTORY}/Mirage.xcarchive"
ARCHIVE_DERIVED_DATA_PATH="${BUILD_DIRECTORY}/ArchiveDerivedData"
DIST_DIRECTORY="${PROJECT_DIRECTORY}/dist"
DMG_PATH="${DIST_DIRECTORY}/Mirage-0.1.0-dev.dmg"

# 自动签名需要 Xcode 已登录开发者账号；设为 0 可用于仅验证无签名编译。
PROVISIONING_ARGUMENTS=()
if [[ "${ALLOW_PROVISIONING_UPDATES:-1}" == "1" ]]; then
  PROVISIONING_ARGUMENTS+=("-allowProvisioningUpdates")
fi

# 重新生成工程，保证 project.yml 是构建配置的唯一来源。
cd "${PROJECT_DIRECTORY}"
xcodegen generate --spec "${PROJECT_DIRECTORY}/project.yml"

mkdir -p "${BUILD_DIRECTORY}" "${DIST_DIRECTORY}"

# 每次归档只清理工程 build 目录内的派生签名缓存，避免 Xcode 复用已轮换的 profile UUID。
rm -rf "${ARCHIVE_PATH}" "${ARCHIVE_DERIVED_DATA_PATH}"

# Archive 会先签嵌入的 File Provider，再签宿主 App，便于后续完整验签。
xcodebuild \
  -project "${PROJECT_DIRECTORY}/Mirage.xcodeproj" \
  -scheme Mirage \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "${ARCHIVE_DERIVED_DATA_PATH}" \
  -archivePath "${ARCHIVE_PATH}" \
  "${PROVISIONING_ARGUMENTS[@]}" \
  archive

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Mirage.app"
if [[ ! -d "${APP_PATH}" ]]; then
  print -u2 "未找到归档后的 Mirage.app"
  exit 1
fi

# DMG 只打包已经通过嵌套签名验证的产物，避免交付安装后才暴露 appex 签名问题。
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/mirage-dmg.XXXXXX")"
cleanup() {
  # 临时目录由本脚本创建且路径已固定前缀，可以安全清理。
  rm -rf "${STAGING_DIRECTORY}"
}
trap cleanup EXIT

ditto "${APP_PATH}" "${STAGING_DIRECTORY}/Mirage.app"
ln -s /Applications "${STAGING_DIRECTORY}/Applications"

# 开发版 DMG 允许覆盖同名构建产物；不会触碰工程或用户文件。
hdiutil create \
  -volname "Mirage" \
  -srcfolder "${STAGING_DIRECTORY}" \
  -format UDZO \
  -ov \
  "${DMG_PATH}"

hdiutil verify "${DMG_PATH}"
print "DMG 已生成：${DMG_PATH}"
