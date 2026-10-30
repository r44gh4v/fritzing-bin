#!/usr/bin/env bash
# Builds Fritzing (https://github.com/fritzing/fritzing-app) on Linux or macOS.
# Counterpart of build.ps1 (Windows); keep dependency versions in sync with it.
#
# usage: ./build.sh <linux|macos> [fritzing-app ref] [platform id, used in file names]
# Expects Qt 6 (qmake on PATH), a C++ toolchain, cmake, git, curl, unzip, and
# OpenSSL 3 + pkg-config (Linux: libssl-dev, macOS: brew openssl@3).
# Dependencies are placed as siblings of fritzing-app, as phoenix.pro's *.pri detect scripts expect.
set -euo pipefail

OS="${1:?usage: build.sh <linux|macos> [ref] [platform-id]}"
REF="${2:-}"; REF="${REF:-stable}"
PLATFORM="${3:-$OS}"
ROOT="$(pwd)"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

for tool in qmake lrelease cmake git curl unzip tar make; do
  command -v "$tool" >/dev/null || { echo "'$tool' not found in PATH" >&2; exit 1; }
done

# "stable" = newest X.Y.Z branch or tag; upstream keeps each 1.x release on a branch named after it
if [ "$REF" = stable ]; then
  REF="$(git ls-remote --heads --tags https://github.com/fritzing/fritzing-app.git | awk '{print $2}' \
    | grep -oE '^refs/(heads|tags)/[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#^refs/[a-z]*/##' | sort -V | tail -n1)"
  [ -n "$REF" ] || { echo "could not find the latest stable version" >&2; exit 1; }
fi

QT_VERSION="$(qmake -query QT_VERSION)"
QT_PREFIX="$(qmake -query QT_INSTALL_PREFIX)"
echo "Qt $QT_VERSION ($QT_PREFIX), building fritzing-app @ $REF for $PLATFORM"

fetch() { [ -f "$2" ] || curl -fsSL --retry 5 -o "$2" "$1"; }

# --- Boost (headers only), version must be listed in pri/boostdetect.pri ---
if [ ! -d boost_1_85_0 ]; then
  fetch https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.gz boost.tar.gz
  tar xzf boost.tar.gz
fi

# --- svgpp 1.3.1 (headers only) ---
[ -d svgpp-1.3.1 ] || git clone --quiet --depth 1 --branch v1.3.1 https://github.com/svgpp/svgpp.git svgpp-1.3.1

# --- libgit2 1.7.1 (dynamic on Linux, static on macOS, as in pri/libgit2detect.pri) ---
if [ ! -d libgit2-1.7.1/lib ]; then
  [ -d libgit2-src ] || git clone --quiet --depth 1 --branch v1.7.1 https://github.com/libgit2/libgit2.git libgit2-src
  if [ "$OS" = macos ]; then LG_SHARED=OFF; LG_HTTPS=SecureTransport; else LG_SHARED=ON; LG_HTTPS=OpenSSL; fi
  cmake -S libgit2-src -B libgit2-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=$LG_SHARED -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_HTTPS=$LG_HTTPS -DUSE_SSH=OFF -DUSE_GSSAPI=OFF \
    -DREGEX_BACKEND=builtin -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_PREFIX="$ROOT/libgit2-1.7.1"
  cmake --build libgit2-build -j"$JOBS"
  cmake --install libgit2-build
fi

# --- Clipper1 6.4.2 (polyclipping), static ---
if [ ! -d Clipper1-6.4.2/lib ]; then
  fetch https://downloads.sourceforge.net/project/polyclipping/clipper_ver6.4.2.zip clipper.zip
  unzip -q -o clipper.zip -d clipper-src
  cmake -S clipper-src/cpp -B clipper-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_PREFIX="$ROOT/Clipper1-6.4.2"
  cmake --build clipper-build -j"$JOBS"
  cmake --install clipper-build
fi

