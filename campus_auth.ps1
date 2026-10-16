<#
.SYNOPSIS
    校园网自动认证脚本 - 开机后自动完成 Web Portal 认证（兼容华为 ePortal）。
.DESCRIPTION
    1. 等待网络就绪（Wi-Fi 已连接且认证门户可达）
    2. 检测当前认证状态（已在线则直接退出）
    3. 获取最新的认证参数 queryString（每次连接都会变化，不可硬编码）
    4. 提交账号密码完成认证（凭据由 Windows DPAPI 加密存储）
    5. 验证在线状态并写入日志
.PARAMETER ConfigPath
    配置文件路径，默认取脚本同目录下的 config.json
.PARAMETER ForceLogin
    强制提交一次登录请求（即使检测到已在线），用于接口冒烟测试，不影响已在线会话
.PARAMETER Quiet
    不在控制台输出，仅写日志
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File campus_auth.ps1
#>
param(
    [string]$ConfigPath = "",
    [switch]$ForceLogin,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# 用 UTF-8 代码页调用 netsh，确保输出为英文字段名（避免中文乱码导致正则匹配失败）
# 不全局修改控制台编码，否则脚本自身的中文输出会被配置界面误读为乱码
function Invoke-NetshUtf8 {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$NetshArgs)
    $cmd = "chcp 65001 >nul && netsh.exe " + ($NetshArgs -join " ")
    & cmd.exe /c $cmd 2>&1 | Out-String
}

# ---------- 配置加载 ----------
# 定位脚本所在目录：ps2exe 打包环境下 $PSScriptRoot 为空，改用 EXE 真实路径
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    try {
        $exeFile = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exeFile) { $scriptDir = [System.IO.Path]::GetDirectoryName($exeFile) }
    } catch { }
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir "config.json" }
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[错误] 未找到配置文件: $ConfigPath（请先打开 校园网自动认证配置工具.exe 完成配置）" -ForegroundColor Red
    exit 2
}
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$portalUrl    = [string]$cfg.portalUrl
$username     = [string]$cfg.username
$service      = if ($null -ne $cfg.service) { [string]$cfg.service } else { "" }
$passwordFile = if ($cfg.passwordFile) { [Environment]::ExpandEnvironmentVariables([string]$cfg.passwordFile) } else { Join-Path $scriptDir "password.enc" }
$logFile      = if ($cfg.logFile) { [Environment]::ExpandEnvironmentVariables([string]$cfg.logFile) } else { Join-Path $scriptDir "auth.log" }
$maxWaitSec   = if ($cfg.maxWaitSec) { [int]$cfg.maxWaitSec } else { 300 }
$retryTimes   = if ($cfg.retryTimes) { [int]$cfg.retryTimes } else { 3 }
$expectSsid   = if ($cfg.ssid) { [string]$cfg.ssid } else { "" }
# 校园网不可用时段：offHours 如 "0-6"（0:00-6:00），空表示不限制；offDays "12345"=仅周一至周五，空=每天
$offHours     = if ($null -ne $cfg.offHours) { [string]$cfg.offHours } else { "" }
$offDays      = if ($null -ne $cfg.offDays)  { [string]$cfg.offDays }  else { "" }
$ua           = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

