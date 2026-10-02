<#
.SYNOPSIS
    Менеджер IPBan (DigitalRuby) для Windows: установка, обновление, удаление, настройки.

.DESCRIPTION
    Без параметров — интерактивное меню.
    С параметром -Action — неинтерактивный режим (для автоматизации/развёртывания):
        Install   — установить и применить сохранённые настройки
        Update    — обновить до последнего релиза, настройки сохраняются
        Uninstall — удалить (служба, правила брандмауэра, каталог)
        Apply     — применить сохранённые настройки к ipban.config и перезапустить
        Status    — вывести состояние

    Настройки менеджера хранятся отдельно от ipban.config:
        %ProgramData%\IPBanManager\settings.json
    поэтому переживают обновление IPBan и применяются заново после него.

    Белый список собирается из трёх источников:
        1) loopback;
        2) автоматически обнаруженные ЧАСТНЫЕ подсети интерфейсов (RFC1918, CGNAT) —
           публичные интерфейсы добавляются только своим адресом /32, а не подсетью,
           чтобы не открыть соседей по хостингу;
        3) ручной список (админские IP, офисы, VPN): IP, подсети, доменные имена
           и URL текстовых списков адресов — имена и URL IPBan перечитывает раз в 5 минут.
    Плюс по запросу — адреса клиентов активных RDP-сессий с вошедшим пользователем (чтобы не забанить себя);
    просто открытые соединения на порт RDP не берутся — среди них боты, подбирающие пароль.

.EXAMPLE
    .\IPBan-Manager.ps1
    .\IPBan-Manager.ps1 -Action Install
    .\IPBan-Manager.ps1 -Action Update

.EXAMPLE
    Запуск без скачивания (PowerShell от имени администратора):
    irm https://imiron.ru/IPBanManager/ipban.txt | iex
    С параметром:
    iex "& {$(irm https://imiron.ru/IPBanManager/ipban.txt)} -Action Status"

.NOTES
    Файл хранится в UTF-8 БЕЗ BOM: iex не разбирает текст, начинающийся с BOM.
    Поэтому локально в Windows PowerShell 5.1 запускать так (иначе кириллица прочитается как ANSI):
    iex (Get-Content .\IPBan-Manager.ps1 -Raw -Encoding UTF8)
    В PowerShell 7 работает обычный .\IPBan-Manager.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Update','Uninstall','Apply','Status')]
    [string]$Action = 'Menu'
)

# Вместо #Requires: при запуске через irm | iex он не срабатывает.
# Скрипт не использует $script: — вне файла это глобальная область, а не скрипт.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Нужны права администратора: запустите PowerShell от имени администратора.'
}

# Тело — в дочерней области: iex выполняет код прямо в области консоли, и без этого
# $ErrorActionPreference = 'Stop' и все функции остались бы в сессии пользователя.
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ServiceName   = 'IPBAN'   # уточняется ниже, если IPBan стоит под другим именем
$ManagedKeys   = 'FailedLoginAttemptsBeforeBan','BanTime','ExpireTime','Whitelist','UseDefaultBannedIPAddressHandler'
$DefaultDir    = Join-Path $env:ProgramFiles 'IPBan'
$InstallerUrl  = 'https://raw.githubusercontent.com/DigitalRuby/IPBan/master/IPBanCore/Windows/Scripts/install_latest.ps1'
$ReleaseApi    = 'https://api.github.com/repos/DigitalRuby/IPBan/releases/latest'
$AuditLogonGuid = '{0CCE9215-69AE-11D9-BED3-505054503030}'   # подкатегория «Вход в систему»
$StateDir      = Join-Path $env:ProgramData 'IPBanManager'
$SettingsPath  = Join-Path $StateDir 'settings.json'

#region ── Вывод ─────────────────────────────────────────────────────────────
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[!] $m"  -ForegroundColor Yellow }
function Pause-Menu     { [void](Read-Host "`nEnter — продолжить") }
function Confirm-Yes($q) { (Read-Host "$q [y/N]") -match '^(y|д|yes|да)$' }

# Вывод в колонки по ширине окна, сверху вниз. $Items — строки или @{ Text = ...; Color = ... }.
function Write-Columns($Items, [int]$Indent = 8) {
    $Items = @($Items | Where-Object { $_ })
    if (-not $Items) { return }
    $texts = @($Items | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Text } })
    $w = 3 + ($texts | Measure-Object -Property Length -Maximum).Maximum
    $win = 0; try { $win = $Host.UI.RawUI.WindowSize.Width } catch {}
    if ($win -lt 40) { $win = 100 }   # ISE, перенаправленный вывод
    $cols = [int][Math]::Max(1, [Math]::Floor(($win - $Indent - 1) / $w))
    $rows = [int][Math]::Ceiling($Items.Count / $cols)
    for ($r = 0; $r -lt $rows; $r++) {
        Write-Host (' ' * $Indent) -NoNewline
        for ($c = 0; $c -lt $cols; $c++) {
            $i = $c * $rows + $r
            if ($i -ge $Items.Count) { break }
            $color = if ($Items[$i] -is [string]) { 'Gray' } else { $Items[$i].Color }
            Write-Host $texts[$i].PadRight($w) -NoNewline -ForegroundColor $color
        }
        Write-Host ''
    }
}

