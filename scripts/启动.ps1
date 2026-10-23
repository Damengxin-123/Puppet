# 启动项目内安装的 Godot 并运行木偶人独立界面。
param([switch]$Editor)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$godotExecutable = Join-Path $projectDirectory 'tools\Godot\Godot_v4.7.2-stable_win64.exe'
if (-not (Test-Path -LiteralPath $godotExecutable)) { throw '未找到 tools/Godot 中的引擎程序。' }
$godotArguments = @('--path', ('"' + $projectDirectory + '"'))
if ($Editor) { $godotArguments += '--editor' }
# 运行窗口是用户需要直接操作的软件窗口。
Start-Process -FilePath $godotExecutable -ArgumentList $godotArguments -WorkingDirectory $projectDirectory
