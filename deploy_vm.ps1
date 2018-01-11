#Install AzureRM module into powershell 
Install-Module AzureRM -AllowClobber   #The allow clobber option overrides previous installation 
# Modified from the documentation sample at https://docs.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-linux-powershell-sample-create-vm

# Variables for common values
$location = "eastus"
$vmName = "psLabVM"

# Log in to azure
Add-AzureRmAccount

# Get your resource group's name
Get-AzureRmResourceGroup

# Set a variable to be your resource group's name
$resourceGroup = "EnterYourResourceGroupNameHere"

# Create login credentials for your VM
$securePassword = ConvertTo-SecureString 'LinuxAcademy1' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ("pinehead", $securePassword)

# Create a subnet configuration
$subnetConfig = New-AzureRmVirtualNetworkSubnetConfig -Name psLabSubnet -AddressPrefix 10.0.0.0/24

# Create a virtual network
$vnet = New-AzureRmVirtualNetwork -ResourceGroupName $resourceGroup -Location $location -Name psLabVNet -AddressPrefix 10.0.0.0/16 -Subnet $subnetConfig

# Create a public IP address and specify a DNS name
$pip = New-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Location $location -Name "lapslab$(Get-Random)" -AllocationMethod Dynamic -IdleTimeoutInMinutes 4

# Create an inbound network security group rule for port 22, so we can ssh to this machine
$nsgRuleSSH = New-AzureRmNetworkSecurityRuleConfig -Name myNetworkSecurityGroupRuleSSH  -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22 -Access Allow

# Create a network security group
$nsg = New-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroup -Location $location -Name psLabNSG -SecurityRules $nsgRuleSSH

# Create a virtual network card and associate it with the public IP address and NSG
$nic = New-AzureRmNetworkInterface -Name psLabNIC -ResourceGroupName $resourceGroup -Location $location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id

# Create a virtual machine configuration
$vmConfig = New-AzureRmVMConfig -VMName $vmName -VMSize Standard_A1 | Set-AzureRmVMOperatingSystem -Linux -ComputerName $vmName -Credential $cred | Set-AzureRmVMSourceImage -PublisherName Canonical -Offer UbuntuServer -Skus 14.04.2-LTS -Version latest | Set-AzureRmVMOSDisk -Name psLabOSDisk -DiskSizeInGB 128 -CreateOption FromImage -Caching ReadWrite -StorageAccountType StandardLRS | Add-AzureRmVMNetworkInterface -Id $nic.Id

# Create the virtual machine
New-AzureRmVM -ResourceGroupName $resourceGroup -Location $location -VM $vmConfig