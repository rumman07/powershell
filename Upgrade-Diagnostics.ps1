param (
	[Parameter(Mandatory=$true)]
	[string] $SubscriptionName,

	[Parameter(Mandatory=$true)]
    [string] $ResourceGroups,
 
    [Parameter(Mandatory=$false)]
    [string] $OmsWorkspaceName,

    [Parameter(Mandatory=$false)]
    [string] $OmsWorkspaceKey
)

$rgList = $ResourceGroups.Split(',')

if ($rgList.Length -lt 1)
{
    Write-Host "At least one resource group required" -ForegroundColor Red
    Exit
}

$currentDateTime = Get-Date -Format MM-dd-yyyy-HHmmss
$outputFile = "${SubscriptionName}-diagupgrade-${currentDateTime}.csv"
Write-Output "Name, PowerState, ExtensionType, Upgraded" | out-file -FilePath $outputFile

# Authentication setup
$subscriptions = Get-AzureRmSubscription -ErrorAction Ignore
if ($subscriptions -eq $null)
{
    Login-AzureRmAccount
}

Select-AzureRmSubscription -Subscription $SubscriptionName
Write-Host $SubscriptionName -ForegroundColor Green

function Write-Result
{
    param ([string] $Name, [string] $PowerState, [string] $ExtensionType, [string] $Installed )

    $output = "${Name}, ${PowerState}, ${ExtensionType}, ${Installed}"
    # Write-Output $output | out-file -FilePath $outputFile -Append
    Write-Host $output
}

function Add-DiagnosticExtension
{
    <#
    .DESCRIPTION
	    Adds the latest diagnostics extension to a VM

    .PARAMETER ResourceGroup
        The name of a resource group

    .OUTPUT
        New storage account name
    #>

    param (
        [string] $ResourceGroup,
        [string] $VMName,
        [string] $StorageAcctName,
        [string] $SasToken
    )

    $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroup -Name $VMName
    $vmResourceId = $vm.Id

    # Create public config
    $diagConfig = Get-Content linux-diag-pub-settings.json -Raw
    $diagConfig = $diagConfig.Replace("__DIAGNOSTIC_STORAGE_ACCOUNT__", $StorageAcctName)
    $diagConfig = $diagConfig.Replace("__VM_RESOURCE_ID__", $vmResourceId)

    # Create private config
    $diagProtectedSetting = "{'storageAccountName': '$StorageAcctName', 'storageAccountSasToken': '$SasToken'}"

    $Version = '3.0'
    $ExtensionName = 'LinuxDiagnostic'
    $Publisher = 'Microsoft.Azure.Diagnostics'

    Set-AzureRmVMExtension -ResourceGroupName $ResourceGroup -VMName $vm.Name -Location $vm.Location `
        -Name $ExtensionName -Publisher $Publisher `
        -ExtensionType $ExtensionName -TypeHandlerVersion $Version `
        -Settingstring $diagConfig -ProtectedSettingString $diagProtectedSetting
}

function Add-OmsExtension
{
    <#
    .DESCRIPTION
	    Adds the latest OMS extension to a VM

    .PARAMETER ResourceGroup
        The name of a resource group
    .PARAMETER VMName
        The name of the VM
    .PARAMETER WorkspaceId
        OMS workspace ID
    .PARAMETER WorkspaceKey
        OMS workspace ID
    
    .OUTPUT
        New storage account name
    #>

    param (
        [string] $ResourceGroup,
        [string] $VMName,
        [string] $WorkspaceId,
        [string] $WorkspaceKey
    )

    $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroup -Name $VMName
    $vmResourceId = $vm.Id

    # Create public config
    $pubSetting = "{'workspaceId': '$WorkspaceId'}"

    # Create private config
    $protectedSetting = "{'workspaceKey': '$WorkspaceKey'}"

    $Version = '1.*'
    $ExtensionType = 'Microsoft.EnterpriseCloud.Monitoring.OmsAgentForLinux'
    $ExtensionName = 'OmsAgentForLinux'
    $Publisher = 'Microsoft.EnterpriseCloud.Monitoring'

    Set-AzureRmVMExtension -ResourceGroupName $ResourceGroup -VMName $vm.Name -Location $vm.Location `
        -Name $ExtensionName -Publisher $Publisher `
        -ExtensionType $ExtensionType -TypeHandlerVersion $Version `
        -Settingstring $pubSetting -ProtectedSettingString $protectedSetting
}

