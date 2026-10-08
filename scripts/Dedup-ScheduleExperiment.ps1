<#
.SYNOPSIS
  Гостевой скрипт эксперимента SOS-013 / WIN-061: влияние периодичности задания оптимизации
  дедупликации (ежедневно / еженедельно) на объем неоптимизированных данных.
  Выполняется внутри ВМ с Windows Server 2025.

.DESCRIPTION
  Действия (-Action):
    Prepare        - установка ролей FS-Data-Deduplication и Windows-Server-Backup, разметка дисков
                     E: и G:, включение дедупликации на E:, MinimumFileAgeDays = 0,
                     отключение всех стандартных расписаний дедупликации;
    Seed           - исходный набор данных (по умолчанию 40 ГБ) в E:\Data\base и его оптимизация;
    Status         - сведения о стенде;
    Run            - одна серия в ускоренном режиме (по умолчанию 14 модельных суток);
    Summary        - медиана, IQR и CV по файлу runs.csv из каталога -OutDir;
    RealTimeSetup  - режим реального времени: расписание New-DedupSchedule и задачи планировщика;
    Intake, Measure, Backup - действия, которые вызывает планировщик в режиме реального времени.

  Результаты серии (каталог -OutDir, по умолчанию C:\DedupExp\out):
    runs.csv      - строка на каждый запуск задания: объем перед запуском (по файлам и по Get-DedupStatus),
                    длительность, остаток;
    events.csv    - состояние тома по модельным часам (приток, задание);
    wsb.csv       - полные копии тома E: средствами Windows Server Backup;
    meta.json     - параметры стенда и серии;
    progress.log  - журнал выполнения; done.txt / failed.txt - признак завершения серии.

.EXAMPLE
  .\Dedup-ScheduleExperiment.ps1 -Action Prepare
  .\Dedup-ScheduleExperiment.ps1 -Action Seed -SeedGB 40
  .\Dedup-ScheduleExperiment.ps1 -Action Run -Schedule Weekly -IntensityGB 6 -Repeat 1
  .\Dedup-ScheduleExperiment.ps1 -Action RealTimeSetup -Schedule Daily -IntensityGB 2
#>
[CmdletBinding()]
param(
    [ValidateSet('Prepare','Seed','Status','Run','Summary','RealTimeSetup','Intake','Measure','Backup')]
    [string]$Action = 'Status',
    [string]$Volume = 'E:',
    [string]$BackupTarget = 'G:',      # том для копий WSB внутри ВМ
    [ValidateSet('Daily','Weekly')]
    [string]$Schedule = 'Daily',
    [double]$IntensityGB = 6,          # номинальный суточный приток, ГБ
    [double]$IntensityCV = 0.12,       # разброс притока по суткам (доля)
    [double]$DuplicateShare = 0.5,     # доля повторяющихся блоков в новых данных
    [int]$Days = 14,                   # 2 недельных цикла
    [int]$Repeat = 1,
    [double]$SeedGB = 40,              # объем исходного набора, ГБ
    [switch]$SkipBackup,               # не делать копии WSB (используется в пробном прогоне)
    [string]$OutDir = 'C:\DedupExp\out'
)

$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$DataRoot = $Volume + '\Data'
$VolLetter = $Volume.TrimEnd(':')

function N([double]$x, [int]$d = 3) { [Math]::Round($x, $d).ToString($Inv) }
function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    if (Test-Path $OutDir) { Add-Content -Path (Join-Path $OutDir 'progress.log') -Value $line -Encoding UTF8 }
}
function Add-CsvRow([string]$file, [System.Collections.Specialized.OrderedDictionary]$row) {
    $path = Join-Path $OutDir $file
    if (-not (Test-Path $path)) { Add-Content -Path $path -Value (($row.Keys) -join ';') -Encoding UTF8 }
    Add-Content -Path $path -Value (($row.Values | ForEach-Object { "$_" }) -join ';') -Encoding UTF8
}

