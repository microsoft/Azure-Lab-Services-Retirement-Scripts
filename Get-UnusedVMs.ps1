#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices

<#
.SYNOPSIS
Script to find all VMs that appear unused across all Lab Services v2 (Lab Plans) labs in the subscription.

.DESCRIPTION
This script identifies unused VMs across all Azure Lab Services v2 labs based on configurable criteria:
- VMs with minimal usage (less than specified hours)
- VMs that are unassigned to users

The script generates a CSV file per lab containing VM details that should be considered for deletion.

.PARAMETER MaxUsageHours
Maximum usage hours threshold. VMs with usage below this will be considered unused. Default is 1 hour.

.PARAMETER OutputDirectory
Directory where CSV files will be created. Default is current directory.

.EXAMPLE
.\Get-UnusedVMs.ps1 -MaxUsageHours 2 -OutputDirectory "C:\Reports"
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Maximum usage hours threshold for considering a VM unused")]
    [ValidateRange(0.1, 100)]
    [double] $MaxUsageHours = 1.0,

    [Parameter(Mandatory=$false, HelpMessage="Directory where CSV files will be created")]
    [string] $OutputDirectory = "."
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

function Test-VmUnused {
    param(
        [Parameter(Mandatory=$true)]
        $Vm,
        
        [Parameter(Mandatory=$false)]
        $User = $null,
        
        [Parameter(Mandatory=$true)]
        [double] $MaxUsageHours
    )
    
    $reasons = @()
    
    # Check if VM is unassigned
    if (-not $Vm.ClaimedByUserId) {
        $reasons += "Unassigned"
    }
    
    # Check usage hours if user exists
    if ($User) {
        $usageHours = if ($User.TotalUsage) { $User.TotalUsage.TotalHours } else { 0 }
        if ($usageHours -le $MaxUsageHours) {
            $reasons += "Low usage ($usageHours hours)"
        }
    } else {
        $reasons += "No user data"
    }
    
    return @{
        IsUnused = ($reasons | Measure-Object).Count -gt 0
        Reasons = $reasons -join "; "
        UsageHours = if ($User -and $User.TotalUsage) { $User.TotalUsage.TotalHours } else { 0 }
    }
}

function Get-UnusedVmsFromLabPlan {
    param(
        [Parameter(Mandatory=$true)]
        $Lab,
        
        [Parameter(Mandatory=$true)]
        [double] $MaxUsageHours
    )
    
    try {
        Write-LogMessage "Processing Lab Plan lab: $($Lab.Name)"
        
        # Get VMs and users for the lab
        $vms = Get-AzLabServicesVM -LabName $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        $users = Get-AzLabServicesUser -LabName $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        if (-not $vms) {
            Write-LogMessage "No VMs found in lab $($Lab.Name)" -Level Warning
            return @()
        }
        
        $unusedVms = @()

        foreach ($vm in $vms) {
            # Skip template VM
            if ($vm.VMType -ieq "Template") {
                continue
            }
            
            # Find associated user
            $user = $null
            if ($vm.ClaimedByUserId) {
                $user = $users | Where-Object { $_.Id -eq $vm.ClaimedByUserId }
            }
            
            # Test if VM is unused
            $usageTest = Test-VmUnused -Vm $vm -User $user -MaxUsageHours $MaxUsageHours
            
            if ($usageTest.IsUnused) {
                # Find lab plan name from the labplans collection
                $labPlan = $labPlans | Where-Object { $_.Id -ieq $Lab.PlanId }
                $labPlanName = if ($labPlan) { $labPlan.Name } else { ($Lab.PlanId -split '/')[-1] }

                $vmInfo = [PSCustomObject]@{
                    LabPlanName = $labPlanName
                    LabName = $Lab.Name
                    ResourceGroupName = $Lab.ResourceGroupName
                    VmName = $vm.Name
                    VmId = $vm.Id
                    Status = $vm.State
                    ClaimedByUserId = $vm.ClaimedByUserId
                    UserEmail = if ($user) { $user.Email } else { "N/A" }
                    UserDisplayName = if ($user) { $user.DisplayName } else { "N/A" }
                    UsageHours = $usageTest.UsageHours
                    UnusedReasons = $usageTest.Reasons
                    IpAddress = $vm.ConnectionProfilePrivateIPAddress
                }
                
                $unusedVms += $vmInfo
            }
        }
        
        return $unusedVms
    }
    catch {
        Write-LogMessage "Error processing lab $($Lab.Name): $($_.Exception.Message)" -Level Error
        return @()
    }
}

