#requires -Version 5.1
<#
.SYNOPSIS
  从本地 Sunshine 源码树构建 Windows NSIS 安装包，供控制面板的“源码更新”流程调用。

.DESCRIPTION
  流程：CMake configure（开启驱动依赖下载）-> ninja 增量构建 -> cpack 打 NSIS 包。
  本脚本只负责构建，不做任何 git 同步（同步逻辑在调用方 Rust 侧）。

  普通构建日志实时透传到 stdout；阶段切换打印 @@STAGE:<name>@@ 标记行；
  成功时最后一行打印 @@ARTIFACT:<绝对路径>@@；任何步骤失败以非零退出码结束。

  关键环境约定（来自实际验证）：
  - 必须把 MSYS2 UCRT64 的 bin 放到系统里其它 mingw 目录之前，否则 c++ 编译会
    被错误工具链组件拖垮；但又必须让“原生 Windows node”排在 UCRT64 自带的 GNU node
    之前，否则构建 web 资产时 rolldown 会去找 gnu 原生绑定而失败。
    因此 PATH 顺序固定为：<原生node目录>;<ucrt64/bin>;<原PATH>。
  - 出整包必须在 configure 时打开 FETCH_DRIVER_DEPS，否则驱动依赖目录为空，
    cpack 的 install 阶段会因找不到 nefconw.exe 等文件失败。

.PARAMETER SourceDir
  Sunshine 源码根目录（包含 CMakeLists.txt，且其下 build/ 已完成过一次 configure）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Write-Stage {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Output "@@STAGE:$Name@@"
}

function Die {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("更新构建失败：$Message")
    exit 1
}

# 从 CMakeCache.txt 读取形如 KEY:TYPE=VALUE 的缓存变量。
function Get-CacheValue {
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $pattern = '^' + [regex]::Escape($Key) + '(?::[^=]*)?=(.*)$'
    foreach ($line in (Get-Content -LiteralPath $CachePath)) {
        if ($line -and ($line -match $pattern)) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# 运行原生程序并检查退出码；stdout/stderr 直接透传，不做缓冲重定向。
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgList,
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StageLabel
    )
    Write-Stage $StageLabel
    $previous = (Get-Location).Path
    if ($WorkingDirectory) {
        Set-Location $WorkingDirectory
    }
    try {
        & $FilePath @ArgList
        $code = $LASTEXITCODE
    }
    finally {
        if ($WorkingDirectory) {
            Set-Location $previous
        }
    }
    if ($code -ne 0) {
        Die "$StageLabel 失败（退出码 $code）：$FilePath $($ArgList -join ' ')"
    }
}

# ---------- 1. 定位源码树与已配置的 build/ ----------
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Die "源码目录不存在：$SourceDir"
}
$sourceRoot = (Resolve-Path -LiteralPath $SourceDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt'))) {
    Die "不是 Sunshine 源码根目录（缺 CMakeLists.txt）：$sourceRoot"
}
$buildDir = Join-Path $sourceRoot 'build'
$cachePath = Join-Path $buildDir 'CMakeCache.txt'
if (-not (Test-Path -LiteralPath $cachePath)) {
    Die "找不到已配置的构建树 $cachePath；请先在 build/ 完成一次 CMake configure。"
}

$cxxCompiler = Get-CacheValue -CachePath $cachePath -Key 'CMAKE_CXX_COMPILER'
$cmakeExe = Get-CacheValue -CachePath $cachePath -Key 'CMAKE_COMMAND'
$cpackExe = Get-CacheValue -CachePath $cachePath -Key 'CMAKE_CPACK_COMMAND'
$ninjaExe = Get-CacheValue -CachePath $cachePath -Key 'CMAKE_MAKE_PROGRAM'

foreach ($pair in @(
        @{ Name = 'CMAKE_CXX_COMPILER'; Value = $cxxCompiler },
        @{ Name = 'CMAKE_COMMAND'; Value = $cmakeExe },
        @{ Name = 'CMAKE_CPACK_COMMAND'; Value = $cpackExe },
        @{ Name = 'CMAKE_MAKE_PROGRAM'; Value = $ninjaExe }
    )) {
    if (-not $pair.Value -or -not (Test-Path -LiteralPath $pair.Value)) {
        Die "CMakeCache 中 $($pair.Name) 缺失或指向的文件不存在：$($pair.Value)"
    }
}

