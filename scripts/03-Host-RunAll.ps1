<#
.SYNOPSIS
  Проведение серий эксперимента (п. 4.5-4.6 протокола).
  Запускается на хосте от имени администратора.

.DESCRIPTION
  План: 2 расписания (Daily, Weekly) x 2 интенсивности притока (2 и 6 ГБ/сут) x повторы,
  каждая серия - 14 модельных суток (2 недельных цикла). Еженедельное задание запускается
  после каждых 7 суток притока, полная копия тома E: средствами Windows Server Backup
  делается раз в неделю (23:00 6-х и 13-х суток).
  Порядок серий перемешивается с фиксированным зерном, чтобы изменение состояния хоста
  во времени (нагрев, фоновые задачи) не совпадало с уровнем фактора.

  Для каждой серии:
    1) ВМ откатывается к контрольной точке Base, исходное состояние у всех серий одинаковое;
    2) ВМ запускается, в нее копируется гостевой скрипт;
    3) серия выполняется внутри ВМ как задача планировщика от имени SYSTEM,
       поэтому разрыв сеанса PowerShell Direct ее не прерывает;
    4) хост раз в минуту выводит ход серии и ждет файла done.txt или failed.txt;
    5) результаты копируются на хост в results\<серия> до следующего отката;
    6) ВМ выключается.
  При повторном запуске серии, для которых уже есть done.txt, пропускаются.
  В конце CSV-файлы серий объединяются в results\runs.csv, events.csv и wsb.csv.

.EXAMPLE
  $c = Get-Credential Administrator
  .\03-Host-RunAll.ps1 -Credential $c -Smoke         # пробная короткая серия без WSB (около 10 мин)
  .\03-Host-RunAll.ps1 -Credential $c -Repeats 4     # 16 серий, n = 4
  .\03-Host-RunAll.ps1 -Credential $c                # 20 серий, n = 5
  .\03-Host-RunAll.ps1 -Credential $c -Repeats 8     # 32 серии, n = 8
  .\03-Host-RunAll.ps1 -Credential $c -NoBackup -Intensities 6 -Repeats 1
                                                     # контрольные серии без WSB (results_noWSB)
  .\03-Host-RunAll.ps1 -Credential $c -MemoryGB 4    # если на хосте не хватает ОЗУ для 8 ГБ
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$VMName = 'WS2025-DEDUP',
    [pscredential]$Credential,
    [string[]]$Schedules = @('Daily', 'Weekly'),
    [double[]]$Intensities = @(2, 6),
    [int]$Repeats = 5,
    [int]$Days = 14,
    [string]$ResultsDir = (Join-Path $PSScriptRoot 'results'),
    [switch]$Smoke,
    [switch]$NoBackup,                  # контрольные серии без копий WSB, результаты в results_noWSB
    [int]$MemoryGB = 0                  # больше 0 - объем ОЗУ ВМ, задается после каждого отката
)
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V
if (-not $Credential) { $Credential = Get-Credential -UserName 'Administrator' -Message 'Пароль администратора ВМ' }
if (-not (Get-VMSnapshot -VMName $VMName -Name 'Base' -ErrorAction SilentlyContinue)) {
    throw 'Нет контрольной точки Base. Сначала выполните .\02-Host-DeployToVM.ps1'
}
$GuestScript = Join-Path $PSScriptRoot 'Dedup-ScheduleExperiment.ps1'
$GuestOut = 'C:\DedupExp\out'
$extra = ''
if ($NoBackup) {
    if (-not $PSBoundParameters.ContainsKey('ResultsDir')) { $ResultsDir = Join-Path $PSScriptRoot 'results_noWSB' }
    $extra = ' -SkipBackup'
}
if ($Smoke) {
    $ResultsDir = Join-Path $PSScriptRoot 'results_smoke'
    $Schedules = @('Weekly'); $Intensities = @(0.5); $Repeats = 1; $Days = 7
    $extra = ' -SkipBackup'
}
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---------- план серий (в случайном порядке)
$plan = foreach ($sch in $Schedules) { foreach ($i in $Intensities) { foreach ($r in 1..$Repeats) {
    [pscustomobject]@{ Schedule = $sch; Intensity = $i; Repeat = $r
                       Tag = ('{0}_{1}GB_r{2}' -f $sch, $i.ToString($inv), $r) } } } }
