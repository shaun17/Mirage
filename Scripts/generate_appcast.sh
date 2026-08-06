#!/bin/zsh

set -euo pipefail

fail() {
  print -u2 -- "错误：$*"
  exit 1
}

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
BUILD_TMP_DIRECTORY="${PROJECT_DIRECTORY}/build/tmp"
DEFAULT_SPARKLE_BIN_DIRECTORY="${PROJECT_DIRECTORY}/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

UPDATE_ARCHIVE="${1:-}"
RELEASE_TAG="${2:-}"
OUTPUT_PATH="${3:-${PROJECT_DIRECTORY}/dist/appcast.xml}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.wenren.Mirage}"
GENERATE_APPCAST_PATH="${SPARKLE_GENERATE_APPCAST:-${DEFAULT_SPARKLE_BIN_DIRECTORY}/generate_appcast}"
SIGN_UPDATE_PATH="${SPARKLE_SIGN_UPDATE:-${DEFAULT_SPARKLE_BIN_DIRECTORY}/sign_update}"

[[ -n "${UPDATE_ARCHIVE}" ]] \
  || fail "用法：${0:t} <Mirage.dmg> <v版本号> [appcast.xml 输出路径]"
[[ -f "${UPDATE_ARCHIVE}" ]] || fail "未找到更新安装包：${UPDATE_ARCHIVE}"
[[ "${RELEASE_TAG}" =~ '^v[0-9]+([.][0-9]+)*$' ]] \
  || fail "Release tag 必须为 v0.4.0 这样的格式：${RELEASE_TAG:-<空>}"
[[ -x "${GENERATE_APPCAST_PATH}" ]] \
  || fail "未找到 Sparkle generate_appcast，请先解析 Swift Package：${GENERATE_APPCAST_PATH}"
[[ -x "${SIGN_UPDATE_PATH}" ]] \
  || fail "未找到 Sparkle sign_update：${SIGN_UPDATE_PATH}"

for required_command in ditto mkdir mktemp xmllint; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || fail "缺少必要命令：${required_command}"
done

MARKETING_VERSION="${RELEASE_TAG#v}"
EXPECTED_ARCHIVE_NAME="Mirage-${MARKETING_VERSION}.dmg"
[[ "${UPDATE_ARCHIVE:t}" == "${EXPECTED_ARCHIVE_NAME}" ]] \
  || fail "安装包名称与 tag 不匹配，预期 ${EXPECTED_ARCHIVE_NAME}"

mkdir -p "${BUILD_TMP_DIRECTORY}"
WORK_DIRECTORY="$(mktemp -d "${BUILD_TMP_DIRECTORY}/mirage-appcast.XXXXXX")"

cleanup() {
  if [[ -n "${WORK_DIRECTORY:-}" && "${WORK_DIRECTORY}" == "${BUILD_TMP_DIRECTORY}/"* ]]; then
    rm -rf -- "${WORK_DIRECTORY}"
  fi
}
trap cleanup EXIT

ARCHIVE_COPY_PATH="${WORK_DIRECTORY}/${EXPECTED_ARCHIVE_NAME}"
WORK_APPCAST_PATH="${WORK_DIRECTORY}/appcast.xml"
ditto "${UPDATE_ARCHIVE}" "${ARCHIVE_COPY_PATH}"

GENERATE_ARGUMENTS=(
  --download-url-prefix "https://github.com/shaun17/Mirage/releases/download/${RELEASE_TAG}/"
  --link "https://mirage.wenmsg.fun"
  --full-release-notes-url "https://github.com/shaun17/Mirage/releases/tag/${RELEASE_TAG}"
  --maximum-versions 1
  --maximum-deltas 0
  -o "${WORK_APPCAST_PATH}"
)

if [[ -n "${SPARKLE_RELEASE_NOTES_PATH:-}" ]]; then
  [[ -f "${SPARKLE_RELEASE_NOTES_PATH}" ]] \
    || fail "未找到更新说明：${SPARKLE_RELEASE_NOTES_PATH}"
  case "${SPARKLE_RELEASE_NOTES_PATH:e:l}" in
    md|markdown|html|txt)
      ;;
    *)
      fail "更新说明只支持 md、markdown、html 或 txt"
      ;;
  esac

  RELEASE_NOTES_COPY_PATH="${WORK_DIRECTORY}/${EXPECTED_ARCHIVE_NAME:r}.${SPARKLE_RELEASE_NOTES_PATH:e:l}"
  ditto "${SPARKLE_RELEASE_NOTES_PATH}" "${RELEASE_NOTES_COPY_PATH}"
  GENERATE_ARGUMENTS+=(--embed-release-notes)
fi

run_with_sparkle_key() {
  local executable_path="$1"
  shift

  if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    print -rn -- "${SPARKLE_ED_PRIVATE_KEY}" \
      | "${executable_path}" --ed-key-file - "$@"
    return
  fi

  "${executable_path}" --account "${SPARKLE_KEY_ACCOUNT}" "$@"
}

run_with_sparkle_key \
  "${GENERATE_APPCAST_PATH}" \
  "${GENERATE_ARGUMENTS[@]}" \
  "${WORK_DIRECTORY}"

[[ -s "${WORK_APPCAST_PATH}" ]] || fail "Sparkle 未生成 appcast.xml"
xmllint --noout "${WORK_APPCAST_PATH}"

ED_SIGNATURE="$(xmllint --xpath \
  'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
  "${WORK_APPCAST_PATH}")"
[[ -n "${ED_SIGNATURE}" ]] || fail "appcast.xml 缺少更新安装包的 EdDSA 签名"

run_with_sparkle_key "${SIGN_UPDATE_PATH}" --verify "${ARCHIVE_COPY_PATH}" "${ED_SIGNATURE}"
run_with_sparkle_key "${SIGN_UPDATE_PATH}" --verify "${WORK_APPCAST_PATH}"

mkdir -p "${OUTPUT_PATH:h}"
ditto "${WORK_APPCAST_PATH}" "${OUTPUT_PATH}"
print "Sparkle appcast 已生成并验签：${OUTPUT_PATH}"
