# Builds Fritzing (https://github.com/fritzing/fritzing-app) for 64-bit Windows.
# Expects: MSVC environment (cl.exe), Qt 6 on PATH (qmake.exe), cmake, git, 7z, curl.
# Dependencies are placed as siblings of fritzing-app, as phoenix.pro's *.pri detect scripts expect.
# Counterpart of build.sh (Linux/macOS); keep dependency versions in sync with it.
param(
  [string]$Ref = "",                 # git ref of fritzing-app to build (branch/tag), empty = develop
  [string]$Platform = "windows-x64"  # used in output names
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Run([scriptblock]$cmd) {
  & $cmd
  if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE): $cmd" }
}

$root = (Get-Location).Path
if (-not $Ref) { $Ref = "stable" }
# "stable" = newest X.Y.Z branch or tag; upstream keeps each 1.x release on a branch named after it
if ($Ref -eq "stable") {
  $Ref = git ls-remote --heads --tags https://github.com/fritzing/fritzing-app.git |
    ForEach-Object { if ($_ -match 'refs/(heads|tags)/(\d+\.\d+\.\d+)$') { $Matches[2] } } |
    Sort-Object { [version]$_ } | Select-Object -Last 1
  if (-not $Ref) { throw "could not find the latest stable version" }
}

foreach ($tool in "cl", "qmake", "lrelease", "cmake", "git", "7z", "curl") {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found in PATH" }
}

$qtVersion = (qmake -query QT_VERSION).Trim()
$qtPrefix = (qmake -query QT_INSTALL_PREFIX).Trim()
Write-Host "Qt $qtVersion, building fritzing-app @ $Ref"

function Fetch([string]$url, [string]$out) {
  if (-not (Test-Path $out)) { Run { curl.exe -fsSL --retry 5 -o $out $url } }
}

# --- Boost (headers only), version must be listed in pri/boostdetect.pri ---
if (-not (Test-Path "boost_1_85_0")) {
  Fetch "https://archives.boost.io/release/1.85.0/source/boost_1_85_0.7z" "boost.7z"
  Run { 7z x -y -bso0 boost.7z }
}

