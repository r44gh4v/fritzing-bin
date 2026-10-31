#!/usr/bin/env bash
# Builds Fritzing (https://github.com/fritzing/fritzing-app) on Linux or macOS.
# Counterpart of build.ps1 (Windows); keep dependency versions and pins in sync with it.
#
# usage: bash build.sh <linux|macos> [fritzing-app ref] [platform id, used in file names]
#   ref: empty or "stable" = newest X.Y.Z release, "develop", or any fritzing-app branch/tag
# Expects Qt 6 (qmake on PATH), a C++ toolchain, cmake, git, curl, unzip, python3, and
# OpenSSL 3 + pkg-config (Linux: libssl-dev, macOS: brew openssl@3).
# Dependencies are placed as siblings of fritzing-app, as phoenix.pro's *.pri detect scripts expect.
# Folders that already exist are reused (the workflow caches them).
set -euo pipefail

OS="${1:?usage: build.sh <linux|macos> [ref] [platform-id]}"
REF="${2:-}"; REF="${REF:-stable}"
PLATFORM="${3:-$OS}"
ROOT="$(pwd)"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

for tool in qmake lrelease cmake git curl unzip tar make python3; do
  command -v "$tool" >/dev/null || { echo "'$tool' not found in PATH" >&2; exit 1; }
done

