#Requires -RunAsAdministrator
<#
.SYNOPSIS
    将裸 .inf 驱动目录打包为 SDIO 兼容的 .7z 驱动包
.DESCRIPTION
    遍历 DataDir\drivers\ 的每个子目录，
    将其打包为 .7z 文件放入 DataDir\SDIO\drivers\ 目录。
    支持 BaseDir/DataDir 分盘部署。
.NOTES
    前提：SDIO 已安装，7z.exe 可用（SDIO 自带或系统已装）
#>

# 读取配置文件
$ConfigFile = "$PSScriptRoot\config.ini"
if (-not (Test-Path $ConfigFile)) {
    Write-Error "配置文件不存在: $ConfigFile"
    Write-Host "请确保 config.ini 与本脚本在同一目录下"
    exit 1
}

$BaseDir = $null
$DataDir = $null
foreach ($line in Get-Content $ConfigFile -Encoding UTF8) {
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { continue }
    $key = $parts[0].Trim()
    $val = $parts[1].Trim()
    switch ($key) {
        'BaseDir' { $BaseDir = $val }
        'DataDir' { $DataDir = $val }
    }
}

if (-not $BaseDir) {
    Write-Error "config.ini 中未配置 BaseDir"
    exit 1
}

# DataDir 未设置时与 BaseDir 相同
if (-not $DataDir) { $DataDir = $BaseDir }

$SourceDir = "$DataDir\drivers"          # .inf 源文件（数据盘）
$SDIODir   = "$BaseDir\SDIO"             # SDIO 程序目录（程序盘，找 7z.exe）
$OutputDir = "$DataDir\SDIO\drivers"     # .7z 输出到数据盘

# 查找 7z 可执行文件
$7zExe = $null
$searchPaths = @(
    "$env:ProgramFiles\7-Zip\7z.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
    "$SDIODir\7z.exe"
)
foreach ($p in $searchPaths) {
    if (Test-Path $p) { $7zExe = $p; break }
}
if (-not $7zExe) {
    Write-Error "未找到 7z.exe，请安装 7-Zip 或将 7z.exe 放到 $SDIODir"
    exit 1
}

Write-Host "使用 7z: $7zExe"
Write-Host "源目录: $SourceDir"
Write-Host "输出目录: $OutputDir"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# 遍历每个驱动子目录
$driverDirs = Get-ChildItem -Path $SourceDir -Directory -ErrorAction SilentlyContinue

if ($driverDirs.Count -eq 0) {
    Write-Host "drivers 目录下没有子目录，无需打包"
    exit 0
}

$packed = 0
$failed = 0

foreach ($dir in $driverDirs) {
    $infFiles = Get-ChildItem -Path $dir.FullName -Filter "*.inf" -ErrorAction SilentlyContinue
    if ($infFiles.Count -eq 0) {
        Write-Host "跳过 $($dir.Name)（无 .inf 文件）" -ForegroundColor Yellow
        continue
    }

    $packName = "DRP_Printer_$($dir.Name).7z"
    $outputPath = Join-Path $OutputDir $packName

    Write-Host "打包 $($dir.Name) -> $packName ..."

    $result = & $7zExe a -t7z -m0=lzma2 -mx=5 "$outputPath" "$($dir.FullName)\*" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  成功" -ForegroundColor Green
        $packed++
    } else {
        Write-Host "  失败: $result" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "打包完成: 成功 $packed, 失败 $failed"
Write-Host "驱动包已输出到: $OutputDir"
Write-Host ""
Write-Host "下一步: 启动 SDIO 让它自动生成索引（首次运行会自动处理）"
