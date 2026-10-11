# Builds the Windows app: TagLib + OpenCC (vcpkg), the shared Swift core as CleanUpMusicBridge.dll, then the WinUI app.
#   .\windows\build.ps1            # Release build, plus windows\dist\CleanUpMusic-win-x64.zip to copy to other PCs
#   .\windows\build.ps1 -Test      # also runs the Swift core tests
param([switch]$Test, [string]$Configuration = "Release")
# Native tools write warnings to stderr, which Windows PowerShell treats as errors under "Stop"; exit codes are checked instead.
$root = Split-Path $PSScriptRoot
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
$triplet = "x64-windows-static-md" # marisa-trie (OpenCC) only builds static on Windows
$deps = "$PSScriptRoot\vcpkg_installed\$triplet"

& "$vs\VC\vcpkg\vcpkg.exe" install --triplet $triplet --x-manifest-root=$PSScriptRoot --x-install-root="$PSScriptRoot\vcpkg_installed"
if ($LASTEXITCODE) { throw "vcpkg failed" }

# Static TagLib and OpenCC also need the libraries they link to.
$flags = @("-Xcc", "-I$deps\include\taglib", "-Xcc", "-I$deps\include\opencc", "-Xswiftc", "-L$deps\lib")
foreach ($lib in "tag", "marisa", "zs") { $flags += "-Xswiftc", "-l$lib" }

$swiftConfig = $Configuration.ToLower()
swift build --package-path $root -c $swiftConfig --product CleanUpMusicBridge @flags
if ($LASTEXITCODE) { throw "swift build failed" }
if ($Test) {
    swift test --package-path $root @flags
    if ($LASTEXITCODE) { throw "swift test failed" }
}

# Everything the app loads at runtime: the core, the Swift runtime, and OpenCC's dictionaries.
$native = "$PSScriptRoot\native"
Remove-Item -Recurse -Force $native -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$native\opencc" | Out-Null
$bin = (swift build --package-path $root -c $swiftConfig --show-bin-path @flags)
Copy-Item "$bin\CleanUpMusicBridge.dll" $native -ErrorAction Stop
$runtime = Split-Path (Get-Command swiftCore.dll).Source
Copy-Item "$runtime\*.dll" $native -ErrorAction Stop
Copy-Item "$deps\share\opencc\*.json", "$deps\share\opencc\*.ocd2" "$native\opencc" -ErrorAction Stop

$msbuild = "$vs\MSBuild\Current\Bin\MSBuild.exe"
& $msbuild "$PSScriptRoot\CleanUpMusic\CleanUpMusic.csproj" -restore -p:Configuration=$Configuration -p:Platform=x64 -v:m -nologo
if ($LASTEXITCODE) { throw "app build failed" }

# The app folder needs nothing installed, so a zip of it is the release.
$out = "$PSScriptRoot\CleanUpMusic\bin\x64\$Configuration\net10.0-windows10.0.19041.0\win-x64"
$dist = "$PSScriptRoot\dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = "$dist\CleanUpMusic-win-x64.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$out\*" -DestinationPath $zip -ErrorAction Stop
"Zip: $zip"
