<#
.SYNOPSIS
Gracefully shuts down all powered-on virtual machines in a selected vCenter cluster.

.DESCRIPTION
Connects to one vCenter Server using a PSCredential, lists clusters, sends a guest OS
shutdown request to every powered-on VM in the selected cluster, and polls vCenter until
all VMs report PoweredOff or the timeout expires. No hard power-off fallback is used.

.NOTES
Requires Windows, PowerShell 7+, WPF, and VMware.PowerCLI.
The guest shutdown operation requires VMware Tools or open-vm-tools to be installed and responsive.
#>
[CmdletBinding()]
param([switch]$NoRelaunch)

$Global:ClusterShutdownVersion = '1.6.0'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'


function Initialize-ScriptSignature {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path) -or -not $IsWindows) { return }
    try {
        $existing = Get-AuthenticodeSignature -FilePath $Path
        if ($existing.Status -eq 'Valid') { return }
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.NotAfter -gt (Get-Date).AddDays(1) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) {
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Local PowerShell Code Signing' `
                -CertStoreLocation 'Cert:\CurrentUser\My' -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(3)
        }
        $null = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert -HashAlgorithm SHA256
    } catch {
        Write-Warning "Automatic script signing was not completed: $($_.Exception.Message)"
    }
}

# Self-sign at launch, before the UI is created. A signature does not automatically trust the certificate elsewhere.
Initialize-ScriptSignature -Path $PSCommandPath

# Relaunch in STA so WPF works reliably.
try {
    $pwsh = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $pwsh) { $pwsh = 'pwsh.exe' }
} catch { $pwsh = 'pwsh.exe' }
try {
    if (-not $NoRelaunch -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "$PSCommandPath" -NoRelaunch
        exit $LASTEXITCODE
    }
} catch {}

$script:ReportsBase = (Get-Location).Path
$script:RunDir = $null
$Global:LogFile = $null
$script:VIServer = $null
$script:ClusterMap = @{}
$script:ShutdownInProgress = $false
$script:CancelRequested = $false
$script:PreviewRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$script:UpdatingSelectAll = $false

function New-RunDir {
    param([string]$Base)
    if ([string]::IsNullOrWhiteSpace($Base) -or -not (Test-Path -LiteralPath $Base)) {
        $Base = (Get-Location).Path
    }
    $dir = Join-Path $Base ("ClusterShutdown-Run-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Global:LogFile = Join-Path $dir ("ClusterShutdown-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    '' | Set-Content -LiteralPath $Global:LogFile -Encoding UTF8
    $script:RunDir = $dir
    return $dir
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try { if ($Global:LogFile) { Add-Content -LiteralPath $Global:LogFile -Value $line -Encoding UTF8 } } catch {}
    try {
        if ($script:txtLog) {
            $script:txtLog.AppendText("$line`r`n")
            $script:txtLog.ScrollToEnd()
        }
    } catch {}
    Write-Host $line
}

function Set-StatusText {
    param($Label, [string]$Text, [ValidateSet('OK','FAIL','WARN','INFO')][string]$State = 'INFO')
    if (-not $Label) { return }
    $colors = @{ OK='#7FD37F'; FAIL='#D97878'; WARN='#D6C15A'; INFO='#E6E6E6' }
    $Label.Text = $Text
    $Label.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($colors[$State])
}

function Show-InfoMessage {
    param([string]$Message, [string]$Title = 'vCenter Cluster Guest Shutdown')
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information') | Out-Null
}
function Show-ErrorMessage {
    param([string]$Message, [string]$Title = 'vCenter Cluster Guest Shutdown')
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
}

function Update-Window {
    try {
        $frame = New-Object Windows.Threading.DispatcherFrame
        [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; return $null },
            $frame
        ) | Out-Null
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch {}
}

function Prereq-Check {
    $ok = $true
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Set-StatusText $script:lblPS "PowerShell $($PSVersionTable.PSVersion)" OK
    } else {
        Set-StatusText $script:lblPS "PowerShell $($PSVersionTable.PSVersion), version 7+ required" FAIL
        $ok = $false
    }
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        Set-StatusText $script:lblWPF '.NET/WPF: Available' OK
    } else {
        Set-StatusText $script:lblWPF '.NET/WPF: Windows required' FAIL
        $ok = $false
    }
    $pcli = Get-Module -ListAvailable -Name VCF.PowerCLI,VMware.PowerCLI | Sort-Object Version -Descending | Select-Object -First 1
    $core = Get-Module -ListAvailable -Name VMware.VimAutomation.Core | Sort-Object Version -Descending | Select-Object -First 1
    if ($pcli -and $core) {
        Set-StatusText $script:lblPCLI "$($pcli.Name): $($pcli.Version); Core: $($core.Version)" OK
    } elseif ($core) {
        Set-StatusText $script:lblPCLI "VMware.VimAutomation.Core: $($core.Version)" WARN
    } else {
        Set-StatusText $script:lblPCLI 'VCF.PowerCLI: Not installed' FAIL
        $ok = $false
    }
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cert) { Set-StatusText $script:lblSigning "Code signing cert: $($cert.Subject)" OK }
    else { Set-StatusText $script:lblSigning 'Code signing cert: None (optional)' WARN }
    $script:PrereqsOK = $ok
    Refresh-UIState
}