$rng = [System.Random]::new(2026)
$plan = $plan | Sort-Object { $rng.Next() }
$plan | Format-Table Tag -AutoSize | Out-String | Write-Host
$plan | Select-Object Tag | Export-Csv (Join-Path $ResultsDir 'plan_order.csv') -NoTypeInformation -Encoding UTF8

function Wait-Guest {
    # Ожидание готовности гостевой ОС через PowerShell Direct (не более 15 минут).
    $last = ''; $credErr = 0
    Write-Host 'Ожидание готовности гостевой ОС' -NoNewline
    for ($i = 0; $i -lt 180; $i++) {
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop | Out-Null
            Write-Host ' готово.'; return
        } catch {
            $last = $_.Exception.Message
            # Сразу после загрузки ВМ PowerShell Direct может некоторое время отвечать
            # "Недопустимые учетные данные", пока не запущены службы входа.
            # Пароль считается неверным, если ошибка повторяется 4 минуты подряд.
            if ($last -match 'credential|учетн|учётн|парол|password|логон|logon|имя пользователя|user name') { $credErr++ } else { $credErr = 0 }
            if ($credErr -ge 48) {
                Write-Host ''
                throw ("ВМ не принимает имя пользователя или пароль: $last`n" +
                       'Проверьте имя (Administrator), пароль и раскладку клавиатуры и запустите скрипт снова.')
            }
            if (($i % 12) -eq 11) { Write-Host (" [{0} мин, ВМ: {1}]" -f [int](($i + 1) * 5 / 60), (Get-VM $VMName).State) -NoNewline }
            else { Write-Host '.' -NoNewline }
            Start-Sleep 5
        }
    }
    Write-Host ''
    throw ("Гостевая ОС не ответила за 15 минут. Состояние ВМ: {0}. Последняя ошибка: {1}`n" +
           "Проверьте экран ВМ: vmconnect localhost {2}") -f (Get-VM $VMName).State, $last, $VMName
}

