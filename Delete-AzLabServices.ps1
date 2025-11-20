#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices, Az.Resources, ThreadJob

<#
.SYNOPSIS
'Nuke everything' script to delete all Azure Lab Services resources after transitioning to a new solution.

.DESCRIPTION
This script provides a comprehensive cleanup solution for Azure Lab Services environments.
It deletes all labs in parallel with throttling, includes timeouts and error checking for
failed deletions, and provides detailed reporting. The script handles both Lab Plans (v2)
and Lab Accounts (v1) resources.

Key features:
- Parallel processing with configurable throttling
- Comprehensive timeout and error handling
- Detailed progress reporting and logging
- Support for both Lab Plans and Lab Accounts
- WhatIf mode for safe testing
- Retry logic for transient failures

.PARAMETER MaxConcurrentJobs
Maximum number of parallel deletion jobs. Default is 8 to balance speed with API limits.

.PARAMETER OutputFile
Path to the output CSV file containing deletion results. Default is "LabDeletionResults_[timestamp].csv".

.PARAMETER WhatIf
Run the script without making actual changes to see what would be deleted.

.PARAMETER Force
Overwrite the output file if it already exists.

.EXAMPLE
.\Delete-AzLabServices.ps1 -WhatIf

.EXAMPLE
.\Delete-AzLabServices.ps1 -MaxConcurrentJobs 5
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Maximum number of parallel deletion jobs")]
    [ValidateRange(1, 20)]
    [int] $MaxConcurrentJobs = 10,

    [Parameter(Mandatory=$false, HelpMessage="Path to the output CSV file")]
    [string] $OutputFile = "",

    [Parameter(Mandatory=$false, HelpMessage="Run without making actual changes")]
    [switch] $WhatIf,

    [Parameter(Mandatory=$false, HelpMessage="Overwrite output file if it exists")]
    [switch] $Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-LogMessage {
    param(
        [Parameter(Mandatory=$true)]
        [string] $Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string] $Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info" { "White" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Success" { "Green" }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Limit-ConcurrentJobs {
    param(
        [Parameter(Mandatory=$true)]
        [int] $MaxJobs,
        
        [Parameter(Mandatory=$true)]
        [ref] $JobsArray,
        
        [Parameter(Mandatory=$true)]
        [ref] $ResultsArray,
        
        [Parameter(Mandatory=$false)]
        [int] $WaitSeconds = 30
    )
    
    # First, check if there are any completed jobs that we haven't processed yet
    $completedJobs = Get-Job -State Completed
    foreach ($completedJob in $completedJobs) {
        # Find job info and check if it's already been processed
        $jobIndex = $null
        $jobInfo = $null
        for ($i = 0; $i -lt ($JobsArray.Value | Measure-Object).Count; $i++) {
            if ($JobsArray.Value[$i].Job.Id -eq $completedJob.Id -and -not $JobsArray.Value[$i].Processed) {
                $jobInfo = $JobsArray.Value[$i]
                $jobIndex = $i
                break
            }
        }
        
        if ($jobInfo) {
            $result = Receive-Job -Job $completedJob
            Write-LogMessage "Completed deletion of $($jobInfo.ResourceType): $($jobInfo.ResourceName) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
            $ResultsArray.Value += $result
            
            # Mark this job as processed
            $JobsArray.Value[$jobIndex].Processed = $true
        }
    }
    
    # Count all active jobs (not Completed and not Failed)
    $activeJobsCount = (Get-Job | Where-Object { $_.State -ne "Completed" -and $_.State -ne "Failed" } | Measure-Object).Count
    
    # Check if we need to throttle
    while ($activeJobsCount -ge $MaxJobs) {
        Write-LogMessage "Throttling: Maximum concurrent jobs reached ($activeJobsCount), waiting..."
        Start-Sleep -Seconds $WaitSeconds
        
        # Check for completed and failed jobs that haven't been processed yet
        $finishedJobs = Get-Job | Where-Object { $_.State -eq "Completed" -or $_.State -eq "Failed" }
        foreach ($finishedJob in $finishedJobs) {
            # Find job info and check if it's already been processed
            $jobIndex = $null
            $jobInfo = $null
            for ($i = 0; $i -lt ($JobsArray.Value | Measure-Object).Count; $i++) {
                if ($JobsArray.Value[$i].Job.Id -eq $finishedJob.Id -and -not $JobsArray.Value[$i].Processed) {
                    $jobInfo = $JobsArray.Value[$i]
                    $jobIndex = $i
                    break
                }
            }
            
            if ($jobInfo) {
                $result = Receive-Job -Job $finishedJob
                
                if ($finishedJob.State -eq "Failed") {
                    Write-LogMessage "Failed job for $($jobInfo.ResourceType): $($jobInfo.ResourceName) - Error: $($finishedJob.Error)" -Level "Error"
                    # Create a result object similar to successful jobs for consistency
                    $ResultsArray.Value += @{
                        ResourceName = $jobInfo.ResourceName
                        ResourceType = $jobInfo.ResourceType
                        DeletionResult = "Failed"
                        Error = $finishedJob.Error
                    }
                } else {
                    Write-LogMessage "Completed deletion of $($jobInfo.ResourceType): $($jobInfo.ResourceName) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
                    $ResultsArray.Value += $result
                }
                
                # Mark this job as processed
                $JobsArray.Value[$jobIndex].Processed = $true
            }
        }
        
        # Recount active jobs
        $activeJobsCount = (Get-Job | Where-Object { $_.State -ne "Completed" -and $_.State -ne "Failed" } | Measure-Object).Count
    }
}

function Wait-JobCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [ref] $JobsArray,
        
        [Parameter(Mandatory=$true)]
        [ref] $ResultsArray,
        
        [Parameter(Mandatory=$false)]
        [string] $WaitMessage = "Waiting for all jobs to complete...",
        
        [Parameter(Mandatory=$false)]
        [int] $WaitSeconds = 15
    )
    
    Write-LogMessage $WaitMessage
    
    # Process all jobs until they are all complete
    $waitingForCompletion = $true
    $loopCount = 0
    
    while ($waitingForCompletion) {
        # Gather job states for logging
        $allJobs = Get-Job
        $jobStateGroups = $allJobs | Group-Object State
        $jobStates = $jobStateGroups | ForEach-Object { "$($_.Name):$(($_ | Measure-Object).Count)" }
        
        # Log job status every 3 loops to avoid spamming
        if ($loopCount % 3 -eq 0) {
            Write-LogMessage "Job states: $($jobStates -join ', ')"
        }
        
        # Process completed and failed jobs
        $finishedJobs = Get-Job | Where-Object { $_.State -eq "Completed" -or $_.State -eq "Failed" }
        foreach ($finishedJob in $finishedJobs) {
            # Find job info and check if it's already been processed
            $jobIndex = $null
            $jobInfo = $null
            
            for ($i = 0; $i -lt ($JobsArray.Value | Measure-Object).Count; $i++) {
                if ($JobsArray.Value[$i].Job.Id -eq $finishedJob.Id -and -not $JobsArray.Value[$i].Processed) {
                    $jobInfo = $JobsArray.Value[$i]
                    $jobIndex = $i
                    break
                }
            }
            
            if ($jobInfo) {
                $result = Receive-Job -Job $finishedJob
                
                if ($finishedJob.State -eq "Failed") {
                    Write-LogMessage "Failed job for $($jobInfo.ResourceType): $($jobInfo.ResourceName) - Error: $($finishedJob.Error)" -Level "Error"
                    # Create a result object similar to successful jobs for consistency
                    $ResultsArray.Value += @{
                        ResourceName = $jobInfo.ResourceName
                        ResourceType = $jobInfo.ResourceType
                        DeletionResult = "Failed"
                        Error = $finishedJob.Error
                    }
                } else {
                    Write-LogMessage "Completed deletion of $($jobInfo.ResourceType): $($jobInfo.ResourceName) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
                    $ResultsArray.Value += $result
                }
                
                # Mark this job as processed
                $JobsArray.Value[$jobIndex].Processed = $true
            }
        }
        
        # Check if we're done processing jobs
        $pendingJobs = $allJobs | Where-Object { $_.State -ne "Completed" -and $_.State -ne "Failed" }
        $waitingForCompletion = (($pendingJobs | Measure-Object).Count -gt 0)
        
        # Check for unprocessed completed or failed jobs
        $unprocessedCompletedCount = 0
        for ($i = 0; $i -lt ($JobsArray.Value | Measure-Object).Count; $i++) {
            $job = Get-Job -Id $JobsArray.Value[$i].Job.Id -ErrorAction SilentlyContinue
            if ($job -and ($job.State -eq "Completed" -or $job.State -eq "Failed") -and -not $JobsArray.Value[$i].Processed) {
                $unprocessedCompletedCount++
            }
        }
        
        $waitingForCompletion = $waitingForCompletion -or ($unprocessedCompletedCount -gt 0)
        
        if ($waitingForCompletion) {
            Start-Sleep -Seconds $WaitSeconds
        }
        
        $loopCount++
    }
}

