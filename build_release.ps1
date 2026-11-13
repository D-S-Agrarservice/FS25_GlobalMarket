# =========================================================================================
# FS25_GlobalMarket - build_release.ps1
# Builds a clean, ModHub/TestRunner-compliant FS25_GlobalMarket.zip release archive.
# Author: D-S-Agrarservice
# =========================================================================================
param(
    [string]$OutputDir = "",
    [switch]$CopyToMods
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot ".releases"
}

$modDescPath = Join-Path $repoRoot "modDesc.xml"
if (-not (Test-Path -LiteralPath $modDescPath)) {
    throw "modDesc.xml not found in repository root: $repoRoot"
}

[xml]$modDescXml = Get-Content -LiteralPath $modDescPath -Raw -Encoding UTF8
$modVersion = $modDescXml.modDesc.version.Trim()

# Strict allowlist of runtime directories and root files included in FS25_GlobalMarket.zip
$allowedRootFiles = @("modDesc.xml", "GlobalMarket.lua", "icon_GM.dds")
$allowedSubDirs = @("events", "gui", "images", "modules", "translations", "xml")
$allowedExtensions = @(".lua", ".xml", ".dds")

$filesToPack = New-Object System.Collections.Generic.List[object]

foreach ($rootFile in $allowedRootFiles) {
    $fullPath = Join-Path $repoRoot $rootFile
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Required root mod file missing: $rootFile"
    }
    $filesToPack.Add([PSCustomObject]@{
        FullPath  = $fullPath
        EntryPath = $rootFile
    })
}

foreach ($subDir in $allowedSubDirs) {
    $subDirFull = Join-Path $repoRoot $subDir
    if (-not (Test-Path -LiteralPath $subDirFull)) {
        continue
    }

    $subFiles = Get-ChildItem -LiteralPath $subDirFull -Recurse -File | Sort-Object FullName
    foreach ($f in $subFiles) {
        $ext = $f.Extension.ToLowerInvariant()
        if ($allowedExtensions -notcontains $ext) {
            throw "Disallowed file extension inside '$subDir': $($f.FullName)"
        }

        $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $filesToPack.Add([PSCustomObject]@{
            FullPath  = $f.FullName
            EntryPath = $rel
        })
    }
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$zipPath = Join-Path $OutputDir "FS25_GlobalMarket.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in $filesToPack) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zipArchive,
            $item.FullPath,
            $item.EntryPath,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    $zipArchive.Dispose()
}

# Post-build archive verification (ensure zero forbidden files or backslashes slipped in)
$forbiddenPatterns = @("^\.git", "^\.agents", "^README", "\.ps1$", "\.md$", "\\")
$verifyZip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entryCount = $verifyZip.Entries.Count
    foreach ($entry in $verifyZip.Entries) {
        foreach ($pat in $forbiddenPatterns) {
            if ($entry.FullName -match $pat) {
                throw "Archive verification failed! Forbidden entry detected: $($entry.FullName)"
            }
        }
    }
}
finally {
    $verifyZip.Dispose()
}

$zipInfo = Get-Item -LiteralPath $zipPath
$sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash

Write-Host "=================================================================" -ForegroundColor Green
Write-Host " FS25_GlobalMarket Release Archive Built Successfully" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " Version : $modVersion"
Write-Host " Output  : $zipPath"
Write-Host " Entries : $entryCount files"
Write-Host " Size    : $([Math]::Round($zipInfo.Length / 1KB, 1)) KB"
Write-Host " SHA256  : $sha256"

if ($CopyToMods) {
    $modsDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "My Games\FarmingSimulator2025\mods"
    if (Test-Path -LiteralPath $modsDir) {
        $destZip = Join-Path $modsDir "FS25_GlobalMarket.zip"
        Copy-Item -LiteralPath $zipPath -Destination $destZip -Force
        Write-Host " Deployed: $destZip" -ForegroundColor Cyan
    }
    else {
        Write-Warning "FS25 mods folder not found at: $modsDir"
    }
}
