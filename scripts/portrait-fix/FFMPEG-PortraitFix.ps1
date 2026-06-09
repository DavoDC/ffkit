param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile
)

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\.."))
$FfmpegDir    = Join-Path $RepoRoot "dependencies\ffmpeg"
$LogDir       = Join-Path $RepoRoot "data\logs"
$SessionStart = Get-Date

if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: File not found: $InputFile"
    exit 1
}

$inputDir  = Split-Path -Parent $InputFile
$inputBase = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)

Write-Host ""
Write-Host "=== FFMPEG Portrait Fix ==="
Write-Host "Input: $InputFile"
Write-Host ""
Write-Host "  Mode:"
Write-Host "    [1] Remove black bars only  (keep portrait, fast)"
Write-Host "    [2] Landscape blur-fill     (1280x720, blurred background - best for PC)"
Write-Host ""
$choice = Read-Host "  Choose (1-2)"
Write-Host ""

if ($choice -notin @("1","2")) {
    Write-Host "Invalid choice."
    exit 1
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir "portrait-fix_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Start-Transcript -Path $LogFile -NoClobber | Out-Null

Write-Host "=== FFMPEG Portrait Fix ==="
Write-Host "Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Input   : $InputFile"
Write-Host "Mode    : $(if ($choice -eq '1') { 'Remove black bars' } else { 'Landscape blur-fill' })"
Write-Host ""

# ── Step 1: Locate FFmpeg ─────────────────────────────────────────────────────
Write-Host "[1/4] Locating FFmpeg..."

function Find-InDir {
    param([string]$Dir, [string]$Name)
    $result = Get-ChildItem -Path $Dir -Filter $Name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($result) { return $result.FullName }
    return $null
}

$ffmpegExe  = $null
$ffprobeExe = $null

if (Test-Path $FfmpegDir) {
    $ffmpegExe  = Find-InDir $FfmpegDir "ffmpeg.exe"
    $ffprobeExe = Find-InDir $FfmpegDir "ffprobe.exe"
}

if (-not $ffmpegExe) {
    $sysFF = Get-Command "ffmpeg"  -ErrorAction SilentlyContinue
    $sysFP = Get-Command "ffprobe" -ErrorAction SilentlyContinue
    if ($sysFF) {
        $ffmpegExe  = $sysFF.Source
        $ffprobeExe = if ($sysFP) { $sysFP.Source } else { $null }
        Write-Host "  Using system FFmpeg: $ffmpegExe"
    }
}

if (-not $ffmpegExe) {
    Write-Host "  FFmpeg not found - downloading to $FfmpegDir ..."
    if (-not (Test-Path $FfmpegDir)) { New-Item -ItemType Directory -Path $FfmpegDir | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $7zExe = $null
    foreach ($candidate in @("7z", "7za", "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($candidate -match '\\') {
            if (Test-Path $candidate -ErrorAction SilentlyContinue) { $7zExe = $candidate; break }
        } else {
            if (Get-Command $candidate -ErrorAction SilentlyContinue) { $7zExe = $candidate; break }
        }
    }

    if ($7zExe) {
        $archive = Join-Path $FfmpegDir "ffmpeg-dl.7z"
        Write-Host "  Downloading 7z archive (~32 MB)..."
        Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.7z" -OutFile $archive -UseBasicParsing
        & $7zExe x $archive "-o$FfmpegDir" -y | Out-Null
    } else {
        $archive = Join-Path $FfmpegDir "ffmpeg-dl.zip"
        Write-Host "  Downloading zip archive (~80 MB). Install 7-Zip to use the smaller archive next time."
        Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $archive -UseBasicParsing
        Expand-Archive -Path $archive -DestinationPath $FfmpegDir -Force
    }

    $ffmpegExe  = Find-InDir $FfmpegDir "ffmpeg.exe"
    $ffprobeExe = Find-InDir $FfmpegDir "ffprobe.exe"

    if (-not $ffmpegExe) {
        Write-Host "ERROR: ffmpeg.exe not found after download."
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-Host "  Installed: $ffmpegExe"
}

if (-not $ffprobeExe) {
    $candidate = $ffmpegExe -replace "ffmpeg\.exe$", "ffprobe.exe"
    if (Test-Path $candidate) { $ffprobeExe = $candidate }
}
if (-not $ffprobeExe) {
    Write-Host "ERROR: ffprobe.exe not found alongside ffmpeg."
    Stop-Transcript | Out-Null
    exit 1
}

Write-Host "  ffmpeg : $ffmpegExe"
Write-Host "  ffprobe: $ffprobeExe"

# ── Step 2: Detect black bars ─────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/4] Detecting black bars..."
$t2Start = Get-Date

# Read duration for scan limit
$rawDuration = (& $ffprobeExe -v error -show_entries format=duration `
    -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>&1 | Out-String).Trim()
[double]$duration = 0.0
[double]::TryParse($rawDuration, [ref]$duration) | Out-Null

# Read original dimensions
$rawDims = (& $ffprobeExe -v error -select_streams v:0 `
    -show_entries stream=width,height `
    -of csv=p=0 "$InputFile" 2>&1 | Out-String).Trim()
$dimParts  = $rawDims -split ','
$origW = [int]$dimParts[0]
$origH = [int]$dimParts[1]
Write-Host "  Original: ${origW}x${origH} ($('{0:F1}' -f $duration)s)"

# Scan up to 30s for reliable crop detection
$scanSec = [math]::Min($duration, 30)
$cropRaw = & $ffmpegExe -nostdin -i "$InputFile" -t $scanSec `
    -vf "cropdetect=limit=24:round=2:reset=0" -f null NUL 2>&1

$cropMatch = ($cropRaw | Select-String 'crop=\d+:\d+:\d+:\d+' | Select-Object -Last 1).ToString()
$cropW = $origW; $cropH = $origH; $cropX = 0; $cropY = 0
$hasCrop = $false

if ($cropMatch -match 'crop=(\d+):(\d+):(\d+):(\d+)') {
    $cropW = [int]$Matches[1]; $cropH = [int]$Matches[2]
    $cropX = [int]$Matches[3]; $cropY = [int]$Matches[4]
    # Only meaningful if it removes at least 10px from original
    if ($cropH -lt ($origH - 10) -or $cropW -lt ($origW - 10)) {
        $hasCrop = $true
        Write-Host "  Black bars found - crop: ${cropW}x${cropH} at ${cropX},${cropY}"
        $removedTop    = $cropY
        $removedBottom = $origH - $cropY - $cropH
        $removedLeft   = $cropX
        $removedRight  = $origW - $cropX - $cropW
        if ($removedTop -gt 0 -or $removedBottom -gt 0) {
            Write-Host "  Vertical bars  : top=${removedTop}px  bottom=${removedBottom}px"
        }
        if ($removedLeft -gt 0 -or $removedRight -gt 0) {
            Write-Host "  Horizontal bars: left=${removedLeft}px  right=${removedRight}px"
        }
    } else {
        Write-Host "  No significant black bars detected."
    }
} else {
    Write-Host "  No black bars detected."
}
Write-Host "  Detection time: $([int]((Get-Date) - $t2Start).TotalSeconds)s"

# ── Step 3: Encode ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/4] Encoding..."
$t3Start = Get-Date

if ($choice -eq "1") {
    # Remove black bars only
    if (-not $hasCrop) {
        Write-Host "  No black bars found - nothing to remove."
        Stop-Transcript | Out-Null
        exit 0
    }
    $suffix     = "cropfix"
    $outputFile = Join-Path $inputDir "${inputBase}_${suffix}.mp4"
    $vfFilter   = "crop=${cropW}:${cropH}:${cropX}:${cropY}"
    Write-Host "  Output: ${cropW}x${cropH}"

    & $ffmpegExe -nostdin -y -i "$InputFile" `
        -vf $vfFilter `
        -c:v libx264 -preset fast -crf 18 `
        -c:a copy `
        -movflags +faststart `
        "$outputFile"

} else {
    # Landscape blur-fill to 1280x720
    $suffix     = "landscape"
    $outputFile = Join-Path $inputDir "${inputBase}_${suffix}.mp4"
    Write-Host "  Output: 1280x720 (blur-fill)"

    # Build filter: crop if bars found, then blur-fill to 1280x720
    if ($hasCrop) {
        $filterComplex = "[0:v]crop=${cropW}:${cropH}:${cropX}:${cropY},split[c1][c2];[c1]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,boxblur=15:5[bg];[c2]scale=1280:720:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
    } else {
        $filterComplex = "[0:v]split[c1][c2];[c1]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,boxblur=15:5[bg];[c2]scale=1280:720:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
    }

    & $ffmpegExe -nostdin -y -i "$InputFile" `
        -filter_complex $filterComplex `
        -map "[out]" -map "0:a?" `
        -c:v libx264 -preset fast -crf 18 `
        -c:a aac -b:a 128k `
        -movflags +faststart `
        "$outputFile"
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Encode failed (exit code $LASTEXITCODE)"
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "  Encode time: $([int]((Get-Date) - $t3Start).TotalSeconds)s"

# ── Step 4: Results ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[4/4] Results"

if (Test-Path $outputFile) {
    $outMB = [math]::Round((Get-Item $outputFile).Length / 1MB, 2)
    $inMB  = [math]::Round((Get-Item $InputFile).Length / 1MB, 2)
    Write-Host "  Output : $outputFile"
    Write-Host "  Size   : ${outMB} MB  (was ${inMB} MB)"
} else {
    Write-Host "  ERROR: Output file was not created."
}

$totalSec = [int]((Get-Date) - $SessionStart).TotalSeconds
$elapsed  = "{0}m {1}s" -f [int]($totalSec / 60), ($totalSec % 60)

Write-Host ""
Write-Host "=== Complete ==="
Write-Host "Finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Elapsed  : $elapsed"
Write-Host "Log      : $LogFile"
Write-Host ""

Stop-Transcript | Out-Null
