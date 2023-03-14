# Assess a shared AKS cluster for ACA migration

**Scenario:** You have a shared AKS cluster for low profile applications (with < 5 pods per app) and each application resides in its own namespace.
 1. Edit the ``prices.json`` file with your prices. You can also get the list prices in your currency here: https://azure.microsoft.com/en-us/pricing/details/container-apps/
 1. Run the script to assess all AKS clusters in a subscription: ``./queryAksUsage.ps1`` ( you can optionally use ``-susbcriptionId`` or ``-subscriptionName`` to set the process context )
    * It will give you estimates for 3 scenarios (no idling, 45% idle, 20% idle)
    * For each scenario you get price calculation based on avg and 99th percentile
 1. Run the script to get the current pure AKS costs: ``./queryPureAksCosts.ps1`` ( you can optionally use ``-susbcriptionId`` or ``-subscriptionName`` to set the process context )


## Why average and 99th percentile?
Depending on the workload, the costs will usually be between average and 99th percentile. So the assessment can give you a range (from better to worse case).

## Why 45% and 20% idling?
The assessment is based on common usage patterns as stated below:
```
Example 45% idle profile
Day   |   Usage
------+--------
Mon   |   16h		    Total	168h
Tue   |   16h		    Usage	54.76%
Wed   |   16h		    Idle    45.24%
Thu   |   16h
Fri   |   16h
Sat   |    6h
Sun   |    6h


Example 20% idle profile
Day   |   Usage
------+--------
Mon   |   20h		    Total	168
Tue   |   20h		    Usage	79.76%
Wed   |   20h		    Idle    20.24%
Thu   |   20h
Fri   |   20h
Sat   |   17h
Sun   |   17h
```
