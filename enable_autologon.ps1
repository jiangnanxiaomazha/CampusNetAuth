<#
.SYNOPSIS
    启用 Windows 开机自动登录（AutoAdminLogon）。必须以管理员身份运行。
.DESCRIPTION
    写入 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon：
      AutoAdminLogon=1 / DefaultUserName / DefaultDomainName / DefaultPassword
    使电脑重启后自动进入桌面，无需输入开机密码。
    注意：
      1. 密码会以明文形式保存在注册表中，任何能接触本机的人都可进入已登录会话。
      2. 手动锁屏(Win+L)或睡眠唤醒仍需输入密码，不受影响。
      3. 如需取消，运行 disable_autologon.ps1。
.PARAMETER Password
    可直接传入密码（不推荐在命令行明文传入，默认交互安全输入）。
.EXAMPLE
    右键 enable_autologon.cmd -> 以管理员身份运行，按提示输入密码
#>
param([string]$Password = "")

$ErrorActionPreference = "Stop"

# 管理员权限检查
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[错误] 需要管理员权限。请右键 enable_autologon.cmd，选择“以管理员身份运行”。" -ForegroundColor Red
    exit 1
}

# 读取密码（优先使用预置文件，否则交互输入）
$stagedFile = Join-Path $PSScriptRoot "winlogon_pw.txt"
if (-not $Password -and (Test-Path $stagedFile)) {
    $Password = ([System.IO.File]::ReadAllText($stagedFile)).Trim()
}
if (-not $Password) {
    $sec = Read-Host "请输入 Windows 登录密码（输入时不显示）" -AsSecureString
    if (-not $sec -or $sec.Length -eq 0) { Write-Host "[错误] 密码不能为空。" -ForegroundColor Red; exit 1 }
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

$user   = [Environment]::UserName
$domain = [Environment]::MachineName
$wl     = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

Set-ItemProperty -Path $wl -Name "AutoAdminLogon"    -Value "1"  -Type String
Set-ItemProperty -Path $wl -Name "DefaultUserName"   -Value $user -Type String
Set-ItemProperty -Path $wl -Name "DefaultDomainName" -Value $domain -Type String
Set-ItemProperty -Path $wl -Name "DefaultPassword"   -Value $Password -Type String

# 清理预置明文文件（已写入注册表）
if (Test-Path $stagedFile) { Remove-Item $stagedFile -Force }

Write-Host ""
Write-Host "已启用开机自动登录：" -ForegroundColor Green
Write-Host "  账户：$domain\$user"
Write-Host "  下次重启后自动进入桌面，无需输入密码。"
Write-Host ""
Write-Host "安全提醒：" -ForegroundColor Yellow
Write-Host "  - 开机自动登录期间，任何能接触本机的人可直接使用已登录会话，请注意环境安全"
Write-Host "  - 锁屏/睡眠唤醒仍需密码"
Write-Host "  - 取消自动登录：以管理员身份运行 disable_autologon.cmd"
