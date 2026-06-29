#Requires -RunAsAdministrator
<#
.SYNOPSIS
    医院 VOI 胖终端打印机驱动自动安装脚本
.DESCRIPTION
    系统开机/还原后自动检测连接的打印机，优先用本地 .inf 驱动静默安装，
    失败时回退到 SDIO 脚本模式安装，仍失败则弹出 SDIO GUI 供手动操作。
    支持 -OnInsert 参数，由 USB 设备插入事件触发时使用。
.NOTES
    所有路径由 config.ini 配置文件指定：BaseDir（脚本/程序）、DataDir（驱动/日志）
    支持程序和数据分盘部署，适配系统还原场景
    config.ini 需与本脚本放在同一目录下
    需要管理员权限运行
#>

param(
    # 由 USB 插入事件触发时传入，增加防抖等待并跳过 SDIO GUI 弹窗
    [switch]$OnInsert
)

# ============================================================
# 读取配置文件（config.ini 与本脚本同目录）
# ============================================================
$ConfigFile = "$PSScriptRoot\config.ini"
if (-not (Test-Path $ConfigFile)) {
    Write-Error "配置文件不存在: $ConfigFile"
    Write-Host "请确保 config.ini 与本脚本在同一目录下"
    exit 1
}

$BaseDir       = $null
$DataDir       = $null
$LogRetainDays = 30

foreach ($line in Get-Content $ConfigFile -Encoding UTF8) {
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { continue }
    $key = $parts[0].Trim()
    $val = $parts[1].Trim()
    switch ($key) {
        'BaseDir'       { $BaseDir       = $val }
        'DataDir'       { $DataDir       = $val }
        'LogRetainDays' { $LogRetainDays = [int]$val }
    }
}

if (-not $BaseDir) {
    Write-Error "config.ini 中未配置 BaseDir"
    exit 1
}

# DataDir 未设置时与 BaseDir 相同（单目录部署模式）
if (-not $DataDir) { $DataDir = $BaseDir }

$DriverDir     = "$DataDir\drivers"          # .inf 驱动文件（按型号分子目录，持久化）
$SDIODir       = "$BaseDir\SDIO"             # SDIO 程序目录（随镜像）
$SDIOScript    = "$BaseDir\auto_printer.txt" # SDIO 脚本文件
$LogDir        = "$DataDir\logs"
$LogFile       = "$LogDir\install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ============================================================
# 日志函数
# ============================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ============================================================
# 初始化
# ============================================================
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

Write-Log "========== 打印机驱动自动安装开始 =========="
Write-Log "计算机名: $env:COMPUTERNAME"

# 清理旧日志
Get-ChildItem -Path $LogDir -Filter "install_*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetainDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ============================================================
# 防抖等待（USB插入触发时）
# ============================================================
if ($OnInsert) {
    Write-Log "由 USB 设备插入事件触发，等待 8 秒让设备完成枚举..."
    Start-Sleep -Seconds 8
}

# ============================================================
# 阶段1: 检测连接的打印机
# ============================================================
Write-Log "--- 阶段1: 检测打印机设备 ---"

$printers = @()

# 方法1: 通过 Get-PnpDevice 获取打印机类设备
try {
    $pnpPrinters = Get-PnpDevice -Class Printer -Status OK -ErrorAction Stop
    foreach ($p in $pnpPrinters) {
        $hwids = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_HardwareIds" -InstanceId $p.InstanceId -ErrorAction SilentlyContinue
        if ($hwids -and $hwids.Data) {
            $printers += [PSCustomObject]@{
                Name       = $p.FriendlyName
                InstanceId = $p.InstanceId
                HWIDs      = $hwids.Data
                Status     = "Connected"
            }
        }
    }
} catch {
    Write-Log "Get-PnpDevice 查询失败: $_" WARN
}

# 方法2: 补充检查 USB 打印类设备（有些打印机不注册为 Printer class）
try {
    $usbPrinters = Get-PnpDevice -Status OK -ErrorAction Stop |
        Where-Object { $_.InstanceId -match "^USB\\.*&.*&.*PRINT" -or $_.Class -eq "USB" -and $_.FriendlyName -match "print" }
    foreach ($p in $usbPrinters) {
        $alreadyFound = $printers | Where-Object { $_.InstanceId -eq $p.InstanceId }
        if (-not $alreadyFound) {
            $hwids = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_HardwareIds" -InstanceId $p.InstanceId -ErrorAction SilentlyContinue
            if ($hwids -and $hwids.Data) {
                $printers += [PSCustomObject]@{
                    Name       = $p.FriendlyName
                    InstanceId = $p.InstanceId
                    HWIDs      = $hwids.Data
                    Status     = "Connected"
                }
            }
        }
    }
} catch {
    # 忽略，不是所有系统都支持
}