# Меню со стрелками: ↑/↓, Home/End — выбор, Enter — выполнить, цифра — сразу пункт, Esc — пункт «0».
# $Items — массив пар @('ключ','текст'); пара с пустым ключом — разделитель. Возвращает ключ.
# Без настоящей консоли (ISE, Enter-PSSession, перенаправленный ввод) — ввод номера, как раньше.
function Select-Menu($Items, [string]$Default) {
    $keys = @($Items | ForEach-Object { $_[0] })
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) {
        foreach ($it in $Items) { Write-Host $(if ($it[0]) { "  $($it[0])) $($it[1])" } else { "  $($it[1])" }) }
        return Read-Host "`nВыбор"
    }
    $sel = @(for ($i = 0; $i -lt $keys.Count; $i++) { if ($keys[$i]) { $i } })
    $pos = [array]::IndexOf($keys, $Default)
    if ($pos -lt 0 -or -not $keys[$pos]) { $pos = $sel[0] }
    $width = 4 + ($Items | ForEach-Object { "$($_[0])) $($_[1])".Length } | Measure-Object -Maximum).Maximum
    $draw = {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $k, $t = $Items[$i]
            if (-not $k)         { Write-Host "    $t".PadRight($width) -ForegroundColor DarkGray }
            elseif ($i -eq $pos) { Write-Host "  > $k) $t".PadRight($width) -ForegroundColor Black -BackgroundColor Cyan }
            else                 { Write-Host "    $k) $t".PadRight($width) }
        }
        Write-Host "`n  ↑↓ — выбор, Enter — выполнить, цифра — сразу пункт, Esc — назад" -ForegroundColor DarkGray
    }
    Write-Host ''
    & $draw
    $top = [Console]::CursorTop - $Items.Count - 2   # считаем после вывода: экран мог прокрутиться
    $cursor = $null
    try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            $n = [array]::IndexOf($sel, $pos)
            switch ($key.Key) {
                'UpArrow'   { $pos = $sel[($n - 1 + $sel.Count) % $sel.Count] }
                'DownArrow' { $pos = $sel[($n + 1) % $sel.Count] }
                'Home'      { $pos = $sel[0] }
                'End'       { $pos = $sel[-1] }
                'Enter'     { return $keys[$pos] }
                'Escape'    { return '0' }
                default     { if ($keys -contains [string]$key.KeyChar) { return [string]$key.KeyChar } }
            }
            [Console]::SetCursorPosition(0, [Math]::Max(0, $top))
            & $draw
        }
    } finally {
        if ($null -ne $cursor) { try { [Console]::CursorVisible = $cursor } catch {} }
    }
}
#endregion

#region ── Настройки менеджера ───────────────────────────────────────────────
function Get-DefaultSettings {
    [pscustomobject]@{
        Attempts        = 5
        BanTime         = '01:00:00:00'   # DD:HH:MM:SS
        ExpireTime      = '01:00:00:00'
        ShareBannedIPs  = $false
        AutoNetworks    = $true           # добавлять обнаруженные частные подсети
        IncludeRdpPeers = $true           # добавлять адреса активных RDP-сессий при применении
        ExtraWhitelist  = @()             # ручной список IP/CIDR
        Origin          = 'ours'          # ours — ставили мы; adopted — нашли готовую установку и импортировали
        AdoptedAt       = $null
    }
}

function Load-Settings {
    $d = Get-DefaultSettings
    if (Test-Path $SettingsPath) {
        $s = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $d.PSObject.Properties.Name) {
            if ($null -ne $s.$p) { $d.$p = $s.$p }
        }
        $d.ExtraWhitelist = @($d.ExtraWhitelist | Where-Object { $_ })
    }
    $d
}

function Save-Settings($s) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }
    $s | ConvertTo-Json -Depth 4 | Set-Content $SettingsPath -Encoding UTF8
    Write-Ok "Настройки сохранены: $SettingsPath"
}
#endregion

#region ── Сети ──────────────────────────────────────────────────────────────
function ConvertTo-UInt32([string]$ip) {
    $b = [Net.IPAddress]::Parse($ip).GetAddressBytes(); [Array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
}
function ConvertFrom-UInt32([uint32]$n) {
    $b = [BitConverter]::GetBytes($n); [Array]::Reverse($b)
    ([Net.IPAddress]::new($b)).ToString()
}
# Маска через арифметику: литерал 0xFFFFFFFF в PowerShell — это int32 -1, сдвиги на нём врут.
function Get-Mask([int]$prefix) { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix)) }
function Get-NetworkCidr([string]$ip, [int]$prefix) {
    $mask = Get-Mask $prefix
    $net  = [uint32]((ConvertTo-UInt32 $ip) -band $mask)
    "{0}/{1}" -f (ConvertFrom-UInt32 $net), $prefix
}
function Test-PrivateIPv4([string]$ip) {
    $n = ConvertTo-UInt32 $ip
    $ranges = @(
        @('10.0.0.0',    8),   # RFC1918
        @('172.16.0.0',  12),  # RFC1918
        @('192.168.0.0', 16),  # RFC1918
        @('100.64.0.0',  10)   # CGNAT
    )
    foreach ($r in $ranges) {
        $mask = Get-Mask $r[1]
        if (($n -band $mask) -eq ((ConvertTo-UInt32 $r[0]) -band $mask)) { return $true }
    }
    $false
}

# Обнаружение сетей на интерфейсах. Возвращает объекты с пояснением.
function Get-LocalNetworks {
    $result = @()
    $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
    foreach ($a in $addrs) {
        $alias = $a.InterfaceAlias
        if (Test-PrivateIPv4 $a.IPAddress) {
            $result += [pscustomobject]@{
                Entry = Get-NetworkCidr $a.IPAddress $a.PrefixLength
                Type  = 'частная подсеть'
                From  = "$alias ($($a.IPAddress)/$($a.PrefixLength))"
            }
        } else {
            $result += [pscustomobject]@{
                Entry = "$($a.IPAddress)/32"
                Type  = 'публичный адрес (только сам хост)'
                From  = "$alias (подсеть /$($a.PrefixLength) НЕ добавляется)"
            }
        }
    }
    $result | Sort-Object Entry -Unique
}

