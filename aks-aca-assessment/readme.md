# Assess a shared AKS cluster for ACA migration

**Scenario:** You have a shared AKS cluster for low profile applications (with < 5 pods per app) and each application resides in its own namespace.

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
Day    Usage			
Mo	   16h		    Total	168h
Di	   16h		    Usage	54.76%
Mi	   16h		    Idle	45.24%
Do	   16h			
Fr	   16h			
Sa	    6h			
So	    6h			


Example 20% idle profile
Day	   Usage			
Mo	   20h		    Total	168
Di	   20h		    Usage	79.76%
Mi	   20h		    Idle	20.24%
Do	   20h			
Fr	   20h			
Sa	   17h			
So	   17h			
```