# ---------- 工具函数 ----------
function Write-Log {
    param([string]$Msg)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    if (-not $Quiet) { Write-Output $line }
    try {
        $dir = Split-Path $logFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch { }
}

# 双重 URL 编码，模拟登录页 JS 的 encodeURIComponent(encodeURIComponent(x))
function ConvertTo-DoubleUrlEncode {
    param([string]$s)
    return [System.Uri]::EscapeDataString([System.Uri]::EscapeDataString($s))
}

# 解密凭据（DPAPI，仅本机本账户可解）
function Get-PlainPassword {
    $enc = [System.IO.File]::ReadAllText($passwordFile)
    $sec = $enc | ConvertTo-SecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# 获取当前活动网络连接名称（无线连接时即 WiFi 的 SSID）
function Get-CurrentSsid {
    try {
        $prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4Connectivity -and $_.IPv4Connectivity -ne "Disconnected" } |
            Select-Object -First 1
        if ($prof) { return ([string]$prof.Name).Trim() }
    } catch { }
    return ""
}

# 判断当前连接是否为目标 WiFi：
#   完全一致；或以目标名为前缀且下一字符为 空格/-/_（如配置 CQRK，可匹配 "CQRK 4"/"CQRK-5G"）
#   未配置 SSID（为空）时不限制，保持兼容
function Test-TargetWifi {
    param([string]$Name)
    if (-not $expectSsid) { return $true }
    if (-not $Name) { return $false }
    if ($Name -eq $expectSsid) { return $true }
    if ($Name.Length -gt $expectSsid.Length -and
        $Name.StartsWith($expectSsid, [System.StringComparison]::OrdinalIgnoreCase)) {
        $next = $Name[$expectSsid.Length]
        return ($next -eq ' ' -or $next -eq '-' -or $next -eq '_')
    }
    return $false
}

# 中国法定节假日日历（2026年，来源：国务院办公厅 国办发明电〔2025〕7号）
# 放假日（含调休形成的小长假）
$CN_HOLIDAYS_2026 = @(
    "2026-01-01","2026-01-02","2026-01-03",                                   # 元旦
    "2026-02-15","2026-02-16","2026-02-17","2026-02-18","2026-02-19",
    "2026-02-20","2026-02-21","2026-02-22","2026-02-23",                       # 春节
    "2026-04-04","2026-04-05","2026-04-06",                                   # 清明
    "2026-05-01","2026-05-02","2026-05-03","2026-05-04","2026-05-05",         # 劳动节
    "2026-06-19","2026-06-20","2026-06-21",                                   # 端午
    "2026-09-25","2026-09-26","2026-09-27",                                   # 中秋
    "2026-10-01","2026-10-02","2026-10-03","2026-10-04",
    "2026-10-05","2026-10-06","2026-10-07"                                    # 国庆
)
# 调休上班日（周末补班）
$CN_WORKDAYS_2026 = @(
    "2026-01-04","2026-02-14","2026-02-28","2026-05-09","2026-09-20","2026-10-10"
)

# 按中国法定节假日日历判断当天是否为工作日
# 2026 年使用内置官方日历；其余年份（如 2027 年安排尚未发布）按常规周末判断
function Test-CnWorkday {
    param([datetime]$d)
    if ($d.Year -eq 2026) {
        $s = $d.ToString("yyyy-MM-dd")
        if ($CN_HOLIDAYS_2026 -contains $s) { return $false }
        if ($CN_WORKDAYS_2026 -contains $s) { return $true }
    }
    return ($d.DayOfWeek -ne [DayOfWeek]::Saturday -and $d.DayOfWeek -ne [DayOfWeek]::Sunday)
}

# 判断当前时间是否处于校园网不可用时段（offHours 如 "0-6"，支持跨天如 "22-6"）
function Test-OffHours {
    if (-not $offHours) { return $false }
    $parts = $offHours -split "-"
    if ($parts.Count -ne 2) { return $false }
    $start = 0; $end = 0
    if (-not [int]::TryParse($parts[0], [ref]$start)) { return $false }
    if (-not [int]::TryParse($parts[1], [ref]$end))   { return $false }
    # 星期匹配：offDays "12345" 表示按法定节假日日历的"仅工作日"（节假日与正常周末不生效，调休上班日生效）
    if ($offDays -eq "12345") {
        if (-not (Test-CnWorkday (Get-Date))) { return $false }
    } elseif ($offDays) {
        $dow = [string][int](Get-Date).DayOfWeek
        if ($offDays -notmatch $dow) { return $false }
    }
    $now = (Get-Date).Hour
    if ($start -eq $end) { return $false }
    if ($start -lt $end) { return ($now -ge $start -and $now -lt $end) }
    return ($now -ge $start -or $now -lt $end)   # 跨天，如 22-6
}

# 扫描目标 SSID 的所有接入点，按频段偏好选择最佳 BSSID
# 返回 @{Bssid; Channel; Signal; Band}，未找到返回 $null
function Get-BestBssid {
    param([string]$Ssid, [int]$BandPref)
    try {
        $raw = Invoke-NetshUtf8 wlan show networks mode=bssid
        $lines = $raw -split "`r?`n"
        $results = New-Object System.Collections.ArrayList
        $curSsid = ""
        $curBssid = ""
        $curChannel = 0
        $curSignal = 0
        $curBand = ""
        foreach ($line in $lines) {
            if ($line -match "^\s*SSID\s+\d+\s*:\s*(.+)") {
                if ($curBssid -and $curSsid -match [regex]::Escape($Ssid)) {
                    if (-not $curBand) { $curBand = if ($curChannel -ge 36) { "5GHz" } else { "2.4GHz" } }
                    [void]$results.Add([PSCustomObject]@{ Bssid = $curBssid; Channel = $curChannel; Signal = $curSignal; Band = $curBand })
                }
                $curSsid = $Matches[1].Trim()
                $curBssid = ""; $curChannel = 0; $curSignal = 0; $curBand = ""
            } elseif ($line -match "BSSID\s+\d+\s*:\s*([0-9a-fA-F:]+)") {
                if ($curBssid -and $curSsid -match [regex]::Escape($Ssid)) {
                    if (-not $curBand) { $curBand = if ($curChannel -ge 36) { "5GHz" } else { "2.4GHz" } }
                    [void]$results.Add([PSCustomObject]@{ Bssid = $curBssid; Channel = $curChannel; Signal = $curSignal; Band = $curBand })
                }
                $curBssid = $Matches[1].Trim()
                $curChannel = 0; $curSignal = 0; $curBand = ""
            } elseif ($line -match "Channel\s*:\s*(\d+)") {
                $curChannel = [int]$Matches[1]
            } elseif ($line -match "Signal\s*:\s*(\d+)%") {
                $curSignal = [int]$Matches[1]
            } elseif ($line -match "Band\s*:\s*(.+)") {
                $b = $Matches[1].Trim()
                if ($b -match "5") { $curBand = "5GHz" } elseif ($b -match "2\.4") { $curBand = "2.4GHz" }
            }
        }
        if ($curBssid -and $curSsid -match [regex]::Escape($Ssid)) {
            if (-not $curBand) { $curBand = if ($curChannel -ge 36) { "5GHz" } else { "2.4GHz" } }
            [void]$results.Add([PSCustomObject]@{ Bssid = $curBssid; Channel = $curChannel; Signal = $curSignal; Band = $curBand })
        }
        if ($results.Count -eq 0) { return $null }

        $five = $results | Where-Object { $_.Band -eq "5GHz" } | Sort-Object Signal -Descending
        $two  = $results | Where-Object { $_.Band -eq "2.4GHz" } | Sort-Object Signal -Descending
        switch ($BandPref) {
            1 { if ($five) { return $five[0] } elseif ($two) { return $two[0] } else { return $null } }
            2 { if ($five) { return $five[0] } else { return $null } }
            3 { if ($two) { return $two[0] } elseif ($five) { return $five[0] } else { return $null } }
            4 { if ($two) { return $two[0] } else { return $null } }
            default { return ($results | Sort-Object Signal -Descending)[0] }
        }
    } catch {
        return $null
    }
}

# 查询当前 WiFi 连接的实际频段信息
function Get-CurrentWifiInfo {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $ifOut = Invoke-NetshUtf8 wlan show interfaces
            $ssid = ""; $bssid = ""; $band = ""; $channel = 0; $signal = 0
            if ($ifOut -match "SSID\s*:\s*(.+?)\s*`r?`n") { $ssid = $Matches[1].Trim() }
            if ($ifOut -match "BSSID\s*:\s*([0-9a-fA-F:]+)") { $bssid = $Matches[1] }
            if ($ifOut -match "Channel\s*:\s*(\d+)") { $channel = [int]$Matches[1] }
            if ($ifOut -match "Signal\s*:\s*(\d+)%") { $signal = [int]$Matches[1] }
            if ($ifOut -match "Band\s*:\s*(.+)") {
                $b = $Matches[1].Trim()
                if ($b -match "5") { $band = "5GHz" } elseif ($b -match "2\.4") { $band = "2.4GHz" }
            }
            if (-not $band -and $channel -gt 0) { $band = if ($channel -ge 36) { "5GHz" } else { "2.4GHz" } }
            if ($band) { return @{ Ssid = $ssid; Bssid = $bssid; Band = $band; Channel = $channel; Signal = $signal } }
        } catch { }
        Start-Sleep -Milliseconds 800
    }
    # 查询失败时记录原始输出用于诊断
    try {
        $dbg = & netsh.exe wlan show interfaces 2>&1 | Out-String
        Write-Log "频段查询失败，netsh原始输出：$($dbg.Substring(0, [Math]::Min(300, $dbg.Length)))"
    } catch { }
    return @{ Ssid = ""; Bssid = ""; Band = ""; Channel = 0; Signal = 0 }
}

