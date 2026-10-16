<#
.SYNOPSIS
    校园网自动认证配置工具（图形界面，免安装）。
    功能：配置/修改校园网账号密码、登录网址、WiFi名称；
          可选择是否开启 Windows 开机自动登录（自动输入密码解锁）；
          开启 WiFi 自动连接；安装开机自启；测试与卸载。
.USAGE
    双击同目录下的 校园网自动认证配置工具.cmd 启动（自动以 -STA 模式运行）。
    本脚本须在 Windows PowerShell 5.1+ 下运行。
#>
param([switch]$SmokeTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    # ps2exe 打包环境下 $PSScriptRoot / $MyInvocation.MyCommand.Path 均为空，
    # 改用 EXE 自身真实路径定位所在目录
    try {
        $exeFile = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exeFile) { $scriptDir = [System.IO.Path]::GetDirectoryName($exeFile) }
    } catch { }
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$configPath = Join-Path $scriptDir "config.json"
$pwPath     = Join-Path $scriptDir "password.enc"
$logPath    = Join-Path $scriptDir "auth.log"
$startupDir = [Environment]::GetFolderPath("Startup")
$startupVbs = Join-Path $startupDir "校园网自动认证.vbs"
$winlogon   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

# ================= 工具函数 =================
function Write-UI {
    param([string]$Msg)
    $txtLog.AppendText(("[" + (Get-Date -Format 'HH:mm:ss') + "] " + $Msg + "`r`n"))
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Load-ExistingConfig {
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $txtPortal.Text = [string]$cfg.portalUrl
            $txtSsid.Text   = [string]$cfg.ssid
            $txtUser.Text   = [string]$cfg.username
            if ($cfg.service) { $cboService.SelectedItem = [string]$cfg.service }
            if ($null -ne $cfg.bandPref) { $cboBand.SelectedIndex = [int]$cfg.bandPref }
            if ($null -ne $cfg.offHours) { $txtOff.Text = [string]$cfg.offHours }
            if ($null -ne $cfg.offDays)  { $chkOff.Checked = ([string]$cfg.offDays -eq "12345") }
        } catch { }
    }
    if (Test-Path $pwPath) {
        $lblPassState.Text = "已加密保存（填写新密码可覆盖）"
    } else {
        $lblPassState.Text = "未设置"
    }
}

