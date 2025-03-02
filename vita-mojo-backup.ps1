param (    
    [string]
    $SelectedCubeName,
    [string]
    $IncrementalBackupFromDateTime = "2025-02-28T03:00:00"    
)

function Get-VitaMojoAuthenticationToken {
    $Uri = "https://vmos2.vmos.io/user/v1/auth"
    $Method = "Post"
    $ContentType = "application/json"
    $Body = @{
        "email" = $VitaMojoUsername
        "password" = $VitaMojoPassword
        "x-reporting-key" = $VitaMojoReportingKey
        "x-requested-from" = "management"
    } | ConvertTo-Json
       
    $TokenResponse = Invoke-APIRequest -Uri $Uri -Method $Method -ContentType $ContentType -Body $Body
    $TokenResponse.payload.token.value
}

function Invoke-APIRequest {
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri,
        [Parameter(Mandatory)]
        [string]
        $Method,                
        $Headers,      
        [string]
        $ContentType,
        [string]
        $Body
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
        [Parameter(Mandatory)]
        [string]
        $EndpointName,
        [Parameter(Mandatory)]
        [string]
        $Method,
        [string]
        $Body
    )
       
    $Uri = "https://reporting.data.vmos.io/cubejs-api/v1/$($EndpointName)"
    $Headers = @{
        "Authorization" = Get-VitaMojoAuthenticationToken
        "x-reporting-key" = $VitaMojoReportingKey
    }
    $ContentType = "application/json"

    Invoke-APIRequest -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body    
}

function Set-AzureStorageConnection {

    # Connect to Azure as the service principal.
    $AzureServicePrincipalSecretSecureString = $AzureServicePrincipalSecret | ConvertTo-SecureString -AsPlainText -Force
    $AzureServicePrincipalCredential = New-Object -TypeName PSCredential -ArgumentList $AzureServicePrincipalID, $AzureServicePrincipalSecretSecureString
    Connect-AzAccount -ServicePrincipal -Credential $AzureServicePrincipalCredential -Tenant $AzureTenantID -SubscriptionId $AzureSubscriptionID

    # Get the Azure storage account.
    $AzureStorageAccountContext = (Get-AzStorageAccount -ResourceGroupName $AzureResourceGroupName -AccountName $AzureStorageAccountName).Context

    # Get the Azure storage account container.
    Get-AzStorageContainer -Context $AzureStorageAccountContext -Name $AzureStorageContainerName

    # If the Azure storage account container does not exist, create it.
    if ($? -eq $false) {
        New-AzStorageContainer -Name vitamojo -Context $AzureStorageAccountContext    
    }
    
    New-AzStorageContainerSASToken -Context $AzureStorageAccountContext -Name $AzureStorageContainerName -Permission racwdl    
}

function Copy-ToAzureStorage {
    param (
        [Parameter(Mandatory)]
        [string]
        $SourceFilename,        
        [Parameter(Mandatory)]
        [string]
        $FolderName,
        [Parameter(Mandatory)]
        [string]
        $Filename        
    )                    
    
    # Copy the file to the Azure storage container.
    $DestinationFilePath = "$AzureStorageContainerName/$FolderName"
    $SASTokenValue = $SASToken[2]
    & ./azcopy copy $SourceFilename "https://honestarchive.blob.core.windows.net/$DestinationFilePath/?$SASTokenVaLue"    

    Write-Host "Data written to Azure blob storage $DestinationFilePath"                    
}

# The list of cubes that hold transactional data and so will be exported incrementally.
$TransactionalDataCubeNames = @(
    "CashManagement",
    "OrderItems",
    "OrderTransactions",
    "ReconciliationReports"
)

$VitaMojoUsername = $Env:vitamojousername
$VitaMojoPassword = $Env:vitamojopassword
$VitaMojoReportingKey = $env:vitamojoreportingkey
$AzureSubscriptionID = $Env:azuresubscriptionid
$AzureTenantID = $Env:azuretenantid
$AzureServicePrincipalID = $Env:azureserviceprincipalid
$AzureServicePrincipalSecret = $Env:azureserviceprincipalsecret
$AzureResourceGroupName = $Env:azureresourcegroupname
$AzureStorageAccountName = $Env:azurestorageaccountname
$AzureStorageContainerName = "vitamojo"

# The maximum number of records to return from each request to the Vita Mojo API.
$PageSize = 10000

# Get the cubes metadata
$MetaResponse = Invoke-VitaMojoAPIRequest -EndpointName "meta" -Method "Get"  

$SASToken = Set-AzureStorageConnection