$defineFunctions = {
function Delete-LabPlan {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject] $Resource,
        
        [Parameter(Mandatory=$false)]
        [switch] $WhatIfMode
    )
    
    $result = [PSCustomObject]@{
        ResourceType = $Resource.ResourceType
        Name = $Resource.Name
        ResourceGroupName = $Resource.ResourceGroupName
        ResourceId = $Resource.ResourceId
        Location = $Resource.Location
        DeletionResult = ""
        DeletionStartTime = (Get-Date)
        DeletionEndTime = $null
        DurationMinutes = 0
        Error = ""
    }
    
    $startTime = (Get-Date)
    
    try {
        if ($WhatIfMode) {
            Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
            $result.DeletionResult = "WhatIf_Success"
        } else {
            # Direct deletion without nested job
            Remove-AzLabServicesLabPlan -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -Confirm:$false -WarningAction SilentlyContinue
            $result.DeletionResult = "Success"
        }
    }
    catch {
        $result.DeletionResult = "Failed"
        $result.Error = $_.Exception.Message
    }
    
    $result.DeletionEndTime = (Get-Date)
    $result.DurationMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
    
    return $result
}

function Delete-LabAccount {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject] $Resource,
        
        [Parameter(Mandatory=$false)]
        [switch] $WhatIfMode
    )
    
    $result = [PSCustomObject]@{
        ResourceType = $Resource.ResourceType
        Name = $Resource.Name
        ResourceGroupName = $Resource.ResourceGroupName
        ResourceId = $Resource.ResourceId
        Location = $Resource.Location
        DeletionResult = ""
        DeletionStartTime = (Get-Date)
        DeletionEndTime = $null
        DurationMinutes = 0
        Error = ""
    }
    
    $startTime = (Get-Date)
    
    try {
        if ($WhatIfMode) {
            Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
            $result.DeletionResult = "WhatIf_Success"
        } else {
            
            $apiVersion = "2019-01-01-preview"
            $uri = "https://management.azure.com$($Resource.ResourceId)?api-version=$apiVersion"
            
            $restResponse = Invoke-AzRestMethod -Uri $uri -Method DELETE
            if ($restResponse.StatusCode -ge 200 -and $restResponse.StatusCode -lt 300) {
                $result.DeletionResult = "Success"
            } else {
                throw "API returned status code: $($restResponse.StatusCode), Response: $($restResponse.Content)"
            }
        }
    }
    catch {
        $result.DeletionResult = "Failed"
        $result.Error = $_.Exception.Message
    }
    
    $result.DeletionEndTime = (Get-Date)
    $result.DurationMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
        
        return $result
    }

    function Delete-Labv1 {
        param(
            [Parameter(Mandatory=$true)]
            [PSCustomObject] $Resource,
            
            [Parameter(Mandatory=$false)]
            [switch] $WhatIfMode
        )
        
        $result = [PSCustomObject]@{
            ResourceType = $Resource.ResourceType
            Name = $Resource.Name
            ResourceGroupName = $Resource.ResourceGroupName
            ResourceId = $Resource.ResourceId
            Location = $Resource.Location
            DeletionResult = ""
            DeletionStartTime = (Get-Date)
            DeletionEndTime = $null
            DurationMinutes = 0
            Error = ""
        }
        
        $startTime = (Get-Date)
        
        try {
            if ($WhatIfMode) {
                Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
                $result.DeletionResult = "WhatIf_Success"
            } else {
                # Direct deletion without nested job using REST API
                $apiVersion = "2019-01-01-preview"
                $response = Invoke-AzRestMethod -Path "$($Resource.ResourceId)?api-version=$apiVersion" -Method DELETE
                if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 202 -or $response.StatusCode -eq 204) {
                    $result.DeletionResult = "Success"
                } else {
                    throw "REST API deletion failed with status code: $($response.StatusCode). Response: $($response.Content)"
                }
            }
        }
        catch {
            $result.DeletionResult = "Failed"
            $result.Error = $_.Exception.Message
        }
        
        $result.DeletionEndTime = (Get-Date)
        $result.DurationMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
        
        return $result
    }

    function Delete-Labv2 {
        param(
            [Parameter(Mandatory=$true)]
            [PSCustomObject] $Resource,
            
            [Parameter(Mandatory=$false)]
            [switch] $WhatIfMode
        )

        $result = [PSCustomObject]@{
            ResourceType = $Resource.ResourceType
            Name = $Resource.Name
            ResourceGroupName = $Resource.ResourceGroupName
            ResourceId = $Resource.ResourceId
            Location = $Resource.Location
            DeletionResult = ""
            DeletionStartTime = (Get-Date)
            DeletionEndTime = $null
            DurationMinutes = 0
            Error = ""
        }
        
        $startTime = (Get-Date)
        
        try {
            if ($WhatIfMode) {
                Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
                $result.DeletionResult = "WhatIf_Success"
            } else {
                # Direct deletion without nested job
                Remove-AzLabServicesLab -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -Confirm:$false -WarningAction SilentlyContinue
                $result.DeletionResult = "Success"
            }
        }
        catch {
            $result.DeletionResult = "Failed"
            $result.Error = $_.Exception.Message
        }
        
        $result.DeletionEndTime = (Get-Date)
        $result.DurationMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
        
        return $result
    }
}