# --- svgpp 1.3.1 (headers only) ---
if (-not (Test-Path "svgpp-1.3.1")) {
  Run { git clone --quiet --depth 1 --branch v1.3.1 https://github.com/svgpp/svgpp.git svgpp-1.3.1 }
}

# --- libgit2 1.7.1, static (Windows uses the static variant) ---
if (-not (Test-Path "libgit2-1.7.1\lib\git2.lib")) {
  Run { git clone --quiet --depth 1 --branch v1.7.1 https://github.com/libgit2/libgit2.git libgit2-src }
  Run { cmake -G Ninja -S libgit2-src -B libgit2-build -DCMAKE_BUILD_TYPE=Release `
      -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF `
      -DUSE_HTTPS=WinHTTP -DUSE_SSH=OFF -DREGEX_BACKEND=builtin -DSTATIC_CRT=OFF `
      "-DCMAKE_INSTALL_PREFIX=$root\libgit2-1.7.1" }
  Run { cmake --build libgit2-build }
  Run { cmake --install libgit2-build }
}

# --- Clipper1 6.4.2 (polyclipping) ---
if (-not (Test-Path "Clipper1-6.4.2\lib")) {
  Fetch "https://downloads.sourceforge.net/project/polyclipping/clipper_ver6.4.2.zip" "clipper.zip"
  Run { 7z x -y -bso0 -oclipper-src clipper.zip }
  Run { cmake -G Ninja -S clipper-src\cpp -B clipper-build -DCMAKE_BUILD_TYPE=Release `
      -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$root\Clipper1-6.4.2" }
  Run { cmake --build clipper-build }
  Run { cmake --install clipper-build }
}

# --- zlib 1.3.1, static, for QuaZip (Windows has no system zlib) ---
if (-not (Test-Path "zlib\lib")) {
  Run { git clone --quiet --depth 1 --branch v1.3.1 https://github.com/madler/zlib.git zlib-src }
  Run { cmake -G Ninja -S zlib-src -B zlib-build -DCMAKE_BUILD_TYPE=Release `
      -DCMAKE_POLICY_VERSION_MINIMUM="3.5" "-DCMAKE_INSTALL_PREFIX=$root\zlib" }
  Run { cmake --build zlib-build }
  Run { cmake --install zlib-build }
}

# --- QuaZip 1.4 built against the same Qt (dir name is what pri/quazipdetect.pri expects) ---
$quazipDir = "$root\quazip-$qtVersion-1.4intuisphere"
if (-not (Test-Path "$quazipDir\lib")) {
  Run { git clone --quiet --depth 1 --branch v1.4 https://github.com/stachenov/quazip.git quazip-src }
  Run { cmake -G Ninja -S quazip-src -B quazip-build -DCMAKE_BUILD_TYPE=Release `
      -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_FETCH_LIBS=ON `
      "-DZLIB_ROOT=$root\zlib" -DZLIB_USE_STATIC_LIBS=ON `
      -DQUAZIP_ENABLE_TESTS=OFF "-DCMAKE_PREFIX_PATH=$qtPrefix" "-DCMAKE_INSTALL_PREFIX=$quazipDir" }
  Run { cmake --build quazip-build }
  Run { cmake --install quazip-build }
}

# --- ngspice 42: prebuilt shared library (headers for the build, ngspice.dll for runtime) ---
if (-not (Test-Path "ngspice-42\include")) {
  Fetch "https://downloads.sourceforge.net/project/ngspice/ng-spice-rework/old-releases/42/ngspice-42_dll_64.7z" "ngspice.7z"
  Run { 7z x -y -bso0 -ongspice-tmp ngspice.7z }
  $dllRoot = (Get-ChildItem ngspice-tmp -Directory | Select-Object -First 1).FullName
  New-Item -ItemType Directory ngspice-42 | Out-Null
  Copy-Item "$dllRoot\include" ngspice-42\include -Recurse
  Copy-Item "$dllRoot\bin" ngspice-42\bin -Recurse
}

# --- fritzing-app and fritzing-parts ---
if (-not (Test-Path "fritzing-app")) {
  Run { git clone --quiet https://github.com/fritzing/fritzing-app.git fritzing-app }
}
Run { git -C fritzing-app fetch --quiet --tags origin }
Run { git -C fritzing-app checkout --quiet --force $Ref }
# upstream pairs develop app builds with develop parts, everything else with master
$partsBranch = if ($Ref -eq "develop") { "develop" } else { "master" }
if (-not (Test-Path "fritzing-parts")) {
  Run { git clone --quiet --depth 1 --branch $partsBranch https://github.com/fritzing/fritzing-parts.git fritzing-parts }
}
$version = $Ref
if ($Ref -notmatch '^\d+\.\d+\.\d+$') {
  $version = (git -C fritzing-app describe --tags 2>$null)
  if (-not $version) { $version = $Ref }
  $version = $version.Trim()
}

# --- build ---
# pri/gitversion.pri shells out to `git describe`; fritzing-app's .git is a sibling dir, so it works as-is.
Push-Location fritzing-app
Run { lrelease phoenix.pro }  # translations/*.qm are not committed
Run { qmake -o Makefile phoenix.pro "CONFIG+=release" }
Run { nmake release }
Pop-Location

$exe = Get-Item "$root\release64\Fritzing.exe" -ErrorAction SilentlyContinue  # DESTDIR from phoenix.pro
if (-not $exe) { throw "Fritzing.exe not found after build" }

# --- package ---
$out = "$root\github\fritzing-$version-$Platform"
if (Test-Path "$root\github") { Remove-Item "$root\github" -Recurse -Force }
New-Item -ItemType Directory $out | Out-Null
Copy-Item $exe.FullName $out
Run { windeployqt --release --compiler-runtime --no-translations "$out\Fritzing.exe" }

Copy-Item "$quazipDir\lib\*.dll" $out -ErrorAction SilentlyContinue
Copy-Item "$root\ngspice-42\bin\*.dll" $out -ErrorAction SilentlyContinue
if (Test-Path "$out\ngspice.dll") { } elseif (Test-Path "$out\libngspice-0.dll") { Copy-Item "$out\libngspice-0.dll" "$out\ngspice.dll" }

$app = "$root\fritzing-app"
foreach ($d in "sketches", "translations", "help") { Copy-Item "$app\$d" "$out\$d" -Recurse }
Remove-Item "$out\translations\*.ts"
Get-ChildItem "$out\translations\*.qm" | Where-Object { $_.Length -lt 128 } | Remove-Item  # empty translations
Copy-Item "$root\fritzing-parts" "$out\fritzing-parts" -Recurse
Remove-Item "$out\fritzing-parts\.git" -Recurse -Force -ErrorAction SilentlyContinue
foreach ($f in "README.md", "INSTALL.txt", "LICENSE.GPL2", "LICENSE.GPL3", "LICENSE.LGPLv3", "LICENSE.CC-BY-SA",
               "LICENSE.Modified_BSD", "LICENSE_1_0.txt.BOOST", "license-openssl-ssleay.txt") {
  if (Test-Path "$app\$f") { Copy-Item "$app\$f" $out }
}
(Get-Content "$root\SOURCE.txt" -Raw).Replace("@VERSION@", $version).Replace("@REF@", $Ref) |
  Set-Content "$out\SOURCE.txt"

# Pre-build the parts database, as the upstream release script does.
$env:QT_QPA_PLATFORM = "offscreen"
& "$out\Fritzing.exe" -db "$out\fritzing-parts\parts.db" -pp "$out\fritzing-parts" -f "$out"
if ($LASTEXITCODE -ne 0) { Write-Warning "could not pre-build parts.db; Fritzing will build it on first start" }

"FRITZING_VERSION=$version" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
