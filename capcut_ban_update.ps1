#Requires -Version 5.1
<#
    capcut_ban_update.ps1  ——  CapCut / 剪映国际版：关闭自动更新并禁止 update.exe 执行

    设计原则：
      1) 不删除任何文件。删掉 update.exe 会让启动器找不到它，程序直接不显示界面。
      2) 只给 update.exe 追加一条 Deny ExecuteFile ACE，文件保留、程序照常启动。
      3) 配置里的四个更新开关写 false + 文件设只读（防止程序自己改回去）。
      4) 修正 Configure.ini 的 last_version，不给启动器“目标版本不存在”的口子。
      5) 防火墙只按程序封，绝不按域名封（域名封会把字幕识别、素材一起打死）。

    用法：双击同目录的 capcut_ban_update.bat（会自己请求管理员权限）。
#>

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function Say($s) { $script:lines.Add([string]$s) }
$reportPath = Join-Path $env:TEMP 'capcut_ban_update_report.txt'

Say '================ CapCut 禁止更新 ================'

# ---------- 0. 权限 ----------
$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
Say ('管理员权限：' + $(if ($isAdmin) { '是' } else { '否（防火墙规则会跳过，ACL 与配置照常生效）' }))

# ---------- 1. 定位安装目录 ----------
$candidates = New-Object System.Collections.Generic.List[string]
foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    try {
        Get-ItemProperty $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'CapCut|Jianying|剪映' } |
            ForEach-Object {
                if ($_.InstallLocation) { $candidates.Add($_.InstallLocation.TrimEnd('\')) }
                elseif ($_.DisplayIcon) { $candidates.Add((Split-Path ($_.DisplayIcon.Trim('"')) -Parent)) }
            }
    } catch {}
}
foreach ($p in @('D:\CapCut\CapCut', 'D:\CapCut', 'C:\Program Files\CapCut', 'C:\Program Files (x86)\CapCut', "$env:LOCALAPPDATA\CapCut")) {
    if (Test-Path -LiteralPath $p) { $candidates.Add($p) }
}

$roots = New-Object System.Collections.Generic.List[string]
foreach ($c in $candidates) {
    try { $c = [IO.Path]::GetFullPath($c).TrimEnd('\') } catch { continue }
    $sub = Join-Path $c 'CapCut'
    if (Test-Path -LiteralPath $sub) { if (-not $roots.Contains($sub)) { $roots.Add($sub) } }
    elseif (Test-Path -LiteralPath $c) { if (-not $roots.Contains($c)) { $roots.Add($c) } }
}
Say ('安装目录：' + ($roots -join ' | '))

# ---------- 2. 收集 update.exe（只看一级版本子目录，不做全树递归） ----------
$updaters = New-Object System.Collections.Generic.List[string]
foreach ($r in $roots) {
    $direct = Join-Path $r 'update.exe'
    if (Test-Path -LiteralPath $direct) { $updaters.Add($direct) }
    try {
        foreach ($d in [IO.Directory]::EnumerateDirectories($r)) {
            $u = Join-Path $d 'update.exe'
            if (Test-Path -LiteralPath $u) { if (-not $updaters.Contains($u)) { $updaters.Add($u) } }
        }
    } catch {}
}
Say ('发现 update.exe：' + $updaters.Count + ' 个')
foreach ($u in $updaters) { Say ('  ' + $u) }

# ---------- 3. 加 Deny ExecuteFile（幂等） ----------
$sid = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
foreach ($u in $updaters) {
    try {
        $acl = Get-Acl -LiteralPath $u
        foreach ($a in @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.FileSystemRights -match 'Execute|Traverse' })) {
            [void]$acl.RemoveAccessRule($a)
        }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::ExecuteFile, 'Deny')
        [void]$acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $u -AclObject $acl
        $n = @((Get-Acl -LiteralPath $u).Access | Where-Object { $_.AccessControlType -eq 'Deny' }).Count
        Say ('  [OK] 已禁止执行 update.exe，Deny=' + $n + '  (' + $u + ')')
    } catch {
        Say ('  [FAIL] ' + $u + ' => ' + $_.Exception.Message)
    }
}

