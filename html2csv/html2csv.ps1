#Requires -Version 5.1

<#
.SYNOPSIS
    This script converts a specific data table from an HTML file into a CSV file.

.DESCRIPTION
    The script prompts for an input HTML file and an output CSV path. It is specifically tailored
    to parse the third table in the provided HTML structure, which contains entity information.
    It intelligently handles empty cells in the first column by carrying forward the last known value.

.PARAMETER InputHtmlPath
    The full path to the source HTML file containing the tables.

.PARAMETER OutputCsvPath
    The full path where the destination CSV file will be created.

.EXAMPLE
    PS C:\> .\Convert-HtmlTableToCsv.ps1

    This will run the script, and you will be prompted to enter the input and output file paths.

.NOTES
    Author: Tomy Carrasco
    Date: 2025-Dec-12
    - This script is designed to parse the *third* table in the HTML file.
    - It requires PowerShell 5.1 or later and a Windows environment for the COM object.
    - It includes special logic to populate empty 'Entity Type' cells.
#>

# --- Script Parameters ---
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$InputHtmlPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputCsvPath
)

# Initialize COM object variable to null
$ie = $null

try {
    # --- 1. Get Input and Output File Paths ---

    if ([string]::IsNullOrWhiteSpace($InputHtmlPath)) {
        $InputHtmlPath = Read-Host -Prompt "Enter the full path to the input HTML file (e.g., C:\Temp\report.html)"
    }

    if (-not (Test-Path -Path $InputHtmlPath -PathType Leaf)) {
        throw "Error: The specified input file does not exist at '$InputHtmlPath'."
    }

    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Read-Host -Prompt "Enter the full path for the output CSV file (e.g., C:\Temp\output.csv)"
    }

    Write-Host "Reading HTML file from: $InputHtmlPath"

    # --- 2. Parse the HTML File ---

    $ie = New-Object -ComObject 'InternetExplorer.Application'
    $ie.Visible = $false

    # Navigate to the local HTML file.
    $ie.Navigate("file://$InputHtmlPath")

    # Wait for the document to be fully loaded.
    while ($ie.Busy) {
        Start-Sleep -Seconds 1
    }

    $htmlDocument = $ie.Document

    # --- 3. Extract the Correct Table and Data ---

    # Get all tables from the document.
    $allTables = $htmlDocument.getElementsByTagName('table')

    # Check if there are enough tables. In the sample HTML, we need the third one (index 2).
    if ($allTables.Count -lt 3) {
        throw "Error: Expected at least 3 tables in the HTML file, but found $($allTables.Count). Cannot find the target data table."
    }

    # **FIXED**: Select the third table (index 2) which contains the entity data.
    $table = $allTables[2]

    # Extract the table header cells (<th>) and clean up the text content.
    $headers = $table.getElementsByTagName('th') | ForEach-Object { $_.innerText.Trim() }

    if ($headers.Count -eq 0) {
        throw "Error: No table headers (<th> tags) were found in the target table. Unable to generate CSV columns."
    }

    # Get all data rows (<tr>) from the target table.
    $rows = $table.getElementsByTagName('tr')

    $dataForCsv = New-Object System.Collections.ArrayList
    $lastEntityType = '' # Variable to hold the 'Entity Type' across rows.

    # --- 4. Process Rows and Create Objects with Special Logic ---

    # Loop through each row, skipping any rows that don't contain data cells (like the header row).
    foreach ($row in $rows) {
        $cells = $row.getElementsByTagName('td')

        # Only process rows that contain data cells.
        if ($cells.Count -gt 0) {
            $rowObject = New-Object -TypeName PSObject

            # **FIXED**: Special handling for the first column ('Entity Type').
            # If the first cell is empty, use the value from the previous row.
            $currentEntityType = $cells[0].innerText.Trim()
            if ([string]::IsNullOrWhiteSpace($currentEntityType)) {
                $entityTypeValue = $lastEntityType
            } else {
                $entityTypeValue = $currentEntityType
                $lastEntityType = $entityTypeValue # Update the last known type.
            }

            # Add the 'Entity Type' to the object.
            Add-Member -InputObject $rowObject -MemberType NoteProperty -Name $headers[0] -Value $entityTypeValue

            # Process the rest of the cells for the current row.
            for ($j = 1; $j -lt $headers.Count; $j++) {
                $cellText = if ($j -lt $cells.Count) { $cells[$j].innerText.Trim() } else { '' }
                Add-Member -InputObject $rowObject -MemberType NoteProperty -Name $headers[$j] -Value $cellText
            }

            [void]$dataForCsv.Add($rowObject)
        }
    }

    # --- 5. Export Data to CSV File ---

    if ($dataForCsv.Count -gt 0) {
        Write-Host "Exporting $($dataForCsv.Count) rows to: $OutputCsvPath"
        $dataForCsv | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Successfully converted HTML table to CSV!" -ForegroundColor Green
    } else {
        Write-Warning "No data rows were found in the target table to export."
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
finally {
    # --- 6. Clean Up ---
    # Ensure the Internet Explorer COM object is closed and released from memory.
    if ($null -ne $ie) {
        $ie.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ie) | Out-Null
        Remove-Variable -Name 'ie' -ErrorAction SilentlyContinue
    }
}
