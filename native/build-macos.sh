#!/bin/bash
#
# libre + baresip 를 macOS(arm64) 용 정적 라이브러리로 빌드한다.
#
#   ./build-macos.sh
#
# 결과: macos/lib/{libre.a,libbaresip.a,libwebrtc-audio-processing.a,
#                  libssl.a,libcrypto.a,libopus.a}
#       macos/include/{re,baresip.h}
#
# 소스는 third_party/ 에 받는다(git 에 넣지 않는다). 결과물은 git 에 넣는다 — 앱을
# 빌드할 때마다 스택을 다시 빌드하지 않게.
#
# 의존 라이브러리(OpenSSL·Opus·webrtc-audio-processing)도 모두 소스에서
# MIN_MACOS 로 빌드한다. Homebrew 의 .a 는 빌드한 기계의 macOS 버전을 최소
# 버전으로 달고 나와 더 낮은 macOS 에서 앱이 뜨지 않는다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/third_party"
OUT="$HERE/macos"

VERSION=v4.11.0
MIN_MACOS=12.0

# OpenSSL 은 LTS 줄(3.5)을 쓴다. 받은 파일은 SHA-256 으로 확인한다.
OPENSSL_VERSION=3.5.8
OPENSSL_SHA256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
OPENSSL="$SRC/openssl-prefix"

OPUS_VERSION=v1.6.1
OPUS="$SRC/opus-prefix"

# 에코 제거(webrtc_aec)가 쓰는 WebRTC 오디오 처리 라이브러리. baresip 은 1.x
# (webrtc-audio-processing-1) 를 찾는다.
WEBRTC_AP_VERSION=v1.3
AEC="$SRC/aec-prefix"

# 음성 통화에 필요한 것만. 영상 모듈은 다음 단계에서 붙인다.
MODULES="g711;opus;audiounit;auconv;auresamp;webrtc_aec;stun;turn;ice;srtp;dtls_srtp"

log() { printf '\n=== %s\n' "$*"; }

fetch() {
  local name="$1"
  if [ ! -d "$SRC/$name" ]; then
    git clone -q --depth 1 -b "$VERSION" "https://github.com/baresip/$name.git" "$SRC/$name"
  fi
}

mkdir -p "$SRC"
fetch re
fetch baresip
if [ ! -d "$SRC/webrtc-ap" ]; then
  git clone -q --depth 1 -b "$WEBRTC_AP_VERSION" \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$SRC/webrtc-ap"
fi

# meson 은 시스템에 깔지 않고 여기 가상 환경에 둔다.
if [ ! -x "$SRC/.venv/bin/meson" ]; then
  python3 -m venv "$SRC/.venv"
  "$SRC/.venv/bin/pip" install -q meson
fi

COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DOPENSSL_ROOT_DIR="$OPENSSL"
  -DOPENSSL_USE_STATIC_LIBS=TRUE
)

log "OpenSSL $OPENSSL_VERSION"
if [ ! -f "$OPENSSL/lib/libcrypto.a" ]; then
  tarball="$SRC/openssl-$OPENSSL_VERSION.tar.gz"
  url="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION"
  [ -f "$tarball" ] || curl -fsSL -o "$tarball" "$url/openssl-$OPENSSL_VERSION.tar.gz"
  expected="${OPENSSL_SHA256:-$(curl -fsSL "$url/openssl-$OPENSSL_VERSION.tar.gz.sha256" | awk '{print $1}')}"
  echo "$expected  $tarball" | shasum -a 256 -c -
  rm -rf "$SRC/openssl-$OPENSSL_VERSION"
  tar -xzf "$tarball" -C "$SRC"
  (
    cd "$SRC/openssl-$OPENSSL_VERSION"
    ./Configure darwin64-arm64-cc no-shared no-tests no-docs \
      -mmacosx-version-min="$MIN_MACOS" --prefix="$OPENSSL" --libdir=lib \
      > "$SRC/openssl-configure.log"
    make -j"$(sysctl -n hw.ncpu)" build_libs > "$SRC/openssl-build.log"
    make install_dev > "$SRC/openssl-install.log"
  )
