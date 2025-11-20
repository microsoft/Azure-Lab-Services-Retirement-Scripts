#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices

<#
.SYNOPSIS
Get all the Azure Lab Services labs (based on Lab Plans, v2) in the subscription and output key details to a CSV file.

.DESCRIPTION
This script retrieves all Azure Lab Services labs (v2, based on Lab Plans) in the current subscription and provides detailed information about each lab.
Information includes lab configuration settings, capacity, VM details, network settings, and usage statistics.
Results are exported to a CSV file for further analysis or reporting purposes.

.PARAMETER OutputFile
Path to the output CSV file. Default is "AzureLabServices_Labs_[timestamp].csv" in the current directory.

.PARAMETER PassThru
Switch parameter to return the lab objects to the pipeline, in addition to generating the CSV file.

.EXAMPLE
.\Get-Labs.ps1
Gets all labs and exports them to the default CSV file in the current directory.

.EXAMPLE
.\Get-Labs.ps1 -OutputFile "C:\Reports\AzureLabs.csv"
Gets all labs and exports them to the specified file.

.EXAMPLE
$labs = .\Get-Labs.ps1 -PassThru
Gets all labs, exports them to the default CSV file, and returns the lab objects for further processing.
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Path to the output CSV file")]
    [string] $OutputFile = "",

    [Parameter(Mandatory=$false, HelpMessage="Use the PassThru parameter to return an object containing the results")]
    [switch] $PassThru
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

function Get-FormattedPercentage {
    param (
        [Parameter(Mandatory=$true)]
        $Value,
        
        [Parameter(Mandatory=$false)]
        [int] $DecimalPlaces = 1
    )
    
    if ($Value -eq "N/A" -or $null -eq $Value) {
        return "N/A"
    }
    
    return [math]::Round($Value, $DecimalPlaces).ToString() + " %"
}

function Get-LabDetailedInfo {
    param(
        [Parameter(Mandatory=$true)]
        [object] $Lab
    )
    
    try {
        # Get additional lab details
        $templateVM = Get-AzLabServicesTemplateVM -LabName $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        $studentVMs = Get-AzLabServicesVM -LabName $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | 
                    Where-Object { if ($templateVM -and $_.Id -ieq $templateVM.Id) { $false } else { $true } }
        
        # Basic lab info
        $labInfo = [ordered]@{
            "SubscriptionId" = (Get-AzContext).Subscription.Id
            "SubscriptionName" = (Get-AzContext).Subscription.Name
            "LabPlanId" = $Lab.PlanId
            "LabPlanName" = ($Lab.PlanId -split '/')[-1]
            "LabName" = $Lab.Name
            "Title" = $Lab.Title
            "ResourceGroupName" = $Lab.ResourceGroupName
            "Location" = $Lab.Location
            "SkuName" = $Lab.SkuName
            "OsType" = $Lab.VirtualMachineProfileOSType
            "SkuCapacity" = $lab.SkuCapacity
            "State" = $lab.State
            "CreatedDate" = $Lab.SystemDataCreatedAt
            "Id" = $Lab.Id
        }
        
        # VM counts and capacity
        $totalVMs = ($studentVMs | Measure-Object).Count
        $assignedVMs = ($studentVMs | Where-Object { $_.ClaimedByUserId } | Measure-Object).Count
        
        # Network settings
        $isAdvancedNetworking = if ($Lab.NetworkProfileSubnetId) { $true } else { $false }
        $networkProfile = if ($isAdvancedNetworking) { "Advanced" } else { "Standard" }

        # Add VM and network properties
        $labInfo += [ordered]@{
            "TotalVMs" = $totalVMs
            "AssignedVMs" = $assignedVMs
            "IsAdvancedNetworking" = $isAdvancedNetworking
            "NetworkProfile" = $networkProfile
            "SubnetId" = if ($isAdvancedNetworking) { $Lab.NetworkProfileSubnetId } else { "N/A" }
            "IsCustomImage" = if ($Lab.ImageReferenceId) { $true } else { $false }
            "ImageSource" = if ($Lab.ImageReferenceId) { $Lab.ImageReferenceId } else { "Marketplace Image" }
        }
                
        return [PSCustomObject]$labInfo
    }
    catch {
        Write-LogMessage "Error processing lab $($Lab.Name): $($_.Exception.Message)" -Level Error
        return $null
    }
}