function Set-Busy {
    param([bool]$Busy)
    $script:ShutdownInProgress = $Busy
    foreach ($control in @($script:btnRecheck,$script:btnConnect,$script:btnRefreshClusters,$script:cmbCluster,$script:txtVCenter,$script:txtUser,$script:pbPassword,$script:txtTimeout,$script:btnInstallPCLI)) {
        if ($control) { $control.IsEnabled = -not $Busy }
    }
    if ($script:btnCancel) { $script:btnCancel.IsEnabled = $Busy }
    Refresh-UIState
}

function Refresh-UIState {
    if (-not $script:btnShutdown) { return }
    $connected = $null -ne $script:VIServer -and $script:VIServer.IsConnected
    $selected = $null -ne $script:cmbCluster.SelectedItem
    $script:btnShutdown.IsEnabled = [bool]($script:PrereqsOK -and $connected -and $selected -and -not $script:ShutdownInProgress)
}

function Connect-SingleVCenter {
    param([string]$Server, [string]$Username, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Server)) { throw 'vCenter Server FQDN or IP is required.' }
    if ([string]::IsNullOrWhiteSpace($Username)) { throw 'Username is required.' }
    if ([string]::IsNullOrWhiteSpace($Password)) { throw 'Password is required.' }

    if (Get-Module -ListAvailable -Name VCF.PowerCLI | Select-Object -First 1) { Import-Module VCF.PowerCLI -ErrorAction Stop } else { Import-Module VMware.VimAutomation.Core -ErrorAction Stop }
    Set-PowerCLIConfiguration -Scope Session -DefaultVIServerMode Single -ParticipateInCEIP:$false -Confirm:$false | Out-Null
    if ($script:chkIgnoreCert.IsChecked) {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    }
    if ($script:VIServer) {
        Disconnect-VIServer -Server $script:VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $script:VIServer = $null
    }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = [pscredential]::new($Username, $secure)
    $script:VIServer = Connect-VIServer -Server $Server -Credential $credential -NotDefault:$false -ErrorAction Stop
    return $script:VIServer
}

function Populate-Clusters {
    if (-not $script:VIServer -or -not $script:VIServer.IsConnected) { throw 'Connect to vCenter first.' }
    $clusters = @(Get-Cluster -Server $script:VIServer | Sort-Object Name)
    $script:cmbCluster.Items.Clear()
    $script:ClusterMap = @{}
    foreach ($cluster in $clusters) {
        $label = '{0}  [{1}]' -f $cluster.Name, $cluster.Id
        [void]$script:cmbCluster.Items.Add($label)
        $script:ClusterMap[$label] = $cluster
    }
    if ($clusters.Count -gt 0) { $script:cmbCluster.SelectedIndex = 0 }
    $script:lblInventory.Text = "Clusters available: $($clusters.Count)"
    Write-Log "Loaded $($clusters.Count) cluster(s) from $($script:VIServer.Name)."
    Refresh-UIState
}

function Get-ClusterPoweredOnVMs {
    param($Cluster)
    return @(Get-VM -Location $Cluster -Server $script:VIServer | Where-Object { $_.PowerState -eq 'PoweredOn' } | Sort-Object Name)
}

function Set-AllVMSelections {
    param([bool]$Include)
    $script:UpdatingSelectAll = $true
    try {
        foreach ($row in $script:PreviewRows) { $row.Include = if ($row.Eligible) { $Include } else { $false } }
        $script:dgVMs.Items.Refresh()
        Update-PreviewCounts
        $action = if ($Include) { 'selected' } else { 'cleared' }
        Write-Log "Select All $action all eligible powered-on preview VM(s). Powered-off VMs remain visible but cannot be selected. Individual powered-on selections can still be changed."
    } finally { $script:UpdatingSelectAll = $false }
}

function Update-VMShutdownPreview {
    param($Cluster)
    $script:PreviewRows.Clear()
    if (-not $Cluster -or -not $script:VIServer -or -not $script:VIServer.IsConnected) {
        $script:lblTotal.Text = '0'
        $script:lblInventoryOn.Text = '0'
        $script:lblInventoryOff.Text = '0'
        $script:lblSelected.Text = '0'
        $script:lblExcluded.Text = '0'
        return
    }
    try {
        $vms = @(Get-VM -Location $Cluster -Server $script:VIServer | Sort-Object @{ Expression = { if ($_.PowerState -eq 'PoweredOn') { 0 } else { 1 } } }, Name)
        foreach ($vm in $vms) {
            $eligible = $vm.PowerState -eq 'PoweredOn'
            $script:PreviewRows.Add([pscustomobject]@{
                Include = [bool]$eligible
                Eligible = [bool]$eligible
                Name = $vm.Name
                PowerState = [string]$vm.PowerState
                ToolsStatus = [string]$vm.ExtensionData.Guest.ToolsStatus
                VMId = $vm.Id
                Request = 'Not started'
                Completed = ''
                Message = ''
            })
        }
        $script:dgVMs.ItemsSource = $script:PreviewRows
        Update-PreviewCounts
        $script:lblRunStatus.Text = "Review the VM list and clear Include for any VM that must remain powered on."
        $poweredOnCount = @($script:PreviewRows | Where-Object { $_.Eligible }).Count
        $poweredOffCount = $vms.Count - $poweredOnCount
        Write-Log "Preview loaded for cluster '$($Cluster.Name)': $($vms.Count) total VM(s), $poweredOnCount powered on, $poweredOffCount not powered on."
    } catch {
        Write-Log "VM preview failed: $($_.Exception.Message)" ERROR
        Show-ErrorMessage $_.Exception.Message 'Unable to load VM preview'
    }
}