# Клиенты активных RDP-сессий через WTS API. Установленные TCP-соединения на порт RDP брать нельзя:
# среди них боты, подбирающие пароль, — они попали бы в белый список (а это разрешающее правило брандмауэра).
$RdpSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace IPBanManager
{
    public static class Rdp
    {
        [StructLayout(LayoutKind.Sequential)]
        struct WTS_SESSION_INFO { public int SessionId; public IntPtr WinStationName; public int State; }

        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr info, out int count);
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr memory);

        const int WTSActive = 0, WTSUserName = 5, WTSDomainName = 7, WTSClientAddress = 14, AF_INET = 2;

        // "ip|DOMAIN\user" for every active session with a logged-on user and an IPv4 client address
        public static string[] ActiveClients()
        {
            List<string> result = new List<string>();
            IntPtr info; int count;
            if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out info, out count)) return result.ToArray();
            try
            {
                int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                for (int i = 0; i < count; i++)
                {
                    WTS_SESSION_INFO s = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(info.ToInt64() + (long)i * size), typeof(WTS_SESSION_INFO));
                    if (s.State != WTSActive) continue;
                    string user = Query(s.SessionId, WTSUserName);
                    if (String.IsNullOrEmpty(user)) continue;
                    IntPtr buf; int bytes;
                    if (!WTSQuerySessionInformation(IntPtr.Zero, s.SessionId, WTSClientAddress, out buf, out bytes)) continue;
                    try
                    {
                        // WTS_CLIENT_ADDRESS: DWORD AddressFamily; BYTE Address[20]; IPv4 is in Address[2..5]
                        if (Marshal.ReadInt32(buf) != AF_INET) continue;
                        string ip = String.Format("{0}.{1}.{2}.{3}", Marshal.ReadByte(buf, 6), Marshal.ReadByte(buf, 7), Marshal.ReadByte(buf, 8), Marshal.ReadByte(buf, 9));
                        string domain = Query(s.SessionId, WTSDomainName);
                        result.Add(ip + "|" + (String.IsNullOrEmpty(domain) ? user : domain + "\\" + user));
                    }
                    finally { WTSFreeMemory(buf); }
                }
            }
            finally { WTSFreeMemory(info); }
            return result.ToArray();
        }

        static string Query(int sessionId, int infoClass)
        {
            IntPtr buf; int bytes;
            if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, infoClass, out buf, out bytes)) return null;
            try { return Marshal.PtrToStringUni(buf); }
            finally { WTSFreeMemory(buf); }
        }
    }
}
'@

# Кто сейчас работает по RDP (вошедшие пользователи) — чтобы не забанить администратора.
function Get-RdpPeers {
    try {
        if (-not ('IPBanManager.Rdp' -as [type])) { Add-Type -TypeDefinition $RdpSource -ErrorAction Stop }
        foreach ($c in [IPBanManager.Rdp]::ActiveClients()) {
            $ip, $user = $c -split '\|', 2
            [pscustomobject]@{ Address = $ip; User = $user }
        }
    } catch { Write-Warn "Не удалось получить RDP-сессии: $($_.Exception.Message)" }
}

# Итоговый белый список с источником каждой записи; у дублей остаётся первый источник.
function Get-WhitelistEntries($s) {
    $list = @()
    # Для импортированной установки loopback не навязываем — он уже в списке, если был.
    if ($s.Origin -ne 'adopted') { $list += '127.0.0.1', '::1' | ForEach-Object { [pscustomobject]@{ Entry = $_; Source = 'loopback'; Note = $null } } }
    if ($s.AutoNetworks)    { $list += Get-LocalNetworks | ForEach-Object { [pscustomobject]@{ Entry = $_.Entry; Source = 'сети интерфейсов'; Note = $null } } }
    if ($s.IncludeRdpPeers) { $list += Get-RdpPeers | ForEach-Object { [pscustomobject]@{ Entry = $_.Address; Source = 'RDP-сессии'; Note = $_.User } } }
    $list += $s.ExtraWhitelist | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Entry = $_; Source = 'ручной список'; Note = $null } }
    $seen = @{}
    foreach ($e in $list) {
        if (-not $e -or $seen.ContainsKey($e.Entry)) { continue }
        $seen[$e.Entry] = $true
        $e
    }
}

# Белый список: что добавится (+), уйдёт (-), останется (=) — по источникам, колонками.
function Show-WhitelistDiff([string]$OldValue, $Entries) {
    $old = @(($OldValue -split '[,;\s]+') | Where-Object { $_ })
    $new = @($Entries | ForEach-Object { $_.Entry })
    $add = @($new | Where-Object { $_ -notin $old })
    $del = @($old | Where-Object { $_ -notin $new })
    Write-Host ("    Белый список: сейчас {0}, станет {1}  (+{2} / -{3})" -f $old.Count, $new.Count, $add.Count, $del.Count) -ForegroundColor White
    foreach ($src in 'loopback', 'сети интерфейсов', 'RDP-сессии', 'ручной список') {
        $group = @($Entries | Where-Object { $_.Source -eq $src })
        if (-not $group) { continue }
        Write-Host "      $src" -ForegroundColor DarkCyan
        Write-Columns @($group | ForEach-Object {
            $t = if ($_.Note) { "$($_.Entry) ($($_.Note))" } else { $_.Entry }
            if ($_.Entry -in $old) { @{ Text = "= $t"; Color = 'Gray' } } else { @{ Text = "+ $t"; Color = 'Green' } }
        })
    }
    if ($del) {
        Write-Host "      уйдут из списка" -ForegroundColor DarkCyan
        Write-Columns @($del | ForEach-Object { @{ Text = "- $_"; Color = 'Red' } })
    }
    Write-Host "      + добавится   - уйдёт   = останется" -ForegroundColor DarkGray
}
#endregion

#region ── IPBan: пути, версия, состояние ─────────────────────────────────────
function Get-IPBanService { Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue }

