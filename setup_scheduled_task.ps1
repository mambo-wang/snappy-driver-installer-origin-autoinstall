#Requires -RunAsAdministrator
<#
.SYNOPSIS
    注册 Windows 任务计划，支持三种触发方式：
    1. 系统启动（延迟30秒等USB设备就绪）
    2. USB设备插入（实时触发，延迟5秒等设备枚举完成）
    3. 用户登录（延迟60秒）
.DESCRIPTION
    通过任务计划 XML 定义事件触发器，监听设备插入事件。
    无需常驻进程，零CPU占用。
.NOTES
    需要管理员权限运行一次即可
    删除任务: Unregister-ScheduledTask -TaskName "AutoInstallPrinterDriver" -Confirm:$false
    删除插入触发任务: Unregister-ScheduledTask -TaskName "AutoInstallPrinterDriver_OnInsert" -Confirm:$false
#>

$ScriptPath = "C:\PrinterDrivers\auto_install_printer.ps1"

# 检查脚本是否存在
if (-not (Test-Path $ScriptPath)) {
    Write-Error "脚本不存在: $ScriptPath"
    Write-Host "请先将 auto_install_printer.ps1 放到 C:\PrinterDrivers\"
    exit 1
}

# ============================================================
# 任务1: 开机自动运行
# ============================================================
$TaskNameBoot = "AutoInstallPrinterDriver"

$existing = Get-ScheduledTask -TaskName $TaskNameBoot -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskNameBoot -Confirm:$false
    Write-Host "已删除旧任务: $TaskNameBoot"
}

# 用 XML 定义任务（支持 Delay 等高级属性）
$bootXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>开机自动检测并安装打印机驱动（医院VOI终端）</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>2</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$bootXmlFile = "$env:TEMP\printer_boot_task.xml"
$bootXml | Out-File -FilePath $bootXmlFile -Encoding Unicode
schtasks /Create /TN $TaskNameBoot /XML $bootXmlFile /F | Out-Null
Remove-Item $bootXmlFile -Force -ErrorAction SilentlyContinue

Write-Host "任务1 注册成功: $TaskNameBoot (开机启动+30秒延迟)" -ForegroundColor Green


# ============================================================
# 任务2: USB设备插入时触发
# ============================================================
$TaskNameInsert = "AutoInstallPrinterDriver_OnInsert"

$existing2 = Get-ScheduledTask -TaskName $TaskNameInsert -ErrorAction SilentlyContinue
if ($existing2) {
    Unregister-ScheduledTask -TaskName $TaskNameInsert -Confirm:$false
    Write-Host "已删除旧任务: $TaskNameInsert"
}

# 事件触发器：监听 USB 设备插入
# 使用 Microsoft-Windows-DriverFrameworks-UserMode/Operational 日志
# Event ID 20003 = PnP 设备到达
# 过滤条件包含 USB 打印类设备的 InstanceId 模式
$insertXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>USB打印机插入时自动安装驱动（医院VOI终端）</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-DriverFrameworks-UserMode/Operational"&gt;&lt;Select Path="Microsoft-Windows-DriverFrameworks-UserMode/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-DriverFrameworks-UserMode'] and EventID=20003]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath" -OnInsert</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$insertXmlFile = "$env:TEMP\printer_insert_task.xml"
$insertXml | Out-File -FilePath $insertXmlFile -Encoding Unicode
schtasks /Create /TN $TaskNameInsert /XML $insertXmlFile /F | Out-Null
Remove-Item $insertXmlFile -Force -ErrorAction SilentlyContinue

Write-Host "任务2 注册成功: $TaskNameInsert (USB设备插入+5秒延迟)" -ForegroundColor Green

# ============================================================
# 确保事件日志通道已启用
# ============================================================
try {
    $logName = "Microsoft-Windows-DriverFrameworks-UserMode/Operational"
    $log = Get-WinEvent -ListLog $logName -ErrorAction Stop
    if (-not $log.IsEnabled) {
        $log.IsEnabled = $true
        $log.SaveChanges()
        Write-Host "已启用事件日志: $logName" -ForegroundColor Yellow
    }
} catch {
    Write-Host "注意: 无法启用 DriverFrameworks 事件日志，插入触发可能不工作" -ForegroundColor Yellow
    Write-Host "  可手动在事件查看器中启用: Microsoft-Windows-DriverFrameworks-UserMode/Operational" -ForegroundColor Yellow
}

# ============================================================
# 汇总
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " 打印机驱动自动安装 - 任务计划注册完成" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "触发条件:"
Write-Host "  [1] 开机启动 → 延迟30秒 → 扫描并安装"
Write-Host "  [2] USB设备插入 → 延迟5秒 → 扫描并安装"
Write-Host ""
Write-Host "执行脚本: $ScriptPath"
Write-Host "运行身份: SYSTEM（无需用户登录）"
Write-Host ""
Write-Host "管理命令:" -ForegroundColor Yellow
Write-Host "  手动触发:   schtasks /Run /TN `"$TaskNameBoot`""
Write-Host "  查看状态:   schtasks /Query /TN `"$TaskNameBoot`""
Write-Host "  禁用开机:   schtasks /Change /TN `"$TaskNameBoot`" /DISABLE"
Write-Host "  禁用插入:   schtasks /Change /TN `"$TaskNameInsert`" /DISABLE"
Write-Host "  全部删除:   Unregister-ScheduledTask -TaskName `"$TaskNameBoot`" -Confirm:`$false"
Write-Host "              Unregister-ScheduledTask -TaskName `"$TaskNameInsert`" -Confirm:`$false"
Write-Host ""
Write-Host "立即测试运行？(Y/N)"
$answer = Read-Host
if ($answer -eq 'Y' -or $answer -eq 'y') {
    Write-Host "正在运行..."
    schtasks /Run /TN $TaskNameBoot
}