# Main execution
try {
    $startTime = Get-Date
    Write-LogMessage "Starting Azure Lab Services lab information retrieval script"
    
    # Ensure user is logged in
    if (-not (Get-AzContext).Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level Error
        exit 1
    }
    
    # Set default output file if not specified
    if (-not $OutputFile) {
        $OutputFile = "AzureLabServices_Labs_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }
    
    # Validate output directory
    $outputDir = Split-Path -Path $OutputFile -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-LogMessage "Created output directory: $outputDir" -Level Info
    }
    
    Write-LogMessage "Output file: $OutputFile" -Level Info
    
    # Collection to hold detailed lab information
    $allLabs = @()
    
    # Get all Lab Plans and Labs
    Write-LogMessage "Getting Lab Plans and Labs..." -Level Info
    # First call to Lab Services commandlet - display warnings
    $labPlans = Get-AzLabServicesLabPlan -ErrorAction SilentlyContinue
    Write-LogMessage "Found $(($labPlans | Measure-Object).Count) lab plans" -Level Info
    
    # Get all labs
    $labs = Get-AzLabServicesLab -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    
    if ($labs) {
        $labCount = ($labs | Measure-Object).Count
        Write-LogMessage "Found $labCount labs to process" -Level Info
        
        # Process each lab to get detailed information
        $i = 0
        foreach ($lab in $labs) {
            $i++
            Write-Progress -Activity "Processing Azure Lab Services labs" -Status ("Processing lab $i of $labCount" + ": " + $lab.Name) -PercentComplete (($i * 100) / $labCount)
            
            # Get detailed lab info
            $labInfo = Get-LabDetailedInfo -Lab $lab
            
            if ($labInfo) {
                $allLabs += $labInfo
            }
        }
        
        # Export results to CSV
        if (($allLabs | Measure-Object).Count -gt 0) {
            $allLabs | Export-Csv -Path $OutputFile -NoTypeInformation
            Write-LogMessage "Exported $($allLabs.Count) labs to: $OutputFile" -Level Success
            
            # Display summary statistics
            Write-LogMessage "=== SUMMARY ===" -Level Success
            Write-LogMessage "Total labs found: $(($allLabs | Measure-Object).Count)" -Level Info
            
            # VM statistics
            $totalVMs = ($allLabs | Measure-Object -Property TotalVMs -Sum).Sum
            $assignedVMs = ($allLabs | Measure-Object -Property AssignedVMs -Sum).Sum
            
            Write-LogMessage "Total VMs across all labs: $totalVMs" -Level Info
            Write-LogMessage "Total assigned VMs: $assignedVMs" -Level Info
            
            # Display lab distribution by location
            $locationDistribution = $allLabs | Group-Object -Property Location | Sort-Object -Property Count -Descending
            Write-LogMessage " " # Empty line for better readability
            Write-LogMessage "Lab distribution by location:" -Level Info
            foreach ($location in $locationDistribution) {
                Write-LogMessage "  $($location.Name): $($location.Count) labs" -Level Info
            }
            
            # Display lab distribution by OS type
            $osTypeDistribution = $allLabs | Group-Object -Property OsType | Sort-Object -Property Count -Descending
            Write-LogMessage " " # Empty line for better readability
            Write-LogMessage "Lab distribution by OS type:" -Level Info
            foreach ($osType in $osTypeDistribution) {
                Write-LogMessage "  $($osType.Name): $($osType.Count) labs" -Level Info
            }
        } else {
            Write-LogMessage "No labs found or all labs had errors during processing" -Level Warning
        }
    } else {
        Write-LogMessage "No Lab Services labs found in this subscription" -Level Warning
    }
    
    $executionTime = (Get-Date) - $startTime
    Write-LogMessage "Script completed successfully in $([math]::Round($executionTime.TotalSeconds, 2)) seconds" -Level Success
    
    # Return the lab objects if PassThru is specified
    if ($PassThru) {
        return $allLabs
    }
}
catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
