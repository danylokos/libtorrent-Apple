#!/bin/bash

set -e
set -o pipefail

PROJ_DIR=$(pwd)
BUILD_DIR="$PROJ_DIR/build"
DIST_DIR="$PROJ_DIR/dist"

LIBTORRENT_VER=1.2.17
BOOST_VER=1.69.0

LIBTORRENT_DIST="$DIST_DIR/libtorrent-$LIBTORRENT_VER"
BOOST_DIST="$DIST_DIR/boost-$BOOST_VER"

MIN_MACOS_VER=10.14
MIN_IOS_VER=12.0
MIN_TVOS_VER=12.0

clean() {
  echo "[*] cleaning build results..."
  rm -rf "$BUILD_DIR/"
}

download() {
  echo "[*] cleaning downloads..."
  rm -rf "$DIST_DIR/"

  LIBTORRENT_TARBALL="$DIST_DIR/libtorrent-$LIBTORRENT_VER.tar.gz"
  BOOST_TARBALL="$DIST_DIR/boost-$BOOST_VER.tar.gz"

  echo "[*] downloading libtorrent..."
  curl -L -o "$LIBTORRENT_TARBALL" --create-dirs \
    "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VER/libtorrent-rasterbar-$LIBTORRENT_VER.tar.gz"

  mkdir -p "$LIBTORRENT_DIST"
  echo "[*] extracting libtorrent..."
  tar -xzf "$LIBTORRENT_TARBALL" --strip 1 -C "$LIBTORRENT_DIST"


  echo "[*] downloading boost..."
  BOOST_VER_FIX=$(echo $BOOST_VER | sed -r "s/\./_/g")
  curl -L -o "$BOOST_TARBALL" --create-dirs \
    "https://boostorg.jfrog.io/artifactory/main/release/$BOOST_VER/source/boost_$BOOST_VER_FIX.tar.gz"

  echo "[*] extracting boost..."
  mkdir -p "$BOOST_DIST"
  tar -xzf "$BOOST_TARBALL" --strip 1 -C "$BOOST_DIST"
}

build_target() {
  sdk=$1
  target=$2
  arch=$3
  cflags=$3

  regex="^(.+)-apple"
  if [[ $target =~ $regex ]]; then
    arch="${BASH_REMATCH[1]}"
  else
    echo "[E] $target doesn't match" >&2
    exit 1
  fi

  SDK_ROOT=$(xcrun --sdk $sdk --show-sdk-path)
  # echo "[+] [$sdk.$arch] SDK_ROOT: $SDK_ROOT"
  CFLAGS="$cflags \
    -target $target \
    -I$LIBTORRENT_DIST/include \
    -I$BOOST_DIST \
    -std=gnu++14 \
    -stdlib=libc++ \
    -Wno-deprecated-declarations"
  CC="xcrun --sdk $sdk clang --sysroot=$SDK_ROOT $CFLAGS"

  TARGET_BUILD_DIR="$BUILD_DIR/$sdk/$arch"
  OBJS_DIR="$TARGET_BUILD_DIR/objs"
  mkdir -p "$OBJS_DIR"
  
  cd "$LIBTORRENT_DIST/"
  LIBTORRENT_SRCS=$(find src ed25519/src -name "*.cpp" | sort)
  echo "[*] [$sdk.$arch] compiling sources..."
  for file in ${LIBTORRENT_SRCS[@]}; do
    # echo "    [*] [$sdk.$arch] compiling $file..."
    basefile=$(basename -- $file)
    $CC -c $file -o $OBJS_DIR/${basefile%.*}.o
  done

  # echo "[*] [$sdk.$arch] generating FileList..."
  FILE_LIST="$TARGET_BUILD_DIR/objs/libtorrent.LinkFileList"
  echo -n "$(ls $TARGET_BUILD_DIR/objs/*.o)" > "$FILE_LIST"

  TARGET_LIB_DIR="$TARGET_BUILD_DIR/lib"
  mkdir -p "$TARGET_LIB_DIR"

  LIB_FILE="$TARGET_BUILD_DIR/lib/libtorrent.a"

  echo "[*] [$sdk.$arch] creating library..."
  xcrun --sdk $sdk libtool \
    -no_warning_for_no_symbols \
    -static \
    -syslibroot "$SDK_ROOT" \
    -filelist "$FILE_LIST" \
    -o "$LIB_FILE"

  echo "[+] [$sdk.$arch] libary saved at path: $LIB_FILE"
}

create_fat_lib() {
  sdk=$1

  SDK_BUILD_DIR="$BUILD_DIR/$sdk"
  FAT_BUILD_DIR="$SDK_BUILD_DIR/fat"
  mkdir -p "$FAT_BUILD_DIR"

  FAT_LIB_PATH="$FAT_BUILD_DIR/libtorrent.a"
  LIBS=($(ls $SDK_BUILD_DIR/*/lib/libtorrent.a))

  echo "[*] [$sdk] creating fat library..."
  xcrun --sdk $sdk lipo -create \
    -output "$FAT_LIB_PATH" \
    ${LIBS[@]}
  
  echo "[+] [$sdk] fat library saved at at path: $FAT_LIB_PATH"
}

build_targets() {
  sdk=$1
  targets=$2
  cflags=$3

  for target in ${targets[@]}; do
    build_target $sdk $target $cflags
  done

  create_fat_lib $sdk
}

targets_for_sys() {
  sys=$1

  echo $(for arch in x86_64 arm64; do echo "$arch-apple-$sys"; done)
}

build_macos() {
  sdk="macosx"
  targets=($(targets_for_sys "macos$MIN_MACOS_VER"))
  cflags=""

  build_targets $sdk $targets $cflags
}

build_ios() {
  sdk="iphoneos"
  targets=(arm64-apple-ios$MIN_IOS_VER)
  cflags="-fembed-bitcode"

  build_targets $sdk $targets $cflags
}

build_ios_sim() {
  sdk="iphonesimulator"
  targets=($(targets_for_sys "ios$MIN_IOS_VER-simulator"))
  cflags="-fembed-bitcode"

  build_targets $sdk $targets $cflags
}

build_tvos() {
  sdk="appletvos"
  targets=(arm64-apple-tvos$MIN_TVOS_VER)
  cflags="-fembed-bitcode"

  build_targets $sdk $targets $cflags
}

build_tvos_sim() {
  sdk="appletvsimulator"
  targets=($(targets_for_sys "tvos$MIN_TVOS_VER-simulator"))
  cflags="-fembed-bitcode"

  build_targets $sdk $targets $cflags
}

create_xcframework() {
  lib_params=()
  all_libs=$(echo -n $(ls $BUILD_DIR/*/fat/libtorrent.a))
  for lib in ${all_libs[@]}; do
    lib_params+=("-library "$lib" -headers $LIBTORRENT_DIST/include")
  done

  echo "[*] creating libtorrent.xcframework..."
  xcodebuild \
    -create-xcframework \
    -output "$BUILD_DIR/libtorrent.xcframework" \
    ${lib_params[@]}

  echo "[*] compressing libtorrent.xcframework..."
  cd "$BUILD_DIR"
  zip -r -q "libtorrent.xcframework.zip" \
    "libtorrent.xcframework"
}

if [[ $# > 0 ]]; then
  if [[ $1 == "-v" ]]; then
    echo $LIBTORRENT_VER
    exit 0
  fi
fi

clean
download
build_macos
build_ios
build_ios_sim
build_tvos
build_tvos_sim
create_xcframework

echo "[+] done."