# Путь к exe из PathName службы. Учитываем, что путь может быть БЕЗ кавычек и с пробелами
# (C:\Program Files\IPBan\DigitalRuby.IPBan.exe) — делить по пробелу нельзя.
function Split-ServicePath([string]$raw) {
    $raw = $raw.Trim()
    if ($raw -match '^"([^"]+)"(.*)$')       { return @{ Exe = $Matches[1]; Args = $Matches[2]; Quoted = $true } }
    if ($raw -match '^(.+?\.exe)(\s.*)?$')   { return @{ Exe = $Matches[1]; Args = [string]$Matches[2]; Quoted = $false } }
    @{ Exe = ($raw -split '\s')[0]; Args = ''; Quoted = $false }
}
function Get-IPBanExe {
    $svc = Get-IPBanService
    if (-not $svc) { return $null }
    (Split-ServicePath $svc.PathName).Exe
}
function Get-IPBanDir {
    $exe = Get-IPBanExe
    if ($exe -and (Test-Path $exe)) { Split-Path $exe -Parent } else { $DefaultDir }
}

# Путь службы с пробелами без кавычек — известная уязвимость (unquoted service path):
# Windows может запустить C:\Program.exe от имени SYSTEM. Чиним через ImagePath в реестре.
function Test-UnquotedServicePath {
    $svc = Get-IPBanService
    if (-not $svc) { return $false }
    $p = Split-ServicePath $svc.PathName
    (-not $p.Quoted) -and ($p.Exe -match '\s')
}
function Repair-ServicePath {
    if (-not (Test-UnquotedServicePath)) { return }
    $p = Split-ServicePath (Get-IPBanService).PathName
    $new = '"' + $p.Exe + '"' + $p.Args
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name ImagePath -Value $new
    Write-Ok "Путь службы взят в кавычки: $new"
}
# Ищем IPBan не только по имени IPBAN, но и по пути исполняемого файла службы.
# Возвращает имя службы или $null.
function Resolve-IPBanServiceName {
    $all = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue
    $hit = $all | Where-Object { $_.Name -eq 'IPBAN' } | Select-Object -First 1
    if (-not $hit) { $hit = $all | Where-Object { $_.PathName -match 'IPBan' } | Select-Object -First 1 }
    if ($hit) {
        if ($hit.Name -ne 'IPBAN') { Write-Warn "IPBan найден под нестандартным именем службы: $($hit.Name)" }
        $hit.Name
    }
}

# Основной конфиг: ipban.config, у старых версий — DigitalRuby.IPBan.dll.config
function Get-ConfigPath {
    $d = Get-IPBanDir
    foreach ($n in 'ipban.config', 'DigitalRuby.IPBan.dll.config') {
        $p = Join-Path $d $n; if (Test-Path $p) { return $p }
    }
    Join-Path $d 'ipban.config'
}
function Get-OverridePath { Join-Path (Get-IPBanDir) 'ipban.override.config' }

# Действующие значения наших ключей: основной конфиг, поверх — override, если он есть.
function Read-EffectiveValues {
    $h = [ordered]@{}
    foreach ($f in @((Get-ConfigPath), (Get-OverridePath))) {
        if (-not (Test-Path $f)) { continue }
        [xml]$x = Get-Content $f -Raw -Encoding UTF8
        foreach ($k in $ManagedKeys) {
            $n = $x.SelectSingleNode("//appSettings/add[@key='$k']")
            if ($n) { $h[$k] = $n.GetAttribute('value') }
        }
    }
    $h
}

function Test-ForeignInstall { (Get-Service $ServiceName -ErrorAction SilentlyContinue) -and -not (Test-Path $SettingsPath) }

# Берём настройки существующей установки как есть — ничего не расширяем.
function Import-ExistingSettings {
    $v = Read-EffectiveValues
    $s = Get-DefaultSettings
    if ($v.FailedLoginAttemptsBeforeBan -match '^\d+$') { $s.Attempts = [int]$v.FailedLoginAttemptsBeforeBan }
    if ($v.BanTime)    { $s.BanTime    = $v.BanTime }
    if ($v.ExpireTime) { $s.ExpireTime = $v.ExpireTime }
    $s.ShareBannedIPs  = ($v.UseDefaultBannedIPAddressHandler -eq 'true')
    $s.ExtraWhitelist  = @(($v.Whitelist -split '[,;\s]+') | Where-Object { $_ })   # как есть, включая loopback
    $s.AutoNetworks    = $false   # не расширяем чужой белый список молча
    $s.IncludeRdpPeers = $false
    $s.Origin          = 'adopted'
    $s.AdoptedAt       = (Get-Date).ToString('s')
    Write-Step "Импортированы настройки существующей установки IPBan"
    Write-Host "    Попыток: $($s.Attempts); бан: $($s.BanTime); сброс: $($s.ExpireTime); глоб. база: $($s.ShareBannedIPs)"
    Write-Host "    Белый список ($($s.ExtraWhitelist.Count)):"
    Write-Columns $s.ExtraWhitelist
    Write-Warn "Автоопределение сетей и RDP выключены, чтобы поведение не изменилось. Включить можно в Настройки → Белый список."
    Save-Settings $s
    $s
}

# Единая точка получения настроек: при чужой установке — сначала импорт.
function Get-Settings {
    if (Test-ForeignInstall) {
        Write-Warn "IPBan установлен не этим менеджером — настройки ещё не импортированы"
        return Import-ExistingSettings
    }
    Load-Settings
}

# Программы того же назначения — будут дублировать баны и мешать разбану.
function Get-Competitors {
    $re = 'RdpGuard|EvlWatcher|Syspeace|Cyberarms|wail2ban|fail2ban|RDPShield|BruteForceBlocker'
    $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $re -and $_.Name -ne $ServiceName } |
        ForEach-Object { "служба: $($_.DisplayName) [$($_.State)]" }
    $tsk = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { "$($_.TaskName) $(($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' ')" -match $re } |
        ForEach-Object { "задача: $($_.TaskPath)$($_.TaskName)" }
    @($svc) + @($tsk) | Where-Object { $_ }
}

