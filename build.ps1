# Builds Fritzing (https://github.com/fritzing/fritzing-app) for 64-bit Windows.
# Counterpart of build.sh (Linux/macOS); keep versions and checksums in sync.
#
# usage: pwsh build.ps1 [-Ref <ref>] [-Platform <id>]
#   Ref: empty or "stable" = newest X.Y.Z release, "develop", or any fritzing-app branch/tag
# Expects Visual Studio with C++ tools, Qt 6 (qmake.exe on PATH), cmake, ninja, git, 7z, curl, python.
# Dependencies go next to fritzing-app, where its *.pri files look for them. Existing folders are reused.
param(
    [string]$Ref = "",
    [string]$Platform = "windows-x64"
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

function Fetch([string]$out, [string]$sum, [string[]]$urls) {
    if ((Test-Path $out) -and (Get-FileHash $out -Algorithm SHA256).Hash -eq $sum) { return }
    foreach ($url in $urls) {
        try { Retry { curl.exe -fsSL --connect-timeout 30 -o "$out.part" $url } } catch { continue }
        if ((Get-FileHash "$out.part" -Algorithm SHA256).Hash -eq $sum) { Move-Item -Force "$out.part" $out; return }
        Write-Warning "checksum mismatch for $url"
    }
    Remove-Item "$out.part" -ErrorAction SilentlyContinue
    throw "could not download $out"
}

function ClonePinned([string]$dir, [string]$tag, [string]$commit, [string]$url) {
    # fails if the tag was moved
    if (Test-Path $dir) { return }
    Retry { if (Test-Path "$dir.tmp") { Remove-Item "$dir.tmp" -Recurse -Force }; git clone --quiet --depth 1 --branch $tag $url "$dir.tmp" }
    if ((git -C "$dir.tmp" rev-parse HEAD) -ne $commit) { throw "$url $tag is not commit $commit" }
    Move-Item "$dir.tmp" $dir
}

$SF = "https://downloads.sourceforge.net/project"
$SFMaster = "https://master.dl.sourceforge.net/project"

$root = (Get-Location).Path
if (-not $Ref) { $Ref = "stable" }
# "stable" = newest X.Y.Z branch or tag (upstream keeps each release on a branch with its name)
if ($Ref -eq "stable") {
    $refs = $null
    Retry { $script:refs = git ls-remote --heads --tags https://github.com/fritzing/fritzing-app.git }
    $Ref = $refs | ForEach-Object { if ($_ -match 'refs/(heads|tags)/(\d+\.\d+\.\d+)$') { $Matches[2] } } |
    Sort-Object { [version]$_ } | Select-Object -Last 1
    if (-not $Ref) { throw "could not find the latest stable version" }
}

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

$qtVersion = (qmake -query QT_VERSION).Trim()
$qtPrefix = (qmake -query QT_INSTALL_PREFIX).Trim()
Write-Host "Qt $qtVersion ($qtPrefix), building fritzing-app @ $Ref for $Platform"

# Boost headers; the version must be listed in pri/boostdetect.pri
if (-not (Test-Path "boost_1_85_0")) {
    Fetch "boost.7z" "16D16B9658753117C1434E5450C5EAC194957F4B6D0B390B9D07900D37C115A4" @(
        "https://archives.boost.io/release/1.85.0/source/boost_1_85_0.7z",
        "https://sourceforge.net/projects/boost/files/boost/1.85.0/boost_1_85_0.7z/download")
    Run { 7z x -y -bso0 boost.7z }
}

ClonePinned svgpp-1.3.1 v1.3.1 fda1fd889548289178261d7aa02dd5d647247f94 https://github.com/svgpp/svgpp.git

# zlib, static: Windows has none, and libgit2, QuaZip and Fritzing need it
if (-not (Test-Path "zlib\lib\zlib.lib")) {
    ClonePinned zlib-src v1.3.1 51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf https://github.com/madler/zlib.git
    Run { cmake -G Ninja -S zlib-src -B zlib-build -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" "-DCMAKE_INSTALL_PREFIX=$root\zlib" }
    Run { cmake --build zlib-build }
    Run { cmake --install zlib-build }
    # only the static library, under the name the others look for
    Copy-Item -Force zlib\lib\zlibstatic.lib zlib\lib\zlib.lib
    Remove-Item zlib\bin -Recurse -Force -ErrorAction SilentlyContinue
}

# libgit2, static, as pri/libgit2detect.pri expects on Windows
if (-not (Test-Path "libgit2-1.7.1\lib\git2.lib")) {
    ClonePinned libgit2-src v1.7.1 a2bde63741977ca0f4ef7db2f609df320be67a08 https://github.com/libgit2/libgit2.git
    Run { cmake -G Ninja -S libgit2-src -B libgit2-build -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF `
            -DUSE_HTTPS=WinHTTP -DUSE_SSH=OFF -DUSE_GSSAPI=OFF -DREGEX_BACKEND=builtin -DSTATIC_CRT=OFF `
            -DUSE_BUNDLED_ZLIB=OFF "-DCMAKE_PREFIX_PATH=$root\zlib" "-DCMAKE_INSTALL_PREFIX=$root\libgit2-1.7.1" }
    Run { cmake --build libgit2-build }
    Run { cmake --install libgit2-build }
}

if (-not (Test-Path "Clipper1-6.4.2\lib")) {
    Fetch "clipper.zip" "A14320D82194807C4480CE59C98AA71CD4175A5156645C4E2B3EDD330B930627" @(
        "$SF/polyclipping/clipper_ver6.4.2.zip", "$SFMaster/polyclipping/clipper_ver6.4.2.zip")
    if (Test-Path clipper-src) { Remove-Item clipper-src -Recurse -Force }
    Run { 7z x -y -bso0 -oclipper-src clipper.zip }
    Run { cmake -G Ninja -S clipper-src\cpp -B clipper-build -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$root\Clipper1-6.4.2" }
    Run { cmake --build clipper-build }
    Run { cmake --install clipper-build }
}

# QuaZip, built with the same Qt; the folder name is what pri/quazipdetect.pri expects
$quazipDir = "$root\quazip-$qtVersion-1.4intuisphere"
if (-not (Test-Path "$quazipDir\lib")) {
    ClonePinned quazip-src v1.4 566fa496649b8cb09018b497575bb3bf2977965f https://github.com/stachenov/quazip.git
    Run { cmake -G Ninja -S quazip-src -B quazip-build -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_FETCH_LIBS=ON `
            -DQUAZIP_ENABLE_TESTS=OFF "-DCMAKE_PREFIX_PATH=$qtPrefix;$root\zlib" "-DCMAKE_INSTALL_PREFIX=$quazipDir" }
    Run { cmake --build quazip-build }
    Run { cmake --install quazip-build }
}

# ngspice: prebuilt DLL for the simulator
if (-not (Test-Path "ngspice-42\include")) {
    Fetch "ngspice.7z" "EFDC6315A6ADC4DE957E408AAC4DB0B1BF63EAF74DA5FCF48D1C911DF92AB174" @(
        "$SF/ngspice/ng-spice-rework/old-releases/42/ngspice-42_dll_64.7z",
        "$SFMaster/ngspice/ng-spice-rework/old-releases/42/ngspice-42_dll_64.7z")
    if (Test-Path ngspice-tmp) { Remove-Item ngspice-tmp -Recurse -Force }
    Run { 7z x -y -bso0 -ongspice-tmp ngspice.7z }
    New-Item -ItemType Directory ngspice-42 | Out-Null
    Copy-Item ngspice-tmp\Spice64_dll\include ngspice-42\include -Recurse
    Copy-Item ngspice-tmp\Spice64_dll\dll-vs ngspice-42\bin -Recurse  # ngspice.dll and its OpenMP runtime
}

if (-not (Test-Path "fritzing-app")) {
    Retry { if (Test-Path fritzing-app) { Remove-Item fritzing-app -Recurse -Force }
        git clone --quiet --filter=blob:none https://github.com/fritzing/fritzing-app.git fritzing-app }
}
Retry { git -C fritzing-app fetch --quiet --tags origin }
Run { git -C fritzing-app checkout --quiet --force $Ref }
# as upstream: develop parts for develop builds, master parts otherwise
$partsBranch = if ($Ref -eq "develop") { "develop" } else { "master" }
if (-not (Test-Path "fritzing-parts")) {
    Retry { if (Test-Path fritzing-parts) { Remove-Item fritzing-parts -Recurse -Force }
        git clone --quiet --single-branch --branch $partsBranch https://github.com/fritzing/fritzing-parts.git fritzing-parts }
}
$version = $Ref
if ($Ref -notmatch '^\d+\.\d+\.\d+$') {
    $version = (git -C fritzing-app describe --tags 2>$null)
    if (-not $version) { $version = $Ref }
    $version = $version.Trim()
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

$out = "$root\github\fritzing-$version-$Platform"
if (Test-Path "$root\github") { Remove-Item "$root\github" -Recurse -Force }
New-Item -ItemType Directory $out | Out-Null
Copy-Item $exe.FullName $out
Copy-Item "$quazipDir\bin\*.dll" $out
Run { windeployqt --release --compiler-runtime --no-translations "$out\Fritzing.exe" }
# windeployqt does not follow non-Qt DLLs: deploy QuaZip's Qt dependencies too
foreach ($dll in Get-ChildItem "$out\quazip*.dll") {
    Run { windeployqt --release --no-translations --dir $out $dll.FullName }
}
Copy-Item "$root\ngspice-42\bin\*.dll" $out
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
(Get-Content "$root\SOURCE.txt" -Raw).Replace("@VERSION@", $version).Replace("@REF@", $Ref) |
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

"FRITZING_VERSION=$version" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
