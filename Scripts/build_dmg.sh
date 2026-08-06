#!/bin/zsh

set -euo pipefail

fail() {
  print -u2 -- "错误：$*"
  exit 1
}

# 始终从脚本所在位置解析工程根目录，避免调用方当前目录影响产物路径。
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
PROJECT_SPEC="${PROJECT_DIRECTORY}/project.yml"
DMG_BACKGROUND_SOURCE="${PROJECT_DIRECTORY}/Branding/DmgBackground.svg"
DMG_LAYOUT_SCRIPT="${SCRIPT_DIRECTORY}/layout_dmg.applescript"
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/build"
BUILD_TMP_DIRECTORY="${BUILD_DIRECTORY}/tmp"
SOURCE_PACKAGES_DIRECTORY="${BUILD_DIRECTORY}/SourcePackages"
DIST_DIRECTORY="${PROJECT_DIRECTORY}/dist"
RELEASE_MODE="${RELEASE_MODE:-development}"

for required_command in SetFile awk codesign diskutil ditto hdiutil osascript plutil security shasum sips spctl xcodebuild xcodegen xcrun; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || fail "缺少必要命令：${required_command}"
done

[[ -f "${PROJECT_SPEC}" ]] || fail "未找到项目配置：${PROJECT_SPEC}"
[[ -f "${DMG_BACKGROUND_SOURCE}" ]] \
  || fail "未找到 DMG 背景源文件：${DMG_BACKGROUND_SOURCE}"
[[ -f "${DMG_LAYOUT_SCRIPT}" ]] \
  || fail "未找到 DMG Finder 布局脚本：${DMG_LAYOUT_SCRIPT}"

read_project_setting() {
  local setting_name="$1"

  awk -v key="${setting_name}" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/[\"[:space:]]/, "", value)
      print value
      exit
    }
  ' "${PROJECT_SPEC}"
}

MARKETING_VERSION="$(read_project_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_project_setting CURRENT_PROJECT_VERSION)"
DEVELOPMENT_TEAM="$(read_project_setting DEVELOPMENT_TEAM)"

VERSION_PATTERN='^[0-9]+([.][0-9]+)*$'
BUILD_PATTERN='^[0-9]+$'
TEAM_PATTERN='^[A-Z0-9]{10}$'

[[ "${MARKETING_VERSION}" =~ ${VERSION_PATTERN} ]] \
  || fail "project.yml 中的 MARKETING_VERSION 无效：${MARKETING_VERSION:-<空>}"
[[ "${BUILD_NUMBER}" =~ ${BUILD_PATTERN} ]] \
  || fail "project.yml 中的 CURRENT_PROJECT_VERSION 无效：${BUILD_NUMBER:-<空>}"
[[ "${DEVELOPMENT_TEAM}" =~ ${TEAM_PATTERN} ]] \
  || fail "project.yml 中的 DEVELOPMENT_TEAM 无效：${DEVELOPMENT_TEAM:-<空>}"

case "${RELEASE_MODE}" in
  development)
    DMG_FILENAME="Mirage-${MARKETING_VERSION}-development.dmg"
    EXPECTED_AUTHORITY="Authority=Apple Development:"
    ;;
  developer-id)
    DMG_FILENAME="Mirage-${MARKETING_VERSION}.dmg"
    EXPECTED_AUTHORITY="Authority=Developer ID Application:"
    ;;
  *)
    fail "RELEASE_MODE 仅支持 development 或 developer-id，当前值：${RELEASE_MODE}"
    ;;
esac

DMG_PATH="${DIST_DIRECTORY}/${DMG_FILENAME}"
SHA256_FILENAME="${DMG_FILENAME}.sha256"
SHA256_PATH="${DIST_DIRECTORY}/${SHA256_FILENAME}"

# 自动签名需要 Xcode 已登录开发者账号；设为 0 可禁止 Xcode 更新 profile。
PROVISIONING_ARGUMENTS=()
case "${ALLOW_PROVISIONING_UPDATES:-1}" in
  1)
    PROVISIONING_ARGUMENTS+=("-allowProvisioningUpdates")
    ;;
  0)
    ;;
  *)
    fail "ALLOW_PROVISIONING_UPDATES 仅支持 0 或 1"
    ;;
esac

