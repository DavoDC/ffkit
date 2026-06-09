@echo off
title FFMPEG Portrait Fix

if "%~1"=="" (
    echo.
    echo  Usage: Drag and drop a video file onto this script.
    echo.
    cmd /k
    exit
)

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0FFMPEG-PortraitFix.ps1" "%~1"
cmd /k
