$SecurePassword = Read-Host "Enter the password" -AsSecureString 
$SecurePassword | ConvertFrom-SecureString | Set-Content "D:\Scripts\Nutanix - Run Weekly\Collector\.secretpw.txt" 
# Hide the file 
# attrib +H +S "$env:USERPROFILE\scripts\.secretpw.txt"