DEVELOPER_IDENTITY_HASH=""
if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] \
    || fail "developer-id 模式必须设置 NOTARY_KEYCHAIN_PROFILE"

  DEVELOPER_IDENTITY_HASH="$(
    security find-identity -v -p codesigning \
      | awk -v team="${DEVELOPMENT_TEAM}" '
          /"Developer ID Application:/ && index($0, "(" team ")") {
            print $2
            exit
          }
        '
  )"
  [[ -n "${DEVELOPER_IDENTITY_HASH}" ]] \
    || fail "未找到团队 ${DEVELOPMENT_TEAM} 的有效 Developer ID Application 证书及私钥"

  # 在耗时构建前验证 profile 确实存在且可用于访问公证服务。
  xcrun notarytool history \
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    >/dev/null \
    || fail "NOTARY_KEYCHAIN_PROFILE 无效或无法访问公证服务"
fi

mkdir -p "${BUILD_TMP_DIRECTORY}" "${DIST_DIRECTORY}"
WORK_DIRECTORY="$(mktemp -d "${BUILD_TMP_DIRECTORY}/mirage-release.XXXXXX")"

cleanup() {
  local cleanup_path="${WORK_DIRECTORY:-}"
  local may_remove_work_directory=1

  if [[ -n "${DMG_MOUNT_DEVICE:-}" ]]; then
    if ! hdiutil detach "${DMG_MOUNT_DEVICE}" >/dev/null 2>&1; then
      if [[ -z "${DMG_MOUNT_DIRECTORY:-}" ]] \
        || ! hdiutil detach "${DMG_MOUNT_DIRECTORY}" >/dev/null 2>&1; then
        may_remove_work_directory=0
      fi
    fi
  elif [[ -n "${DMG_MOUNT_DIRECTORY:-}" ]]; then
    hdiutil detach "${DMG_MOUNT_DIRECTORY}" >/dev/null 2>&1 \
      || may_remove_work_directory=0
  fi

  if (( may_remove_work_directory == 0 )); then
    print -u2 -- "警告：DMG 临时卷卸载失败，已保留工作目录：${cleanup_path}"
    return 0
  fi

  # 只允许清理本工程 build/tmp 下由 mktemp 创建的唯一工作目录。
  if [[ -n "${cleanup_path}" && "${cleanup_path}" == "${BUILD_TMP_DIRECTORY}/"* ]]; then
    rm -rf -- "${cleanup_path}"
  fi
}
trap cleanup EXIT

ARCHIVE_PATH="${WORK_DIRECTORY}/Mirage.xcarchive"
ARCHIVE_DERIVED_DATA_PATH="${WORK_DIRECTORY}/ArchiveDerivedData"
EXPORT_DIRECTORY="${WORK_DIRECTORY}/Export"
STAGING_DIRECTORY="${WORK_DIRECTORY}/DmgRoot"
READ_WRITE_DMG_PATH="${WORK_DIRECTORY}/Mirage-layout.dmg"
DMG_MOUNT_DIRECTORY="${WORK_DIRECTORY}/DmgMount"
DMG_MOUNT_DEVICE=""
WORK_DMG_PATH="${WORK_DIRECTORY}/${DMG_FILENAME}"
DMG_LAYOUT_VOLUME_NAME="Mirage Layout ${$}-${RANDOM}"

DMG_WINDOW_WIDTH=680
DMG_WINDOW_HEIGHT=382
DMG_APP_X=180
DMG_APP_Y=150
DMG_APPLICATIONS_X=500
DMG_APPLICATIONS_Y=150
DMG_ICON_SIZE=128

print "开始构建 Mirage ${MARKETING_VERSION} (${BUILD_NUMBER})，模式：${RELEASE_MODE}"

# 重新生成工程，保证 project.yml 是构建配置的唯一来源。
cd "${PROJECT_DIRECTORY}"
xcodegen generate --spec "${PROJECT_SPEC}"

# Archive 会先签嵌入的 File Provider，再签宿主 App。
xcodebuild \
  -project "${PROJECT_DIRECTORY}/Mirage.xcodeproj" \
  -scheme Mirage \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIRECTORY}" \
  -derivedDataPath "${ARCHIVE_DERIVED_DATA_PATH}" \
  -archivePath "${ARCHIVE_PATH}" \
  "${PROVISIONING_ARGUMENTS[@]}" \
  archive

if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  EXPORT_OPTIONS_PLIST="$(mktemp "${WORK_DIRECTORY}/ExportOptions.XXXXXX")"
  plutil -create xml1 "${EXPORT_OPTIONS_PLIST}"
  plutil -insert method -string developer-id "${EXPORT_OPTIONS_PLIST}"
  plutil -insert signingStyle -string automatic "${EXPORT_OPTIONS_PLIST}"
  plutil -insert teamID -string "${DEVELOPMENT_TEAM}" "${EXPORT_OPTIONS_PLIST}"

  xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIRECTORY}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
    "${PROVISIONING_ARGUMENTS[@]}"

  APP_PATH="${EXPORT_DIRECTORY}/Mirage.app"
