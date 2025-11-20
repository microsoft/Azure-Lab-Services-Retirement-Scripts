#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices

<#
.SYNOPSIS
Script to find VMs with exceptionally high usage hours that may indicate misuse.

.DESCRIPTION
This script identifies VMs across all Azure Lab Services labs that have accumulated usage hours
exceeding a specified threshold. This helps identify VMs that may be misused by students for 
non-academic activities or indicate other usage anomalies.

The script uses the Az.LabServices PowerShell library for Azure Lab Services with Lab Plans.

.PARAMETER MaxHours
Maximum allowed usage hours. VMs with usage above this threshold will be reported. Default is 100 hours.

.PARAMETER OutputFile
Path to the output CSV file. Default is "HighlyUsedVMs_[timestamp].csv" in current directory.

.EXAMPLE
.\Get-HighlyUsedVMs.ps1 -MaxHours 100 -OutputFile "C:\Reports\HighUsage.csv"
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Maximum allowed usage hours threshold")]
    [ValidateRange(1, 2000)]
    [int] $MaxHours = 1,

    [Parameter(Mandatory=$false, HelpMessage="Path to the output CSV file")]
    [string] $OutputFile = ""
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

function Get-HighlyUsedVmsFromLabPlan {
    param(
        [Parameter(Mandatory=$true)]
        $Lab,
        
        [Parameter(Mandatory=$true)]
        [int] $MaxHours
    )
    
    try {
        Write-LogMessage "Processing Lab Plan lab: $($Lab.Name)"
        
        # Get users for the lab (where usage data is stored)
        $users = Get-AzLabServicesUser -LabName $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        if (-not $users) {
            Write-LogMessage "No users found in lab $($Lab.Name)" -Level Warning
            return @()
        }
        
        # Get VMs for additional details
        $vms = Get-AzLabServicesVM -LabName $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        $highlyUsedVms = @()
        
        foreach ($user in $users) {
            $usageHours = if ($user.TotalUsage) { $user.TotalUsage.TotalHours } else { 0 }
            
            if ($usageHours -gt $MaxHours) {
                # Find associated VM
                $vm = $null
                if ($vms) {
                    $vm = $vms | Where-Object { $_.ClaimedByUserId -eq $user.Id }
                }
                
                # Create VM info object
                $vmInfo = [PSCustomObject]@{
                    LabPlanName = ($Lab.PlanId -split '/')[-1]
                    LabName = $Lab.Name
                    ResourceGroupName = $Lab.ResourceGroupName  # Using the direct property instead of parsing from Id
                    UserEmail = $user.Email
                    UserDisplayName = $user.DisplayName
                    UsageHours = [math]::Round($usageHours, 2)
                }
                
                # Add VM details if available
                if ($vm) {
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "VmName" -Value $vm.Name
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "VmId" -Value $vm.Id
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "VmState" -Value $vm.State
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "ConnectionProfilePrivateIPAddress" -Value $vm.ConnectionProfilePrivateIPAddress
                } else {
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "VmName" -Value "Not Found"
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "VmId" -Value "N/A"
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "VmState" -Value "N/A"
                    $vmInfo | Add-Member -MemberType NoteProperty -Name "ConnectionProfilePrivateIPAddress" -Value "N/A"
                }
                
                # Add lab details for SKU and OS type
                $vmInfo | Add-Member -MemberType NoteProperty -Name "SkuName" -Value $Lab.SkuName
                $vmInfo | Add-Member -MemberType NoteProperty -Name "OsType" -Value $Lab.VirtualMachineProfileOSType
                
                # Add all additional details
                $additionalQuota = if ($user.AdditionalUsageQuota) { $user.AdditionalUsageQuota.TotalHours } else { 0 }
                $vmInfo | Add-Member -MemberType NoteProperty -Name "AdditionalUsageQuota" -Value $additionalQuota
                $vmInfo | Add-Member -MemberType NoteProperty -Name "UserId" -Value $user.Id
                $vmInfo | Add-Member -MemberType NoteProperty -Name "LabLocation" -Value $Lab.Location
                
                $highlyUsedVms += $vmInfo
            }
        }
        
        return $highlyUsedVms
    }
    catch {
        Write-LogMessage "Error processing lab $($Lab.Name): $($_.Exception.Message)" -Level Error
        return @()
    }
}

