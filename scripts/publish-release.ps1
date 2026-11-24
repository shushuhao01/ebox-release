# ============================================================
# eBox 发布脚本：把本地构建产物发布为一个新版本
# ------------------------------------------------------------
# 用法（在仓库根目录执行）：
#   powershell -ExecutionPolicy Bypass -File .\publish-release.ps1 -Tag v3.4.0 -NotesFile notes.txt
#   powershell -ExecutionPolicy Bypass -File .\publish-release.ps1 -Tag v3.4.0 -Notes "修复xxx`n优化yyy"
#   powershell -ExecutionPolicy Bypass -File .\publish-release.ps1 -Tag v3.4.0 -DryRun   # 只检查不发布
#   # 游戏版（tag 必须是 v5.x，先用 /p:GameEdition=true 构建）：
#   powershell -ExecutionPolicy Bypass -File .\publish-release.ps1 -Tag v5.0.1 -Game -NotesFile notes.txt
#
# 作用：在源码仓库创建 GitHub Release（tag + eBox.exe/eBoxGame.exe + 更新日志），
#       随后由 .github/workflows/auto-update.yml 按 tag 分流自动完成：
#         正式版 v4.* -> eBox.exe / dist/update.json
#         游戏版 v5.* -> eBoxGame.exe / dist/update-game.json
#         上传国内镜像 -> 重写清单并推回 main -> 同步到公开发行仓库 ebox-release -> purge jsDelivr
#
# 前置：已构建 Release|x64（正式版 bin\x64\eBox.exe；游戏版 bin\Game\x64\eBoxGame.exe）；源码改动已提交并推送。
# 凭据：优先 $env:GH_TOKEN，否则读取本机已保存的 git 凭据。
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Exe = "",
    [switch]$Game,
    [string]$Notes = "",
    [string]$NotesFile = "",
    [string]$Repo = "shushuhao01/ebox",
    [string]$Token = "",
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Fail($msg) { Write-Host "[错误] $msg" -ForegroundColor Red; exit 1 }

# ---------- 0. 发布通道（正式版 / 游戏版）----------
# 两个版本共用同一源码仓库与公开发行仓库，仅靠 tag 前缀（v4.* / v5.*）与产物名区分：
# 游戏版 v5.* 由 auto-update.yml 生成 dist/update-game.json，正式版 v4.* 生成 dist/update.json。
$channelName = if ($Game) { "游戏版" } else { "正式版" }
$assetName = if ($Game) { "eBoxGame.exe" } else { "eBox.exe" }
if (-not $Exe) {
    $Exe = if ($Game) { "bin\Game\x64\eBoxGame.exe" } else { "bin\x64\eBox.exe" }
}
Write-Host ("==> 发布通道：{0}（资产名 {1}）" -f $channelName, $assetName) -ForegroundColor Cyan

# ---------- 1. 校验 tag 与版本号 ----------
Write-Host "==> 1/4 校验版本号与构建产物" -ForegroundColor Cyan
if ($Tag -notmatch '^[vV]?(\d+)\.(\d+)\.(\d+)$') { Fail "tag 格式应为 vX.Y.Z，当前：$Tag" }
$tagMajor, $tagMinor, $tagPatch = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
$Tag = "v$tagMajor.$tagMinor.$tagPatch"

# 通道与 tag 主版本必须匹配：v5.* = 游戏版，其余 = 正式版（与 auto-update.yml 的分流规则一致）
if ($Game -and $tagMajor -ne 5) { Fail "游戏版 tag 必须是 v5.x（对应 product_defs.h 游戏版版本号），当前：$Tag" }
if (-not $Game -and $tagMajor -eq 5) { Fail "v5.x 属于游戏版通道：请加 -Game，并用 bin\Game\x64\eBoxGame.exe 发布" }

$versionDefs = Join-Path $Root "common\header_units\product_defs.h"
if (Test-Path $versionDefs) {
    $src = [IO.File]::ReadAllText((Resolve-Path $versionDefs).Path, [Text.Encoding]::UTF8)
    # 按发布通道只取对应分支，避免正式版/游戏版版本号互相串台
    $section = if ($Game) { '===== 游戏版' } else { '===== 正式版' }
    $channelSrc = ($src -split $section)[1]
    $major = if ($channelSrc -match 'verMajor\s*=\s*(\d+)') { [int]$Matches[1] } else { -1 }
    $minor = if ($channelSrc -match 'verMinor\s*=\s*(\d+)') { [int]$Matches[1] } else { -1 }
    $patch = if ($channelSrc -match 'verPatch\s*=\s*(\d+)') { [int]$Matches[1] } else { -1 }
    if ($major -ne $tagMajor -or $minor -ne $tagMinor -or $patch -ne $tagPatch) {
        Fail "tag 与 product_defs.h $channelName 版本号不一致：源码是 v$major.$minor.$patch，tag 是 $Tag（请先改版本号并重新构建）"
    }
    Write-Host "    $channelName 源码版本 v$major.$minor.$patch 与 tag 一致" -ForegroundColor DarkGray
}

