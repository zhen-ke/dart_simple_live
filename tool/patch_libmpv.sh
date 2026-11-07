#!/usr/bin/env bash
# 在 flutter pub get 之后、pod install 之前执行：
# 把 media_kit_libs_macos_video 的 libmpv 下载地址从上游
# (mpv 0.36.0 / ffmpeg 6.0) 换到本仓库 Release 自产资产
# (mpv 0.40.0 / ffmpeg 7.1.5，由 build_libmpv.yml 产出)。
#
# 用法：
#   bash tool/patch_libmpv.sh
#
# 环境变量：
#   GH_REPO      资产所在仓库。生产值见 build_macos.yml
#                （当前：ister-app/libmpv-darwin-build，mpv 0.41.0 /
#                ffmpeg 9.0.1 预编译）；
#                自产备份：GH_REPO=zhen-ke/dart_simple_live
#                LIBMPV_TAG=libmpv_v0.8.0（先跑 build_libmpv.yml）
#   LIBMPV_TAG   release tag（默认 v0.8.4）
#
# tool/libmpv/xcframework.sha256 存在时同时替换 Makefile 的校验值；
# 不存在则移除校验行（自产资产，靠 HTTPS 完整性）。首次构建完成后
# 可把 sha256 写回该文件以恢复校验。

set -euo pipefail

PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}"
PKG_DIR=$(find "$PUB_CACHE_DIR/hosted" -maxdepth 3 -type d \
  -name 'media_kit_libs_macos_video-*' 2>/dev/null | sort -V | tail -1)

if [ -z "$PKG_DIR" ]; then
  echo "error: media_kit_libs_macos_video not found in pub cache; run 'flutter pub get' first" >&2
  exit 1
fi

MAKEFILE="$PKG_DIR/macos/Makefile"
GH_REPO="${GH_REPO:-ister-app/libmpv-darwin-build}"
LIBMPV_TAG="${LIBMPV_TAG:-v0.8.4}"
VERSION="${LIBMPV_TAG#libmpv_}"
ASSET="libmpv-xcframeworks_${VERSION}_macos-universal-video-default.tar.gz"
URL="https://github.com/${GH_REPO}/releases/download/${LIBMPV_TAG}/${ASSET}"
SHA_FILE="$(cd "$(dirname "$0")" && pwd)/libmpv/xcframework.sha256"

# 版本号（用于缓存文件名）与下载地址
sed -i '' -E \
  -e "s|^MPV_XCFRAMEWORKS_VERSION=.*|MPV_XCFRAMEWORKS_VERSION=${VERSION}|" \
  -e "s|media-kit/libmpv-darwin-build/releases/download/\\\$\{MPV_XCFRAMEWORKS_VERSION\}|${GH_REPO}/releases/download/${LIBMPV_TAG}|" \
  -e "s|libmpv-xcframeworks_\\\$\{MPV_XCFRAMEWORKS_VERSION\}_macos-universal-video-default|libmpv-xcframeworks_${VERSION}_macos-universal-video-default|" \
  "$MAKEFILE"

if [ -f "$SHA_FILE" ]; then
  SHA=$(tr -d ' \n' < "$SHA_FILE")
  sed -i '' -E "s|^MPV_XCFRAMEWORKS_SHA256SUM=.*|MPV_XCFRAMEWORKS_SHA256SUM=${SHA}|" "$MAKEFILE"
else
  sed -i '' -E 's|^.*shasum -a 256.*$|\techo "note: skip libmpv sha256 check (self-built asset)"|' "$MAKEFILE"
fi

echo "patched: $MAKEFILE"
echo "    url: $URL"
grep -n "MPV_XCFRAMEWORKS_VERSION\|releases/download" "$MAKEFILE"