# Main execution
try {
    $startTime = Get-Date
    Write-LogMessage "Starting highly used VM detection script"
    
    # Ensure user is logged in
    if (-not (Get-AzContext).Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level Error
        exit 1
    }
    
    # Set default output file if not specified
    if (-not $OutputFile) {
        $OutputFile = "HighlyUsedVMs_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }
    
    # Validate output directory
    $outputDir = Split-Path -Path $OutputFile -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-LogMessage "Created output directory: $outputDir"
    }
    
    Write-LogMessage "Maximum usage hours threshold: $MaxHours hours"
    Write-LogMessage "Output file: $OutputFile"
    
    $allHighlyUsedVms = @()
    
    # Process Lab Plans (v2) labs
    try {
        Write-LogMessage "Getting Lab Plans and Labs..."
        # Get lab plans to ensure Azure is initialized properly, but we don't need to use the result directly
        Get-AzLabServicesLabPlan -ErrorAction SilentlyContinue | Out-Null
        $labs = Get-AzLabServicesLab -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        if ($labs) {
            Write-LogMessage "Found $(($labs | Measure-Object).Count) Lab Plan labs to process"
            
            foreach ($lab in $labs) {
                $highlyUsedVms = Get-HighlyUsedVmsFromLabPlan -Lab $lab -MaxHours $MaxHours
                $allHighlyUsedVms += $highlyUsedVms
                
                if (($highlyUsedVms | Measure-Object).Count -gt 0) {
                    Write-LogMessage "Lab '$($lab.Name)': Found $(($highlyUsedVms | Measure-Object).Count) highly used VMs"
                }
            }
        } else {
            Write-LogMessage "No Lab Plan labs found" -Level Warning
        }
    }
    catch {
        Write-LogMessage "Error processing Lab Plans: $($_.Exception.Message)" -Level Error
    }
        
    # Export results
    if (($allHighlyUsedVms | Measure-Object).Count -gt 0) {
        $allHighlyUsedVms | Export-Csv -Path $OutputFile -NoTypeInformation
        Write-LogMessage "Exported results to: $OutputFile"
        
        # Display summary statistics
        $maxUsageFound = ($allHighlyUsedVms | Measure-Object -Property UsageHours -Maximum).Maximum
        $avgUsageFound = ($allHighlyUsedVms | Measure-Object -Property UsageHours -Average).Average
        
        Write-LogMessage "=== SUMMARY ===" -Level Success
        Write-LogMessage "Total highly used VMs found: $(($allHighlyUsedVms | Measure-Object).Count)"
        Write-LogMessage "Maximum usage found: $([math]::Round($maxUsageFound, 2)) hours"
        Write-LogMessage "Average usage of flagged VMs: $([math]::Round($avgUsageFound, 2)) hours"
        
        # Show top users
        $topUsers = $allHighlyUsedVms | Sort-Object -Property UsageHours -Descending | Select-Object -First 5
        Write-LogMessage "  "
        Write-LogMessage "Top 5 users by usage hours:"
        foreach ($user in $topUsers) {
            Write-LogMessage "  $($user.UserDisplayName) ($($user.UserEmail)): $($user.UsageHours) hours in lab '$($user.LabName)'"
        }
    } else {
        Write-LogMessage "No VMs found exceeding the usage threshold of $MaxHours hours" -Level Warning
    }
    
    $executionTime = (Get-Date) - $startTime
    Write-LogMessage "Script completed successfully in $([math]::Round($executionTime.TotalMinutes, 2)) minutes"
}
catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