function Update-PreviewCounts {
    $total = @($script:PreviewRows).Count
    $eligible = @($script:PreviewRows | Where-Object { $_.Eligible }).Count
    $poweredOff = $total - $eligible
    $selected = @($script:PreviewRows | Where-Object { $_.Eligible -and $_.Include }).Count
    $excluded = $eligible - $selected
    $script:lblTotal.Text = [string]$total
    $script:lblInventoryOn.Text = [string]$eligible
    $script:lblInventoryOff.Text = [string]$poweredOff
    $script:lblSelected.Text = [string]$selected
    $script:lblExcluded.Text = [string]$excluded
    if ($script:chkSelectAll -and -not $script:UpdatingSelectAll) {
        $script:UpdatingSelectAll = $true
        try {
            if ($eligible -eq 0 -or $selected -eq 0) { $script:chkSelectAll.IsChecked = $false }
            elseif ($selected -eq $eligible) { $script:chkSelectAll.IsChecked = $true }
            else { $script:chkSelectAll.IsChecked = $null }
        } finally { $script:UpdatingSelectAll = $false }
    }
    if (-not $script:ShutdownInProgress) {
        $script:lblRemaining.Text = [string]$selected
        $script:lblPoweredOff.Text = '0'
        $script:pbProgress.Minimum = 0
        $script:pbProgress.Maximum = [Math]::Max(1, $selected)
        $script:pbProgress.Value = 0
    }
}