function Get-DiagnosticsStorageAcct
{
    <#
    .DESCRIPTION
	    Looks to see if a diagnostics storage account (*-diag) exists in the resource group. If not, one is created.

    .PARAMETER ResourceGroup
        The name of a resource group

    .OUTPUT
        New or existing diagnostics storage account name
    #>

    param ( [string] $ResourceGroup)

    $rg = Get-AzureRmResourceGroup -Name $ResourceGroup
    $rgLocation = $rg.Location

    $storageAccts = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroup
    $diagStorageAcct = $storageAccts | Where-Object { $_.StorageAccountName -like "*diag" }

    if ($diagStorageAcct -eq $null)
    {
        $sgName = $ResourceGroup.Replace('-','')
        $sgName = $sgName.Replace('_','')
        $sgName = $sgName + "diag"

        $newStorageAcct = New-AzureRmStorageAccount -ResourceGroupName $ResourceGroup `
                                                    -AccountName  $sgName `
                                                    -SkuName "Standard_LRS" `
                                                    -Location $rgLocation
        
        return $newStorageAcct.StorageAccountName
    }
    else
    {
        return $diagStorageAcct.StorageAccountName
    }
}

function Get-SaSToken
{
    param (
        [string] $ResourceGroup,
        [string] $StorageAccountName
    )

    $storageAccountKeys = Get-AzureRmStorageAccountKey -ResourceGroupName $ResourceGroup -Name $StorageAccountName
    $storageAccountKey = $storageAccountKeys[0].Value
    $context = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageAccountKey
    $sasToken = New-AzureStorageAccountSASToken -Context $context -Service Blob,Table -ResourceType Container,Object -Permission "wlacu"
    return $sasToken
}

foreach ($rg in $ResourceGroups)
{
    $diagStorageAccountName = Get-DiagnosticsStorageAcct -ResourceGroup $rg
    $sasToken = Get-SasToken -ResourceGroup $rg -StorageAccountName $diagStorageAccountName
    $vms = Get-AzureRmVM -ResourceGroupName $rg

    foreach ($vm in $vms)
    {
        $hasDiagnosticExtension = $false
        $hasOmsExtension = $false
        $vmWithStatus = Get-AzureRmVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status
        $powerState = $vmWithStatus.Statuses | Where-Object { $_.code -like "PowerState*" }
        $powerStateDisplay = $powerState.DisplayStatus
        
        if($powerStateDisplay -eq "VM Running")
        {
            $OSTCEExtensions = $vmWithStatus.Extensions | Where-Object { $_.Type -eq "Microsoft.OSTCExtensions.LinuxDiagnostic"}
            if ($OSTCEExtensions.Count -eq 1)
            {
                Remove-AzureRmVMDiagnosticsExtension -ResourceGroupName $rg -VMName $vmWithStatus.Name -Name $OSTCEExtensions[0].Name
            }

            $azureDiagnosticExtensions = $vmWithStatus.Extensions | Where-Object { $_.Type -eq "Microsoft.Azure.Diagnostics.LinuxDiagnostic"}
            if ($azureDiagnosticExtensions.Count -eq 1)
            {
                # Extension is already insatlled
                Write-Result -Name $vmWithStatus.Name -PowerState $powerStateDisplay -ExtensionType $azureDiagnosticExtensions[0].Type -Installed "False"
                $hasDiagnosticExtension = $true
            }

            $OmsExtensions = $vmWithStatus.Extensions | Where-Object { $_.Type -eq "Microsoft.EnterpriseCloud.Monitoring.OmsAgentForLinux"}
            if ($OmsExtensions.Count -eq 1 -and $hasDiagnosticExtension -eq $false)
            {
                # OMS Extension can cause issues when adding the new diagnostic extension. Remove and re-add.
                $hasOmsExtension = $true
                Remove-AzureRmVMDiagnosticsExtension -ResourceGroupName $rg -VMName $vmWithStatus.Name -Name $OmsExtensions[0].Name
            }
            
            if ($hasDiagnosticExtension -eq $false)
            {
                Add-DiagnosticExtension -ResourceGroup $rg -VMName $vmWithStatus.Name -StorageAcctName $diagStorageAccountName -SasToken $sasToken
                Write-Result -Name $vmWithStatus.Name -PowerState $powerStateDisplay -ExtensionType "Microsoft.Azure.Diagnostics.LinuxDiagnostic" -Installed "True"
            }

            # re-add the OMS extension 
            if ($hasOmsExtension -eq $true -and $OmsWorkspaceKey -ne $null)
            {
                Add-DiagnosticExtension -ResourceGroup $rg -VMName $vmWithStatus.Name -StorageAcctName $diagStorageAccountName -SasToken $sasToken
                Write-Result -Name $vmWithStatus.Name -PowerState $powerStateDisplay -ExtensionType "Microsoft.Azure.Diagnostics.LinuxDiagnostic" -Installed "True"
            }

        }
        else {
            # VM is shut down. Can't do anything.
            Write-Result -Name $vmWithStatus.Name -PowerState $powerStateDisplay -ExtensionType "unknown" -Installed "False"
        }
    }
}