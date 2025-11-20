#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices

<#
.SYNOPSIS
Deletes Azure Lab Services labs specified in a CSV file.

.DESCRIPTION
This script reads a CSV file containing information about Azure Lab Services labs, provides a summary 
to the user, asks for confirmation, and then deletes all the specified labs if approved.
The deletion is irreversible, so a confirmation step is required.

.PARAMETER CsvFilePath
Path to the CSV file containing the list of labs to delete. The CSV file must contain at least
the following columns: LabName, ResourceGroupName.

.PARAMETER Force
When specified, skips the confirmation prompts and proceeds with deletion.
Use with caution as this will immediately delete resources without confirmation.

.PARAMETER WhatIf
Shows what would happen if the script runs. The labs are not actually deleted.

.EXAMPLE
.\Delete-Labs.ps1 -CsvFilePath "AzureLabServices_Labs_20250827.csv"
Reads the specified CSV file, displays a summary, and prompts for confirmation before deleting labs.

.EXAMPLE
.\Delete-Labs.ps1 -CsvFilePath "AzureLabServices_Labs_20250827.csv" -Force
Reads the specified CSV file and deletes all labs without prompting for confirmation.

.EXAMPLE
.\Delete-Labs.ps1 -CsvFilePath "AzureLabServices_Labs_20250827.csv" -WhatIf
Shows what labs would be deleted without actually deleting them.
#>

param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="Path to the CSV file containing lab information")]
    [ValidateNotNullOrEmpty()]
    [string] $CsvFilePath,
    
    [Parameter(Mandatory=$false, HelpMessage="Skip confirmation prompts")]
    [switch] $Force,
    
    [Parameter(Mandatory=$false, HelpMessage="Show what would happen without making changes")]
    [switch] $WhatIf
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

