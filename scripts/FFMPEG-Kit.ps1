param(
    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$InputFiles,

    # Non-interactive mode: pass these to skip all Read-Host prompts (for scripted/Claude use).
    # -Action: compress|landscape|cropfix|trim|merge|mp3 (or "1".."6")
    [string]$Action = "",
    [double]$TargetMB = 0,               # for -Action compress
    [string[]]$ClipArgs = @(),           # for -Action trim, e.g. "6:01-6:34","8:54-9:24" (blank end = "to end of file", e.g. "20:55-")
    [string]$TrimMode = "fast"           # for -Action trim: "fast" (stream copy, keyframe-accurate, seconds) or "precise" (re-encode, frame-accurate, slow)
)

# ──────────────────────────────────────────────────────────────────────────────
# CONFIG - edit once to suit your setup
$OutputDir = "$env:USERPROFILE\Downloads"   # Empty = output alongside input
# ──────────────────────────────────────────────────────────────────────────────

$InputFile = $InputFiles[0]
$ActionMap = @{ "compress"="1"; "landscape"="2"; "cropfix"="3"; "trim"="4"; "merge"="5"; "mp3"="6" }
$ActionNum = if ($Action -and $ActionMap.ContainsKey($Action.ToLower())) { $ActionMap[$Action.ToLower()] } elseif ($Action) { $Action } else { "" }

