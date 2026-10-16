<#
.SYNOPSIS
    开启指定 WiFi 的自动连接并设为优先。以管理员身份运行（或由配置工具自动提权调用）。
.PARAMETER Ssid
    无线网名称，默认 CQRK
#>
param([string]$Ssid = "CQRK")

$ErrorActionPreference = "Continue"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[错误] 需要管理员权限，请在提权窗口中运行。" -ForegroundColor Red
    Read-Host "按回车键关闭"
    exit 1
}

if (-not $Ssid) { $Ssid = Read-Host "请输入无线网名称(SSID)" }

Write-Host "正在设置 $Ssid 自动连接..."
netsh wlan set profileparameter name=$Ssid connectionmode=auto
netsh wlan set profileorder name=$Ssid priority=1
Write-Host ""
Write-Host "完成：$Ssid 已设为自动连接并优先（信号范围内自动连接）" -ForegroundColor Green
Read-Host "按回车键关闭窗口"