# --- QuaZip 1.4 built against the same Qt (dir name is what pri/quazipdetect.pri expects) ---
QUAZIP_DIR="$ROOT/quazip-$QT_VERSION-1.4intuisphere"
if [ ! -d "$QUAZIP_DIR/lib" ]; then
  [ -d quazip-src ] || git clone --quiet --depth 1 --branch v1.4 https://github.com/stachenov/quazip.git quazip-src
  cmake -S quazip-src -B quazip-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_FETCH_LIBS=ON -DQUAZIP_ENABLE_TESTS=OFF \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR"
  cmake --build quazip-build -j"$JOBS"
  cmake --install quazip-build
fi

# --- ngspice 42 as a shared library (headers for the build, libngspice for runtime simulation) ---
if [ ! -d ngspice-42/lib ]; then
  fetch https://downloads.sourceforge.net/project/ngspice/ng-spice-rework/old-releases/42/ngspice-42.tar.gz ngspice.tar.gz
  mkdir -p ngspice-src && tar xzf ngspice.tar.gz -C ngspice-src --strip-components=1
  ( cd ngspice-src && ./configure --with-ngshared --without-x --with-readline=no --disable-debug --disable-openmp \
      --prefix="$ROOT/ngspice-42" && make -j"$JOBS" && make install )
fi