# 尝试自动连接到目标 WiFi（需系统里曾连接并保存过该网络配置）
function Connect-TargetWifi {
    if (-not $expectSsid) { return $false }
    try {
        # 从无线配置文件列表中找到目标 SSID 对应的配置名（如 "CQRK" 或 "CQRK 4"）
        $profilesOut = Invoke-NetshUtf8 wlan show profiles
        $profileName = ""
        foreach ($line in ($profilesOut -split "`r?`n")) {
            if ($line -match ":\s*([^\s:].*?)\s*$") {
                $namePart = $Matches[1].Trim()
                if ($namePart -and $namePart -match [regex]::Escape($expectSsid)) {
                    $profileName = $namePart
                    break
                }
            }
        }
        if (-not $profileName) {
            Write-Log "未找到 '$expectSsid' 的无线网络配置（需先在系统里连接过该 WiFi）"
            return $false
        }

        # 按频段偏好选择最佳 BSSID
        $bandPref = if ($cfg.bandPref) { [int]$cfg.bandPref } else { 1 }
        $best = Get-BestBssid -Ssid $expectSsid -BandPref $bandPref
        if ($best) {
            Write-Log "选择接入点：$($best.Bssid)（$($best.Band) 通道$($best.Channel) 信号$($best.Signal)%）"
            $out = & netsh.exe wlan connect name="$profileName" ssid="$expectSsid" bssid="$($best.Bssid)" 2>&1 | Out-String
        } else {
            Write-Log "未扫描到合适的接入点，使用系统默认选择"
            $out = & netsh.exe wlan connect name="$profileName" ssid="$expectSsid" 2>&1 | Out-String
        }

        if ($LASTEXITCODE -eq 0) {
            Write-Log "已发出自动连接请求：$profileName"
            # 等待连接建立，查询实际连接的频段
            Start-Sleep -Seconds 4
            $ifOut = Invoke-NetshUtf8 wlan show interfaces
            $actualBand = ""
            $actualChannel = 0
            $actualBssid = ""
            foreach ($l in ($ifOut -split "`r?`n")) {
                if ($l -match "BSSID\s*:\s*([0-9a-fA-F:]+)") { $actualBssid = $Matches[1] }
                elseif ($l -match "Channel\s*:\s*(\d+)") { $actualChannel = [int]$Matches[1] }
                elseif ($l -match "Band\s*:\s*(.+)") {
                    $b = $Matches[1].Trim()
                    if ($b -match "5") { $actualBand = "5GHz" } elseif ($b -match "2\.4") { $actualBand = "2.4GHz" }
                }
            }
            if (-not $actualBand -and $actualChannel -gt 0) {
                $actualBand = if ($actualChannel -ge 36) { "5GHz" } else { "2.4GHz" }
            }
            if ($actualBand) {
                Write-Log "实际连接：BSSID=$actualBssid 频段=$actualBand 通道=$actualChannel"
            }
            return $true
        }
        Write-Log "自动连接请求失败：$($out.Trim())"
        return $false
    } catch {
        Write-Log "自动连接异常：$($_.Exception.Message)"
        return $false
    }
}