function Invoke-ClusterGuestShutdown {
    param($Cluster, [int]$TimeoutMinutes, [object[]]$SelectedRows)

    $script:CancelRequested = $false
    $selectedIds = @($SelectedRows | ForEach-Object { $_.VMId })
    $initialVMs = @(Get-VM -Location $Cluster -Server $script:VIServer | Where-Object { $_.Id -in $selectedIds -and $_.PowerState -eq 'PoweredOn' } | Sort-Object Name)
    $total = $initialVMs.Count
    $results = [System.Collections.Generic.List[object]]::new()
    $tracked = @{}

    $script:lblTotal.Text = [string]$total
    $script:lblRemaining.Text = [string]$total
    $script:lblPoweredOff.Text = '0'
    $script:pbProgress.Minimum = 0
    $script:pbProgress.Maximum = [Math]::Max(1, $total)
    $script:pbProgress.Value = 0

    if ($total -eq 0) {
        Write-Log "Cluster '$($Cluster.Name)' has no powered-on VMs."
        Show-InfoMessage "Cluster '$($Cluster.Name)' has no powered-on virtual machines."
        return
    }

    foreach ($vm in $initialVMs) {
        $row = $SelectedRows | Where-Object { $_.VMId -eq $vm.Id } | Select-Object -First 1
        $row.Request = 'Pending'
        $row.Completed = ''
        $row.Message = ''
        $tracked[$vm.Id] = $row
        $results.Add($row) | Out-Null
    }
    $script:dgVMs.ItemsSource = $script:PreviewRows
    Update-Window

    Write-Log "Starting graceful guest shutdown for $total VM(s) in cluster '$($Cluster.Name)'. Timeout: $TimeoutMinutes minute(s)."
    foreach ($vm in $initialVMs) {
        $row = $tracked[$vm.Id]
        try {
            Shutdown-VMGuest -VM $vm -Server $script:VIServer -Confirm:$false -ErrorAction Stop | Out-Null
            $row.Request = 'Sent'
            $row.Message = 'Guest shutdown request accepted.'
            Write-Log "Guest shutdown sent to '$($vm.Name)'. Tools status: $($row.ToolsStatus)."
        } catch {
            $row.Request = 'Failed'
            $row.Message = $_.Exception.Message
            Write-Log "Guest shutdown request failed for '$($vm.Name)': $($_.Exception.Message)" ERROR
        }
        $script:dgVMs.Items.Refresh()
        Update-Window
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        if ($script:CancelRequested) {
            Write-Log 'Monitoring canceled by the operator. No hard power-off was issued.' WARN
            break
        }

        $current = @{}
        foreach ($vm in @(Get-VM -Location $Cluster -Server $script:VIServer)) { $current[$vm.Id] = $vm }
        $remaining = 0
        foreach ($id in $tracked.Keys) {
            $row = $tracked[$id]
            $vm = $current[$id]
            if ($null -eq $vm) {
                $row.PowerState = 'NotFound'
                if (-not $row.Completed) { $row.Completed = (Get-Date).ToString('s') }
            } elseif ($vm.PowerState -eq 'PoweredOff') {
                $row.PowerState = 'PoweredOff'
                if (-not $row.Completed) {
                    $row.Completed = (Get-Date).ToString('s')
                    Write-Log "'$($row.Name)' now reports PoweredOff."
                }
            } else {
                $row.PowerState = [string]$vm.PowerState
                $remaining++
            }
        }
        $off = $total - $remaining
        $script:lblRemaining.Text = [string]$remaining
        $script:lblPoweredOff.Text = [string]$off
        $script:pbProgress.Value = [Math]::Min($off, $script:pbProgress.Maximum)
        $script:lblRunStatus.Text = "Monitoring: $remaining of $total VM(s) still not powered off"
        $script:dgVMs.Items.Refresh()
        Update-Window

        if ($remaining -eq 0) { break }
        for ($i = 0; $i -lt 10 -and -not $script:CancelRequested; $i++) {
            Start-Sleep -Milliseconds 500
            Update-Window
        }
    } while ((Get-Date) -lt $deadline)

    # Final refresh and report.
    $current = @{}
    foreach ($vm in @(Get-VM -Location $Cluster -Server $script:VIServer)) { $current[$vm.Id] = $vm }
    foreach ($id in $tracked.Keys) {
        $row = $tracked[$id]
        if ($current.ContainsKey($id)) { $row.PowerState = [string]$current[$id].PowerState }
        if ($row.PowerState -ne 'PoweredOff' -and -not $row.Message.StartsWith('Guest shutdown request failed')) {
            $row.Message = if ($script:CancelRequested) { 'Monitoring canceled before powered-off status was observed.' } else { 'Did not report PoweredOff before timeout.' }
        }
    }

    $reportPath = Join-Path $script:RunDir ("ClusterShutdownResults-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $results | Select-Object Include,Name,PowerState,ToolsStatus,Request,Completed,Message | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    $notOff = @($results | Where-Object { $_.PowerState -ne 'PoweredOff' })
    $poweredOff = $total - $notOff.Count
    $script:lblRemaining.Text = [string]$notOff.Count
    $script:lblPoweredOff.Text = [string]$poweredOff
    $script:pbProgress.Value = [Math]::Min($poweredOff, $script:pbProgress.Maximum)
    $script:dgVMs.Items.Refresh()

    Write-Log "Shutdown monitoring finished. Total=$total, PoweredOff=$poweredOff, NotPoweredOff=$($notOff.Count). Report: $reportPath"
    if ($notOff.Count -eq 0) {
        $script:lblRunStatus.Text = 'Complete: all tracked VMs report PoweredOff'
        Set-StatusText $script:lblRunStatus $script:lblRunStatus.Text OK
        Show-InfoMessage "All $total VM(s) in cluster '$($Cluster.Name)' report PoweredOff.`n`nReport:`n$reportPath" 'Shutdown complete'
    } else {
        $script:lblRunStatus.Text = "Complete with exceptions: $($notOff.Count) VM(s) not powered off"
        Set-StatusText $script:lblRunStatus $script:lblRunStatus.Text WARN
        $names = ($notOff | Select-Object -ExpandProperty Name) -join "`n"
        Show-ErrorMessage "$($notOff.Count) of $total VM(s) did not report PoweredOff.`n`n$names`n`nNo hard power-off was attempted.`n`nReport:`n$reportPath" 'Shutdown completed with exceptions'
    }
}

function Install-OrRepairVCFPowerCLI {
    try {
        Set-Busy $true
        Set-StatusText $script:lblRunStatus 'Installing VCF.PowerCLI for CurrentUser...' INFO
        Write-Log 'Beginning VCF.PowerCLI installation/repair for CurrentUser.'
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -Confirm:$false | Out-Null
        }
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if (-not $repo) { Register-PSRepository -Default }
        Install-Module -Name VCF.PowerCLI -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        Import-Module VCF.PowerCLI -Force -ErrorAction Stop
        Write-Log 'VCF.PowerCLI installation/repair completed successfully.'
        Prereq-Check
        Show-InfoMessage 'VCF.PowerCLI was installed or repaired for the current user. The prerequisite display has been refreshed.' 'VCF PowerCLI ready'
    } catch {
        Write-Log "VCF.PowerCLI installation failed: $($_.Exception.Message)" ERROR
        Show-ErrorMessage "VCF.PowerCLI installation failed.`n`n$($_.Exception.Message)`n`nConfirm this workstation can reach PowerShell Gallery and that TLS inspection or repository policy is not blocking it." 'PowerCLI installation failed'
    } finally { Set-Busy $false }
}

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase -ErrorAction Stop | Out-Null
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="vCenter Cluster Guest Shutdown v1.6" Height="920" Width="1260" WindowStartupLocation="CenterScreen" Background="#050A0D" FontFamily="Segoe UI" Foreground="#E6E6E6">
<Window.Resources>
<SolidColorBrush x:Key="Panel2" Color="#0A1418"/><SolidColorBrush x:Key="Accent" Color="#29B6F6"/><SolidColorBrush x:Key="Text" Color="#E6E6E6"/><SolidColorBrush x:Key="Muted" Color="#9CB5C0"/>
<Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Margin" Value="0,4,8,4"/></Style>
<Style TargetType="TextBox"><Setter Property="Background" Value="#050A0D"/><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Margin" Value="0,2,8,8"/><Setter Property="Padding" Value="6"/></Style>
<Style TargetType="PasswordBox"><Setter Property="Background" Value="#050A0D"/><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Margin" Value="0,2,8,8"/><Setter Property="Padding" Value="6"/></Style>
<Style TargetType="ComboBox"><Setter Property="Background" Value="#050A0D"/><Setter Property="Foreground" Value="#111111"/><Setter Property="BorderBrush" Value="#607D8B"/><Setter Property="Margin" Value="0,2,8,8"/><Setter Property="Padding" Value="5"/></Style>
<Style TargetType="Button"><Setter Property="Background" Value="{StaticResource Accent}"/><Setter Property="Foreground" Value="#071218"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="0,4,8,4"/><Setter Property="MinWidth" Value="110"/></Style>
<Style TargetType="GroupBox"><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Background" Value="{StaticResource Panel2}"/><Setter Property="BorderBrush" Value="#2B4D59"/><Setter Property="Margin" Value="8"/><Setter Property="Padding" Value="10"/></Style>
<Style TargetType="DataGrid"><Setter Property="Background" Value="#050A0D"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="RowBackground" Value="#071116"/><Setter Property="AlternatingRowBackground" Value="#0B1A20"/><Setter Property="HeadersVisibility" Value="Column"/></Style>
<Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#0A1418"/><Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
</Window.Resources>
<Grid Margin="12"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="2*"/><RowDefinition Height="1*"/></Grid.RowDefinitions>
<Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="1.05*"/><ColumnDefinition Width="1.45*"/></Grid.ColumnDefinitions>
<GroupBox Header="Prerequisites / Output" Grid.Column="0"><StackPanel><WrapPanel><TextBlock Name="lblPS"/><TextBlock Name="lblWPF"/><TextBlock Name="lblPCLI"/><TextBlock Name="lblSigning"/></WrapPanel><StackPanel Orientation="Horizontal"><Button Name="btnRecheck" Content="Recheck"/><Button Name="btnInstallPCLI" Content="Install / Repair VCF PowerCLI" MinWidth="220"/><Button Name="btnOpenOut" Content="Open Output"/></StackPanel><TextBlock Name="lblRunStatus" Text="Ready" FontWeight="SemiBold" Foreground="{StaticResource Muted}"/></StackPanel></GroupBox>
<GroupBox Header="Single vCenter Connection" Grid.Column="1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="1.3*"/><ColumnDefinition Width="1*"/><ColumnDefinition Width="1*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Grid.Row="0" Grid.Column="0" Text="vCenter FQDN/IP"/><TextBlock Grid.Row="0" Grid.Column="1" Text="Username"/><TextBlock Grid.Row="0" Grid.Column="2" Text="Password"/>
<TextBox Grid.Row="1" Grid.Column="0" Name="txtVCenter"/><TextBox Grid.Row="1" Grid.Column="1" Name="txtUser"/><PasswordBox Grid.Row="1" Grid.Column="2" Name="pbPassword"/><Button Grid.Row="1" Grid.Column="3" Name="btnConnect" Content="Connect"/>
<CheckBox Grid.Row="2" Grid.ColumnSpan="2" Name="chkIgnoreCert" Content="Ignore untrusted vCenter certificate for this session" Foreground="{StaticResource Text}" IsChecked="True"/><TextBlock Grid.Row="2" Grid.Column="2" Grid.ColumnSpan="2" Name="lblConnection" Text="Not connected" Foreground="{StaticResource Muted}"/>
</Grid></GroupBox></Grid>
<GroupBox Grid.Row="1" Header="Cluster Selection"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="1.2*"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Cluster" VerticalAlignment="Top"/><ComboBox Grid.Column="0" Name="cmbCluster" Margin="0,28,8,8"/><Button Grid.Column="1" Name="btnRefreshClusters" Content="Refresh Clusters" VerticalAlignment="Bottom"/><TextBlock Grid.Column="2" Name="lblInventory" Text="Connect to vCenter to load clusters" VerticalAlignment="Center" Foreground="{StaticResource Muted}"/></Grid></GroupBox>
<GroupBox Grid.Row="2" Header="Graceful Guest OS Shutdown"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
<StackPanel Grid.Column="0" Margin="6"><TextBlock Text="Inventory"/><TextBlock Name="lblTotal" Text="0" FontSize="26" FontWeight="Bold"/></StackPanel><StackPanel Grid.Column="1" Margin="8,6"><TextBlock Text="Currently on"/><TextBlock Name="lblInventoryOn" Text="0" FontSize="26" FontWeight="Bold" Foreground="#29B6F6"/></StackPanel><StackPanel Grid.Column="2" Margin="8,6"><TextBlock Text="Already off"/><TextBlock Name="lblInventoryOff" Text="0" FontSize="26" FontWeight="Bold" Foreground="#9CB5C0"/></StackPanel><StackPanel Grid.Column="3" Margin="8,6"><TextBlock Text="Selected"/><TextBlock Name="lblSelected" Text="0" FontSize="26" FontWeight="Bold" Foreground="#29B6F6"/></StackPanel><StackPanel Grid.Column="4" Margin="8,6"><TextBlock Text="Excluded"/><TextBlock Name="lblExcluded" Text="0" FontSize="26" FontWeight="Bold" Foreground="#D6C15A"/></StackPanel><StackPanel Grid.Column="5" Margin="8,6"><TextBlock Text="Shut down now"/><TextBlock Name="lblPoweredOff" Text="0" FontSize="26" FontWeight="Bold" Foreground="#7FD37F"/></StackPanel><StackPanel Grid.Column="6" Margin="8,6"><TextBlock Text="Remaining"/><TextBlock Name="lblRemaining" Text="0" FontSize="26" FontWeight="Bold" Foreground="#D6C15A"/></StackPanel>
<StackPanel Grid.Column="7" Margin="10,6"><TextBlock Text="Progress"/><ProgressBar Name="pbProgress" Height="24" Minimum="0" Maximum="1" Value="0"/></StackPanel>
<StackPanel Grid.Column="8" Margin="6"><TextBlock Text="Timeout"/><TextBox Name="txtTimeout" Text="30" Width="65"/></StackPanel>
<StackPanel Grid.Column="9" Margin="6"><Button Name="btnShutdown" Content="Gracefully Shut Down Selected VMs" Background="#F2A65A" MinWidth="225"/><Button Name="btnCancel" Content="Stop Monitoring" Background="#607D8B" IsEnabled="False"/></StackPanel>
</Grid></GroupBox>
<GroupBox Grid.Row="3"><GroupBox.Header><StackPanel Orientation="Horizontal"><TextBlock Text="VM Status - All cluster VMs; only powered-on VMs are eligible" VerticalAlignment="Center"/><CheckBox Name="chkSelectAll" Content="Select All" IsThreeState="True" IsChecked="True" Foreground="{StaticResource Text}" Margin="18,0,0,0" ToolTip="Checked selects all powered-on VMs; unchecked clears all powered-on VMs; a filled state means the list contains a mix of selected and excluded VMs."/></StackPanel></GroupBox.Header><DataGrid Name="dgVMs" AutoGenerateColumns="False" IsReadOnly="False" CanUserAddRows="False"><DataGrid.Columns><DataGridCheckBoxColumn Header="Include" Binding="{Binding Include, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="75"><DataGridCheckBoxColumn.ElementStyle><Style TargetType="CheckBox"><Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="IsEnabled" Value="{Binding Eligible}"/></Style></DataGridCheckBoxColumn.ElementStyle><DataGridCheckBoxColumn.EditingElementStyle><Style TargetType="CheckBox"><Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="IsEnabled" Value="{Binding Eligible}"/></Style></DataGridCheckBoxColumn.EditingElementStyle></DataGridCheckBoxColumn><DataGridTextColumn Header="VM Name" Binding="{Binding Name}" IsReadOnly="True" Width="2*"/><DataGridTextColumn Header="Power State" Binding="{Binding PowerState}" IsReadOnly="True" Width="110"/><DataGridTextColumn Header="Tools Status" Binding="{Binding ToolsStatus}" IsReadOnly="True" Width="130"/><DataGridTextColumn Header="Request" Binding="{Binding Request}" IsReadOnly="True" Width="120"/><DataGridTextColumn Header="Completed" Binding="{Binding Completed}" IsReadOnly="True" Width="150"/><DataGridTextColumn Header="Message" Binding="{Binding Message}" IsReadOnly="True" Width="2*"/></DataGrid.Columns></DataGrid></GroupBox><GroupBox Grid.Row="4" Header="Output / Log"><TextBox Name="txtLog" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"/></GroupBox>
</Grid></Window>
"@

