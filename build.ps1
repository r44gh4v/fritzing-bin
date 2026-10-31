# Builds Fritzing (https://github.com/fritzing/fritzing-app) for 64-bit Windows.
# Counterpart of build.sh (Linux/macOS). Versions come from fritzing_versions.py.
#
# usage: pwsh build.ps1 [-Ref <ref>] [-Platform <id>] [-Version <label>]
#   Ref: empty or "stable" = newest release, "develop", or any fritzing-app branch, tag or commit
# Expects Visual Studio with C++ tools, Qt 6 (qmake.exe on PATH), cmake, ninja, git, 7z, curl, python.
# Dependencies go next to fritzing-app, where its *.pri files look for them. Existing folders are reused.
param(
    [string]$Ref = "",
    [string]$Platform = "windows-x64",
    [string]$Version = ""
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Run([scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE): $cmd" }
}

function Retry([scriptblock]$cmd) {
    foreach ($n in 1..3) {
        try { Run $cmd; return } catch { Write-Warning "attempt $n failed: $_"; if ($n -eq 3) { throw }; Start-Sleep ($n * 15) }
    }
}

function Fetch([string]$name, [string]$sum, [string[]]$urls) {
    $out = "$work\$name"
    if ((Test-Path $out) -and (-not $sum -or (Get-FileHash $out -Algorithm SHA256).Hash -eq $sum)) { return }
    if (-not $sum) { Write-Warning "no known checksum for $name; not verified" }
    foreach ($url in $urls) {
        curl.exe -fsSL --retry 3 --retry-delay 10 --connect-timeout 30 -o "$out.part" $url
        if ($LASTEXITCODE -ne 0) { continue }
        if (-not $sum -or (Get-FileHash "$out.part" -Algorithm SHA256).Hash -eq $sum) { Move-Item -Force "$out.part" $out; return }
        Write-Warning "checksum mismatch for $url"
    }
    Remove-Item "$out.part" -ErrorAction SilentlyContinue
    throw "could not download $name"
}

function ClonePinned([string]$dir, [string]$tag, [string]$commit, [string]$url) {
    # fails if the tag was moved
    if (Test-Path $dir) { return }
    Retry { if (Test-Path "$dir.tmp") { Remove-Item "$dir.tmp" -Recurse -Force }; git clone --quiet --depth 1 --branch $tag $url "$dir.tmp" }
    if (-not $commit) { Write-Warning "no known commit for $url $tag; not verified" }
    elseif ((git -C "$dir.tmp" rev-parse HEAD) -ne $commit) { throw "$url $tag is not commit $commit" }
    Move-Item "$dir.tmp" $dir
}

function Versions([string[]]$arguments) {
    $lines = python -I "$root\fritzing_versions.py" @arguments
    if ($LASTEXITCODE -ne 0) { throw "fritzing_versions.py $arguments failed" }
    $values = @{}
    foreach ($line in $lines) { if ($line -match '^(\w+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim("'") } }
    $values
}

$SF = "https://downloads.sourceforge.net/project"
$SFMaster = "https://master.dl.sourceforge.net/project"
$root = (Get-Location).Path
$work = "$root\_work"
New-Item -ItemType Directory -Force $work | Out-Null

# Visual Studio x64 environment, unless this is already a developer prompt
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "Visual Studio with C++ tools not found" }
    cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item "Env:$($Matches[1])" $Matches[2] }
    }
}

foreach ($tool in "cl", "link", "nmake", "qmake", "lrelease", "windeployqt", "cmake", "ninja", "git", "7z", "curl", "dumpbin", "python") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found in PATH" }
}
# Git for Windows has a Unix `link` tool; the MSVC linker must come first
if ((Get-Command link).Source -notmatch 'MSVC') { throw "'link' is not the MSVC linker: $((Get-Command link).Source)" }

