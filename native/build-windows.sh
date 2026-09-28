#!/bin/bash
#
# libre + baresip 를 Windows(x64, MSVC) 용 정적 라이브러리로 빌드한다.
#
#   ./build-windows.sh
#
# Git Bash 에서 MSVC 환경(vcvars64)을 연 채로 돌린다. CI 에서는
# .github/workflows/baresip-windows.yml 이 돌리고 결과를 아티팩트로 올린다.
#
# 결과: windows/lib/{re-static,baresip,webrtc-audio-processing,libssl,libcrypto,opus}.lib
#       windows/include/{re,baresip.h}
#       windows/defines.txt   (C 경계를 libre 와 같은 매크로로 빌드하려고)
#
# 필요한 것: cmake, ninja, python(meson), Strawberry Perl(OpenSSL Configure).
# cl 옵션은 /D 대신 -D 로 쓴다 — Git Bash 가 /로 시작하는 인자를 경로로 바꾼다.
# 모두 MSVC 동적 CRT(/MD)로 맞춘다 — Flutter Windows 앱과 같아야 한다.
# baresip 의 C++ 는 webrtc_aec 뿐인데, 지정 초기화(C++20)를 쓴다. Clang 은
# 기본으로 받지만 MSVC 는 C++20 을 말해 줘야 한다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/third_party-windows"
OUT="$HERE/windows"

VERSION=v4.11.0

OPENSSL_VERSION=3.5.8
OPENSSL_SHA256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
OPENSSL="$SRC/openssl-prefix"

OPUS_VERSION=v1.6.1
OPUS="$SRC/opus-prefix"

WEBRTC_AP_VERSION=v1.3
AEC="$SRC/aec-prefix"

# 음성만. 영상(H.264)은 무엇으로 할지 정한 뒤 붙인다.
MODULES="g711;opus;wasapi;auconv;auresamp;webrtc_aec;stun;turn;ice;srtp;dtls_srtp"

# OpenSSL 의 Configure 는 MSYS perl 이 아니라 Strawberry Perl 이어야 한다.
PERL="${PERL:-/c/Strawberry/perl/bin/perl.exe}"

log() { printf '\n=== %s\n' "$*"; }
win() { cygpath -m "$1"; }

COMMON=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER=cl
  -DCMAKE_CXX_COMPILER=cl
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW
)

mkdir -p "$SRC"

fetch() {
  local name="$1"
  if [ ! -d "$SRC/$name" ]; then
    git clone -q --depth 1 -b "$VERSION" "https://github.com/baresip/$name.git" "$SRC/$name"
  fi
}
fetch re
fetch baresip

# macOS 와 같은 고침을 얹는다(해당 없는 파일이면 그대로 지나간다).
git -C "$SRC/baresip" checkout -q -- .
for p in "$HERE"/patches/baresip-*.patch; do
  git -C "$SRC/baresip" apply "$p"
done

log "Opus $OPUS_VERSION"
if [ ! -f "$OPUS/lib/opus.lib" ]; then
  [ -d "$SRC/opus" ] || git clone -q --depth 1 -b "$OPUS_VERSION" \
    https://github.com/xiph/opus.git "$SRC/opus"
  cmake -S "$SRC/opus" -B "$SRC/opus/build" "${COMMON[@]}" \
    -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
    -DCMAKE_INSTALL_PREFIX="$(win "$OPUS")"
  cmake --build "$SRC/opus/build" --target install
  cp "$SRC/opus/COPYING" "$OPUS/LICENSE"
fi

log "OpenSSL $OPENSSL_VERSION"
if [ ! -f "$OPENSSL/lib/libcrypto.lib" ]; then
  tarball="$SRC/openssl-$OPENSSL_VERSION.tar.gz"
  url="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION"
  [ -f "$tarball" ] || curl -fsSL -o "$tarball" "$url/openssl-$OPENSSL_VERSION.tar.gz"
  echo "$OPENSSL_SHA256  $tarball" | sha256sum -c -
  rm -rf "$SRC/openssl-$OPENSSL_VERSION"
  tar -xzf "$tarball" -C "$SRC"
  (
    cd "$SRC/openssl-$OPENSSL_VERSION"
    # no-asm: NASM 없이 빌드한다. 암호화는 TLS·DTLS 핸드셰이크와 SRTP 뿐이다.
    "$PERL" Configure VC-WIN64A no-shared no-asm no-tests no-docs \
      --prefix="$(win "$OPENSSL")" --openssldir="$(win "$OPENSSL")/ssl"
    nmake build_libs
    nmake install_dev
  )
  cp "$SRC/openssl-$OPENSSL_VERSION/LICENSE.txt" "$OPENSSL/LICENSE"
fi

