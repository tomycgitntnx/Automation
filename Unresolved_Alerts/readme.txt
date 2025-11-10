# Collect all unresolved Alerts from all clusters and Prism Centrals listed in cluster.txt

New-Item -Path "$env:USERPROFILE\Documents" -Name "NutanixAlertDashboard" -ItemType Directory -Force