# =====================================================================  ПОДГОТОВКА
function Initialize-DataDisks {
    $raw = @(Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Size)
    $plan = @()
    if ($raw.Count -ge 2) { $plan = @(@{Disk = $raw[0]; Letter = $VolLetter; Label = 'DATA'},
                                      @{Disk = $raw[1]; Letter = $BackupTarget.TrimEnd(':'); Label = 'BACKUP'}) }
    elseif ($raw.Count -eq 1 -and -not (Get-Volume -DriveLetter $VolLetter -ErrorAction SilentlyContinue)) {
        $plan = @(@{Disk = $raw[0]; Letter = $VolLetter; Label = 'DATA'})
    }
    foreach ($p in $plan) {
        $busy = Get-Partition -DriveLetter $p.Letter -ErrorAction SilentlyContinue
        if ($busy) { throw "Буква $($p.Letter): уже занята. Отключите ISO от DVD-привода ВМ или освободите букву." }
        try { Set-Disk -Number $p.Disk.Number -IsOffline $false; Set-Disk -Number $p.Disk.Number -IsReadOnly $false } catch {}
        Initialize-Disk -Number $p.Disk.Number -PartitionStyle GPT
        New-Partition -DiskNumber $p.Disk.Number -UseMaximumSize -DriveLetter $p.Letter |
            Format-Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel $p.Label -Confirm:$false | Out-Null
        Log ("Диск {0} ({1:N0} ГБ) размечен как {2}: [{3}]" -f $p.Disk.Number, ($p.Disk.Size / 1GB), $p.Letter, $p.Label)
    }
    $need = @($VolLetter); if (-not $SkipBackup) { $need += $BackupTarget.TrimEnd(':') }
    foreach ($l in $need) {
        if (-not (Get-Volume -DriveLetter $l -ErrorAction SilentlyContinue)) { throw "Том $($l): не найден. Проверьте, что к ВМ подключены диск данных и диск резервных копий." }
    }
}

