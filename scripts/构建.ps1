# 在本机 Visual Studio 环境中编译 C++ 动画核心。
param([int]$Jobs = 8)
$ErrorActionPreference = 'Stop'
# 从脚本位置确定工程目录，支持中文与空格路径。
$projectDirectory = Split-Path -Parent $PSScriptRoot
$vswherePath = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswherePath)) { throw '未找到 Visual Studio 安装检测工具。' }
$visualStudioDirectory = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudioDirectory) { throw '需要 Visual Studio C++ 桌面编译工具。' }
Import-Module -Name (Join-Path $visualStudioDirectory 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $visualStudioDirectory -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$pythonExecutable = Join-Path $projectDirectory 'tools\python\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonExecutable)) { throw '请先按 README 准备项目 tools/python 环境。' }
Push-Location -LiteralPath $projectDirectory
# 链接器的临时路径使用项目内 ASCII 目录，兼容中文 Windows 用户名。
$originalTemporaryDirectory = $env:TEMP
$originalTemporaryAlias = $env:TMP
$compilerTemporaryDirectory = Join-Path $projectDirectory 'build\compiler_temp'
[System.IO.Directory]::CreateDirectory($compilerTemporaryDirectory) | Out-Null
$env:TEMP = $compilerTemporaryDirectory
$env:TMP = $compilerTemporaryDirectory
try {
    & $pythonExecutable -m SCons platform=windows target=template_debug arch=x86_64 build_profile=native/build_profile.json use_static_cpp=yes optimize=speed debug_symbols=no "-j$Jobs"
    if ($LASTEXITCODE -ne 0) { throw '动画核心编译失败。' }
    # 同时生成无终端窗口的项目启动入口。
    $launcherSource = Join-Path $projectDirectory 'launcher\windows_launcher.cpp'
    $launcherObject = Join-Path $compilerTemporaryDirectory 'launcher.obj'
    $launcherExecutable = Join-Path $compilerTemporaryDirectory 'PuppetLauncher.exe'
    & cl.exe /nologo /utf-8 /std:c++17 /O2 /MT /EHsc /DUNICODE /D_UNICODE $launcherSource "/Fo$launcherObject" "/Fe$launcherExecutable" /link /SUBSYSTEM:WINDOWS user32.lib
    if ($LASTEXITCODE -ne 0) { throw '项目启动器编译失败。' }
    Copy-Item -LiteralPath $launcherExecutable -Destination (Join-Path $projectDirectory '木偶人.exe') -Force
} finally {
    $env:TEMP = $originalTemporaryDirectory
    $env:TMP = $originalTemporaryAlias
    Pop-Location
}