else
  APP_PATH="${ARCHIVE_PATH}/Products/Applications/Mirage.app"
fi

[[ -d "${APP_PATH}" ]] || fail "未找到构建后的 Mirage.app：${APP_PATH}"

FILE_PROVIDER_PATH="${APP_PATH}/Contents/PlugIns/MirageFileProvider.appex"
[[ -d "${FILE_PROVIDER_PATH}" ]] \
  || fail "未找到嵌入的 MirageFileProvider.appex"

verify_bundle_signature() {
  local bundle_path="$1"
  local signature_details

  codesign --verify --strict --verbose=2 "${bundle_path}"
  signature_details="$(codesign -dv --verbose=4 "${bundle_path}" 2>&1)"

  [[ "${signature_details}" == *"${EXPECTED_AUTHORITY}"* ]] \
    || fail "签名 Authority 不符合 ${RELEASE_MODE} 模式：${bundle_path}"
  [[ "${signature_details}" == *"TeamIdentifier=${DEVELOPMENT_TEAM}"* ]] \
    || fail "签名 TeamIdentifier 不匹配：${bundle_path}"
}

# 先验签嵌套扩展，再深度验证宿主 App 的完整签名封装。
verify_bundle_signature "${FILE_PROVIDER_PATH}"
verify_bundle_signature "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

verify_bundle_version() {
  local bundle_path="$1"
  local info_plist="${bundle_path}/Contents/Info.plist"
  local actual_version
  local actual_build

  [[ -f "${info_plist}" ]] || fail "未找到 bundle Info.plist：${bundle_path}"
  actual_version="$(plutil -extract CFBundleShortVersionString raw "${info_plist}")"
  actual_build="$(plutil -extract CFBundleVersion raw "${info_plist}")"

  [[ "${actual_version}" == "${MARKETING_VERSION}" ]] \
    || fail "bundle 版本不匹配：${bundle_path}，预期 ${MARKETING_VERSION}，实际 ${actual_version}"
  [[ "${actual_build}" == "${BUILD_NUMBER}" ]] \
    || fail "bundle build number 不匹配：${bundle_path}，预期 ${BUILD_NUMBER}，实际 ${actual_build}"
}

verify_bundle_version "${FILE_PROVIDER_PATH}"
verify_bundle_version "${APP_PATH}"

mkdir -p "${STAGING_DIRECTORY}"
ditto "${APP_PATH}" "${STAGING_DIRECTORY}/Mirage.app"
ln -s /Applications "${STAGING_DIRECTORY}/Applications"

# Chrome 风格的 Finder 安装界面需要把背景、图标坐标和窗口状态写入卷内。
VOLUME_ICON_SOURCE="${APP_PATH}/Contents/Resources/AppIcon.icns"
[[ -f "${VOLUME_ICON_SOURCE}" ]] \
  || fail "未找到用于 DMG 卷图标的 AppIcon.icns"

mkdir -p "${STAGING_DIRECTORY}/.background"
ditto "${VOLUME_ICON_SOURCE}" "${STAGING_DIRECTORY}/.VolumeIcon.icns"
sips \
  -s format png \
  -s dpiWidth 72 \
  -s dpiHeight 72 \
  "${DMG_BACKGROUND_SOURCE}" \
  --out "${STAGING_DIRECTORY}/.background/background.png" \
  >/dev/null

BACKGROUND_WIDTH="$(
  sips -g pixelWidth "${STAGING_DIRECTORY}/.background/background.png" \
    | awk '/pixelWidth:/ { print $2; exit }'
)"
BACKGROUND_HEIGHT="$(
  sips -g pixelHeight "${STAGING_DIRECTORY}/.background/background.png" \
    | awk '/pixelHeight:/ { print $2; exit }'
)"
[[ "${BACKGROUND_WIDTH}" == "${DMG_WINDOW_WIDTH}" \
  && "${BACKGROUND_HEIGHT}" == "$((DMG_WINDOW_HEIGHT - 22))" ]] \
  || fail "DMG 背景尺寸错误：${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}"

hdiutil create \
  -volname "${DMG_LAYOUT_VOLUME_NAME}" \
  -srcfolder "${STAGING_DIRECTORY}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "${READ_WRITE_DMG_PATH}"

mkdir -p "${DMG_MOUNT_DIRECTORY}"
ATTACH_OUTPUT="$(hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "${DMG_MOUNT_DIRECTORY}" \
  "${READ_WRITE_DMG_PATH}")"