if ($printers.Count -eq 0) {
    Write-Log "未检测到连接的打印机，退出" INFO
    Write-Log "========== 自动安装结束 =========="
    exit 0
}

Write-Log "检测到 $($printers.Count) 台打印机:"
foreach ($p in $printers) {
    Write-Log "  - $($p.Name) | HWID: $($p.HWIDs -join ', ')"
}

# ============================================================
# 阶段2: 检查已安装的驱动，跳过已有驱动的打印机
# ============================================================
Write-Log "--- 阶段2: 检查驱动状态 ---"

$needInstall = @()
foreach ($p in $printers) {
    # 检查设备是否已有驱动（Driver 属性非空 = 已安装）
    $driverInfo = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_Driver" -InstanceId $p.InstanceId -ErrorAction SilentlyContinue
    if ($driverInfo -and $driverInfo.Data) {
        Write-Log "  $($p.Name): 已有驱动 [$($driverInfo.Data)]，跳过"
    } else {
        Write-Log "  $($p.Name): 缺少驱动，需要安装"
        $needInstall += $p
    }
}

if ($needInstall.Count -eq 0) {
    Write-Log "所有打印机驱动已安装，无需操作"
    Write-Log "========== 自动安装结束 =========="
    exit 0
}

Write-Log "需要安装驱动的打印机: $($needInstall.Count) 台"

# ============================================================
# 阶段3: 用本地 .inf 文件静默安装（pnputil）
# ============================================================
Write-Log "--- 阶段3: 本地 .inf 驱动安装 ---"

$installed = @()
$failed    = @()

foreach ($printer in $needInstall) {
    $success = $false
    $matchedInf = $null

    Write-Log "  尝试安装: $($printer.Name) | HWID: $($printer.HWIDs[0])"

    # 遍历 drivers 目录下的所有 .inf 文件
    if (Test-Path $DriverDir) {
        $infFiles = Get-ChildItem -Path $DriverDir -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue

        foreach ($inf in $infFiles) {
            # 读取 .inf 文件内容，检查是否包含该打印机的 HWID
            $infContent = Get-Content -Path $inf.FullName -ErrorAction SilentlyContinue -Encoding Default

            foreach ($hwid in $printer.HWIDs) {
                # HWID 匹配：.inf 中的 HardwareID 段包含此 HWID
                if ($infContent -match [regex]::Escape($hwid)) {
                    $matchedInf = $inf.FullName
                    Write-Log "    匹配到驱动: $($inf.FullName)"

                    # 使用 pnputil 添加驱动到驱动存储
                    $addResult = & pnputil /add-driver "$($inf.FullName)" /install 2>&1
                    $exitCode = $LASTEXITCODE

                    if ($exitCode -eq 0 -or ($addResult -match "Driver package added successfully")) {
                        Write-Log "    pnputil 安装成功"
                        $success = $true
                    } else {
                        Write-Log "    pnputil 安装失败 (exit=$exitCode): $addResult" WARN
                    }
                    break
                }
            }
            if ($success) { break }
        }
    }

    if ($success) {
        $installed += $printer
    } else {
        if (-not $matchedInf) {
            Write-Log "    未找到匹配的 .inf 驱动文件" WARN
        }
        $failed += $printer
    }
}

Write-Log "本地安装结果: 成功 $($installed.Count), 失败 $($failed.Count)"