# --- helpers: retries, checksums, pinned clones ---
retry() { # retry <command...>: 3 attempts, growing pause
  local n
  for n in 1 2 3; do
    "$@" && return 0
    echo "attempt $n failed: $*" >&2; sleep $((n * 15))
  done
  return 1
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

fetch() { # fetch <file> <sha256> <url> [mirror urls...]: download and verify, trying each url
  local out="$1" sum="$2" url; shift 2
  [ -f "$out" ] && [ "$(sha256 "$out")" = "$sum" ] && return 0
  for url in "$@"; do
    if retry curl -fsSL --connect-timeout 30 -o "$out.part" "$url"; then
      if [ "$(sha256 "$out.part")" = "$sum" ]; then mv "$out.part" "$out"; return 0; fi
      echo "checksum mismatch for $url" >&2
    fi
  done
  rm -f "$out.part"; echo "could not download $out" >&2; return 1
}

clone_pinned() { # clone_pinned <dir> <tag> <commit> <url>: shallow clone, then make sure the tag was not moved
  [ -d "$1" ] && return 0
  retry sh -c 'rm -rf "$1.tmp" && git clone --quiet --depth 1 --branch "$2" "$3" "$1.tmp"' _ "$1" "$2" "$4"
  [ "$(git -C "$1.tmp" rev-parse HEAD)" = "$3" ] || { echo "$4 $2 is not commit $3" >&2; exit 1; }
  mv "$1.tmp" "$1"
}

SF=https://downloads.sourceforge.net/project
SF_MASTER=https://master.dl.sourceforge.net/project

# "stable" = newest X.Y.Z branch or tag; upstream keeps each 1.x release on a branch named after it
if [ "$REF" = stable ]; then
  REF="$(retry git ls-remote --heads --tags https://github.com/fritzing/fritzing-app.git | awk '{print $2}' \
    | grep -oE '^refs/(heads|tags)/[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#^refs/[a-z]*/##' | sort -V | tail -n1)"
  [ -n "$REF" ] || { echo "could not find the latest stable version" >&2; exit 1; }
fi

QT_VERSION="$(qmake -query QT_VERSION)"
QT_PREFIX="$(qmake -query QT_INSTALL_PREFIX)"
echo "Qt $QT_VERSION ($QT_PREFIX), building fritzing-app @ $REF for $PLATFORM"

# --- Boost 1.85 (headers only), version must be listed in pri/boostdetect.pri ---
if [ ! -d boost_1_85_0 ]; then
  fetch boost.tar.gz be0d91732d5b0cc6fbb275c7939974457e79b54d6f07ce2e3dfdd68bef883b0b \
    https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.gz \
    https://sourceforge.net/projects/boost/files/boost/1.85.0/boost_1_85_0.tar.gz/download
  tar xzf boost.tar.gz boost_1_85_0/boost
fi

# --- svgpp 1.3.1 (headers only) ---
clone_pinned svgpp-1.3.1 v1.3.1 fda1fd889548289178261d7aa02dd5d647247f94 https://github.com/svgpp/svgpp.git

# --- libgit2 1.7.1 (dynamic on Linux, static on macOS, as in pri/libgit2detect.pri) ---
if [ ! -d libgit2-1.7.1/lib ]; then
  clone_pinned libgit2-src v1.7.1 a2bde63741977ca0f4ef7db2f609df320be67a08 https://github.com/libgit2/libgit2.git
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
  fetch clipper.zip a14320d82194807c4480ce59c98aa71cd4175a5156645c4e2b3edd330b930627 \
    "$SF/polyclipping/clipper_ver6.4.2.zip" "$SF_MASTER/polyclipping/clipper_ver6.4.2.zip"
  rm -rf clipper-src && unzip -q clipper.zip -d clipper-src
  cmake -S clipper-src/cpp -B clipper-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_PREFIX="$ROOT/Clipper1-6.4.2"
  cmake --build clipper-build -j"$JOBS"
  cmake --install clipper-build
fi

# --- QuaZip 1.4 built against the same Qt (dir name is what pri/quazipdetect.pri expects) ---
QUAZIP_DIR="$ROOT/quazip-$QT_VERSION-1.4intuisphere"
if [ ! -d "$QUAZIP_DIR/lib" ]; then
  clone_pinned quazip-src v1.4 566fa496649b8cb09018b497575bb3bf2977965f https://github.com/stachenov/quazip.git
  cmake -S quazip-src -B quazip-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_FETCH_LIBS=ON -DQUAZIP_ENABLE_TESTS=OFF \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR" \
    -DCMAKE_INSTALL_RPATH="$QT_PREFIX/lib"  # macdeployqt resolves QuaZip's @rpath Qt links only through this
  cmake --build quazip-build -j"$JOBS"
  cmake --install quazip-build
fi

# --- ngspice 42 as a shared library (headers for the build, libngspice for runtime simulation) ---
if [ ! -d ngspice-42/lib ]; then
  fetch ngspice.tar.gz 737fe3846ab2333a250dfadf1ed6ebe1860af1d8a5ff5e7803c772cc4256e50a \
    "$SF/ngspice/ng-spice-rework/old-releases/42/ngspice-42.tar.gz" \
    "$SF_MASTER/ngspice/ng-spice-rework/old-releases/42/ngspice-42.tar.gz"
  rm -rf ngspice-src && mkdir ngspice-src && tar xzf ngspice.tar.gz -C ngspice-src --strip-components=1
  ( cd ngspice-src && ./configure --with-ngshared --without-x --with-readline=no --disable-debug --disable-openmp \
      --prefix="$ROOT/ngspice-42" && make -j"$JOBS" && make install )
fi

# --- fritzing-app and fritzing-parts ---
[ -d fritzing-app ] || retry sh -c 'rm -rf fritzing-app && git clone --quiet --filter=blob:none https://github.com/fritzing/fritzing-app.git fritzing-app'
retry git -C fritzing-app fetch --quiet --tags origin
git -C fritzing-app checkout --quiet --force "$REF"
# upstream pairs develop app builds with develop parts, everything else with master
PARTS_BRANCH=master; [ "$REF" = develop ] && PARTS_BRANCH=develop
[ -d fritzing-parts ] || retry sh -c 'rm -rf fritzing-parts && git clone --quiet --single-branch --branch "$1" https://github.com/fritzing/fritzing-parts.git fritzing-parts' _ "$PARTS_BRANCH"
VERSION="$REF"
[[ "$REF" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || VERSION="$(git -C fritzing-app describe --tags 2>/dev/null || echo "$REF")"

# --- build ---
QMAKE_EXTRA=()
# phoenix.pro asks for a universal x86_64+arm64 app; deps here are built for the host arch only
[ "$OS" = macos ] && QMAKE_EXTRA=(-after "QMAKE_APPLE_DEVICE_ARCHS=$(uname -m)")
# Qt's own ccache support (mkspecs/features/unix/ccache.prf), when ccache is installed
command -v ccache >/dev/null && QMAKE_EXTRA+=(CONFIG+=ccache)
# pri/gitversion.pri bakes the current time (to the second) into every compile command as BUILD_DATE,
# which makes every file a ccache miss. Like SOURCE_DATE_EPOCH, use the commit time instead:
# a `date` shim on PATH while qmake runs.
EPOCH="$(git -C fritzing-app log -1 --format=%ct)"
mkdir -p "$ROOT/date-shim"
if [ "$OS" = macos ]; then DATE_ARGS="-r $EPOCH"; else DATE_ARGS="-d @$EPOCH"; fi
printf '#!/bin/sh\nexec /bin/date %s "$@"\n' "$DATE_ARGS" > "$ROOT/date-shim/date"
chmod +x "$ROOT/date-shim/date"
(
  unset CI  # pri/gitversion.pri treats CI=true as a Travis build and makes a broken version string
  cd fritzing-app
  lrelease phoenix.pro  # translations/*.qm are not committed
  PATH="$ROOT/date-shim:$PATH" qmake -o Makefile phoenix.pro CONFIG+=release ${QMAKE_EXTRA[@]+"${QMAKE_EXTRA[@]}"}
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
    if [ -f "$APP/$f" ]; then cp "$APP/$f" "$1/"; fi
  done
  sed "s/@VERSION@/$VERSION/; s/@REF@/$REF/" "$ROOT/SOURCE.txt" > "$1/SOURCE.txt"
}

copy_resources() { # same set as upstream's release scripts
  for d in sketches translations help; do cp -R "$APP/$d" "$1/$d"; done
  rm -f "$1"/translations/*.ts
  find "$1/translations" -name '*.qm' -size -128c -delete
  # keep .git, as upstream does: building the parts database reads its commit (PartsChecker::getSha),
  # and the in-app parts update fetches and merges into it
  cp -R "$ROOT/fritzing-parts" "$1/fritzing-parts"
  license_files "$1"
}

# A copy of the parts with malformed XML repaired (see fix_parts_xml.py). Fritzing indexes this copy;
# the shipped fritzing-parts stays an unmodified clone, which the in-app parts update needs.
# parts.db stores paths relative to the parts folder, so the database works in the shipped folder.
fixed_parts_copy() { # $1 = shipped fritzing-parts; prints the copy's path
  local work; work="$(mktemp -d)"
  cp -R "$1" "$work/fritzing-parts"
  python3 -I "$ROOT/fix_parts_xml.py" "$work/fritzing-parts" >&2
  echo "$work/fritzing-parts"
}

# Smoke test + parts database, as upstream's release scripts do: the packaged app must start,
# index all parts and exit. Any missing library or plugin fails the build here, not on the user's PC.
build_parts_db() { # $1 = fritzing executable, $2 = release folder (empty: app finds it), $3 = parts to index, $4 = output db
  local db="$4" pid n status=0
  # Fritzing's own qDebug output into the log (default category only, not Qt's internals).
  # QT_PLUGIN_PATH from install-qt-action would load Qt's plugins instead of the bundled ones.
  env -u QT_PLUGIN_PATH QT_LOGGING_RULES='*.debug=false;default.debug=true' QT_FORCE_STDERR_LOGGING=1 \
    "$1" -db "$db" -pp "$3" ${2:+-f "$2"} &
  pid=$!
  for ((n = 0; n < 900; n++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    # still running after 15 minutes: show where it is stuck, then fail
    echo "Fritzing did not finish in 15 minutes; parts.db size: $(wc -c < "$db" 2>/dev/null || echo none)" >&2
    if command -v gdb >/dev/null; then
      sudo gdb -p "$pid" -batch -ex "thread apply all bt 25" 2>&1 | grep -E '^(Thread|#)' | head -150 >&2
    elif command -v lldb >/dev/null; then
      sudo lldb -p "$pid" --batch -o "thread backtrace all -c 25" 2>&1 | head -150 >&2
    fi
    kill -9 "$pid"
    exit 1
  fi
  wait "$pid" || status=$?
  [ "$status" -eq 0 ] || { echo "packaged Fritzing failed (exit code $status)" >&2; exit 1; }
  [ "$(wc -c < "$db")" -gt 1000000 ] || { echo "parts database is missing or too small" >&2; exit 1; }
}

if [ "$OS" = linux ]; then
  # same layout as upstream's tools/linux_release_script: binary + libs in lib/, launcher named Fritzing
  EXE="$APP/Fritzing"  # phoenix.pro sets no DESTDIR on Linux
  [ -f "$EXE" ] || { echo "Fritzing binary not found after build" >&2; exit 1; }
  D="$OUT/$NAME"; L="$D/lib"; mkdir -p "$L"
  cp "$EXE" "$L/Fritzing"  # stripped after the smoke test, so a stuck run gives a readable stack

  # Qt plugins are found next to the executable; then bundle every non-system library needed
  for p in platforms imageformats sqldrivers printsupport xcbglintegrations platforminputcontexts platformthemes iconengines tls; do
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
  # second pass picks up libs pulled in only by bundled libs (icu, etc.)
  find "$L" -maxdepth 1 -name '*.so*' | while read -r so; do bundle_libs "$so"; done
  # ngspice is dlopen()ed as libngspice.so from the executable's folder
  cp -L "$ROOT/ngspice-42/lib/libngspice.so" "$L/libngspice.so"

  # fail now if a bundled binary needs a library that is neither bundled nor part of the system
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
  strip "$L/Fritzing"

  # Turn the folder into an AppImage: one file that runs on most distros. The upstream launcher
  # already resolves its own folder, so it works as AppRun inside the mounted image.
  cp "$APP/Fritzing.sh" "$D/AppRun"; chmod +x "$D/AppRun"
  cp "$APP/resources/system_icons/linux/fritzing_icon.png" "$D/fritzing.png"  # desktop file: Icon=fritzing
  fetch appimagetool ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 \
    https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
  # pinned runtime; without --runtime-file appimagetool downloads the unpinned "continuous" one
  fetch appimage-runtime 2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d \
    https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
  chmod +x appimagetool
  ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 ./appimagetool --no-appstream --runtime-file appimage-runtime \
    "$D" "$OUT/$NAME.AppImage"
  chmod +x "$OUT/$NAME.AppImage"

  # smoke test the AppImage itself: it must start and index the parts
  SMOKE="$(mktemp -d)"
  ( export APPIMAGE_EXTRACT_AND_RUN=1 QT_QPA_PLATFORM=offscreen; cd "$SMOKE"
    build_parts_db "$OUT/$NAME.AppImage" "$D" "$PARTS_FIXED" "$SMOKE/parts.db" )
  rm -rf "$SMOKE" "$D" "$(dirname "$PARTS_FIXED")"

else # macos
  BUNDLE="$ROOT/release64/Fritzing.app"  # DESTDIR from phoenix.pro
  [ -d "$BUNDLE" ] || { echo "Fritzing.app not found after build" >&2; exit 1; }
  D="$OUT/$NAME"; mkdir -p "$D"
  cp -R "$BUNDLE" "$D/Fritzing.app"
  # Data goes to Contents/Resources, which Fritzing searches on macOS (FolderUtils::applicationDirPath).
  # Contents/MacOS may hold only code: codesign rejects folders such as fritzing-parts/.git there.
  S="$D/Fritzing.app/Contents/Resources"
  copy_resources "$S"
  # ngspice is dlopen()ed from the executable's folder
  cp -L "$ROOT/ngspice-42/lib/libngspice.0.dylib" "$D/Fritzing.app/Contents/MacOS/"

  macdeployqt "$D/Fritzing.app" -libpath="$QT_PREFIX/lib" -libpath="$QUAZIP_DIR/lib" -libpath="$ROOT/ngspice-42/lib"
  # Fritzing only uses SQLite; the other SQL drivers need client libraries that are not bundled
  find "$D/Fritzing.app/Contents/PlugIns/sqldrivers" -type f ! -name 'libqsqlite.dylib' -delete
  # as upstream: with the normal (cocoa) platform; runners have a GUI session
  PARTS_FIXED="$(fixed_parts_copy "$S/fritzing-parts")"
  # no -f: the app must find Contents/Resources by itself, as it will on the user's Mac
  build_parts_db "$D/Fritzing.app/Contents/MacOS/Fritzing" "" "$PARTS_FIXED" "$S/fritzing-parts/parts.db"
  rm -rf "$(dirname "$PARTS_FIXED")"
  # unsigned arm64 binaries do not launch at all; an ad-hoc signature fixes that
  codesign --force --deep --sign - "$D/Fritzing.app"
  codesign --verify --deep --strict "$D/Fritzing.app"
  ditto -c -k --keepParent "$D/Fritzing.app" "$OUT/$NAME.zip" && rm -rf "$D"
fi

echo "FRITZING_VERSION=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
ls -lh "$OUT"