# Main execution
try {
    $startTime = Get-Date
    Write-LogMessage "Starting unused VM detection script"
    
    # Ensure user is logged in
    if (-not (Get-AzContext).Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level Error
        exit 1
    }
    
    # Validate and create output directory
    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        Write-LogMessage "Created output directory: $OutputDirectory"
    }
    
    # Log the usage hours threshold
    Write-LogMessage "Maximum usage hours threshold: $MaxUsageHours hours"
    
    $allUnusedVms = @()
    
    # Process Lab Plans (v2) labs
    try {
        Write-LogMessage "Getting Lab Plans and Labs..."
        # First call to Azure Lab Services commandlet - display warnings
        $labPlans = Get-AzLabServicesLabPlan -ErrorAction SilentlyContinue
        Write-LogMessage "Found $(($labPlans | Measure-Object).Count) lab plans"
        $labs = Get-AzLabServicesLab -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        if ($labs) {
            Write-LogMessage "Found $(($labs | Measure-Object).Count) labs to process"
            
            foreach ($lab in $labs) {
                # Add LabPlans reference to each lab
                Add-Member -InputObject $lab -MemberType NoteProperty -Name "LabPlan" -Value ($labPlans | Where-Object {$_.Id -ieq $lab.PlanId})
                
                $unusedVms = Get-UnusedVmsFromLabPlan -Lab $lab -MaxUsageHours $MaxUsageHours
                $allUnusedVms += $unusedVms
                
                if (($unusedVms | Measure-Object).Count -gt 0) {
                    $outputFile = Join-Path -Path $OutputDirectory -ChildPath "UnusedVMs_Lab_$($lab.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                    $unusedVms | Export-Csv -Path $outputFile -NoTypeInformation
                    Write-LogMessage "Created report for lab '$($lab.Name)': $outputFile ($(($unusedVms | Measure-Object).Count) unused VMs)"
                }
            }
        } else {
            Write-LogMessage "No Lab Plan labs found" -Level Warning
        }
    }
    catch {
        Write-LogMessage "Error processing Lab Plans: $($_.Exception.Message)" -Level Error
    }
   
    # Create summary report
    if (($allUnusedVms | Measure-Object).Count -gt 0) {
        $summaryFile = Join-Path -Path $OutputDirectory -ChildPath "UnusedVMs_Summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $allUnusedVms | Export-Csv -Path $summaryFile -NoTypeInformation
        Write-LogMessage "Created summary report: $summaryFile" -Level Success
        
        # Display summary statistics
        $unassignedCount = (($allUnusedVms | Where-Object { $_.UnusedReasons -like "*Unassigned*" }) | Measure-Object).Count
        $lowUsageCount = (($allUnusedVms | Where-Object { $_.UnusedReasons -like "*Low usage*" }) | Measure-Object).Count
        
        Write-LogMessage "=== SUMMARY ==="
        Write-LogMessage "Total unused VMs found: $(($allUnusedVms | Measure-Object).Count)"
        Write-LogMessage "  - Unassigned VMs: $unassignedCount"
        Write-LogMessage "  - Low usage VMs: $lowUsageCount"
    } else {
        Write-LogMessage "No unused VMs found matching the criteria" -Level Warning
    }
    
    $executionTime = (Get-Date) - $startTime
    Write-LogMessage "Script completed successfully in $([math]::Round($executionTime.TotalMinutes, 2)) minutes"
}
catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
