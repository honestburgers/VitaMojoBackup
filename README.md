# Vita Mojo backup script

A PowerShell script for backing up data from the **Vita Mojo** reporting API and uploading it to an **Azure** storage account blob.

## Features

✅ Authenticates with the **Vita Mojo** API using username and password  
✅ Backs up both transactional and non-transactional data  
✅ Supports incremental backups for transactional data  
✅ Handles large data sets with pagination  
✅ Saves backup files in JSON format in Microsoft **Azure**  
✅ Supports scheduled execution for automated backups  

## Prerequisites

- **PowerShell 5.1+** (or PowerShell Core for cross-platform support)  
- **Azure Powershell module** [more details...](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell?view=azps-13.2.0)
- **Azcopy** installed in the script directory [more details...](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10?tabs=dnf)
- A **Vita Mojo** account with API access
- An **Azure** account with a storage account and a service principal that has write access

## Installation

Clone the repository or download the script:

````
git clone https://github.com/The-Kitchen-Sync/VitaMojoBackup.git
cd VitaMojoBackup
````

## Usage

Run the script manually using PowerShell:

```
.\VitaMojoBackup.ps1 ` 
  -VitaMojoUsername "your-username" `
  -VitaMojoPassword "your-password" `
  -AzureTenantID "your-tenant-id" `
  -AzureServicePrincipalID "your-service-principal-id" `
  -AzureServicePrincipalSecret "your-service-principal-secret" `
  -AzureResourceGroupName "your-resource-group-name" `
  -AzureStorageAccountName "your-storage-account-name"
```

## Optional Parameters

- **-IncrementalBackupFromDateTime**: If no previous backup is found, this sets the start date/time for incremental backups. Must be specified in yyyy-MM-ddTHH:mm:ss format.

Example:
```
.\VitaMojoBackup.ps1 ` 
  -VitaMojoUsername "your-username" `
  -VitaMojoPassword "your-password" `
  -AzureTenantID "your-tenant-id" `
  -AzureServicePrincipalID "your-service-principal-id" `
  -AzureServicePrincipalSecret "your-service-principal-secret" `
  -AzureResourceGroupName "your-resource-group-name" `
  -AzureStorageAccountName "your-storage-account-name" `
  -IncrementalBackupFromDateTime “2025-02-26T03:00:00”
```

- **-SelectedCubeName**: Only backs up the selected cube.

Example:
```
.\VitaMojoBackup.ps1 ` 
  -VitaMojoUsername "your-username" `
  -VitaMojoPassword "your-password" `
  -AzureTenantID "your-tenant-id" `
  -AzureServicePrincipalID "your-service-principal-id" `
  -AzureServicePrincipalSecret "your-service-principal-secret" `
  -AzureResourceGroupName "your-resource-group-name" `
  -AzureStorageAccountName "your-storage-account-name" `
  -SelectedCubeName “cube-name”
```

## How It Works

1. **Vita Mojo** Authentication
	- The script obtains an authentication token from **Vita Mojo** using the username and password supplied.
2. Retrieve Cube Metadata
	- Fetches the list of available data cubes from the **Vita Mojo** API.
	- Defines whether each cube is transactional (backed up incrementally) or static.
3. Data Export
	- For transactional cubes:
	  - Only exports new/updated records since the last backup.
	  - Stores the latest timestamp in a latest-data-date-time.txt file for future runs.
	- For non-transactional cubes:
	  - Fetches all data in full each time.
4. Data Storage
	- Uploads each backup file as a JSON file to the **Azure** blob container selected.	
	- Transactional exports are split into numbered files.

## Example Output Structure

* /Output  
  * /CashManagement  
    * 0000001.json  
    * latest-data-date-time.txt  
  * /OrderItems  
    * 0000001.json  
    * 0000002.json  
    * latest-data-date-time.txt  
  * /Stores  
    * 0000001.json