# --- Fritzing source, then the versions it needs ---
if (-not (Test-Path "fritzing-app")) {
    Retry { if (Test-Path fritzing-app) { Remove-Item fritzing-app -Recurse -Force }
        git clone --quiet --filter=blob:none https://github.com/fritzing/fritzing-app.git fritzing-app }
}
Retry { git -C fritzing-app fetch --quiet --tags origin }
$resolved = Versions @("resolve", "fritzing-app", $Ref)
$Ref = $resolved.REF
if (-not $Version) { $Version = $resolved.VERSION }
Run { git -C fritzing-app checkout --quiet --force $Ref }
$v = Versions @("deps", "fritzing-app")

$qtVersion = (qmake -query QT_VERSION).Trim()
$qtPrefix = (qmake -query QT_INSTALL_PREFIX).Trim()
if ([version]$qtVersion -lt [version]$v.QT_LEAST -or [version]$qtVersion -gt [version]$v.QT_MOST) {
    throw "Fritzing $Version needs Qt $($v.QT_LEAST) to $($v.QT_MOST), found $qtVersion"
}
Write-Host "Fritzing $Version ($Ref) with Qt $qtVersion for $Platform"

# --- dependencies ---
$boostDir = "boost_1_$($v.BOOST)_0"
if (-not (Test-Path $boostDir)) {
    Fetch "boost.7z" $v.BOOST_SHA_7Z @(
        "https://archives.boost.io/release/1.$($v.BOOST).0/source/$boostDir.7z",
        "https://sourceforge.net/projects/boost/files/boost/1.$($v.BOOST).0/$boostDir.7z/download")
    Run { 7z x -y -bso0 "$work\boost.7z" }
}

ClonePinned "svgpp-$($v.SVGPP)" "v$($v.SVGPP)" $v.SVGPP_COMMIT https://github.com/svgpp/svgpp.git

# zlib, static: Windows has none, and libgit2, QuaZip and Fritzing need it
if (-not (Test-Path "zlib\lib\zlib.lib")) {
    ClonePinned "$work\zlib-src" v1.3.1 51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf https://github.com/madler/zlib.git
    Run { cmake -G Ninja -S "$work\zlib-src" -B "$work\zlib-build" -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" "-DCMAKE_INSTALL_PREFIX=$root\zlib" }
    Run { cmake --build "$work\zlib-build" }
    Run { cmake --install "$work\zlib-build" }
    # only the static library, under the name the others look for
    Copy-Item -Force zlib\lib\zlibstatic.lib zlib\lib\zlib.lib
    Remove-Item zlib\bin -Recurse -Force -ErrorAction SilentlyContinue
}

# libgit2, static, as pri/libgit2detect.pri expects on Windows
$libgit2Dir = "$root\libgit2-$($v.LIBGIT2)"
if (-not (Test-Path "$libgit2Dir\lib\git2.lib")) {
    ClonePinned "$work\libgit2-src" "v$($v.LIBGIT2)" $v.LIBGIT2_COMMIT https://github.com/libgit2/libgit2.git
    Run { cmake -G Ninja -S "$work\libgit2-src" -B "$work\libgit2-build" -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF `
            -DUSE_HTTPS=WinHTTP -DUSE_SSH=OFF -DUSE_GSSAPI=OFF -DREGEX_BACKEND=builtin -DSTATIC_CRT=OFF `
            -DUSE_BUNDLED_ZLIB=OFF "-DCMAKE_PREFIX_PATH=$root\zlib" "-DCMAKE_INSTALL_PREFIX=$libgit2Dir" }
    Run { cmake --build "$work\libgit2-build" }
    Run { cmake --install "$work\libgit2-build" }
}

$clipperDir = "$root\Clipper1-$($v.CLIPPER)"
if (-not (Test-Path "$clipperDir\lib")) {
    Fetch "clipper.zip" $v.CLIPPER_SHA @(
        "$SF/polyclipping/clipper_ver$($v.CLIPPER).zip", "$SFMaster/polyclipping/clipper_ver$($v.CLIPPER).zip")
    if (Test-Path "$work\clipper-src") { Remove-Item "$work\clipper-src" -Recurse -Force }
    Run { 7z x -y -bso0 "-o$work\clipper-src" "$work\clipper.zip" }
    Run { cmake -G Ninja -S "$work\clipper-src\cpp" -B "$work\clipper-build" -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$clipperDir" }
    Run { cmake --build "$work\clipper-build" }
    Run { cmake --install "$work\clipper-build" }
}

$quazipDir = "$root\" + $v.QUAZIP_DIR.Replace("@QT@", $qtVersion)
if (-not (Test-Path "$quazipDir\lib")) {
    ClonePinned "$work\quazip-src" "v$($v.QUAZIP)" $v.QUAZIP_COMMIT https://github.com/stachenov/quazip.git
    Run { cmake -G Ninja -S "$work\quazip-src" -B "$work\quazip-build" -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_FETCH_LIBS=ON `
            -DQUAZIP_ENABLE_TESTS=OFF "-DCMAKE_PREFIX_PATH=$qtPrefix;$root\zlib" "-DCMAKE_INSTALL_PREFIX=$quazipDir" }
    Run { cmake --build "$work\quazip-build" }
    Run { cmake --install "$work\quazip-build" }
}

# ngspice: prebuilt DLL for the simulator
$ngspiceDir = "$root\ngspice-$($v.NGSPICE)"
if (-not (Test-Path "$ngspiceDir\include")) {
    $n = $v.NGSPICE
    Fetch "ngspice.7z" $v.NGSPICE_SHA_DLL @(
        "$SF/ngspice/ng-spice-rework/$n/ngspice-${n}_dll_64.7z",
        "$SF/ngspice/ng-spice-rework/old-releases/$n/ngspice-${n}_dll_64.7z",
        "$SFMaster/ngspice/ng-spice-rework/old-releases/$n/ngspice-${n}_dll_64.7z")
    if (Test-Path "$work\ngspice-tmp") { Remove-Item "$work\ngspice-tmp" -Recurse -Force }
    Run { 7z x -y -bso0 "-o$work\ngspice-tmp" "$work\ngspice.7z" }
    New-Item -ItemType Directory $ngspiceDir | Out-Null
    Copy-Item "$work\ngspice-tmp\Spice64_dll\include" "$ngspiceDir\include" -Recurse
    Copy-Item "$work\ngspice-tmp\Spice64_dll\dll-vs" "$ngspiceDir\bin" -Recurse  # ngspice.dll and its OpenMP runtime
}

# Parts: the current library (develop), as upstream releases and distribution packages ship it.
# Full clone with .git: the parts database and the in-app parts check use it.
if (-not (Test-Path "fritzing-parts")) {
    Retry { if (Test-Path fritzing-parts) { Remove-Item fritzing-parts -Recurse -Force }
        git clone --quiet --single-branch --branch develop https://github.com/fritzing/fritzing-parts.git fritzing-parts }
}

# pri/gitversion.pri treats CI=true as Travis and makes a broken version string
Remove-Item Env:CI -ErrorAction SilentlyContinue
$z = "$root\zlib" -replace '\\', '/'
Push-Location fritzing-app
Run { lrelease phoenix.pro }  # the .qm translation files are not committed
# static libgit2 needs these system libraries; pri/libgit2detect.pri does not add them
Run { qmake -o Makefile phoenix.pro "CONFIG+=release" "QMAKE_TARGET.arch=x86_64" "INCLUDEPATH+=$z/include" `
        "LIBS+=-L$z/lib -lzlib -lwinhttp -lrpcrt4 -lcrypt32 -lole32 -lsecur32 -ladvapi32 -lws2_32" }
# nmake runs one job at a time; /MP makes cl use all cores
$env:CL = "/MP"
Run { nmake release }
Remove-Item Env:CL
Pop-Location

$exe = Get-Item "$root\release64\Fritzing.exe" -ErrorAction SilentlyContinue  # DESTDIR from phoenix.pro
if (-not $exe) { throw "Fritzing.exe not found after build" }

$out = "$root\github\fritzing-$Version-$Platform"
if (Test-Path "$root\github") { Remove-Item "$root\github" -Recurse -Force }
New-Item -ItemType Directory $out | Out-Null
Copy-Item $exe.FullName $out
Copy-Item "$quazipDir\bin\*.dll" $out
Run { windeployqt --release --compiler-runtime --no-translations "$out\Fritzing.exe" }
# windeployqt does not follow non-Qt DLLs: deploy QuaZip's Qt dependencies too
foreach ($dll in Get-ChildItem "$out\quazip*.dll") {
    Run { windeployqt --release --no-translations --dir $out $dll.FullName }
}
Copy-Item "$ngspiceDir\bin\*.dll" $out
# Fritzing only uses SQLite; the other SQL drivers need client libraries that are not bundled
Get-ChildItem "$out\sqldrivers\*.dll" -Exclude qsqlite.dll | Remove-Item

# fail if the exe or a bundled DLL imports a DLL that is neither bundled nor part of Windows
$missing = foreach ($bin in Get-ChildItem $out -Include *.exe, *.dll -Recurse) {
    dumpbin /nologo /dependents $bin.FullName | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w.+-]+\.dll$' } |
    Where-Object { -not (Test-Path "$out\$_") -and -not (Test-Path "$env:SystemRoot\System32\$_") -and $_ -notmatch '^(api|ext)-ms-' } |
    ForEach-Object { "$($bin.Name) -> $_" }
}
if ($missing) { throw "missing DLLs in package:`n$($missing -join "`n")" }

$app = "$root\fritzing-app"
foreach ($d in "sketches", "translations", "help") { Copy-Item "$app\$d" "$out\$d" -Recurse }
Remove-Item "$out\translations\*.ts"
Get-ChildItem "$out\translations\*.qm" | Where-Object { $_.Length -lt 128 } | Remove-Item
# with .git, as upstream: the parts database and the in-app parts update use it (-Force: .git is hidden)
Copy-Item "$root\fritzing-parts" "$out\fritzing-parts" -Recurse -Force
if (-not (Test-Path "$out\fritzing-parts\.git\HEAD")) { throw "fritzing-parts\.git was not copied" }
foreach ($f in "README.md", "INSTALL.txt", "LICENSE.GPL2", "LICENSE.GPL3", "LICENSE.LGPLv3", "LICENSE.CC-BY-SA",
    "LICENSE.Modified_BSD", "LICENSE_1_0.txt.BOOST", "license-openssl-ssleay.txt") {
    if (Test-Path "$app\$f") { Copy-Item "$app\$f" $out }
}
(Get-Content "$root\SOURCE.txt" -Raw).Replace("@VERSION@", $Version).Replace("@REF@", $Ref) |
Set-Content "$out\SOURCE.txt"

# Builds the parts database with the packaged app, as upstream's release script does. This is also
# the smoke test. Fritzing indexes a copy of the parts with malformed XML repaired (fix_parts_xml.py);
# the shipped fritzing-parts stays an unmodified clone for the in-app parts update.
$partsFixed = Join-Path ([IO.Path]::GetTempPath()) "fritzing-parts-fixed-$PID"
Copy-Item "$out\fritzing-parts" $partsFixed -Recurse -Force
Run { python -I "$root\fix_parts_xml.py" $partsFixed }
$qtPluginPath = $env:QT_PLUGIN_PATH  # from install-qt-action; would load Qt's plugins, not the bundled ones
Remove-Item Env:QT_PLUGIN_PATH -ErrorAction SilentlyContinue
$db = "$out\fritzing-parts\parts.db"
$p = Start-Process "$out\Fritzing.exe" -PassThru -NoNewWindow `
    -ArgumentList "-db", "`"$db`"", "-pp", "`"$partsFixed`"", "-f", "`"$out`""
$null = $p.Handle  # needed for ExitCode
if (-not $p.WaitForExit(900000)) { $p.Kill(); throw "packaged Fritzing did not finish building the parts database in 15 minutes" }
if ($p.ExitCode -ne 0) { throw "packaged Fritzing failed to start or to build the parts database (exit code $($p.ExitCode))" }
if (-not (Test-Path $db) -or (Get-Item $db).Length -lt 1MB) { throw "parts database is missing or too small" }
if ($qtPluginPath) { $env:QT_PLUGIN_PATH = $qtPluginPath }
Remove-Item $partsFixed -Recurse -Force

Run { 7z a -tzip -bso0 "$out.zip" $out }
Remove-Item $out -Recurse -Force

"FRITZING_VERSION=$Version" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
