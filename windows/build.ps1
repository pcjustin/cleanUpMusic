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


# What the app loads at runtime: the core, the Swift runtime DLLs it links (found by walking their imports, so
# unused ones such as RegexBuilder or FoundationXML stay out), and the OpenCC dictionaries s2tw uses.
$native = "$PSScriptRoot\native"
Remove-Item -Recurse -Force $native -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$native\opencc" | Out-Null
$bin = (swift build --package-path $root -c $swiftConfig --show-bin-path @flags)
Copy-Item "$bin\CleanUpMusicBridge.dll" $native -ErrorAction Stop
$runtime = Split-Path (Get-Command swiftCore.dll).Source
$dumpbin = (Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" | Select-Object -Last 1).FullName
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue("$bin\CleanUpMusicBridge.dll")
$copied = @{}
while ($queue.Count) {
    foreach ($line in (& $dumpbin /nologo /dependents $queue.Dequeue())) {
        if ($line -notmatch '^\s+(\S+\.dll)\s*$') { continue }
        $src = Join-Path $runtime $Matches[1]
        if ($copied.ContainsKey($Matches[1]) -or -not (Test-Path $src)) { continue }
        $copied[$Matches[1]] = $true
        Copy-Item $src $native -ErrorAction Stop
        $queue.Enqueue($src)
    }
}
$opencc = "$deps\share\opencc"
Copy-Item "$opencc\s2tw.json" "$native\opencc" -ErrorAction Stop
foreach ($dict in ([regex]::Matches((Get-Content -Raw "$opencc\s2tw.json"), '"file":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
    Copy-Item "$opencc\$dict" "$native\opencc" -ErrorAction Stop
}


$msbuild = "$vs\MSBuild\Current\Bin\MSBuild.exe"
& $msbuild "$PSScriptRoot\CleanUpMusic\CleanUpMusic.csproj" -restore -p:Configuration=$Configuration -p:Platform=x64 -v:m -nologo
if ($LASTEXITCODE) { throw "app build failed" }
# The build output, not a publish: publishing an unpackaged WinUI app leaves out the compiled XAML (.xbf, .pri).
$publish = "$PSScriptRoot\CleanUpMusic\bin\release-zip"
Remove-Item -Recurse -Force $publish -ErrorAction SilentlyContinue
Copy-Item "$PSScriptRoot\CleanUpMusic\bin\x64\$Configuration\net10.0-windows10.0.19041.0\win-x64" $publish -Recurse -ErrorAction Stop

# The app runs on the installed .NET Desktop Runtime and Windows App Runtime, so the zip carries their
# installers (downloaded once into windows\redist) and a script that installs both.
$redist = "$PSScriptRoot\redist"
New-Item -ItemType Directory -Force $redist | Out-Null
$ProgressPreference = "SilentlyContinue"
# The runtime installer must match the SDK version the app builds with ("latest" can lag behind it and leave
# components the app checks for at an older version), so it is named and fetched by that version.
$sdk = ([xml](Get-Content "$PSScriptRoot\CleanUpMusic\CleanUpMusic.csproj")).Project.ItemGroup.PackageReference |
    Where-Object { $_.Include -eq "Microsoft.WindowsAppSDK" } | ForEach-Object { $_.Version }
$sdkMinor = ($sdk -split '\.')[0..1] -join '.'
$installers = @{
    "windowsdesktop-runtime-win-x64.exe"   = "https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe"
    "WindowsAppRuntimeInstall-$sdk-x64.exe" = "https://aka.ms/windowsappsdk/$sdkMinor/$sdk/windowsappruntimeinstall-x64.exe"
}
foreach ($name in $installers.Keys) {
    if (-not (Test-Path "$redist\$name")) { Invoke-WebRequest $installers[$name] -OutFile "$redist\$name" -ErrorAction Stop }
}
Get-ChildItem "$redist\WindowsAppRuntimeInstall-*.exe" -Exclude "WindowsAppRuntimeInstall-$sdk-x64.exe" | Remove-Item
New-Item -ItemType Directory -Force "$publish\prerequisites" | Out-Null
Copy-Item "$redist\windowsdesktop-runtime-win-x64.exe" "$publish\prerequisites" -ErrorAction Stop
Copy-Item "$redist\WindowsAppRuntimeInstall-$sdk-x64.exe" "$publish\prerequisites\WindowsAppRuntimeInstall-x64.exe" -ErrorAction Stop
@"
@echo off
rem Installs what CleanUpMusic.exe needs; both installers skip what is already installed.
cd /d "%~dp0prerequisites"
echo Installing .NET 10 Desktop Runtime...
windowsdesktop-runtime-win-x64.exe /install /passive /norestart
echo Installing Windows App Runtime 1.8...
WindowsAppRuntimeInstall-x64.exe --quiet
echo Done. You can now run CleanUpMusic.exe.
pause
"@ -replace "`n", "`r`n" | Set-Content "$publish\install-prerequisites.cmd" -Encoding ASCII -NoNewline
# The install guide (windows\*.txt; matched by pattern since this script is read as ANSI and can't name it).
Copy-Item "$PSScriptRoot\*.txt" $publish -ErrorAction Stop

$dist = "$PSScriptRoot\dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = "$dist\CleanUpMusic-win-x64.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$publish\*" -DestinationPath $zip -ErrorAction Stop
"Zip: $zip"
