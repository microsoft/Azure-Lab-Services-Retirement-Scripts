#The MIT License (MIT)
#Copyright (c) Microsoft Corporation  
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

#Requires -Version 5.0
#Requires -Modules Az.Accounts, Az.LabServices

<#
.SYNOPSIS
This script is used to query an existing Azure Lab Services deployment in a customer subscription and report on the results at varying levels of granularity

.DESCRIPTION
This script will query all the labs in the subscription and provide a summary of the labs, including the number of virtual machines, the number of virtual machines assigned to students, the percentage of virtual machines assigned, the number of users, the number of users with no usage, the number of users with low usage, the total hours used by all users, and the overall engagement of users.  The script can be run at different levels of detail, from a high-level summary to a detailed report of each lab, including the users and virtual machines in each lab.

There are two 'utilization' metrics measured on the labs:
1)  VM Utilization:  This is the percentage of virtual machines that are assigned to students.  This is a rough measure of how well the lab is being utilized.
2)  User Engagement:  This is the percentage of users who have used their virtual machines for more than 3 hours.  This is a measure of how engaged the users are with the lab.


.PARAMETER -DetailLevel
To adjust the level of detail provided by the report, 1 is the least detailed, and 3 is the most detailed.  Default is 1.
   Detail Level 1:  Show Labs, Region, Assigned VMs, and Unassigned VMs (shows rough resource utilization based on assigned VMs)
   Detail Level 2:  Detail Level 1 plus showing summary of quota usage in each lab (shows user engagement based on users who have used their VMs)
   Detail Level 3:  Readout of each labs details
   Detail Level 4:  Full readout of lab details, users and virtual machines
#>

param
(
    [Parameter(Mandatory=$false, HelpMessage="To adjust the level of detail in report, 1 (least detailed) to 4 (most detailed)")]
    [ValidateSet(1, 2, 3, 4)]
    [int] $DetailLevel = 4,

    [Parameter(Mandatory=$false, HelpMessage="Use the PassThru parameter to return an object containing the results")]
    [switch] $PassThru

)

function isNumeric($x) {
    return $x -is [byte]  -or $x -is [int16]  -or $x -is [int32]  -or $x -is [int64]  `
       -or $x -is [sbyte] -or $x -is [uint16] -or $x -is [uint32] -or $x -is [uint64] `
       -or $x -is [float] -or $x -is [double] -or $x -is [decimal]
}

function color($val) {

    if (isNumeric($val)) {
        if ($val -gt 80) { "Green" } 
        elseif ($val -gt 40) { "Yellow" } 
        else { "Red" } 
    }
    else {
        $color = [System.Console]::ForegroundColor.ToString()
        # in some environments (Mac & Cloud Shell), foreground color isn't set, so default to Gray
        if ($color -eq "-1") { "Gray" }
        else { $color }
    }
}

function Write-LabDetails ($Lab) {
    Write-Host "-----------------------------------------------------------"
    Write-Host " Resource Group: $($lab.ResourceGroupName)  Lab Name: $($lab.Name)" -ForegroundColor DarkCyan
    Write-Host " "
    Write-Host "  Lab Plan Name: $($lab.LabPlan.Name)"
    Write-Host "  Lab Region: $($lab.Location)"
    Write-Host "  Lab SKU: $($lab.SkuName)"
    Write-Host "  Networking: $(if ($lab.NetworkProfileSubnetId) {"Advanced"} else {"Standard"})"
    Write-Host "  Image Type: $(if ($lab.ImageReferenceId) {"Custom Image"} else {"Marketplace Image"})"
    Write-Host "  Os Type: $($lab.VirtualMachineProfileOSType)"
    Write-Host " "
    Write-Host "  Total Virtual Machines: $($lab.'Student-VMs-Count')"
    Write-Host "  Total Virtual Machines assigned to Students:  $($lab.'Assigned-Student-VMs-Count')"
    Write-Host "  Virtual Machine Utilization: $($lab.'VM-Utilization') %" -ForegroundColor (color($lab.'VM-Utilization'))
    Write-Host " "
    Write-Host "  Total Users: $($lab.UserCount)"
    Write-Host "  Users with no usage: $($lab.UsersWithNoUsage)"
    Write-Host "  Users with low usage: $($lab.UsersWithLowUsage)"
    Write-Host "  Total Hours Used by All Users: $($lab.TotalUsedHours)"
    Write-Host "  Overall Engagement of Users: $($lab.UserEngagement) %" -ForegroundColor (color($lab.UserEngagement))
    Write-Host " "
}

