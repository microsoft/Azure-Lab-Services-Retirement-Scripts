#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices, Az.Resources

<#
.SYNOPSIS
Script to find all users and teachers across all labs in Azure Lab Services (Lab Plans only, V2).

.DESCRIPTION
This script enumerates all Lab Plans and Labs in the subscription, then lists all users associated with each lab.
For each user, it identifies whether they are a student or a teacher (owner) based on their RBAC permissions.
The script outputs detailed information including Lab Plan info, Lab info, User info, and their role (Student/Teacher).

The output can be exported to a CSV file for further analysis.

.PARAMETER OutputFile
Path to the output CSV file. Default is "AzLabServicesUsers_[timestamp].csv" in the current directory.

.PARAMETER PassThru
Use the PassThru parameter to return an object containing the results.

.EXAMPLE
.\Get-AzLabServicesUsers.ps1

.EXAMPLE
.\Get-AzLabServicesUsers.ps1 -OutputFile "C:\Reports\AllLabUsers.csv"

.EXAMPLE
$allUsers = .\Get-AzLabServicesUsers.ps1 -PassThru
$teachersOnly = $allUsers | Where-Object { $_.Role -eq "Teacher" }
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
    
    # Handle empty messages safely
    if ([string]::IsNullOrWhiteSpace($Message)) {
        # Just write an empty line without timestamp or level
        Write-Host ""
        return
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info" { "White" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Success" { "Green" }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Main execution
try {
    $startTime = Get-Date
    Write-LogMessage "Starting Azure Lab Services users enumeration script"
    
    # Ensure user is logged in
    if (-not (Get-AzContext).Subscription.Id) {
        Write-LogMessage "User must be logged in to proceed. Please run Connect-AzAccount" -Level "Error"
        exit 1
    }

    $subscriptionName = (Get-AzContext).Subscription.Name
    $subscriptionId = (Get-AzContext).Subscription.Id
    Write-LogMessage "Working with subscription: $subscriptionName ($subscriptionId)"
    
    # Set default output file if not specified
    if (-not $OutputFile) {
        $OutputFile = "AzLabServicesUsers_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }
    
    # Validate output directory
    $outputDir = Split-Path -Path $OutputFile -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-LogMessage "Created output directory: $outputDir"
    }
    
    Write-LogMessage "Output file: $OutputFile"
    
    $allUsers = @()
    
    # Get all Labs directly (Lab Plans are sibling resources)
    Write-LogMessage "Getting all Labs..."
    $labs = Get-AzLabServicesLab -WarningAction SilentlyContinue
    
    if (-not $labs) {
        Write-LogMessage "No Labs found in subscription" -Level "Warning"
        exit 0
    }
    
    Write-LogMessage "Found $(($labs | Measure-Object).Count) Labs"
    
    # Process each Lab
    foreach ($lab in $labs) {
        Write-LogMessage "Processing Lab: $($lab.Name)"
        
        # Get registered lab users (typically students)
        $registeredUsers = Get-AzLabServicesUser -LabName $lab.Name -ResourceGroupName $lab.ResourceGroupName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        
        # Get all role assignments directly on the lab (to capture all Lab Services roles)
        # Full list of roles from: https://learn.microsoft.com/en-us/azure/lab-services/concept-lab-services-role-based-access-control
        $labServicesRoles = @(
            # Administrator roles
            "Owner", 
            "Contributor", 
            "Lab Services Contributor",
            
            # Lab management roles
            "Lab Creator",
            "Lab Contributor", 
            "Lab Assistant",
            "Lab Services Reader"
        )
        
        $roleAssignments = Get-AzRoleAssignment -Scope $lab.Id -WarningAction SilentlyContinue | 
                          Where-Object { $_.Scope -eq $lab.Id } | 
                          Where-Object { $_.RoleDefinitionName -in $labServicesRoles }
        
        # Process registered users (students) and teachers separately and add them directly to allUsers
        
        # Process registered students first
        if ($registeredUsers) {
            Write-LogMessage "Found $(($registeredUsers | Measure-Object).Count) registered users in Lab $($lab.Name)"
            
            foreach ($student in $registeredUsers) {
                
                # Create complete standardized student info object with all required properties
                $studentInfo = [PSCustomObject]@{
                    # Subscription info
                    SubscriptionName = $subscriptionName
                    SubscriptionId = $subscriptionId
                    
                    # Lab info
                    LabName = $lab.Name
                    LabId = $lab.Id
                    LabLocation = $lab.Location
                    LabResourceGroup = $lab.ResourceGroupName
                    
                    # User info
                    UserEmail = $student.Email
                    UserDisplayName = $student.DisplayName
                    UserId = $student.Id
                    UserObjectId = $student.Id
                    UserRegistrationState = $student.RegistrationState
                    Role = "Student"  # Directly assign the Student role
                    
                    # Usage info
                    UsageHours = if ($student.TotalUsage) { $student.TotalUsage.TotalHours } else { 0 }
                    AdditionalUsageQuota = if ($student.AdditionalUsageQuota) { $student.AdditionalUsageQuota.TotalHours } else { 0 }
                }
                
                # Add directly to the all users collection
                $allUsers += $studentInfo
            }
        } else {
            Write-LogMessage "No registered users found in Lab $($lab.Name)" -Level "Warning"
        }
        
        # Process teachers with RBAC roles
        if ($roleAssignments) {
            Write-LogMessage "Found $(($roleAssignments | Measure-Object).Count) role assignments in Lab $($lab.Name)"
            
            foreach ($roleAssignment in $roleAssignments) {
                # Skip service principals
                if ($roleAssignment.ObjectType -eq "ServicePrincipal") {
                    continue
                }
                
                # Check if this user has already been processed as a student (now checking in allUsers)
                $existingUser = $allUsers | Where-Object { $_.UserEmail -ieq $roleAssignment.SignInName }
                
                if (-not $existingUser) {
                    # Create complete standardized teacher info object with all required properties
                    $teacherInfo = [PSCustomObject]@{
                        # Subscription info
                        SubscriptionName = $subscriptionName
                        SubscriptionId = $subscriptionId
                        
                        # Lab info
                        LabName = $lab.Name
                        LabId = $lab.Id
                        LabLocation = $lab.Location
                        LabResourceGroup = $lab.ResourceGroupName
                        
                        # User info
                        UserEmail = $roleAssignment.SignInName
                        UserDisplayName = $roleAssignment.DisplayName
                        UserId = $roleAssignment.ObjectId
                        UserObjectId = $roleAssignment.ObjectId
                        UserRegistrationState = "Teacher" # Mark them as teachers directly
                        Role = "Teacher ($($roleAssignment.RoleDefinitionName))"
                        
                        # Usage info (teachers don't have usage stats)
                        UsageHours = ""
                        AdditionalUsageQuota = ""
                    }
                    
                    # Add directly to the all users collection
                    $allUsers += $teacherInfo
                    
                    Write-LogMessage "Added teacher: $($teacherInfo.UserDisplayName) with role $($roleAssignment.RoleDefinitionName)"
                }
                else {
                    # User already exists in allUsers (was also a student)
                    # Update the user's role to indicate they have both roles
                    $existingUser.Role = "Student and Teacher ($($roleAssignment.RoleDefinitionName))"
                    $existingUser.UserRegistrationState = "Student and Teacher" # Update registration state to reflect dual role
                    Write-LogMessage "Updated user $($existingUser.UserDisplayName) to have both student and teacher roles ($($roleAssignment.RoleDefinitionName))"
                }
            }
        }
        
        # Check if we found any users for this lab
        $labUserCount = ($allUsers | Where-Object { $_.LabId -eq $lab.Id } | Measure-Object).Count
        
        if ($labUserCount -eq 0) {
            Write-LogMessage "No users or teachers found in Lab $($lab.Name)" -Level "Warning"
            continue
        }
        
        Write-LogMessage "Added $labUserCount users from Lab $($lab.Name)"
    }
    
    # Export results
    if (($allUsers | Measure-Object).Count -gt 0) {
        $allUsers | Export-Csv -Path $OutputFile -NoTypeInformation
        Write-LogMessage "Successfully exported $(($allUsers | Measure-Object).Count) users to: $OutputFile" -Level "Success"
        
        # Display summary statistics
        Write-LogMessage "=== SUMMARY ===" -Level "Success"
        Write-LogMessage "Total Labs: $(($labs | Sort-Object -Property Id -Unique | Measure-Object).Count)"
        Write-LogMessage "Total Users: $(($allUsers | Measure-Object).Count)"
     
        # Always display usage information in the summary
        $totalUsage = ($allUsers | Measure-Object -Property UsageHours -Sum).Sum
        $avgUsage = ($allUsers | Measure-Object -Property UsageHours -Average).Average
        Write-LogMessage "Total Usage Hours: $([math]::Round($totalUsage, 2))"
        Write-LogMessage "Average Usage Hours per User: $([math]::Round($avgUsage, 2))"
    } else {
        Write-LogMessage "No users found in any Lab" -Level "Warning"
    }
    
    $executionTime = (Get-Date) - $startTime
    Write-LogMessage "Script completed in $([math]::Round($executionTime.TotalSeconds, 2)) seconds"
    
    if ($PassThru) {
        # Return the results on the pipeline if requested
        return $allUsers
    }
} catch {
    Write-LogMessage "Script failed with error: $($_.Exception.Message)" -Level "Error"
    Write-LogMessage "Stack trace:% $($_.ScriptStackTrace)" -Level "Error"
    exit 1
}