# ---------- 4. 配置开关写 false + 只读 ----------
$cfgList = New-Object System.Collections.Generic.List[string]
$appCfg = Join-Path $env:LOCALAPPDATA 'CapCut\User Data\Config\globalSetting'
if (Test-Path -LiteralPath $appCfg) { $cfgList.Add($appCfg) }
foreach ($r in $roots) {
    $g = Join-Path $r 'globalSetting'
    if (Test-Path -LiteralPath $g) { if (-not $cfgList.Contains($g)) { $cfgList.Add($g) } }
}
$map = [ordered]@{
    'enableAutoUpdate'         = 'false'
    'totalSilentUpgradeSwitch' = 'false'
    'debugSilentUpgradeSwitch' = 'false'
    'upgradeIntervalMin'       = '99999999999'
}
foreach ($cfg in $cfgList) {
    try {
        (Get-Item -LiteralPath $cfg).IsReadOnly = $false
        $t = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
        foreach ($k in $map.Keys) {
            $pat = '(?m)^' + [regex]::Escape($k) + '\s*=\s*.*$'
            if ($t -match $pat) { $t = [regex]::Replace($t, $pat, ($k + '=' + $map[$k])) }
            else { $t = $t.TrimEnd() + "`r`n" + $k + '=' + $map[$k] + "`r`n" }
        }
        [IO.File]::WriteAllText($cfg, $t, (New-Object Text.UTF8Encoding $false))
        (Get-Item -LiteralPath $cfg).IsReadOnly = $true
        Say ('  [OK] 已关闭更新开关并设为只读：' + $cfg)
        foreach ($k in $map.Keys) {
            $v = [regex]::Match([IO.File]::ReadAllText($cfg), '(?m)^' + [regex]::Escape($k) + '\s*=\s*(.*)$').Groups[1].Value.Trim()
            Say ('        ' + $k + ' = ' + $v)
        }
    } catch {
        Say ('  [FAIL] ' + $cfg + ' => ' + $_.Exception.Message)
    }
}

# ---------- 5. Configure.ini 指向现存最新版本 ----------
foreach ($r in $roots) {
    $ci = Join-Path $r 'Configure.ini'
    if (-not (Test-Path -LiteralPath $ci)) { continue }
    try {
        $vers = @([IO.Directory]::EnumerateDirectories($r) |
            ForEach-Object { Split-Path $_ -Leaf } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+' -and (Test-Path (Join-Path (Join-Path $r $_) 'CapCut.exe')) })
        if ($vers.Count -eq 0) { Say ('  [SKIP] ' + $r + ' 没有可用版本目录'); continue }
        $pick = $vers | Sort-Object -Descending | Select-Object -First 1
        [IO.File]::WriteAllText($ci, "[capcut]`r`nlast_version=$pick`r`n", (New-Object Text.UTF8Encoding $false))
        Say ('  [OK] Configure.ini last_version -> ' + $pick)
    } catch {
        Say ('  [FAIL] Configure.ini => ' + $_.Exception.Message)
    }
}

# ---------- 6. 防火墙：按程序，不按域名 ----------
if ($isAdmin -and $updaters.Count -gt 0) {
    $name = 'Block_CapCut_Update'
    try { & "$env:WINDIR\System32\netsh.exe" advfirewall firewall delete rule name="$name" | Out-Null } catch {}
    foreach ($u in $updaters) {
        try {
            & "$env:WINDIR\System32\netsh.exe" advfirewall firewall add rule name="$name" dir=out action=block program="$u" enable=yes profile=any | Out-Null
            Say ('  [OK] 防火墙出站阻止：' + $u)
        } catch {
            Say ('  [FAIL] 防火墙规则 => ' + $_.Exception.Message)
        }
    }
} elseif (-not $isAdmin) {
    Say '  [SKIP] 非管理员：防火墙规则未添加（Deny ACE 已经挡住静默安装）'
}

# ---------- 7. 校验 ----------
Say ''
Say '================ 校验 ================'
foreach ($u in $updaters) {
    $d = @((Get-Acl -LiteralPath $u).Access | Where-Object { $_.AccessControlType -eq 'Deny' }).Count
    Say ('  Deny=' + $d + '  ' + $u)
}
foreach ($r in $roots) {
    Say ('  版本目录 ' + $r + ': ' + ((@([IO.Directory]::EnumerateDirectories($r) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))
}
Say ''
Say '完成。验证方式：正常启动 CapCut，能进界面即说明没被改坏。'

try { [IO.File]::WriteAllText($reportPath, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding $false)) } catch {}
$lines -join "`r`n"
Write-Host ''
Write-Host ('报告：' + $reportPath)
