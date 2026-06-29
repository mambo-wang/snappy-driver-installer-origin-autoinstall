#Requires -RunAsAdministrator
<#
.SYNOPSIS
    医院 VOI 胖终端打印机驱动自动安装脚本
.DESCRIPTION
    系统开机/还原后自动检测连接的 USB 打印机和网络打印机，
    USB 打印机优先用本地 .inf 驱动静默安装，失败时回退到 SDIO 脚本模式，仍失败弹出 GUI。
    网络打印机根据 config.ini 中的 [Section] 配置自动创建端口、安装驱动、添加打印机。
    支持 -OnInsert 参数，由 USB 设备插入事件触发时使用。
.NOTES
    路径由 config.ini 的 DataDir 指定，脚本目录自动识别
    支持 USB 打印机 + 网络打印机
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

$BaseDir         = $PSScriptRoot
$DataDir         = $null
$LogRetainDays   = 30
$NetworkPrinters = @()

# 解析 INI 配置文件（支持 [Section] 分段）
$Config = @{ Global = @{}; Sections = @{} }
$currentSection = $null

foreach ($rawLine in Get-Content $ConfigFile -Encoding UTF8) {
    $trimmed = $rawLine.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }

    # [SectionName]
    if ($trimmed -match '^\[([^\]]+)\]$') {
        $currentSection = $matches[1]
        $Config.Sections[$currentSection] = @{}
        continue
    }

    $parts = $trimmed -split '=', 2
    if ($parts.Count -ne 2) { continue }
    $key = $parts[0].Trim()
    $val = $parts[1].Trim()

    if ($currentSection) {
        $Config.Sections[$currentSection][$key] = $val
    } else {
        $Config.Global[$key] = $val
    }
}

# 全局配置
if ($Config.Global.ContainsKey('DataDir'))      { $DataDir       = $Config.Global['DataDir'] }
if ($Config.Global.ContainsKey('LogRetainDays')) { $LogRetainDays = [int]$Config.Global['LogRetainDays'] }

# 网络打印机配置
foreach ($section in $Config.Sections.Values) {
    if ($section.ContainsKey('Name') -and $section.ContainsKey('IP') -and $section.ContainsKey('Driver')) {
        $port = 9100
        if ($section.ContainsKey('Port')) { $port = [int]$section['Port'] }
        $NetworkPrinters += [PSCustomObject]@{
            Name   = $section['Name']
            IP     = $section['IP']
            Driver = $section['Driver']
            Port   = $port
        }
    }
}

# DataDir 未设置时与脚本同目录（单目录部署模式）
if (-not $DataDir) { $DataDir = $BaseDir }

$DriverDir  = "$DataDir\drivers"          # .inf 驱动文件（按型号分子目录，持久化）
$SDIODir    = "$BaseDir\SDIO"             # SDIO 程序目录（随镜像）
$SDIOScript = "$BaseDir\auto_printer.txt" # SDIO 脚本文件
$LogDir     = "$DataDir\logs"
$LogFile    = "$LogDir\install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
# 阶段1: 检测连接的 USB 打印机
# ============================================================
Write-Log "--- 阶段1: 检测打印机设备 ---"

$printers = @()

