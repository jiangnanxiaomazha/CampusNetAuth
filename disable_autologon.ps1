<#
.SYNOPSIS
    取消 Windows 开机自动登录。必须以管理员身份运行。
#>
$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[错误] 需要管理员权限。请右键 disable_autologon.cmd，选择“以管理员身份运行”。" -ForegroundColor Red
    exit 1
}

$wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Remove-ItemProperty -Path $wl -Name "AutoAdminLogon"    -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wl -Name "DefaultUserName"   -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wl -Name "DefaultDomainName" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wl -Name "DefaultPassword"   -ErrorAction SilentlyContinue

Write-Host "已取消开机自动登录，下次开机将恢复要求输入密码。" -ForegroundColor Green
