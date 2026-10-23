# 下载固定版本工具、编译原生核心并准备本地运行资源。
param([int]$Jobs = 8)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$dependencyInfo = Get-Content -LiteralPath (Join-Path $projectDirectory 'dependencies.lock.json') -Raw | ConvertFrom-Json
$godotDirectory = Join-Path $projectDirectory 'tools\Godot'
$thirdPartyDirectory = Join-Path $projectDirectory 'third_party'
$pythonDirectory = Join-Path $projectDirectory 'tools\python'
$utf8Encoding = [System.Text.UTF8Encoding]::new($false)
# 隔离工具及本地数据，避免 Godot 扫描编译器和 Python 环境。
foreach ($folderName in @('tools', 'third_party', 'build', 'workspace', 'native')) {
    $folderPath = Join-Path $projectDirectory $folderName
    [System.IO.Directory]::CreateDirectory($folderPath) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $folderPath '.gdignore'), "`n", $utf8Encoding)
}
[System.IO.Directory]::CreateDirectory($godotDirectory) | Out-Null
$godotExecutable = Join-Path $godotDirectory 'Godot_v4.7.2-stable_win64_console.exe'
if (-not (Test-Path -LiteralPath $godotExecutable)) {
    $archivePath = Join-Path $godotDirectory 'Godot_v4.7.2-stable_win64.exe.zip'
    Invoke-WebRequest -Uri $dependencyInfo.godot.archive_url -OutFile $archivePath
    $downloadHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $dependencyInfo.godot.archive_sha256) { throw 'Godot 下载文件校验失败。' }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $godotDirectory -Force
}
$bindingDirectory = Join-Path $thirdPartyDirectory 'godot-cpp'
if (-not (Test-Path -LiteralPath (Join-Path $bindingDirectory 'SConstruct'))) {
    git clone --depth 1 --branch $dependencyInfo.godot_cpp.tag $dependencyInfo.godot_cpp.repository $bindingDirectory
    if ($LASTEXITCODE -ne 0) { throw 'C++ 绑定下载失败。' }
}
$bindingCommit = git -C $bindingDirectory rev-parse HEAD
if ($bindingCommit -ne $dependencyInfo.godot_cpp.commit) { throw '本地 godot-cpp 版本与锁定版本不一致。' }
$pythonExecutable = Join-Path $pythonDirectory 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonExecutable)) {
    $installedPython = (Get-Command python.exe -ErrorAction Stop).Source
    & $installedPython -m venv $pythonDirectory
    if ($LASTEXITCODE -ne 0) { throw '本地 Python 环境创建失败。' }
}
& $pythonExecutable -m pip install ("scons==" + $dependencyInfo.build.scons) --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { throw 'SCons 准备失败。' }
& $pythonExecutable -m pip install -r (Join-Path $projectDirectory 'mcp_service\requirements.txt') --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { throw 'MCP 依赖准备失败。' }
& (Join-Path $PSScriptRoot '构建.ps1') -Jobs $Jobs
& $godotExecutable --headless --path $projectDirectory --editor --import --quit
if ($LASTEXITCODE -ne 0) { throw 'Godot 资源导入失败。' }
Write-Output ('环境已准备完成，可双击：' + (Join-Path $projectDirectory '木偶人.exe'))