function Read-CsvFile {
    param (
        [Parameter(Mandatory=$true)]
        [string] $FilePath
    )
    
    try {
        # Verify the file exists
        if (-not (Test-Path -Path $FilePath)) {
            throw "CSV file not found: $FilePath"
        }
        
        # Import the CSV file
        $data = Import-Csv -Path $FilePath
        
        # Verify the CSV has the required columns
        $requiredColumns = @("LabName", "ResourceGroupName")
        $missingColumns = $requiredColumns | Where-Object { $_ -notin $data[0].PSObject.Properties.Name }
        
        if (($missingColumns | Measure-Object).Count -gt 0) {
            throw "CSV file is missing required columns: $($missingColumns -join ', ')"
        }
        
        return $data
    }
    catch {
        Write-LogMessage "Error reading CSV file: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-LabSummary {
    param (
        [Parameter(Mandatory=$true)]
        $Labs
    )
    
    try {
        $labCount = ($Labs | Measure-Object).Count
        Write-LogMessage "Found $labCount labs in the CSV file" -Level Info
        
        if ($labCount -eq 0) {
            return
        }
        
        # Gather lab statistics
        $resourceGroupsCount = ($Labs | Select-Object -Property ResourceGroupName -Unique | Measure-Object).Count
        $locationsCount = if ($Labs[0].PSObject.Properties.Name -contains "Location") {
            ($Labs | Select-Object -Property Location -Unique | Measure-Object).Count
        } else { "N/A" }
        
        $vmCount = if ($Labs[0].PSObject.Properties.Name -contains "TotalVMs") {
            ($Labs | Measure-Object -Property TotalVMs -Sum).Sum
        } else { "N/A" }
        
        # Display summary table
        Write-LogMessage "=== LABS SUMMARY ===" -Level Warning
        Write-LogMessage "Total labs to delete: $labCount" -Level Warning
        Write-LogMessage "Resource groups affected: $resourceGroupsCount" -Level Warning
        
        if ($locationsCount -ne "N/A") {
            Write-LogMessage "Azure locations affected: $locationsCount" -Level Warning
        }
        
        if ($vmCount -ne "N/A") {
            Write-LogMessage "Total VMs that will be deleted: $vmCount" -Level Warning
        }
        
        # List the first 10 labs (if more than 20)
        Write-LogMessage " "
        Write-LogMessage "Labs that will be deleted:" -Level Warning
        $displayCount = [Math]::Min($labCount, 20)
        
        for ($i = 0; $i -lt $displayCount; $i++) {
            Write-LogMessage "  ⦿ $($Labs[$i].LabName) (Resource Group: $($Labs[$i].ResourceGroupName))" -Level Warning
        }
        
        if ($labCount -gt 20) {
            Write-LogMessage "  - ... and $($labCount - 20) more labs" -Level Warning
        }
    }
    catch {
        Write-LogMessage "Error generating lab summary: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Remove-LabsFromCsv {
    param (
        [Parameter(Mandatory=$true)]
        $Labs,
        
        [Parameter(Mandatory=$false)]
        [switch] $WhatIfMode
    )
    
    try {
        $totalCount = ($Labs | Measure-Object).Count
        $deletedCount = 0
        $errorCount = 0
        
        Write-LogMessage "Starting deletion of $totalCount labs..." -Level Info
        
        $i = 0
        foreach ($lab in $Labs) {
            $i++
            $labName = $lab.LabName
            $resourceGroupName = $lab.ResourceGroupName
            
            try {
                Write-Progress -Activity "Deleting Azure Lab Services labs" -Status "Processing lab $i of $totalCount" -PercentComplete (($i * 100) / $totalCount)
                
                # Verify the lab exists
                $existingLab = Get-AzLabServicesLab -Name $labName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
                
                if (-not $existingLab) {
                    Write-LogMessage "Lab not found: $labName in resource group $resourceGroupName" -Level Warning
                    $errorCount++
                    continue
                }
                
                # Delete the lab
                if ($WhatIfMode) {
                    Write-LogMessage "WhatIf: Would delete lab $labName from resource group $resourceGroupName" -Level Warning
                } else {
                    Write-LogMessage "Deleting lab $labName from resource group $resourceGroupName..." -Level Info
                    Remove-AzLabServicesLab -Name $labName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    Write-LogMessage "Successfully deleted lab $labName" -Level Success
                }
                
                $deletedCount++
            }
            catch {
                Write-LogMessage "Error deleting lab $labName from resource group $resourceGroupName : $($_.Exception.Message)" -Level Error
                $errorCount++
            }
        }
        
        Write-Progress -Activity "Deleting Azure Lab Services labs" -Completed
        
        # Return deletion results
        return @{
            TotalCount = $totalCount
            DeletedCount = $deletedCount
            ErrorCount = $errorCount
        }
    }
    catch {
        Write-LogMessage "Error during lab deletion process: $($_.Exception.Message)" -Level Error
        throw
    }
}

# Main script execution
try {
    $startTime = Get-Date
    Write-LogMessage "Starting Azure Lab Services lab deletion script" -Level Info
    
    # Ensure user is logged in
    if (-not (Get-AzContext).Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level Error
        exit 1
    }
    
    # Display current subscription context
    $currentContext = Get-AzContext
    Write-LogMessage "Current subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" -Level Info
    
    # Read the CSV file
    Write-LogMessage "Reading lab information from CSV file: $CsvFilePath" -Level Info
    $labs = Read-CsvFile -FilePath $CsvFilePath
    
    # Display lab summary
    Get-LabSummary -Labs $labs
    
    # Confirmation step
    if (-not $WhatIf -and -not $Force) {
        Write-LogMessage "`n⚠️ WARNING: This operation will DELETE all labs listed above! This action is IRREVERSIBLE! ⚠️" -Level Warning
        $confirmation = Read-Host "Are you sure you want to proceed? Type 'YES' to confirm"
        
        if ($confirmation -ne "YES") {
            Write-LogMessage "Deletion cancelled. No changes were made." -Level Warning
            exit 0
        }
    }
    
    # Perform the deletion
    $deletionResults = Remove-LabsFromCsv -Labs $labs -WhatIfMode:$WhatIf
    
    # Display results
    if ($WhatIf) {
        Write-LogMessage "`n=== WHATIF SUMMARY ===" -Level Success
        Write-LogMessage "Would have deleted $($deletionResults.DeletedCount) labs" -Level Info
        if ($deletionResults.ErrorCount -gt 0) {
            Write-LogMessage "Would have encountered errors with $($deletionResults.ErrorCount) labs" -Level Warning
        }
    } else {
        Write-LogMessage "`n=== DELETION SUMMARY ===" -Level Success
        Write-LogMessage "Successfully deleted $($deletionResults.DeletedCount) labs" -Level Success
        if ($deletionResults.ErrorCount -gt 0) {
            Write-LogMessage "Failed to delete $($deletionResults.ErrorCount) labs" -Level Warning
        }
    }
    
    $executionTime = (Get-Date) - $startTime
    Write-LogMessage "Script completed in $([math]::Round($executionTime.TotalSeconds, 2)) seconds" -Level Success
}
catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
