param (    
    [string]
    $SelectedCubeName,
    [string]
    $IncrementalBackupFromDate = "2025-03-02"    
)

function Get-VitaMojoAuthenticationToken {        
    $Uri = "https://vmos2.vmos.io/user/v1/auth"
    $Method = "Post"
    $ContentType = "application/json"
    $Body = @{
        "email" = $Env:vitamojousername
        "password" = $Env:vitamojopassword
        "x-reporting-key" = $env:vitamojoreportingkey
        "x-requested-from" = "management"
    } | ConvertTo-Json
       
    $TokenResponse = Invoke-APIRequest -Uri $Uri -Method $Method -ContentType $ContentType -Body $Body
    
    return $TokenResponse.payload.token.value
}

function Invoke-APIRequest {
    param (
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Method,                
        $Headers,      
        [string] $ContentType,
        [string] $Body
    )

    $InvokeAttempts = 0

    Do {
        If ($InvokeAttempts -gt 0) {            
            Start-Sleep -Seconds 5
            Write-Host "Retrying API call to $URI"
        }

        if ($Headers) {
            $Response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body -StatusCodeVariable "ResponseStatusCode" -SkipHttpErrorCheck
        }
        else {
            $Response = Invoke-RestMethod -Uri $Uri -Method $Method -ContentType $ContentType -Body $Body -StatusCodeVariable "ResponseStatusCode" -SkipHttpErrorCheck
        }

        If ($ResponseStatusCode -ge 400) {            
            Write-Host "API call to $Uri failed. $ResponseStatusCode : $($Response.message)"    
        }        

        $InvokeAttempts = $InvokeAttempts + 1
    }
    While ($ResponseStatusCode -ge 500 -and $InvokeAttempts -lt 5)

    If ($InvokeAttempts -eq 5) {
        Write-Host "API call to $Uri failed 5 times. Exiting..."
        exit 1
    }

    return $Response
}

function Invoke-VitaMojoAPIRequest {
    param (        
        [Parameter(Mandatory)][string] $EndpointName,
        [Parameter(Mandatory)][string] $Method,
        [string] $Body
    )    
       
    $Token = Get-VitaMojoAuthenticationToken
    $Authorization = $Token 

    $Uri = "https://reporting.data.vmos.io/cubejs-api/v1/$($EndpointName)"
    $Headers = @{
        "Authorization" = $Authorization
        "x-reporting-key" = $env:vitamojoreportingkey
    }
    $ContentType = "application/json"

    return Invoke-APIRequest -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body    
}

function Get-AzureStorageAccountContext {
    param (        
        [Parameter(Mandatory)][string] $ContainerName        
    )

    # Connect to Azure as the service principal.
    $SecretSecureString = $Env:azureserviceprincipalsecret | ConvertTo-SecureString -AsPlainText -Force
    $Credential = New-Object -TypeName PSCredential -ArgumentList $Env:azureserviceprincipalid, $SecretSecureString
    Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $Env:azuretenantid -SubscriptionId $Env:azuresubscriptionid > $null

    # Get the Azure storage account.    
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $Env:azureresourcegroupname -AccountName $Env:azurestorageaccountname    

    # Get the Azure storage account container.
    Get-AzStorageContainer -Context $StorageAccount.Context -Name $ContainerName > $null

    # If the Azure storage account container does not exist, create it.
    if ($? -eq $false) {
        New-AzStorageContainer -Name vitamojo -Context $StorageAccount.Context > $null
    }    

    return $StorageAccount.Context
}

function Get-AzureStorageContainerSASToken {
    param (
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $ContainerName        
    )

    # Create a SAS token to use for uploading backup data to the container.
    return New-AzStorageContainerSASToken -Context $Context -Name $ContainerName -Permission racwdl
}

function Get-CubeDimensions {
    param (
        [Parameter(Mandatory)] $Cube
    )
    
    return $Cube.dimensions | Select-Object -ExpandProperty name    
}

function Get-CubeMeasures {
    param (
        [Parameter(Mandatory)] $Cube
    )
    
    $Cube.measures | Select-Object -ExpandProperty name    
}

function Copy-FileToAzureStorage {
    param (        
        [Parameter(Mandatory)][string] $SourceFilename,        
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $ContainerName,        
        [Parameter(Mandatory)][string] $FolderName,
        [Parameter(Mandatory)][string] $Filename        
    )                        
    
    # Copy the file to the Azure storage container.
    $DestinationFilePath = "$ContainerName/$FolderName"

    # Get an Azure storage token    
    $SASToken = Get-AzureStorageContainerSASToken -Context $Context -ContainerName $ContainerName    

    & ./azcopy copy $SourceFilename "https://honestarchive.blob.core.windows.net/$DestinationFilePath/?$SASToken" --check-length=false   

    If (-Not $?) {
        throw "Unable to copy file $SourceFilename to Azure blob storage."
    }

    Write-Host "Data written to Azure blob storage $DestinationFilePath"                    
}

