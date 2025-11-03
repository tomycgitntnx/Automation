PS C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC> C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1
No specific PCs provided. Reading list from 'clusters.txt'.
The following PCs will be queried: D1-NX-PRISM, D2-NX-PRISM, D1-NX-OBJPRISM, D2-NX-OBJPRISM, D1-NX-VDIPRISM, D2-NX-VDIPRISM, S1-NX-PRISM
WARNING: Encryption key file not found at 'C:\Users\xxacarrasco\key.key'. Password must be re-entered.
WARNING: Could not decrypt the password file. Please re-enter the password.
ConvertFrom-SecureString : Cannot bind parameter 'Key'. Cannot convert value "01000000d08c9ddf0115d1118c7a00c04fc297eb0100000035bdb8c35e38274caf3ecd016665d3160000000002000000000003660000c00000001000000066ac239cfa66fea59ea5b8d072da7f500000000004800000a000000010000000930e16f29d0dc3891245979271cec26840000000b8f5096202bb1ac53141623afd7e45b369e7e1e1
440f6a0f25a24c6bb7512ed4cc55921596a3da550fd13d55518a7f3b216f0aa83f04213bc3b522f51b973e55140000003b335a8df53d38285b6d0b9f0b619fe1ab575724" to type "System.Byte". Error: "Input string was not in a correct format."
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:91 char:47
+     $Password | ConvertFrom-SecureString -Key $key | Set-Content $Cre ...
+                                               ~~~~
    + CategoryInfo          : InvalidArgument: (:) [ConvertFrom-SecureString], ParameterBindingException
    + FullyQualifiedErrorId : CannotConvertArgumentNoMessage,Microsoft.PowerShell.Commands.ConvertFromSecureStringCommand
 
Connecting to Prism Central: D1-NX-PRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from D1-NX-PRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
Connecting to Prism Central: D2-NX-PRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from D2-NX-PRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
Connecting to Prism Central: D1-NX-OBJPRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from D1-NX-OBJPRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
Connecting to Prism Central: D2-NX-OBJPRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from D2-NX-OBJPRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
Connecting to Prism Central: D1-NX-VDIPRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from D1-NX-VDIPRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
Connecting to Prism Central: D2-NX-VDIPRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from D2-NX-VDIPRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
Connecting to Prism Central: S1-NX-PRISM
  Fetching alerts (Page 1)...
Get-NutanixUnresolvedAlerts : Failed to retrieve alerts from S1-NX-PRISM. Error: The underlying connection was closed: An unexpected error occurred on a send.
At C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC\get_alerts_pc.ps1:209 char:15
+ ...   $alerts = Get-NutanixUnresolvedAlerts -PC $pc -Credential $Credenti ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException,Get-NutanixUnresolvedAlerts
 
WARNING: No unresolved alerts found on any of the targeted Prism Element clusters.
HTML report generated at: reports\Nutanix_Unresolved_Alerts_11_03_2025__17_19_42.html
Main index file updated: index.html

PS C:\Users\xxacarrasco\Scripting\PS_scripts\Alerts_PC> 
