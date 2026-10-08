<#
.SYNOPSIS
  Подготовка стенда внутри ВМ и создание контрольной точки Base (п. 4.4 протокола).
  Запускается на хосте от имени администратора.

.DESCRIPTION
  Работает через PowerShell Direct, сетевое подключение к ВМ не требуется:
    1) отключает ISO от DVD-привода ВМ;
    2) копирует в ВМ гостевой скрипт Dedup-ScheduleExperiment.ps1 (папка C:\DedupExp);
    3) выполняет -Action Prepare: компоненты, разметка дисков E: и G:, настройка дедупликации;
    4) выполняет -Action Seed: исходный набор данных 40 ГБ и его оптимизация;
    5) сохраняет сведения о стенде в results\stand_status.txt;
    6) выключает ВМ и создает контрольную точку Base, с которой начинается каждая серия.

.EXAMPLE
  $c = Get-Credential Administrator
  .\02-Host-DeployToVM.ps1 -Credential $c
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$VMName = 'WS2025-DEDUP',
    [pscredential]$Credential,
    [double]$SeedGB = 40,
    [string]$ResultsDir = (Join-Path $PSScriptRoot 'results')
)
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V
if (-not $Credential) { $Credential = Get-Credential -UserName 'Administrator' -Message 'Пароль администратора ВМ' }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

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

# 1. ISO больше не нужен, иначе DVD-привод может занять букву E:
Set-VMDvdDrive -VMName $VMName -Path $null -ErrorAction SilentlyContinue
if ((Get-VM $VMName).State -ne 'Running') { Start-VM $VMName }
Wait-Guest

$s = New-PSSession -VMName $VMName -Credential $Credential
try {
    # 2. гостевой скрипт
    Invoke-Command -Session $s { New-Item -ItemType Directory -Force -Path 'C:\DedupExp' | Out-Null }
    Copy-Item -ToSession $s -Path (Join-Path $PSScriptRoot 'Dedup-ScheduleExperiment.ps1') -Destination 'C:\DedupExp\' -Force

    # 3. подготовка стенда
    Invoke-Command -Session $s {
        Set-ExecutionPolicy -Scope Process Bypass -Force
        & 'C:\DedupExp\Dedup-ScheduleExperiment.ps1' -Action Prepare
    }
    # 4. исходный набор данных
    Invoke-Command -Session $s -ArgumentList $SeedGB {
        param($gb)
        Set-ExecutionPolicy -Scope Process Bypass -Force
        & 'C:\DedupExp\Dedup-ScheduleExperiment.ps1' -Action Seed -SeedGB $gb
    }
    # 5. сведения о стенде
    $status = Invoke-Command -Session $s {
        Set-ExecutionPolicy -Scope Process Bypass -Force
        & 'C:\DedupExp\Dedup-ScheduleExperiment.ps1' -Action Status
    }
    $status | Out-File (Join-Path $ResultsDir 'stand_status.txt') -Encoding UTF8
    $status
}
finally { Remove-PSSession $s }

# 6. контрольная точка
Write-Host 'Выключение ВМ и создание контрольной точки Base...'
Stop-VM -Name $VMName
Get-VMSnapshot -VMName $VMName -Name 'Base' -ErrorAction SilentlyContinue | Remove-VMSnapshot
Checkpoint-VM -Name $VMName -SnapshotName 'Base'
Get-VMSnapshot -VMName $VMName | Format-Table Name, CreationTime, SnapshotType -AutoSize
Write-Host 'Стенд подготовлен. Далее пробный прогон: .\03-Host-RunAll.ps1 -Smoke (п. 4.5 протокола).'