function Initialize-Stand {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Log 'Установка ролей FS-Data-Deduplication и Windows-Server-Backup...'
    Install-WindowsFeature -Name FS-Data-Deduplication, Windows-Server-Backup -IncludeManagementTools | Out-Null
    Import-Module Deduplication
    Initialize-DataDisks
    if (-not (Get-DedupVolume -Volume $Volume -ErrorAction SilentlyContinue)) {
        Enable-DedupVolume -Volume $Volume -UsageType Default | Out-Null
    }
    # файлы попадают в политику сразу, момент оптимизации определяет только расписание
    Set-DedupVolume -Volume $Volume -MinimumFileAgeDays 0
    # отключаются все расписания (фоновая оптимизация, сборка мусора, проверка целостности)
    Get-DedupSchedule | ForEach-Object { Set-DedupSchedule -Name $_.Name -Enabled $false }
    # исключение для антивируса, чтобы проверка тестовых файлов не влияла на время
    try { Add-MpPreference -ExclusionPath $DataRoot, ($BackupTarget + '\') } catch { Log 'Defender: исключение не добавлено.' }
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    Log 'Стенд подготовлен.'
    Show-Status
}

function Show-Status {
    Import-Module Deduplication
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    "`n=== Система ==="
    "{0} (сборка {1}); vCPU: {2}; ОЗУ: {3:N1} ГБ" -f $os.Caption, $os.BuildNumber, $cs.NumberOfLogicalProcessors, ($cs.TotalPhysicalMemory / 1GB)
    "`n=== Компоненты ==="
    Get-WindowsFeature FS-Data-Deduplication, Windows-Server-Backup | Format-Table Name, InstallState -AutoSize | Out-String
    "=== Тома ==="
    Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter |
        Format-Table DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={[Math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[Math]::Round($_.SizeRemaining/1GB,1)}} -AutoSize | Out-String
    "=== Дедупликация тома $Volume ==="
    Get-DedupVolume -Volume $Volume | Format-List Volume, Enabled, UsageType, MinimumFileAgeDays, SavedSpace, SavingsRate | Out-String
    "=== Расписания дедупликации ==="
    Get-DedupSchedule | Format-Table Name, Type, Enabled, Days, Start, DurationHours -AutoSize | Out-String
    "=== Состояние (Get-DedupStatus) ==="
    Update-DedupStatus -Volume $Volume | Out-Null
    Get-DedupStatus -Volume $Volume | Format-List Volume, FreeSpace, SavedSpace, OptimizedFilesCount, OptimizedFilesSize, InPolicyFilesCount, InPolicyFilesSize, LastOptimizationTime, LastOptimizationResultMessage | Out-String
}

# =====================================================================  ГЕНЕРАТОР ДАННЫХ
$script:Pool = $null
$script:Buf = [byte[]]::new(1MB)
$script:Crypto = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$script:Rnd = [System.Random]::new()

function Get-DuplicatePool {
    # 64 блока по 1 МиБ - повторяющееся содержимое (шаблоны, общие библиотеки).
    # Зерно фиксировано, поэтому пул одинаков в исходном наборе и во всех сериях.
    if (-not $script:Pool) {
        $r = [System.Random]::new(20260926)
        $script:Pool = New-Object 'System.Collections.Generic.List[byte[]]'
        for ($i = 0; $i -lt 64; $i++) { $b = [byte[]]::new(1MB); $r.NextBytes($b); $script:Pool.Add($b) }
    }
    $script:Pool
}

function Write-TestData([string]$Dir, [double]$GB) {
    $pool = Get-DuplicatePool
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $leftMB = [long][Math]::Round($GB * 1024); $i = 0
    while ($leftMB -gt 0) {
        $sizeMB = [Math]::Min($script:Rnd.Next(4, 65), $leftMB)
        $fs = [System.IO.File]::Create((Join-Path $Dir ('f{0:D5}.bin' -f $i)))
        try {
            for ($k = 0; $k -lt $sizeMB; $k++) {
                if ($script:Rnd.NextDouble() -lt $DuplicateShare) { $fs.Write($pool[$script:Rnd.Next(0, $pool.Count)], 0, 1MB) }
                else { $script:Crypto.GetBytes($script:Buf); $fs.Write($script:Buf, 0, 1MB) }
            }
        } finally { $fs.Close() }
        $leftMB -= $sizeMB; $i++
    }
}

function Get-DailyIntake {
    # нормальное распределение (преобразование Бокса - Мюллера), отрицательные значения отсекаются
    $u1 = 1 - $script:Rnd.NextDouble(); $u2 = $script:Rnd.NextDouble()
    $z = [Math]::Sqrt(-2 * [Math]::Log($u1)) * [Math]::Cos(2 * [Math]::PI * $u2)
    [Math]::Max(0.1 * $IntensityGB, $IntensityGB * (1 + $IntensityCV * $z))
}

# =====================================================================  ИЗМЕРЕНИЯ
function Measure-Fast {
    # Зависимая переменная: суммарный размер файлов >= 32 КБ без атрибута ReparsePoint,
    # т. е. файлов, которые еще не заменены ссылками на хранилище фрагментов (chunk store).
    $unopt = [double]0; $logical = [double]0
    foreach ($f in [System.IO.Directory]::EnumerateFiles($DataRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $fi = [System.IO.FileInfo]::new($f)
        $logical += $fi.Length
        if ($fi.Length -ge 32KB -and -not ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $unopt += $fi.Length }
    }
    [pscustomobject]@{ UnoptGB = $unopt / 1GB; LogicalGB = $logical / 1GB }
}

function Get-StatusUnopt {
    # Для сравнения с Measure-Fast: объем файлов в политике минус объем оптимизированных по Get-DedupStatus.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Update-DedupStatus -Volume $Volume | Out-Null
    $s = Get-DedupStatus -Volume $Volume
    $sw.Stop()
    [pscustomobject]@{
        InPolicyGB = $s.InPolicyFilesSize / 1GB; OptimizedGB = $s.OptimizedFilesSize / 1GB
        UnoptGB = ($s.InPolicyFilesSize - $s.OptimizedFilesSize) / 1GB; Seconds = $sw.Elapsed.TotalSeconds
    }
}

function Get-SavedGB {
    Update-DedupStatus -Volume $Volume | Out-Null
    (Get-DedupStatus -Volume $Volume).SavedSpace / 1GB
}

function Invoke-Optimization {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-DedupJob -Volume $Volume -Type Optimization -Priority Normal -Wait | Out-Null
    $sw.Stop()
    $st = Get-DedupStatus -Volume $Volume
    [pscustomobject]@{ Minutes = $sw.Elapsed.TotalMinutes; Result = "$($st.LastOptimizationResultMessage)" }
}

function Invoke-WsbBackup([int]$Day) {
    # Каждый раз делается полная копия: цель очищается, чтобы WSB не сделал инкрементальную.
    $tgt = $BackupTarget.TrimEnd(':') + ':'
    try { & wbadmin delete catalog -quiet 2>&1 | Out-Null } catch {}
    if (Test-Path "$tgt\WindowsImageBackup") { Remove-Item "$tgt\WindowsImageBackup" -Recurse -Force }
    & vssadmin delete shadows /for=$tgt /all /quiet 2>&1 | Out-Null
    $v = Get-Volume -DriveLetter $VolLetter
    $usedGB = ($v.Size - $v.SizeRemaining) / 1GB
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & wbadmin start backup "-backupTarget:$tgt" "-include:$Volume" -quiet 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    $img = (Get-ChildItem "$tgt\WindowsImageBackup" -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $row = [ordered]@{
        Schedule = $Schedule; IntensityGB = (N $IntensityGB); Repeat = $Repeat; Day = $Day
        UsedGB = (N $usedGB); ImageGB = (N ([double]$img / 1GB)); Minutes = (N $sw.Elapsed.TotalMinutes)
        ExitCode = $code
    }
    Add-CsvRow 'wsb.csv' $row
    if ($code -ne 0) { Log "ВНИМАНИЕ: wbadmin завершился с кодом $code. $($out | Select-Object -Last 3)" }
    Log ("WSB: сутки {0}, занято на томе {1} ГБ, образ {2} ГБ, {3} мин" -f $Day, (N $usedGB 1), (N ([double]$img / 1GB) 1), (N $sw.Elapsed.TotalMinutes 1))
}

function Add-Event([int]$Day, [int]$Hour, [string]$Kind, $m, [double]$savedGB) {
    Add-CsvRow 'events.csv' ([ordered]@{
        Schedule = $Schedule; IntensityGB = (N $IntensityGB); Repeat = $Repeat; Day = $Day; Hour = $Hour; Event = $Kind
        UnoptimizedGB = (N $m.UnoptGB); LogicalGB = (N $m.LogicalGB); SavedGB = (N $savedGB)
    })
}

function Test-JobDay([int]$Day) {
    # Day - номер модельных суток. Задание запускается в 02:00 суток Day, т. е. после притока суток Day-1.
    if ($Schedule -eq 'Daily') { return $Day -ge 2 }
    return ($Day -gt 1) -and ((($Day - 1) % 7) -eq 0)     # 8-е и 15-е сутки: после каждых 7 суток притока
}

function Write-Meta {
    $os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem
    $dv = Get-DedupVolume -Volume $Volume; $vol = Get-Volume -DriveLetter $VolLetter
    [ordered]@{
        Schedule = $Schedule; IntensityGB = $IntensityGB; IntensityCV = $IntensityCV; DuplicateShare = $DuplicateShare
        Days = $Days; Repeat = $Repeat; Mode = 'Accelerated'; Started = (Get-Date -Format s)
        OS = $os.Caption; Build = $os.BuildNumber; vCPU = $cs.NumberOfLogicalProcessors
        RamGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        DataVolumeGB = [Math]::Round($vol.Size / 1GB, 0); FileSystem = $vol.FileSystem
        UsageType = "$($dv.UsageType)"; MinimumFileAgeDays = $dv.MinimumFileAgeDays; Backup = (-not $SkipBackup)
        BaseLogicalGB = [Math]::Round((Measure-Fast).LogicalGB, 2); BaseSavedGB = [Math]::Round((Get-SavedGB), 2)
        PSVersion = "$($PSVersionTable.PSVersion)"
    } | ConvertTo-Json | Set-Content -Path (Join-Path $OutDir 'meta.json') -Encoding UTF8
}

# =====================================================================  СЕРИЯ (ускоренный режим)
function Start-Series {
    Import-Module Deduplication
    if (Test-Path $OutDir) { Remove-Item (Join-Path $OutDir '*') -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Log "Серия: расписание $Schedule, приток $IntensityGB ГБ/сут, повтор $Repeat, $Days сут."
    if (-not (Test-Path "$DataRoot\base")) { throw 'Нет исходного набора E:\Data\base. Сначала выполните -Action Seed.' }
    Get-ChildItem $DataRoot -Directory | Where-Object Name -ne 'base' | Remove-Item -Recurse -Force
    Get-DedupSchedule | Where-Object Enabled | ForEach-Object { Set-DedupSchedule -Name $_.Name -Enabled $false }
    Write-Meta
    $saved = Get-SavedGB
    Add-Event 1 0 'start' (Measure-Fast) $saved
    $run = 0
    for ($day = 1; $day -le $Days + 1; $day++) {
        if (Test-JobDay $day) {                                  # 02:00
            $run++
            $pre = Measure-Fast                                  # замер перед запуском задания
            $st = Get-StatusUnopt                                # контрольный замер по Get-DedupStatus
            $job = Invoke-Optimization
            $post = Measure-Fast
            $saved = Get-SavedGB
            Add-CsvRow 'runs.csv' ([ordered]@{
                Schedule = $Schedule; IntensityGB = (N $IntensityGB); Repeat = $Repeat; Run = $run; Day = $day
                Timestamp = (Get-Date -Format s); UnoptimizedGB = (N $pre.UnoptGB); LogicalGB = (N $pre.LogicalGB)
                JobMinutes = (N $job.Minutes); ResidualGB = (N $post.UnoptGB); SavedGB = (N $saved); JobResult = $job.Result
                StatusInPolicyGB = (N $st.InPolicyGB); StatusOptimizedGB = (N $st.OptimizedGB)
                StatusUnoptGB = (N $st.UnoptGB); StatusSeconds = (N $st.Seconds 1)
            })
            Add-Event $day 2 'job' $post $saved
            Log ("Сутки {0}, 02:00: до задания {1} ГБ, задание {2} мин, остаток {3} ГБ" -f $day, (N $pre.UnoptGB 2), (N $job.Minutes 2), (N $post.UnoptGB 2))
        }
        if ($day -gt $Days) { break }
        $intake = Get-DailyIntake                                # приток 08:00-20:00 двенадцатью порциями
        for ($h = 8; $h -lt 20; $h++) {
            Write-TestData -Dir ('{0}\day{1:D2}\h{2:D2}' -f $DataRoot, $day, $h) -GB ($intake / 12)
            Add-Event $day $h 'intake' (Measure-Fast) $saved
        }
        Log ("Сутки {0}: приток {1} ГБ" -f $day, (N $intake 2))
        if ((($day % 7) -eq 6) -and -not $SkipBackup) { Invoke-WsbBackup $day }   # 23:00 6-х и 13-х суток (конец недели)
    }
    Set-Content -Path (Join-Path $OutDir 'done.txt') -Value (Get-Date -Format s)
    Log 'Серия завершена.'
}

# =====================================================================  СВОДКА
function Get-Quantile([double[]]$v, [double]$p) {
    $s = [double[]]($v | Sort-Object); $h = ($s.Count - 1) * $p
    $lo = [int][Math]::Floor($h); $hi = [int][Math]::Ceiling($h)
    $s[$lo] + ($h - $lo) * ($s[$hi] - $s[$lo])
}
function Show-Summary([string]$csv = (Join-Path $OutDir 'runs.csv')) {
    $rows = Import-Csv $csv -Delimiter ';'
    $per = $rows | Group-Object Schedule, IntensityGB, Repeat | ForEach-Object {
        [pscustomobject]@{
            Schedule = $_.Group[0].Schedule; IntensityGB = $_.Group[0].IntensityGB
            Mean = ($_.Group | ForEach-Object { [double]($_.UnoptimizedGB -replace ',', '.') } | Measure-Object -Average).Average
        }
    }
    $per | Group-Object Schedule, IntensityGB | ForEach-Object {
        $v = [double[]]($_.Group | ForEach-Object { $_.Mean })
        $mean = ($v | Measure-Object -Average).Average
        $sd = 0; if ($v.Count -gt 1) { $sd = [Math]::Sqrt((($v | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / ($v.Count - 1)) }
        [pscustomobject]@{
            Schedule = $_.Group[0].Schedule; IntensityGB = $_.Group[0].IntensityGB; n = $v.Count
            MedianGB = [Math]::Round((Get-Quantile $v 0.5), 2)
            IQR_GB = [Math]::Round((Get-Quantile $v 0.75) - (Get-Quantile $v 0.25), 2)
            CV_pct = [Math]::Round(100 * $sd / $mean, 1)
        }
    } | Sort-Object IntensityGB, Schedule | Format-Table -AutoSize | Out-String
}

# =====================================================================  РЕЖИМ РЕАЛЬНОГО ВРЕМЕНИ
function Set-RealTimeSchedule {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Get-DedupSchedule | Where-Object Name -like 'Exp-*' | ForEach-Object { Remove-DedupSchedule -Name $_.Name }
    $days = if ($Schedule -eq 'Daily') { [DayOfWeek[]](0..6) } else { [DayOfWeek[]]@('Sunday') }
    New-DedupSchedule -Name "Exp-$Schedule" -Type Optimization -Days $days -Start (Get-Date '02:00') -DurationHours 6 -Priority Normal | Out-Null
    $common = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Schedule $Schedule -IntensityGB $(N $IntensityGB) -Repeat $Repeat -Volume $Volume -BackupTarget $BackupTarget -OutDir `"$OutDir`""
    $tasks = @(
        @{ Name = 'DedupExp-Intake';  Arg = "-Action Intake $common";  Trig = (New-ScheduledTaskTrigger -Daily -At '08:00') },
        @{ Name = 'DedupExp-Measure'; Arg = "-Action Measure $common"; Trig = $(if ($Schedule -eq 'Daily') { New-ScheduledTaskTrigger -Daily -At '01:55' } else { New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '01:55' }) },
        @{ Name = 'DedupExp-Backup';  Arg = "-Action Backup $common";  Trig = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '23:00') }
    )
    if ($SkipBackup) { $tasks = @($tasks | Where-Object { $_.Name -ne 'DedupExp-Backup' }) }
    foreach ($t in $tasks) {
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $t.Arg
        $task = Register-ScheduledTask -TaskName $t.Name -Action $a -Trigger $t.Trig -User 'SYSTEM' -RunLevel Highest -Force
        if ($t.Name -eq 'DedupExp-Intake') {   # каждый час с 08:00 до 19:00
            $task.Triggers[0].Repetition = (New-ScheduledTaskTrigger -Once -At '08:00' -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 11) -ErrorAction Stop).Repetition
            $task | Set-ScheduledTask | Out-Null
        }
    }
    Get-DedupSchedule -Name "Exp-$Schedule" | Format-List Name, Type, Days, Start, DurationHours, Enabled
    Get-ScheduledTask -TaskName 'DedupExp-*' | Format-Table TaskName, State -AutoSize
}

# =====================================================================  ТОЧКА ВХОДА
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
try {
    switch ($Action) {
        'Prepare'       { Initialize-Stand }
        'Seed'          {
            Import-Module Deduplication
            if (Test-Path "$DataRoot\base") { Log 'Удаление недописанного исходного набора от прошлого запуска...'; Remove-Item "$DataRoot\base" -Recurse -Force }
            Log "Создание исходного набора $SeedGB ГБ в $DataRoot\base..."
            Write-TestData -Dir "$DataRoot\base" -GB $SeedGB
            Log 'Оптимизация исходного набора...'
            $j = Invoke-Optimization
            Log ("Готово: {0} мин, результат: {1}" -f (N $j.Minutes 1), $j.Result)
            Show-Status
        }
        'Status'        { Show-Status }
        'Run'           { Start-Series; Show-Summary }
        'Summary'       { Show-Summary }
        'RealTimeSetup' { Set-RealTimeSchedule }
        'Intake'        { $h = (Get-Date).Hour; Write-TestData -Dir ('{0}\rt\{1:yyyyMMdd}\h{2:D2}' -f $DataRoot, (Get-Date), $h) -GB ((Get-DailyIntake) / 12)
                          Add-Event (Get-Date).DayOfYear $h 'intake' (Measure-Fast) (Get-SavedGB) }
        'Measure'       { $m = Measure-Fast
                          Add-CsvRow 'runs.csv' ([ordered]@{ Schedule = $Schedule; IntensityGB = (N $IntensityGB); Repeat = $Repeat
                              Run = ''; Day = (Get-Date).DayOfYear; Timestamp = (Get-Date -Format s); UnoptimizedGB = (N $m.UnoptGB)
                              LogicalGB = (N $m.LogicalGB); JobMinutes = ''; ResidualGB = ''; SavedGB = (N (Get-SavedGB)); JobResult = '' }) }
        'Backup'        { Invoke-WsbBackup (Get-Date).DayOfYear }
    }
}
catch {
    $msg = "ОШИБКА: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Log $msg
    if ($Action -eq 'Run') { Set-Content -Path (Join-Path $OutDir 'failed.txt') -Value $msg -Encoding UTF8 }
    throw
}