DMG_MOUNT_DEVICE="$(
  print -r -- "${ATTACH_OUTPUT}" \
    | awk '$2 == "Apple_HFS" { print $1; exit }'
)"
[[ -n "${DMG_MOUNT_DEVICE}" ]] \
  || fail "无法识别 DMG 的 HFS+ 挂载设备"

# 先由 Finder 生成包含布局的 .DS_Store。
osascript "${DMG_LAYOUT_SCRIPT}" \
  "${DMG_MOUNT_DIRECTORY}" \
  "${DMG_WINDOW_WIDTH}" \
  "${DMG_WINDOW_HEIGHT}" \
  "${DMG_APP_X}" \
  "${DMG_APP_Y}" \
  "${DMG_APPLICATIONS_X}" \
  "${DMG_APPLICATIONS_Y}" \
  "${DMG_ICON_SIZE}"

[[ -s "${DMG_MOUNT_DIRECTORY}/.DS_Store" ]] \
  || fail "Finder 未写入 DMG 布局文件 .DS_Store"

# 临时唯一卷名可隔离同名 Mirage 卷的 Finder 缓存；布局落盘后再恢复正式卷名。
diskutil rename "${DMG_MOUNT_DEVICE}" "Mirage" >/dev/null
ACTUAL_VOLUME_NAME="$(
  diskutil info -plist "${DMG_MOUNT_DEVICE}" \
    | plutil -extract VolumeName raw -
)"
[[ "${ACTUAL_VOLUME_NAME}" == "Mirage" ]] \
  || fail "DMG 卷名设置失败：${ACTUAL_VOLUME_NAME}"

# Finder 更新卷内容时会移除预置的卷图标，因此必须在布局写入后补回。
ditto "${VOLUME_ICON_SOURCE}" "${DMG_MOUNT_DIRECTORY}/.VolumeIcon.icns"
SetFile -a C "${DMG_MOUNT_DIRECTORY}"

hdiutil detach "${DMG_MOUNT_DEVICE}" >/dev/null
DMG_MOUNT_DEVICE=""
DMG_MOUNT_DIRECTORY=""

hdiutil convert \
  "${READ_WRITE_DMG_PATH}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "${WORK_DMG_PATH}" \
  >/dev/null

if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  # DMG 使用与导出 App 同团队的 Developer ID identity；没有证书时前置检查已失败。
  codesign \
    --force \
    --timestamp \
    --sign "${DEVELOPER_IDENTITY_HASH}" \
    "${WORK_DMG_PATH}"
  codesign --verify --verbose=2 "${WORK_DMG_PATH}"

  NOTARY_RESULT_PATH="${WORK_DIRECTORY}/notary-result.json"
  xcrun notarytool submit "${WORK_DMG_PATH}" \
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    --wait \
    --output-format json \
    > "${NOTARY_RESULT_PATH}"

  NOTARY_STATUS="$(plutil -extract status raw "${NOTARY_RESULT_PATH}")"
  NOTARY_SUBMISSION_ID="$(plutil -extract id raw "${NOTARY_RESULT_PATH}")"
  [[ "${NOTARY_STATUS}" == "Accepted" ]] \
    || fail "公证未通过，submission ${NOTARY_SUBMISSION_ID} 状态：${NOTARY_STATUS}"

  xcrun stapler staple "${WORK_DMG_PATH}"
  xcrun stapler validate "${WORK_DMG_PATH}"

  # 正式产物必须同时通过容器签名、App 签名和 Gatekeeper 校验。
  codesign --verify --verbose=2 "${WORK_DMG_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  spctl --assess --type execute --verbose=2 "${APP_PATH}"
  spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "${WORK_DMG_PATH}"

  print "公证已接受：${NOTARY_SUBMISSION_ID}"
else
  print "development 模式仅供本机验证；DMG 不会进行 Developer ID 签名或公证。"
fi

# 对最终字节执行磁盘镜像校验；全部通过后才发布到 dist。
hdiutil verify "${WORK_DMG_PATH}"
mv -f -- "${WORK_DMG_PATH}" "${DMG_PATH}"

(
  cd "${DIST_DIRECTORY}"
  shasum -a 256 "${DMG_FILENAME}" > "${SHA256_FILENAME}"
)

print "DMG 已生成：${DMG_PATH}"
print "SHA-256 已生成：${SHA256_PATH}"

if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  APPCAST_PATH="${DIST_DIRECTORY}/appcast.xml"
  "${SCRIPT_DIRECTORY}/generate_appcast.sh" \
    "${DMG_PATH}" \
    "v${MARKETING_VERSION}" \
    "${APPCAST_PATH}"
  print "Sparkle appcast 已生成：${APPCAST_PATH}"
fi
