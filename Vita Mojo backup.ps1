param (
    [Parameter(Mandatory)]
    $Email,
    [Parameter(Mandatory)]
    $Password
)

function Get-VitaMojoAuthenticationToken {
    param (
        $Email,
        $Password
    )

    $Uri = "https://vmos2.vmos.io/user/v1/auth"
    $Method = "Post"
    $ContentType = "application/json"
    $Body = @{
        "email" = $Email
        "password" = $Password
    } | ConvertTo-Json

    $TokenResponse = Invoke-RestMethod -Uri $Uri -Method $Method -ContentType $ContentType -Body $Body
    $TokenResponse.payload.token.value
}

Write-Host "Start"

$Token = Get-VitaMojoAuthenticationToken -Email $Email -Password $Password

$Headers = @{
    'Authorization'=$Token
}

$MetaResponse = Invoke-RestMethod -Uri "https://reporting.data.vmos.io/cubejs-api/v1/meta" -Method "Get" -Headers $Headers -ContentType "application/json"

$TransactionalTables = @(
    "CashManagement",
    "OrderItems",
    "OrderTransactions",
    "ReconciliationReports"
)

$MetaResponse.cubes | ForEach-Object {
    if ($_.name -ne "Stores") {
        return
    }

    $Dimensions = @($_ | ForEach-Object {
        $_.dimensions | Select-Object -ExpandProperty name    
    })

    if ($TransactionalTables -contains $_.name) {
        $Order = @{                     
            "$($_.name).updatedAt" = "asc"                     
        }

        $Filters = @(
            @{
                "member" = "$($_.name).updatedAt"
                "operator" = "afterDate"
                "values" = @(
                    "2025-02-25"
                )
            }
        )        
    }
    else {
        $Order = @{                     
            $Dimensions[0] = "asc"                     
        }

        $Filters = @()
    }  

    $Measures = @($_ | ForEach-Object {
        $_.measures | Select-Object -ExpandProperty name
    })    

    $PageSize = 10000
    $PageIndex = 0

    Do {
        Write-Host $PageIndex

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

        Do {
            $LoadResponse = Invoke-RestMethod -Uri "https://reporting.data.vmos.io/cubejs-api/v1/load" -Method "Post" -Headers $Headers -ContentType "application/json" -Body $Body
        } While ($LoadResponse.error -eq "Continue wait")

        $OutputFolder = "Output/$($_.name)"
        New-Item -Path $OutputFolder -Type Directory -Force
        $LoadResponse | ConvertTo-Json -Depth 100 | Out-File "$($OutputFolder)/$('{0:d7}' -f ($PageIndex + 1)).json"
        $PageIndex = $PageIndex + 1            
    } While ($LoadResponse.data.Count -eq $PageSize)        
}

Write-Host "Finish"