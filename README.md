# Azure-Lab-Services-Retirement-Scripts
This repository provides a set of automation scripts to help Azure Lab Services customers efficiently prepare for and complete their service retirement workflows. The scripts are designed to streamline bulk cleanup, resource validation, and deprovisioning tasks, reducing manual effort and simplifying the overall offboarding process.

## Prerequisites
All scripts require:
- PowerShell 5.0 or higher
- Az PowerShell modules:
  - Az.Accounts
  - Az.LabServices
  - Az.Resources (for some scripts)
  - ThreadJob (for Delete-AzLabServices.ps1)
- Azure account with appropriate permissions for Azure Lab Services

## Script Overview

### 1. Get-AzLabServicesUsage.ps1

**Purpose**: Comprehensive reporting on Azure Lab Services usage across all labs.

**Key Features**:
- Reports VM utilization metrics (percentage of VMs assigned)
- Measures user engagement (percentage of active users)
- Provides detailed lab configuration information
- Multiple detail levels for different reporting needs

**Parameters**:
- `-DetailLevel`: Controls report detail level (1-4, default: 4)
  - Level 1: Basic labs overview with assigned VMs info
  - Level 2: Adds user quota summaries
  - Level 3: Detailed lab-by-lab information
  - Level 4: Complete details including users and VMs
- `-PassThru`: Returns data objects for further processing

**Example Usage**:
```powershell
# Basic usage overview
.\Get-AzLabServicesUsage.ps1 -DetailLevel 1

# Full detailed report
.\Get-AzLabServicesUsage.ps1 -DetailLevel 4

# Get data for further processing
$labData = .\Get-AzLabServicesUsage.ps1 -PassThru
```

### 2. Get-UnusedVMs.ps1

**Purpose**: Identifies underutilized VMs across all Azure Lab Services labs.

**Key Features**:
- Detects VMs with usage below specified threshold
- Identifies unassigned VMs
- Generates separate CSV reports per lab
- Creates summary report across all labs

**Parameters**:
- `-MaxUsageHours`: Maximum usage hours threshold (default: 1.0)
- `-OutputDirectory`: Directory for CSV reports (default: current directory)

**Example Usage**:
```powershell
# Find VMs with less than 1 hour usage (default)
.\Get-UnusedVMs.ps1

# Find VMs with less than 3 hours usage and save reports to specific folder
.\Get-UnusedVMs.ps1 -MaxUsageHours 3 -OutputDirectory "C:\Reports\UnusedVMs"
```

### 3. Get-HighlyUsedVMs.ps1

**Purpose**: Identifies VMs with exceptionally high usage that may indicate misuse.

**Key Features**:
- Detects VMs with usage exceeding specified threshold
- Generates a CSV report with detailed information
- Helps identify potential policy violations or misuse

**Parameters**:
- `-MinHours`: Minimum usage hours threshold (default: 40)
- `-OutputFile`: Path to output CSV file

**Example Usage**:
```powershell
# Default threshold (40 hours)
.\Get-HighlyUsedVMs.ps1

# Custom threshold and output file
.\Get-HighlyUsedVMs.ps1 -MinHours 60 -OutputFile "C:\Reports\HighUsageVMs.csv"
```

### 4. Get-Labs.ps1

**Purpose**: Exports detailed information about all Azure Lab Services labs.

**Key Features**:
- Comprehensive lab details export (configuration, capacity, networking)
- Creates a CSV report for analysis and auditing
- Includes VM and usage details for each lab

**Parameters**:
- `-OutputFile`: Path to output CSV file

**Example Usage**:
```powershell
# Default output file in current directory
.\Get-Labs.ps1

# Custom output file
.\Get-Labs.ps1 -OutputFile "C:\Reports\AllLabs_Inventory.csv"
```

### 5. Get-AzLabServicesUsers.ps1

**Purpose**: Reports on all users across all Azure Lab Services labs.

**Key Features**:
- Identifies both students and teachers based on RBAC permissions
- Maps users to specific labs and lab plans
- Provides detailed user information including usage

**Parameters**:
- `-OutputFile`: Path to output CSV file

**Example Usage**:
```powershell
# Default output file in current directory
.\Get-AzLabServicesUsers.ps1

# Custom output file
.\Get-AzLabServicesUsers.ps1 -OutputFile "C:\Reports\AllUsers.csv"
```

### 6. Delete-Labs.ps1

**Purpose**: Safely deletes Azure Lab Services labs specified in a CSV file.

**Key Features**:
- Takes a CSV file with lab information as input
- Requires confirmation before deletion
- Reports detailed deletion results

**Parameters**:
- `-CsvFilePath`: Path to CSV file containing labs to delete
- `-Force`: Skip confirmation prompt (use with caution)

**Example Usage**:
```powershell
# Delete labs listed in CSV with confirmation prompt
.\Delete-Labs.ps1 -CsvFilePath "C:\Reports\LabsToDelete.csv"

# Delete labs without confirmation (dangerous!)
.\Delete-Labs.ps1 -CsvFilePath "C:\Reports\LabsToDelete.csv" -Force
```

