param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile
)

# ──────────────────────────────────────────────────────────────────────────────
# CONFIG - edit once to suit your setup
$OutputDir = "C:\Users\David\Videos\Processed"
# ──────────────────────────────────────────────────────────────────────────────

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
$FfmpegDir    = Join-Path $RepoRoot "dependencies\ffmpeg"
$LogDir       = Join-Path $RepoRoot "data\logs"
$SessionStart = Get-Date

if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: File not found: $InputFile"
    exit 1
}

$inputDir  = Split-Path -Parent $InputFile
$inputBase = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
$outDir    = if ($OutputDir -and $OutputDir.Trim()) { $OutputDir } else { $inputDir }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$inputSizeMB     = [math]::Round((Get-Item $InputFile).Length / 1MB, 2)
$quarterSizeMB   = [math]::Round($inputSizeMB * 0.25, 2)
$halfSizeMB      = [math]::Round($inputSizeMB * 0.5, 2)

Write-Host ""
Write-Host "=== FFMPEG Kit ==="
Write-Host "Input : $InputFile  (${inputSizeMB} MB)"
if ($outDir -ne $inputDir) { Write-Host "Output: $outDir" }
Write-Host ""
Write-Host "  [1] Compress to target size"
Write-Host "  [2] Portrait to landscape  (blur-fill 1280x720, removes black bars)"
Write-Host "  [3] Remove black bars only (keep original dimensions)"
Write-Host ""
$choice = Read-Host "  Choose (1-3)"
Write-Host ""

if ($choice -notin @("1","2","3")) {
    Write-Host "Invalid choice."
    exit 1
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir "ffkit_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Start-Transcript -Path $LogFile -NoClobber | Out-Null

$toolName = switch ($choice) { "1" { "Compress" } "2" { "Landscape blur-fill" } "3" { "Remove black bars" } }
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
    if ($7zExe) {
        $arch = Join-Path $FfmpegDir "ffmpeg-dl.7z"
        Write-Host "  Downloading 7z archive (~32 MB)..."
        Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.7z" -OutFile $arch -UseBasicParsing
        & $7zExe x $arch "-o$FfmpegDir" -y | Out-Null
    } else {
        $arch = Join-Path $FfmpegDir "ffmpeg-dl.zip"
        Write-Host "  Downloading zip (~80 MB). Install 7-Zip for the smaller archive next time."
        Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $arch -UseBasicParsing
        Expand-Archive -Path $arch -DestinationPath $FfmpegDir -Force
    }
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

    $audioBps = if ($dur -gt 600) { 48 } elseif ($dur -gt 300) { 64 } else { 96 }
    $targetBytes  = $TargetMB * 1024 * 1024 * 0.98
    $vidBitrateK  = [int]([math]::Max(5, ($targetBytes * 8 / $dur - $audioBps * 1000) / 1000))
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
        $outMB  = [math]::Round((Get-Item $outputFile).Length/1MB,2)
        $ratio  = [math]::Round((Get-Item $outputFile).Length/(Get-Item $InputFile).Length*100,1)
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
            Write-Host "  Found  : crop=${cW}:${cH}:${cX}:${cY}  (removing top=$cY  bottom=$(${origH}-$cY-$cH)  left=$cX  right=$(${origW}-$cX-$cW))"
        } else {
            Write-Host "  None   : no significant black bars found."
        }
    } else {
        Write-Host "  None   : cropdetect returned no crop."
    }
    Write-Host "  Detection: $([int]((Get-Date)-$t).TotalSeconds)s"
    return $cW, $cH, $cX, $cY, $found
}
