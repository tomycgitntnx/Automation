# Create-NCC-ReportIndex.ps1 v1.0  Sept 19, 2025
#
# This script scans the current directory for NCC report folders (e.g., "NCC_Reports_*")
# and generates a master HTML index file with organized links to each report.
# The reports are grouped by month and by week for easy navigation.
#
# Usage:
# 1. Place this script in the same parent folder where your NCC_clusters.ps1 script
#    saves its "NCC_Reports_..." directories.
# 2. Run from PowerShell: .\Create-NCC-ReportIndex.ps1
#
# The script will create or overwrite "NCC_Master_Index.html" in the same folder.

# --- Configuration ---
$reportsBaseDir  = $PSScriptRoot # Use the script's own directory as the base
$masterIndexFile = Join-Path -Path $reportsBaseDir -ChildPath "NCC_Master_Index.html"
$reportDirPattern = "NCC_Reports_*"
$summaryFileName  = "NCC_Summary_Report.html"

Write-Host "Scanning for NCC report directories..." -ForegroundColor Yellow

# Find all report directories and parse their dates from the folder names
$reportData = Get-ChildItem -Path $reportsBaseDir -Directory -Filter $reportDirPattern | ForEach-Object {
    # Extract the timestamp from a directory name like "NCC_Reports_2025_09_19__10_30_00"
    if ($_.Name -match '(\d{4}_\d{2}_\d{2}__\d{2}_\d{2}_\d{2})') {
        $dateString = $Matches[1]
        try {
            # Convert the string into a real DateTime object
            $reportDate = [datetime]::ParseExact($dateString, "yyyy_MM_dd__HH_mm_ss", $null)

            # Output a custom object with all the info we need for grouping and linking
            [PSCustomObject]@{
                Date        = $reportDate
                MonthYear   = $reportDate.ToString("MMMM yyyy")
                WeekNumber  = (Get-Culture).Calendar.GetWeekOfYear($reportDate, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
                RelativePath = $_.Name
            }
        } catch {
            Write-Warning "Could not parse a valid date from directory name: '$($_.Name)'. Skipping."
        }
    }
}

if (-not $reportData) {
    Write-Host "No valid NCC report directories found matching '$reportDirPattern'." -ForegroundColor Red
    $errorMessage = "<h1>No NCC Reports Found</h1><p>No directories matching the pattern '$reportDirPattern' were found in this folder.</p>"
    Set-Content -Path $masterIndexFile -Value $errorMessage
    Start-Process $masterIndexFile
    exit
}

# --- HTML Generation ---
Write-Host "Found $($reportData.Count) reports. Generating master HTML index..." -ForegroundColor Green

# HTML Header and CSS styling, including for collapsible <details> sections
$htmlHead = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nutanix NCC Reports - Master Index</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
        h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
        h2 { font-size: 1.5em; color: #003a70; }
        h3 { font-size: 1.2em; color: #333; border-bottom: 1px solid #ccc; padding-bottom: 5px; margin-top: 25px; }
        ul { list-style-type: none; padding-left: 20px; }
        li { background-color: #fff; margin: 8px 0; padding: 12px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); display: flex; align-items: center; justify-content: space-between; }
        li .date { font-weight: bold; }
        li .links a { margin-left: 15px; text-decoration: none; font-weight: bold; color: #007bff; }
        li .links a:hover { text-decoration: underline; }
        details { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; padding: 10px 20px; }
        summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 10px 0; }
        footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
    </style>
</head>
<body>
    <h1>Nutanix NCC Reports - Master Index</h1>
    <p>Last updated on: $(Get-Date -Format 'dddd, MMMM dd, yyyy HH:mm')</p>
"@

$htmlBody = ""

# Group all reports by Month-Year (e.g., "September 2025")
$groupedByMonth = $reportData | Sort-Object Date -Descending | Group-Object -Property MonthYear

foreach ($monthGroup in $groupedByMonth) {
    # Create a collapsible section for each month
    $htmlBody += "<details open><summary><h2>$($monthGroup.Name)</h2></summary>"

    # Within each month, group the reports by week number
    $groupedByWeek = $monthGroup.Group | Group-Object -Property WeekNumber

    foreach ($weekGroup in $groupedByWeek) {
        $htmlBody += "<h3>Week $($weekGroup.Name)</h3><ul>"

        # Finally, list each report run within that week
        foreach ($report in $weekGroup.Group) {
            $reportSummaryPath = Join-Path -Path $report.RelativePath -ChildPath $summaryFileName
            $reportDateFormatted = $report.Date.ToString("dddd, MMMM dd, yyyy 'at' HH:mm:ss")

            $htmlBody += "<li>"
            $htmlBody += "<span class='date'>$reportDateFormatted</span>"
            $htmlBody += "<span class='links'>"
            $htmlBody += "<a href='$reportSummaryPath' target='_blank'>View Summary Report</a>" # Opens in a new tab
            $htmlBody += "<a href='$($report.RelativePath)/' target='_blank'>Browse Files</a>"
            $htmlBody += "</span>"
            $htmlBody += "</li>"
        }
        $htmlBody += "</ul>"
    }
    $htmlBody += "</details>"
}

$htmlFoot = @"
    <footer>Index generated by Create-NCC-ReportIndex.ps1 v1.0</footer>
</body>
</html>
"@

# Combine all the HTML parts and save the file
$htmlContent = $htmlHead + $htmlBody + $htmlFoot
Set-Content -Path $masterIndexFile -Value $htmlContent

# Automatically open the newly created index page for immediate review
Start-Process $masterIndexFile

Write-Host "Success! Master index page '$masterIndexFile' has been created and opened." -ForegroundColor Green