# Ensure that the user is logged in
if (-not (Get-AzContext).Subscription.Id) {
    Write-Error "User must be logged in to proceed, please run Connect-AzAccount"
}

# Get all the Lab Plans & Labs (we need this for all labs)
$labplans = Get-AzLabServicesLabPlan
# Each call to Lab Services commandlet generates a warning - since we already display one with
# Get-AzLabServicesLabPlan, we will suppress the others
$labs = Get-AzLabServicesLab -WarningAction SilentlyContinue

# For each of the labs, let's add in the RG Name, lab plan info & VMs info for use later
$labCount = ($labs | Measure-Object).Count
$i = 0

if ($labCount -eq 0) {
    Write-Host "No Labs from Azure Lab Services found in this subscription."
}
else {
    $labs | ForEach-Object {
        Write-Progress -PercentComplete (($i * 100)/$labCount) -Activity "Querying Lab Virtual Machines" -Status "Processing Lab: $($_.Name)"
        $lab = $_
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "LabPlan" -Value ($labplans | Where-Object {$_.Id -ieq $lab.PlanId})
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "LabName" -Value $lab.Name
        $templateVM = $lab | Get-AzLabServicesTemplateVM -WarningAction SilentlyContinue
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "TemplateVm" -Value $templateVM
        $studentVMs = Get-AzLabServicesVM -LabName $_.Name -ResourceGroupName $_.ResourceGroupName -WarningAction SilentlyContinue | Where-Object {if ($templateVM -and $_.Id -ieq $templateVM.Id) { $false } else { $true }}
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "Student-VMs" -Value $studentVMs
        $studentVMsCount = ($studentVMs | Measure-Object).Count
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "Student-VMs-Count" -Value $studentVMsCount 
        $assignedVMsCount = ($studentVMs | Where-Object {$_.ClaimedByUserId} | Measure-Object).Count
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "Assigned-Student-VMs-Count" -Value $assignedVMsCount
        if ($studentVMsCount -gt 0) {
            $VmUtilization = [math]::Round(($assignedVMsCount / $studentVMsCount) * 100, 1)
        }
        else {
            $VmUtilization = "N/A"
        }
        Add-Member -InputObject $_ -MemberType NoteProperty -Name "VM-Utilization" -Value $VmUtilization
    }

    # Detail Level 1 includes info about lab & assigned VMs
    if ($DetailLevel -eq 1) {

        # print out results to the console
        $labs | Format-Table ResourceGroupName, `
                            @{l="LabName";e={$_.Name}}, `
                            Student-VMs-Count, `
                            Assigned-Student-VMs-Count, `
                            @{n="VM-Utilization";e={"$($_.'VM-Utilization') %"}}, `
                            @{l="LabSku";e={$_.SkuName}}, `
                            @{l="Networking";e={if ($_.NetworkProfileSubnetId) {"Advanced"} else {"Standard"}}} `
            | Out-String | Write-Host

    }
    else {

        # loop through labs and enrich data with users info
        $i = 0
        $labs | ForEach-Object {
            Write-Progress -PercentComplete (($i * 100)/$labCount) -Activity "Querying Lab Users" -Status "Processing Lab: $($_.Name)"
            $users = Get-AzLabServicesUser -LabName $_.Name -ResourceGroupName $_.ResourceGroupName -WarningAction SilentlyContinue
            Add-Member -InputObject $_ -MemberType NoteProperty -Name "Users" -Value $users
            $userCount = ($users | Measure-Object).Count
            Add-Member -InputObject $_ -MemberType NoteProperty -Name "UserCount" -Value $userCount
            $usersWithNoUsage = ($users | Where-Object {$_.TotalUsage.TotalHours -eq 0} | Measure-Object).Count
            Add-Member -InputObject $_ -MemberType NoteProperty -Name "UsersWithNoUsage" -Value $usersWithNoUsage
            $usersWithLowUsage = ($users | Where-Object {$_.TotalUsage.TotalHours -lt 1} | Measure-Object).Count
            Add-Member -InputObject $_ -MemberType NoteProperty -Name "UsersWithLowUsage" -Value $usersWithLowUsage
            $userTotalHoursSum = [math]::Round((($users.TotalQuota.TotalHours | Measure-Object).Sum), 1)
            Add-Member -InputObject $_ -MemberType NoteProperty -Name "TotalUsedHours" -Value $userTotalHoursSum
            if ($userCount -gt 0) {
                # Calculate user engagement by dividing users with some usage by total users
                $UserEngagement = [math]::Round((($userCount - $usersWithLowUsage) / $userCount) * 100, 1)
            }
            else {
                $UserEngagement = "N/A"
            }
            Add-Member -InputObject $_ -MemberType NoteProperty -Name "UserEngagement" -Value $UserEngagement
    
        }

        # Detail level 2 adds in user quotas into the table (more queries)
        if ($DetailLevel -eq 2) {
            $labs | Format-Table ResourceGroupName, `
                            @{n="LabName";e={$_.Name}}, `
                            @{n="TotalVirtualMachines";e={$_.'Student-VMs-Count'}}, `
                            @{n="AssignedVMs";e={$_.'Assigned-Student-VMs-Count'}}, `
                            @{n="TotalStudents";e={$_.UserCount}}, `
                            @{n="TotalStudentsWithUsage";e={$_.UserCount - $_.UsersWithLowUsage}}, `
                            @{n="VM-Utilization";e={"$($_.'VM-Utilization') %"}}, `
                            @{n="User-Engagement";e={"$($_.'UserEngagement') %"}}, `
                            @{n="LabSku";e={$_.SkuName}}, `
                            @{n="Networking";e={if ($_.NetworkProfileSubnetId) {"Advanced"} else {"Standard"}}} `
            | Out-String | Write-Host
        }
        # Detail Level 2 adds in information about user quotas (more queries)
        elseif ($DetailLevel -eq 3) {

            foreach ($lab in $labs)
            {
                Write-LabDetails -Lab $lab
            }

            Write-Host "-----------------------------------------------------------"
        }
        # Detail level 3 prints the info above AND also prints out all user & VM details in a table
        else {
        
            foreach ($lab in $labs)
            {
                Write-LabDetails -Lab $lab
                Write-Host "  Users & Virtual Machines"
                if ($lab.'Student-VMs') {
                    $lab.'Student-VMs' | ForEach-Object {
                        if ($_.ClaimedByUserId) {
                            $claimedBy = $_.ClaimedByUserId
                            Add-Member -InputObject $_ -MemberType NoteProperty -Name "User" -Value ($lab.Users | Where-Object {$_.Id -ieq $claimedBy})
                        }
                        else {
                            Add-Member -InputObject $_ -MemberType NoteProperty -Name "User" -Value ([PSCustomObject]@{
                                DisplayName = "VM Not Assigned"
                                Email = ""
                                TotalUsage = [PSCustomObject]@{TotalHours = ""}
                                AdditionalUsageQuota = [PSCustomObject]@{TotalHours = ""}
                            })
                        }
                    }

                    $results = @($lab.'Student-VMs' | Select-Object @{n="DisplayName";e={$_.User.DisplayName}}, `
                                                    @{n="Email";e={$_.User.Email}}, `
                                                    @{n="Status";e={"$($_.User.RegistrationState.ToString())"}}, `
                                                    @{n="TotalHoursUsed";e={$_.User.TotalUsage.TotalHours}}, `
                                                    @{n="AdditionalHoursGranted";e={$_.User.AdditionalUsageQuota.TotalHours}}, `
                                                    @{n="IPAddress";e={if ($_.ConnectionProfilePrivateIPAddress) {$_.ConnectionProfilePrivateIPAddress} else {"Not Published"}}}, `
                                                    @{n="VmStatus";e={"$($_.ProvisioningState.ToString())"}})
                    
                    $results += $lab.Users `
                                    | Where-Object {$_.Id -notin ($lab.'Student-VMs'.ClaimedByUserId)} `
                                    | Select-Object @{n="DisplayName";e={$_.DisplayName}}, `
                                            @{n="Email";e={$_.Email}}, `
                                            @{n="Status";e={$_.RegistrationState.ToString()}}, `
                                            @{n="TotalHoursUsed";e={$_.TotalUsage.TotalHours}}, `
                                            @{n="AdditionalHoursGranted";e={$_.AdditionalUsageQuota.TotalHours}}, `
                                            @{n="IPAddress";e={"No VM Assigned"}}, `
                                            @{n="VmStatus";e={" "}} `
                    
                    $results | Format-Table  `
                            | Out-String -Stream `
                            | ForEach-Object {Write-Host "    $_"}
                }
                else {
                    Write-Host "    No Virtual Machines in this Lab"
                    Write-Host " "
                }
            }

            Write-Host "-----------------------------------------------------------"

        }
    }

    if ($PassThru) {
        # Add the results on the pipeline if the user passed the "PassThru" switch
        return $labs
    }
}