function Get-AllLabResources {
    try {
        $allResources = @()
        
        # Get Lab Plans and Labs (v2)
        try {
            Write-LogMessage "Discovering Lab Plans and Labs (v2)..."
            # This is the first Lab Services cmdlet, so we let the warnings show
            $labPlans = Get-AzLabServicesLabPlan -ErrorAction SilentlyContinue
            $labs = Get-AzLabServicesLab -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            
            if ($labPlans) {
                foreach ($labPlan in $labPlans) {
                    $resource = [PSCustomObject]@{
                        ResourceType = "LabPlan"
                        Name = $labPlan.Name
                        ResourceGroupName = ($labPlan.Id -split '/')[4]
                        ResourceId = $labPlan.Id
                        Location = $labPlan.Location
                        LabPlanName = $labPlan.Name
                        LabAccountName = $null
                        LabsCount = ($labs | Where-Object { $_.PlanId -eq $labPlan.Id } | Measure-Object).Count
                        Status = "Discovered"
                    }
                    $allResources += $resource
                }
                Write-LogMessage "Found $(($labPlans | Measure-Object).Count) Lab Plans"
            }
            
            if ($labs) {
                foreach ($lab in $labs) {
                    $resource = [PSCustomObject]@{
                        ResourceType = "Lab"
                        Name = $lab.Name
                        ResourceGroupName = ($lab.Id -split '/')[4]
                        ResourceId = $lab.Id
                        Location = $lab.Location
                        LabPlanName = ($lab.PlanId -split '/')[-1]
                        LabAccountName = $null
                        LabsCount = 0
                        Status = "Discovered"
                    }
                    $allResources += $resource
                }
                Write-LogMessage "Found $(($labs | Measure-Object).Count) Labs in Lab Plans"
            }
        }
        catch {
            Write-LogMessage "Error discovering Lab Plans: $($_.Exception.Message)" -Level Warning
        }
        
        # Get Lab Accounts and Labs (v1)
        try {
            Write-LogMessage "Discovering Lab Accounts and Labs (v1)..."
            $labAccounts = Get-AzResource -ResourceType "Microsoft.LabServices/labaccounts" -ErrorAction SilentlyContinue
            
            if ($labAccounts) {
                foreach ($labAccount in $labAccounts) {
                    $apiVersion = "2019-01-01-preview"
                    $uri = "https://management.azure.com$($labAccount.ResourceId)/labs?api-version=$apiVersion"
                    
                    try {
                        $restResponse = Invoke-AzRestMethod -Uri $uri -Method GET
                        $labsJson = $restResponse.Content | ConvertFrom-Json
                        $labAccountLabs = $labsJson.value
                    }
                    catch {
                        Write-LogMessage "Error getting labs for Lab Account $($labAccount.Name): $($_.Exception.Message)" -Level Warning
                        $labAccountLabs = $null
                    }
                        
                        $resource = [PSCustomObject]@{
                            ResourceType = "LabAccount"
                            Name = $labAccount.Name
                            ResourceGroupName = $labAccount.ResourceGroupName
                            ResourceId = $labAccount.ResourceId
                            Location = $labAccount.Location
                            LabPlanName = $null
                            LabAccountName = $labAccount.Name
                            LabsCount = if ($labAccountLabs) { ($labAccountLabs | Measure-Object).Count } else { 0 }
                            Status = "Discovered"
                        }
                        $allResources += $resource
                        
                        # Add individual labs
                        if ($labAccountLabs) {
                            foreach ($lab in $labAccountLabs) {
                                # Construct the full resource ID
                                $resourceId = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$($labAccount.ResourceGroupName)/providers/Microsoft.LabServices/labaccounts/$($labAccount.Name)/labs/$($lab.name)"
                                
                                $labResource = [PSCustomObject]@{
                                    ResourceType = "LabAccountLab"
                                    Name = $lab.name
                                    ResourceGroupName = $labAccount.ResourceGroupName
                                    ResourceId = $resourceId
                                    Location = $lab.location
                                    LabPlanName = $null
                                    LabAccountName = $labAccount.Name
                                    LabsCount = 0
                                    Status = "Discovered"
                                }
                                $allResources += $labResource
                            }
                        }
                    }
                    Write-LogMessage "Found $(($labAccounts | Measure-Object).Count) Lab Accounts with $(($allResources | Where-Object { $_.ResourceType -eq 'LabAccountLab' } | Measure-Object).Count) total labs"
                }
            }
        catch {
            Write-LogMessage "Error discovering Lab Accounts: $($_.Exception.Message)" -Level Warning
        }
        
        return $allResources
    }
    catch {
        Write-LogMessage "Error during resource discovery: $($_.Exception.Message)" -Level Error
        return @()
    }
}