function Load-AutoLoginState {
    try {
        $v = (Get-ItemProperty -Path $winlogon -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
        $chkAutoLogin.Checked = ($v -eq "1")
    } catch {
        $chkAutoLogin.Checked = $false
    }
}

function Save-CampusConfig {
    $portal = $txtPortal.Text.Trim()
    $ssid   = $txtSsid.Text.Trim()
    $user   = $txtUser.Text.Trim()
    $svc    = $cboService.Text
    if (-not $portal) { [System.Windows.Forms.MessageBox]::Show("请填写登录网址", "提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
    if (-not $user)   { [System.Windows.Forms.MessageBox]::Show("请填写校园网账号", "提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }

    # 校园网不可用时段（可选）：格式 "开始-结束"，如 0-6 表示 0:00-6:00
    $offStr  = $txtOff.Text.Trim()
    $offDays = ""
    if ($offStr) {
        $offParts = $offStr -split "-"
        if ($offParts.Count -ne 2 -or $offParts[0] -notmatch '^\d{1,2}$' -or $offParts[1] -notmatch '^\d{1,2}$' -or [int]$offParts[0] -lt 0 -or [int]$offParts[0] -gt 23 -or [int]$offParts[1] -lt 0 -or [int]$offParts[1] -gt 23) {
            [System.Windows.Forms.MessageBox]::Show("不可用时段格式应为【开始-结束】（如 0-6，表示 0:00-6:00）", "提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($chkOff.Checked) { $offDays = "12345" }   # 12345 = 按法定节假日日历的"仅工作日"
    }

    # 校园网密码：填写则加密覆盖；留空则保留已有
    if ($txtPass.Text) {
        $sec = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
        $enc = ConvertFrom-SecureString $sec
        [System.IO.File]::WriteAllText($pwPath, $enc, [System.Text.Encoding]::ASCII)
        Write-UI "校园网密码已加密保存（DPAPI，仅本机本账户可解）"
        $lblPassState.Text = "已加密保存"
        $txtPass.Clear()
    } elseif (-not (Test-Path $pwPath)) {
        [System.Windows.Forms.MessageBox]::Show("请填写校园网密码（首次配置必填）", "提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $cfgObj = [ordered]@{
        portalUrl    = $portal
        ssid         = $ssid
        username     = $user
        service      = $svc
        bandPref     = $cboBand.SelectedIndex
        passwordFile = $pwPath
        logFile      = $logPath
        maxWaitSec   = 300
        retryTimes   = 3
        offHours     = $offStr
        offDays      = $offDays
    }
    [System.IO.File]::WriteAllText($configPath, ($cfgObj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($true)))
    Write-UI "配置已保存：$configPath"

    # 注册开机自启（当前用户启动文件夹，无需管理员）
    # 优先调用打包后的 campus_auth.exe（静默无窗口）；exe 不存在时回退 powershell
    try {
        $exePath = Join-Path $scriptDir "campus_auth.exe"
        $psPath  = Join-Path $scriptDir "campus_auth.ps1"
        if (Test-Path $exePath) {
            $inner = '"' + $exePath + '"'
        } else {
            $inner = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $psPath + '" -Quiet'
        }
        $innerVbs = $inner.Replace('"', '""')
        $vbs = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" + 'sh.Run "' + $innerVbs + '", 0, False'
        [System.IO.File]::WriteAllText($startupVbs, $vbs, [System.Text.Encoding]::Unicode)
        Write-UI "开机自启已注册：$startupVbs"
    } catch {
        Write-UI "开机自启注册失败：$($_.Exception.Message)"
    }
}

function Test-Auth {
    $psPath = Join-Path $scriptDir "campus_auth.ps1"
    if (-not (Test-Path $psPath)) { Write-UI "缺少 campus_auth.ps1（请勿拆分文件夹）"; return }
    Write-UI "正在运行认证脚本（已在线时会提示无需认证）..."
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $psPath 2>&1 | Out-String
        $out -split "`n" | ForEach-Object { if ($_.Trim()) { Write-UI $_.Trim() } }
    } catch {
        Write-UI "测试异常：$($_.Exception.Message)"
    }
}

function Apply-AutoLogin {
    # 勾选 = 启用自动登录；取消勾选 = 关闭自动登录
    if ($chkAutoLogin.Checked) {
        $stage = Join-Path $scriptDir "winlogon_pw.txt"
        if ($txtWinPass.Text) {
            [System.IO.File]::WriteAllText($stage, $txtWinPass.Text, [System.Text.Encoding]::ASCII)
            $acl = Get-Acl $stage
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(("$env:USERDOMAIN\$env:USERNAME"), "FullControl", "Allow")
            $acl.AddAccessRule($rule)
            Set-Acl -Path $stage -AclObject $acl
            Write-UI "Windows 密码已暂存（应用后自动删除）"
        } else {
            Write-UI "未填写 Windows 密码：稍后在提权窗口中手动输入"
        }
        try {
            Start-Process -FilePath (Join-Path $scriptDir "enable_autologon.cmd") -Verb RunAs
            Write-UI "已弹出提权窗口：请点击【是】，将自动启用开机自动登录"
        } catch { Write-UI "启动失败：$($_.Exception.Message)" }
    } else {
        try {
            Start-Process -FilePath (Join-Path $scriptDir "disable_autologon.cmd") -Verb RunAs
            Write-UI "已弹出提权窗口：请点击【是】以取消开机自动登录"
        } catch { Write-UI "启动失败：$($_.Exception.Message)" }
    }
}

function Set-WifiAutoConnect {
    $ssid = $txtSsid.Text.Trim()
    if (-not $ssid) { [System.Windows.Forms.MessageBox]::Show("请先填写WiFi名称", "提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
    Write-UI "正在开启 $ssid 自动连接..."
    $out = (& netsh wlan set profileparameter name=$ssid connectionmode=auto 2>&1 | Out-String)
    if ($out -match "updated successfully|更新成功") {
        Write-UI "成功：$ssid 已设为自动连接"
        & netsh wlan set profileorder name=$ssid priority=1 2>$null | Out-Null
    } else {
        Write-UI "直接设置未成功（可能需要管理员），正在尝试提权执行..."
        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $scriptDir "enable_wifi_autoconnect.ps1"), "-Ssid", "`"$ssid`"") -Verb RunAs
            Write-UI "已弹出提权窗口：请点击【是】"
        } catch { Write-UI "启动失败：$($_.Exception.Message)" }
    }
}

function Uninstall-All {
    try {
        Start-Process -FilePath (Join-Path $scriptDir "uninstall.cmd") -Verb RunAs
        Write-UI "已弹出提权窗口：请点击【是】以卸载自启项与计划任务"
    } catch { Write-UI "启动失败：$($_.Exception.Message)" }
}

# ================= 检查更新 =================
$script:LocalVersion = 1
$UpdateUrl = "https://cdn.jsdelivr.net/gh/jiangnanxiaomazha/CampusNetAuth@main/version.json"

function Check-Update {
    Write-UI "正在检查更新..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $json = Invoke-RestMethod -Uri $UpdateUrl -TimeoutSec 10 -UseBasicParsing
        $latest = [int]$json.versionCode
        Write-UI "当前版本：v$($script:LocalVersion)，最新版本：v$latest（$($json.versionName)）"
        if ($latest -le $script:LocalVersion) {
            Write-UI "已是最新版本"
            return
        }
        Write-UI "发现新版本！更新内容：$($json.changelog)"
        Write-UI "开始下载更新文件..."
        $baseUrl = "https://cdn.jsdelivr.net/gh/jiangnanxiaomazha/CampusNetAuth@main/"
        $updated = 0
        foreach ($f in $json.files) {
            try {
                $content = Invoke-WebRequest -Uri ($baseUrl + $f) -TimeoutSec 15 -UseBasicParsing
                Set-Content -Path (Join-Path $scriptDir $f) -Value $content.Content -Encoding UTF8 -NoNewline
                Write-UI "已更新：$f"
                $updated++
            } catch {
                Write-UI "下载失败：$f - $($_.Exception.Message)"
            }
        }
        if ($updated -gt 0) {
            $script:LocalVersion = $latest
            Write-UI "更新完成（$updated 个文件），请重启配置工具以生效"
            [System.Windows.Forms.MessageBox]::Show("更新完成，请重启配置工具以生效。", "更新成功", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    } catch {
        Write-UI "检查更新失败：$($_.Exception.Message)"
    }
}

# ================= 界面构建 =================
$form = New-Object System.Windows.Forms.Form
$form.Text = "校园网自动认证配置工具"
$form.Size = New-Object System.Drawing.Size(620, 760)
$form.StartPosition = "CenterScreen"
$form.MaximizeBox = $false
$form.FormBorderStyle = "FixedSingle"
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9)

# --- 校园网认证配置 ---
$grpCampus = New-Object System.Windows.Forms.GroupBox
$grpCampus.Text = "校园网认证配置（登录网址 / 账号密码）"
$grpCampus.Location = New-Object System.Drawing.Point(12, 8)
$grpCampus.Size = New-Object System.Drawing.Size(580, 204)

$lblPortal = New-Object System.Windows.Forms.Label; $lblPortal.Text = "登录网址："; $lblPortal.Location = New-Object System.Drawing.Point(15, 30)
$txtPortal = New-Object System.Windows.Forms.TextBox; $txtPortal.Text = ""; $txtPortal.Location = New-Object System.Drawing.Point(110, 26); $txtPortal.Size = New-Object System.Drawing.Size(440, 23); $txtPortal.PlaceholderText = "请填写本校登录网址（如 http://10.x.x.x）"

$lblSsid = New-Object System.Windows.Forms.Label; $lblSsid.Text = "WiFi名称："; $lblSsid.Location = New-Object System.Drawing.Point(15, 66)
$txtSsid = New-Object System.Windows.Forms.TextBox; $txtSsid.Text = ""; $txtSsid.Location = New-Object System.Drawing.Point(110, 62); $txtSsid.Size = New-Object System.Drawing.Size(160, 23); $txtSsid.PlaceholderText = "校园网WiFi名称"

$lblOff = New-Object System.Windows.Forms.Label; $lblOff.Text = "不可用时段："; $lblOff.Location = New-Object System.Drawing.Point(285, 66); $lblOff.Size = New-Object System.Drawing.Size(82, 23)
$txtOff = New-Object System.Windows.Forms.TextBox; $txtOff.Text = "0-6"; $txtOff.Location = New-Object System.Drawing.Point(367, 62); $txtOff.Size = New-Object System.Drawing.Size(72, 23); $txtOff.ToolTipText = "校园网无法使用的时段，格式：【开始-结束】（如 0-6 表示 0:00-6:00），留空表示不限制"
$chkOff = New-Object System.Windows.Forms.CheckBox; $chkOff.Text = "仅工作日"; $chkOff.Location = New-Object System.Drawing.Point(448, 64); $chkOff.Size = New-Object System.Drawing.Size(80, 26); $chkOff.Checked = $true; $chkOff.ToolTipText = "按国务院法定节假日安排计算：正常周末和法定节假日不生效，调休上班日视为工作日"

$lblUser = New-Object System.Windows.Forms.Label; $lblUser.Text = "校园网账号："; $lblUser.Location = New-Object System.Drawing.Point(15, 102)
$txtUser = New-Object System.Windows.Forms.TextBox; $txtUser.Location = New-Object System.Drawing.Point(110, 98); $txtUser.Size = New-Object System.Drawing.Size(160, 23)

$lblService = New-Object System.Windows.Forms.Label; $lblService.Text = "运营商："; $lblService.Location = New-Object System.Drawing.Point(285, 102); $lblService.Size = New-Object System.Drawing.Size(55, 23)
$cboService = New-Object System.Windows.Forms.ComboBox; $cboService.Location = New-Object System.Drawing.Point(340, 98); $cboService.Size = New-Object System.Drawing.Size(130, 23); $cboService.DropDownStyle = "DropDown"
[void]$cboService.Items.AddRange(@("校园内网", "中国移动", "中国联通", "中国电信"))
$cboService.SelectedItem = "中国移动"
$cboService.ToolTipText = "可从下拉选择，也可手动输入本校运营商名称"

$lblPass = New-Object System.Windows.Forms.Label; $lblPass.Text = "校园网密码："; $lblPass.Location = New-Object System.Drawing.Point(15, 138)
$txtPass = New-Object System.Windows.Forms.TextBox; $txtPass.Location = New-Object System.Drawing.Point(110, 134); $txtPass.Size = New-Object System.Drawing.Size(160, 23); $txtPass.PasswordChar = "*"
$lblPassState = New-Object System.Windows.Forms.Label; $lblPassState.Text = ""; $lblPassState.Location = New-Object System.Drawing.Point(285, 138); $lblPassState.Size = New-Object System.Drawing.Size(280, 23); $lblPassState.ForeColor = [System.Drawing.Color]::Gray

$lblBand = New-Object System.Windows.Forms.Label; $lblBand.Text = "优先频段："; $lblBand.Location = New-Object System.Drawing.Point(15, 174); $lblBand.Size = New-Object System.Drawing.Size(82, 23)
$cboBand = New-Object System.Windows.Forms.ComboBox; $cboBand.Location = New-Object System.Drawing.Point(110, 170); $cboBand.Size = New-Object System.Drawing.Size(160, 23); $cboBand.DropDownStyle = "DropDownList"
[void]$cboBand.Items.AddRange(@("自动（系统选择）", "优先 5GHz", "仅 5GHz", "优先 2.4GHz", "仅 2.4GHz"))
$cboBand.SelectedIndex = 1
$cboBand.ToolTipText = "连接校园网时优先选择的WiFi频段"

$grpCampus.Controls.AddRange(@($lblPortal,$txtPortal,$lblSsid,$txtSsid,$lblOff,$txtOff,$chkOff,$lblUser,$txtUser,$lblService,$cboService,$lblPass,$txtPass,$lblPassState,$lblBand,$cboBand))

$btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "保存校园网配置"; $btnSave.Location = New-Object System.Drawing.Point(12, 222); $btnSave.Size = New-Object System.Drawing.Size(150, 32); $btnSave.BackColor = [System.Drawing.Color]::FromArgb(46, 160, 67); $btnSave.ForeColor = [System.Drawing.Color]::White
$btnTest = New-Object System.Windows.Forms.Button; $btnTest.Text = "测试认证脚本"; $btnTest.Location = New-Object System.Drawing.Point(170, 222); $btnTest.Size = New-Object System.Drawing.Size(130, 32)

# --- Windows 开机自动登录（可选择是否开启）---
$grpWin = New-Object System.Windows.Forms.GroupBox
$grpWin.Text = "Windows 开机自动登录（可选）"
$grpWin.Location = New-Object System.Drawing.Point(12, 264)
$grpWin.Size = New-Object System.Drawing.Size(580, 150)

$chkAutoLogin = New-Object System.Windows.Forms.CheckBox
$chkAutoLogin.Text = "开机自动输入Windows密码解锁（勾选=启用，取消勾选=关闭）"
$chkAutoLogin.Location = New-Object System.Drawing.Point(15, 24)
$chkAutoLogin.Size = New-Object System.Drawing.Size(500, 26)
$chkAutoLogin.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9, [System.Drawing.FontStyle]::Bold)

$lblWinUser = New-Object System.Windows.Forms.Label; $lblWinUser.Text = "Windows账户："; $lblWinUser.Location = New-Object System.Drawing.Point(15, 62)
$txtWinUser = New-Object System.Windows.Forms.TextBox; $txtWinUser.Text = [Environment]::UserName; $txtWinUser.Location = New-Object System.Drawing.Point(110, 58); $txtWinUser.Size = New-Object System.Drawing.Size(160, 23)

$lblWinPass = New-Object System.Windows.Forms.Label; $lblWinPass.Text = "Windows密码："; $lblWinPass.Location = New-Object System.Drawing.Point(15, 98)
$txtWinPass = New-Object System.Windows.Forms.TextBox; $txtWinPass.Location = New-Object System.Drawing.Point(110, 94); $txtWinPass.Size = New-Object System.Drawing.Size(160, 23); $txtWinPass.PasswordChar = "*"

$lblWinHint = New-Object System.Windows.Forms.Label; $lblWinHint.Text = "提示：填写密码可不弹输入框；留空则在提权窗口手动输入一次"; $lblWinHint.Location = New-Object System.Drawing.Point(15, 124); $lblWinHint.Size = New-Object System.Drawing.Size(540, 20); $lblWinHint.ForeColor = [System.Drawing.Color]::Gray

$grpWin.Controls.AddRange(@($chkAutoLogin,$lblWinUser,$txtWinUser,$lblWinPass,$txtWinPass,$lblWinHint))

$btnAutoLogin = New-Object System.Windows.Forms.Button; $btnAutoLogin.Text = "应用自动登录设置"; $btnAutoLogin.Location = New-Object System.Drawing.Point(12, 420); $btnAutoLogin.Size = New-Object System.Drawing.Size(150, 32); $btnAutoLogin.BackColor = [System.Drawing.Color]::FromArgb(0, 122, 204); $btnAutoLogin.ForeColor = [System.Drawing.Color]::White

# --- 其他操作 ---
$grpOther = New-Object System.Windows.Forms.GroupBox
$grpOther.Text = "其他"
$grpOther.Location = New-Object System.Drawing.Point(12, 468)
$grpOther.Size = New-Object System.Drawing.Size(580, 66)

$btnWifi = New-Object System.Windows.Forms.Button; $btnWifi.Text = "开启WiFi自动连接"; $btnWifi.Location = New-Object System.Drawing.Point(15, 24); $btnWifi.Size = New-Object System.Drawing.Size(150, 30)
$btnUninstall = New-Object System.Windows.Forms.Button; $btnUninstall.Text = "卸载全部"; $btnUninstall.Location = New-Object System.Drawing.Point(175, 24); $btnUninstall.Size = New-Object System.Drawing.Size(120, 30)
$btnUpdate = New-Object System.Windows.Forms.Button; $btnUpdate.Text = "检查更新"; $btnUpdate.Location = New-Object System.Drawing.Point(305, 24); $btnUpdate.Size = New-Object System.Drawing.Size(120, 30)
$grpOther.Controls.AddRange(@($btnWifi,$btnUninstall,$btnUpdate))

# --- 日志区 ---
$lblLogTitle = New-Object System.Windows.Forms.Label; $lblLogTitle.Text = "运行信息："; $lblLogTitle.Location = New-Object System.Drawing.Point(12, 546)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 568)
$txtLog.Size = New-Object System.Drawing.Size(580, 160)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = [System.Drawing.Color]::White

# 事件绑定
$btnSave.Add_Click({ Save-CampusConfig })
$btnTest.Add_Click({ Test-Auth })
$btnAutoLogin.Add_Click({ Apply-AutoLogin })
$btnWifi.Add_Click({ Set-WifiAutoConnect })
$btnUninstall.Add_Click({ Uninstall-All })
$btnUpdate.Add_Click({ Check-Update })

$form.Controls.AddRange(@($grpCampus,$btnSave,$btnTest,$grpWin,$btnAutoLogin,$grpOther,$lblLogTitle,$txtLog))

# 加载已有配置与自动登录状态
Load-ExistingConfig
Load-AutoLoginState
Write-UI "欢迎使用校园网自动认证配置工具"
Write-UI "1. 填写校园网配置后点击【保存校园网配置】"
Write-UI "2. 需要开机免输密码就勾选上方选项并点击【应用自动登录设置】（首次需点一次【是】）"

if ($SmokeTest) {
    $form.Add_Shown({ $form.Close() })
}

# 全局异常兜底：未捕获异常写入 gui_error.log，便于排查（不依赖弹窗）
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    try {
        $log = Join-Path $scriptDir "gui_error.log"
        [System.IO.File]::AppendAllText($log, ("{0}  {1}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), [string]$e.ExceptionObject))
    } catch { }
})

[System.Windows.Forms.Application]::Run($form)
if ($SmokeTest) { Write-Host "GUI 构建成功，可正常启动" }