# 编译器所在目录即 MSYS2 UCRT64 的 bin（cmake/ninja/cpack/makensis 与运行时 DLL 都在这里）。
$toolBin = Split-Path -Parent $cxxCompiler
$makensisExe = Join-Path $toolBin 'makensis.exe'
if (-not (Test-Path -LiteralPath $makensisExe)) {
    Die "找不到 makensis.exe（$makensisExe）。请在该 MSYS2 环境安装 NSIS，例如 pacman -S mingw-w64-ucrt-x86_64-nsis。"
}

# 原生 Windows node 目录必须排在最前，避免用到 UCRT64 自带的 GNU node。
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $nodeCommand) {
    Die 'PATH 中找不到 node.exe；构建 web 资产需要原生 Windows 版 Node.js。'
}
$nodeDir = Split-Path -Parent $nodeCommand.Source

# 本地 Tauri GUI 由 cargo 构建；缺失时 ninja 的 sunshine-control-panel 目标不会生成。
$cargoCommand = Get-Command cargo.exe -ErrorAction SilentlyContinue
if (-not $cargoCommand) {
    Die 'PATH 中找不到 cargo.exe；本地构建控制面板需要 Rust 工具链（rustup 的 stable-x86_64-pc-windows-msvc）。'
}
$cargoDir = Split-Path -Parent $cargoCommand.Source

# 去掉 PATH 中已存在的这几个目录，避免重复或旧顺序造成遮蔽，再按固定顺序前置。
$sep = [System.IO.Path]::PathSeparator
$pathParts = ($env:PATH -split [regex]::Escape($sep)) | Where-Object {
    $_ -and
    ($_ -ne $nodeDir.TrimEnd('\')) -and
    ($_ -ne $cargoDir.TrimEnd('\')) -and
    ($_ -ne $toolBin.TrimEnd('\'))
}
# 注意：PowerShell 中 + 的优先级高于二元 -join，必须给 -join 加括号，
# 否则右侧会被解析成 ($sep + $sep + $rest) 这个“超长分隔符”，把 toolBin 甩到 PATH 末尾。
$env:PATH = (($nodeDir, $cargoDir, $toolBin) -join $sep) + $sep + ($pathParts -join $sep)

# ---------- 2. configure（确保驱动依赖开启并下载） ----------
Invoke-Native -FilePath $cmakeExe `
    -ArgList @('-S', $sourceRoot, '-B', $buildDir, '-DFETCH_DRIVER_DEPS=ON') `
    -StageLabel 'configure'

# ---------- 3. 先构建本地 Tauri GUI ----------
# 必须在“下一次 configure”之前产出 exe+dll：packaging/common.cmake 只在 configure
# 阶段检测本地产物，缺失就会把 GUI_DIR 固定为 FetchGUI 下载的旧版并写入缓存，
# 之后即使编译出 GUI，同一次 cpack 仍会打包旧 GUI。
Invoke-Native -FilePath $ninjaExe `
    -ArgList @('-C', $buildDir, 'sunshine-control-panel') `
    -StageLabel 'build'

# GUI 首次产出后再 configure 一次，让 CMake 选中本地 GUI（GUI_DIR 翻转到 target/release）。
& $cmakeExe -S $sourceRoot -B $buildDir -DFETCH_DRIVER_DEPS=ON
if ($LASTEXITCODE -ne 0) {
    Die '本地 GUI 产出后的二次 CMake configure 失败。'
}

# ---------- 4. ninja 增量构建核心 ----------
Invoke-Native -FilePath $ninjaExe `
    -ArgList @('-C', $buildDir) `
    -StageLabel 'build'

# ---------- 5. cpack 打 NSIS 包（需在含 CPackConfig.cmake 的 build 目录内执行） ----------
Invoke-Native -FilePath $cpackExe `
    -ArgList @('-G', 'NSIS') `
    -WorkingDirectory $buildDir `
    -StageLabel 'package'

# ---------- 5. 定位产物 ----------
$artifact = Join-Path $buildDir (Join-Path 'cpack_artifacts' 'Sunshine.exe')
if (-not (Test-Path -LiteralPath $artifact)) {
    Die "打包已结束但未找到安装包：$artifact"
}
Write-Output "@@ARTIFACT:$((Resolve-Path -LiteralPath $artifact).Path)@@"