function Get-InstalledVersion {
    $exe = Get-IPBanExe
    if ($exe -and (Test-Path $exe)) { (Get-Item $exe).VersionInfo.ProductVersion } else { $null }
}
function Get-LatestVersion {
    try { (Invoke-RestMethod $ReleaseApi -Headers @{ 'User-Agent' = 'IPBan-Manager' }).tag_name }
    catch { $null }
}
function Get-BannedIPs {
    Get-NetFirewallRule -DisplayName 'IPBan*Block*' -ErrorAction SilentlyContinue |
        Get-NetFirewallAddressFilter |
        ForEach-Object { $_.RemoteAddress } |
        Where-Object { $_ -and $_ -ne 'Any' } |
        Sort-Object { if ($_ -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)') { '0' + (@($Matches[1], $Matches[2], $Matches[3], $Matches[4] | ForEach-Object { $_.PadLeft(3, '0') }) -join '.') + $_ } else { "1$_" } } -Unique
}

function Show-Banned {
    $b = @(Get-BannedIPs)
    if (-not $b) { Write-Ok "Забаненных адресов нет"; return }
    Write-Step "Забанено адресов: $($b.Count)"
    Write-Columns $b 4
}

# Разбан через unban.txt: служба читает его каждый цикл (~15 с). Ждём, пока адреса пропадут из правил.
function Invoke-Unban {
    if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { Write-Warn "IPBan не установлен"; return }
    $banned = @(Get-BannedIPs)
    if ($banned.Count -le 60) { Show-Banned } else { Write-Host "Забанено адресов: $($banned.Count) — весь список в пункте «Забаненные адреса»" }
    $ips = @((Read-Host "`nIP для разбана (можно несколько через запятую, пусто — отмена)") -split '[,; ]+' | Where-Object { $_ })
    $ips = @($ips | Where-Object { if (Test-IpOrCidr $_) { $true } else { Write-Warn "Некорректный IP: $_"; $false } })
    if (-not $ips) { return }
    foreach ($ip in $ips) { if ($ip -notin $banned) { Write-Warn "$ip сейчас не в бане — всё равно передаю службе" } }
    Add-Content (Join-Path (Get-IPBanDir) 'unban.txt') $ips
    Write-Step "Передано службе, жду снятия бана (до 30 с)…"
    $left = @($ips | Where-Object { $_ -in $banned })
    for ($t = 0; $t -lt 30 -and $left; $t += 3) {
        Start-Sleep 3
        $now = @(Get-BannedIPs)
        $left = @($left | Where-Object { $_ -in $now })
    }
    if ($left) { Write-Warn "Всё ещё в бане: $($left -join ', ') — проверьте лог службы (Настройки → Последние строки лога)" }
    else       { Write-Ok "Разбанено: $($ips -join ', ')" }
    if (Confirm-Yes "Добавить в белый список, чтобы не забанило снова?") {
        $s = Get-Settings
        $s.ExtraWhitelist = @(@($s.ExtraWhitelist) + $ips | Select-Object -Unique)
        Repair-ServicePath
        if (-not (Apply-Settings $s -Save)) { Write-Warn "В белый список не добавлены" }
    }
}

function Show-Status {
    Write-Step "Состояние"
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    $inst = Get-InstalledVersion
    Write-Host ("    Служба:            {0}" -f ($(if ($svc) { "$($svc.Status) / $($svc.StartType)" } else { 'не установлена' })))
    Write-Host ("    Каталог:           {0}" -f (Get-IPBanDir))
    Write-Host ("    Версия:            {0}" -f ($(if ($inst) { $inst } else { '—' })))
    $latest = Get-LatestVersion
    Write-Host ("    Последний релиз:   {0}" -f ($(if ($latest) { $latest } else { 'не удалось получить' })))
    $banned = @(Get-BannedIPs)
    Write-Host ("    Забанено адресов:  {0}" -f $banned.Count)
    $fwOff = Get-NetFirewallProfile | Where-Object { -not $_.Enabled }
    if ($fwOff) { Write-Warn "Брандмауэр выключен в профилях: $($fwOff.Name -join ', ') — баны не действуют" }
    $origin = if (-not $svc) { '—' } elseif (Test-ForeignInstall) { 'чужая установка, настройки не импортированы' } else { switch ((Load-Settings).Origin) { 'adopted' { "чужая, импортирована $((Load-Settings).AdoptedAt)" } default { 'установлена менеджером' } } }
    Write-Host ("    Происхождение:     {0}" -f $origin)
    Write-Host ("    Конфиг:            {0}" -f (Get-ConfigPath))
    if (Test-UnquotedServicePath) { Write-Warn "Путь службы без кавычек (уязвимость unquoted service path). Исправляется пунктом «Обновить» или -Action Apply" }
    if (Test-Path (Get-OverridePath)) { Write-Warn "Есть ipban.override.config — его значения перекрывают основной конфиг (менеджер правит оба)" }
    $comp = @(Get-Competitors)
    if ($comp) { Write-Warn "Найдены программы того же назначения:"; $comp | ForEach-Object { Write-Host "      $_" } }
    $audit = & auditpol.exe /get /subcategory:"$AuditLogonGuid" /r | ConvertFrom-Csv
    Write-Host ("    Аудит входа:       {0}" -f $audit.'Inclusion Setting')
}
#endregion

#region ── Применение настроек к ipban.config ─────────────────────────────────
function Enable-LogonAudit {
    & auditpol.exe /set /subcategory:"$AuditLogonGuid" /failure:enable | Out-Null
    Write-Ok "Аудит неудачных входов включён"
}

# Возвращает $true, если применено (или менять нечего), $false — если пользователь отказался.
# -Save: сохранить настройки менеджера, но только после подтверждения — при отказе ничего не сохраняется.
function Apply-Settings($s, [switch]$NoConfirm, [switch]$Save) {
    $cfg = Get-ConfigPath
    if (-not (Test-Path $cfg)) { throw "Не найден $cfg — IPBan не установлен?" }

    $old = Read-EffectiveValues
    $wl  = @(Get-WhitelistEntries $s)
    $values = [ordered]@{
        FailedLoginAttemptsBeforeBan     = [string]$s.Attempts
        BanTime                          = $s.BanTime
        ExpireTime                       = $s.ExpireTime
        Whitelist                        = @($wl | ForEach-Object { $_.Entry }) -join ','
        UseDefaultBannedIPAddressHandler = ([string][bool]$s.ShareBannedIPs).ToLower()
    }
    $labels = @{
        FailedLoginAttemptsBeforeBan     = 'Попыток до бана'
        BanTime                          = 'Длительность бана'
        ExpireTime                       = 'Сброс счётчика попыток'
        UseDefaultBannedIPAddressHandler = 'Отправлять баны в глоб. базу DigitalRuby'
    }

    # Что именно изменится
    $changes = @($values.Keys | Where-Object {
        if ($_ -eq 'Whitelist') {
            $a = @(([string]$old[$_]   -split '[,;\s]+') | Where-Object { $_ } | Sort-Object -Unique)
            $b = @(([string]$values[$_] -split '[,;\s]+') | Where-Object { $_ } | Sort-Object -Unique)
            ($a -join ',') -ne ($b -join ',')
        } else { [string]$old[$_] -ne [string]$values[$_] }
    })
    if (-not $changes) {
        Write-Ok "Изменений нет — конфиг не трогаю"
        if ($Save) { Save-Settings $s }
        return $true
    }
    Write-Step "Что изменится в $(Split-Path $cfg -Leaf):"
    foreach ($k in $changes) {
        if ($k -eq 'Whitelist') { continue }
        $from, $to = foreach ($v in $old[$k], $values[$k]) {
            switch ([string]$v) { '' { '(не задано)' } 'true' { 'да' } 'false' { 'нет' } default { $v } }
        }
        Write-Host ("    {0}:  " -f $labels[$k]) -NoNewline -ForegroundColor White
        Write-Host $from -NoNewline -ForegroundColor DarkGray
        Write-Host '  →  ' -NoNewline
        Write-Host $to -ForegroundColor Green
    }
    if ($changes -contains 'Whitelist') { Show-WhitelistDiff $old.Whitelist $wl }
    if ($Action -eq 'Menu' -and -not $NoConfirm -and -not (Confirm-Yes "Применить?")) { Write-Warn "Отменено"; return $false }
    if ($Save) { Save-Settings $s }

    # Пишем в основной конфиг и в override (если он есть и содержит ключ) — иначе override перебьёт
    foreach ($f in @($cfg, (Get-OverridePath))) {
        if (-not (Test-Path $f)) { continue }
        Copy-Item $f "$f.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
        [xml]$xml = Get-Content $f -Raw -Encoding UTF8
        $touched = $false
        foreach ($k in $changes) {
            $node = $xml.SelectSingleNode("//appSettings/add[@key='$k']")
            if ($node) { $node.SetAttribute('value', $values[$k]); $touched = $true }
            elseif ($f -eq $cfg) { Write-Warn "Ключ '$k' не найден в $(Split-Path $f -Leaf) — пропущен" }
        }
        if ($touched) { $xml.Save($f) }
        Get-ChildItem "$f.bak_*" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force
    }

    Restart-IPBan
    $true
}

function Restart-IPBan {
    Set-Service $ServiceName -StartupType Automatic
    Restart-Service $ServiceName -Force
    Start-Sleep 2
    Write-Ok "Служба ${ServiceName}: $((Get-Service $ServiceName).Status)"
}
#endregion

#region ── Установка / обновление / удаление ─────────────────────────────────
function Invoke-OfficialInstaller {
    Write-Step "Скачиваю и запускаю официальный установщик DigitalRuby"
    $code = (New-Object Net.WebClient).DownloadString($InstallerUrl)
    Invoke-Expression $code
    Start-Sleep 5
    if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { throw "Служба $ServiceName не появилась после установки" }
}

function Install-IPBan {
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Write-Warn "IPBan уже установлен ($(Get-InstalledVersion)), каталог $(Get-IPBanDir)."
        if (Test-ForeignInstall) { [void](Import-ExistingSettings) }
        Write-Host "    Установка не нужна. Дальше — «Настройки» или «Обновить»."
        return
    }
    $comp = @(Get-Competitors)
    if ($comp) {
        Write-Warn "Уже стоят программы того же назначения:"; $comp | ForEach-Object { Write-Host "      $_" }
        Write-Warn "Две системы банов будут дублировать правила брандмауэра и мешать разбану."
        if ($Action -ne 'Menu' -or -not (Confirm-Yes "Всё равно ставить IPBan?")) { Write-Warn "Установка прервана"; return }
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 14393) { Write-Warn "Официально поддерживаются Windows Server 2016 / Windows 10 и новее" }

    Enable-LogonAudit
    Invoke-OfficialInstaller
    Repair-ServicePath
    $s = Load-Settings
    if (-not (Test-Path $SettingsPath)) { Save-Settings $s }
    [void](Apply-Settings $s -NoConfirm)   # свежая установка — применяем без вопросов
    Write-Ok "Установлено: $(Get-InstalledVersion)"
}