# 检测门户认证状态：online / login / unreachable
# 注意：必须跟随完整重定向链（-L）——未认证时第一次 302 也可能是
# redirectortosuccess.jsp，跟随后最终才是 index.jsp 登录页；只看第一次会误判。
function Get-PortalState {
    try {
        $tmp = Join-Path $env:TEMP ("campus_st_" + [guid]::NewGuid().ToString("N") + ".tmp")
        & curl.exe -s -L -i -m 12 -A $ua -o $tmp "$portalUrl/" 2>$null
        $code = $LASTEXITCODE
        $raw = ""
        if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding Default }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($code -ne 0 -and -not $raw) { return "unreachable" }
        # 取重定向链中最后一次 Location（最终跳转目标）
        $locs = [regex]::Matches($raw, "Location:\s*([^\r\n]+)")
        $lastLoc = if ($locs.Count -gt 0) { $locs[$locs.Count - 1].Groups[1].Value } else { "" }
        # 最终页面正文（最后一个空行之后的内容）
        $body = ""
        $parts = $raw -split "`r?`n`r?`n"
        if ($parts.Count -gt 0) { $body = $parts[$parts.Count - 1] }
        # 已在线：最终跳到 success.jsp，或页面含成功页特征
        if ($lastLoc -match "success\.jsp" -or $body -match "您已成功连接|下线.*Logout|已成功|redirectortosuccess") {
            return "online"
        }
        # 未认证：最终跳到 index.jsp，或页面含登录页特征
        if ($lastLoc -match "index\.jsp" -or $body -match "连接 Login|用户名|密码|username|password|index\.jsp") {
            return "login"
        }
        if ($raw -match "index\.jsp") { return "login" }
        return "unreachable"
    } catch {
        return "unreachable"
    }
}

