$VHDXLocations = @("F:\Public\User\*\CsProfiles.VHDX", "D:\Public\User\*\CsProfiles.VHDX")

$LogPath = ".\FSLogix-Shrinking-Logs"

function Start-DiskShrinker {

    [CmdletBinding()]

    Param (
    
        [Parameter(Position = 1, ValuefromPipelineByPropertyName = $true, ValuefromPipeline = $true, Mandatory = $true)][System.String]$Path,
        [Parameter(ValuefromPipelineByPropertyName = $true)][double]$IgnoreLessThanGB = 0,
        [Parameter(ValuefromPipelineByPropertyName = $true)][int]$DeleteOlderThanDays,
        [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$RollingLog,
        [Parameter(ValuefromPipelineByPropertyName = $true)]
        [System.String]$LogFilePath = "$env:TEMP\FslShrinkDisk $(Get-Date -Format yyyy-MM-dd` HH-mm-ss).csv",
        [Parameter(ValuefromPipelineByPropertyName = $true)][switch]$PassThru,
        [Parameter(ValuefromPipelineByPropertyName = $true)][int]$ThrottleLimit = 4,
        [Parameter(ValuefromPipelineByPropertyName = $true)]
        [ValidateRange(0,1)]
        [double]$RatioFreeSpace = 0.05

    )
    
    BEGIN {

        Set-StrictMode -Version Latest
        function Test-FslDependencies {
            [CmdletBinding()]
            Param ([Parameter(Mandatory = $true,Position = 0,ValueFromPipelineByPropertyName = $true,ValueFromPipeline = $true)][System.String[]]$Name)
            BEGIN { Set-StrictMode -Version Latest}
            PROCESS {
    
                Foreach ($svc in $Name) {
                    $svcObject = Get-Service -Name $svc
                    if ($svcObject.Status -eq "Running") { Return }
                    if ($svcObject.StartType -eq "Disabled") {
                        Write-Warning ("[{0}] Setting Service to Manual" -f $svcObject.DisplayName)
                        Set-Service -Name $svc -StartupType Manual | Out-Null
                    }
                    Start-Service -Name $svc | Out-Null
                    if ((Get-Service -Name $svc).Status -ne 'Running') { Write-Error "Can not start $svcObject.DisplayName" }
                }
            }

            end {}
        }
        function Invoke-Parallel {
 
            [cmdletbinding(DefaultParameterSetName = 'ScriptBlock')]

            Param (

                [Parameter(Mandatory = $false, position = 0, ParameterSetName = 'ScriptBlock')]
                [System.Management.Automation.ScriptBlock]$ScriptBlock,
                [Parameter(Mandatory = $false, ParameterSetName = 'ScriptFile')]
                [ValidateScript( { Test-Path $_ -pathtype leaf })]$ScriptFile,
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [Alias('CN', '__Server', 'IPAddress', 'Server', 'ComputerName')]
                [PSObject]$InputObject,
                [PSObject]$Parameter,
                [switch]$ImportVariables,
                [switch]$ImportModules,
                [switch]$ImportFunctions,
                [int]$Throttle = 20,
                [int]$SleepTimer = 200,
                [int]$RunspaceTimeout = 0,
                [switch]$NoCloseOnTimeout = $false,
                [int]$MaxQueue,
                [validatescript( { Test-Path (Split-Path $_ -parent) })]
                [switch] $AppendLog = $false,
                [string]$LogFile,
                [switch] $Quiet = $false

            )
            begin {

                if ( -not $PSBoundParameters.ContainsKey('MaxQueue') ) {

                    if ($RunspaceTimeout -ne 0) { $script:MaxQueue = $Throttle }
                    else { $script:MaxQueue = $Throttle * 3 }

                } else { $script:MaxQueue = $MaxQueue }


                $ProgressId = Get-Random
                Write-Verbose "Throttle: '$throttle' SleepTimer '$sleepTimer' runSpaceTimeout '$runspaceTimeout' maxQueue '$maxQueue' logFile '$logFile'"
    
                if ($ImportVariables -or $ImportModules -or $ImportFunctions) {
                    $StandardUserEnv = [powershell]::Create().addscript( {
    
                            $Modules = Get-Module | Select-Object -ExpandProperty Name
                            $Snapins = Get-PSSnapin | Select-Object -ExpandProperty Name
                            $Functions = Get-ChildItem function:\ | Select-Object -ExpandProperty Name
    
                            $Variables = Get-Variable | Select-Object -ExpandProperty Name
    
                            @{
                                Variables = $Variables
                                Modules   = $Modules
                                Snapins   = $Snapins
                                Functions = $Functions
                            }
                        }, $true).invoke()[0]
    
                    if ($ImportVariables) {

                        function _temp { [cmdletbinding(SupportsShouldProcess = $True)] param() }
                        $VariablesToExclude = @( (Get-Command _temp | Select-Object -ExpandProperty parameters).Keys + $PSBoundParameters.Keys + $StandardUserEnv.Variables )
                        Write-Verbose "Excluding variables $( ($VariablesToExclude | Sort-Object ) -join ", ")"
                        $UserVariables = @( Get-Variable | Where-Object { -not ($VariablesToExclude -contains $_.Name) } )
                        Write-Verbose "Found variables to import: $( ($UserVariables | Select-Object -expandproperty Name | Sort-Object ) -join ", " | Out-String).`n"
                    }
                    if ($ImportModules) {
                        $UserModules = @( Get-Module | Where-Object { $StandardUserEnv.Modules -notcontains $_.Name -and (Test-Path $_.Path -EA 0) } | Select-Object -ExpandProperty Path )
                        $UserSnapins = @( Get-PSSnapin | Select-Object -ExpandProperty Name | Where-Object { $StandardUserEnv.Snapins -notcontains $_ } )
                    }
                    if ($ImportFunctions) { $UserFunctions = @( Get-ChildItem function:\ | Where-Object { $StandardUserEnv.Functions -notcontains $_.Name } ) }
                }
    
                function Get-RunspaceData {
                    [cmdletbinding()]
                    param( [switch]$Wait )
                    Do {

                        $more = $false
                        if (-not $Quiet) {
                            Write-Progress -Id $ProgressId -Activity "Running Query" -Status "Starting threads"`
                                -CurrentOperation "$startedCount threads defined - $totalCount input objects - $script:completedCount input objects processed"`
                                -PercentComplete $( Try { $script:completedCount / $totalCount * 100 } Catch { 0 } )
                        }
    
                        Foreach ($runspace in $runspaces) {
    
                            $currentdate = Get-Date
                            $runtime = $currentdate - $runspace.startTime
                            $runMin = [math]::Round( $runtime.totalminutes , 2 )
    
                            $log = "" | Select-Object Date, Action, Runtime, Status, Details
                            $log.Action = "Removing:'$($runspace.object)'"
                            $log.Date = $currentdate
                            $log.Runtime = "$runMin minutes"
    
                            if ($runspace.Runspace.isCompleted) {
    
                                $script:completedCount++
                                if ($runspace.powershell.Streams.Error.Count -gt 0) {
                                    $log.status = "CompletedWithErrors"
                                    Write-Verbose ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1]
                                    foreach ($ErrorRecord in $runspace.powershell.Streams.Error) { Write-Error -ErrorRecord $ErrorRecord }
                                }
                                else {

                                    $log.status = "Completed"
                                    Write-Verbose ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1]
                                }
    
                                $runspace.powershell.EndInvoke($runspace.Runspace)
                                $runspace.powershell.dispose()
                                $runspace.Runspace = $null
                                $runspace.powershell = $null
                            }

                            elseif ( $runspaceTimeout -ne 0 -and $runtime.totalseconds -gt $runspaceTimeout) {
                                $script:completedCount++
                                $timedOutTasks = $true
    
                                $log.status = "TimedOut"
                                Write-Verbose ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1]
                                Write-Error "Runspace timed out at $($runtime.totalseconds) seconds for the object:`n$($runspace.object | out-string)"
    
                                if (!$noCloseOnTimeout) { $runspace.powershell.dispose() }
                                $runspace.Runspace = $null
                                $runspace.powershell = $null
                                $completedCount++
                            }
    
                            elseif ($runspace.Runspace -ne $null ) {
                                $log = $null
                                $more = $true
                            }

                            if ($logFile -and $log) { ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1] | out-file $LogFile -append }
                        }
    
                        $temphash = $runspaces.clone()
                        $temphash | Where-Object { $_.runspace -eq $Null } | % { $Runspaces.remove($_) }
                        if ($PSBoundParameters['Wait']) { Start-Sleep -milliseconds $SleepTimer }
    
                    } while ($more -and $PSBoundParameters['Wait'])
    
                }
    
                if ($PSCmdlet.ParameterSetName -eq 'ScriptFile') { $ScriptBlock = [scriptblock]::Create( $(Get-Content $ScriptFile | out-string) ) }
                elseif ($PSCmdlet.ParameterSetName -eq 'ScriptBlock') {

                    [string[]]$ParamsToAdd = '$_'
                    if ( $PSBoundParameters.ContainsKey('Parameter') ) { $ParamsToAdd += '$Parameter' }
                    $UsingVariableData = $Null
    
                    if ($PSVersionTable.PSVersion.Major -gt 2) {

                        $UsingVariables = $ScriptBlock.ast.FindAll( { $args[0] -is [System.Management.Automation.Language.UsingExpressionAst] }, $True)
    
                        if ($UsingVariables) {
                            $List = New-Object 'System.Collections.Generic.List`1[System.Management.Automation.Language.VariableExpressionAst]'
                            ForEach ($Ast in $UsingVariables) { [void]$list.Add($Ast.SubExpression) }
                            $UsingVar = $UsingVariables | Group-Object -Property SubExpression | % { $_.Group | Select-Object -First 1 }
    
                            $UsingVariableData = ForEach ($Var in $UsingVar) {
                                try {
                                    $Value = Get-Variable -Name $Var.SubExpression.VariablePath.UserPath -ErrorAction Stop
                                    [pscustomobject]@{
                                        Name       = $Var.SubExpression.Extent.Text
                                        Value      = $Value.Value
                                        NewName    = ('$__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                        NewVarName = ('__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                    }
                                }
                                catch { Write-Error "$($Var.SubExpression.Extent.Text) is not a valid Using: variable!" }
                            }
                            $ParamsToAdd += $UsingVariableData | Select-Object -ExpandProperty NewName -Unique
                            $NewParams = $UsingVariableData.NewName -join ', '
                            $Tuple = [Tuple]::Create($list, $NewParams)
                            $bindingFlags = [Reflection.BindingFlags]"Default,NonPublic,Instance"
                            $GetWithInputHandlingForInvokeCommandImpl = ($ScriptBlock.ast.gettype().GetMethod('GetWithInputHandlingForInvokeCommandImpl', $bindingFlags))
                            $StringScriptBlock = $GetWithInputHandlingForInvokeCommandImpl.Invoke($ScriptBlock.ast, @($Tuple))
                            $ScriptBlock = [scriptblock]::Create($StringScriptBlock)
                            Write-Verbose $StringScriptBlock
                        }
                    }
    
                    $ScriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock("param($($ParamsToAdd -Join ", "))`r`n" + $Scriptblock.ToString())
                }
                else { Throw "Must provide ScriptBlock or ScriptFile"; Break }
                Write-Debug "`$ScriptBlock: $($ScriptBlock | Out-String)"
                Write-Verbose "Creating runspace pool and session states"
    
                $sessionstate = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                if ($ImportVariables -and $UserVariables.count -gt 0) {
                    foreach ($Variable in $UserVariables) {
                        $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Variable.Name, $Variable.Value, $null) )
                    }
                }
                if ($ImportModules) {
                    if ($UserModules.count -gt 0) { foreach ($ModulePath in $UserModules) { $sessionstate.ImportPSModule($ModulePath) } }
                    if ($UserSnapins.count -gt 0) { foreach ($PSSnapin in $UserSnapins) { [void]$sessionstate.ImportPSSnapIn($PSSnapin, [ref]$null) } }
                }
                if ($ImportFunctions -and $UserFunctions.count -gt 0) {
                    foreach ($FunctionDef in $UserFunctions) { $sessionstate.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $FunctionDef.Name, $FunctionDef.ScriptBlock)) }
                }
    
                $runspacepool = [runspacefactory]::CreateRunspacePool(1, $Throttle, $sessionstate, $Host)
                $runspacepool.Open()
                Write-Verbose "Creating empty collection to hold runspace jobs"
                $Script:runspaces = New-Object System.Collections.ArrayList
                $bound = $PSBoundParameters.keys -contains "InputObject"
                if (-not $bound) { [System.Collections.ArrayList]$allObjects = @() }
    
                if ( $LogFile -and (-not (Test-Path $LogFile) -or $AppendLog -eq $false)) {
                    New-Item -ItemType file -Path $logFile -Force | Out-Null
                    ("" | Select-Object -Property Date, Action, Runtime, Status, Details | ConvertTo-Csv -NoTypeInformation -Delimiter ";")[0] | Out-File $LogFile
                }
    
                $log = "" | Select-Object -Property Date, Action, Runtime, Status, Details
                $log.Date = Get-Date
                $log.Action = "Batch processing started"
                $log.Runtime = $null
                $log.Status = "Started"
                $log.Details = $null
                if ($logFile) { ($log | convertto-csv -Delimiter ";" -NoTypeInformation)[1] | Out-File $LogFile -Append }
                $timedOutTasks = $false

            }
            process {

                if ($bound) { $allObjects = $InputObject }
                else { [void]$allObjects.add( $InputObject ) }
            }
            end {

                try {

                    $totalCount = $allObjects.count
                    $script:completedCount = 0
                    $startedCount = 0
                    foreach ($object in $allObjects) {

                        $powershell = [powershell]::Create()
                        if ($VerbosePreference -eq 'Continue') { [void]$PowerShell.AddScript( { $VerbosePreference = 'Continue' }) }
                        [void]$PowerShell.AddScript($ScriptBlock).AddArgument($object)
                        if ($parameter) { [void]$PowerShell.AddArgument($parameter) }
    
                        if ($UsingVariableData) {
                            Foreach ($UsingVariable in $UsingVariableData) {
                                Write-Verbose "Adding $($UsingVariable.Name) with value: $($UsingVariable.Value)"
                                [void]$PowerShell.AddArgument($UsingVariable.Value)
                            }
                        }
    
                        $powershell.RunspacePool = $runspacepool
    
                        $temp = "" | Select-Object PowerShell, StartTime, object, Runspace
                        $temp.PowerShell = $powershell
                        $temp.StartTime = Get-Date
                        $temp.object = $object
    
                        $temp.Runspace = $powershell.BeginInvoke()
                        $startedCount++
    
                        Write-Verbose ( "Adding {0} to collection at {1}" -f $temp.object, $temp.starttime.tostring() )
                        $runspaces.Add($temp) | Out-Null
    
                        Get-RunspaceData
    
                        $firstRun = $true
                        while ($runspaces.count -ge $Script:MaxQueue) {

                            if ($firstRun) { Write-Verbose "$($runspaces.count) items running - exceeded $Script:MaxQueue limit." }
                            $firstRun = $false
                            Get-RunspaceData
                            Start-Sleep -Milliseconds $sleepTimer
                        }
                    }
                    Write-Verbose ( "Finish processing the remaining runspace jobs: {0}" -f ( @($runspaces | Where-Object { $_.Runspace -ne $Null }).Count) )
    
                    Get-RunspaceData -wait
                    if (-not $quiet) {
                        Write-Progress -Id $ProgressId -Activity "Running Query" -Status "Starting threads" -Completed
                    }
                }
                finally {

                    if ( ($timedOutTasks -eq $false) -or ( ($timedOutTasks -eq $true) -and ($noCloseOnTimeout -eq $false) ) ) {
                        Write-Verbose "Closing the runspace pool"
                        $runspacepool.close()
                    }

                    [gc]::Collect()
                }
            }
        }
        function Mount-FslDisk {
            [CmdletBinding()]
    
            Param (

                [Parameter(Position = 1,ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true,Mandatory = $true)][alias('FullName')][System.String]$Path,
                [Parameter(ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true)][Int]$TimeOut = 3,    
                [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$PassThru

            )
    
            BEGIN { Set-StrictMode -Version Latest }

            PROCESS {
            
                try {
                    $mountedDisk = Mount-DiskImage -ImagePath $Path -NoDriveLetter -PassThru -ErrorAction Stop
                }
                catch {
                    $e = $error[0]
                    Write-Error "Failed to mount disk - `"$e`""
                    return
                }
    
    
                $diskNumber = $false
                $timespan = (Get-Date).AddSeconds($TimeOut)
                while ($diskNumber -eq $false -and $timespan -gt (Get-Date)) {
                    Start-Sleep 0.1
                    try {
                        $mountedDisk = Get-DiskImage -ImagePath $Path
                        if ($mountedDisk.Number) { $diskNumber = $true }
                    }
                    catch { $diskNumber = $false }
    
                }
    
                if ($diskNumber -eq $false) {
                    try { $mountedDisk | Dismount-DiskImage -EA 0 }
                    catch { Write-Error 'Could not dismount Disk Due to no Disknumber' }
                    Write-Error 'Cannot get mount information'
                    return
                }
    
                $partitionType = $false
                $timespan = (Get-Date).AddSeconds($TimeOut)
                while ($partitionType -eq $false -and $timespan -gt (Get-Date)) {
    
                    try {
                        $allPartition = Get-Partition -DiskNumber $mountedDisk.Number -ErrorAction Stop
    
                        if ($allPartition.Type -contains 'Basic') {
                            $partitionType = $true
                            $partition = $allPartition | Where-Object -Property 'Type' -EQ -Value 'Basic'
                        }

                    }
                    catch {

                        if (($allPartition | Measure-Object).Count -gt 0) {
                            $partition = $allPartition | Select-Object -Last 1
                            $partitionType = $true
                        }

                        else{ $partitionType = $false }
    
                    }
                    Start-Sleep 0.1
                }
    
                if ($partitionType -eq $false) {
                    try { $mountedDisk | Dismount-DiskImage -EA 0 }
                    catch { Write-Error 'Could not dismount disk with no partition' }
                    Write-Error 'Cannot get partition information'
                    return
                }
    
                $tempGUID = [guid]::NewGuid().ToString()
                $mountPath = Join-Path $Env:Temp ('FSLogixMnt-' + $tempGUID)
    
                try { New-Item -Path $mountPath -ItemType Directory -ErrorAction Stop | Out-Null }
                catch {
                    $e = $error[0]
                    try { $mountedDisk | Dismount-DiskImage -EA 0 }
                    catch { Write-Error "Could not dismount disk when no folder could be created - `"$e`"" }
                    Write-Error "Failed to create mounting directory - `"$e`""
                    return
                }
    
                try {
                    $addPartitionAccessPathParams = @{
                        DiskNumber      = $mountedDisk.Number
                        PartitionNumber = $partition.PartitionNumber
                        AccessPath      = $mountPath
                        ErrorAction     = 'Stop'
                    }
    
                    Add-PartitionAccessPath @addPartitionAccessPathParams
                }
                catch {
                    $e = $error[0]
                    Remove-Item -Path $mountPath -Force -Recurse -EA 0
                    try { $mountedDisk | Dismount-DiskImage -EA 0 }
                    catch { Write-Error "Could not dismount disk when no junction point could be created - `"$e`"" }
                    Write-Error "Failed to create junction point to - `"$e`""
                    return
                }
    
                if ($PassThru) {

                    $output = [PSCustomObject]@{
                        Path       = $mountPath
                        DiskNumber = $mountedDisk.Number
                        ImagePath  = $mountedDisk.ImagePath
                        PartitionNumber = $partition.PartitionNumber
                    }
                    Write-Output $output
                }
                Write-Verbose "Mounted $Path to $mountPath"
            }

            end { }
        }
        function Dismount-FslDisk {
            [CmdletBinding()]
    
            Param (

                [Parameter(Position = 1,ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true,Mandatory = $true)][String]$Path,
                [Parameter(ValuefromPipelineByPropertyName = $true,Mandatory = $true)][String]$ImagePath,
                [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$PassThru,
                [Parameter(ValuefromPipelineByPropertyName = $true)][Int]$Timeout = 120

            )
    
            BEGIN { Set-StrictMode -Version Latest }
            PROCESS {
    
                $mountRemoved = $false
                $directoryRemoved = $false
                $timeStampDirectory = (Get-Date).AddSeconds(20)
                while ((Get-Date) -lt $timeStampDirectory -and $directoryRemoved -ne $true) {
                    try {
                        Remove-Item -Path $Path -Force -Recurse -ErrorAction Stop | Out-Null
                        $directoryRemoved = $true
                    }
                    catch { $directoryRemoved = $false }
                }
                if (Test-Path $Path) { Write-Warning "Failed to delete temp mount directory $Path" }
    
    
                $timeStampDismount = (Get-Date).AddSeconds($Timeout)
                while ((Get-Date) -lt $timeStampDismount -and $mountRemoved -ne $true) {
                    try {
                        Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null
                        try {
                            $image = Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop
    
                            switch ($image.Attached) {
                                $null { $mountRemoved = $false ; Start-Sleep 0.1; break }
                                $true { $mountRemoved = $false ; break}
                                $false { $mountRemoved = $true ; break }
                                Default { $mountRemoved = $false }
                            }
                        }
                        catch { $mountRemoved = $false }
                    }
                    catch { $mountRemoved = $false }
                }
                if ($mountRemoved -ne $true) { Write-Error "Failed to dismount disk $ImagePath" }
    
                if ($PassThru) {
                    $output = [PSCustomObject]@{
                        MountRemoved         = $mountRemoved
                        DirectoryRemoved     = $directoryRemoved
                    }
                    Write-Output $output
                }
                if ($directoryRemoved -and $mountRemoved) { Write-Verbose "Dismounted $ImagePath" }
    
            } 
            end { }
        }
        function Optimize-OneDisk {
            [CmdletBinding()]
    
            Param (

                [Parameter(ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true,Mandatory = $true)][System.IO.FileInfo]$Disk,
                [Parameter(ValuefromPipelineByPropertyName = $true)][Int]$DeleteOlderThanDays,
                [Parameter(ValuefromPipelineByPropertyName = $true)][Int]$IgnoreLessThanGB,
                [Parameter(ValuefromPipelineByPropertyName = $true)][double]$RatioFreeSpace = 0.05,
                [Parameter(ValuefromPipelineByPropertyName = $true)][int]$MountTimeout = 30,
                [Parameter(ValuefromPipelineByPropertyName = $true)][string]$LogFilePath = "$env:TEMP\FslShrinkDisk $(Get-Date -Format yyyy-MM-dd` HH-mm-ss).csv",
                [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$RollingLog,
                [Parameter(ValuefromPipelineByPropertyName = $true)][switch]$Passthru
    
            )
    
            BEGIN {

                Set-StrictMode -Version Latest
                $hyperv = $false

            }
            PROCESS {

                Dismount-DiskImage -ImagePath $Disk.FullName -EA 0
                $startTime = Get-Date
                if ( $IgnoreLessThanGB ) {
                    $IgnoreLessThanBytes = $IgnoreLessThanGB * 1024 * 1024 * 1024
                }
    
                $originalSize = $Disk.Length
            
                if ($RollingLog) {
                    $LogFilePath = $LogFilePath.Substring(0, $LogFilePath.IndexOf('.'))
                    $LogFilePath = "$LogFilePath $(Get-Date -Format yyyy-MM-dd` HH-mm-ss).csv"
                }

                $PSDefaultParameterValues = @{
                    "Write-VhdOutput:Path"         = $LogFilePath
                    "Write-VhdOutput:StartTime"    = $startTime
                    "Write-VhdOutput:Name"         = $Disk.Name
                    "Write-VhdOutput:DiskState"    = $null
                    "Write-VhdOutput:OriginalSize" = $originalSize
                    "Write-VhdOutput:FinalSize"    = $originalSize
                    "Write-VhdOutput:FullName"     = $Disk.FullName
                    "Write-VhdOutput:Passthru"     = $Passthru
                }
    
                if ($Disk.Extension -ne '.vhd' -and $Disk.Extension -ne '.vhdx' ) {
                    Write-VhdOutput -DiskState 'File Is Not a Virtual Hard Disk format with extension vhd or vhdx' -EndTime (Get-Date)
                    return
                }
    
                if ( $DeleteOlderThanDays ) {

                    $mostRecent = $Disk.LastAccessTime, $Disk.LastWriteTime | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
                    if ($mostRecent -lt (Get-Date).AddDays(-$DeleteOlderThanDays) ) {
                        try {
                            Remove-Item $Disk.FullName -ErrorAction Stop -Force
                            Write-VhdOutput -DiskState "Deleted" -FinalSize 0 -EndTime (Get-Date)
                        }
                        catch { Write-VhdOutput -DiskState 'Disk Deletion Failed' -EndTime (Get-Date) }
                        return
                    }
                }
            
                if ( $IgnoreLessThanGB -and $originalSize -lt $IgnoreLessThanBytes ) {
                    Write-VhdOutput -DiskState 'Ignored' -EndTime (Get-Date)
                    return
                }
   
                try { $mount = Mount-FslDisk -Path $Disk.FullName -TimeOut 30 -PassThru -ErrorAction Stop }
                catch {
                    $err = $error[0]
                    Write-VhdOutput -DiskState $err -EndTime (Get-Date)
                    return
                }

                $timespan = (Get-Date).AddSeconds(120)
                $partInfo = $null
                while (($partInfo | Measure-Object).Count -lt 1 -and $timespan -gt (Get-Date)) {
                    try {
                        $partInfo = Get-Partition -DiskNumber $mount.DiskNumber -ErrorAction Stop | Where-Object -Property 'Type' -EQ -Value 'Basic' -ErrorAction Stop
                    }
                    catch {
                        $partInfo = Get-Partition -DiskNumber $mount.DiskNumber -EA 0 | Select-Object -Last 1
                    }
                    Start-Sleep 0.1
                }
    
                if (($partInfo | Measure-Object).Count -eq 0) {
                    $mount | DisMount-FslDisk
                    Write-VhdOutput -DiskState 'No Partition Information - The Windows Disk SubSystem did not respond in a timely fashion try increasing number of cores or decreasing threads by using the ThrottleLimit parameter' -EndTime (Get-Date)
                    return
                }
    
                $timespan = (Get-Date).AddSeconds(120)
                $defrag = $false
                while ($defrag -eq $false -and $timespan -gt (Get-Date)) {
                    try {
                        Get-Volume -Partition $partInfo -ErrorAction Stop | Optimize-Volume -ErrorAction Stop
                        $defrag = $true
                    }
                    catch {
                        try {
                            Get-Volume -ErrorAction Stop | Where-Object {
                                $_.UniqueId -like "*$($partInfo.Guid)*"
                                -or $_.Path -Like "*$($partInfo.Guid)*"
                                -or $_.ObjectId -Like "*$($partInfo.Guid)*" } | Optimize-Volume -ErrorAction Stop
                            $defrag = $true
                        }
                        catch {
                            $defrag = $false
                            Start-Sleep 0.1
                        }
                        $defrag = $false
                    }
                }
    
                $partSize = $false
                $timespan = (Get-Date).AddSeconds(30)
                while ($partSize -eq $false -and $timespan -gt (Get-Date)) {
                    try {
                        $partitionsize = $partInfo | Get-PartitionSupportedSize -ErrorAction Stop
                        $sizeMax = $partitionsize.SizeMax
                        $partSize = $true
                    }
                    catch {
                        try {
                            $partitionsize = Get-PartitionSupportedSize -DiskNumber $mount.DiskNumber -PartitionNumber $mount.PartitionNumber -ErrorAction Stop
                            $sizeMax = $partitionsize.SizeMax
                            $partSize = $true
                        }
                        catch {
                            $partSize = $false
                            Start-Sleep 0.1
                        }
                        $partSize = $false

                    }
                }
    
                if ($partSize -eq $false) {
                    Write-VhdOutput -DiskState 'No Partition Supported Size Info - The Windows Disk SubSystem did not respond in a timely fashion try increasing number of cores or decreasing threads by using the ThrottleLimit parameter' -EndTime (Get-Date)
                    $mount | DisMount-FslDisk
                    return
                }

                if ( $sizeMax -ne $partInfo.Size ) {
                    Resize-Partition -InputObject $partInfo -Size $sizeMax -ErrorAction Stop
                    Write-Warning -Message "Extended Disk $Disk"
                }

                if ( $partitionsize.SizeMin -gt $disk.Length ) {
                    Write-VhdOutput -DiskState "SkippedAlreadyMinimum" -EndTime (Get-Date)
                    $mount | DisMount-FslDisk
                    return
                }
    
                if (($partitionsize.SizeMin / $disk.Length) -gt (1 - $RatioFreeSpace) ) {
                    Write-VhdOutput -DiskState "LessThan$(100*$RatioFreeSpace)%FreeInsideDisk" -EndTime (Get-Date)
                    $mount | DisMount-FslDisk
                    return
                }
    
                if ($hyperv -eq $true) {
    
                    $i = 0
                    $resize = $false
                    $targetSize = $partitionsize.SizeMin
                    $sizeBytesIncrement = 100 * 1024 * 1024
                    while ($i -le 5 -and $resize -eq $false) {
                        try {
                            Resize-Partition -InputObject $partInfo -Size $targetSize -ErrorAction Stop
                            $resize = $true
                        }
                        catch {
                            $resize = $false
                            $targetSize = $targetSize + $sizeBytesIncrement
                            $i++
                        }
                        finally { Start-Sleep 1 }
                    }
    
                    if ($resize -eq $false) {
                        Write-VhdOutput -DiskState "PartitionShrinkFailed" -EndTime (Get-Date)
                        $mount | DisMount-FslDisk
                        return
                    }
                }
    
                $mount | DisMount-FslDisk
        
                $retries = 0
                $success = $false

                while ($retries -lt 30 -and $success -ne $true) {
    
                    $tempFileName = "$env:TEMP\FslDiskPart$($Disk.Name).txt"
                    function invoke-diskpart ($Path) {
                    
                        Set-Content -Path $Path -Value "SELECT VDISK FILE=`'$($Disk.FullName)`'"
                        Add-Content -Path $Path -Value 'attach vdisk readonly'
                        Add-Content -Path $Path -Value 'COMPACT VDISK'
                        Add-Content -Path $Path -Value 'detach vdisk'
                        $result = DISKPART /s $Path
                        Write-Output $result

                    }
    
                    $diskPartResult = invoke-diskpart -Path $tempFileName
    
                    if ($diskPartResult -match "(DiskPart successfully compacted the virtual disk file.)|(Die Datei f.?r virtuelle Datentr.?ger wurde von DiskPart erfolgreich komprimiert)") {
                        $finalSize = Get-ChildItem $Disk.FullName | Select-Object -ExpandProperty Length
                        $success = $true
                        Remove-Item $tempFileName
                    }
                    else {
                        Set-Content -Path "$env:TEMP\FslDiskPartError$($Disk.Name)-$retries.log" -Value $diskPartResult
                        $retries++
                    }
                    Start-Sleep 1
                }
    
                if ($success -ne $true) {
                    Write-VhdOutput -DiskState "DiskShrinkFailed" -EndTime (Get-Date)
                    Remove-Item $tempFileName
                    return
                }
    
                if ($hyperv -eq $true) {

                    try {
                        $mount = Mount-FslDisk -Path $Disk.FullName -PassThru
                        $partInfo = Get-Partition -DiskNumber $mount.DiskNumber | Where-Object -Property 'Type' -EQ -Value 'Basic'
                        Resize-Partition -InputObject $partInfo -Size $sizeMax -ErrorAction Stop
                        $paramWriteVhdOutput = @{
                            DiskState = "Success"
                            FinalSize = $finalSize
                            EndTime   = Get-Date
                        }
                        Write-VhdOutput @paramWriteVhdOutput
                    }
                    catch {
                        Write-VhdOutput -DiskState "PartitionSizeRestoreFailed" -EndTime (Get-Date)
                        return
                    }
                    finally { $mount | DisMount-FslDisk }
                }
    
    
                $paramWriteVhdOutput = @{
                    DiskState = "Success"
                    FinalSize = $finalSize
                    EndTime   = Get-Date
                }
                Write-VhdOutput @paramWriteVhdOutput
            } 
            end { }
        } 
        function Write-VhdOutput {
            [CmdletBinding()]
    
            Param (

                [Parameter(Mandatory = $true)][System.String]$Path,
                [Parameter(Mandatory = $true)][System.String]$Name,
                [Parameter(Mandatory = $true)][System.String]$DiskState,
                [Parameter(Mandatory = $true)][System.String]$OriginalSize,
                [Parameter(Mandatory = $true)][System.String]$FinalSize,
                [Parameter(Mandatory = $true)][System.String]$FullName,
                [Parameter(Mandatory = $true)][datetime]$StartTime,
                [Parameter(Mandatory = $true)][datetime]$EndTime,
                [Parameter(Mandatory = $true)][Switch]$Passthru

            )
    
            BEGIN { Set-StrictMode -Version Latest }
            PROCESS {
    
                $output = [PSCustomObject]@{
                    Name             = $Name
                    Date             = $StartTime.ToShortDateString()
                    StartTime        = $StartTime.ToLongTimeString()
                    EndTime          = $EndTime.ToLongTimeString()
                    'ElapsedTime(s)' = [math]::Round(($EndTime - $StartTime).TotalSeconds, 1)
                    DiskState        = $DiskState
                    OriginalSizeGB   = [math]::Round( $OriginalSize / 1GB, 2 )
                    FinalSizeGB      = [math]::Round( $FinalSize / 1GB, 2 )
                    SpaceSavedGB     = [math]::Round( ($OriginalSize - $FinalSize) / 1GB, 2 )
                    FullName         = $FullName
                }
    
                if ($Passthru) { Write-Output $output }
                $success = $False
                $retries = 0
                while ($retries -lt 10 -and $success -ne $true) {
                    try {
                        $output | Export-Csv -Path $Path -NoClobber -Append -ErrorAction Stop -NoTypeInformation
                        $success = $true
                    }
                    catch { $retries++ }
                    Start-Sleep 1
                }
            } 
            end { }
        }
    
        $AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow")
        $servicesToTest = 'defragsvc', 'vds'

        try { $servicesToTest | Test-FslDependencies -ErrorAction Stop }
        catch {
            $err = $error[0]
            Write-Error $err
            return
        }

        $numberOfCores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    
        if (($ThrottleLimit / 2) -gt $numberOfCores) {
    
            $ThrottleLimit = $numberOfCores * 2
            Write-Warning "Number of threads set to double the number of cores - $ThrottleLimit"
        }
    
    }
    PROCESS {
    
        if (-not (Test-Path $Path)) {
            Write-Error "$Path not found"
            return
        }
        
        $diskList = Get-ChildItem -Filter *.vhd? -Path $Path -Recurse | ? {!$_.PSIsContainer -and !(gci "$($_.PSParentPath)\*" -Include @("*.lock", "RW.VHDX") -Verbose)}
        $diskList = $diskList | Where-Object { $_.Name -ne "Merge.vhdx" -and $_.Name -ne "RW.vhdx" -and $_.Name -notlike "*_ODFC.vhdx"}
        $diskList | % {$ACL = Get-ACL $_.PSParentPath; $ACL.AddAccessRule($AccessRule); $ACL | Set-ACL $_.PSParentPath}
        
        if ( ($diskList | Measure-Object).count -eq 0 ) {
            Write-Warning "No files to process in $Path"
            return
        }
    
        $scriptblockForEachObject = {
    
    function Mount-FslDisk {
        [CmdletBinding()]
    
        Param (

            [Parameter(Position = 1,ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true,Mandatory = $true)][alias('FullName')][System.String]$Path,
            [Parameter(ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true)][Int]$TimeOut = 3,
            [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$PassThru

        )
    
        BEGIN { Set-StrictMode -Version Latest } 
        PROCESS {
    
            try { $mountedDisk = Mount-DiskImage -ImagePath $Path -NoDriveLetter -PassThru -ErrorAction Stop }
            catch {
                $e = $error[0]
                Write-Error "Failed to mount disk - `"$e`""
                return
            }
    
            $diskNumber = $false
            $timespan = (Get-Date).AddSeconds($TimeOut)
            while ($diskNumber -eq $false -and $timespan -gt (Get-Date)) {
                Start-Sleep 0.1
                try {
                    $mountedDisk = Get-DiskImage -ImagePath $Path
                    if ($mountedDisk.Number) { $diskNumber = $true }
                }
                catch { $diskNumber = $false }
            }
    
            if ($diskNumber -eq $false) {
                try { $mountedDisk | Dismount-DiskImage -EA 0 }
                catch { Write-Error 'Could not dismount Disk Due to no Disknumber' }
                Write-Error 'Cannot get mount information'
                return
            }
    
            $partitionType = $false
            $timespan = (Get-Date).AddSeconds($TimeOut)
            while ($partitionType -eq $false -and $timespan -gt (Get-Date)) {
    
                try {
                    $allPartition = Get-Partition -DiskNumber $mountedDisk.Number -ErrorAction Stop
    
                    if ($allPartition.Type -contains 'Basic') {
                        $partitionType = $true
                        $partition = $allPartition | Where-Object -Property 'Type' -EQ -Value 'Basic'
                    }
                }
                catch {
                    if (($allPartition | Measure-Object).Count -gt 0) {
                        $partition = $allPartition | Select-Object -Last 1
                        $partitionType = $true
                    }
                    else{
    
                        $partitionType = $false
                    }
                }
                Start-Sleep 0.1
            }
    
            if ($partitionType -eq $false) {
                try { $mountedDisk | Dismount-DiskImage -EA 0 }
                catch { Write-Error 'Could not dismount disk with no partition' }
                Write-Error 'Cannot get partition information'
                return
            }
    
            $tempGUID = [guid]::NewGuid().ToString()
            $mountPath = Join-Path $Env:Temp ('FSLogixMnt-' + $tempGUID)
    
            try { New-Item -Path $mountPath -ItemType Directory -ErrorAction Stop | Out-Null }
            catch {
                $e = $error[0]
                try { $mountedDisk | Dismount-DiskImage -EA 0 }
                catch { Write-Error "Could not dismount disk when no folder could be created - `"$e`"" }
                Write-Error "Failed to create mounting directory - `"$e`""
                return
            }
    
            try {
                $addPartitionAccessPathParams = @{
                    DiskNumber      = $mountedDisk.Number
                    PartitionNumber = $partition.PartitionNumber
                    AccessPath      = $mountPath
                    ErrorAction     = 'Stop'
                }
    
                Add-PartitionAccessPath @addPartitionAccessPathParams
            }
            catch {
                $e = $error[0]
                Remove-Item -Path $mountPath -Force -Recurse -EA 0
                try { $mountedDisk | Dismount-DiskImage -EA 0 }
                catch {
                    Write-Error "Could not dismount disk when no junction point could be created - `"$e`""
                }
                Write-Error "Failed to create junction point to - `"$e`""
                return
            }
    
            if ($PassThru) {

                $output = [PSCustomObject]@{
                    Path       = $mountPath
                    DiskNumber = $mountedDisk.Number
                    ImagePath  = $mountedDisk.ImagePath
                    PartitionNumber = $partition.PartitionNumber
                }
                Write-Output $output
            }
            Write-Verbose "Mounted $Path to $mountPath"
        }
        end {
        }
    }
    function Dismount-FslDisk {
        [CmdletBinding()]
    
        Param (

            [Parameter(Position = 1,ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true,Mandatory = $true)][String]$Path,    
            [Parameter(ValuefromPipelineByPropertyName = $true,Mandatory = $true)][String]$ImagePath,
            [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$PassThru,
            [Parameter(ValuefromPipelineByPropertyName = $true)][Int]$Timeout = 120

        )
    
        BEGIN { Set-StrictMode -Version Latest}

        PROCESS {
    
            $mountRemoved = $false
            $directoryRemoved = $false
            $timeStampDirectory = (Get-Date).AddSeconds(20)
    
            while ((Get-Date) -lt $timeStampDirectory -and $directoryRemoved -ne $true) {
                try {
                    Remove-Item -Path $Path -Force -Recurse -ErrorAction Stop | Out-Null
                    $directoryRemoved = $true
                }
                catch { $directoryRemoved = $false }
            }
            if (Test-Path $Path) { Write-Warning "Failed to delete temp mount directory $Path" }
    
    
            $timeStampDismount = (Get-Date).AddSeconds($Timeout)
            while ((Get-Date) -lt $timeStampDismount -and $mountRemoved -ne $true) {
                try {
                    Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null
    
                    try {
                        $image = Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop
    
                        switch ($image.Attached) {
                            $null { $mountRemoved = $false ; Start-Sleep 0.1; break }
                            $true { $mountRemoved = $false ; break}
                            $false { $mountRemoved = $true ; break }
                            Default { $mountRemoved = $false }
                        }
                    }
                    catch { $mountRemoved = $false }
                }
                catch { $mountRemoved = $false }
            }
            if ($mountRemoved -ne $true) { Write-Error "Failed to dismount disk $ImagePath" }
            if ($PassThru) {
                $output = [PSCustomObject]@{
                    MountRemoved         = $mountRemoved
                    DirectoryRemoved     = $directoryRemoved
                }
                Write-Output $output
            }
            
            if ($directoryRemoved -and $mountRemoved) { Write-Verbose "Dismounted $ImagePath" }
        } 
        end { }
    }
    function Optimize-OneDisk {
        [CmdletBinding()]
    
        Param (

            [Parameter(ValuefromPipelineByPropertyName = $true,ValuefromPipeline = $true,Mandatory = $true)][System.IO.FileInfo]$Disk,
            [Parameter(ValuefromPipelineByPropertyName = $true)][Int]$DeleteOlderThanDays,
            [Parameter(ValuefromPipelineByPropertyName = $true)][Int]$IgnoreLessThanGB,
            [Parameter(ValuefromPipelineByPropertyName = $true)][double]$RatioFreeSpace = 0.05,
            [Parameter(ValuefromPipelineByPropertyName = $true)][int]$MountTimeout = 30,    
            [Parameter(ValuefromPipelineByPropertyName = $true)][string]$LogFilePath = "$env:TEMP\FslShrinkDisk $(Get-Date -Format yyyy-MM-dd` HH-mm-ss).csv",
            [Parameter(ValuefromPipelineByPropertyName = $true)][Switch]$RollingLog,[Parameter(ValuefromPipelineByPropertyName = $true)][switch]$Passthru
    
        )
    
        BEGIN {
            Set-StrictMode -Version Latest
            $hyperv = $false
        }
        PROCESS {
            Dismount-DiskImage -ImagePath $Disk.FullName -EA 0
            $startTime = Get-Date
            if ( $IgnoreLessThanGB ) { $IgnoreLessThanBytes = $IgnoreLessThanGB * 1024 * 1024 * 1024 }
            $originalSize = $Disk.Length
            $PSDefaultParameterValues = @{
                "Write-VhdOutput:Path"         = $LogFilePath
                "Write-VhdOutput:StartTime"    = $startTime
                "Write-VhdOutput:Name"         = $Disk.Name
                "Write-VhdOutput:DiskState"    = $null
                "Write-VhdOutput:OriginalSize" = $originalSize
                "Write-VhdOutput:FinalSize"    = $originalSize
                "Write-VhdOutput:FullName"     = $Disk.FullName
                "Write-VhdOutput:Passthru"     = $Passthru
            }

            if ($Disk.Extension -ne '.vhd' -and $Disk.Extension -ne '.vhdx' ) {
                Write-VhdOutput -DiskState 'File Is Not a Virtual Hard Disk format with extension vhd or vhdx' -EndTime (Get-Date)
                return
            }

            if ( $DeleteOlderThanDays ) {

                $mostRecent = $Disk.LastAccessTime, $Disk.LastWriteTime | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
                if ($mostRecent -lt (Get-Date).AddDays(-$DeleteOlderThanDays) ) {
                    try {
                        Remove-Item $Disk.FullName -ErrorAction Stop -Force
                        Write-VhdOutput -DiskState "Deleted" -FinalSize 0 -EndTime (Get-Date)
                    }
                    catch { Write-VhdOutput -DiskState 'Disk Deletion Failed' -EndTime (Get-Date) }
                    return
                }
            }

            if ( $IgnoreLessThanGB -and $originalSize -lt $IgnoreLessThanBytes ) {
                Write-VhdOutput -DiskState 'Ignored' -EndTime (Get-Date)
                return
            }

            try { $mount = Mount-FslDisk -Path $Disk.FullName -TimeOut 30 -PassThru -ErrorAction Stop }
            catch {
                $err = $error[0]
                Write-VhdOutput -DiskState $err -EndTime (Get-Date)
                return
            }


            $timespan = (Get-Date).AddSeconds(120)
            $partInfo = $null
            while (($partInfo | Measure-Object).Count -lt 1 -and $timespan -gt (Get-Date)) {
                try { $partInfo = Get-Partition -DiskNumber $mount.DiskNumber -ErrorAction Stop | Where-Object -Property 'Type' -EQ -Value 'Basic' -ErrorAction Stop }
                catch { $partInfo = Get-Partition -DiskNumber $mount.DiskNumber -EA 0 | Select-Object -Last 1 }
                Start-Sleep 0.1
            }
    
            if (($partInfo | Measure-Object).Count -eq 0) {
                $mount | DisMount-FslDisk
                Write-VhdOutput -DiskState 'No Partition Information - The Windows Disk SubSystem did not respond in a timely fashion try increasing number of cores or decreasing threads by using the ThrottleLimit parameter' -EndTime (Get-Date)
                return
            }
    
            $timespan = (Get-Date).AddSeconds(120)
            $defrag = $false
            while ($defrag -eq $false -and $timespan -gt (Get-Date)) {
                try {
                    Get-Volume -Partition $partInfo -ErrorAction Stop | Optimize-Volume -ErrorAction Stop
                    $defrag = $true
                }
                catch {
                    try {
                        Get-Volume -ErrorAction Stop | Where-Object {
                            $_.UniqueId -like "*$($partInfo.Guid)*"
                            -or $_.Path -Like "*$($partInfo.Guid)*"
                            -or $_.ObjectId -Like "*$($partInfo.Guid)*" } | Optimize-Volume -ErrorAction Stop
                        $defrag = $true
                    }
                    catch {
                        $defrag = $false
                        Start-Sleep 0.1
                    }
                    $defrag = $false
                }
            }

            $partSize = $false
            $timespan = (Get-Date).AddSeconds(30)
            while ($partSize -eq $false -and $timespan -gt (Get-Date)) {
                try {
                    $partitionsize = $partInfo | Get-PartitionSupportedSize -ErrorAction Stop
                    $sizeMax = $partitionsize.SizeMax
                    $partSize = $true
                }
                catch {
                    try {
                        $partitionsize = Get-PartitionSupportedSize -DiskNumber $mount.DiskNumber -PartitionNumber $mount.PartitionNumber -ErrorAction Stop
                        $sizeMax = $partitionsize.SizeMax
                        $partSize = $true
                    }
                    catch {
                    $partSize = $false
                    Start-Sleep 0.1
                }

                
                $partSize = $false
            }
        }

        if ($partSize -eq $false) {

                Write-VhdOutput -DiskState 'No Partition Supported Size Info - The Windows Disk SubSystem did not respond in a timely fashion try increasing number of cores or decreasing threads by using the ThrottleLimit parameter' -EndTime (Get-Date)
                $mount | DisMount-FslDisk
                return
            }

    
            if ( $partitionsize.SizeMin -gt $disk.Length ) {
                Write-VhdOutput -DiskState "SkippedAlreadyMinimum" -EndTime (Get-Date)
                $mount | DisMount-FslDisk
                return
            }
    
    
            if (($partitionsize.SizeMin / $disk.Length) -gt (1 - $RatioFreeSpace) ) {
                Write-VhdOutput -DiskState "LessThan$(100*$RatioFreeSpace)%FreeInsideDisk" -EndTime (Get-Date)
                $mount | DisMount-FslDisk
                return
            }

            if ($hyperv -eq $true) {

                $i = 0
                $resize = $false
                $targetSize = $partitionsize.SizeMin
                $sizeBytesIncrement = 100 * 1024 * 1024
    
                while ($i -le 5 -and $resize -eq $false) {
    
                    try {
                        Resize-Partition -InputObject $partInfo -Size $targetSize -ErrorAction Stop
                        $resize = $true
                    }
                    catch {
                        $resize = $false
                        $targetSize = $targetSize + $sizeBytesIncrement
                        $i++
                    }
                    finally { Start-Sleep 1 }
                }

    
                if ($resize -eq $false) {
                    Write-VhdOutput -DiskState "PartitionShrinkFailed" -EndTime (Get-Date)
                    $mount | DisMount-FslDisk
                    return
                }
            }
    
            $mount | DisMount-FslDisk
            $retries = 0
            $success = $false

            while ($retries -lt 30 -and $success -ne $true) {
    
                $tempFileName = "$env:TEMP\FslDiskPart$($Disk.Name).txt"

                function invoke-diskpart ($Path) {

                    Set-Content -Path $Path -Value "SELECT VDISK FILE=`'$($Disk.FullName)`'"
                    Add-Content -Path $Path -Value 'attach vdisk readonly'
                    Add-Content -Path $Path -Value 'COMPACT VDISK'
                    Add-Content -Path $Path -Value 'detach vdisk'
                    $result = DISKPART /s $Path
                    Write-Output $result
                }
    
                $diskPartResult = invoke-diskpart -Path $tempFileName

                if ($diskPartResult -match "(DiskPart successfully compacted the virtual disk file.)|(Die Datei f.?r virtuelle Datentr.?ger wurde von DiskPart erfolgreich komprimiert)") {
                    $finalSize = Get-ChildItem $Disk.FullName | Select-Object -ExpandProperty Length
                    $success = $true
                    Remove-Item $tempFileName
                }
                else {
                    Set-Content -Path "$env:TEMP\FslDiskPartError$($Disk.Name)-$retries.log" -Value $diskPartResult
                    $retries++
                }
                Start-Sleep 1
            }
    
            if ($success -ne $true) {
                Write-VhdOutput -DiskState "DiskShrinkFailed" -EndTime (Get-Date)
                Remove-Item $tempFileName
                return
            }

            if ($hyperv -eq $true) {

                try {
                    $mount = Mount-FslDisk -Path $Disk.FullName -PassThru
                    $partInfo = Get-Partition -DiskNumber $mount.DiskNumber | Where-Object -Property 'Type' -EQ -Value 'Basic'
                    Resize-Partition -InputObject $partInfo -Size $sizeMax -ErrorAction Stop
                    $paramWriteVhdOutput = @{
                        DiskState = "Success"
                        FinalSize = $finalSize
                        EndTime   = Get-Date
                    }
                    Write-VhdOutput @paramWriteVhdOutput
                }
                catch { Write-VhdOutput -DiskState "PartitionSizeRestoreFailed" -EndTime (Get-Date); return }
                finally { $mount | DisMount-FslDisk }
            }
    
    
            $paramWriteVhdOutput = @{
                DiskState = "Success"
                FinalSize = $finalSize
                EndTime   = Get-Date
            }
            Write-VhdOutput @paramWriteVhdOutput
        }

        end { }

    }
    function Write-VhdOutput {
        [CmdletBinding()]
    
        Param (
        
            [Parameter(Mandatory = $true)][System.String]$Path,
            [Parameter(Mandatory = $true)][System.String]$Name,
            [Parameter(Mandatory = $true)][System.String]$DiskState,
            [Parameter(Mandatory = $true)][System.String]$OriginalSize,
            [Parameter(Mandatory = $true)][System.String]$FinalSize,
            [Parameter(Mandatory = $true)][System.String]$FullName,
            [Parameter(Mandatory = $true)][datetime]$StartTime,
            [Parameter(Mandatory = $true)][datetime]$EndTime,
            [Parameter(Mandatory = $true)][Switch]$RollingLog,
            [Parameter(Mandatory = $true)][Switch]$Passthru
        )
    
        BEGIN { Set-StrictMode -Version Latest}

        PROCESS {

            $output = [PSCustomObject]@{
                Name             = $Name
                StartTime        = $StartTime.ToLongTimeString()
                EndTime          = $EndTime.ToLongTimeString()
                'ElapsedTime(s)' = [math]::Round(($EndTime - $StartTime).TotalSeconds, 1)
                DiskState        = $DiskState
                OriginalSizeGB   = [math]::Round( $OriginalSize / 1GB, 2 )
                FinalSizeGB      = [math]::Round( $FinalSize / 1GB, 2 )
                SpaceSavedGB     = [math]::Round( ($OriginalSize - $FinalSize) / 1GB, 2 )
                FullName         = $FullName
            }
    
            if ($Passthru) { Write-Output $output }
            $success = $False
            $retries = 0
            while ($retries -lt 10 -and $success -ne $true) {
                try {
                    $output | Export-Csv -Path $Path -NoClobber -Append -ErrorAction Stop -NoTypeInformation
                    $success = $true
                }
                catch { $retries++ }
                Start-Sleep 1
            }
        }
        end { }
    }
            
            $paramOptimizeOneDisk = @{
                Disk                = $_
                DeleteOlderThanDays = $using:DeleteOlderThanDays
                IgnoreLessThanGB    = $using:IgnoreLessThanGB
                LogFilePath         = $using:LogFilePath
                PassThru            = $using:PassThru
                RatioFreeSpace      = $using:RatioFreeSpace
            }
            Optimize-OneDisk @paramOptimizeOneDisk
    
        }

        if ($RollingLog) {
            $LogFilePath = $LogFilePath.Substring(0, $LogFilePath.IndexOf('.'))
            $LogFilePath = "$LogFilePath $(Get-Date -Format yyyy-MM-dd` HH-mm-ss).csv"
        }
        $scriptblockInvokeParallel = {
    
            $disk = $_
    
            $paramOptimizeOneDisk = @{
                Disk                = $disk
                DeleteOlderThanDays = $DeleteOlderThanDays
                IgnoreLessThanGB    = $IgnoreLessThanGB
                LogFilePath         = $LogFilePath
                PassThru            = $PassThru
                RatioFreeSpace      = $RatioFreeSpace
            }
            Optimize-OneDisk @paramOptimizeOneDisk
    
        }
    
        if ($PSVersionTable.PSVersion -ge [version]"7.0") { $diskList | % -Parallel $scriptblockForEachObject -ThrottleLimit $ThrottleLimit }
        else { $diskList | Invoke-Parallel -ScriptBlock $scriptblockInvokeParallel -Throttle $ThrottleLimit -ImportFunctions -ImportVariables -ImportModules }
    
    }
    end { }

}