fi

log "Opus $OPUS_VERSION"
if [ ! -f "$OPUS/lib/libopus.a" ]; then
  [ -d "$SRC/opus" ] || git clone -q --depth 1 -b "$OPUS_VERSION" \
    https://github.com/xiph/opus.git "$SRC/opus"
  cmake -S "$SRC/opus" -B "$SRC/opus/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
    -DCMAKE_INSTALL_PREFIX="$OPUS" > "$SRC/opus-build.log"
  cmake --build "$SRC/opus/build" -j --target install >> "$SRC/opus-build.log"
fi

log "webrtc-audio-processing"
# abseil 까지 정적으로 묶여 libwebrtc-audio-processing-1.a 하나로 나온다.
(
  export PATH="$SRC/.venv/bin:$PATH" MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  cd "$SRC/webrtc-ap"
  [ -d build ] || meson setup build --buildtype=release \
    -Ddefault_library=static --force-fallback-for=abseil-cpp \
    -Dprefix="$AEC" \
    -Dc_args="-mmacosx-version-min=$MIN_MACOS" \
    -Dcpp_args="-mmacosx-version-min=$MIN_MACOS"
  meson install -C build >/dev/null
)

log "libre"
cmake -S "$SRC/re" -B "$SRC/re/build" "${COMMON[@]}" \
  -DLIBRE_BUILD_SHARED=OFF -DLIBRE_BUILD_STATIC=ON \
  -DUSE_OPENSSL=ON -DUSE_RTMP=OFF -DUSE_BFCP=OFF
cmake --build "$SRC/re/build" -j

log "baresip"
cmake -S "$SRC/baresip" -B "$SRC/baresip/build" "${COMMON[@]}" \
  -DSTATIC=ON -DMODULES="$MODULES" \
  -DCMAKE_PREFIX_PATH="$OPUS" \
  -DWEBRTC_AEC_INCLUDE_DIRS="$AEC/include/webrtc-audio-processing-1" \
  -DWEBRTC_AEC_LIBRARY_DIRS="$AEC/lib" \
  -DCMAKE_CXX_FLAGS="-DWEBRTC_POSIX -DWEBRTC_MAC -I$AEC/include" \
  -DRE_INCLUDE_DIR="$SRC/re/include" \
  -DRE_LIBRARY="$SRC/re/build/libre.a"
cmake --build "$SRC/baresip/build" -j --target baresip

log "모으기"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp "$SRC/re/build/libre.a" "$OUT/lib/"
# 모듈은 OBJECT 라이브러리라 libbaresip.a 에 함께 들어 있다(static.c 가 목록).
cp "$SRC/baresip/build/libbaresip.a" "$OUT/lib/"
cp "$AEC/lib/libwebrtc-audio-processing-1.a" "$OUT/lib/libwebrtc-audio-processing.a"
cp "$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" "$OPUS/lib/libopus.a" "$OUT/lib/"
cp -R "$SRC/re/include" "$OUT/include/re"
cp "$SRC/baresip/include/baresip.h" "$OUT/include/"
cp "$SRC/re/LICENSE" "$OUT/LICENSE.libre"
cp "$SRC/baresip/LICENSE" "$OUT/LICENSE.baresip"
cp "$SRC/webrtc-ap/COPYING" "$OUT/LICENSE.webrtc-audio-processing"
cp "$SRC/openssl-$OPENSSL_VERSION/LICENSE.txt" "$OUT/LICENSE.openssl"
cp "$SRC/opus/COPYING" "$OUT/LICENSE.opus"

# 모든 .a 가 MIN_MACOS 로 빌드됐는지 확인한다.
bad=$(for a in "$OUT"/lib/*.a; do
  otool -l "$a" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}'
done | sort -u | grep -vx "$MIN_MACOS" || true)
if [ -n "$bad" ]; then
  echo "최소 macOS 가 $MIN_MACOS 가 아닌 객체가 있다: $bad" >&2
  exit 1
fi
ls -lh "$OUT/lib"