# 从 redirectortosuccess.jsp 重定向链中获取 userIndex（用于登出）
function Get-UserIndex {
    try {
        $tmp = Join-Path $env:TEMP ("campus_ui_" + [guid]::NewGuid().ToString("N") + ".tmp")
        & curl.exe -s -i -m 10 -A $ua -o $tmp "$portalUrl/eportal/redirectortosuccess.jsp" 2>$null
        $raw = ""
        if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding Default }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $m = [regex]::Match($raw, "userIndex=([0-9a-f_]+)")
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    } catch { }
    return $null
}

# 认证成功后从门户成功页提取实际运营商（网关确认的，不是配置里填的）
function Get-ActualOperator {
    try {
        $tmp = Join-Path $env:TEMP ("campus_op_" + [guid]::NewGuid().ToString("N") + ".tmp")
        & curl.exe -s -L -m 10 -A $ua -o $tmp "$portalUrl/eportal/redirectortosuccess.jsp" 2>$null
        $raw = ""
        if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding Default }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $ops = @("校园内网", "中国移动", "中国联通", "中国电信")
        foreach ($op in $ops) {
            if ($raw -match [regex]::Escape($op)) { return $op }
        }
    } catch { }
    return $null
}

# 获取本次连接的最新认证参数 queryString
function Get-FreshQueryString {
    try {
        # 未认证时访问门户根路径，跟随完整重定向链，从 302 Location 中找 index.jsp?<参数>
        # （未认证时第一次 302 可能是 redirectortosuccess，跟随后才到 index.jsp）
        $tmp = Join-Path $env:TEMP ("campus_qs_" + [guid]::NewGuid().ToString("N") + ".tmp")
        & curl.exe -s -L -i -m 12 -A $ua -o $tmp "$portalUrl/" 2>$null
        $raw = ""
        if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding Default }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $locs = [regex]::Matches($raw, "Location:\s*([^\r\n]+)")
        foreach ($loc in $locs) {
            $m = [regex]::Match($loc.Groups[1].Value, "index\.jsp\?([^\r\n]+)")
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        }
        # 兜底：直接访问 index.jsp
        $tmp2 = Join-Path $env:TEMP ("campus_qs2_" + [guid]::NewGuid().ToString("N") + ".tmp")
        & curl.exe -s -i -m 12 -A $ua -o $tmp2 "$portalUrl/eportal/index.jsp" 2>$null
        $raw2 = ""
        if (Test-Path $tmp2) { $raw2 = Get-Content $tmp2 -Raw -Encoding Default }
        Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue
        $m2 = [regex]::Match($raw2, "index\.jsp\?([^\r\n""' ]+)")
        if ($m2.Success) { return $m2.Groups[1].Value.Trim() }
        # 兜底2：已在线/会话保留时，参数在 redirectortosuccess.jsp 页面内容里
        # （它包含跳转到 index.jsp?<完整参数> 的 JS 脚本）
        $tmp3 = Join-Path $env:TEMP ("campus_qs3_" + [guid]::NewGuid().ToString("N") + ".tmp")
        & curl.exe -s -L -m 12 -A $ua -o $tmp3 "$portalUrl/eportal/redirectortosuccess.jsp" 2>$null
        $raw3 = ""
        if (Test-Path $tmp3) { $raw3 = Get-Content $tmp3 -Raw -Encoding Default }
        Remove-Item $tmp3 -Force -ErrorAction SilentlyContinue
        $m3 = [regex]::Match($raw3, "index\.jsp\?([^\r\n""' ]+)")
        if ($m3.Success) { return $m3.Groups[1].Value.Trim() }
    } catch { }
    return $null
}