function Remove-FolderFromAzureStorage {
    param (                
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $ContainerName,        
        [Parameter(Mandatory)][string] $FolderName        
    )                        
    
    # Copy the file to the Azure storage container.
    $DestinationFolderPath = "$ContainerName/$FolderName"

    # Get an Azure storage token    
    $SASToken = Get-AzureStorageContainerSASToken -Context $Context -ContainerName $ContainerName    

    & ./azcopy remove $SourceFilename "https://honestarchive.blob.core.windows.net/$DestinationFolderPath/?$SASToken" --recursive

    If (-Not $?) {
        throw "Unable to remove folder $DestinationFolderPath from Azure blob storage. This must be deleted manually before running the backup again."
    }

    Write-Host "Data removed from Azure blob storage $DestinationFolderPath"                    
}

function Copy-VitaMojoQueryResultToAzureStorage {
    param (        
        [Parameter(Mandatory)][string] $TempOutputFolder,
        [Parameter(Mandatory)][string] $AzureStorageContainerOutputFolder,
        [Parameter(Mandatory)] $Dimensions,
        [Parameter(Mandatory)] $Measures,
        [Parameter(Mandatory)] $Filters,
        [Parameter(Mandatory)] $Order,
        [Parameter(Mandatory)] $PageSize,
        [Parameter(Mandatory)] $AzureStorageAccountContext,
        [Parameter(Mandatory)] $AzureStorageContainerName
    )        

    try {        
        $PageIndex = 0         
        
        # Ensure the output folder exists.
        If (-Not (Test-Path -Path $TempOutputFolder)) {
            New-Item -Path $TempOutputFolder -Type Directory
        }

        # Keep requesting the cube's data until the number of rows returned is less than the page size which indicates that there are no more pages.
        Do {        

            # Get the body of the query as JSON.
            $Body = @{
                "query" = @{
                    "measures" = $Measures
                    "dimensions" = $Dimensions
                    "filters" = $Filters
                    "limit" = $PageSize
                    "offset" = $PageIndex * $PageSize
                    "order" = $Order    
                }
            } | ConvertTo-Json -Depth 100        

            $Waiting = $False

            # Keep requesting the page of data until a non-wait response is received.
            Do {        
                If ($Waiting) {
                    Write-Host "Checking for response from API."
                }

                $LoadResponse = Invoke-VitaMojoAPIRequest -EndpointName "load" -Method "Post" -Body $Body            
                $Waiting = $True
            } While ($LoadResponse.error -eq "Continue wait")
                            
            # Use the page number as the latest file index.
            $OutputFileLatestIndex = $PageIndex        
                    
            # If some data has been returned then export it.
            If ($LoadResponse.data.Count -gt 0) {

                # Get the filename in which to store the exported data.
                $OutputFilename = "$('{0:d7}' -f ($OutputFileLatestIndex + 1)).json"
                $TempOutputFilenameWithPath = "$TempOutputFolder/$OutputFilename"

                # Write the data to the file.
                $LoadResponse | ConvertTo-Json -Depth 100 | Out-File $TempOutputFilenameWithPath            

                Copy-FileToAzureStorage -SourceFilename $TempOutputFilenameWithPath -Context $AzureStorageAccountContext -ContainerName $AzureStorageContainerName -FolderName $AzureStorageContainerOutputFolder -Filename $OutputFilename                
            }        
            
            $PageIndex = $PageIndex + 1                
        } While ($LoadResponse.data.Count -eq $PageSize)    
    }
    catch {
        Remove-FolderFromAzureStorage -Context $AzureStorageAccountContext -ContainerName $AzureStorageContainerName -FolderName $AzureStorageContainerOutputFolder
        throw
    }
}

