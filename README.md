# 医院 VOI 胖终端 — 打印机驱动自动安装方案

## 方案概述

两种触发方式，三级安装回退，**不改任何源码**。

- **触发方式**：开机自动检测 + USB 设备插入实时检测
- **安装策略**：本地 .inf 静默安装 → SDIO 脚本模式 → SDIO GUI 手动装

```
┌─ 触发方式 ──────────────────────────────────────────────┐
│                                                          │
│  [A] 系统启动/还原 ──→ 延迟30秒 ──→ 扫描并安装          │
│                                                          │
│  [B] USB打印机插入 ──→ 延迟5+8秒 ──→ 扫描并安装         │
│                                                          │
└────────────────────────┬─────────────────────────────────┘
                         ▼
              检测连接的打印机 (Get-PnpDevice)
                         │
                   已有驱动 → 跳过
                         │
                         ▼
              阶段3: pnputil 安装本地 .inf ──→ 成功 → 完成
                         │ 失败
                         ▼
              阶段4: SDIO 脚本模式 (/script /nogui)
                         │                    → 成功 → 完成
                         │ 失败
                         ▼
              阶段5: 开机触发 → 弹出 SDIO GUI 手动装
                      插入触发 → 记日志，不弹GUI，等下次开机重试
```

---

## 目录结构

部署到每台终端的完整文件包：

```
C:\PrinterDrivers\
├── auto_install_printer.ps1    ← 主脚本（自动安装，支持 -OnInsert 参数）
├── auto_printer.txt            ← SDIO 脚本文件
├── pack_drivers.ps1            ← 驱动打包工具（仅准备阶段用）
├── setup_scheduled_task.ps1    ← 任务计划注册（仅部署一次）
│
├── drivers\                    ← 裸 .inf 驱动文件（按型号分子目录）
│   ├── HP_LaserJet_1020\
│   │   ├── HPLJ1020.inf
│   │   ├── HPLJ1020.gpd
│   │   └── ...（所有配套文件）
│   ├── Canon_LBP6230dn\
│   │   ├── CNXxxx.inf
│   │   └── ...
│   └── ...（更多打印机型号）
│
├── SDIO\                       ← SDIO 程序（整个解压到这里）
│   ├── SDIO_x64_R830.exe
│   ├── drivers\                ← SDIO 驱动包（.7z 格式）
│   │   ├── DRP_Printer_HP_LaserJet_1020.7z
│   │   └── DRP_Printer_Canon_LBP6230dn.7z
│   └── indexes\                ← SDIO 索引（自动生成）
│
└── logs\                       ← 安装日志（自动生成）
    └── install_20260629_083000.log
```

---

## 部署步骤（IT 管理员一次性操作）

### 第1步：准备驱动文件

将每个打印机型号的驱动文件（.inf 及配套的 .dll/.sys/.gpd 等）放到对应子目录：

```powershell
# 示例：创建目录结构
mkdir C:\PrinterDrivers\drivers\HP_LaserJet_1020
# 把从HP官网下载的驱动文件复制进去
copy D:\下载\HP1020\* C:\PrinterDrivers\drivers\HP_LaserJet_1020\

mkdir C:\PrinterDrivers\drivers\Canon_LBP6230dn
copy D:\下载\Canon\* C:\PrinterDrivers\drivers\Canon_LBP6230dn\
```

### 第2步：部署 SDIO

从 https://www.glenn.delahoy.com/snappy-driver-installer-origin 下载 SDIO，
解压到 `C:\PrinterDrivers\SDIO\`。

### 第3步：打包 SDIO 驱动包

运行打包脚本，将裸 .inf 目录打包为 SDIO 兼容的 .7z 驱动包：

```powershell
powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\pack_drivers.ps1
```

> 前提：系统已安装 7-Zip（`C:\Program Files\7-Zip\7z.exe`）。

### 第4步：注册任务计划

以管理员身份运行：

```powershell
powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\setup_scheduled_task.ps1
```

此脚本会注册两个任务计划：

| 任务名称 | 触发条件 | 延迟 | 说明 |
|----------|----------|------|------|
| `AutoInstallPrinterDriver` | 系统启动 | 30秒 | 开机扫描已连接的打印机 |
| `AutoInstallPrinterDriver_OnInsert` | USB设备插入 | 5秒（任务计划）+ 8秒（脚本防抖） | 实时响应新插入的打印机 |

脚本会自动启用 `Microsoft-Windows-DriverFrameworks-UserMode/Operational` 事件日志通道（插入触发依赖此日志）。

### 第5步：封装系统镜像

将 `C:\PrinterDrivers` 整个目录包含在系统镜像中。
系统还原后此目录不受影响（在 C 盘根目录，通常不在还原分区内，或者配置为保留目录）。

---

## 日常使用（无人值守）

### 正常使用流程

**场景1：开机自动安装**
1. 终端开机 → 30秒后自动运行脚本
2. 脚本检测已连接的打印机
3. 自动安装驱动（pnputil 优先，SDIO 回退）
4. 安装成功 → 静默退出，用户无感

**场景2：使用中插入打印机**
1. 用户将打印机 USB 线插入终端
2. Windows 检测到新设备 → 触发事件日志（Event ID 20003）
3. 任务计划在 5 秒后启动脚本，脚本再等 8 秒防抖
4. 自动匹配并安装驱动 → 用户等约 15 秒即可打印
5. 安装失败 → 不弹 GUI（避免打扰用户），记录日志，下次开机重试

**场景3：自动安装失败（仅开机触发时）**
- SDIO GUI 自动弹出
- 运维人员到终端前，在 SDIO 界面中：
  1. 找到标红的打印机设备
  2. 勾选对应的驱动
  3. 点击"安装"按钮

### 运维管理命令

```powershell
# ---- 开机任务 ----
# 手动触发安装
schtasks /Run /TN "AutoInstallPrinterDriver"
# 查看任务状态
schtasks /Query /TN "AutoInstallPrinterDriver"
# 临时禁用
schtasks /Change /TN "AutoInstallPrinterDriver" /DISABLE
# 重新启用
schtasks /Change /TN "AutoInstallPrinterDriver" /ENABLE