# ============================================================
# 阶段4: 失败的打印机 → SDIO 脚本模式尝试
# ============================================================
if ($failed.Count -gt 0) {
    Write-Log "--- 阶段4: SDIO 脚本模式回退 ---"

    # 分盘部署时，创建 junction 让 SDIO 找到持久化盘上的驱动包
    if ($DataDir -ne $BaseDir) {
        $junctionTarget = "$DataDir\SDIO\drivers"
        $junctionLink   = "$SDIODir\drivers"
        if (-not (Test-Path $junctionTarget)) {
            New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        }
        if (-not (Test-Path $junctionLink)) {
            cmd /c mklink /J "$junctionLink" "$junctionTarget" 2>&1 | Out-Null
            Write-Log "  创建驱动包链接: $junctionLink -> $junctionTarget"
        }
    }

    $sdioExe = Get-ChildItem -Path $SDIODir -Filter "SDIO_x64*.exe" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1

    if (-not $sdioExe) {
        # 尝试 32 位版本
        $sdioExe = Get-ChildItem -Path $SDIODir -Filter "SDIO_*R*.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "x64" } |
            Sort-Object Name -Descending | Select-Object -First 1
    }

    if ($sdioExe -and (Test-Path $SDIOScript)) {
        Write-Log "  调用 SDIO 脚本模式: $($sdioExe.FullName)"
        Write-Log "  脚本: $SDIOScript"

        try {
            $sdioArgs = "/script:`"$SDIOScript`" /nogui"
            $process = Start-Process -FilePath $sdioExe.FullName -ArgumentList $sdioArgs `
                -Wait -PassThru -WindowStyle Hidden -Timeout 300
            Write-Log "  SDIO 脚本退出码: $($process.ExitCode)"

            if ($process.ExitCode -eq 0) {
                Write-Log "  SDIO 脚本安装成功"
            } else {
                Write-Log "  SDIO 脚本返回非零退出码" WARN
            }
        } catch {
            Write-Log "  SDIO 脚本执行异常: $_" ERROR
        }
    } else {
        Write-Log "  SDIO 程序或脚本文件不存在，跳过脚本模式" WARN
        if (-not $sdioExe) { Write-Log "    未找到 SDIO 可执行文件" WARN }
        if (-not (Test-Path $SDIOScript)) { Write-Log "    未找到脚本文件: $SDIOScript" WARN }
    }

    # 再次检查失败设备的驱动状态
    $stillFailed = @()
    foreach ($printer in $failed) {
        $driverInfo = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_Driver" `
            -InstanceId $printer.InstanceId -ErrorAction SilentlyContinue
        if ($driverInfo -and $driverInfo.Data) {
            Write-Log "  SDIO 成功安装了 $($printer.Name) 的驱动"
        } else {
            $stillFailed += $printer
        }
    }
    $failed = $stillFailed
}

# ============================================================
# 阶段5: 仍失败 → 弹出 SDIO GUI 供手动操作（仅开机触发时）
# ============================================================
if ($failed.Count -gt 0) {
    if ($OnInsert) {
        # USB插入触发时不弹GUI，避免打扰用户，记录失败等下次开机处理
        Write-Log "--- 阶段5: USB插入触发模式，不弹出 GUI ---"
        Write-Log "  以下打印机驱动自动安装失败，将在下次开机时重试:"
        foreach ($p in $failed) {
            Write-Log "    - $($p.Name) | $($p.HWIDs[0])"
        }
    } else {
        Write-Log "--- 阶段5: 启动 SDIO GUI 手动安装 ---"
        Write-Log "  以下打印机驱动自动安装失败:"
        foreach ($p in $failed) {
            Write-Log "    - $($p.Name) | $($p.HWIDs[0])"
        }

        $sdioExe = Get-ChildItem -Path $SDIODir -Filter "SDIO_x64*.exe" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $sdioExe) {
            $sdioExe = Get-ChildItem -Path $SDIODir -Filter "SDIO_*R*.exe" -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
        }

        if ($sdioExe) {
            Write-Log "  启动 SDIO GUI: $($sdioExe.FullName)"
            Start-Process -FilePath $sdioExe.FullName -WindowStyle Normal
            Write-Log "  SDIO GUI 已启动，等待用户手动操作"
        } else {
            Write-Log "  SDIO 程序不存在，无法启动 GUI" ERROR
        }
    }
}

# ============================================================
# 汇总
# ============================================================
Write-Log "========== 安装汇总 =========="
Write-Log "检测打印机: $($printers.Count) 台"
Write-Log "已有驱动:   $($printers.Count - $needInstall.Count) 台"
Write-Log "新安装成功: $($installed.Count) 台"
Write-Log "安装失败:   $($failed.Count) 台"
if ($failed.Count -gt 0 -and (Get-Process -Name "SDIO*" -ErrorAction SilentlyContinue)) {
    Write-Log "SDIO GUI 已打开，请手动安装剩余驱动"
}
Write-Log "========== 自动安装结束 =========="
