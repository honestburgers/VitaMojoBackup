Here’s a README tailored specifically for your VitaMojoBackup PowerShell script:

VitaMojoBackup

A PowerShell script for backing up transactional and non-transactional data from the Vita Mojo reporting API. It exports data incrementally, ensuring that only new or updated records are retrieved and stored efficiently.

Features

✅ Authenticates with the Vita Mojo API using email and password
✅ Exports both transactional and non-transactional data
✅ Supports incremental backups for transactional data
✅ Handles large data sets with pagination
✅ Saves backup files in JSON format
✅ Supports scheduled execution for automated backups

Prerequisites
	•	PowerShell 5.1+ (or PowerShell Core for cross-platform support)
	•	A Vita Mojo account with API access
	•	Sufficient storage space for backup files

Installation

Clone the repository or download the script:

git clone https://github.com/The-Kitchen-Sync/VitaMojoBackup.git
cd VitaMojoBackup

Usage

Run the script manually using PowerShell:

.\VitaMojoBackup.ps1 -Email "your-email@example.com" -Password "your-password"

Optional Parameters
	•	-FallbackExportFromDateTime:
If no previous backup is found, this sets the default date-time for incremental exports.
Example:

.\VitaMojoBackup.ps1 -Email "your-email@example.com" -Password "your-password" -FallbackExportFromDateTime "2025-02-26T16:25:00"



How It Works
	1.	Authentication
	•	The script obtains an authentication token from Vita Mojo.
	2.	Retrieve Cube Metadata
	•	Fetches the list of available data “cubes” (tables).
	•	Defines whether each cube is transactional (exported incrementally) or static.
	3.	Data Export
	•	For transactional cubes:
	•	Only exports new/updated records since the last backup.
	•	Stores the latest timestamp in a latest-data-date-time.txt file for future runs.
	•	For non-transactional cubes:
	•	Fetches all data in full each time.
	4.	Data Storage
	•	Saves each data export as a JSON file in Output/{CubeName}/.
	•	Transactional exports are split into numbered files.

Example Output Structure

/Output
  /CashManagement
    0000001.json
    latest-data-date-time.txt
  /OrderItems
    0000001.json
    0000002.json
    latest-data-date-time.txt
  /Stores
    0000001.json

Automating the Backup Process

To schedule automatic backups, use Task Scheduler (Windows) or cron jobs (Linux/macOS).

Windows Task Scheduler Setup
	1.	Open Task Scheduler → “Create Basic Task”.
	2.	Set a schedule (e.g., daily at midnight).
	3.	Choose “Start a Program” and set the action to:

powershell.exe -ExecutionPolicy Bypass -File "C:\Path\To\VitaMojoBackup.ps1" -Email "your-email@example.com" -Password "your-password"


	4.	Save and enable the task.

Logging & Debugging
	•	The script uses Write-Host to output progress messages.
	•	Check for any authentication errors or API rate limits if data is missing.
	•	Debugging tip: Temporarily remove the If ($CubeName -ne "Stores") { return } line to export all cubes.

Contributing

Contributions are welcome! To contribute:
	1.	Fork the repository.
	2.	Create a feature branch:

git checkout -b feature-name


	3.	Commit and push changes.
	4.	Submit a pull request with a clear description.

License

This project is licensed under the MIT License.

Support

For issues or questions, please open an Issue in the repository or contact the maintainers.

Would you like any refinements, such as additional error-handling details or setup instructions?