if (-not (Test-Path $Exe)) { Fail "找不到构建产物：$Exe（请先构建 Release|x64$(if ($Game) { '，并带 /p:GameEdition=true' })）" }
$Exe = (Resolve-Path $Exe).Path
$exeInfo = Get-Item $Exe
$sha = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLower()
Write-Host ("    {0}  大小 {1} 字节  SHA-256 {2}..." -f $exeInfo.Name, $exeInfo.Length, $sha.Substring(0, 16)) -ForegroundColor DarkGray

# 工作区有未提交改动时提醒（不阻断，但发布出去的内容可能与源码不一致）
$dirty = git status --porcelain -- eBox dist .github
if ($dirty) {
    Write-Host "[警告] 以下改动尚未提交，发布后仓库与产物可能不一致：" -ForegroundColor Yellow
    Write-Host $dirty
}

# ---------- 2. 更新日志 ----------
Write-Host "==> 2/4 读取更新日志" -ForegroundColor Cyan
if ($NotesFile) {
    if (-not (Test-Path $NotesFile)) { Fail "更新日志文件不存在：$NotesFile" }
    $Notes = [IO.File]::ReadAllText((Resolve-Path $NotesFile).Path, [Text.Encoding]::UTF8)
}
$Notes = ($Notes -replace "`r`n", "`n").Trim()
if (-not $Notes) { Fail "缺少更新日志：请用 -Notes 或 -NotesFile（客户端会逐行显示）" }
$lineCount = ($Notes -split "`n" | Where-Object { $_.Trim() }).Count
Write-Host "    共 $lineCount 行" -ForegroundColor DarkGray

# ---------- 3. 取凭据 ----------
Write-Host "==> 3/4 检查 GitHub 凭据" -ForegroundColor Cyan
if (-not $Token) { $Token = $env:GH_TOKEN }
if (-not $Token) {
    $credIn = @('protocol=https', 'host=github.com', '') -join "`r`n"
    $cred = $credIn | git credential fill 2>&1
    $Token = @($cred | Where-Object { $_ -like 'password=*' })[0] -replace '^password=', ''
}
if (-not $Token) { Fail "未找到 GitHub 凭据：请设置 `$env:GH_TOKEN 或先在 git 中登录 GitHub" }
$Headers = @{
    Authorization          = "token $Token"
    Accept                 = "application/vnd.github+json"
    'User-Agent'           = 'ebox-publish'
    'X-GitHub-Api-Version' = '2022-11-28'
}
try {
    $me = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $Headers
    Write-Host "    仓库可访问：$($me.full_name)（默认分支 $($me.default_branch)）" -ForegroundColor DarkGray
} catch {
    Fail "访问 $Repo 失败：$($_.Exception.Message)"
}

# 已存在同 tag 的 Release：默认中止，避免覆盖线上产物
$existing = $null
try { $existing = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $Headers } catch { }
if ($existing) {
    if (-not $Force) { Fail "$Tag 已存在 Release。如确认要重发，加 -Force（会先删除旧 Release）" }
    Write-Host "    -Force：删除已存在的 Release $Tag" -ForegroundColor Yellow
    if (-not $DryRun) {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/$($existing.id)" -Method Delete -Headers $Headers | Out-Null
    }
}

# ---------- 4. 发布 ----------
Write-Host "==> 4/4 创建 Release 并上传产物" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "[DryRun] 将发布 $Tag 到 $Repo（$channelName），资产 $($exeInfo.Name) -> $assetName，$lineCount 行日志" -ForegroundColor Yellow
    Write-Host "[DryRun] 未做任何修改" -ForegroundColor Yellow
    exit 0
}

$body = @{
    tag_name         = $Tag
    name             = $Tag
    body             = $Notes
    target_commitish = $me.default_branch
    draft            = $false
    prerelease       = $false
} | ConvertTo-Json -Depth 3
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases" -Method Post -Headers $Headers `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
Write-Host "    Release 已创建：$($release.html_url)" -ForegroundColor DarkGray

try {
    $asset = Invoke-RestMethod -Uri "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets?name=$assetName" `
        -Method Post -Headers $Headers -InFile $Exe -ContentType 'application/octet-stream'
    Write-Host "    资产已上传：$($asset.name) $($asset.size) 字节" -ForegroundColor DarkGray
} catch {
    Fail "资产上传失败：$($_.Exception.Message)（Release 已创建，可在网页补传 $assetName）"
}

Write-Host ""
Write-Host "发布已触发：$Repo $Tag（$channelName）" -ForegroundColor Green
$manifestName = if ($Game) { "update-game.json" } else { "update.json" }
Write-Host "   后续自动完成（约 1-2 分钟）：镜像上传 -> $manifestName -> 公开仓库 ebox-release -> purge CDN" -ForegroundColor DarkGray
Write-Host "   进度查看：https://github.com/$Repo/actions/workflows/auto-update.yml" -ForegroundColor DarkGray
