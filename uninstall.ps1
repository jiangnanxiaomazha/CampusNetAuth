<#
.SYNOPSIS
    校园网自动认证 - 卸载：删除开机自启项与兜底计划任务（不删除凭据文件，由用户手动决定）。
.USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#>
$ErrorActionPreference = "Stop"

# 1. 删除启动文件夹自启项
$startupDir = [Environment]::GetFolderPath("Startup")
$vbsPath = Join-Path $startupDir "校园网自动认证.vbs"
if (Test-Path $vbsPath) {
    Remove-Item $vbsPath -Force
    Write-Host "已删除开机自启项：$vbsPath" -ForegroundColor Green
} else {
    Write-Host "未找到开机自启项，跳过。"
}

# 2. 删除兜底计划任务
try {
    schtasks /Delete /TN "CampusNetAutoAuth" /F 2>$null | Out-Null
    Write-Host "已删除兜底计划任务 CampusNetAutoAuth（若存在）。" -ForegroundColor Green
} catch {
    Write-Host "[提示] 计划任务删除失败：$($_.Exception.Message)" -ForegroundColor Yellow
}

# 3. 提示
Write-Host ""
Write-Host "自动认证已停止。"
Write-Host "配置目录：$PSScriptRoot（含 config.json、password.enc、auth.log）"
Write-Host "如需彻底清除凭据，请手动删除该目录。"
