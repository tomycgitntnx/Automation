
# Create-NCC-ReportIndex.ps1 v1.1  Sep 23, 2025

#
# This script scans for NCC report folders and generates a master HTML dashboard.

# v1.1 - Reworked to parse individual cluster reports and display a detailed,

#        color-coded status breakdown directly on the master index page.

#        The layout is a dashboard showing each run with its cluster statuses.

#
# Usage:

# 1. Place this script in the same parent folder where your NCC_clusters.ps1 script

#    saves its "NCC_Reports_..." directories.

# 2. Run from PowerShell: .\Create-NCC-ReportIndex.ps1

#
# The script will create or overwrite "NCC_Master_Index.html" in the same folder.

# --- Configuration ---
$reportsBaseDir  = $PSScriptRoot
$masterIndexFile = Join-Path -Path $reportsBaseDir -ChildPath "NCC_Master_Index.html"
$reportDirPattern = "NCC_Reports_*"
$summaryFileName  = "NCC_Summary_Report.html"
$clusterReportFilter = "*-NCC_Report.txt"

Write-Host "Scanning for NCC report directories..." -ForegroundColor Yellow

# Find all report directories
$reportDirs = Get-ChildItem -Path $reportsBaseDir -Directory -Filter $reportDirPattern | Sort-Object Name -Descending

if (-not $reportDirs) {
    Write-Host "No valid NCC report directories found matching '$reportDirPattern'." -ForegroundColor Red
    $errorMessage = "<h1>No NCC Reports Found</h1><p>No directories matching the pattern '$reportDirPattern' were found in this folder.</p>"
    Set-Content -Path $masterIndexFile -Value $errorMessage
    Start-Process $masterIndexFile
    exit
}

# --- HTML Generation ---
Write-Host "Found $($reportDirs.Count) report runs. Generating master HTML dashboard..." -ForegroundColor Green

# HTML Header and CSS styling
$htmlHead = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nutanix NCC Reports - Master Dashboard</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
        h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
        h2 { font-size: 1.5em; color: #003a70; }
        h3 { font-size: 1.2em; color: #333; border-bottom: 1px solid #ccc; padding-bottom: 5px; margin-top: 25px; }
        details { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; padding: 10px 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.05); }
        summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 10px 0; }
        .run-container { border: 1px solid #e0e0e0; border-radius: 5px; margin-bottom: 25px; background: #fff; }
        .run-header { background-color: #e9ecef; padding: 12px; border-bottom: 1px solid #ddd; display: flex; justify-content: space-between; align-items: center; }
        .run-header .date { font-weight: bold; font-size: 1.1em; color: #333; }
        .run-header a { text-decoration: none; font-weight: bold; color: #007bff; }
        .cluster-table { width: 100%; border-collapse: collapse; }
        .cluster-table th, .cluster-table td { border-bottom: 1px solid 