# 提交登录请求，返回 @{result; message}
function Invoke-Login {
    param([string]$Qs)
    $password = Get-PlainPassword
    $svc = if ($service) { $service } else { "（未指定，使用网关默认）" }
    Write-Log "登录账号：$username  运营商：$svc"
    $body = "userId=" + (ConvertTo-DoubleUrlEncode $username) +
            "&password=" + (ConvertTo-DoubleUrlEncode $password) +
            "&service=" + (ConvertTo-DoubleUrlEncode $service) +
            "&queryString=" + (ConvertTo-DoubleUrlEncode $Qs) +
            "&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"
    $tmp = Join-Path $env:TEMP ("campus_login_" + [guid]::NewGuid().ToString("N") + ".tmp")
    & curl.exe -s -m 15 -A $ua -e "$portalUrl/eportal/index.jsp" -d $body -o $tmp "$portalUrl/eportal/InterFace.do?method=login" 2>$null
    $resp = ""
    if (Test-Path $tmp) { $resp = Get-Content $tmp -Raw -Encoding UTF8 }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if (-not $resp) { return @{ result = "fail"; message = "接口无响应" } }
    try {
        $j = $resp | ConvertFrom-Json
        return @{ result = [string]$j.result; message = [string]$j.message }
    } catch {
        return @{ result = "fail"; message = "响应解析失败" }
    }
}