### 7. Delete-AzLabServices.ps1

**Purpose**: Comprehensive cleanup tool for all Azure Lab Services resources.

**Key Features**:
- Parallel processing for efficient deletion
- Handles both v1 (Lab Accounts) and v2 (Lab Plans) resources
- Detailed logging and reporting of deletion results
- WhatIf mode for safe testing

**Parameters**:
- `-MaxConcurrentJobs`: Maximum parallel deletion jobs (default: 10)
- `-OutputFile`: Path for deletion results CSV file
- `-WhatIf`: Run without making actual changes
- `-Force`: Overwrite output file if it exists

**Example Usage**:
```powershell
# Test run without making changes
.\Delete-AzLabServices.ps1 -WhatIf

# Delete with 5 concurrent jobs
.\Delete-AzLabServices.ps1 -MaxConcurrentJobs 5

# Custom output file
.\Delete-AzLabServices.ps1 -OutputFile "C:\Reports\DeletionResults.csv"
```

### 8. Resize-Labs.ps1

**Purpose**: Automatically reduce lab capacity based on unassigned VMs.

**Key Features**:
- Optimizes resource utilization by removing excess capacity
- Works around API limitations by adjusting capacity instead of directly deleting VMs
- Detailed logging and confirmation process
- Can target specific resource groups or all labs

**Parameters**:
- `-ResourceGroupName`: Optional resource group to target
- `-LabName`: Optional specific lab name to target
- `-WhatIf`: Run without making actual changes
- `-Force`: Skip confirmation prompts

**Example Usage**:
```powershell
# Test run showing what would be resized
.\Resize-Labs.ps1 -WhatIf

# Resize all labs (with confirmation)
.\Resize-Labs.ps1

# Resize specific lab without confirmation
.\Resize-Labs.ps1 -ResourceGroupName "MyLabRG" -LabName "DataScience-Lab" -Force
```

## Common Scenarios

### Scenario 1: Monthly Lab Usage Review

To perform a monthly review of lab usage and identify optimization opportunities:

1. Generate comprehensive usage report:
```powershell
.\Get-AzLabServicesUsage.ps1 -DetailLevel 3
```

2. Identify underutilized VMs:
```powershell
.\Get-UnusedVMs.ps1 -MaxUsageHours 2 -OutputDirectory "C:\Reports\August2025"
```

3. Check for potentially misused VMs:
```powershell
.\Get-HighlyUsedVMs.ps1 -MinHours 50 -OutputFile "C:\Reports\August2025\HighUsage.csv"
```

4. Export user information for review:
```powershell
.\Get-AzLabServicesUsers.ps1 -OutputFile "C:\Reports\August2025\AllUsers.csv"
```

### Scenario 2: Lab Capacity Optimization

To reduce costs by optimizing lab capacity based on usage patterns:

1. Generate CSV report of labs with utilization data:
```powershell
.\Get-AzLabServicesUsage.ps1 -DetailLevel 2 -PassThru | Export-Csv -Path "C:\Reports\LabUtilization.csv" -NoTypeInformation
```

2. Find labs with unassigned VMs:
```powershell
.\Get-UnusedVMs.ps1 -OutputDirectory "C:\Reports\Optimization"
```

3. Automatically resize labs to remove unassigned capacity (test first):
```powershell
.\Resize-Labs.ps1 -WhatIf
```

4. Perform actual resize operation:
```powershell
.\Resize-Labs.ps1
```

### Scenario 3: End-of-Term Cleanup

To clean up resources after a term or academic period:

1. Generate comprehensive lab inventory:
```powershell
.\Get-Labs.ps1 -OutputFile "C:\Reports\TermEnd\LabInventory.csv"
```

2. Identify labs to delete (edit CSV as needed):
```powershell
Import-Csv "C:\Reports\TermEnd\LabInventory.csv" | Where-Object { $_.LabName -like "*Spring2025*" } | Select-Object LabName, ResourceGroupName | Export-Csv -Path "C:\Reports\TermEnd\LabsToDelete.csv" -NoTypeInformation
```

3. Review and delete specific labs:
```powershell
.\Delete-Labs.ps1 -CsvFilePath "C:\Reports\TermEnd\LabsToDelete.csv"
```

### Scenario 4: Complete Migration or Environment Shutdown

To completely remove all Azure Lab Services resources when migrating to a new solution:

1. Test deletion process first:
```powershell
.\Delete-AzLabServices.ps1 -WhatIf
```

2. Perform complete deletion:
```powershell
.\Delete-AzLabServices.ps1 -OutputFile "C:\Reports\MigrationCleanup\DeletionResults.csv"
```

## Important Notes

- Always run with `-WhatIf` first for deletion/modification operations
- Use these scripts with appropriate permissions and authorization
- Back up or export important data before deletion operations
- All scripts support detailed logging for audit purposes
- These scripts are designed to work with both v1 and v2 of Azure Lab Services where applicable

## License

The MIT License (MIT)  
Copyright (c) Microsoft Corporation

See license headers in individual scripts for full details.