# ---- 插入触发任务 ----
# 手动触发
schtasks /Run /TN "AutoInstallPrinterDriver_OnInsert"
# 查看状态
schtasks /Query /TN "AutoInstallPrinterDriver_OnInsert"
# 禁用插入触发（保留开机触发）
schtasks /Change /TN "AutoInstallPrinterDriver_OnInsert" /DISABLE

# ---- 通用 ----
# 查看安装日志
type C:\PrinterDrivers\logs\install_*.log
# 查看最新一次日志
Get-ChildItem C:\PrinterDrivers\logs -Filter "install_*.log" | Sort LastWriteTime -Desc | Select -First 1 | Get-Content
# 查看当前连接的打印机及HWID
Get-PnpDevice -Class Printer | Select FriendlyName, InstanceId
# 删除所有任务
Unregister-ScheduledTask -TaskName "AutoInstallPrinterDriver" -Confirm:$false
Unregister-ScheduledTask -TaskName "AutoInstallPrinterDriver_OnInsert" -Confirm:$false
```

### 添加新打印机型号

1. 将新打印机的 .inf 驱动文件放到 `C:\PrinterDrivers\drivers\新打印机型号\`
2. 重新运行打包脚本：
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\pack_drivers.ps1
   ```
3. 更新系统镜像（如果有的话）

---

## 两种触发方式对比

| | 开机触发 | USB 插入触发 |
|---|---|---|
| 任务名称 | `AutoInstallPrinterDriver` | `AutoInstallPrinterDriver_OnInsert` |
| 触发时机 | 系统启动后 | USB 设备插入后 |
| 延迟 | 30秒（等设备枚举） | 5秒（任务计划）+ 8秒（脚本防抖） |
| 脚本参数 | 无 | `-OnInsert` |
| 安装失败行为 | 弹出 SDIO GUI | 不弹 GUI，记日志，下次开机重试 |
| 适用场景 | 系统还原后首次开机、已有固定打印机 | 用户临时接入新打印机 |

---

## 配置调整

编辑 `auto_install_printer.ps1` 顶部的配置区：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `$BaseDir` | `C:\PrinterDrivers` | 方案根目录 |
| `$DriverDir` | `$BaseDir\drivers` | 裸 .inf 驱动目录 |
| `$SDIODir` | `$BaseDir\SDIO` | SDIO 程序目录 |
| `$LogRetainDays` | `30` | 日志保留天数 |

---

## 注意事项

1. **系统还原兼容性**：`C:\PrinterDrivers` 目录需要在系统还原时被保留。
   如果整个 C 盘都会还原，需要将此目录放到不受还原影响的分区，
   或在还原脚本中增加一步重新复制此目录。

2. **PowerShell 执行策略**：系统镜像中需要允许脚本执行：
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
   ```

3. **事件日志通道**：插入触发依赖 `Microsoft-Windows-DriverFrameworks-UserMode/Operational`
   日志通道，`setup_scheduled_task.ps1` 会自动启用。如果手动注册任务，
   需在事件查看器中手动启用此日志通道。

4. **USB 打印机检测延迟**：插入触发的总延迟约 13 秒（5秒任务计划 + 8秒脚本防抖），
   确保设备完成枚举。如果某些打印机初始化更慢，可调整脚本中的 `Start-Sleep -Seconds 8`。

5. **插入触发频率**：每次 USB 设备插入都会触发（不仅限于打印机），
   但脚本内部会快速判断是否有打印机需要安装，无打印机时秒退，不影响性能。

6. **SDIO 驱动包命名**：如果只想通过 SDIO 安装打印机（不装其他设备驱动），
   将驱动包命名为 `DRP_Printer_xxx.7z`，然后修改 `auto_printer.txt` 中的
   `select missing` 为 `select missing printer`。

7. **日志位置**：每次安装生成一个带时间戳的日志文件，
   超期自动清理，不会占满磁盘。

8. **不支持网络打印机**：本方案仅处理 USB 直连打印机。
   网络打印机通常通过 TCP/IP 端口添加，需另外的部署脚本。