# 快速外网连通测试（门户显示已认证 ≠ 真的能上网，需要双确认）
function Test-Internet {
    try {
        $tmp = Join-Path $env:TEMP ("campus_net_" + [guid]::NewGuid().ToString("N") + ".tmp")
        $code = & curl.exe -s -m 8 -o $tmp -w "%{http_code}" "http://www.baidu.com" 2>$null
        $size = 0
        if (Test-Path $tmp) { $size = (Get-Item $tmp).Length; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        $ok = ($code -match "200|301|302|304" -and $size -gt 0)
        return @{ Ok = $ok; Code = $code; Size = $size; Error = $null }
    } catch {
        return @{ Ok = $false; Code = "0"; Size = 0; Error = $_.Exception.Message }
    }
}

# 等待网络就绪（门户可达），返回状态
# 等待期间一旦检测到连接被切换到其他网络（非目标 WiFi），立即静默退出，不采取任何行动
function Wait-ForNetwork {
    $deadline = (Get-Date).AddSeconds($maxWaitSec)
    while ((Get-Date) -lt $deadline) {
        $cur = Get-CurrentSsid
        if (-not (Test-TargetWifi $cur)) {
            Write-Log "检测到当前连接已切换为 '$cur'，不再采取操作。"
            exit 0
        }
        $st = Get-PortalState
        if ($st -ne "unreachable") { return $st }
        Start-Sleep -Seconds 6
    }
    return "unreachable"
}

# ---------- 主流程 ----------
Write-Log "===== 校园网自动认证开始 ====="
Write-Log "目标 WiFi：$expectSsid  运营商：$(if ($service) { $service } else { '未指定' })"

# ---- 阶段1：判断当前网络状态 ----
# 核心原则：只要电脑能上网（任何网络）就不抢网、不动作；
#           只有完全没有网络（或当前连接无法上网）时才尝试自动连接校园网并认证
$cur = Get-CurrentSsid

if ($cur -and (Test-TargetWifi $cur)) {
    # 已连接目标 WiFi → 进入认证流程（已在线则跳过，未认证则认证）
    $bandInfo = ""
    try {
        $netshOut = Invoke-NetshUtf8 wlan show interfaces
        if ($netshOut -match "Band\s*:\s*(.+)") {
            $b = $Matches[1].Trim()
            if ($b -match "5") { $bandInfo = "5GHz" } elseif ($b -match "2\.4") { $bandInfo = "2.4GHz" }
        }
        if (-not $bandInfo -and $netshOut -match "Channel\s*:\s*(\d+)") {
            $ch = [int]$Matches[1]
            $bandInfo = if ($ch -ge 36) { "5GHz" } else { "2.4GHz" }
        }
        if ($bandInfo -and $netshOut -match "Signal\s*:\s*(\d+)%") {
            $bandInfo = "$bandInfo 信号$($Matches[1])%"
        }
    } catch { }
    if ($bandInfo) { Write-Log "已连接目标 WiFi '$cur'（实际频段：$bandInfo）。" }
    else { Write-Log "已连接目标 WiFi '$cur'。" }
} else {
    # 未连接目标 WiFi：检查当前是否已有可用网络
    $conn = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4Connectivity -and $_.IPv4Connectivity -ne "Disconnected" } |
        Select-Object -First 1
    if ($conn -and $conn.IPv4Connectivity -eq "Internet") {
        Write-Log "已连接网络 '$($conn.Name)'，当前可正常上网，无需操作（不抢网）。"
        exit 0
    }
    # 没有可用网络（或当前连接无法上网）→ 尝试自动连接目标 WiFi
    if (Test-OffHours) {
        $hint = if ($offDays -eq "12345") { "（仅工作日）" } else { "" }
        Write-Log "当前处于校园网不可用时段 $offHours $hint，本次不采取任何操作。"
        exit 0
    }
    $maxScan  = 3
    $scanWait = 30
    $found = $false
    for ($i = 1; $i -le $maxScan; $i++) {
        if ($cur) { Write-Log "第 $i 次尝试：当前连接 '$cur' 无法上网，正在尝试自动连接 '$expectSsid'..." }
        else      { Write-Log "第 $i 次尝试：当前未连接任何网络，正在尝试自动连接 '$expectSsid'..." }
        if (Connect-TargetWifi) {
            Start-Sleep -Seconds 10
            $cur2 = Get-CurrentSsid
            if (Test-TargetWifi $cur2) {
                Write-Log "已自动连接到目标 WiFi '$cur2'。"
                $found = $true
                break
            }
            Write-Log "连接请求已发出，但尚未连上目标 WiFi。"
        }
        if ($i -lt $maxScan) { Write-Log "$scanWait 秒后重试..."; Start-Sleep -Seconds $scanWait }
        $cur = Get-CurrentSsid
    }
    if (-not $found) {
        Write-Log "未能连接到目标 WiFi '$expectSsid'（共尝试 $maxScan 次），本次不采取任何操作。"
        exit 0
    }
}

