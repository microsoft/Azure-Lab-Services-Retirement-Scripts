#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices

<#
.SYNOPSIS
Script to automatically reduce lab capacity based on unassigned VMs in Azure Lab Services labs.

.DESCRIPTION
This script reduces the capacity of Azure Lab Services labs based on the number of unassigned VMs.
Instead of deleting VMs directly (which is not possible via API), the script reduces the lab capacity
which will automatically remove unassigned VMs.

The script uses the Az.LabServices PowerShell library for Azure Lab Services with Lab Plans (v2).

.PARAMETER ResourceGroupName
Optional name of the resource group containing the labs to process. If not specified, all accessible labs will be processed.

.PARAMETER LabName
Optional name of a specific lab to process. If not specified, all labs in the resource group will be processed.

.PARAMETER OutputFile
Path to the output CSV file containing operation results. Default is "LabResize_[timestamp].csv".

.PARAMETER WhatIf
Run the script without making actual changes to see what would be processed.

.PARAMETER Force
Overwrite the output file if it already exists.

.EXAMPLE
.\Resize-Labs.ps1

.EXAMPLE
.\Resize-Labs.ps1 -WhatIf

.EXAMPLE
.\Resize-Labs.ps1 -ResourceGroupName "MyLabResourceGroup"

.EXAMPLE
.\Resize-Labs.ps1 -ResourceGroupName "MyLabResourceGroup" -LabName "MySpecificLab"
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Name of the resource group containing the labs")]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$false, HelpMessage="Name of the specific lab to process")]
    [string] $LabName,

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