function Update-IPBan {
    if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { Write-Warn "IPBan не установлен"; return }
    $cur = Get-InstalledVersion; $new = Get-LatestVersion
    Write-Host "    Установлено: $cur   Последний релиз: $new"
    if ($new -and $cur -and ($new.TrimStart('v') -eq $cur.Split('+')[0])) {
        if ($Action -eq 'Menu' -and -not (Confirm-Yes "Версия актуальна. Всё равно переустановить?")) { return }
    }
    $s = Get-Settings          # при чужой установке — импорт ДО переустановки
    $cfg = Get-ConfigPath
    $keep = Join-Path $StateDir "ipban.config.before-update_$(Get-Date -Format yyyyMMdd_HHmmss)"
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }
    Copy-Item $cfg $keep
    Write-Step "Конфиг до обновления сохранён: $keep"

    Invoke-OfficialInstaller
    Repair-ServicePath
    # Конфиг мог быть заменён свежим из релиза — накатываем наши настройки поверх нового формата.
    [void](Apply-Settings $s)
    Write-Ok "Обновлено: $cur -> $(Get-InstalledVersion)"
}

function Uninstall-IPBan {
    $dir = Get-IPBanDir
    if ((Test-ForeignInstall) -or ((Test-Path $SettingsPath) -and (Load-Settings).Origin -eq 'adopted')) {
        Write-Warn "Эта установка IPBan сделана НЕ этим менеджером — возможно, на неё кто-то рассчитывает."
    }
    if ($Action -eq 'Menu' -and -not (Confirm-Yes "Удалить IPBan и все его правила брандмауэра (баны будут сняты)?")) { return }

    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Write-Step "Останавливаю и удаляю службу"
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
    }
    Write-Step "Удаляю правила брандмауэра IPBan"
    Get-NetFirewallRule -DisplayName 'IPBan*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    if (Test-Path $dir) {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }
        $cfg = Get-ConfigPath
        if (Test-Path $cfg) { Copy-Item $cfg (Join-Path $StateDir "ipban.config.uninstalled_$(Get-Date -Format yyyyMMdd_HHmmss)") }
        Start-Sleep 2
        Remove-Item $dir -Recurse -Force
        Write-Ok "Каталог $dir удалён (копия конфига — в $StateDir)"
    }
    if ($Action -eq 'Menu' -and (Confirm-Yes "Удалить и настройки менеджера ($StateDir)?")) {
        Remove-Item $StateDir -Recurse -Force
    }
    Write-Ok "IPBan удалён. Аудит входа оставлен включённым."
}
#endregion