# --- fritzing-app and fritzing-parts ---
[ -d fritzing-app ] || git clone --quiet https://github.com/fritzing/fritzing-app.git fritzing-app
git -C fritzing-app fetch --quiet --tags origin
git -C fritzing-app checkout --quiet --force "$REF"
# upstream pairs develop app builds with develop parts, everything else with master
PARTS_BRANCH=master; [ "$REF" = develop ] && PARTS_BRANCH=develop
[ -d fritzing-parts ] || git clone --quiet --depth 1 --branch "$PARTS_BRANCH" https://github.com/fritzing/fritzing-parts.git fritzing-parts
VERSION="$REF"
[[ "$REF" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || VERSION="$(git -C fritzing-app describe --tags 2>/dev/null || echo "$REF")"

# --- build ---
QMAKE_EXTRA=()
# phoenix.pro asks for a universal x86_64+arm64 app; deps here are built for the host arch only
[ "$OS" = macos ] && QMAKE_EXTRA=(-after "QMAKE_APPLE_DEVICE_ARCHS=$(uname -m)")
(
  unset CI  # pri/gitversion.pri treats CI=true as a Travis build and makes a broken version string
  cd fritzing-app
  lrelease phoenix.pro  # translations/*.qm are not committed
  qmake -o Makefile phoenix.pro CONFIG+=release "${QMAKE_EXTRA[@]}"
  make -j"$JOBS" release  # phoenix.pro is debug_and_release
)

# --- package ---
APP="$ROOT/fritzing-app"
NAME="fritzing-$VERSION-$PLATFORM"
OUT="$ROOT/github"
rm -rf "$OUT" && mkdir -p "$OUT"
export LD_LIBRARY_PATH="$QT_PREFIX/lib:$QUAZIP_DIR/lib:$ROOT/libgit2-1.7.1/lib:$ROOT/ngspice-42/lib:${LD_LIBRARY_PATH:-}"

license_files() {
  for f in README.md INSTALL.txt LICENSE.GPL2 LICENSE.GPL3 LICENSE.LGPLv3 LICENSE.CC-BY-SA \
           LICENSE.Modified_BSD LICENSE_1_0.txt.BOOST license-openssl-ssleay.txt; do
    [ -f "$APP/$f" ] && cp "$APP/$f" "$1/"
  done
  sed "s/@VERSION@/$VERSION/; s/@REF@/$REF/" "$ROOT/SOURCE.txt" > "$1/SOURCE.txt"
}

build_parts_db() { # $1 = fritzing executable, $2 = release folder (holds fritzing-parts, sketches, ...)
  # perl alarm = portable 10 minute timeout (macOS has no `timeout`)
  perl -e 'alarm shift; exec @ARGV' 600 "$1" -db "$2/fritzing-parts/parts.db" -pp "$2/fritzing-parts" -f "$2" \
    && [ -f "$2/fritzing-parts/parts.db" ] \
    || echo "WARNING: could not pre-build parts.db; Fritzing will build it on first start"
}

copy_resources() { # same set as upstream's release scripts
  for d in sketches translations help; do cp -R "$APP/$d" "$1/$d"; done
  rm -f "$1"/translations/*.ts
  find "$1/translations" -name '*.qm' -size -128c -delete
  cp -R "$ROOT/fritzing-parts" "$1/fritzing-parts"; rm -rf "$1/fritzing-parts/.git"
  license_files "$1"
}

if [ "$OS" = linux ]; then
  # same layout as upstream's tools/linux_release_script: binary + libs in lib/, launcher named Fritzing
  EXE="$APP/Fritzing"  # phoenix.pro sets no DESTDIR on Linux
  [ -f "$EXE" ] || { echo "Fritzing binary not found after build" >&2; exit 1; }
  D="$OUT/$NAME"; L="$D/lib"; mkdir -p "$L"
  cp "$EXE" "$L/Fritzing"; strip "$L/Fritzing"

  # Qt plugins are found next to the executable; then bundle every non-system library needed
  for p in platforms imageformats sqldrivers printsupport xcbglintegrations platforminputcontexts platformthemes iconengines tls; do
    [ -d "$QT_PREFIX/plugins/$p" ] && cp -r "$QT_PREFIX/plugins/$p" "$L/"
  done
  bundle_libs() {
    ldd "$1" 2>/dev/null | awk '/=> \//{print $3}' | while read -r lib; do
      case "$lib" in "$QT_PREFIX"/*|"$ROOT"/*) [ -e "$L/$(basename "$lib")" ] || cp -L "$lib" "$L/" ;; esac
    done
  }
  bundle_libs "$L/Fritzing"
  find "$L" -mindepth 2 -name '*.so' | while read -r so; do bundle_libs "$so"; done
  # second pass picks up libs pulled in only by bundled libs (icu, etc.)
  find "$L" -maxdepth 1 -name '*.so*' | while read -r so; do bundle_libs "$so"; done
  # ngspice is dlopen()ed as libngspice.so from the executable's folder
  cp -L "$ROOT/ngspice-42/lib/libngspice.so" "$L/libngspice.so"

  copy_resources "$D"
  cp "$APP/Fritzing.sh" "$D/Fritzing"; chmod +x "$D/Fritzing"
  cp "$APP/Fritzing.1" "$APP/org.fritzing.Fritzing.desktop" "$APP/org.fritzing.Fritzing.appdata.xml" "$D/"
  mkdir -p "$D/icons" && cp "$APP"/resources/system_icons/linux/* "$D/icons/"
  ( export LD_LIBRARY_PATH="$L" QT_QPA_PLATFORM=offscreen; build_parts_db "$L/Fritzing" "$D" )
  # tar keeps the executable bits that a plain artifact zip would drop
  tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME" && rm -rf "$D"

else # macos
  BUNDLE="$(find "$ROOT/release64" -maxdepth 1 -name Fritzing.app | head -n1)"
  [ -n "$BUNDLE" ] || { echo "Fritzing.app not found after build" >&2; exit 1; }
  D="$OUT/$NAME"; mkdir -p "$D"
  cp -R "$BUNDLE" "$D/Fritzing.app"
  S="$D/Fritzing.app/Contents/MacOS"  # upstream ships resources inside Contents/MacOS
  copy_resources "$S"
  cp -L "$ROOT"/ngspice-42/lib/libngspice.0.dylib "$S/"

  macdeployqt "$D/Fritzing.app" -libpath="$QUAZIP_DIR/lib" -libpath="$ROOT/ngspice-42/lib"
  build_parts_db "$S/Fritzing" "$S"  # as upstream: with the normal (cocoa) platform; runners have a GUI session
  # unsigned arm64 binaries do not launch at all; an ad-hoc signature fixes that
  codesign --force --deep --sign - "$D/Fritzing.app"
  ditto -c -k --keepParent "$D/Fritzing.app" "$OUT/$NAME.zip" && rm -rf "$D"
fi

echo "FRITZING_VERSION=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
ls -lh "$OUT"
