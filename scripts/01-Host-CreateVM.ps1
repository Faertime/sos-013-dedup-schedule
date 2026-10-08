<#
.SYNOPSIS
  Создание виртуальной машины стенда в Hyper-V (п. 4.2 протокола).
  Запускается на хосте от имени администратора.

.DESCRIPTION
  ВМ 2-го поколения: 4 vCPU, 8 ГБ ОЗУ (статическая память), ISO Windows Server 2025 в DVD-приводе.
  Диски создаются в папке F:\HyperV\<имя ВМ>:
    os.vhdx     - системный диск, 80 ГБ;
    data.vhdx   - диск данных, 200 ГБ (в ВМ - том E:);
    backup.vhdx - диск резервных копий, 300 ГБ (в ВМ - том G:).
  Диски динамические и занимают на хосте фактически записанный объем.
  Для полного прогона нужно около 300 ГБ свободного места на диске F: (NTFS).

.EXAMPLE
  .\01-Host-CreateVM.ps1 -IsoPath 'F:\ISO\WS2025.iso'
  .\01-Host-CreateVM.ps1 -IsoPath 'F:\ISO\WS2025.iso' -Replace    # пересоздать ВМ
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$IsoPath,
    [string]$VMName = 'WS2025-DEDUP',
    [string]$VMPath = 'F:\HyperV',
    [int]$CPU = 4,
    [int]$MemoryGB = 8,
    [string]$SwitchName = 'Default Switch',  # сеть для эксперимента не нужна, управление идет через PowerShell Direct
    [switch]$Replace                         # удалить существующую ВМ с этим именем вместе с ее дисками
)
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V

if (-not (Test-Path $IsoPath)) { throw "ISO не найден: $IsoPath" }
$old = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($old) {
    if (-not $Replace) { throw "ВМ $VMName уже существует. Укажите ключ -Replace (старая ВМ и ее диски будут удалены) или другое имя (-VMName)." }
    Write-Warning "Удаление существующей ВМ $VMName и ее дисков..."
    $oldDisks = @((Get-VMHardDiskDrive -VM $old).Path)
    Stop-VM -VM $old -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -VM $old -Force
    foreach ($d in $oldDisks) { Remove-Item $d -Force -ErrorAction SilentlyContinue }
    if ($oldDisks.Count -gt 0) {
        $oldDir = Split-Path $oldDisks[0]
        if ((Split-Path $oldDir -Leaf) -eq $VMName) { Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$dir = Join-Path $VMPath $VMName
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$drv = $dir.Substring(0, 1)
$fs = (Get-Volume -DriveLetter $drv).FileSystem
if ($fs -notin 'NTFS', 'ReFS') { throw "Диск $($drv): имеет файловую систему $fs. Диски ВМ Hyper-V можно размещать только на NTFS или ReFS." }
$free = (Get-PSDrive $drv).Free / 1GB
Write-Host ("Свободно на диске {0}: {1:N0} ГБ (нужно не меньше 300 ГБ)" -f $drv, $free)
if ($free -lt 300) { Write-Warning 'Места может не хватить. Освободите место или укажите другой диск (-VMPath).' }

$os   = Join-Path $dir 'os.vhdx'
$data = Join-Path $dir 'data.vhdx'
$bak  = Join-Path $dir 'backup.vhdx'

$vmArgs = @{ Name = $VMName; Generation = 2; MemoryStartupBytes = ($MemoryGB * 1GB); Path = $VMPath
             NewVHDPath = $os; NewVHDSizeBytes = 80GB }
if ($SwitchName -and (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { $vmArgs.SwitchName = $SwitchName }
else { Write-Warning "Коммутатор '$SwitchName' не найден, ВМ создается без сети." }
New-VM @vmArgs | Out-Null

Set-VM -Name $VMName -ProcessorCount $CPU -StaticMemory -AutomaticCheckpointsEnabled $false -CheckpointType Production
New-VHD -Path $data -SizeBytes 200GB -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $VMName -Path $data
New-VHD -Path $bak -SizeBytes 300GB -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $VMName -Path $bak
Add-VMDvdDrive -VMName $VMName -Path $IsoPath
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMDvdDrive -VMName $VMName)
# Интерфейс гостевой службы. В русской Windows имя компонента переведено, поэтому ищем по ID.
# Для эксперимента он не обязателен: скрипты работают через PowerShell Direct.
Get-VMIntegrationService -VMName $VMName |
    Where-Object { $_.Id -match '6C09BB55-D683-4DA0-8931-C9BF705F6480' -or $_.Name -match 'Guest Service|гостевой службы' } |
    Enable-VMIntegrationService -ErrorAction SilentlyContinue

Get-VM -Name $VMName | Format-List Name, Generation, ProcessorCount, MemoryStartup, State, CheckpointType
Get-VMHardDiskDrive -VMName $VMName | Format-Table ControllerLocation, Path -AutoSize

Start-VM -Name $VMName
Write-Host "`nВМ запущена. В окне подключения нажмите любую клавишу для загрузки с DVD"
Write-Host "и установите Windows Server 2025 (п. 4.3 протокола)."
Start-Process vmconnect.exe -ArgumentList 'localhost', $VMName