#region ── Меню настроек ─────────────────────────────────────────────────────
# Ввод времени по-человечески: 30m, 12h, 1d, 7d — или сразу DD:HH:MM:SS
function Read-Duration($prompt, $current) {
    $v = Read-Host "$prompt (сейчас $current; примеры: 30m, 12h, 1d, 7d)"
    if (-not $v) { return $current }
    if ($v -match '^\d{1,2}:\d{2}:\d{2}:\d{2}$') { return $v }
    if ($v -match '^(\d+)\s*([mhd])$') {
        $n = [int]$Matches[1]
        $ts = switch ($Matches[2]) { 'm' { [TimeSpan]::FromMinutes($n) } 'h' { [TimeSpan]::FromHours($n) } 'd' { [TimeSpan]::FromDays($n) } }
        return ('{0:D2}:{1:D2}:{2:D2}:{3:D2}' -f $ts.Days, $ts.Hours, $ts.Minutes, $ts.Seconds)
    }
    Write-Warn "Не понял формат, оставляю $current"; $current
}

function Test-IpOrCidr([string]$v) {
    $parts = $v.Split('/')
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { return $false }
    if ($parts.Count -eq 2) {
        $max = if ($ip.AddressFamily -eq 'InterNetworkV6') { 128 } else { 32 }
        return ($parts[1] -match '^\d+$' -and [int]$parts[1] -le $max)
    }
    $parts.Count -eq 1
}

# Запись белого списка: IP/CIDR, доменное имя или URL текстового списка адресов — всё это понимает сам IPBan.
function Test-WhitelistEntry([string]$v) {
    if ($v -match '^https?://[^|]+$') { return $true }
    # Похоже на адрес — проверяем строго, иначе опечатка вроде 10.0.0.256 прошла бы как «домен»
    if ($v -match '^[\d./]+$' -or $v -match ':') { return Test-IpOrCidr $v }
    [Uri]::CheckHostName($v) -eq 'Dns'
}

