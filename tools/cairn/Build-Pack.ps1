# Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: MIT OR Apache-2.0 (as the project it is part of)
<#
.SYNOPSIS
    Builds the Cairn mod pack for Noita Entangled Worlds from the two archives this project's own CI makes:
    release\Cairn-Pack-noita-<version>.zip and release\pack-index.json (what the Cairn launcher reads to see a newer pack exists).

.DESCRIPTION
    An *external* pack (docs in the launcher repository: docs/PACKS.md): the mod goes into <Noita>\mods\quant.ew, and the proxy
    (the program that hosts or joins, then starts Noita) is the pack's companion, kept in the launcher's pack store.

      mod\   the contents of quant.ew.zip (the mod folder, including files\version.lua that the proxy checks)
      bin\   noita_proxy.exe and steam_api64.dll from noita_proxy-win.zip, and noita-bridge.exe (the launcher's saves and logs program)
      pack.json      the contract with the launcher
      manifest.txt   MOD|<path>|<size>|<sha256> and BIN|<path>|<size>|<sha256>, one line per file

    The pack's version is the VERSION file (strict X.Y.Z, this project's own); the proxy's version (the one two players must share,
    it is in noita_proxy\Cargo.toml) is the pack's "upstream".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ModZip,
    [Parameter(Mandatory)][string] $ProxyZip,
    [Parameter(Mandatory)][string] $Bridge    # noita-bridge.exe, built from tools\cairn\NoitaBridge (the launcher's program for Noita: saves, logs)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "VERSION must be strict X.Y.Z, got '$version'" }
$proxyVersion = [regex]::Match((Get-Content (Join-Path $root 'noita_proxy\Cargo.toml') -Raw), '(?m)^version = "([^"]+)"').Groups[1].Value
if (-not $proxyVersion) { throw 'could not read the proxy version from noita_proxy\Cargo.toml' }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$release = Join-Path $root 'release'
$stage = Join-Path $release 'pack-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'mod'), (Join-Path $stage 'bin') | Out-Null

function Expand-Safe([string] $zipPath, [string] $dest, [string[]] $only) {
    $destFull = [IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $zipPath))
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            if ($only -and ($only -notcontains $e.FullName)) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $dest ($e.FullName -replace '/', '\')))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "the archive has a path outside its folder: $($e.FullName)" }
            New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

Expand-Safe $ModZip (Join-Path $stage 'mod')
Expand-Safe $ProxyZip (Join-Path $stage 'bin') @('noita_proxy.exe', 'steam_api64.dll')
Copy-Item $Bridge (Join-Path $stage 'bin\noita-bridge.exe')
foreach ($n in @('bin\noita_proxy.exe', 'bin\steam_api64.dll', 'bin\noita-bridge.exe', 'mod\init.lua', 'mod\mod.xml', 'mod\files\version.lua', 'mod\ewext.dll')) {
    if (-not (Test-Path (Join-Path $stage $n))) { throw "the pack is missing $n" }
}

function Get-Sha256([string] $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$launcherMin = '0.3.27'   # the launcher that runs a pack's own program (saves, logs) for an external mod
$packJson = [ordered]@{
    schema              = 2
    id                  = 'noita'
    game                = 'noita'
    version             = $version
    upstream            = $proxyVersion
    kind                = 'external'
    installDir          = 'mods/quant.ew'
    companion           = 'bin/noita_proxy.exe'
    companionStartsGame = $true
    optionsProgram      = 'bin/noita-bridge.exe'
    launcherMin         = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $stage 'pack.json'), (($packJson | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$lines = New-Object System.Collections.Generic.List[string]
foreach ($kind in @('mod', 'bin')) {
    $dir = Join-Path $stage $kind
    foreach ($f in Get-ChildItem $dir -Recurse -File | Sort-Object FullName) {
        $rel = $f.FullName.Substring($dir.Length + 1)
        $lines.Add(('{0}|{1}|{2}|{3}' -f $kind.ToUpperInvariant(), $rel, $f.Length, (Get-Sha256 $f.FullName)))
    }
}
[IO.File]::WriteAllText((Join-Path $stage 'manifest.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$zipName = "Cairn-Pack-noita-$version.zip"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$fs = [IO.File]::Open($zipPath, 'Create')
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

$index = [ordered]@{
    schema      = 2
    id          = 'noita'
    game        = 'noita'
    version     = $version
    upstream    = $proxyVersion
    kind        = 'external'
    file        = $zipName
    sha256      = Get-Sha256 $zipPath
    size        = (Get-Item $zipPath).Length
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $release 'pack-index.json'), (($index | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "pack: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB), version $version, Entangled Worlds $proxyVersion, $($lines.Count) files"
