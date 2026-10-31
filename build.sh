#!/usr/bin/env bash
# Builds Fritzing (https://github.com/fritzing/fritzing-app) on Linux or macOS.
# Counterpart of build.ps1 (Windows). Versions come from fritzing_versions.py.
#
# usage: bash build.sh <linux|macos> [fritzing-app ref] [platform id] [version label]
#   ref: empty or "stable" = newest release, "develop", or any fritzing-app branch, tag or commit
# Expects Qt 6 (qmake on PATH), a C++ toolchain, cmake, git, curl, unzip, python3, and
# OpenSSL 3 + pkg-config on Linux.
# Dependencies go next to fritzing-app, where its *.pri files look for them. Existing folders are reused.
set -euo pipefail

OS="${1:?usage: build.sh <linux|macos> [ref] [platform-id] [version]}"
REF="${2:-}"
PLATFORM="${3:-$OS}"
VERSION="${4:-}"
ROOT="$(pwd)"
WORK="$ROOT/_work"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
mkdir -p "$WORK"

for tool in qmake lrelease cmake git curl unzip tar make python3; do
  command -v "$tool" >/dev/null || { echo "'$tool' not found in PATH" >&2; exit 1; }
done

retry() { # 3 attempts
  local n
  for n in 1 2 3; do
    "$@" && return 0
    echo "attempt $n failed: $*" >&2; sleep $((n * 15))
  done
  return 1
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

fetch() { # <file> <sha256 or empty> <url> [mirror...]
  local out="$WORK/$1" sum="$2" url; shift 2
  [ -f "$out" ] && { [ -z "$sum" ] || [ "$(sha256 "$out")" = "$sum" ]; } && return 0
  [ -n "$sum" ] || echo "WARNING: no known checksum for $(basename "$out"); not verified" >&2
  for url in "$@"; do
    if curl -fsSL --retry 3 --retry-delay 10 --connect-timeout 30 -o "$out.part" "$url"; then
      if [ -z "$sum" ] || [ "$(sha256 "$out.part")" = "$sum" ]; then mv "$out.part" "$out"; return 0; fi
      echo "checksum mismatch for $url" >&2
    fi
  done
  rm -f "$out.part"; echo "could not download $(basename "$out")" >&2; return 1
}

clone_pinned() { # <dir> <tag> <commit or empty> <url>: fails if the tag was moved
  [ -d "$1" ] && return 0
  retry sh -c 'rm -rf "$1.tmp" && git clone --quiet --depth 1 --branch "$2" "$3" "$1.tmp"' _ "$1" "$2" "$4"
  if [ -z "$3" ]; then echo "WARNING: no known commit for $4 $2; not verified" >&2
  elif [ "$(git -C "$1.tmp" rev-parse HEAD)" != "$3" ]; then echo "$4 $2 is not commit $3" >&2; exit 1; fi
  mv "$1.tmp" "$1"
}

SF=https://downloads.sourceforge.net/project
SF_MASTER=https://master.dl.sourceforge.net/project

# --- Fritzing source, then the versions it needs ---
[ -d fritzing-app ] || retry sh -c 'rm -rf fritzing-app && git clone --quiet --filter=blob:none https://github.com/fritzing/fritzing-app.git fritzing-app'
retry git -C fritzing-app fetch --quiet --tags origin
eval "$(python3 -I "$ROOT/fritzing_versions.py" resolve fritzing-app "$REF")"
VERSION="${4:-$VERSION}"
git -C fritzing-app checkout --quiet --force "$REF"
eval "$(python3 -I "$ROOT/fritzing_versions.py" deps fritzing-app)"

QT_VERSION="$(qmake -query QT_VERSION)"
QT_PREFIX="$(qmake -query QT_INSTALL_PREFIX)"
python3 -c "import sys; v=lambda s: tuple(map(int, s.split('.'))); sys.exit(not v('$QT_LEAST') <= v('$QT_VERSION') <= v('$QT_MOST'))" \
  || { echo "Fritzing $VERSION needs Qt $QT_LEAST to $QT_MOST, found $QT_VERSION" >&2; exit 1; }
echo "Fritzing $VERSION ($REF) with Qt $QT_VERSION for $PLATFORM"

CMAKE_COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_LIBDIR=lib)
if [ "$OS" = macos ]; then
  # one universal app for Intel and Apple Silicon; the oldest macOS is the one Qt supports
  MACOSX_DEPLOYMENT_TARGET="$(otool -l "$QT_PREFIX/lib/QtCore.framework/QtCore" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="minos"{print $2; exit}')"
  [ -n "$MACOSX_DEPLOYMENT_TARGET" ] || MACOSX_DEPLOYMENT_TARGET="$(grep -rhs '^ *QMAKE_MACOSX_DEPLOYMENT_TARGET *=' "$QT_PREFIX/mkspecs" | head -n1 | sed 's/.*= *//')"
  [ -n "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "cannot read Qt's minimum macOS version" >&2; exit 1; }
  export MACOSX_DEPLOYMENT_TARGET
  CMAKE_COMMON+=("-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
fi

# --- dependencies ---
BOOST_DIR="boost_1_${BOOST}_0"
if [ ! -d "$BOOST_DIR" ]; then
  fetch boost.tar.gz "$BOOST_SHA_TARGZ" \
    "https://archives.boost.io/release/1.$BOOST.0/source/$BOOST_DIR.tar.gz" \
    "https://sourceforge.net/projects/boost/files/boost/1.$BOOST.0/$BOOST_DIR.tar.gz/download"
  tar xzf "$WORK/boost.tar.gz" "$BOOST_DIR/boost"
fi

clone_pinned "svgpp-$SVGPP" "v$SVGPP" "$SVGPP_COMMIT" https://github.com/svgpp/svgpp.git

# libgit2: dynamic on Linux, static on macOS, as pri/libgit2detect.pri expects
if [ ! -d "libgit2-$LIBGIT2/lib" ]; then
  clone_pinned "$WORK/libgit2-src" "v$LIBGIT2" "$LIBGIT2_COMMIT" https://github.com/libgit2/libgit2.git
  if [ "$OS" = macos ]; then LG_SHARED=OFF; LG_HTTPS=SecureTransport; else LG_SHARED=ON; LG_HTTPS=OpenSSL; fi
  cmake -S "$WORK/libgit2-src" -B "$WORK/libgit2-build" "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=$LG_SHARED \
    -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_HTTPS=$LG_HTTPS -DUSE_SSH=OFF -DUSE_GSSAPI=OFF -DREGEX_BACKEND=builtin \
    -DCMAKE_INSTALL_PREFIX="$ROOT/libgit2-$LIBGIT2"
  cmake --build "$WORK/libgit2-build" -j"$JOBS"
  cmake --install "$WORK/libgit2-build"
fi

if [ ! -d "Clipper1-$CLIPPER/lib" ]; then
  fetch clipper.zip "$CLIPPER_SHA" \
    "$SF/polyclipping/clipper_ver$CLIPPER.zip" "$SF_MASTER/polyclipping/clipper_ver$CLIPPER.zip"
  rm -rf "$WORK/clipper-src" && unzip -q "$WORK/clipper.zip" -d "$WORK/clipper-src"
  cmake -S "$WORK/clipper-src/cpp" -B "$WORK/clipper-build" "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$ROOT/Clipper1-$CLIPPER"
  cmake --build "$WORK/clipper-build" -j"$JOBS"
  cmake --install "$WORK/clipper-build"
fi

QUAZIP_DIR="$ROOT/${QUAZIP_DIR/@QT@/$QT_VERSION}"
if [ ! -d "$QUAZIP_DIR/lib" ]; then
  clone_pinned "$WORK/quazip-src" "v$QUAZIP" "$QUAZIP_COMMIT" https://github.com/stachenov/quazip.git
  cmake -S "$WORK/quazip-src" -B "$WORK/quazip-build" "${CMAKE_COMMON[@]}" \
    -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_FETCH_LIBS=ON -DQUAZIP_ENABLE_TESTS=OFF \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR" \
    -DCMAKE_INSTALL_RPATH="$QT_PREFIX/lib"  # lets macdeployqt find QtCore5Compat
  cmake --build "$WORK/quazip-build" -j"$JOBS"
  cmake --install "$WORK/quazip-build"
fi

# ngspice: shared library for the simulator
if [ ! -d "ngspice-$NGSPICE/lib" ]; then
  fetch ngspice.tar.gz "$NGSPICE_SHA_TARGZ" \
    "$SF/ngspice/ng-spice-rework/$NGSPICE/ngspice-$NGSPICE.tar.gz" \
    "$SF/ngspice/ng-spice-rework/old-releases/$NGSPICE/ngspice-$NGSPICE.tar.gz" \
    "$SF_MASTER/ngspice/ng-spice-rework/old-releases/$NGSPICE/ngspice-$NGSPICE.tar.gz"
  rm -rf "$WORK/ngspice-src" && mkdir "$WORK/ngspice-src"
  tar xzf "$WORK/ngspice.tar.gz" -C "$WORK/ngspice-src" --strip-components=1
  NG_FLAGS=(); [ "$OS" = macos ] && NG_FLAGS=(--disable-dependency-tracking \
    "CFLAGS=-O2 -arch arm64 -arch x86_64" "CXXFLAGS=-O2 -arch arm64 -arch x86_64 -Wno-invalid-specialization" "LDFLAGS=-arch arm64 -arch x86_64")
  ( cd "$WORK/ngspice-src" && ./configure --with-ngshared --without-x --with-readline=no --disable-debug \
      --disable-openmp --prefix="$ROOT/ngspice-$NGSPICE" ${NG_FLAGS[@]+"${NG_FLAGS[@]}"} \
      && make -j"$JOBS" && make install )
fi

# Parts: the current library (develop), as upstream releases and distribution packages ship it.
# Full clone with .git: the parts database and the in-app parts check use it.
[ -d fritzing-parts ] || retry sh -c 'rm -rf fritzing-parts && git clone --quiet --single-branch --branch develop https://github.com/fritzing/fritzing-parts.git fritzing-parts'

# --- build ---
QMAKE_EXTRA=()
command -v ccache >/dev/null && QMAKE_EXTRA+=(CONFIG+=ccache)
# Xcode 26 rejects Qt's qyieldcpu.h (__yield builtin used without a declaration); a warning is enough
[ "$OS" = macos ] && QMAKE_EXTRA+=("QMAKE_CXXFLAGS+=-Wno-error=implicit-function-declaration")
# pri/gitversion.pri puts the current time into every compile command (BUILD_DATE), so ccache
# never hits. A `date` shim returns the commit time instead, like SOURCE_DATE_EPOCH.
EPOCH="$(git -C fritzing-app log -1 --format=%ct)"
mkdir -p "$WORK/date-shim"
if [ "$OS" = macos ]; then DATE_ARGS="-r $EPOCH"; else DATE_ARGS="-d @$EPOCH"; fi
printf '#!/bin/sh\nexec /bin/date %s "$@"\n' "$DATE_ARGS" > "$WORK/date-shim/date"
chmod +x "$WORK/date-shim/date"
(
  unset CI  # pri/gitversion.pri treats CI=true as Travis and makes a broken version string
  cd fritzing-app
  lrelease phoenix.pro  # the .qm translation files are not committed
  PATH="$WORK/date-shim:$PATH" qmake -o Makefile phoenix.pro CONFIG+=release ${QMAKE_EXTRA[@]+"${QMAKE_EXTRA[@]}"}
  make -j"$JOBS" release  # phoenix.pro is debug_and_release
)

APP="$ROOT/fritzing-app"
NAME="fritzing-$VERSION-$PLATFORM"
OUT="$ROOT/github"
rm -rf "$OUT" && mkdir -p "$OUT"
export LD_LIBRARY_PATH="$QT_PREFIX/lib:$QUAZIP_DIR/lib:$ROOT/libgit2-$LIBGIT2/lib:$ROOT/ngspice-$NGSPICE/lib:${LD_LIBRARY_PATH:-}"

license_files() {
  for f in README.md INSTALL.txt LICENSE.GPL2 LICENSE.GPL3 LICENSE.LGPLv3 LICENSE.CC-BY-SA \
           LICENSE.Modified_BSD LICENSE_1_0.txt.BOOST license-openssl-ssleay.txt; do
    if [ -f "$APP/$f" ]; then cp "$APP/$f" "$1/"; fi
  done
  sed "s/@VERSION@/$VERSION/; s/@REF@/$REF/" "$ROOT/SOURCE.txt" > "$1/SOURCE.txt"
}

copy_resources() { # same set as upstream's release scripts
  for d in sketches translations help; do cp -R "$APP/$d" "$1/$d"; done
  rm -f "$1"/translations/*.ts
  find "$1/translations" -name '*.qm' -size -128c -delete
  cp -R "$ROOT/fritzing-parts" "$1/fritzing-parts"
  license_files "$1"
}

# Fritzing indexes a copy of the parts with malformed XML repaired (see fix_parts_xml.py).
# The shipped fritzing-parts stays an unmodified clone. parts.db stores relative paths.
fixed_parts_copy() { # $1 = shipped fritzing-parts; prints the copy's path
  local work; work="$(mktemp -d)"
  cp -R "$1" "$work/fritzing-parts"
  python3 -I "$ROOT/fix_parts_xml.py" "$work/fritzing-parts" >&2
  echo "$work/fritzing-parts"
}

# Builds the parts database with the packaged app, as upstream's release scripts do. This is also
# the smoke test: a missing library or plugin fails the build here, not on the user's computer.
build_parts_db() { # $1 = executable, $2 = data folder (empty: app finds it), $3 = parts to index, $4 = output db
  local pid n status=0
  # QT_PLUGIN_PATH from install-qt-action would load Qt's plugins instead of the bundled ones
  env -u QT_PLUGIN_PATH ${LAUNCH[@]+"${LAUNCH[@]}"} "$1" -db "$4" -pp "$3" ${2:+-f "$2"} &
  pid=$!
  for ((n = 0; n < 900; n++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid"; echo "Fritzing did not finish the parts database in 15 minutes" >&2; exit 1
  fi
  wait "$pid" || status=$?
  [ "$status" -eq 0 ] || { echo "packaged Fritzing failed (exit code $status)" >&2; exit 1; }
  [ "$(wc -c < "$4")" -gt 1000000 ] || { echo "parts database is missing or too small" >&2; exit 1; }
}

if [ "$OS" = linux ]; then
  # layout of upstream's Linux release: binary and libraries in lib/, launcher named Fritzing
  EXE="$APP/Fritzing"  # phoenix.pro sets no DESTDIR on Linux
  [ -f "$EXE" ] || { echo "Fritzing binary not found after build" >&2; exit 1; }
  D="$OUT/$NAME"; L="$D/lib"; mkdir -p "$L"
  cp "$EXE" "$L/Fritzing"; strip "$L/Fritzing"

  # Qt plugins next to the executable, then every non-system library they need
  for p in platforms imageformats sqldrivers printsupport xcbglintegrations platforminputcontexts platformthemes iconengines tls wayland-shell-integration wayland-decoration-client wayland-graphics-integration-client; do
    if [ -d "$QT_PREFIX/plugins/$p" ]; then cp -r "$QT_PREFIX/plugins/$p" "$L/"; fi
  done
  # Fritzing only uses SQLite; the other SQL drivers need client libraries that are not bundled
  find "$L/sqldrivers" -type f ! -name 'libqsqlite.so' -delete
  bundle_libs() {
    ldd "$1" 2>/dev/null | awk '/=> \//{print $3}' | while read -r lib; do
      case "$lib" in "$QT_PREFIX"/*|"$ROOT"/*) [ -e "$L/$(basename "$lib")" ] || cp -L "$lib" "$L/" ;; esac
    done
  }
  bundle_libs "$L/Fritzing"
  find "$L" -mindepth 2 -name '*.so' | while read -r so; do bundle_libs "$so"; done
  # second pass: libraries needed only by bundled libraries (ICU)
  find "$L" -maxdepth 1 -name '*.so*' | while read -r so; do bundle_libs "$so"; done
  # ngspice is dlopen()ed as libngspice.so from the executable's folder
  cp -L "$ROOT/ngspice-$NGSPICE/lib/libngspice.so" "$L/libngspice.so"

  MISSING="$(find "$L" -type f \( -name Fritzing -o -name '*.so*' \) -exec sh -c \
    'LD_LIBRARY_PATH="$1" ldd "$2" 2>/dev/null | grep "not found" | sed "s#^#$2: #"' _ "$L" {} \;)"
  [ -z "$MISSING" ] || { echo "missing libraries in package:" >&2; echo "$MISSING" >&2; exit 1; }

  copy_resources "$D"
  cp "$APP/Fritzing.sh" "$D/Fritzing"; chmod +x "$D/Fritzing"
  cp "$APP/Fritzing.1" "$APP/org.fritzing.Fritzing.desktop" "$APP/org.fritzing.Fritzing.appdata.xml" "$D/"
  mkdir -p "$D/icons" && cp "$APP"/resources/system_icons/linux/* "$D/icons/"
  PARTS_FIXED="$(fixed_parts_copy "$D/fritzing-parts")"
  ( export LD_LIBRARY_PATH="$L" QT_QPA_PLATFORM=offscreen
    build_parts_db "$L/Fritzing" "$D" "$PARTS_FIXED" "$D/fritzing-parts/parts.db" )

  # AppImage: the upstream launcher works as AppRun
  cp "$APP/Fritzing.sh" "$D/AppRun"; chmod +x "$D/AppRun"
  cp "$APP/resources/system_icons/linux/fritzing_icon.png" "$D/fritzing.png"  # desktop file: Icon=fritzing
  fetch appimagetool ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 \
    https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
  # without --runtime-file, appimagetool downloads an unpinned runtime
  fetch appimage-runtime 2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d \
    https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
  chmod +x "$WORK/appimagetool"
  ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$WORK/appimagetool" --no-appstream --runtime-file "$WORK/appimage-runtime" \
    "$D" "$OUT/$NAME.AppImage"
  chmod +x "$OUT/$NAME.AppImage"

  SMOKE="$(mktemp -d)"
  ( export APPIMAGE_EXTRACT_AND_RUN=1 QT_QPA_PLATFORM=offscreen; cd "$SMOKE"
    build_parts_db "$OUT/$NAME.AppImage" "$D" "$PARTS_FIXED" "$SMOKE/parts.db" )
  rm -rf "$SMOKE" "$D" "$(dirname "$PARTS_FIXED")"

else # macos
  BUNDLE="$ROOT/release64/Fritzing.app"  # DESTDIR from phoenix.pro
  [ -d "$BUNDLE" ] || { echo "Fritzing.app not found after build" >&2; exit 1; }
  D="$OUT/$NAME"; mkdir -p "$D"
  cp -R "$BUNDLE" "$D/Fritzing.app"
  # data in Contents/Resources (Fritzing looks there); codesign allows only code in Contents/MacOS
  S="$D/Fritzing.app/Contents/Resources"
  copy_resources "$S"
  # Fritzing loads ngspice from the executable's folder
  cp -L "$ROOT/ngspice-$NGSPICE/lib/libngspice.0.dylib" "$D/Fritzing.app/Contents/MacOS/"

  macdeployqt "$D/Fritzing.app" -libpath="$QT_PREFIX/lib" -libpath="$QUAZIP_DIR/lib" -libpath="$ROOT/ngspice-$NGSPICE/lib"
  # Fritzing only uses SQLite; the other SQL drivers need client libraries that are not bundled
  find "$D/Fritzing.app/Contents/PlugIns/sqldrivers" -type f ! -name 'libqsqlite.dylib' -delete

  # every binary in the app must contain both Intel and Apple Silicon code
  # a function, not inline: macOS bash 3.2 misparses `case` inside $( )
  thin_binaries() {
    find "$D/Fritzing.app" -type f \( -perm -u+x -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' f; do
      local a; a="$(lipo -archs "$f" 2>/dev/null || true)"
      [ -n "$a" ] || continue  # not a Mach-O file
      case " $a " in
        *" x86_64 "*" arm64 "* | *" arm64 "*" x86_64 "*) ;;
        *) echo "$f: $a" ;;
      esac
    done
  }
  THIN="$(thin_binaries)"
  [ -z "$THIN" ] || { echo "binaries without both architectures:" >&2; echo "$THIN" >&2; exit 1; }

  PARTS_FIXED="$(fixed_parts_copy "$S/fritzing-parts")"
  # no data folder argument: the app must find Contents/Resources by itself
  build_parts_db "$D/Fritzing.app/Contents/MacOS/Fritzing" "" "$PARTS_FIXED" "$S/fritzing-parts/parts.db"
  # the Intel code too, through Rosetta, when the build machine has it
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    X86_DB="$(mktemp -d)"
    LAUNCH=(arch -x86_64)
    build_parts_db "$D/Fritzing.app/Contents/MacOS/Fritzing" "" "$PARTS_FIXED" "$X86_DB/parts.db"
    LAUNCH=()
    rm -rf "$X86_DB"
  else
    echo "WARNING: no Rosetta on this machine; the Intel code was not started" >&2
  fi
  rm -rf "$(dirname "$PARTS_FIXED")"
  # Apple Silicon does not start unsigned code; an ad-hoc signature is enough
  codesign --force --deep --sign - "$D/Fritzing.app"
  codesign --verify --deep --strict "$D/Fritzing.app"
  ditto -c -k --keepParent "$D/Fritzing.app" "$OUT/$NAME.zip" && rm -rf "$D"
fi

echo "FRITZING_VERSION=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
ls -lh "$OUT"