# 方法1: 通过 Get-PnpDevice 获取打印机类设备
try {
    $pnpPrinters = Get-PnpDevice -Class Printer -Status OK -ErrorAction Stop
    foreach ($dev in $pnpPrinters) {
        $hwids = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_HardwareIds" -InstanceId $dev.InstanceId -ErrorAction SilentlyContinue
        if ($hwids -and $hwids.Data) {
            $printers += [PSCustomObject]@{
                Name       = $dev.FriendlyName
                InstanceId = $dev.InstanceId
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
        Where-Object { $_.InstanceId -match '^USB\\.*&.*&.*PRINT' -or $_.Class -eq 'USB' -and $_.FriendlyName -match 'print' }
    foreach ($dev in $usbPrinters) {
        $alreadyFound = $printers | Where-Object { $_.InstanceId -eq $dev.InstanceId }
        if (-not $alreadyFound) {
            $hwids = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_HardwareIds" -InstanceId $dev.InstanceId -ErrorAction SilentlyContinue
            if ($hwids -and $hwids.Data) {
                $printers += [PSCustomObject]@{
                    Name       = $dev.FriendlyName
                    InstanceId = $dev.InstanceId
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
    Write-Log "未检测到连接的 USB 打印机"
    if ($NetworkPrinters.Count -eq 0) {
        Write-Log "也未配置网络打印机，退出" INFO
        Write-Log "========== 自动安装结束 =========="
        exit 0
    }
    Write-Log "跳过 USB 打印机阶段，继续处理网络打印机"
}

if ($printers.Count -gt 0) {
    Write-Log "检测到 $($printers.Count) 台打印机:"
    foreach ($p in $printers) {
        Write-Log "  - $($p.Name) | HWID: $($p.HWIDs -join ', ')"
    }
}

# ============================================================
# 阶段2: 检查已安装的驱动，跳过已有驱动的打印机
# ============================================================
$needInstall = @()

if ($printers.Count -gt 0) {
    Write-Log "--- 阶段2: 检查驱动状态 ---"
    foreach ($p in $printers) {
        $driverInfo = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_Driver" -InstanceId $p.InstanceId -ErrorAction SilentlyContinue
        if ($driverInfo -and $driverInfo.Data) {
            Write-Log "  $($p.Name): 已有驱动 [$($driverInfo.Data)]，跳过"
        } else {
            Write-Log "  $($p.Name): 缺少驱动，需要安装"
            $needInstall += $p
        }
    }

    if ($needInstall.Count -eq 0) {
        Write-Log "所有 USB 打印机驱动已安装"
        if ($NetworkPrinters.Count -eq 0) {
            Write-Log "无需操作"
            Write-Log "========== 自动安装结束 =========="
            exit 0
        }
        Write-Log "跳过 USB 安装阶段，继续处理网络打印机"
    }
}

# ============================================================
# 阶段3-5: USB 打印机驱动安装（仅在有需要时执行）
# ============================================================
$installed = @()
$failed    = @()

if ($needInstall.Count -gt 0) {
    Write-Log "需要安装驱动的打印机: $($needInstall.Count) 台"

    # 阶段3: 用本地 .inf 文件静默安装（pnputil）
    Write-Log "--- 阶段3: 本地 .inf 驱动安装 ---"

    foreach ($printer in $needInstall) {
        $success = $false
        $matchedInf = $null

        Write-Log "  尝试安装: $($printer.Name) | HWID: $($printer.HWIDs[0])"

        if (Test-Path $DriverDir) {
            $infFiles = Get-ChildItem -Path $DriverDir -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue

            foreach ($inf in $infFiles) {
                $infContent = Get-Content -Path $inf.FullName -ErrorAction SilentlyContinue -Encoding Default

                foreach ($hwid in $printer.HWIDs) {
                    if ($infContent -match [regex]::Escape($hwid)) {
                        $matchedInf = $inf.FullName
                        Write-Log "    匹配到驱动: $($inf.FullName)"

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

    # 阶段4: 失败的打印机 - SDIO 脚本模式尝试
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
            $sdioExe = Get-ChildItem -Path $SDIODir -Filter "SDIO_*R*.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "x64" } |
                Sort-Object Name -Descending | Select-Object -First 1
        }

        if ($sdioExe -and (Test-Path $SDIOScript)) {
            Write-Log "  调用 SDIO 脚本模式: $($sdioExe.FullName)"
            Write-Log "  脚本: $SDIOScript"

            try {
                $sdioArgs = "/script:`"$SDIOScript`" /nogui"
                $process = Start-Process -FilePath $sdioExe.FullName -ArgumentList $sdioArgs -Wait -PassThru -WindowStyle Hidden -Timeout 300
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
            $driverInfo = Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_Driver" -InstanceId $printer.InstanceId -ErrorAction SilentlyContinue
            if ($driverInfo -and $driverInfo.Data) {
                Write-Log "  SDIO 成功安装了 $($printer.Name) 的驱动"
            } else {
                $stillFailed += $printer
            }
        }
        $failed = $stillFailed
    }

    # 阶段5: 仍失败 - 弹出 SDIO GUI 供手动操作（仅开机触发时）
    if ($failed.Count -gt 0) {
        if ($OnInsert) {
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
}

# ============================================================
# 阶段6: 网络打印机安装
# ============================================================
$netInstalled = 0
$netFailed    = 0

if ($NetworkPrinters.Count -gt 0) {
    Write-Log "--- 阶段6: 网络打印机安装 ---"
    Write-Log "  配置了 $($NetworkPrinters.Count) 台网络打印机"

    foreach ($np in $NetworkPrinters) {
        Write-Log "  处理: $($np.Name) ($($np.IP))"

        # 检查打印机是否已存在
        $existing = Get-Printer -Name $np.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "    已存在，跳过"
            continue
        }

        # 查找驱动 .inf 文件
        $driverPath = "$DriverDir\$($np.Driver)"
        $infFile = Get-ChildItem -Path $driverPath -Filter "*.inf" -ErrorAction SilentlyContinue | Select-Object -First 1

        if (-not $infFile) {
            Write-Log "    未找到驱动文件: $driverPath\*.inf" WARN
            $netFailed++
            continue
        }

        try {
            # 1) 添加驱动到系统
            Write-Log "    添加驱动: $($infFile.FullName)"
            $addResult = & pnputil /add-driver "$($infFile.FullName)" /install 2>&1
            if ($LASTEXITCODE -ne 0 -and $addResult -notmatch "Driver package added successfully") {
                Write-Log "    驱动添加失败: $addResult" WARN
            }

            # 2) 创建 TCP/IP 端口
            $portName = "IP_$($np.IP)"
            $existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
            if (-not $existingPort) {
                Add-PrinterPort -Name $portName -PrinterHostAddress $np.IP -PortNumber $np.Port -ErrorAction Stop
                Write-Log "    创建端口: $portName (端口 $($np.Port))"
            } else {
                Write-Log "    端口已存在: $portName"
            }

            # 3) 注册打印机驱动（如未注册）
            $existingDriver = Get-PrinterDriver -Name $np.Driver -ErrorAction SilentlyContinue
            if (-not $existingDriver) {
                Add-PrinterDriver -Name $np.Driver -ErrorAction Stop
                Write-Log "    注册驱动: $($np.Driver)"
            }

            # 4) 创建打印机
            Add-Printer -Name $np.Name -PortName $portName -DriverName $np.Driver -ErrorAction Stop
            Write-Log "    安装成功: $($np.Name) -> $($np.IP)"
            $netInstalled++
        }
        catch {
            Write-Log "    安装失败: $_" ERROR
            $netFailed++
        }
    }

    Write-Log "网络打印机结果: 成功 $netInstalled, 失败 $netFailed"
}

# ============================================================
# 汇总
# ============================================================
Write-Log "========== 安装汇总 =========="
Write-Log "USB 打印机: 检测 $($printers.Count) 台, 已有驱动 $($printers.Count - $needInstall.Count) 台"
if ($needInstall.Count -gt 0) {
    Write-Log "USB 安装:   成功 $($installed.Count) 台, 失败 $($failed.Count) 台"
}
if ($NetworkPrinters.Count -gt 0) {
    Write-Log "网络打印机: 配置 $($NetworkPrinters.Count) 台, 新装 $netInstalled 台, 失败 $netFailed 台"
}
if ($failed.Count -gt 0 -and (Get-Process -Name "SDIO*" -ErrorAction SilentlyContinue)) {
    Write-Log "SDIO GUI 已打开，请手动安装剩余驱动"
}
Write-Log "========== 自动安装结束 =========="