function Menu-Whitelist($s) {
    $c = $null
    while ($true) {
        Clear-Host
        Write-Host "Белый список`n" -ForegroundColor Cyan
        Write-Host ("Автоопределение сетей: {0}" -f ($(if ($s.AutoNetworks) { 'ВКЛ' } else { 'выкл' })))
        Get-LocalNetworks | Format-Table Entry, Type, From -AutoSize | Out-Host
        $peers = @(Get-RdpPeers | ForEach-Object { "$($_.Address) ($($_.User))" })
        Write-Host ("Активные RDP-сессии: {0}   (добавлять: {1})" -f $(if ($peers) { $peers -join ', ' } else { 'нет' }), $(if ($s.IncludeRdpPeers) { 'да' } else { 'нет' }))
        Write-Host "`nРучной список:"
        if ($s.ExtraWhitelist.Count) { $i = 1; foreach ($e in $s.ExtraWhitelist) { Write-Host "  $i) $e"; $i++ } } else { Write-Host "  (пусто)" }
        $c = Select-Menu @(
            @('1', 'Вкл/выкл автоопределение частных сетей'),
            @('2', 'Вкл/выкл добавление активных RDP-сессий'),
            @('3', 'Добавить IP/подсеть/домен/URL списка вручную'),
            @('4', 'Удалить из ручного списка'),
            @('5', 'Показать итоговый белый список'),
            @('0', 'Назад')
        ) $c
        switch ($c) {
            '1' { $s.AutoNetworks = -not $s.AutoNetworks }
            '2' { $s.IncludeRdpPeers = -not $s.IncludeRdpPeers }
            '3' {
                $v = (Read-Host "IP, CIDR, домен или URL списка адресов (можно несколько через запятую)") -split '[,; ]+' | Where-Object { $_ }
                $pause = $false
                foreach ($x in $v) {
                    if (-not (Test-WhitelistEntry $x)) { Write-Warn "Некорректно: $x"; $pause = $true; continue }
                    $s.ExtraWhitelist = @($s.ExtraWhitelist + $x | Select-Object -Unique)
                    if ([Uri]::CheckHostName($x) -eq 'Dns') {
                        $pause = $true
                        try   { Write-Host "    $x сейчас -> $(([Net.Dns]::GetHostAddresses($x)).IPAddressToString -join ', ')" }
                        catch { Write-Warn "$x сейчас не разрешается — добавлен, IPBan будет пробовать раз в 5 минут" }
                    }
                }
                if ($pause) { Pause-Menu }
            }
            '4' {
                if (-not $s.ExtraWhitelist.Count) { break }
                $items = @(); $i = 0
                foreach ($e in $s.ExtraWhitelist) { $i++; $items += ,@("$i", $e) }
                $items += ,@('0', 'Отмена')
                Clear-Host
                Write-Host "Удалить из ручного списка" -ForegroundColor Cyan
                $n = Select-Menu $items
                if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $s.ExtraWhitelist.Count) {
                    $del = $s.ExtraWhitelist[[int]$n - 1]
                    $s.ExtraWhitelist = @($s.ExtraWhitelist | Where-Object { $_ -ne $del })
                }
            }
            '5' { Write-Host ''; Show-WhitelistDiff (Read-EffectiveValues).Whitelist @(Get-WhitelistEntries $s); Pause-Menu }
            '0' { return }
        }
    }
}

function Menu-Settings {
    $s = Get-Settings
    $c = $null
    while ($true) {
        Clear-Host
        Write-Host "Настройки IPBan" -ForegroundColor Cyan
        $c = Select-Menu @(
            @('1', "Попыток до бана:            $($s.Attempts)"),
            @('2', "Длительность бана:          $($s.BanTime)"),
            @('3', "Сброс счётчика попыток:     $($s.ExpireTime)"),
            @('4', "Белый список…               (ручных: $($s.ExtraWhitelist.Count), авто: $(if ($s.AutoNetworks) {'вкл'} else {'выкл'}))"),
            @('5', "Отправлять баны в глоб. базу DigitalRuby: $(if ($s.ShareBannedIPs) {'ДА'} else {'нет'})"),
            @('',  '─────────────'),
            @('6', 'Последние строки лога'),
            @('',  '─────────────'),
            @('9', 'Сохранить и применить (перезапуск службы)'),
            @('0', 'Назад без применения')
        ) $c
        switch ($c) {
            '1' { $v = Read-Host "Попыток (1–100)"; if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 100) { $s.Attempts = [int]$v } }
            '2' { $s.BanTime    = Read-Duration "Длительность бана" $s.BanTime }
            '3' { $s.ExpireTime = Read-Duration "Сброс счётчика"   $s.ExpireTime }
            '4' { Menu-Whitelist $s }
            '5' { $s.ShareBannedIPs = -not $s.ShareBannedIPs }
            '6' {
                $log = Join-Path (Get-IPBanDir) 'logfile.txt'
                if (Test-Path $log) { Get-Content $log -Tail 40 | Out-Host } else { Write-Warn "Лог не найден: $log" }
                Pause-Menu
            }
            '9' {
                if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
                    Save-Settings $s; Write-Warn "IPBan не установлен — настройки применятся при установке"; Pause-Menu; return
                }
                Repair-ServicePath
                if (Apply-Settings $s -Save) { Pause-Menu; return }
                Write-Warn "Не сохранено. Правки остались в этом меню — можно поправить или выйти через «0» без сохранения"
                Pause-Menu
            }
            '0' { return }
        }
    }
}
#endregion

#region ── Главное меню / точка входа ────────────────────────────────────────
function Menu-Main {
    $c = $null
    while ($true) {
        Clear-Host
        $ver = Get-InstalledVersion
        $tag = if (-not $ver) { 'не установлен' } elseif (Test-ForeignInstall) { "установлен $ver, чужая установка — настройки не импортированы" } elseif ((Load-Settings).Origin -eq 'adopted') { "установлен $ver, импортирован" } else { "установлен $ver" }
        Write-Host "IPBan Manager   [$tag]" -ForegroundColor Cyan
        $c = Select-Menu @(
            @('1', 'Установить'),
            @('2', 'Обновить'),
            @('3', 'Удалить'),
            @('4', 'Настройки'),
            @('5', 'Состояние'),
            @('',  '─────────────'),
            @('6', 'Забаненные адреса'),
            @('7', 'Разбанить IP'),
            @('0', 'Выход')
        ) $c
        try {
            switch ($c) {
                '1' { Install-IPBan;   Pause-Menu }
                '2' { Update-IPBan;    Pause-Menu }
                '3' { Uninstall-IPBan; Pause-Menu }
                '4' { Menu-Settings }
                '5' { Show-Status;     Pause-Menu }
                '6' { Show-Banned;     Pause-Menu }
                '7' { Invoke-Unban;    Pause-Menu }
                '0' { return }
            }
        } catch { Write-Host "ОШИБКА: $($_.Exception.Message)" -ForegroundColor Red; Pause-Menu }
    }
}

$found = Resolve-IPBanServiceName
if ($found) { $ServiceName = $found }

switch ($Action) {
    'Menu'      { Menu-Main }
    'Install'   { Install-IPBan }
    'Update'    { Update-IPBan }
    'Uninstall' { Uninstall-IPBan }
    'Apply'     { Repair-ServicePath; [void](Apply-Settings (Get-Settings)) }
    'Status'    { Show-Status }
}
#endregion
}
