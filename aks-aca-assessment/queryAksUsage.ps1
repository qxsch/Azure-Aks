param(
    [string]$subscriptionName = "",
    [string]$subscriptionGuid = "",
    [string]$month = "",
    [string]$pricesJson = "prices.json"
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
    Select-AzSubscription -Subscription (Get-AzSubscription -SubscriptionId $subscriptionGuid -ErrorAction Stop) -Scope Process | Out-Null
}
elseif($subscriptionName -ne "") {
    Select-AzSubscription -Subscription (Get-AzSubscription -SubscriptionName $subscriptionName -ErrorAction Stop) -Scope Process | Out-Null
}

$subscriptionName = (Get-AzContext).Subscription.Name
$subscriptionGuid = (Get-AzContext).Subscription.Id
Write-Host -ForegroundColor Blue "Assessing subscription `"$subscriptionName`" ($subscriptionGuid)"

$script:prices = ( Get-Content $pricesJson -ErrorAction Stop | ConvertFrom-Json -Depth 40 -AsHashtable -ErrorAction Stop )

class NamespaceConsumptionSummary {
    [string]$ClusterId = ""
    [string]$ClusterName = ""
    [string]$Namespace = ""
    [int]$TotalPods = 0
    [int]$NoStatsPods = 0

    [double] $SumOfAvgCPUUsageCores = 0.0
    [double] $SumOfMaxCPUUsageCores = 0.0
    [double] $SumOfP99CPUUsageCores = 0.0

    [double] $SumOfAvgUsedRssMemoryGBs = 0.0
    [double] $SumOfMaxUsedRssMemoryGBs = 0.0
    [double] $SumOfP99UsedRssMemoryGBs = 0.0

    [double] $priceAvgWithoutIdle = 0.0
    [double] $priceAvgWith45PercentIdle = 0.0
    [double] $priceAvgWith20PercentIdle = 0.0

    [double] $price99thWithoutIdle = 0.0
    [double] $price99thWith45PercentIdle = 0.0
    [double] $price99thWith20PercentIdle = 0.0

    NamespaceConsumptionSummary([string]$ClusterId, [string]$ClusterName, [string]$Namespace) {
        $this.ClusterId = $ClusterId
        $this.ClusterName = $ClusterName
        $this.Namespace = $Namespace
    }

    [void]addUsage(
        [double] $AvgCPUUsageCores,
        [double] $MaxCPUUsageCores,
        [double] $P99CPUUsageCores,
        [double] $AvgUsedRssMemoryGBs,
        [double] $MaxUsedRssMemoryGBs,
        [double] $P99UsedRssMemoryGBs
    ) {
        $this.SumOfAvgCPUUsageCores += $AvgCPUUsageCores
        $this.SumOfMaxCPUUsageCores += $MaxCPUUsageCores
        $this.SumOfP99CPUUsageCores += $P99CPUUsageCores
        $this.SumOfAvgUsedRssMemoryGBs += $AvgUsedRssMemoryGBs
        $this.SumOfMaxUsedRssMemoryGBs += $MaxUsedRssMemoryGBs
        $this.SumOfP99UsedRssMemoryGBs += $P99UsedRssMemoryGBs
    }

    [double] getUsageBasedPrice(
        [double]$idlePercent,
        [int]   $vCPUSecondsFreeGrant,
        [double]$vCPUSteps,
        [double]$vCPUSecondsPrice,
        [double]$vCPUSecondsIdlePrice,
        [int]   $memoryGBSecondsFreeGrant,
        [double]$memoryGBSteps,
        [double]$memoryGBSecondsPrice,
        [double]$memoryGBSecondsIdlePrice,
        [double]$usedCPUCores,
        [double]$usedMemoryGBs
    ) {
        if($idlePercent -lt 0 -or $idlePercent -gt 1) {
            throw "idlePercent must be between 0 and 1"
        }
        $activeSecondsInMonth = (3600 * 24 * 30) * (1 - $idlePercent)
        $idleSecondsInMonth = (3600 * 24 * 30) * $idlePercent

        $price = 0.0

        $price += (([Math]::Ceiling([Math]::Max(($usedMemoryGBs * $activeSecondsInMonth) - $memoryGBSecondsFreeGrant, 0) / $memoryGBSteps) * $memoryGBSteps) * $memoryGBSecondsPrice)
        $price += (([Math]::Ceiling([Math]::Max(($usedMemoryGBs * $idleSecondsInMonth), 0) / $memoryGBSteps) * $memoryGBSteps) * $memoryGBSecondsIdlePrice)
        $price += (([Math]::Ceiling([Math]::Max(($usedCPUCores * $activeSecondsInMonth) - $vCPUSecondsFreeGrant, 0) / $vCPUSteps) * $vCPUSteps) * $vCPUSecondsPrice)
        $price += (([Math]::Ceiling([Math]::Max(($usedCPUCores * $idleSecondsInMonth), 0) / $vCPUSteps) * $vCPUSteps) * $vCPUSecondsIdlePrice)

        return $price
    }

    [NamespaceConsumptionSummary] calculatePrice([string] $location, [bool] $round) {
        $this.priceAvgWithoutIdle = 0.0
        $this.priceAvgWith45PercentIdle = 0.0
        $this.priceAvgWith20PercentIdle = 0.0
        $this.price99thWithoutIdle = 0.0
        $this.price99thWith45PercentIdle = 0.0
        $this.price99thWith20PercentIdle = 0.0
        if($script:prices.ContainsKey($location)) {
            $priceDef = $script:prices[$location]
        }
        elseif($script:prices.ContainsKey("default")) {
            Write-Host -ForegroundColor Yellow "Cannot calculate location-based prices (Using default price)"
            $priceDef = $script:prices["default"]
        }
        else {
            Write-Host -ForegroundColor Red "Cannot calculate prices (No default price has been found)"
            return $this
        }
        if($priceDef -isnot [Hashtable]) {
            Write-Host -ForegroundColor Red "Cannot calculate prices (Data type is not a JSON Object)"
            return $this
        }
        foreach($k in @("vCPUSecondsFreeGrant", "vCPUSecondsPrice", "vCPUSecondsIdlePrice", "vCPUSteps", "memoryGBSecondsFreeGrant", "memoryGBSecondsPrice", "memoryGBSecondsIdlePrice", "memoryGBSteps")) {
            if(-not $priceDef.ContainsKey($k)) {
                Write-Host -ForegroundColor Red "Cannot calculate prices (JSON Object is missing the required key $k)"
                return $this
            }
            if($k -eq "vCPUSecondsFreeGrant" -or $k -eq "memoryGBSecondsFreeGrant") {
                $priceDef[$k] = [int]$priceDef[$k]
            }
            else {
                $priceDef[$k] = [double]$priceDef[$k]
            }
        }
        # no idling calculation
        $this.priceAvgWithoutIdle += $this.getUsageBasedPrice(
            0,
            $priceDef["vCPUSecondsFreeGrant"],
            $priceDef["vCPUSteps"],
            $priceDef["vCPUSecondsPrice"],
            $priceDef["vCPUSecondsIdlePrice"],
            $priceDef["memoryGBSecondsFreeGrant"],
            $priceDef["memoryGBSteps"],
            $priceDef["memoryGBSecondsPrice"],
            $priceDef["memoryGBSecondsIdlePrice"],
            $this.SumOfAvgCPUUsageCores,
            $this.SumOfAvgUsedRssMemoryGBs
        )
        $this.price99thWithoutIdle += $this.getUsageBasedPrice(
            0,
            $priceDef["vCPUSecondsFreeGrant"],
            $priceDef["vCPUSteps"],
            $priceDef["vCPUSecondsPrice"],
            $priceDef["vCPUSecondsIdlePrice"],
            $priceDef["memoryGBSecondsFreeGrant"],
            $priceDef["memoryGBSteps"],
            $priceDef["memoryGBSecondsPrice"],
            $priceDef["memoryGBSecondsIdlePrice"],
            $this.SumOfP99CPUUsageCores,
            $this.SumOfP99UsedRssMemoryGBs
        )
        # 45 percent idle calculation
        $this.priceAvgWith45PercentIdle += $this.getUsageBasedPrice(
            0.45,
            $priceDef["vCPUSecondsFreeGrant"],
            $priceDef["vCPUSteps"],
            $priceDef["vCPUSecondsPrice"],
            $priceDef["vCPUSecondsIdlePrice"],
            $priceDef["memoryGBSecondsFreeGrant"],
            $priceDef["memoryGBSteps"],
            $priceDef["memoryGBSecondsPrice"],
            $priceDef["memoryGBSecondsIdlePrice"],
            $this.SumOfAvgCPUUsageCores,
            $this.SumOfAvgUsedRssMemoryGBs
        )
        $this.price99thWith45PercentIdle += $this.getUsageBasedPrice(
            0.45,
            $priceDef["vCPUSecondsFreeGrant"],
            $priceDef["vCPUSteps"],
            $priceDef["vCPUSecondsPrice"],
            $priceDef["vCPUSecondsIdlePrice"],
            $priceDef["memoryGBSecondsFreeGrant"],
            $priceDef["memoryGBSteps"],
            $priceDef["memoryGBSecondsPrice"],
            $priceDef["memoryGBSecondsIdlePrice"],
            $this.SumOfP99CPUUsageCores,
            $this.SumOfP99UsedRssMemoryGBs
        )
        # 20 percent idle calculation
        $this.priceAvgWith20PercentIdle += $this.getUsageBasedPrice(
            0.20,
            $priceDef["vCPUSecondsFreeGrant"],
            $priceDef["vCPUSteps"],
            $priceDef["vCPUSecondsPrice"],
            $priceDef["vCPUSecondsIdlePrice"],
            $priceDef["memoryGBSecondsFreeGrant"],
            $priceDef["memoryGBSteps"],
            $priceDef["memoryGBSecondsPrice"],
            $priceDef["memoryGBSecondsIdlePrice"],
            $this.SumOfAvgCPUUsageCores,
            $this.SumOfAvgUsedRssMemoryGBs
        )
        $this.price99thWith20PercentIdle += $this.getUsageBasedPrice(
            0.20,
            $priceDef["vCPUSecondsFreeGrant"],
            $priceDef["vCPUSteps"],
            $priceDef["vCPUSecondsPrice"],
            $priceDef["vCPUSecondsIdlePrice"],
            $priceDef["memoryGBSecondsFreeGrant"],
            $priceDef["memoryGBSteps"],
            $priceDef["memoryGBSecondsPrice"],
            $priceDef["memoryGBSecondsIdlePrice"],
            $this.SumOfP99CPUUsageCores,
            $this.SumOfP99UsedRssMemoryGBs
        )

        if($round) {
            $this.priceAvgWithoutIdle        = [math]::Round($this.priceAvgWithoutIdle, 4)
            $this.priceAvgWith45PercentIdle  = [math]::Round($this.priceAvgWith45PercentIdle, 4)
            $this.priceAvgWith20PercentIdle  = [math]::Round($this.priceAvgWith20PercentIdle, 4)
            $this.price99thWithoutIdle       = [math]::Round($this.price99thWithoutIdle, 4)
            $this.price99thWith45PercentIdle = [math]::Round($this.price99thWith45PercentIdle, 4)
            $this.price99thWith20PercentIdle = [math]::Round($this.price99thWith20PercentIdle, 4)
        }

        return $this
    }

}

class PodInfo {
    [string] $ControllerKind
    [string] $ContainerStatus
    [string] $ClusterName
    [string] $Namespace
    [string] $Name
    [string] $PodStatus
    [string] $ClusterId
    [string] $ContainerName
    [string] $_ResourceId
    [string] $UniquePodId = ""

    [double] $AvgCPUUsageCores = 0.0
    [double] $MaxCPUUsageCores = 0.0
    [double] $P99CPUUsageCores = 0.0
    hidden [bool] $UpdatedCPUUsageCores = $false

    [double] $AvgUsedRssMemoryGBs = 0.0
    [double] $MaxUsedRssMemoryGBs = 0.0
    [double] $P99UsedRssMemoryGBs = 0.0
    hidden [bool] $UpdatedUsedRssMemoryGBs = $false

    [void] SetCpuStats([double] $AvgCPUUsageCores, [double] $MaxCPUUsageCores, [double] $P99CPUUsageCores) {
        if($this.hasCpuStats()) {
            Write-Host -ForegroundColor Red "Existing CPU values overwritten (please check kusto summarize query)"
            Write-Host ("`tOld: {0,11:f4} - {1,11:f4} - {2,11:f4}" -f @($this.AvgCPUUsageCores, $this.MaxCPUUsageCores,  $this.P99CPUUsageCores))
            Write-Host ("`tNew: {0,11:f4} - {1,11:f4} - {2,11:f4}" -f @($AvgCPUUsageCores, $MaxCPUUsageCores,  $P99CPUUsageCores))
            $this.AvgCPUUsageCores = ($this.AvgCPUUsageCores + $AvgCPUUsageCores) / 2
            $this.MaxCPUUsageCores = [math]::Max($this.MaxCPUUsageCores, $MaxCPUUsageCores)
            $this.P99CPUUsageCores = [math]::Max($this.P99CPUUsageCores, $P99CPUUsageCores)
        }
        else {
            $this.AvgCPUUsageCores = $AvgCPUUsageCores
            $this.MaxCPUUsageCores = $MaxCPUUsageCores
            $this.P99CPUUsageCores = $P99CPUUsageCores
        }
        $this.UpdatedCPUUsageCores = $true
    }
    [bool]hasCpuStats() {
        return $this.UpdatedCPUUsageCores #($this.AvgCPUUsageCores -ne 0 -or $this.MaxCPUUsageCores -ne 0 -or $this.P99CPUUsageCores -ne 0)
    }
    [void] SetMemStats([double] $AvgUsedRssMemoryGBs, [double] $MaxUsedRssMemoryGBs, [double] $P99UsedRssMemoryGBs) {
        if($this.hasMemStats()) {
            Write-Host -ForegroundColor Red "Existing memory values overwritten (please check kusto summarize query)"
            Write-Host ("`tOld: {0,11:f4} - {1,11:f4} - {2,11:f4}" -f @($this.AvgUsedRssMemoryGBs, $this.MaxUsedRssMemoryGBs,  $this.P99UsedRssMemoryGBs))
            Write-Host ("`tNew: {0,11:f4} - {1,11:f4} - {2,11:f4}" -f @($AvgUsedRssMemoryGBs, $MaxUsedRssMemoryGBs,  $P99UsedRssMemoryGBs))
            $this.AvgUsedRssMemoryGBs = ($this.AvgUsedRssMemoryGBs + $AvgUsedRssMemoryGBs) / 2
            $this.MaxUsedRssMemoryGBs = [math]::Max($this.MaxUsedRssMemoryGBs, $MaxUsedRssMemoryGBs)
            $this.P99UsedRssMemoryGBs = [math]::Max($this.P99UsedRssMemoryGBs, $P99UsedRssMemoryGBs)
        }
        else {
            $this.AvgUsedRssMemoryGBs = $AvgUsedRssMemoryGBs
            $this.MaxUsedRssMemoryGBs = $MaxUsedRssMemoryGBs
            $this.P99UsedRssMemoryGBs = $P99UsedRssMemoryGBs
        }
        $this.UpdatedUsedRssMemoryGBs = $true
    }
    [bool]hasMemStats() {
        return $this.UpdatedUsedRssMemoryGBs #($this.AvgUsedRssMemoryGBs -ne 0 -or $this.MaxUsedRssMemoryGBs -ne 0 -or $this.P99UsedRssMemoryGBs -ne 0)
    }
}