$script:window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in @('lblPS','lblWPF','lblPCLI','lblSigning','btnRecheck','btnInstallPCLI','btnOpenOut','lblRunStatus','txtVCenter','txtUser','pbPassword','btnConnect','chkIgnoreCert','lblConnection','cmbCluster','btnRefreshClusters','lblInventory','lblTotal','lblInventoryOn','lblInventoryOff','lblSelected','lblExcluded','lblPoweredOff','lblRemaining','pbProgress','txtTimeout','btnShutdown','btnCancel','chkSelectAll','dgVMs','txtLog')) {
    Set-Variable -Name $name -Scope Script -Value $script:window.FindName($name)
}

$script:window.Add_ContentRendered({
    if (-not $script:RunDir) { New-RunDir -Base $script:ReportsBase | Out-Null }
    Prereq-Check
    Write-Log "==== vCenter Cluster Guest Shutdown UI started v$Global:ClusterShutdownVersion ===="
    Write-Log "Run folder: $script:RunDir"
})
$script:window.Add_Closing({
    if ($script:ShutdownInProgress) {
        $_.Cancel = $true
        Show-InfoMessage 'Stop monitoring before closing the window.'
    } elseif ($script:VIServer) {
        Disconnect-VIServer -Server $script:VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
})
$script:btnRecheck.Add_Click({ Prereq-Check })
$script:btnInstallPCLI.Add_Click({ Install-OrRepairVCFPowerCLI })
$script:btnOpenOut.Add_Click({ try { Start-Process explorer.exe -ArgumentList "`"$script:RunDir`"" } catch { Show-ErrorMessage $_.Exception.Message } })
$script:btnConnect.Add_Click({
    try {
        Set-Busy $true
        $server = Connect-SingleVCenter -Server $script:txtVCenter.Text.Trim() -Username $script:txtUser.Text.Trim() -Password $script:pbPassword.Password
        Set-StatusText $script:lblConnection "Connected to $($server.Name) as $($server.User)" OK
        Write-Log "Connected to vCenter '$($server.Name)' as '$($server.User)'."
        Populate-Clusters
    } catch {
        $script:VIServer = $null
        Set-StatusText $script:lblConnection 'Connection failed' FAIL
        Write-Log "vCenter connection failed: $($_.Exception.Message)" ERROR
        Show-ErrorMessage $_.Exception.Message 'vCenter connection failed'
    } finally { Set-Busy $false }
})
$script:btnRefreshClusters.Add_Click({ try { Populate-Clusters } catch { Write-Log $_.Exception.Message ERROR; Show-ErrorMessage $_.Exception.Message } })
$script:cmbCluster.Add_SelectionChanged({ $cluster = $script:ClusterMap[[string]$script:cmbCluster.SelectedItem]; Update-VMShutdownPreview -Cluster $cluster; Refresh-UIState })
$script:dgVMs.Add_CurrentCellChanged({ Update-PreviewCounts })
$script:chkSelectAll.Add_Click({
    if ($script:UpdatingSelectAll) { return }
    $target = $script:chkSelectAll.IsChecked
    if ($null -eq $target) { $target = $true; $script:chkSelectAll.IsChecked = $true }
    Set-AllVMSelections -Include ([bool]$target)
})
$script:btnCancel.Add_Click({ $script:CancelRequested = $true; $script:btnCancel.IsEnabled = $false; Write-Log 'Operator requested monitoring cancellation.' WARN })
$script:btnShutdown.Add_Click({
    try {
        $label = [string]$script:cmbCluster.SelectedItem
        $cluster = $script:ClusterMap[$label]
        if (-not $cluster) { throw 'Select a cluster.' }
        $timeout = 0
        if (-not [int]::TryParse($script:txtTimeout.Text.Trim(), [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 1440) { throw 'Timeout must be an integer from 1 through 1440 minutes.' }
        $script:dgVMs.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true) | Out-Null
        $script:dgVMs.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
        Update-PreviewCounts
        $selectedRows = @($script:PreviewRows | Where-Object { $_.Eligible -and $_.Include })
        $excludedRows = @($script:PreviewRows | Where-Object { $_.Eligible -and -not $_.Include })
        if (@($script:PreviewRows | Where-Object { $_.Eligible }).Count -eq 0) { Show-InfoMessage "Cluster '$($cluster.Name)' has no powered-on virtual machines. Powered-off VMs remain listed for inventory visibility."; return }
        if ($selectedRows.Count -eq 0) { Show-ErrorMessage 'No VMs are selected. Select at least one VM or cancel the operation.' 'Nothing selected'; return }
        $answer = [System.Windows.MessageBox]::Show(
            "FIRST CONFIRMATION`n`nCluster: $($cluster.Name)`nCluster inventory VMs: $($script:PreviewRows.Count)`nCurrently powered on: $(@($script:PreviewRows | Where-Object { $_.Eligible }).Count)`nSelected for shutdown: $($selectedRows.Count)`nExcluded: $($excludedRows.Count)`n`nContinue to the final confirmation?",
            'Review shutdown scope','YesNo','Warning')
        if ($answer -ne 'Yes') { return }
        # Write the complete reviewed scope to disk before the final confirmation. This avoids an
        # oversized MessageBox for clusters containing hundreds of VMs while preserving a full audit list.
        $scopePath = Join-Path $script:RunDir ("ShutdownScope-{0}-{1}.txt" -f (($cluster.Name -replace '[^a-zA-Z0-9_.-]','_')), (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $scopeLines = [System.Collections.Generic.List[string]]::new()
        $scopeLines.Add("vCenter Cluster Guest Shutdown - Reviewed Scope") | Out-Null
        $scopeLines.Add("Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))") | Out-Null
        $scopeLines.Add("vCenter: $($script:VIServer.Name)") | Out-Null
        $scopeLines.Add("Cluster: $($cluster.Name)") | Out-Null
        $scopeLines.Add("Cluster inventory VMs reviewed: $($script:PreviewRows.Count)")
        $scopeLines.Add("Currently powered on: $(@($script:PreviewRows | Where-Object { $_.Eligible }).Count)")
        $scopeLines.Add("Already powered off: $(@($script:PreviewRows | Where-Object { -not $_.Eligible }).Count)") | Out-Null
        $scopeLines.Add("Selected for graceful shutdown: $($selectedRows.Count)") | Out-Null
        $scopeLines.Add("Excluded and left running: $($excludedRows.Count)") | Out-Null
        $scopeLines.Add('') | Out-Null
        $scopeLines.Add('SELECTED FOR GRACEFUL SHUTDOWN') | Out-Null
        $scopeLines.Add('================================') | Out-Null
        foreach ($row in ($selectedRows | Sort-Object Name)) { $scopeLines.Add($row.Name) | Out-Null }
        $scopeLines.Add('') | Out-Null
        $scopeLines.Add('EXCLUDED AND LEFT RUNNING') | Out-Null
        $scopeLines.Add('=========================') | Out-Null
        if ($excludedRows.Count) {
            foreach ($row in ($excludedRows | Sort-Object Name)) { $scopeLines.Add($row.Name) | Out-Null }
        } else { $scopeLines.Add('None') | Out-Null }
        $scopeLines | Set-Content -LiteralPath $scopePath -Encoding UTF8
        Write-Log "Reviewed shutdown scope saved: $scopePath"

        # Keep the final confirmation compact for large clusters. The complete selected and
        # excluded VM lists are available only in the reviewed scope file created above.
        $finalText = "FINAL CONFIRMATION`n`nCluster: $($cluster.Name)`nCluster inventory: $($script:PreviewRows.Count)`nCurrently powered on: $(@($script:PreviewRows | Where-Object { $_.Eligible }).Count)`nSelected for graceful shutdown: $($selectedRows.Count)`nExcluded and left running: $($excludedRows.Count)`nAlready powered off: $(@($script:PreviewRows | Where-Object { -not $_.Eligible }).Count)`n`nComplete reviewed VM list:`n$scopePath`n`nNo VM names are displayed in this confirmation window.`nNo hard power-off fallback will be used.`n`nProceed now?"
        $final = [System.Windows.MessageBox]::Show($finalText, 'FINAL confirmation - selected VMs only', 'YesNo', 'Warning')
        if ($final -ne 'Yes') {
            Write-Log "Final shutdown confirmation declined. Reviewed scope remains saved at: $scopePath" WARN
            return
        }
        Set-Busy $true
        Invoke-ClusterGuestShutdown -Cluster $cluster -TimeoutMinutes $timeout -SelectedRows $selectedRows
    } catch {
        Write-Log "Shutdown workflow failed: $($_.Exception.Message)" ERROR
        Show-ErrorMessage $_.Exception.Message 'Shutdown workflow failed'
    } finally { Set-Busy $false }
})

$null = $script:window.ShowDialog()

# SIG # Begin signature block
# MIIHqAYJKoZIhvcNAQcCoIIHmTCCB5UCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAoFRGauZBqsqK3
# 3YkYLemR+G+ibfDhOQE7HV4Sdncku6CCBGwwggRoMIIC0KADAgECAhBD4gjR2cwY
# tUDxDBD3yCrHMA0GCSqGSIb3DQEBCwUAMEwxSjBIBgNVBAMMQVZDRjkxIEVTWCBD
# b21taXNzaW9uaW5nIExvY2FsIENvZGUgU2lnbmluZyAoeGFkbWluQEhPTUVPRkZJ
# Q0VMQUIpMB4XDTI2MDYxMzE5NTE0OVoXDTMxMDYxMzIwMDE0OVowTDFKMEgGA1UE
# AwxBVkNGOTEgRVNYIENvbW1pc3Npb25pbmcgTG9jYWwgQ29kZSBTaWduaW5nICh4
# YWRtaW5ASE9NRU9GRklDRUxBQikwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGK
# AoIBgQC4LZnM0ddBbe1pe4S02wHpyupKLqBMwxPo0RrAgno+8qNUqtcqQ5UFaIcv
# pA5a/lllUM3/zbEjdNhe04c6nmRfDkALJJhjN1tzMaPooI9Lka6lj9lvIwc3Htg1
# zeAumdxk7Piej0+mANJYOW8r8YNjy2MAFtKLgdPB6/FLmE/LaNmkxixiUSpR1Z3+
# kx4ckgLVwu96+7gVpmsByfUyk3IKvWSENmBIkLCVgmZvgtX/56CUdnVZrwmGD5zG
# 9neNxU13Le4/sMdP1xZOjoYTwwBGl3bI5ljN0i4p9whmuN6aAqcpA/x5QT9qSowG
# iD3i1HS1oOTEqMlsFA/Q3iv8v8Vgzn2P9eQ7zCDb46rJaOJQ+oJlPdoDk947KzLW
# 0/cz8chIE+HiYA1bUs1hrzO8n4+u2j4IkNRRO0KqeTAmzf9fQGP+oRky02+MeN22
# ZeI0w/sBHE122v0uR+4xYmyPR159VSFyli75+VX1ZhiB7Ll7aT5gwJP3DdRmsuj9
# xUviKZUCAwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUF
# BwMDMB0GA1UdDgQWBBSpd8FTnsmNjr3A7Hv9y8NUAzyMHDANBgkqhkiG9w0BAQsF
# AAOCAYEAOwhwSfZ3KiSUBO4jhXtNYE4Hk54ndjV9n3A+9M1cl1Ukzkzw/Ex4158o
# G0YwX7l+bPuZeuYuYxKxMnSCmx7+uA054YivJUz0NA5XRMq10Mhm0b+1pRjUtkWd
# hc1sH+voJEqIO9T/Z6t96s+GDAz7u9aJbQ4NohIFiGP78Zf6j6lG/QWtk0/fV5Q8
# YwyDrUIjqOux6ep9tmmokSV5DevLtI0+pY3rnv8/qcXKNffAu0aydbK2LOsPPvIo
# gxpZbUZMj/nfrLXR6fiiXINWYi2yxqarVhMJm2YSyQpxZMiCMvhT6c9Y95DXc/fX
# H9lvakYtAtjqOjaxtc6qMP2gnzl/u3CHEANDVEHxHb6KonNfqXHYicJ1xF1fHyLa
# fSB9ApwNPlhfE/lEQzgC8O4lh+K299ZSIW06zzo6CAyYP7M6A1xCunjPmfX0Z06n
# N3QT98cTgAXnGC+ONiTEa964lE1P8BbLqE5lOdZ6ciEm9eKwlzoYZEVDDRI8nnN6
# WwZ2D6VyMYICkjCCAo4CAQEwYDBMMUowSAYDVQQDDEFWQ0Y5MSBFU1ggQ29tbWlz
# c2lvbmluZyBMb2NhbCBDb2RlIFNpZ25pbmcgKHhhZG1pbkBIT01FT0ZGSUNFTEFC
# KQIQQ+II0dnMGLVA8QwQ98gqxzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCA2MrUyj+J9
# YGrqGixJ/Q7eHrd3+TxT1dMGjl7hYk+UpjANBgkqhkiG9w0BAQEFAASCAYCxBoIb
# ecD6BG7xeMiOpXZjjtCxAm9kVv4Ew0EazQu34wZyamGgHhhJGtGUBf9HX0D+kKme
# pa2lK+MN9ocHuWXWrJR46V6PcxMol0fzCcw3aZWxIZywqxGwomZEK8nb+7C98z4Z
# Pz/fbLiLvYNuBMuhsE73KF8JORl56wKrmEENs/sU7lbBfPFxTzrZqlWXVAz+Mli+
# R/EkcD7Km3YIIbtqcODBVjG+aBJvgyJFc0d0UDHduRkQbnOy8tDP8reoQK9hrfYa
# uBxqOvrAZi7hs3A3MUSVjhGNFCR6y372Q6KAkhb7yqK9EwrZC1Mt3qgiWqXDHI2W
# VVOuAmTMU+N0gK7RvlBNlrY48K6dO7qfqyE+fbUNpXFkFzuupBQ4Ifr4vqxotW9V
# bEC8fQtqmLXmHMkbpy3odG4/xY1l+diY20sbY6hacSxaa8flD+L8Eq4wwPOZ3HSM
# QEMOv+Z+rg1iLJCE7PbDWpgRqfjTykb12I9hIfP8UR6X1NU/boVC8RHTHwQ=
# SIG # End signature block
