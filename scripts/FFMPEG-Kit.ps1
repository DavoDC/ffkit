param(
    [Parameter(Mandatory=$true)]
    [string[]]$InputFiles
)

# ──────────────────────────────────────────────────────────────────────────────
# CONFIG - edit once to suit your setup
$OutputDir = "$env:USERPROFILE\Downloads"   # Empty = output alongside input
# ──────────────────────────────────────────────────────────────────────────────

$InputFile = $InputFiles[0]

# ==============================================================================
# TOOL: Compress to target size
# ==============================================================================
function Invoke-Compress {
    Write-Host ""
    Write-Host "[2] Analysing duration..."
    $t = Get-Date
    $rawDur = (& $ffprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>&1 | Out-String).Trim()
    [double]$dur = 0.0
    if (-not [double]::TryParse($rawDur,[ref]$dur) -or $dur -le 0) {
        Write-Host "ERROR: Cannot read video duration."; Stop-Transcript | Out-Null; exit 1
    }
    $durFmt = [TimeSpan]::FromSeconds($dur).ToString("hh\:mm\:ss")
    Write-Host "  Duration : $durFmt ($([math]::Round($dur,1))s)"
    Write-Host "  Input    : ${inputSizeMB} MB"

    Write-Host ""
    Write-Host "  Target size:"
    Write-Host "    [1] 4 MB"
    Write-Host "    [2] 6 MB"
    Write-Host "    [3] 8 MB"
    Write-Host "    [4] Quarter of original (${quarterSizeMB} MB)"
    Write-Host "    [5] Half of original    (${halfSizeMB} MB)"
    Write-Host "    [6] Custom MB"
    Write-Host ""
    $sc = Read-Host "  Choose (1-6)"
    $TargetMB = switch ($sc.Trim()) {
        "1" { 4 } "2" { 6 } "3" { 8 }
        "4" { $quarterSizeMB } "5" { $halfSizeMB }
        "6" {
            $cv = Read-Host "  Enter target MB"
            $cm = 0.0
            if ([double]::TryParse($cv,[ref]$cm) -and $cm -gt 0) { $cm } else { Write-Host "  Invalid - using 4 MB."; 4 }
        }
        default { Write-Host "  Invalid - using 4 MB."; 4 }
    }
    Write-Host ""

    $audioBps    = if ($dur -gt 600) { 48 } elseif ($dur -gt 300) { 64 } else { 96 }
    $targetBytes = $TargetMB * 1024 * 1024 * 0.98
    $vidBitrateK = [int]([math]::Max(5, ($targetBytes * 8 / $dur - $audioBps * 1000) / 1000))
    Write-Host "  Video bitrate: ${vidBitrateK} kbps | Audio: ${audioBps} kbps"
    Write-Host "  Analysis: $([int]((Get-Date)-$t).TotalSeconds)s"

    $outputFile = Join-Path $outDir "${inputBase}_${TargetMB}mb.mp4"
    $passlog    = Join-Path $env:TEMP "ffkit-pass-$PID"

    Write-Host ""
    Write-Host "[3] Two-pass encoding..."
    $t3 = Get-Date
    Write-Host "  Pass 1/2..."
    & $ffmpegExe -nostdin -y -i "$InputFile" -c:v libx264 -preset slow -profile:v high `
        -b:v "${vidBitrateK}k" -pass 1 -passlogfile "$passlog" -an -f null NUL
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Pass 1 failed."; Remove-Item "${passlog}*" -EA SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }

    Write-Host "  Pass 2/2..."
    & $ffmpegExe -nostdin -y -i "$InputFile" -c:v libx264 -preset slow -profile:v high `
        -b:v "${vidBitrateK}k" -pass 2 -passlogfile "$passlog" `
        -c:a aac -b:a "${audioBps}k" -af aresample=async=1 -movflags +faststart "$outputFile"
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Pass 2 failed."; Remove-Item "${passlog}*" -EA SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }
    Remove-Item "${passlog}*" -EA SilentlyContinue
    Write-Host "  Encode: $([int]((Get-Date)-$t3).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    if (Test-Path $outputFile) {
        $outMB = [math]::Round((Get-Item $outputFile).Length/1MB,2)
        $ratio = [math]::Round((Get-Item $outputFile).Length/(Get-Item $InputFile).Length*100,1)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  (target: ${TargetMB} MB,  ${ratio}% of original)"
        if ((Get-Item $outputFile).Length -gt $TargetMB*1024*1024) {
            Write-Host "  NOTE   : Slightly over limit (container overhead)."
        }
    } else { Write-Host "  ERROR: Output not created." }
}


# ==============================================================================
# TOOL: Portrait to landscape - blur-fill 1280x720
# ==============================================================================
function Invoke-LandscapeFill {
    $cropW, $cropH, $cropX, $cropY, $hasCrop = Get-CropParams
    $outputFile = Join-Path $outDir "${inputBase}_landscape.mp4"
    Write-Host ""
    Write-Host "[3] Encoding landscape blur-fill..."
    $t = Get-Date

    if ($hasCrop) {
        $fc = "[0:v]crop=${cropW}:${cropH}:${cropX}:${cropY},split[c1][c2];[c1]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,boxblur=15:5[bg];[c2]scale=1280:720:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
    } else {
        $fc = "[0:v]split[c1][c2];[c1]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,boxblur=15:5[bg];[c2]scale=1280:720:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
    }

    & $ffmpegExe -nostdin -y -i "$InputFile" `
        -filter_complex $fc -map "[out]" -map "0:a?" `
        -c:v libx264 -preset fast -crf 18 `
        -c:a aac -b:a 128k -movflags +faststart "$outputFile"
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Encode failed."; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "  Encode: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    if (Test-Path $outputFile) {
        $outMB = [math]::Round((Get-Item $outputFile).Length/1MB,2)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  (1280x720 landscape)"
    } else { Write-Host "  ERROR: Output not created." }
}