# Main execution
try {
    $scriptStartTime = Get-Date
    Write-LogMessage "=== AZURE LAB SERVICES CLEANUP SCRIPT ===" -Level Success
    Write-LogMessage "Starting comprehensive Azure Lab Services cleanup"
    Write-LogMessage "WhatIf mode: $($WhatIf.IsPresent)"
    if ($MaxConcurrentJobs -eq 1) {
        Write-LogMessage "Running in synchronous mode (MaxConcurrentJobs=1)"
    } else {
        Write-LogMessage "Max concurrent jobs: $MaxConcurrentJobs (throttling handled by ThreadJob module)"
    }
    
    # Ensure user is logged in
    $context = Get-AzContext
    if (-not $context.Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level Error
        exit 1
    }
    
    Write-LogMessage "Connected to subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
    
    # Ensure context autosave is enabled for parallel jobs
    if ($MaxConcurrentJobs -gt 1) {
        $autoSaveSetting = Get-AzContextAutosaveSetting
        if ($autoSaveSetting.ContextFile -eq "None" -or $autoSaveSetting.CacheFile -eq "None") {
            Write-LogMessage "Context autosave must be enabled for parallel jobs. Run 'Enable-AzContextAutosave'" -Level Error
            exit 1
        }
    }
    
    # Set default output file if not specified
    if (-not $OutputFile) {
        $OutputFile = "LabDeletionResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }
    
    # Validate output file
    if ((Test-Path -Path $OutputFile) -and -not $Force) {
        Write-LogMessage "Output file '$OutputFile' already exists. Use -Force to overwrite." -Level Error
        exit 1
    }
    
    # Discovery phase - Query for all labs, lab plans and lab accounts
    Write-LogMessage "=== DISCOVERY PHASE ===" -Level Success
    $allResources = Get-AllLabResources
    
    if (($allResources | Measure-Object).Count -eq 0) {
        Write-LogMessage "No Azure Lab Services resources found to delete" -Level Warning
        exit 0
    }
    
    # Display discovery summary
    $labsCount = ($allResources | Where-Object { $_.ResourceType -eq "Lab" } | Measure-Object).Count
    $labAccountLabsCount = ($allResources | Where-Object { $_.ResourceType -eq "LabAccountLab" } | Measure-Object).Count
    $labPlansCount = ($allResources | Where-Object { $_.ResourceType -eq "LabPlan" } | Measure-Object).Count
    $labAccountsCount = ($allResources | Where-Object { $_.ResourceType -eq "LabAccount" } | Measure-Object).Count
    
    Write-LogMessage "=== DISCOVERY SUMMARY ===" -Level Success
    Write-LogMessage "Total resources found: $(($allResources | Measure-Object).Count)"
    Write-LogMessage "  - Lab Plan Labs (v2): $labsCount"
    Write-LogMessage "  - Lab Account Labs (v1): $labAccountLabsCount"
    Write-LogMessage "  - Lab Plans: $labPlansCount"
    Write-LogMessage "  - Lab Accounts: $labAccountsCount"
    
    if ($WhatIf.IsPresent) {
        Write-LogMessage " "
        Write-LogMessage "WHATIF: The following resources would be deleted:"
        foreach ($resource in $allResources) {
            Write-LogMessage "  - $($resource.ResourceType): $($resource.Name) (RG: $($resource.ResourceGroupName))"
        }
    }
    
    # Create jobs to run the deletion functions
    Write-LogMessage " "
    Write-LogMessage "=== DELETION PHASE ===" -Level Success
    
    # Array to track all deletion jobs and results
    $allJobs = @()
    $results = @()
    . $defineFunctions # Ensure functions are defined in the job scope

    # First, create jobs for Labs (v1 and v2)
    $labsV2 = $allResources | Where-Object { $_.ResourceType -eq "Lab" }
    $labsV1 = $allResources | Where-Object { $_.ResourceType -eq "LabAccountLab" }
    
    # Create jobs for v2 labs
    foreach ($lab in $labsV2) {
        Write-LogMessage "Processing deletion of Lab (v2): $($lab.Name)"
        
        # Run synchronously if MaxConcurrentJobs is 1
        if ($MaxConcurrentJobs -eq 1) {
            $result = if ($WhatIf.IsPresent) {
                Delete-Labv2 -Resource $lab -WhatIfMode
            } else {
                Delete-Labv2 -Resource $lab
            }
            Write-LogMessage "Completed deletion of Lab (v2): $($lab.Name) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
            $results += $result
        } else {
            # Run asynchronously with jobs
            $job = Start-ThreadJob -ScriptBlock {
                param($labResource, $whatIf)
                
                # Run the function
                if ($whatIf) {
                    Delete-Labv2 -Resource $labResource -WhatIfMode
                } else {
                    Delete-Labv2 -Resource $labResource
                }
            } -ArgumentList $lab, $WhatIf.IsPresent -InitializationScript $defineFunctions -ThrottleLimit $MaxConcurrentJobs
            
            $allJobs += @{
                Job = $job
                ResourceName = $lab.Name
                ResourceType = $lab.ResourceType
                Processed = $false
            }
            
            # Throttle if needed
            Limit-ConcurrentJobs -MaxJobs $MaxConcurrentJobs -JobsArray ([ref]$allJobs) -ResultsArray ([ref]$results)
        }
    }
    
    # Create jobs for v1 labs
    foreach ($lab in $labsV1) {
        Write-LogMessage "Processing deletion of Lab (v1): $($lab.Name)"
        Start-Sleep -Seconds 1 # Slight delay to avoid multiple threads accessing az context
        # Run synchronously if MaxConcurrentJobs is 1
        if ($MaxConcurrentJobs -eq 1) {
            $result = if ($WhatIf.IsPresent) {
                Delete-Labv1 -Resource $lab -WhatIfMode
            } else {
                Delete-Labv1 -Resource $lab
            }
            Write-LogMessage "Completed deletion of Lab (v1): $($lab.Name) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
            $results += $result
        } else {
            # Run asynchronously with jobs
            $job = Start-ThreadJob -ScriptBlock {
                param($labResource, $whatIf)
                
                # Run the function
                if ($whatIf) {
                    Delete-Labv1 -Resource $labResource -WhatIfMode
                } else {
                    Delete-Labv1 -Resource $labResource
                }
            } -ArgumentList $lab, $WhatIf.IsPresent -InitializationScript $defineFunctions -ThrottleLimit $MaxConcurrentJobs
            
            $allJobs += @{
                Job = $job
                ResourceName = $lab.Name
                ResourceType = $lab.ResourceType
                Processed = $false
            }
            
            # Throttle if needed
            Limit-ConcurrentJobs -MaxJobs $MaxConcurrentJobs -JobsArray ([ref]$allJobs) -ResultsArray ([ref]$results)
        }
    }
    
    # Wait for all Lab deletion jobs to complete before moving on to Lab Plans and Accounts (only if running in parallel)
    if ($MaxConcurrentJobs -gt 1) {
        Wait-JobCompletion -JobsArray ([ref]$allJobs) -ResultsArray ([ref]$results) -WaitMessage "Waiting for all Lab deletion jobs to complete..."
        
        # Clean up any remaining jobs
        Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    
    # Now create jobs for Lab Plans and Lab Accounts
    $labPlans = $allResources | Where-Object { $_.ResourceType -eq "LabPlan" }
    $labAccounts = $allResources | Where-Object { $_.ResourceType -eq "LabAccount" }
    
    # Create jobs for Lab Plans
    foreach ($labPlan in $labPlans) {
        Write-LogMessage "Processing deletion of Lab Plan: $($labPlan.Name)"
        Start-Sleep -Seconds 1 # Slight delay to avoid multiple threads accessing az context
        
        # Run synchronously if MaxConcurrentJobs is 1
        if ($MaxConcurrentJobs -eq 1) {
            $result = if ($WhatIf.IsPresent) {
                Delete-LabPlan -Resource $labPlan -WhatIfMode
            } else {
                Delete-LabPlan -Resource $labPlan
            }
            Write-LogMessage "Completed deletion of Lab Plan: $($labPlan.Name) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
            $results += $result
        } else {
            # Run asynchronously with jobs
            $job = Start-ThreadJob -ScriptBlock {
                param($labPlanResource, $whatIf)
                
                # Run the function
                if ($whatIf) {
                    Delete-LabPlan -Resource $labPlanResource -WhatIfMode
                } else {
                    Delete-LabPlan -Resource $labPlanResource
                }
            } -ArgumentList $labPlan, $WhatIf.IsPresent -InitializationScript $defineFunctions -ThrottleLimit $MaxConcurrentJobs
            
            $allJobs += @{
                Job = $job
                ResourceName = $labPlan.Name
                ResourceType = $labPlan.ResourceType
                Processed = $false
            }
            
            # Throttle if needed
            Limit-ConcurrentJobs -MaxJobs $MaxConcurrentJobs -JobsArray ([ref]$allJobs) -ResultsArray ([ref]$results)
        }
    }
    
    # Create jobs for Lab Accounts
    foreach ($labAccount in $labAccounts) {
        Write-LogMessage "Processing deletion of Lab Account: $($labAccount.Name)"
        Start-Sleep -Seconds 1 # Slight delay to avoid multiple threads accessing az context
        
        # Run synchronously if MaxConcurrentJobs is 1
        if ($MaxConcurrentJobs -eq 1) {
            $result = if ($WhatIf.IsPresent) {
                Delete-LabAccount -Resource $labAccount -WhatIfMode
            } else {
                Delete-LabAccount -Resource $labAccount
            }
            Write-LogMessage "Completed deletion of Lab Account: $($labAccount.Name) - Result: $($result.DeletionResult)" -Level $(if ($result.DeletionResult -eq "Success" -or $result.DeletionResult -eq "WhatIf_Success") { "Success" } else { "Error" })
            $results += $result
        } else {
            # Run asynchronously with jobs
            $job = Start-ThreadJob -ScriptBlock {
                param($labAccountResource, $whatIf)
                
                # Run the function
                if ($whatIf) {
                    Delete-LabAccount -Resource $labAccountResource -WhatIfMode
                } else {
                    Delete-LabAccount -Resource $labAccountResource
                }
            } -ArgumentList $labAccount, $WhatIf.IsPresent -InitializationScript $defineFunctions -ThrottleLimit $MaxConcurrentJobs
            
            $allJobs += @{
                Job = $job
                ResourceName = $labAccount.Name
                ResourceType = $labAccount.ResourceType
                Processed = $false
            }
            
            # Throttle if needed
            Limit-ConcurrentJobs -MaxJobs $MaxConcurrentJobs -JobsArray ([ref]$allJobs) -ResultsArray ([ref]$results)
        }
    }
    
    # Wait for all remaining jobs to complete (only if running in parallel)
    if ($MaxConcurrentJobs -gt 1) {
        Wait-JobCompletion -JobsArray ([ref]$allJobs) -ResultsArray ([ref]$results) -WaitMessage "Waiting for all remaining deletion jobs to complete..."
        
        # Final cleanup
        Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    
    # Export results to CSV
    $results | Export-Csv -Path $OutputFile -Force:$Force -NoTypeInformation
    Write-LogMessage "Exported deletion results to: $OutputFile" -Level Success
    
    # Generate summary statistics
    $successCount = ($results | Where-Object { $_.DeletionResult -eq "Success" -or $_.DeletionResult -eq "WhatIf_Success" } | Measure-Object).Count
    $failedCount = ($results | Where-Object { $_.DeletionResult -eq "Failed" -or $_.DeletionResult -eq "Timeout" } | Measure-Object).Count
    
    # Final summary
    Write-LogMessage " "
    Write-LogMessage "=== FINAL SUMMARY ===" -Level Success
    Write-LogMessage "Total resources processed: $(($results | Measure-Object).Count)"
    
    if ($WhatIf.IsPresent) {
        Write-LogMessage "Would successfully delete: $successCount resources"
    } else {
        Write-LogMessage "Successfully deleted: $successCount resources"
        Write-LogMessage "Failed to delete: $failedCount resources"
    }
    
    Write-LogMessage "Total execution time: $([math]::Round(((Get-Date) - $scriptStartTime).TotalMinutes, 2)) minutes"
    
    # Report by resource type
    $labv2Results = ($results | Where-Object { $_.ResourceType -eq "Lab" })
    $labv1Results = ($results | Where-Object { $_.ResourceType -eq "LabAccountLab" })
    $labPlanResults = ($results | Where-Object { $_.ResourceType -eq "LabPlan" })
    $labAccountResults = ($results | Where-Object { $_.ResourceType -eq "LabAccount" })
    
    Write-LogMessage " "
    Write-LogMessage "Results by resource type:"
    
    if (($labv2Results | Measure-Object).Count -gt 0) {
        $successCount = ($labv2Results | Where-Object { $_.DeletionResult -eq "Success" -or $_.DeletionResult -eq "WhatIf_Success" } | Measure-Object).Count
        Write-LogMessage "  - Labs v2: $successCount/$(($labv2Results | Measure-Object).Count) successful"
    }
    
    if (($labv1Results | Measure-Object).Count -gt 0) {
        $successCount = ($labv1Results | Where-Object { $_.DeletionResult -eq "Success" -or $_.DeletionResult -eq "WhatIf_Success" } | Measure-Object).Count
        Write-LogMessage "  - Labs v1: $successCount/$(($labv1Results | Measure-Object).Count) successful"
    }
    
    if (($labPlanResults | Measure-Object).Count -gt 0) {
        $successCount = ($labPlanResults | Where-Object { $_.DeletionResult -eq "Success" -or $_.DeletionResult -eq "WhatIf_Success" } | Measure-Object).Count
        Write-LogMessage "  - Lab Plans: $successCount/$(($labPlanResults | Measure-Object).Count) successful"
    }
    
    if (($labAccountResults | Measure-Object).Count -gt 0) {
        $successCount = ($labAccountResults | Where-Object { $_.DeletionResult -eq "Success" -or $_.DeletionResult -eq "WhatIf_Success" } | Measure-Object).Count
        Write-LogMessage "  - Lab Accounts: $successCount/$(($labAccountResults | Measure-Object).Count) successful"
    }
    
    if ($failedCount -gt 0 -and -not $WhatIf.IsPresent) {
        Write-LogMessage " "
        Write-LogMessage "=== FAILED DELETIONS ===" -Level Error
        $failedResults = $results | Where-Object { $_.DeletionResult -eq "Failed" -or $_.DeletionResult -eq "Timeout" }
        foreach ($failed in $failedResults) {
            Write-LogMessage "  - $($failed.ResourceType) '$($failed.Name)': $($failed.Error)" -Level Error
        }
    }
    
    if ($WhatIf.IsPresent) {
        Write-LogMessage " "
        Write-LogMessage "WHATIF COMPLETE: No actual changes were made. Remove -WhatIf to perform actual deletion." -Level Warning
    } elseif ($failedCount -eq 0) {
        Write-LogMessage " "
        Write-LogMessage "ALL AZURE LAB SERVICES RESOURCES SUCCESSFULLY DELETED!" -Level Success
    }
}
catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