# ==============================================================================
# HELPER: Duration / time-string conversions shared by the tools below
# ==============================================================================
function Get-VideoDuration([string]$File) {
    $raw = (& $ffprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$File" 2>&1 | Out-String).Trim()
    [double]$d = 0.0
    if ([double]::TryParse($raw,[ref]$d)) { return $d }
    return 0.0
}

function ConvertTo-Seconds([string]$TimeStr) {
    if (-not $TimeStr) { return 0.0 }
    $sec = 0.0
    foreach ($p in ($TimeStr -split ':')) { $sec = $sec * 60 + [double]$p }
    return $sec
}

function Format-Seconds([double]$Sec) {
    if ($Sec -lt 0) { $Sec = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Round($Sec))
    if ($ts.TotalHours -ge 1) { return $ts.ToString("hh\:mm\:ss") }
    return $ts.ToString("mm\:ss")
}

# ProcessStartInfo.ArgumentList isn't present on this box's Windows PowerShell 5.1 / .NET Framework
# build (tested: it comes back $null, so .Add() throws) - build a single quoted Arguments string
# instead, using the same escaping rules CommandLineToArgvW expects (this is what correctly
# round-trips paths/filters with spaces or quotes, unlike the old bare string-interpolation calls).
function ConvertTo-QuotedArg([string]$Arg) {
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Arg.Length) {
        $numBackslashes = 0
        while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $numBackslashes++; $i++ }
        if ($i -eq $Arg.Length) {
            [void]$sb.Append('\' * ($numBackslashes * 2))
            break
        } elseif ($Arg[$i] -eq '"') {
            [void]$sb.Append('\' * ($numBackslashes * 2 + 1))
            [void]$sb.Append('"')
            $i++
        } else {
            [void]$sb.Append('\' * $numBackslashes)
            [void]$sb.Append($Arg[$i])
            $i++
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# ==============================================================================
# HELPER: Run ffmpeg with a single self-overwriting progress line on the
# terminal, while the log file keeps ffmpeg's own diagnostic detail.
#
# Design note (tested empirically, not assumed): Start-Transcript holds an
# EXCLUSIVE file handle on $LogFile for the whole run on Windows - both a
# direct `2>>` append from a second process and Add-Content against the
# open-transcript file throw "The process cannot access the file ... because
# it is being used by another process." So ffmpeg's raw stderr can't append
# to the transcript log directly; it goes to a sibling file instead
# ($script:FfmpegRawLog, set up in MAIN), whose path is printed once near the
# top of the transcript log and on any failure.
#
# -LogLevel defaults to "error" so the console (via -progress pipe:1 on a
# separate stdout channel) only shows the clean progress line, not ffmpeg's
# codec banner - real errors still land in $script:FfmpegRawLog. Callers that
# need ffmpeg's normal-verbosity stderr for their own parsing (cropdetect)
# can override -LogLevel; -progress reporting is independent of loglevel.
# ==============================================================================
function Invoke-FfmpegWithProgress {
    param(
        [Parameter(Mandatory=$true)][string[]]$FfmpegArgs,
        [double]$DurationSec = 0,
        [string]$Label = "Encoding",
        [string]$LogLevel = "error"
    )

    $fullArgs = $FfmpegArgs + @("-loglevel", $LogLevel, "-progress", "pipe:1")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $ffmpegExe
    $psi.Arguments = ($fullArgs | ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stderrSb  = New-Object System.Text.StringBuilder
    $errAction = {
        if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    }
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errAction -MessageData $stderrSb

    [void]$proc.Start()
    $proc.BeginErrorReadLine()

    $overallSw  = [System.Diagnostics.Stopwatch]::StartNew()
    $throttleSw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLen    = 0
    $curOutSec  = 0.0
    $curSpeed   = ""

    while ($true) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }

        if ($line -match '^out_time_ms=(-?\d+)') {
            $curOutSec = [double]$Matches[1] / 1000000.0
        } elseif ($line -match '^out_time=(\d+):(\d+):([\d.]+)') {
            $curOutSec = [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [double]$Matches[3]
        } elseif ($line -match '^speed=\s*([\d.]+)x') {
            $curSpeed = $Matches[1]
        }

        $isEnd = $line -match '^progress=end'
        if ($isEnd -or $throttleSw.Elapsed.TotalSeconds -ge 0.5) {
            if ($DurationSec -gt 0) {
                $pct = [math]::Min(100, [math]::Max(0, ($curOutSec / $DurationSec) * 100))
                $rendered = "  ${Label}: $([math]::Round($pct))% ($(Format-Seconds $curOutSec)/$(Format-Seconds $DurationSec)$(if ($curSpeed) { ", ${curSpeed}x" }))"
            } else {
                $rendered = "  ${Label}: $(Format-Seconds $overallSw.Elapsed.TotalSeconds) elapsed$(if ($curSpeed) { " (${curSpeed}x)" })"
            }
            $pad = [math]::Max(0, $lastLen - $rendered.Length)
            Write-Host -NoNewline ("`r" + $rendered + (" " * $pad))
            $lastLen = $rendered.Length
            $throttleSw.Restart()
        }
    }
    Write-Host ""   # end the self-overwriting line

    $proc.WaitForExit()
    Unregister-Event -SourceIdentifier $errSub.Name -EA SilentlyContinue
    Remove-Job -Name $errSub.Name -Force -EA SilentlyContinue
    $exitCode = $proc.ExitCode

    $header = "===== $Label : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') : exit=$exitCode ====="
    Add-Content -Path $script:FfmpegRawLog -Value $header
    if ($stderrSb.Length -gt 0) { Add-Content -Path $script:FfmpegRawLog -Value $stderrSb.ToString().TrimEnd() }

    return [PSCustomObject]@{ ExitCode = $exitCode; StdErr = $stderrSb.ToString() }
}

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

    if ($TargetMB -gt 0) {
        Write-Host "  Target size: ${TargetMB} MB (from -TargetMB)"
    } else {
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
    $p1Args = @("-nostdin","-y","-i",$InputFile,"-c:v","libx264","-preset","slow","-profile:v","high",
                "-b:v","${vidBitrateK}k","-pass","1","-passlogfile",$passlog,"-an","-f","null","NUL")
    $r1 = Invoke-FfmpegWithProgress -FfmpegArgs $p1Args -DurationSec $dur -Label "Pass 1/2"
    if ($r1.ExitCode -ne 0) { Write-Host "ERROR: Pass 1 failed. See raw ffmpeg log: $script:FfmpegRawLog"; Remove-Item "${passlog}*" -EA SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }

    $p2Args = @("-nostdin","-y","-i",$InputFile,"-c:v","libx264","-preset","slow","-profile:v","high",
                "-b:v","${vidBitrateK}k","-pass","2","-passlogfile",$passlog,
                "-c:a","aac","-b:a","${audioBps}k","-af","aresample=async=1","-movflags","+faststart",$outputFile)
    $r2 = Invoke-FfmpegWithProgress -FfmpegArgs $p2Args -DurationSec $dur -Label "Pass 2/2"
    if ($r2.ExitCode -ne 0) { Write-Host "ERROR: Pass 2 failed. See raw ffmpeg log: $script:FfmpegRawLog"; Remove-Item "${passlog}*" -EA SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }
    Remove-Item "${passlog}*" -EA SilentlyContinue
    Write-Host "  Encode: $([int]((Get-Date)-$t3).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    if (Test-Path -LiteralPath $outputFile) {
        $outMB = [math]::Round((Get-Item -LiteralPath $outputFile).Length/1MB,2)
        $ratio = [math]::Round((Get-Item -LiteralPath $outputFile).Length/(Get-Item -LiteralPath $InputFile).Length*100,1)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  (target: ${TargetMB} MB,  ${ratio}% of original)"
        if ((Get-Item -LiteralPath $outputFile).Length -gt $TargetMB*1024*1024) {
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
    $dur = Get-VideoDuration $InputFile

    if ($hasCrop) {
        $fc = "[0:v]crop=${cropW}:${cropH}:${cropX}:${cropY},split[c1][c2];[c1]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,boxblur=15:5[bg];[c2]scale=1280:720:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
    } else {
        $fc = "[0:v]split[c1][c2];[c1]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,boxblur=15:5[bg];[c2]scale=1280:720:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
    }

    $encArgs = @("-nostdin","-y","-i",$InputFile,"-filter_complex",$fc,"-map","[out]","-map","0:a?",
                 "-c:v","libx264","-preset","fast","-crf","18",
                 "-c:a","aac","-b:a","128k","-movflags","+faststart",$outputFile)
    $r = Invoke-FfmpegWithProgress -FfmpegArgs $encArgs -DurationSec $dur -Label "Encoding"
    if ($r.ExitCode -ne 0) { Write-Host "ERROR: Encode failed. See raw ffmpeg log: $script:FfmpegRawLog"; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "  Encode: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    if (Test-Path -LiteralPath $outputFile) {
        $outMB = [math]::Round((Get-Item -LiteralPath $outputFile).Length/1MB,2)
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
    $dur = Get-VideoDuration $InputFile

    $encArgs = @("-nostdin","-y","-i",$InputFile,"-vf","crop=${cropW}:${cropH}:${cropX}:${cropY}",
                 "-c:v","libx264","-preset","fast","-crf","18",
                 "-c:a","copy","-movflags","+faststart",$outputFile)
    $r = Invoke-FfmpegWithProgress -FfmpegArgs $encArgs -DurationSec $dur -Label "Encoding"
    if ($r.ExitCode -ne 0) { Write-Host "ERROR: Encode failed. See raw ffmpeg log: $script:FfmpegRawLog"; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "  Encode: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    if (Test-Path -LiteralPath $outputFile) {
        $outMB = [math]::Round((Get-Item -LiteralPath $outputFile).Length/1MB,2)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  (${cropW}x${cropH})"
    } else { Write-Host "  ERROR: Output not created." }
}


# ==============================================================================
# TOOL: Trim clip(s) from a single file (visually lossless re-encode)
# ==============================================================================
function Invoke-Trim {
    $clips = @()
    if ($ClipArgs.Count -gt 0) {
        Write-Host ""
        Write-Host "[2] Using clips from -ClipArgs argument:"
        foreach ($c in $ClipArgs) {
            $parts = $c -split '-', 2
            if ($parts.Count -ne 2) { Write-Host "ERROR: Invalid clip format '$c' - expected 'start-end' (blank end = to EOF)."; Stop-Transcript | Out-Null; exit 1 }
            $endLabel = if ($parts[1].Trim()) { $parts[1].Trim() } else { "(end of file)" }
            Write-Host "  $($parts[0].Trim()) -> $endLabel"
            $clips += [PSCustomObject]@{ Start = $parts[0].Trim(); End = $parts[1].Trim() }
        }
    } else {
        Write-Host ""
        Write-Host "[2] Enter clips to extract (HH:MM:SS or MM:SS). Blank start to finish, blank end = to EOF."
        while ($true) {
            Write-Host ""
            $s = Read-Host "  Clip $($clips.Count + 1) start (blank to finish)"
            if (-not $s -or -not $s.Trim()) { break }
            $e = Read-Host "  Clip $($clips.Count + 1) end (blank = to end of file)"
            $clips += [PSCustomObject]@{ Start = $s.Trim(); End = $e.Trim() }
        }
    }
    if ($clips.Count -eq 0) {
        Write-Host "  No clips entered - nothing to do."
        Stop-Transcript | Out-Null; exit 0
    }

    $ext = [System.IO.Path]::GetExtension($InputFile)
    $modeDesc = if ($TrimMode -eq "fast") { "stream copy, keyframe-accurate, no re-encode" } else { "re-encode, frame-accurate, visually lossless" }
    Write-Host ""
    Write-Host "[3] Trimming $($clips.Count) clip(s) ($modeDesc)..."
    $t = Get-Date
    $outFiles = @()
    for ($i = 0; $i -lt $clips.Count; $i++) {
        $c = $clips[$i]
        $suffix = if ($clips.Count -gt 1) { "_clip$($i+1)" } else { "_clip" }
        $clipFile = Join-Path $outDir "${inputBase}${suffix}${ext}"
        $endLabel = if ($c.End) { $c.End } else { "EOF" }
        Write-Host "  Clip $($i+1): $($c.Start) -> $endLabel"
        if ($TrimMode -eq "fast") {
            # Input seeking (-ss before -i) + stream copy: near-instant, no quality loss.
            # Cut lands on the nearest keyframe at/before the requested start (usually within ~1-2s for typical GOP sizes).
            # Sub-second op - no live progress line, but stderr still goes to the raw log, not the console.
            # (Captured via 2>&1 + Add-Content rather than a native `2>>` redirect - the latter writes
            # UTF-16 while Add-Content's default encoding is single-byte, and mixing the two in one file
            # garbles it; this keeps every write to $script:FfmpegRawLog on the same encoding.)
            if ($c.End) {
                $fastErr = & $ffmpegExe -nostdin -y -ss $c.Start -i "$InputFile" -to $c.End -c copy -avoid_negative_ts make_zero "$clipFile" 2>&1
            } else {
                $fastErr = & $ffmpegExe -nostdin -y -ss $c.Start -i "$InputFile" -c copy -avoid_negative_ts make_zero "$clipFile" 2>&1
            }
            $fastExit = $LASTEXITCODE
            Add-Content -Path $script:FfmpegRawLog -Value "===== Trim clip $($i+1) (fast) : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') : exit=$fastExit ====="
            if ($fastErr) { Add-Content -Path $script:FfmpegRawLog -Value (($fastErr | Out-String).TrimEnd()) }
            if ($fastExit -ne 0) { Write-Host "ERROR: Trim failed for clip $($i+1). See raw ffmpeg log: $script:FfmpegRawLog"; Stop-Transcript | Out-Null; exit 1 }
        } else {
            # Output seeking (-ss after -i) + re-encode: exact frame cut, but decodes from the start of the file - slow on large files.
            $clipStartSec = ConvertTo-Seconds $c.Start
            if ($c.End) {
                $clipDur  = (ConvertTo-Seconds $c.End) - $clipStartSec
                $trimArgs = @("-nostdin","-y","-i",$InputFile,"-ss",$c.Start,"-to",$c.End,"-c:v","libx265","-preset","slow","-crf","16","-c:a","ac3","-b:a","224k",$clipFile)
            } else {
                if (-not $script:trimFileDur) { $script:trimFileDur = Get-VideoDuration $InputFile }
                $clipDur  = $script:trimFileDur - $clipStartSec
                $trimArgs = @("-nostdin","-y","-i",$InputFile,"-ss",$c.Start,"-c:v","libx265","-preset","slow","-crf","16","-c:a","ac3","-b:a","224k",$clipFile)
            }
            $label = if ($clips.Count -gt 1) { "Trimming clip $($i+1)/$($clips.Count)" } else { "Trimming" }
            $r = Invoke-FfmpegWithProgress -FfmpegArgs $trimArgs -DurationSec $clipDur -Label $label
            if ($r.ExitCode -ne 0) { Write-Host "ERROR: Trim failed for clip $($i+1). See raw ffmpeg log: $script:FfmpegRawLog"; Stop-Transcript | Out-Null; exit 1 }
        }
        $outFiles += $clipFile
    }
    Write-Host "  Trim: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[4] Results"
    foreach ($f in $outFiles) {
        if (Test-Path -LiteralPath $f) {
            $outMB = [math]::Round((Get-Item -LiteralPath $f).Length/1MB,2)
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
    # Sub-second op when it works - no live progress line, but stderr still goes to the raw log, not the
    # console (captured via 2>&1 + Add-Content, see the matching comment in Invoke-Trim's fast path).
    $copyErr  = & $ffmpegExe -nostdin -y -f concat -safe 0 -i "$listFile" -c copy "$outputFile" 2>&1
    $copyExit = $LASTEXITCODE
    Add-Content -Path $script:FfmpegRawLog -Value "===== Merge (stream copy) : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') : exit=$copyExit ====="
    if ($copyErr) { Add-Content -Path $script:FfmpegRawLog -Value (($copyErr | Out-String).TrimEnd()) }
    $copyOk = ($copyExit -eq 0) -and (Test-Path -LiteralPath $outputFile) -and ((Get-Item -LiteralPath $outputFile).Length -gt 0)

    if (-not $copyOk) {
        Write-Host "  Stream copy failed (mismatched codecs/params) - re-encoding instead..."
        Remove-Item -LiteralPath $outputFile -Force -EA SilentlyContinue
        $n = $InputFiles.Count
        $concatInputs = (0..($n-1) | ForEach-Object { "[$_`:v:0][$_`:a:0]" }) -join ""
        $fc = "${concatInputs}concat=n=${n}:v=1:a=1[v][a]"
        $reArgs = @("-nostdin","-y")
        foreach ($f in $InputFiles) { $reArgs += @("-i", $f) }
        $reArgs += @("-filter_complex",$fc,"-map","[v]","-map","[a]","-c:v","libx265","-preset","slow","-crf","16","-c:a","ac3","-b:a","224k",$outputFile)
        $mergeDur = ($InputFiles | ForEach-Object { Get-VideoDuration $_ } | Measure-Object -Sum).Sum
        $r = Invoke-FfmpegWithProgress -FfmpegArgs $reArgs -DurationSec $mergeDur -Label "Merging"
        if ($r.ExitCode -ne 0) { Write-Host "ERROR: Merge failed. See raw ffmpeg log: $script:FfmpegRawLog"; Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }
    } else {
        Write-Host "  Stream copy succeeded."
    }
    Write-Host "  Merge: $([int]((Get-Date)-$t).TotalSeconds)s"
    Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue

    Write-Host ""
    Write-Host "[3] Results"
    if (Test-Path -LiteralPath $outputFile) {
        $outMB = [math]::Round((Get-Item -LiteralPath $outputFile).Length/1MB,2)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  ($($InputFiles.Count) files merged)"
    } else { Write-Host "  ERROR: Output not created." }
}


# ==============================================================================
# TOOL: Convert any format to MP3 (audio-only, VBR high quality)
# ==============================================================================
function Invoke-ConvertMp3 {
    $outputFile = Join-Path $outDir "${inputBase}.mp3"
    Write-Host ""
    Write-Host "[2] Converting to MP3..."
    $t = Get-Date
    $dur = Get-VideoDuration $InputFile

    $convArgs = @("-nostdin","-y","-i",$InputFile,"-vn","-c:a","libmp3lame","-q:a","0",$outputFile)
    $r = Invoke-FfmpegWithProgress -FfmpegArgs $convArgs -DurationSec $dur -Label "Converting"
    if ($r.ExitCode -ne 0) { Write-Host "ERROR: Conversion failed. See raw ffmpeg log: $script:FfmpegRawLog"; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "  Convert: $([int]((Get-Date)-$t).TotalSeconds)s"

    Write-Host ""
    Write-Host "[3] Results"
    if (Test-Path -LiteralPath $outputFile) {
        $outMB = [math]::Round((Get-Item -LiteralPath $outputFile).Length/1MB,2)
        Write-Host "  Output : $outputFile"
        Write-Host "  Size   : ${outMB} MB  (MP3, VBR ~245kbps avg)"
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
    # cropdetect's own crop=W:H:X:Y values are logged at normal (not "error") verbosity, so this call
    # keeps -LogLevel at ffmpeg's default and parses them out of the captured stderr - it's a scan, not
    # an encode, so DurationSec is intentionally omitted and the progress line shows elapsed time only.
    $scanArgs  = @("-nostdin","-i",$InputFile,"-t","$scanSec","-vf","cropdetect=limit=24:round=2:reset=0","-f","null","NUL")
    $scanResult = Invoke-FfmpegWithProgress -FfmpegArgs $scanArgs -Label "Scanning" -LogLevel "info"
    $lastMatch = ($scanResult.StdErr -split "`r?`n" | Select-String 'crop=\d+:\d+:\d+:\d+' | Select-Object -Last 1)
    $last = if ($lastMatch) { $lastMatch.ToString() } else { "" }

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
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "ERROR: File not found: $f"
        exit 1
    }
}

$multiFile     = $InputFiles.Count -gt 1
$inputDir      = Split-Path -Parent $InputFile
$inputBase     = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
$outDir        = if ($OutputDir -and $OutputDir.Trim()) { $OutputDir } else { $inputDir }
$inputSizeMB   = [math]::Round((Get-Item -LiteralPath $InputFile).Length / 1MB, 2)
$quarterSizeMB = [math]::Round($inputSizeMB * 0.25, 2)
$halfSizeMB    = [math]::Round($inputSizeMB * 0.5, 2)

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host ""
Write-Host "=== FFMPEG Kit ==="
if ($multiFile) {
    Write-Host "Input : $($InputFiles.Count) files dropped"
    $InputFiles | ForEach-Object { Write-Host "  - $_" }
    $choice = if ($ActionNum) { $ActionNum } else { "5" }
} elseif ($ActionNum) {
    Write-Host "Input : $InputFile  (${inputSizeMB} MB)"
    Write-Host "Action: $ActionNum (from -Action argument)"
    $choice = $ActionNum
} else {
    Write-Host "Input : $InputFile  (${inputSizeMB} MB)"
    Write-Host ""
    Write-Host "  [1] Compress to target size"
    Write-Host "  [2] Portrait to landscape  (blur-fill 1280x720, removes black bars)"
    Write-Host "  [3] Remove black bars only (keep original dimensions)"
    Write-Host "  [4] Trim clip(s)           (cut one or more sections from this file)"
    Write-Host "  [6] Convert to MP3         (any format - audio-only, VBR high quality)"
    Write-Host ""
    $choice = Read-Host "  Choose (1-4, 6)"
}
Write-Host ""

if ($choice -notin @("1","2","3","4","5","6")) {
    Write-Host "Invalid choice."
    exit 1
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile  = Join-Path $LogDir "ffkit_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile -NoClobber | Out-Null

# Sibling file for ffmpeg's own raw stderr/diagnostic output - see the design note above
# Invoke-FfmpegWithProgress for why this can't just append into $LogFile.
$script:FfmpegRawLog = Join-Path $LogDir "$([System.IO.Path]::GetFileNameWithoutExtension($LogFile))_ffmpeg.log"
New-Item -ItemType File -Path $script:FfmpegRawLog -Force | Out-Null

$toolName = switch ($choice) { "1" { "Compress" } "2" { "Landscape blur-fill" } "3" { "Remove black bars" } "4" { "Trim clip(s)" } "5" { "Merge files" } "6" { "Convert to MP3" } }
Write-Host "=== FFMPEG Kit - $toolName ==="
Write-Host "Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Input   : $InputFile"
Write-Host "FFmpeg log: $script:FfmpegRawLog"
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
    "6" { Invoke-ConvertMp3 }
}

# ── Finish ────────────────────────────────────────────────────────────────────
$totalSec = [int]((Get-Date) - $SessionStart).TotalSeconds
Write-Host ""
Write-Host "=== Complete ==="
Write-Host "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Elapsed : $([int]($totalSec/60))m $($totalSec%60)s"
Write-Host "Log     : $LogFile"
Write-Host "FFmpeg  : $script:FfmpegRawLog"
Write-Host ""
Stop-Transcript | Out-Null