function Get-AllLabs {
    param(
        [Parameter(Mandatory=$false)]
        [string] $ResourceGroupName,
        
        [Parameter(Mandatory=$false)]
        [string] $LabName
    )
    
    try {
        # Get labs based on provided filters
        if ($LabName -and $ResourceGroupName) {
            Write-LogMessage "Getting specific lab: $LabName in resource group: $ResourceGroupName"
            $labs = Get-AzLabServicesLab -ResourceGroupName $ResourceGroupName -Name $LabName -ErrorAction SilentlyContinue
        }
        elseif ($ResourceGroupName) {
            Write-LogMessage "Getting all labs in resource group: $ResourceGroupName"
            $labs = Get-AzLabServicesLab -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        else {
            Write-LogMessage "Getting all accessible labs across all resource groups"
            $labs = Get-AzLabServicesLab -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        
        return $labs
    }
    catch {
        Write-LogMessage "Error retrieving labs: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Start-LabCapacityOptimization {
    param(
        [Parameter(Mandatory=$true)]
        $Lab,
        
        [Parameter(Mandatory=$true)]
        [bool] $WhatIfMode
    )
    
    $labName = $Lab.Name
    $resourceGroupName = $Lab.ResourceGroupName
    $currentCapacity = $Lab.SkuCapacity
    
    Write-LogMessage "Processing lab: $labName in resource group: $resourceGroupName"
    Write-LogMessage "Current lab capacity: $currentCapacity"
    
    # Initialize result object
    $result = [PSCustomObject]@{
        LabName = $labName
        ResourceGroupName = $resourceGroupName
        OriginalCapacity = $currentCapacity
        NewCapacity = $currentCapacity
        TotalVMs = 0
        AssignedVMs = 0
        UnassignedVMs = 0
        RegisteredUsers = 0
        CapacityReduction = 0
        CapacityUpdated = $false
        ProcessingResult = ""
        ProcessingTime = Get-Date
        Error = ""
    }
    
    try {
        # Get all VMs in the lab
        $vms = Get-AzLabServicesVM -ResourceGroupName $resourceGroupName -LabName $labName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        # Get user information
        $users = Get-AzLabServicesUser -ResourceGroupName $resourceGroupName -LabName $labName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        $registeredUsers = $users | Where-Object { $_.RegistrationState -ieq "Registered" }
        $registeredUserCount = ($registeredUsers | Measure-Object).Count
        
        # Count non-template VMs
        $nonTemplateVms = $vms | Where-Object { $_.VmType -ne "Template" }
        $totalVmCount = ($nonTemplateVms | Measure-Object).Count
        
        # Count assigned and unassigned VMs
        # A VM is considered assigned if ClaimedByUserId has a value
        $assignedVms = $nonTemplateVms | Where-Object { $_.ClaimedByUserId }
        $assignedVmCount = ($assignedVms | Measure-Object).Count
        
        $unassignedVmCount = $totalVmCount - $assignedVmCount
        
        # Update result object with counts
        $result.TotalVMs = $totalVmCount
        $result.AssignedVMs = $assignedVmCount
        $result.UnassignedVMs = $unassignedVmCount
        $result.RegisteredUsers = $registeredUserCount
        
        Write-LogMessage "Lab statistics: Total VMs: $totalVmCount, Assigned VMs: $assignedVmCount, Unassigned VMs: $unassignedVmCount, Registered Users: $registeredUserCount"
        
        # Check if we need to reduce capacity
        if ($unassignedVmCount -eq 0) {
            Write-LogMessage "No unassigned VMs found in lab '$labName'. No action needed." -Level Info
            $result.ProcessingResult = "Skipped_NoUnassignedVMs"
            return $result
        }
        
        # Calculate new capacity - we need to keep capacity >= registered users
        $optimalCapacity = $assignedVmCount
        # But ensure we don't go below registered user count
        $safeCapacity = [Math]::Max($optimalCapacity, $registeredUserCount)
        $capacityReduction = $currentCapacity - $safeCapacity
        
        $result.NewCapacity = $safeCapacity
        $result.CapacityReduction = $capacityReduction
        
        if ($capacityReduction -le 0) {
            Write-LogMessage "Lab '$labName' capacity of $currentCapacity cannot be reduced (optimal capacity: $safeCapacity). No action needed." -Level Info
            $result.ProcessingResult = "Skipped_NoCapacityReduction"
            return $result
        }
        
        if ($WhatIfMode) {
            Write-LogMessage "WhatIf: Would reduce lab '$labName' capacity from $currentCapacity to $safeCapacity" -Level Warning
            $result.ProcessingResult = "WhatIf_Success"
            return $result
        }
        
        # Update the lab capacity using Set-AzResource
        try {
            # Get the full lab resource with expanded properties
            $labResource = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceName $labName -ResourceType "Microsoft.LabServices/labs" -ExpandProperties -WarningAction SilentlyContinue
            
            # Get the current capacity from the resource
            $currentLabCapacity = $labResource.Properties.virtualMachineProfile.sku.capacity
            
            # Only update capacity if the new capacity is smaller than the current capacity
            if ($safeCapacity -lt $currentLabCapacity) {
                # Update the capacity property
                $labResource.Properties.virtualMachineProfile.sku.capacity = $safeCapacity
            
                # Apply the change back to Azure
                Set-AzResource -ResourceId $labResource.Id -Properties $labResource.Properties -Force -WarningAction SilentlyContinue | Out-Null
                
                $result.CapacityUpdated = $true
                
                if ($safeCapacity -gt $optimalCapacity) {
                    Write-LogMessage "Reduced lab '$labName' capacity from $currentLabCapacity to $safeCapacity (limited by $registeredUserCount registered users)" -Level Warning
                } else {
                    Write-LogMessage "Reduced lab '$labName' capacity from $currentLabCapacity to $safeCapacity" -Level Success
                }
                
                $result.ProcessingResult = "Success"
            } else {
                Write-LogMessage "Lab '$labName' capacity is already at $currentLabCapacity, which is not greater than the desired capacity of $safeCapacity. No update needed." -Level Info
                $result.ProcessingResult = "Skipped_AlreadyOptimal"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -like "*CapacityIsTooLow*") {
                $result.Error = "Failed to update capacity: Cannot reduce capacity below number of registered users"
                Write-LogMessage "Failed to update capacity for lab '$labName': Cannot reduce capacity below the number of registered users. Please remove users before reducing capacity." -Level Warning
            } else {
                $result.Error = "Failed to update capacity: $errorMessage"
                Write-LogMessage "Failed to update capacity for lab '$labName': $errorMessage" -Level Error
            }
            
            $result.ProcessingResult = "Failed"
        }
    }
    catch {
        $result.Error = "Failed to process lab: $($_.Exception.Message)"
        $result.ProcessingResult = "Failed"
        Write-LogMessage "Error processing lab '$labName': $($_.Exception.Message)" -Level Error
    }
    
    return $result
}

# Main execution
try {
    $startTime = Get-Date
    Write-LogMessage "Starting lab capacity optimization script"
    Write-LogMessage "WhatIf mode: $($WhatIf.IsPresent)"
    
    # Ensure user is logged in
    if (-not (Get-AzContext).Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level Error
        exit 1
    }
    
    # Set default output file if not specified
    if (-not $OutputFile) {
        $OutputFile = "LabResize_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }
    
    # Validate output file
    if ((Test-Path -Path $OutputFile) -and -not $Force) {
        Write-LogMessage "Output file '$OutputFile' already exists. Use -Force to overwrite." -Level Error
        exit 1
    }
    
    # Get all labs based on parameters
    $labs = Get-AllLabs -ResourceGroupName $ResourceGroupName -LabName $LabName
    
    if (-not $labs -or ($labs | Measure-Object).Count -eq 0) {
        Write-LogMessage "No labs found with the specified criteria." -Level Warning
        exit 0
    }
    
    Write-LogMessage "Found $(($labs | Measure-Object).Count) labs to process"
    
    # Process each lab
    $results = @()
    
    foreach ($lab in $labs) {
        $result = Start-LabCapacityOptimization -Lab $lab -WhatIfMode $WhatIf.IsPresent
        $results += $result
    }
    
    # Export results
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-LogMessage "Exported processing results to: $OutputFile" -Level Success
    
    # Display summary statistics
    $successCount = ($results | Where-Object { $_.ProcessingResult -eq "Success" } | Measure-Object).Count
    $whatIfCount = ($results | Where-Object { $_.ProcessingResult -eq "WhatIf_Success" } | Measure-Object).Count
    $failedCount = ($results | Where-Object { $_.ProcessingResult -eq "Failed" } | Measure-Object).Count
    $skippedCount = ($results | Where-Object { $_.ProcessingResult -like "Skipped*" } | Measure-Object).Count
    
    # Handle cases where there might be no successful results
    $successfulResults = $results | Where-Object { $_.ProcessingResult -eq "Success" -or $_.ProcessingResult -eq "WhatIf_Success" }
    $totalVmsReduced = if ($successfulResults) { 
        $measure = $successfulResults | Measure-Object -Property UnassignedVMs -Sum
        if ($measure.Sum) { $measure.Sum } else { 0 } 
    } else { 0 }
    
    $capacityReducedResults = $results | Where-Object { $_.ProcessingResult -eq "Success" }
    $totalCapacityReduced = if ($capacityReducedResults) { 
        $measure = $capacityReducedResults | Measure-Object -Property CapacityReduction -Sum
        if ($measure.Sum) { $measure.Sum } else { 0 } 
    } else { 0 }
    
    Write-LogMessage "=== PROCESSING SUMMARY ===" -Level Success
    Write-LogMessage "Total labs processed: $(($results | Measure-Object).Count)"
    
    if ($WhatIf.IsPresent) {
        Write-LogMessage "  - Would resize: $whatIfCount labs"
        Write-LogMessage "  - Would remove approximately: $totalVmsReduced unassigned VMs"
    } else {
        Write-LogMessage "  - Successfully resized: $successCount labs"
        Write-LogMessage "  - Failed to resize: $failedCount labs"
        Write-LogMessage "  - Total capacity reduced: $totalCapacityReduced"
        Write-LogMessage "  - Estimated unassigned VMs removed: $totalVmsReduced"
    }
    Write-LogMessage "  - Skipped: $skippedCount labs (no action needed)"
    
    if ($failedCount -gt 0) {
        Write-LogMessage " "
        Write-LogMessage "Failed processing:" -Level Warning
        $failedResults = $results | Where-Object { $_.ProcessingResult -eq "Failed" }
        foreach ($failed in $failedResults) {
            Write-LogMessage "  Lab '$($failed.LabName)': $($failed.Error)" -Level Error
        }
    }
    
    $executionTime = (Get-Date) - $startTime
    Write-LogMessage "Script completed in $([math]::Round($executionTime.TotalSeconds, 2)) seconds"
}
catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
