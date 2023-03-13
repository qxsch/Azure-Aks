param(
    [string]$subscriptionName = "",
    [string]$subscriptionGuid = "",
    [string]$month = ""
)

Import-Module Az -ErrorAction Stop
Import-Module Az.OperationalInsights -ErrorAction Stop

if($month -eq "") {
    $month = (Get-Date).AddMonths(-1).ToString("yyyy-MM")
}
if($month -match ([regex] '^(\d{4})-(\d{2})$')) {
    if(([int]$Matches[2]) -lt 1 -or ([int]$Matches[2]) -gt 12) {
        throw ("Invalid month: it should be 01 - 12, but it is "  + $Matches[2])
    }
    if(([int]$Matches[1]) -lt ((Get-Date).Year - 1) -and ([int]$Matches[1]) -gt (Get-Date).Year) {
        throw ("Invalid year: year must be the current or last year")
    }
    $firstDayInMonth = $month + "-01"
    $daysInMonth = [datetime]::DaysInMonth([int]$Matches[1], [int]$Matches[2])
    $lastDayInMonth = $month + "-" + $daysInMonth
    if((Get-Date) -lt (Get-Date "$lastDayInMonth 23:59:59")) {
        throw ("Invalid month: just months in the past are allowed")
    }
}
else {
    throw "Invalid month pattern is: YYYY-MM"
}

if($subscriptionGuid -ne "") {
    Select-AzSubscription -Subscription (Get-AzSubscription -SubscriptionId $subscriptionGuid) -Scope Process | Out-Null
}
elseif($subscriptionName -ne "") {
    Select-AzSubscription -Subscription (Get-AzSubscription -SubscriptionName $subscriptionName) -Scope Process | Out-Null
}

$subscriptionName = (Get-AzContext).Subscription.Name
$subscriptionGuid = (Get-AzContext).Subscription.Id
Write-Host -ForegroundColor Blue "Assessing subscription `"$subscriptionName`" ($subscriptionGuid)"
Write-Host -ForegroundColor Blue "Assessing costs from $firstDayInMonth to $lastDayInMonth"


class CostSummary {
    [string]$ClusterId = ""
    [string]$ClusterName = ""
    [string]$AssessmentTimespan = ""
    [double]$RawPureAksCosts = 0
    [double]$NormalizedPureAksCosts = 0
    CostSummary(
        [string]$ClusterId,
        [string]$ClusterName,
        [string]$AssessmentTimespan,
        [double]$RawPureAksCosts,
        [double]$NormalizedPureAksCosts 
    ) {
        $this.ClusterId              = $ClusterId
        $this.ClusterName            = $ClusterName
        $this.AssessmentTimespan     = $AssessmentTimespan
        $this.RawPureAksCosts        = $RawPureAksCosts
        $this.NormalizedPureAksCosts = $NormalizedPureAksCosts
    }
}

$allCostSummary = @()
foreach($cluster in Get-AzAksCluster) {
    if($cluster.PowerState.Code -ne "Running") {
        continue
    }
    if($null -eq $cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID) {
        continue
    }

    Write-Host ("ID: " + $cluster.Id)
    
    $totalCosts = [double]0
    $data = (Invoke-AzRest -Path ("/subscriptions/$subscriptionGuid/resourceGroups/" + [System.Web.HttpUtility]::UrlEncode($cluster.ResourceGroupName) + "/providers/Microsoft.CostManagement/query?api-version=2022-10-01") -Method Post -Payload (@{
        "type" = "Usage"
        "timeframe" = "Custom"
        "timePeriod" = @{
            "from" = "$firstDayInMonth"
            "to" = "$lastDayInMonth"
        }
        "dataset" = @{
            "granularity" = "None"
            "aggregation" = @{
            "totalCost" = @{
                "name" = "PreTaxCost"
                "function" = "Sum"

            }
            }
            "grouping" = @(
            @{
                "type" = "Dimension"
                "name" = "ResourceId"
            }
            )
        }
    } | ConvertTo-Json -Depth 40)).Content | ConvertFrom-Json -Depth 40
    $rowPosResourceId = 1
    $rowPosCosts      = 0
    $i = 0
    foreach($row in $data.properties.columns) {
        if($row.name -eq "PreTaxCost") {
            $rowPosCosts = $i
        }
        elseif($row.name -eq "ResourceId") {
            $rowPosResourceId = $i
        }
        $i++
    }
    foreach($row in $data.properties.rows) {
        if($row[$rowPosResourceId] -eq $cluster.Id) {
            $totalCosts += [double]$row[$rowPosCosts]
        }
    }

    $data = (Invoke-AzRest -Path ("/subscriptions/$subscriptionGuid/resourceGroups/" + [System.Web.HttpUtility]::UrlEncode($cluster.NodeResourceGroup) + "/providers/Microsoft.CostManagement/query?api-version=2022-10-01") -Method Post -Payload (@{
        "type" = "Usage"
        "timeframe" = "Custom"
        "timePeriod" = @{
            "from" = "$firstDayInMonth"
            "to" = "$lastDayInMonth"
        }
        "dataset" = @{
            "granularity" = "None"
            "aggregation" = @{
            "totalCost" = @{
                "name" = "PreTaxCost"
                "function" = "Sum"
    
            }
            }
            "grouping" = @(
            @{
                "type" = "Dimension"
                "name" = "ResourceType"
            }
            )
        }
    } | ConvertTo-Json -Depth 40)).Content | ConvertFrom-Json -Depth 40
    $rowPosCosts = 0
    $i = 0
    foreach($row in $data.properties.columns) {
        if($row.name -eq "PreTaxCost") {
            $rowPosCosts = $i
        }
        $i++
    }
    foreach($row in $data.properties.rows) {
        $totalCosts += [double]$row[$rowPosCosts]
    }

    Write-Host ("Total Pure AKS Costs: {0,11:f4}" -f @($totalCosts))
    if($totalCosts -gt 0) {
        Write-Host ("Total Pure AKS Costs: {0,11:f4}  (normalized to 30 days)" -f @((($totalCosts / $daysInMonth)* 30)))
        $allCostSummary += [CostSummary]::new($cluster.Id, $cluster.Name, "$firstDayInMonth - $lastDayInMonth", $totalCosts, (($totalCosts / $daysInMonth)* 30))
    }
    else {
        $allCostSummary += [CostSummary]::new($cluster.Id, $cluster.Name, "$firstDayInMonth - $lastDayInMonth", $totalCosts, 0)
    }
}

$allCostSummary | ForEach-Object {
    # clone and round stats
    $o = $_.psobject.copy()
    $o.RawPureAksCosts = [math]::Round($o.RawPureAksCosts, 4)
    $o.NormalizedPureAksCosts = [math]::Round($o.NormalizedPureAksCosts, 4)
    return $o
} | Export-Csv -Path ($subscriptionName + "-summary.csv") -Encoding utf8BOM