# ==============================================================================
# TOOL: Remove black bars only
# ==============================================================================
function Invoke-CropFix {
    $cropW, $cropH, $cropX, $cropY, $hasCrop = Get-CropParams
    if (-not $hasCrop) {
        Write-Host "  No significant black bars detected - nothing to do."
        Stop-Transcript | Out-Null; exit 0
    }
    $outputFile = Join-Path $outDir "${inputBase}_cropfix.mp4"
    Write-Host ""
    Write-Host "[3] Encoding with black bars removed..."
    $t = Get-Date

    & $ffmpegExe -nostdin -y -i "$InputFile" `
        -vf "crop=${cropW}:${cropH}:${cropX}:${cropY}" `
        -c:v libx264 -preset fast -crf 18 `
        -c:a copy -movflags +faststart "$outputFile"
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Encode failed."; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "  Encode: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    if (Test-Path $outputFile) {
        $outMB = [math]::Round((Get-Item $outputFile).Length/1MB,2)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  (${cropW}x${cropH})"
    } else { Write-Host "  ERROR: Output not created." }
}


# ==============================================================================
# TOOL: Trim clip(s) from a single file (visually lossless re-encode)
# ==============================================================================
function Invoke-Trim {
    Write-Host ""
    Write-Host "[2] Enter clips to extract (HH:MM:SS or MM:SS). Blank start to finish."
    $clips = @()
    while ($true) {
        Write-Host ""
        $s = Read-Host "  Clip $($clips.Count + 1) start (blank to finish)"
        if (-not $s -or -not $s.Trim()) { break }
        $e = Read-Host "  Clip $($clips.Count + 1) end"
        if (-not $e -or -not $e.Trim()) { Write-Host "  No end time given - skipping clip."; continue }
        $clips += [PSCustomObject]@{ Start = $s.Trim(); End = $e.Trim() }
    }
    if ($clips.Count -eq 0) {
        Write-Host "  No clips entered - nothing to do."
        Stop-Transcript | Out-Null; exit 0
    }

    $ext = [System.IO.Path]::GetExtension($InputFile)
    Write-Host ""
    Write-Host "[3] Trimming $($clips.Count) clip(s) (re-encode for frame-accurate cuts, visually lossless)..."
    $t = Get-Date
    $outFiles = @()
    for ($i = 0; $i -lt $clips.Count; $i++) {
        $c = $clips[$i]
        $suffix = if ($clips.Count -gt 1) { "_clip$($i+1)" } else { "_clip" }
        $clipFile = Join-Path $outDir "${inputBase}${suffix}${ext}"
        Write-Host "  Clip $($i+1): $($c.Start) -> $($c.End)"
        & $ffmpegExe -nostdin -y -i "$InputFile" -ss $c.Start -to $c.End `
            -c:v libx265 -preset slow -crf 16 `
            -c:a ac3 -b:a 224k "$clipFile"
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Trim failed for clip $($i+1)."; Stop-Transcript | Out-Null; exit 1 }
        $outFiles += $clipFile
    }
    Write-Host "  Trim: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    foreach ($f in $outFiles) {
        if (Test-Path $f) {
            $outMB = [math]::Round((Get-Item $f).Length/1MB,2)
            Write-Host "  Output : $f  (${outMB} MB)"
        } else { Write-Host "  ERROR: $f not created." }
    }
}


# ==============================================================================
# TOOL: Merge multiple files into one (stream copy if compatible, else re-encode)
# ==============================================================================
function Invoke-Merge {
    if ($InputFiles.Count -lt 2) {
        Write-Host "  Need 2+ files to merge - drag and drop multiple files onto the launcher."
        Stop-Transcript | Out-Null; exit 1
    }
    $ext        = [System.IO.Path]::GetExtension($InputFiles[0])
    $outputFile = Join-Path $outDir "${inputBase}_merged${ext}"
    $tempDir    = Join-Path $env:TEMP "ffkit-merge-$PID"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $listFile   = Join-Path $tempDir "concat.txt"
    $listLines  = $InputFiles | ForEach-Object { "file '$_'" }
    Set-Content -Path $listFile -Value $listLines -Encoding ASCII

    Write-Host ""
    Write-Host "[2] Merging $($InputFiles.Count) file(s)..."
    Write-Host "  Attempting stream copy (lossless, no re-encode)..."
    $t = Get-Date
    & $ffmpegExe -nostdin -y -f concat -safe 0 -i "$listFile" -c copy "$outputFile" 2>$null
    $copyOk = ($LASTEXITCODE -eq 0) -and (Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)

    if (-not $copyOk) {
        Write-Host "  Stream copy failed (mismatched codecs/params) - re-encoding instead..."
        Remove-Item $outputFile -Force -EA SilentlyContinue
        $inputArgs = $InputFiles | ForEach-Object { "-i", "`"$_`"" }
        $n = $InputFiles.Count
        $concatInputs = (0..($n-1) | ForEach-Object { "[$_`:v:0][$_`:a:0]" }) -join ""
        $fc = "${concatInputs}concat=n=${n}:v=1:a=1[v][a]"
        & $ffmpegExe -nostdin -y @($InputFiles | ForEach-Object { @("-i", $_) } | ForEach-Object { $_ }) `
            -filter_complex $fc -map "[v]" -map "[a]" `
            -c:v libx265 -preset slow -crf 16 `
            -c:a ac3 -b:a 224k "$outputFile"
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Merge failed."; Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }
    } else {
        Write-Host "  Stream copy succeeded."
    }
    Write-Host "  Merge: $([int]((Get-Date)-$t).TotalSeconds)s"
    Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue

    Write-Host ""
    Write-Host "[3] Results"
    if (Test-Path $outputFile) {
        $outMB = [math]::Round((Get-Item $outputFile).Length/1MB,2)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  ($($InputFiles.Count) files merged)"
    } else { Write-Host "  ERROR: Output not created." }
}


# ==============================================================================
# HELPER: Detect black bars via cropdetect
# ==============================================================================
function Get-CropParams {
    Write-Host ""
    Write-Host "[2] Detecting black bars..."
    $t = Get-Date

    $rawDims = (& $ffprobeExe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$InputFile" 2>&1 | Out-String).Trim()
    $dp = $rawDims -split ','; $origW = [int]$dp[0]; $origH = [int]$dp[1]

    $rawDur = (& $ffprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>&1 | Out-String).Trim()
    [double]$dur = 0.0; [double]::TryParse($rawDur,[ref]$dur) | Out-Null
    $scanSec = [math]::Min($dur, 30)

    Write-Host "  Scanning ${origW}x${origH} for up to ${scanSec}s..."
    $raw = & $ffmpegExe -nostdin -i "$InputFile" -t $scanSec -vf "cropdetect=limit=24:round=2:reset=0" -f null NUL 2>&1
    $last = ($raw | Select-String 'crop=\d+:\d+:\d+:\d+' | Select-Object -Last 1).ToString()

    $cW = $origW; $cH = $origH; $cX = 0; $cY = 0; $found = $false
    if ($last -match 'crop=(\d+):(\d+):(\d+):(\d+)') {
        $cW = [int]$Matches[1]; $cH = [int]$Matches[2]; $cX = [int]$Matches[3]; $cY = [int]$Matches[4]
        if ($cH -lt ($origH - 10) -or $cW -lt ($origW - 10)) {
            $found = $true
            $remBottom = $origH - $cY - $cH
            $remRight  = $origW - $cX - $cW
            Write-Host "  Found  : crop=${cW}:${cH}:${cX}:${cY}  (top=$cY  bottom=$remBottom  left=$cX  right=$remRight)"
        } else {
            Write-Host "  None   : no significant black bars found."
        }
    } else {
        Write-Host "  None   : cropdetect returned no crop."
    }
    Write-Host "  Detection: $([int]((Get-Date)-$t).TotalSeconds)s"
    return $cW, $cH, $cX, $cY, $found
}


# ==============================================================================
# MAIN
# ==============================================================================
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
$FfmpegDir    = Join-Path $RepoRoot "dependencies\ffmpeg"
$LogDir       = Join-Path $RepoRoot "data\logs"
$SessionStart = Get-Date

foreach ($f in $InputFiles) {
    if (-not (Test-Path $f)) {
        Write-Host "ERROR: File not found: $f"
        exit 1
    }
}

$multiFile     = $InputFiles.Count -gt 1
$inputDir      = Split-Path -Parent $InputFile
$inputBase     = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
$outDir        = if ($OutputDir -and $OutputDir.Trim()) { $OutputDir } else { $inputDir }
$inputSizeMB   = [math]::Round((Get-Item $InputFile).Length / 1MB, 2)
$quarterSizeMB = [math]::Round($inputSizeMB * 0.25, 2)
$halfSizeMB    = [math]::Round($inputSizeMB * 0.5, 2)

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host ""
Write-Host "=== FFMPEG Kit ==="
if ($multiFile) {
    Write-Host "Input : $($InputFiles.Count) files dropped"
    $InputFiles | ForEach-Object { Write-Host "  - $_" }
    Write-Host ""
    Write-Host "  [5] Merge these files into one"
    Write-Host ""
    $choice = "5"
} else {
    Write-Host "Input : $InputFile  (${inputSizeMB} MB)"
    Write-Host ""
    Write-Host "  [1] Compress to target size"
    Write-Host "  [2] Portrait to landscape  (blur-fill 1280x720, removes black bars)"
    Write-Host "  [3] Remove black bars only (keep original dimensions)"
    Write-Host "  [4] Trim clip(s)           (cut one or more sections from this file)"
    Write-Host ""
    $choice = Read-Host "  Choose (1-4)"
}
Write-Host ""

if ($choice -notin @("1","2","3","4","5")) {
    Write-Host "Invalid choice."
    exit 1
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile  = Join-Path $LogDir "ffkit_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile -NoClobber | Out-Null

$toolName = switch ($choice) { "1" { "Compress" } "2" { "Landscape blur-fill" } "3" { "Remove black bars" } "4" { "Trim clip(s)" } "5" { "Merge files" } }
Write-Host "=== FFMPEG Kit - $toolName ==="
Write-Host "Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Input   : $InputFile"
Write-Host ""

# ── Locate FFmpeg ─────────────────────────────────────────────────────────────
Write-Host "[1] Locating FFmpeg..."

function Find-InDir([string]$Dir, [string]$Name) {
    $r = Get-ChildItem -Path $Dir -Filter $Name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($r) { return $r.FullName }; return $null
}

$ffmpegExe = $null; $ffprobeExe = $null

if (Test-Path $FfmpegDir) {
    $ffmpegExe  = Find-InDir $FfmpegDir "ffmpeg.exe"
    $ffprobeExe = Find-InDir $FfmpegDir "ffprobe.exe"
}
if (-not $ffmpegExe) {
    $sysFF = Get-Command "ffmpeg"  -ErrorAction SilentlyContinue
    $sysFP = Get-Command "ffprobe" -ErrorAction SilentlyContinue
    if ($sysFF) { $ffmpegExe = $sysFF.Source; $ffprobeExe = if ($sysFP) { $sysFP.Source } else { $null } }
}
if (-not $ffmpegExe) {
    Write-Host "  FFmpeg not found - downloading to $FfmpegDir ..."
    if (-not (Test-Path $FfmpegDir)) { New-Item -ItemType Directory -Path $FfmpegDir | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $7zExe = $null
    foreach ($c in @("7z","7za","$env:ProgramFiles\7-Zip\7z.exe","${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($c -match '\\') { if (Test-Path $c -EA SilentlyContinue) { $7zExe = $c; break } }
        else                 { if (Get-Command $c -EA SilentlyContinue) { $7zExe = $c; break } }
    }
    $curlExe = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    $oldProgressPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    function Get-File([string]$Url, [string]$Dest) {
        if ($curlExe) { & $curlExe.Source -L --fail -o $Dest $Url 2>$null; return $LASTEXITCODE -eq 0 }
        try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing; return $true } catch { return $false }
    }
    function Get-LatestAssetUrl([string]$Repo, [string]$NamePattern) {
        $api = "https://api.github.com/repos/$Repo/releases/latest"
        try {
            $json = if ($curlExe) { & $curlExe.Source -s -L --fail $api } else { (Invoke-WebRequest -Uri $api -UseBasicParsing).Content }
            $asset = ($json | ConvertFrom-Json).assets | Where-Object { $_.name -match $NamePattern } | Select-Object -First 1
            if ($asset) { return $asset.browser_download_url }
        } catch {}
        return $null
    }
    # GyanD/codexffmpeg mirrors gyan.dev's small "essentials" build (~32 MB, includes libx264) as a
    # GitHub release - same small size, GitHub's fast CDN instead of gyan.dev's slow server.
    $ext = if ($7zExe) { "7z" } else { "zip" }
    $arch = Join-Path $FfmpegDir "ffmpeg-dl.$ext"
    Write-Host "  Downloading from GitHub mirror (GyanD/codexffmpeg essentials, ~32 MB)..."
    $dlStart = Get-Date
    $assetUrl = Get-LatestAssetUrl "GyanD/codexffmpeg" "essentials_build\.$ext$"
    $ok = $false
    if ($assetUrl) { $ok = Get-File $assetUrl $arch }
    if (-not $ok) {
        Write-Host "  GitHub mirror unavailable - falling back to gyan.dev (slower)..."
        $arch = Join-Path $FfmpegDir "ffmpeg-dl.$ext"
        $ok = Get-File "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.$ext" $arch
    }
    if (-not $ok) { Write-Host "ERROR: could not download FFmpeg from any source."; Stop-Transcript | Out-Null; exit 1 }
    $dlSecs = [math]::Round(((Get-Date) - $dlStart).TotalSeconds, 1)
    Write-Host "  Download took: ${dlSecs}s"
    $extractDir = Join-Path $FfmpegDir "_extract"
    if ($7zExe) { & $7zExe x $arch "-o$extractDir" -y | Out-Null } else { Expand-Archive -Path $arch -DestinationPath $extractDir -Force }
    $ProgressPreference = $oldProgressPref
    # Flatten: move bin/ contents straight into $FfmpegDir, discard the rest (docs/license/src not needed).
    $binDir = Find-InDir $extractDir "ffmpeg.exe" | Split-Path -Parent
    Get-ChildItem -Path $binDir | Move-Item -Destination $FfmpegDir -Force
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $arch -Force -ErrorAction SilentlyContinue
    $ffmpegExe  = Find-InDir $FfmpegDir "ffmpeg.exe"
    $ffprobeExe = Find-InDir $FfmpegDir "ffprobe.exe"
    if (-not $ffmpegExe) { Write-Host "ERROR: ffmpeg.exe not found after download."; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "  Installed: $ffmpegExe"
}
if (-not $ffprobeExe) {
    $c = $ffmpegExe -replace "ffmpeg\.exe$","ffprobe.exe"
    if (Test-Path $c) { $ffprobeExe = $c }
}
if (-not $ffprobeExe) { Write-Host "ERROR: ffprobe.exe not found."; Stop-Transcript | Out-Null; exit 1 }
Write-Host "  ffmpeg : $ffmpegExe"
Write-Host "  ffprobe: $ffprobeExe"

# ── Dispatch ──────────────────────────────────────────────────────────────────
switch ($choice) {
    "1" { Invoke-Compress }
    "2" { Invoke-LandscapeFill }
    "3" { Invoke-CropFix }
    "4" { Invoke-Trim }
    "5" { Invoke-Merge }
}

# ── Finish ────────────────────────────────────────────────────────────────────
$totalSec = [int]((Get-Date) - $SessionStart).TotalSeconds
Write-Host ""
Write-Host "=== Complete ==="
Write-Host "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Elapsed : $([int]($totalSec/60))m $($totalSec%60)s"
Write-Host "Log     : $LogFile"
Write-Host ""
Stop-Transcript | Out-Null
