# SDIO 打印机驱动自动安装方案

基于 [Snappy Driver Installer Origin](https://www.glenn.delahoy.com/snappy-driver-installer-origin) 的打印机驱动自动检测和静默安装工具。

SDIO 本身是一个功能强大的万能驱动安装工具，但默认需要手动操作 GUI。本方案在其之上封装了一层 PowerShell 自动化，实现：

- **开机自动检测** — 系统启动/还原后 30 秒，自动扫描并安装打印机驱动
- **插入实时检测** — USB 打印机插入后约 13 秒，自动匹配并安装驱动
- **三级回退** — 本地 .inf 静默安装 → SDIO 脚本模式 → SDIO GUI 手动装
- **不改 SDIO 源码** — 纯包装层，利用 SDIO 现有的脚本引擎

典型场景：医院、学校、企业等大量终端设备需要不定期接入不同型号打印机，且系统盘会定期还原的环境。

---

## 系统要求

- Windows 10 / 11 或 Windows Server 2016+
- PowerShell 5.1+（系统自带）
- 管理员权限
- [7-Zip](https://www.7-zip.org/)（用于打包 SDIO 驱动包）
- SDIO 主程序（从[官网](https://www.glenn.delahoy.com/snappy-driver-installer-origin)下载）

---

## 快速开始

支持程序和数据分盘部署：`BaseDir`（脚本/程序，随系统镜像）和 `DataDir`（驱动/日志，持久化不被还原）。
以下示例：脚本放 `C:\PrinterDrivers`，数据放 `D:\PrinterDrivers`。

```powershell
# 1. 克隆本仓库到目标终端的系统盘（随镜像分发）
git clone https://github.com/mambo-wang/snappy-driver-installer-origin-autoinstall.git C:\PrinterDrivers

# 2. 编辑 config.ini
#    BaseDir=C:\PrinterDrivers     ← 脚本和程序目录（系统盘）
#    DataDir=D:\PrinterDrivers     ← 驱动和日志目录（持久化盘）

# 3. 在数据盘放入打印机 .inf 驱动文件（按型号分子目录）
mkdir D:\PrinterDrivers\drivers\HP_LaserJet_1020
copy D:\驱动包\HP1020\* D:\PrinterDrivers\drivers\HP_LaserJet_1020\

# 4. 下载 SDIO 并解压到 C:\PrinterDrivers\SDIO\（随镜像）
#    从 https://www.glenn.delahoy.com/snappy-driver-installer-origin 下载

# 5. 打包驱动为 SDIO 兼容格式（输出到数据盘）
powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\pack_drivers.ps1

# 6. 注册开机自启 + USB插入触发（管理员运行）
powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\setup_scheduled_task.ps1
```

部署完成后，终端开机会自动检测打印机并安装驱动，用户插入新打印机也会实时响应。
系统还原时 C 盘从镜像恢复，D 盘的驱动文件和日志不受影响。

---

## 工作流程

```
触发方式:
  [A] 系统启动/还原 ──→ 延迟30秒 ──→ 扫描并安装
  [B] USB打印机插入 ──→ 延迟13秒 ──→ 扫描并安装
                        │
                        ▼
              检测连接的打印机 (Get-PnpDevice)
                        │
                  已有驱动 → 跳过
                        │
                        ▼
         阶段3: pnputil 安装本地 .inf ──→ 成功 → 完成
                        │ 失败
                        ▼
         阶段4: SDIO 脚本模式 (/script /nogui) ──→ 成功 → 完成
                        │ 失败
                        ▼
         阶段5: 开机触发 → 弹出 SDIO GUI 手动装
                 插入触发 → 记日志，不弹GUI，下次开机重试
```

---

## 仓库文件说明

| 文件 | 用途 | 运行时角色 |
|------|------|-----------|
| `config.ini` | 配置文件 | 所有脚本从此文件读取 BaseDir 和 DataDir |
| `auto_install_printer.ps1` | 主安装脚本 | 每次触发时执行，支持 `-OnInsert` 参数 |
| `auto_printer.txt` | SDIO 脚本文件 | 阶段4回退时由 SDIO 加载执行 |
| `pack_drivers.ps1` | 驱动打包工具 | 仅部署阶段使用，将 .inf 目录打成 .7z |
| `setup_scheduled_task.ps1` | 任务计划注册 | 仅部署时运行一次 |
| `README.md` | 本文档 | — |

---

## 部署后的目录结构

支持分盘部署，`BaseDir` 和 `DataDir` 由 `config.ini` 指定。以下以 C 盘 / D 盘为例：

**BaseDir — 系统盘（随镜像分发）**

```
C:\PrinterDrivers\
├── config.ini                    ← 配置文件
├── auto_install_printer.ps1      ← 主安装脚本
├── auto_printer.txt              ← SDIO 脚本文件
├── pack_drivers.ps1              ← 驱动打包工具（仅部署时用）
├── setup_scheduled_task.ps1      ← 任务计划注册（仅部署时用）
│
└── SDIO\                         ← SDIO 程序（从官网下载解压）
    └── SDIO_x64_R830.exe
```

**DataDir — 数据盘（持久化，不被系统还原）**

```
D:\PrinterDrivers\
├── drivers\                      ← 裸 .inf 驱动文件（按型号分子目录）
│   ├── HP_LaserJet_1020\
│   │   ├── HPLJ1020.inf
│   │   └── ...
│   ├── Canon_LBP6230dn\
│   │   ├── CNXxxx.inf
│   │   └── ...
│   └── ...
│
├── SDIO\
│   ├── drivers\                  ← SDIO 驱动包（.7z，由 pack_drivers.ps1 生成）
│   │   ├── DRP_Printer_HP_LaserJet_1020.7z
│   │   └── DRP_Printer_Canon_LBP6230dn.7z
│   └── indexes\                  ← SDIO 索引（自动生成）
│
└── logs\                         ← 安装日志（自动生成，超期自动清理）
    └── install_20260629_083000.log
```

> 分盘部署时，脚本会自动创建目录链接（junction），让 SDIO 程序（C 盘）找到数据盘上的驱动包。
> 如果 `DataDir` 不填或与 `BaseDir` 相同，则所有内容都在同一目录下。

---

## 部署步骤详解

### 第1步：准备驱动文件

将每个打印机型号的驱动文件（.inf 及配套的 .dll/.sys/.gpd 等）放到**数据盘** `drivers\` 下的独立子目录：

```powershell
mkdir D:\PrinterDrivers\drivers\HP_LaserJet_1020
copy D:\驱动包\HP1020\* D:\PrinterDrivers\drivers\HP_LaserJet_1020\

mkdir D:\PrinterDrivers\drivers\Canon_LBP6230dn
copy D:\驱动包\Canon\* D:\PrinterDrivers\drivers\Canon_LBP6230dn\
```

### 第2步：部署 SDIO

从 https://www.glenn.delahoy.com/snappy-driver-installer-origin 下载 SDIO，解压到 `C:\PrinterDrivers\SDIO\`（系统盘，随镜像）。

### 第3步：打包 SDIO 驱动包

将裸 .inf 目录打包为 SDIO 兼容的 .7z 驱动包（自动输出到数据盘）：

```powershell
powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\pack_drivers.ps1
```

### 第4步：注册任务计划

以管理员身份运行：

```powershell
powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\setup_scheduled_task.ps1
```

此脚本注册两个任务计划，并自动启用插入触发所需的事件日志通道：

| 任务名称 | 触发条件 | 延迟 | 说明 |
|----------|----------|------|------|
| `AutoInstallPrinterDriver` | 系统启动 | 30秒 | 开机扫描已连接的打印机 |
| `AutoInstallPrinterDriver_OnInsert` | USB设备插入 | 13秒 | 实时响应新插入的打印机 |

### 第5步：封装系统镜像

将 `C:\PrinterDrivers`（BaseDir）包含在系统镜像中。`D:\PrinterDrivers`（DataDir）在数据盘上，不受系统还原影响。

---

## 日常运维

### 使用场景

**开机自动安装** — 终端开机 30 秒后自动检测打印机并安装驱动，成功则静默退出，用户无感。

**插入实时安装** — 用户插入打印机 USB 线后约 13 秒自动安装。失败时不弹 GUI（避免打扰用户），记日志等下次开机重试。

**手动兜底** — 自动安装失败且为开机触发时，SDIO GUI 自动弹出，运维人员可在界面中手动勾选安装。

### 常用命令

```powershell
# 手动触发安装
schtasks /Run /TN "AutoInstallPrinterDriver"

# 查看任务状态
schtasks /Query /TN "AutoInstallPrinterDriver"
schtasks /Query /TN "AutoInstallPrinterDriver_OnInsert"

# 禁用/启用
schtasks /Change /TN "AutoInstallPrinterDriver" /DISABLE
schtasks /Change /TN "AutoInstallPrinterDriver" /ENABLE

# 查看最新日志（在数据盘）
Get-ChildItem D:\PrinterDrivers\logs -Filter "install_*.log" | Sort LastWriteTime -Desc | Select -First 1 | Get-Content

# 查看当前连接的打印机
Get-PnpDevice -Class Printer | Select FriendlyName, InstanceId

# 删除所有任务
Unregister-ScheduledTask -TaskName "AutoInstallPrinterDriver" -Confirm:$false
Unregister-ScheduledTask -TaskName "AutoInstallPrinterDriver_OnInsert" -Confirm:$false
```

### 添加新打印机型号

1. 将驱动文件放到**数据盘** `D:\PrinterDrivers\drivers\新打印机型号\`
2. 重新运行打包：`powershell -ExecutionPolicy Bypass -File C:\PrinterDrivers\pack_drivers.ps1`
3. 无需更新镜像（驱动在数据盘，不受还原影响）

---

## 触发方式对比

| | 开机触发 | USB 插入触发 |
|---|---|---|
| 任务名称 | `AutoInstallPrinterDriver` | `AutoInstallPrinterDriver_OnInsert` |
| 触发时机 | 系统启动后 | USB 设备插入后 |
| 延迟 | 30秒 | 5秒（任务计划）+ 8秒（脚本防抖） |
| 脚本参数 | 无 | `-OnInsert` |
| 失败行为 | 弹出 SDIO GUI | 不弹 GUI，记日志，下次开机重试 |
| 适用场景 | 系统还原后首次开机、已固定连接打印机 | 用户临时接入新打印机 |

---

## 配置项

所有配置集中在 `config.ini` 文件中（与脚本同目录），格式为 `key=value`，`#` 开头的行为注释。

```ini
# 脚本和程序目录（随系统镜像分发，通常在 C 盘）
BaseDir=C:\PrinterDrivers

# 数据目录（驱动文件、日志等运行时数据，通常在非系统盘，不被还原）
# 留空或不填则与 BaseDir 相同
DataDir=D:\PrinterDrivers

# 日志保留天数
LogRetainDays=30
```

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `BaseDir` | 无（必填） | 脚本和程序目录。存放 .ps1 脚本、config.ini、auto_printer.txt 和 SDIO 程序。随系统镜像分发 |
| `DataDir` | 与 BaseDir 相同 | 数据目录。存放 drivers\（.inf 源文件）、SDIO\drivers\（.7z 驱动包）和 logs\。推荐指向非系统盘 |
| `LogRetainDays` | `30` | 日志保留天数，超期自动清理 |

> **分盘部署**：BaseDir 和 DataDir 指向不同盘时，脚本自动创建目录链接（junction），让 SDIO 程序（BaseDir）找到数据盘上的驱动包（DataDir）。无需手动配置。

---

## 注意事项

1. **系统还原**：`BaseDir`（如 `C:\PrinterDrivers`）随系统镜像恢复；`DataDir`（如 `D:\PrinterDrivers`）在数据盘上，不受还原影响。还原后开机即可自动工作，无需重新部署驱动。

2. **PowerShell 执行策略**：系统镜像中需预设：
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
   ```

3. **事件日志通道**：插入触发依赖 `Microsoft-Windows-DriverFrameworks-UserMode/Operational`，`setup_scheduled_task.ps1` 会自动启用。

4. **插入触发频率**：每次 USB 设备插入都会触发，但脚本会快速判断是否有打印机需安装，无打印机时秒退，不影响性能。

5. **SDIO 驱动包命名**：若只想通过 SDIO 安装打印机驱动（排除其他设备），将 .7z 包命名为 `DRP_Printer_xxx.7z`，并修改 `auto_printer.txt` 中 `select missing` 为 `select missing printer`。

6. **不支持网络打印机**：本方案仅处理 USB 直连打印机，网络打印机需另行部署。
