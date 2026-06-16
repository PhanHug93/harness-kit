#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_VERSION="0.37.2"
PROVENANCE_FILE="${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v${RTK_VERSION}.sha256"

OS="$(uname -s)"
ARCH="$(uname -m)"
PLATFORM="${OS}-${ARCH}"

case "${PLATFORM}" in
  Darwin-arm64)
    ASSET="rtk-aarch64-apple-darwin.tar.gz"
    ;;
  Darwin-x86_64)
    ASSET="rtk-x86_64-apple-darwin.tar.gz"
    ;;
  Linux-aarch64)
    ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"
    ;;
  Linux-x86_64)
    ASSET="rtk-x86_64-unknown-linux-musl.tar.gz"
    ;;
  *)
    echo "Unsupported platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac

if [ ! -f "${PROVENANCE_FILE}" ]; then
  echo "Missing rtk provenance manifest: ${PROVENANCE_FILE}" >&2
  exit 1
fi
SHA256="$(awk -v asset="${ASSET}" '$2 == asset { print $1 }' "${PROVENANCE_FILE}" | head -n1)"
if [ -z "${SHA256}" ]; then
  echo "No checksum for ${ASSET} in ${PROVENANCE_FILE}" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${ASSET}"
INSTALL_DIR="${ROOT_DIR}/.tools/rtk/v${RTK_VERSION}"
ARCHIVE_PATH="${INSTALL_DIR}/${ASSET}"
BIN_PATH="${INSTALL_DIR}/rtk"
LINK_PATH="${ROOT_DIR}/.tools/bin/rtk"

mkdir -p "${INSTALL_DIR}" "${ROOT_DIR}/.tools/bin"
if command -v curl >/dev/null 2>&1; then
  curl -fL "${DOWNLOAD_URL}" -o "${ARCHIVE_PATH}"
elif command -v wget >/dev/null 2>&1; then
  wget -O "${ARCHIVE_PATH}" "${DOWNLOAD_URL}"
else
  echo "Need curl or wget to download rtk." >&2; exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
else
  echo "Need sha256sum or shasum to verify rtk." >&2; exit 1
fi
if [ "${ACTUAL_SHA256}" != "${SHA256}" ]; then
  echo "Checksum mismatch for ${ASSET}" >&2
  echo "Expected: ${SHA256}" >&2
  echo "Actual  : ${ACTUAL_SHA256}" >&2
  exit 1
fi

tar -xzf "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"
chmod +x "${BIN_PATH}"
ln -sfn "../rtk/v${RTK_VERSION}/rtk" "${LINK_PATH}"

echo "Installed pinned rtk v${RTK_VERSION} at ${BIN_PATH}"
"${BIN_PATH}" --version