function Copy-TransactionalDataCubeToAzureStorage {  
    param (
        [Parameter(Mandatory)] $Cube,
        [Parameter(Mandatory)] $AzureStorageAccountContext,
        [Parameter(Mandatory)][string] $AzureStorageContainerName,
        [Parameter(Mandatory)] $PageSize
    )
        
    $Dimensions = Get-CubeDimensions -Cube $Cube
    $Measures = Get-CubeMeasures -Cube $Cube    
    
    if ($Cube.name -eq "CashManagement") {
        $UpdatedAtFieldName = "$($Cube.name).updated_at"
    }
    else {
        $UpdatedAtFieldName = "$($Cube.name).updatedAt"
    }

    # Tell the query to order by the updated at field. The order isn't that important but not specifying one causes issues with paged results.
    $Order = @{                     
        $UpdatedAtFieldName = "asc"                     
    }            

    $CubeOutputFolder = $Cube.name
    $TempCubeOutputFolder = "Output/$CubeOutputFolder"
    
    $Context = Get-AzureStorageAccountContext  -ContainerName $AzureStorageContainerName
    $Blobs = Get-AzStorageBlob -Context $Context -Container $AzureStorageContainerName | Where-Object { $_.Name -like "$CubeOutputFolder/*" }
    $SecondLevelFolders = $Blobs | ForEach-Object { ($_.Name -split "/")[1] } | Sort-Object -Unique    

    # Get the most recent folder date in the output folder.
    $LatestDataDate = $SecondLevelFolders |
        Where-Object { $_ -match "^\d{4}-\d{2}-\d{2}$" } |  # Ensure valid date format
        ForEach-Object { [datetime]::ParseExact($_, "yyyy-MM-dd", $null) } |  # Convert to DateTime
        Sort-Object -Descending |  # Sort newest first
        Select-Object -First 1  # Get the most recent            
    
    # If there are no folders in the output folder then start the fallback date.
    If ($LatestDataDate) {
        $ProcessingDate = $LatestDataDate.AddDays(1).ToString("yyyy-MM-dd")        
    }
    else {
        $ProcessingDate = $IncrementalBackupFromDate
    }   
    
    While ([DateTime]$ProcessingDate -lt (Get-Date -AsUTC).Date) {

        # Get the path of the folder in which to write the exported cube data.
        $OutputFolder = "$CubeOutputFolder/$ProcessingDate"  
        $TempCubeOutputFolder = "$TempCubeOutputFolder/$ProcessingDate"  

        # Tell the query to only return records that have been updated (or created) after the latest export date/time.
        $Filters = @(
            @{
                "member" = $UpdatedAtFieldName
                "operator" = "inDateRange"
                "values" = @(
                    $ProcessingDate, 
                    $ProcessingDate
                )
            }            
        )                    

        Copy-VitaMojoQueryResultToAzureStorage -TempOutputFolder $TempCubeOutputFolder -AzureStorageContainerOutputFolder $OutputFolder -Dimensions $Dimensions -Measures $Measures -Filters $Filters -Order $Order -PageSize $PageSize -AzureStorageContainerName $AzureStorageContainerName -AzureStorageAccountContext $AzureStorageAccountContext

        $ProcessingDate = ([DateTime]$ProcessingDate).AddDays(1).ToString("yyyy-MM-dd")
    }
}

function Copy-NonTransactionalDataCubeToAzureStorage {      
    param (
        [Parameter(Mandatory)] $Cube,
        [Parameter(Mandatory)] $AzureStorageAccountContext,
        [Parameter(Mandatory)] $AzureStorageContainerName,
        [Parameter(Mandatory)] $PageSize
    )
        
    $CubeOutputFolder = $Cube.name
    $TempCubeOutputFolder = "Output/$($Cube.name)"
    $Dimensions = Get-CubeDimensions -Cube $Cube
    $Measures = @(Get-CubeMeasures -Cube $Cube)
    $Filters = @()    
    
    # Tell the query to order by the first dimension field. The order isn't that important but not specifying one causes issues with paged results.
    $Order = @{                     
        $Dimensions[0] = "asc"                     
    }    
    
    Copy-VitaMojoQueryResultToAzureStorage -TempOutputFolder $TempCubeOutputFolder -AzureStorageContainerOutputFolder $CubeOutputFolder -Dimensions $Dimensions -Measures $Measures -Filters $Filters -Order $Order -PageSize $PageSize -AzureStorageContainerName $AzureStorageContainerName -AzureStorageAccountContext $AzureStorageAccountContext
}

# The list of cubes that hold transactional data and so will be exported incrementally.
$TransactionalDataCubeNames = @(
    "CashManagement",
    "OrderItems",
    "OrderTransactions",
    "ReconciliationReports"
)

# The name of the Azure storage container in which to store the backup data.
$AzureStorageContainerName = "vitamojo"

$AzureStorageAccountContext = Get-AzureStorageAccountContext -ContainerName $AzureStorageContainerName

# The maximum number of records to return from each request to the Vita Mojo API.
$PageSize = 10000

# Get the cubes metadata
$MetaResponse = Invoke-VitaMojoAPIRequest -EndpointName "meta" -Method "Get"  

# Loop through each cube and export the data.
$MetaResponse.cubes | ForEach-Object {    
    Write-Host "Exporting cube $($_.name)"    
    
    If (($SelectedCubeName -ne "") -and ($_.name -ne $SelectedCubeName)) {
        return
    }    

    if ($TransactionalDataCubeNames -contains $_.name) {
        Copy-TransactionalDataCubeToAzureStorage -Cube $_ -AzureStorageAccountContext $AzureStorageAccountContext -AzureStorageContainerName $AzureStorageContainerName -PageSize $PageSize
    }
    else {
        Copy-NonTransactionalDataCubeToAzureStorage -Cube $_ -AzureStorageAccountContext $AzureStorageAccountContext -AzureStorageContainerName $AzureStorageContainerName -PageSize $PageSize
    }
}