function Format-Span([TimeSpan]$t) { '{0} ч {1:D2} мин' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
function Test-Done($p) { Test-Path (Join-Path (Join-Path $ResultsDir $p.Tag) 'done.txt') }

$total = @($plan).Count; $k = 0; $ran = 0; $t0 = Get-Date
foreach ($p in $plan) {
    $k++
    $dest = Join-Path $ResultsDir $p.Tag
    if (Test-Done $p) { Write-Host "[$k/$total] $($p.Tag): уже выполнена, пропуск."; continue }
    Write-Host "`n[$k/$total] $($p.Tag): откат к Base и запуск ВМ..." -ForegroundColor Cyan

    if ((Get-VM $VMName).State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
    # Откат удаляет разностные диски прошлой серии, поэтому свободное место проверяется после него.
    Restore-VMSnapshot -VMName $VMName -Name 'Base' -Confirm:$false
    Start-Sleep -Seconds 5
    if ($MemoryGB -gt 0) {
        # откат возвращает настройки ВМ из Base, поэтому память задается после каждого отката
        Set-VMMemory -VMName $VMName -StartupBytes ($MemoryGB * 1GB)
        Write-Host ("  память ВМ: {0} ГБ" -f $MemoryGB)
    }
    $drv = (Get-VM $VMName).Path.Substring(0, 1)
    $freeGB = (Get-PSDrive $drv).Free / 1GB
    Write-Host ("  свободно на диске {0}: {1:N0} ГБ" -f $drv, $freeGB)
    if ($freeGB -lt 180) { throw ("На диске {0}: свободно {1:N0} ГБ, для серии нужно не меньше 180 ГБ. Освободите место и запустите скрипт снова." -f $drv, $freeGB) }
    Start-VM -Name $VMName
    Wait-Guest

    $s = New-PSSession -VMName $VMName -Credential $Credential
    try {
        Copy-Item -ToSession $s -Path $GuestScript -Destination 'C:\DedupExp\' -Force
        $arg = ('-NoProfile -ExecutionPolicy Bypass -File "C:\DedupExp\Dedup-ScheduleExperiment.ps1" -Action Run ' +
                '-Schedule {0} -IntensityGB {1} -Repeat {2} -Days {3} -OutDir "{4}"{5}') -f `
                $p.Schedule, $p.Intensity.ToString($inv), $p.Repeat, $Days, $GuestOut, $extra
        Invoke-Command -Session $s -ArgumentList $arg {
            param($a)
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $a
            $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 24) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName 'DedupExpSeries' -Action $act -Settings $set -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
            Start-ScheduledTask -TaskName 'DedupExpSeries'
        }
    } finally { Remove-PSSession $s }

    # ---------- ожидание завершения серии
    $state = 'running'
    while ($state -eq 'running') {
        Start-Sleep -Seconds 60
        if ((Get-VM $VMName).State -match 'Paused') {
            Write-Warning "ВМ приостановлена, вероятно, закончилось место на диске хоста. Освободите место и выполните Resume-VM $VMName"
            continue
        }
        try {
            $state, $last = Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $GuestOut {
                param($o)
                $st = 'running'
                if (Test-Path "$o\done.txt") { $st = 'done' } elseif (Test-Path "$o\failed.txt") { $st = 'failed' }
                elseif ((Get-ScheduledTask -TaskName 'DedupExpSeries').State -ne 'Running') { $st = 'failed' }
                $l = ''; if (Test-Path "$o\progress.log") { $l = Get-Content "$o\progress.log" -Tail 1 -Encoding UTF8 }
                $st; $l
            } -ErrorAction Stop
            Write-Host ("  {0:HH:mm}  {1}" -f (Get-Date), $last)
        } catch { Write-Host "  (нет связи с ВМ, повтор через минуту)" }
    }

    # ---------- копирование результатов на хост до следующего отката
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $s = New-PSSession -VMName $VMName -Credential $Credential
    try { Copy-Item -FromSession $s -Path "$GuestOut\*" -Destination $dest -Recurse -Force }
    finally { Remove-PSSession $s }
    if ($state -eq 'failed') {
        Write-Warning "Серия $($p.Tag) завершилась с ошибкой, см. $dest\progress.log и failed.txt"
        Write-Warning 'После устранения причины запустите скрипт снова, готовые серии будут пропущены.'
        Stop-VM -Name $VMName -Force
        return
    }
    Stop-VM -Name $VMName -Force
    $ran++
    $el = (Get-Date) - $t0
    $left = @($plan | Where-Object { -not (Test-Done $_) }).Count
    Write-Host ("[{0}/{1}] {2}: готово. Прошло {3}, осталось примерно {4}" -f $k, $total, $p.Tag,
        (Format-Span $el), (Format-Span ([TimeSpan]::FromTicks([long]($el.Ticks / $ran * $left))))) -ForegroundColor Green
}

# ---------- объединение CSV завершенных серий (набор столбцов - объединение по всем файлам)
foreach ($name in 'runs.csv', 'events.csv', 'wsb.csv') {
    $files = Get-ChildItem $ResultsDir -Recurse -Filter $name |
        Where-Object { $_.DirectoryName -ne $ResultsDir -and (Test-Path (Join-Path $_.DirectoryName 'done.txt')) }
    if (-not $files) { continue }
    $all = foreach ($f in $files) { Import-Csv $f.FullName -Delimiter ';' }
    $cols = @(); foreach ($row in $all) { foreach ($n in $row.PSObject.Properties.Name) { if ($cols -notcontains $n) { $cols += $n } } }
    $all | Select-Object $cols | Export-Csv (Join-Path $ResultsDir $name) -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host ("{0}: {1} строк" -f $name, @($all).Count)
}
Write-Host "`nСерии завершены. Результаты: $ResultsDir"
Write-Host 'Сводка (медиана, IQR, CV среднего объема перед запуском задания):'
& $GuestScript -Action Summary -OutDir $ResultsDir