cd $(Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)
if (!(Test-Path $LogPath)) {New-Item -Type Directory $LogPath | Out-Null}
Start-Transcript -Path "$LogPath\Output.txt" -Force | Out-Null
$VHDXLocations | ? {gci $_ -EA 0} | Start-DiskShrinker -LogFilePath "$((gi $LogPath).FullName)\Log.csv" -Verbose

# Final VHDX attachment safety check
Write-Verbose "Checking for VHDX files that are still attached..."

$stillAttached = @(

    Get-ChildItem $VHDXLocations -Filter *.vhdx -Recurse -EA 0 | % {
        
        $image = Get-DiskImage -ImagePath $_.FullName -EA 0
        if ($image -and $image.Attached) {
            
            Write-Warning "VHDX STILL ATTACHED: $($_.FullName)"
            try { Dismount-DiskImage -ImagePath $_.FullName -ErrorAction Stop }
            catch { Write-Error "Failed to dismount VHDX: $($_.FullName) - $($_.Exception.Message)" }
            [PSCustomObject]@{ Path = $_.FullName; Attached = $true }
            
        }
    }
)

Start-Sleep 2

$stillAttached = @( $stillAttached | % { $image = Get-DiskImage -ImagePath $_.Path -EA 0; if ($image -and $image.Attached) { Write-Error "VHDX COULD NOT BE DISMOUNTED: $($_.Path)"; $_ } } )
if ($stillAttached.Count -gt 0) { Write-Error "$($stillAttached.Count) VHDX file(s) are still attached."; exit 1 }
Write-Verbose "Final VHDX attachment check completed successfully."

Stop-Transcript
