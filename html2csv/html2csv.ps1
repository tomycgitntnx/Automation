#Requires -Version 5.1

<#
.SYNOPSIS
    This script converts the first HTML table found in a specified HTML file into a CSV file.

.DESCRIPTION
    The script prompts the user for the path to an input HTML file and a path for the output CSV file.
    It parses the HTML, extracts the header and data rows from the first table, and exports them to a CSV file.
    It uses the Internet Explorer COM object for robust HTML parsing, which is available on Windows systems.

.PARAMETER InputHtmlPath
    The full path to the source HTML file containing the table.

.PARAMETER OutputCsvPath
    The full path where the destination CSV file will be created.

.EXAMPLE
    PS C:\> .\Convert-HtmlTableToCsv.ps1

    This will run the script, and you will be prompted to enter the input and output file paths.

.NOTES
    Author: Tomy Carrasco
    Date: 2025-Dec-12
    - This script is designed to parse the *first* table in the HTML file.
    - It assumes the table has a header row using <th> tags.
    - Requires PowerShell 5.1 or later and a Windows environment for the COM object.
#>

# --- Script Parameters ---
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$InputHtmlPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputCsvPath
)

try {
    # --- 1. Get Input and Output File Paths ---

    # If the input path is not provided via parameters, prompt the user.
    if ([string]::IsNullOrWhiteSpace($InputHtmlPath)) {
        $InputHtmlPath = Read-Host -Prompt "Enter the full path to the input HTML file (e.g., C:\Temp\report.html)"
    }

    # Validate that the input file exists.
    if (-not (Test-Path -Path $InputHtmlPath -PathType Leaf)) {
        throw "Error: The specified input file does not exist at '$InputHtmlPath'."
    }

    # If the output path is not provided, prompt the user.
    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Read-Host -Prompt "Enter the full path for the output CSV file (e.g., C:\Temp\output.csv)"
    }

    Write-Host "Reading HTML file from: $InputHtmlPath"

    # --- 2. Parse the HTML File ---

    # Create an instance of the Internet Explorer COM object to parse the HTML.
    # The '-f' (or -Force) parameter on New-Object helps release the COM object if it's already in memory.
    $ie = New-Object -ComObject 'InternetExplorer.Application' -Force
    $ie.Visible = $false # Keep the IE window hidden.

    # Navigate to the local HTML file.
    $ie.Navigate("file://$InputHtmlPath")

    # Wait for the document to be fully loaded before proceeding.
    while ($ie.Busy) {
        Start-Sleep -Seconds 1
    }

    # Store the parsed HTML document object.
    $htmlDocument = $ie.Document

    # --- 3. Extract the Table Data ---

    # Select the first table in the document.
    # To select a different table, you could use its ID, e.g., $htmlDocument.getElementById('myTableId')
    $table = $htmlDocument.getElementsByTagName('table')[0]

    if ($null -eq $table) {
        throw "Error: No <table> element was found in the HTML file."
    }

    # Extract the table header cells (<th>) and clean up the text content.
    $headers = $table.getElementsByTagName('th') | ForEach-Object { $_.innerText.Trim() }

    # Get all rows (<tr>) in the table body.
    $rows = $table.getElementsByTagName('tr')

    # Create an array to hold the data objects for CSV export.
    $dataForCsv = [System.Collections.ArrayList]::new()

    # --- 4. Process Rows and Create Objects ---

    # Loop through each row in the table, skipping the header row (index 0).
    # The loop starts at 1.
    for ($i = 1; $i -lt $rows.Count; $i++) {
        # Get all data cells (<td>) for the current row.
        $cells = $rows[$i].getElementsByTagName('td')

        # Create a new custom PowerShell object to hold the row's data.
        $rowObject = New-Object -TypeName PSObject

        # Loop through each cell in the row and add it as a property to the custom object.
        # The property name is taken from the corresponding header.
        for ($j = 0; $j -lt $headers.Count; $j++) {
            # Get the cell's text, trim whitespace, and add it to the object.
            $cellText = if ($j -lt $cells.Count) { $cells[$j].innerText.Trim() } else { '' }
            Add-Member -InputObject $rowObject -MemberType NoteProperty -Name $headers[$j] -Value $cellText
        }

        # Add the completed row object to our data array.
        [void]$dataForCsv.Add($rowObject)
    }

    # --- 5. Export Data to CSV File ---

    Write-Host "Exporting data to: $OutputCsvPath"

    # Export the array of custom objects to a CSV file.
    # -NoTypeInformation prevents PowerShell type information from being written to the first line.
    $dataForCsv | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

    Write-Host "Successfully converted HTML table to CSV!" -ForegroundColor Green

}
catch {
    # If any errors occurred, write them to the console.
    Write-Error "An error occurred: $($_.Exception.Message)"
}
finally {
    # --- 6. Clean Up ---
    # Ensure the Internet Explorer COM object is closed and released from memory.
    if ($ie) {
        $ie.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ie) | Out-Null
        Remove-Variable -Name 'ie' -Force -ErrorAction SilentlyContinue
    }
}