# ---- 阶段2：等待门户可达并认证 ----
$state = Wait-ForNetwork
if ($state -eq "unreachable") {
    Write-Log "登录网址 $portalUrl 不可达（网络未就绪），本次跳过。"
    exit 0
}
if ($state -eq "online" -and -not $ForceLogin) {
    $net = Test-Internet
    if ($net.Ok) {
        Write-Log "外网验证：已连接上外网（baidu.com 返回 HTTP $($net.Code)，页面内容 $($net.Size) 字节）"
        Write-Log "已在线，无需认证。"
        exit 0
    } else {
        $errMsg = if ($net.Error) { "请求异常：$($net.Error)" } else { "baidu.com 返回 HTTP $($net.Code)，内容 $($net.Size) 字节" }
        Write-Log "外网验证：未连接上外网（$errMsg）"
    }
    # 门户显示已认证但外网不通（可能会话被挤下线/运营商未放行）
    # 此时门户不返回登录页参数，需先自动登出，再走正常认证流程
    Write-Log "门户显示已在线但外网不通，先自动登出再重新认证..."
    $ui = Get-UserIndex
    if ($ui) {
        & curl.exe -s -m 8 -o NUL "$portalUrl/eportal/InterFace.do?method=logout&userIndex=$ui" 2>$null
        Start-Sleep -Seconds 2
        Write-Log "已执行登出（userIndex 已获取），准备重新认证。"
    } else {
        Write-Log "未获取到 userIndex，直接尝试重新认证。"
    }
    $state = "login"
}

# 提交前再次确认仍连接目标 WiFi（用户可能已切换网络）
$cur = Get-CurrentSsid
if (-not (Test-TargetWifi $cur)) {
    Write-Log "检测到当前连接已切换为 '$cur'，不再执行认证。"
    exit 0
}

Write-Log "检测到需要认证，正在获取认证参数..."
$qs = Get-FreshQueryString
if (-not $qs) {
    Write-Log "未能获取认证参数（queryString），本次跳过。"
    exit 1
}
Write-Log "已获取认证参数（长度 $($qs.Length)）。"

$ok = $false
for ($i = 1; $i -le $retryTimes; $i++) {
    # 每次提交登录前都确认仍连接目标 WiFi（用户切换网络则静默放弃）
    $cur = Get-CurrentSsid
    if (-not (Test-TargetWifi $cur)) {
        Write-Log "提交前检测到连接已切换为 '$cur'，取消认证。"
        exit 0
    }
    try {
        $r = Invoke-Login -Qs $qs
        Write-Log "登录请求第 $i 次：result=$($r.result) message=$($r.message)"
        if ($r.result -eq "success") { $ok = $true; break }
    } catch {
        Write-Log "登录请求第 $i 次异常：$($_.Exception.Message)"
    }
    Start-Sleep -Seconds 8
}

if ($ok) {
    Start-Sleep -Seconds 3
    # 验证前确认仍连接目标 WiFi
    $cur = Get-CurrentSsid
    if (-not (Test-TargetWifi $cur)) {
        Write-Log "验证前检测到连接已切换为 '$cur'，本次结束。"
        exit 0
    }
    $final = Get-PortalState
    if ($final -eq "online") {
        Write-Log "验证通过：校园网认证成功，已恢复上网。"
        $actualOp = Get-ActualOperator
        if ($actualOp) {
            Write-Log "实际认证运营商：$actualOp（配置值：$(if ($service) { $service } else { '未指定' })）"
        } else {
            Write-Log "实际认证运营商：未能从成功页获取（配置值：$(if ($service) { $service } else { '未指定' })）"
        }
        $net = Test-Internet
        if ($net.Ok) {
            Write-Log "外网验证：已连接上外网（baidu.com 返回 HTTP $($net.Code)，页面内容 $($net.Size) 字节）"
        } else {
            Write-Log "外网验证：未连接上外网（HTTP $($net.Code)，内容 $($net.Size) 字节）"
        }
        exit 0
    } else {
        Write-Log "提示：接口返回成功但未检测到在线，可能需绑定运营商服务，请打开浏览器确认。"
        exit 1
    }
} else {
    Write-Log "多次认证失败，请检查账号密码是否正确（打开 校园网自动认证配置工具.exe 重新配置），或查看浏览器登录页提示。"
    exit 1
}