# Loop through each cube and export the data.
$MetaResponse.cubes | ForEach-Object {
    $CubeName = $_.name
    Write-Host "Exporting cube $($CubeName)"    
    
    If (($SelectedCubeName -ne "") -and ($CubeName -ne $SelectedCubeName)) {
        return
    }

    $IsTransactionalDataCube = $TransactionalDataCubeNames -contains $CubeName

    # Get the path of the folder in which to write the exported cube data.
    $OutputFolder = "Output/$($CubeName)"

    # Ensure the output folder exists.
    If (-Not (Test-Path -Path $OutputFolder)) {
        New-Item -Path $OutputFolder -Type Directory
    }

    # Get a list of all of the cube's dimensions.
    $Dimensions = @($_ | ForEach-Object {
        $_.dimensions | Select-Object -ExpandProperty name
    })    

    If ($IsTransactionalDataCube) {

        # Get the name of the file which contains the updated date/time of the latest data to have been exported.
        $LatestDataDateTimeFilename = "$($OutputFolder)/latest-data-date-time.txt"

        # If the latest data file exists use the date/time from that file, if it doesn't exist then use the default date/time.
        If (Test-Path -Path $LatestDataDateTimeFilename) {
            $LatestDataDateTime = Get-Content -Path $LatestDataDateTimeFilename -First 1       
        }
        Else {
            $LatestDataDateTime = $IncrementalBackupFromDateTime
        }        
        
        if ($CubeName -eq "CashManagement") {
            $UpdatedAtFieldName = "$($CubeName).updated_at"
        }
        else {
            $UpdatedAtFieldName = "$($CubeName).updatedAt"
        }

        # Tell the query to order by the updated at field. The order isn't that important but not specifying one causes issues with paged results.
        $Order = @{                     
            $UpdatedAtFieldName = "asc"                     
        }        

        # Tell the query to only return records that have been updated (or created) after the latest export date/time.
        $Filters = @(
            @{
                "member" = $UpdatedAtFieldName
                "operator" = "afterDate"
                "values" = @(
                    $LatestDataDateTime
                )
            }
        )                
    }
    Else {
        # Tell the query to order by the first dimension field. The order isn't that important but not specifying one causes issues with paged results.
        $Order = @{                     
            $Dimensions[0] = "asc"                     
        }

        $Filters = @()
    }  

    # Get a list of all of the cube's measures.
    $Measures = @($_ | ForEach-Object {
        $_.measures | Select-Object -ExpandProperty name
    })    
        
    $PageIndex = 0    

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

        # Keep requesting the page of data until a non-wait response is received.
        Do {        
            $LoadResponse = Invoke-VitaMojoAPIRequest -EndpointName "load" -Method "Post" -Body $Body            
        } While ($LoadResponse.error -eq "Continue wait")
                
        If ($IsTransactionalDataCube) {            

            # Get the latest file index by enumerating the existing files, defaulting to 1 if no file exists.
            $OutputFileLatestIndex = [int](Get-ChildItem -Path $OutputFolder -Filter "*.json" |
                ForEach-Object { [int]($_.BaseName) } |
                Measure-Object -Maximum |
                Select-Object -ExpandProperty Maximum) 
        }
        Else {

            # Use the page number as the latest file index.
            $OutputFileLatestIndex = $PageIndex
        }
                
        # If some data has been returned then export it.
        If ($LoadResponse.data.Count -gt 0) {

            # Get the filename in which to store the exported data.
            $OutputFilename = "$('{0:d7}' -f ($OutputFileLatestIndex + 1)).json"
            $OutputFilenameWithPath = "$($OutputFolder)/$($OutputFilename)"

            # Write the data to the file.
            $LoadResponse | ConvertTo-Json -Depth 100 | Out-File $OutputFilenameWithPath

            If ($IsTransactionalDataCube) {

                # Get the updated date/time of the latest data.
                $LastLoadedDateTime = $LoadResponse.data | Measure-Object -Property $UpdatedAtFieldName -Maximum | Select-Object -ExpandProperty Maximum            
            }            

            Copy-ToAzureStorage -SourceFilename $OutputFilenameWithPath -FolderName $CubeName -Filename $OutputFilename
        }        
        
        $PageIndex = $PageIndex + 1                
    } While ($LoadResponse.data.Count -eq $PageSize -and $PageIndex -lt 3)        

    # Write the updated date/time of the latest data to file.
    If ($IsTransactionalDataCube) {
        $LastLoadedDateTime.ToString("yyyy-MM-ddTHH:mm:ss") | Out-File -Path $LatestDataDateTimeFilename
        Copy-ToAzureStorage -SourceFilename $LatestDataDateTimeFilename -FolderName $CubeName -Filename "latest-data-date-time.txt"
    }
}