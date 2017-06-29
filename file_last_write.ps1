Param(
[Parameter(Mandatory=$true)]
[string]$Path,

[Parameter(Mandatory=$true)]
[string]$LastWrite 
) 

GCI -Path $Path | Where-Object -FilterScript `
 {($_.LastWriteTime -gt $LastWrite)}                