log "webrtc-audio-processing $WEBRTC_AP_VERSION"
if [ ! -f "$AEC/lib/libwebrtc-audio-processing-1.a" ] && \
   [ ! -f "$AEC/lib/webrtc-audio-processing-1.lib" ]; then
  [ -d "$SRC/webrtc-ap" ] || git clone -q --depth 1 -b "$WEBRTC_AP_VERSION" \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$SRC/webrtc-ap"
  (
    # Git Bash 의 /usr/bin 에 GNU link 가 있어 meson 이 MSVC link.exe 대신
    # 그걸 집는다. 이 단계에서만 cl 이 있는 폴더를 앞에 둔다.
    export PATH="$(dirname "$(command -v cl)"):$PATH"
    cd "$SRC/webrtc-ap"
    meson setup build --buildtype=release -Ddefault_library=static \
      --force-fallback-for=abseil-cpp -Db_vscrt=md \
      --prefix="$(win "$AEC")"
    meson install -C build
  )
  # CI 캐시는 결과 폴더만 되살리므로 라이선스도 거기에 둔다.
  cp "$SRC/webrtc-ap/COPYING" "$AEC/LICENSE"
  cp "$SRC"/webrtc-ap/subprojects/abseil-cpp-*/LICENSE "$AEC/LICENSE.abseil"
fi
AEC_LIB="$(ls "$AEC"/lib/*webrtc-audio-processing-1.* | head -1)"

log "libre"
cmake -S "$SRC/re" -B "$SRC/re/build" "${COMMON[@]}" \
  -DLIBRE_BUILD_SHARED=OFF -DLIBRE_BUILD_STATIC=ON \
  -DUSE_OPENSSL=ON -DUSE_RTMP=OFF -DUSE_BFCP=OFF \
  -DOPENSSL_ROOT_DIR="$(win "$OPENSSL")" -DOPENSSL_USE_STATIC_LIBS=TRUE
cmake --build "$SRC/re/build"

log "baresip"
cmake -S "$SRC/baresip" -B "$SRC/baresip/build" "${COMMON[@]}" \
  -DSTATIC=ON -DMODULES="$MODULES" \
  -DCMAKE_PREFIX_PATH="$(win "$OPUS")" \
  -DOPENSSL_ROOT_DIR="$(win "$OPENSSL")" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DRE_INCLUDE_DIR="$(win "$SRC/re/include")" \
  -DRE_LIBRARY="$(win "$SRC/re/build/re-static.lib")" \
  -DWEBRTC_AEC_INCLUDE_DIRS="$(win "$AEC/include/webrtc-audio-processing-1")" \
  -DWEBRTC_AEC_LIBRARY_DIRS="$(win "$AEC/lib")" \
  -DCMAKE_CXX_FLAGS="-DWEBRTC_WIN -DNOMINMAX -I$(win "$AEC/include")" \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build "$SRC/baresip/build" --target baresip

log "모으기"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp "$SRC/re/build/re-static.lib" "$OUT/lib/"
cp "$SRC/baresip/build/baresip.lib" "$OUT/lib/"
cp "$AEC_LIB" "$OUT/lib/webrtc-audio-processing.lib"
cp "$OPENSSL/lib/libssl.lib" "$OPENSSL/lib/libcrypto.lib" "$OUT/lib/"
cp "$OPUS/lib/opus.lib" "$OUT/lib/"
cp -R "$SRC/re/include" "$OUT/include/re"
cp "$SRC/baresip/include/baresip.h" "$OUT/include/"

# baresip 을 빌드할 때 쓴 매크로(libre 의 RE_DEFINITIONS). 헤더의 구조체 배치가
# 여기에 달려 있으므로 C 경계(hook/build.dart)도 같은 값으로 빌드한다.
python - "$SRC/baresip/build/compile_commands.json" > "$OUT/defines.txt" <<'PY'
import json, re, sys
cmds = json.load(open(sys.argv[1]))
cmd = next(c["command"] for c in cmds if c["file"].replace("\\", "/").endswith("src/ua.c"))
seen = []
for d in re.findall(r'[-/]D(\S+)', cmd):
    d = d.strip('"')
    if d.split("=")[0] in ("VERSION", "VER_MAJOR", "VER_MINOR", "VER_PATCH",
                           "MOD_PATH", "SHARE_PATH", "ARCH", "OS", "STATIC"):
        continue
    if d not in seen:
        seen.append(d)
print("\n".join(seen))
PY

cp "$SRC/re/LICENSE" "$OUT/LICENSE.libre"
cp "$SRC/baresip/LICENSE" "$OUT/LICENSE.baresip"
cp "$AEC/LICENSE" "$OUT/LICENSE.webrtc-audio-processing"
cp "$AEC/LICENSE.abseil" "$OUT/LICENSE.abseil"
cp "$OPENSSL/LICENSE" "$OUT/LICENSE.openssl"
cp "$OPUS/LICENSE" "$OUT/LICENSE.opus"

ls -l "$OUT/lib"
cat "$OUT/defines.txt"
