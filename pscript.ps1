$arr = @()

for ($i=0; $i -le 9; $i++){

    $obj = New-Object -TypeName PSObject
    Add-Member -InputObject $obj -MemberType NoteProperty -Name Index -Value "$($i)"
    Add-Member -InputObject $obj -MemberType NoteProperty -Name ID -Value "ID$($i+1)"
    Add-Member -InputObject $obj -MemberType NoteProperty -Name Name -Value "Name $($i+1)" 
    $arr+=$obj 
}
$arr.Count 
$arr