class KubernetesInfo {
    hidden [string] $workspaceId = ""
    hidden $podInventory = @{}

    KubernetesInfo([string] $workspaceId) {
        $this.workspaceId = $workspaceId
        $this.refresh()
    }

    [void] refresh() {
        $this.refresh(7)
    }
    [void] refresh([int] $days) {
        $days = ([int]$days)
        if($days -lt 1) {
            $days = 1
        }
        if($days -gt 90) {
            $days = 90
        }
        # inventory data
        $this.podInventory = @{}
        foreach($rr in (Invoke-AzOperationalInsightsQuery -WorkspaceId $this.workspaceId -Query  'KubePodInventory
| where Namespace !in ("kube-system")
| where ContainerStatus =~ "Running"
| sort  by TimeGenerated asc
| distinct ControllerKind, ContainerStatus, ClusterName, Namespace, Name, PodStatus, ClusterId, ContainerName, _ResourceId
| project ControllerKind, ContainerStatus, ClusterName, Namespace, Name, PodStatus, ClusterId, ContainerName, _ResourceId'  -Timespan (New-TimeSpan -Hours 1) -ErrorAction Stop).Results) {
            $pod = ([PodInfo]$rr)
            $pod.UniquePodId = $rr.ClusterId + "/" +$rr.ContainerName
            $this.podInventory[$pod.UniquePodId] = $pod
        }
        # cpu data
        foreach($rr in (Invoke-AzOperationalInsightsQuery -WorkspaceId $this.workspaceId -Query  ('Perf
| where ObjectName == "K8SContainer" and CounterName == "cpuUsageNanoCores"
| summarize AvgCPUUsageCores = avg(CounterValue) / 1000000000, MaxCPUUsageCores = max(CounterValue) / 1000000000, P99CPUUsageCores = percentile(CounterValue, 99) / 1000000000 by InstanceName')  -Timespan (New-TimeSpan -Days $days) -ErrorAction Stop).Results) {
            if($this.podInventory.ContainsKey($rr.InstanceName)) {
                $this.podInventory[$rr.InstanceName].SetCpuStats($rr.AvgCPUUsageCores, $rr.MaxCPUUsageCores, $rr.P99CPUUsageCores)
            }
        }
        # mem data
        foreach($rr in (Invoke-AzOperationalInsightsQuery -WorkspaceId $this.workspaceId -Query  ('Perf
| where ObjectName == "K8SContainer" and CounterName == "memoryRssBytes"
| summarize AvgUsedRssMemoryGBs = avg(CounterValue) / 1000000000, MaxUsedRssMemoryGBs = max(CounterValue) / 1000000000, P99UsedRssMemoryGBs = percentile(CounterValue, 99) / 1000000000  by InstanceName')  -Timespan (New-TimeSpan -Days $days) -ErrorAction Stop).Results) {
            if($this.podInventory.ContainsKey($rr.InstanceName)) {
                $this.podInventory[$rr.InstanceName].SetMemStats($rr.AvgUsedRssMemoryGBs, $rr.MaxUsedRssMemoryGBs, $rr.P99UsedRssMemoryGBs)
            }
        }
    }

    [string[]] getPodIds() {
        return $this.podInventory.Keys
    }

    [bool] hasPodId([string]$podId) {
        return $this.podInventory.ContainsKey($podId)
    }

    [PodInfo] getPodById([string]$podId) {
        if($this.podInventory.ContainsKey($podId)) {
            return $this.podInventory[$podId]
        }
        return $null
    }

    [PodInfo[]] getPods() {
        return $this.podInventory.Values
    }

    [NamespaceConsumptionSummary[]] getNamespaceConsumptionByClusterId([string]$clusterId, [string]$location) {
        # trying to resolve steps per container
        try {
            if($script:prices.ContainsKey($location)) {
                $memoryGBSteps = [double] $script:prices[$location]["memoryGBSteps"]
                $vCPUSteps = [double] $script:prices[$location]["vCPUSteps"]
            }
            elseif($script:prices.ContainsKey("default")) {
                $memoryGBSteps = [double] $script:prices["default"]["memoryGBSteps"]
                $vCPUSteps = [double] $script:prices["default"]["vCPUSteps"]
            }
            else {
                $memoryGBSteps = 0.25
                $vCPUSteps = 0.25
            }
        }
        catch {
            $memoryGBSteps = 0.25
            $vCPUSteps = 0.25
        }

        $namespaces = @{}
        foreach($pod in $this.getPods()) {
            if($pod.ClusterId -ne $clusterId) {
                continue
            }
            # create namespace if missing
            if(-not $namespaces.ContainsKey($pod.Namespace)) {
                $namespaces[$pod.Namespace] = [NamespaceConsumptionSummary]::new($pod.ClusterId, $pod.ClusterName, $pod.Namespace)
            }
            $namespaces[$pod.Namespace].TotalPods++
            # no stats?
            if(-not ($pod.hasCpuStats() -or $pod.hasMemStats())) {
                $namespaces[$pod.Namespace].NoStatsPods++
                continue
            }
            
            $namespaces[$pod.Namespace].addUsage(
                [Math]::Ceiling($pod.AvgCPUUsageCores / $vCPUSteps) * $vCPUSteps,
                [Math]::Ceiling($pod.MaxCPUUsageCores / $vCPUSteps) * $vCPUSteps,
                [Math]::Ceiling($pod.P99CPUUsageCores / $vCPUSteps) * $vCPUSteps,
                [Math]::Ceiling($pod.AvgUsedRssMemoryGBs / $memoryGBSteps) * $memoryGBSteps,
                [Math]::Ceiling($pod.MaxUsedRssMemoryGBs / $memoryGBSteps) * $memoryGBSteps,
                [Math]::Ceiling($pod.P99UsedRssMemoryGBs / $memoryGBSteps) * $memoryGBSteps
            )
        }
        return $namespaces.Values
    }

}

$workspaceIdCache = @{}
$workspaceKubeInfo = @{}
$clusterNameFormatStr = "{0,-20} in {1,-30}"
$clusterNameErrorFormatStr = "$clusterNameFormatStr ({2})"
foreach($cluster in Get-AzAksCluster) {
    if($cluster.PowerState.Code -ne "Running") {
        Write-Host -ForegroundColor Red ( $clusterNameErrorFormatStr -f @($cluster.Name, $cluster.ResourceGroupName, "Not Running" ))
        continue
    }
    if($null -eq $cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID) {
        Write-Host -ForegroundColor Red ( $clusterNameErrorFormatStr -f @($cluster.Name, $cluster.ResourceGroupName, "Not OMSAgent" ))
        continue
    }
    if(-not $workspaceIdCache.ContainsKey($cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID)) {
        $workspaceIdCache[$cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID] = ((Invoke-AzRest -Path ($cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID + '?api-version=2021-12-01-preview') -Method GET).Content | ConvertFrom-Json -Depth 40).properties.customerId
    }
    $workspaceId = $workspaceIdCache[$cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID]

    Write-Host -ForegroundColor Green ( $clusterNameFormatStr -f @($cluster.Name, $cluster.ResourceGroupName))
    Write-Host ( "  ID:                " + $cluster.Id )
    Write-Host ( "  Location:          " + $cluster.Location )
    Write-Host ( "  FQDN:              " + $cluster.Fqdn )
    Write-Host ( "  NodeResourceGroup: " + $cluster.NodeResourceGroup )
    Write-Host ( "  LogAnalyticsId:    " + $cluster.AddonProfiles.omsAgent.Config.logAnalyticsWorkspaceResourceID )
    Write-Host ( "  WorkspaceId:       " + $workspaceId )

    Write-Host -ForegroundColor Blue "  -> Querying Workspace with id $workspaceId for Kubernetes Usage"
    # create Kubernetes Info if required
    if(-not $workspaceKubeInfo.ContainsKey($workspaceId)) {
        $workspaceKubeInfo[$workspaceId] = [KubernetesInfo]::new($workspaceId)
    }
    Write-Host -ForegroundColor Blue ( "  -> Exporting CSV to: " + ($subscriptionName + "__" + $cluster.ResourceGroupName + "__" + $cluster.Name + ".csv"))
    $workspaceKubeInfo[$workspaceId].getNamespaceConsumptionByClusterId($cluster.Id, $cluster.Location) | ForEach-Object {
        # clone and round stats
        $o = $_.psobject.copy()
        $o.SumOfAvgCPUUsageCores = [math]::Round($o.SumOfAvgCPUUsageCores, 4)
        $o.SumOfMaxCPUUsageCores = [math]::Round($o.SumOfMaxCPUUsageCores, 4)
        $o.SumOfP99CPUUsageCores = [math]::Round($o.SumOfP99CPUUsageCores, 4)
        $o.SumOfAvgUsedRssMemoryGBs = [math]::Round($o.SumOfAvgUsedRssMemoryGBs, 4)
        $o.SumOfMaxUsedRssMemoryGBs = [math]::Round($o.SumOfMaxUsedRssMemoryGBs, 4)
        $o.SumOfP99UsedRssMemoryGBs = [math]::Round($o.SumOfP99UsedRssMemoryGBs, 4)
        $o.calculatePrice($cluster.Location, $true)
        return $o
    } | Export-Csv -Path ($subscriptionName + "__" + $cluster.ResourceGroupName + "__" + $cluster.Name + ".csv") -Encoding utf8BOM
}

