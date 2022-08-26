param(
    [Parameter(Mandatory=$true)]
    [string]$resourcegroup = "aks-fuseblob-mi",

    [Parameter(Mandatory=$true)]
    [string]$storageaccountname = "myaksblob",

    [Parameter(Mandatory=$true)]
    [string]$aksname = "aks-fuseblob-mi"

)


# register features
az extension add --name aks-preview
az feature register --name EnableBlobCSIDriver --namespace Microsoft.ContainerService 
az provider register -n Microsoft.ContainerService

# create resource group
az group create -l eastus -n "$resourcegroup"
# create storage account container and upload file
az storage account create -g "$resourcegroup" -n "$storageaccountname" --access-tier Hot  --sku Standard_LRS
az storage container create -n mycontainer --account-name "$storageaccountname" --public-access off
az storage blob upload --account-name "$storageaccountname" --container-name mycontainer --name test.htm --file test.htm --auth-mode key --account-key (az storage account keys list --account-name "$storageaccountname" --query '[0].value' -o tsv)
# create identity and give access to storage account
az identity create -n myaksblobmi -g "$resourcegroup"
$miioid = az identity list -g "$resourcegroup" --query "[?name == 'myaksblobmi'].principalId" -o tsv
$said   = az storage account list -g "$resourcegroup" --query "[?name == '$storageaccountname'].id" -o tsv
az role assignment create --assignee-object-id "$miioid" --role "Storage Blob Data Owner" --scope "$said"

# create aks cluster
az aks create -g "$resourcegroup" -n "$aksname" --enable-managed-identity --enable-blob-driver --node-count 1  --generate-ssh-keys

# add identity to AKS VMSS
$aksnprg = az aks list -g "$resourcegroup" --query "[?name == '$aksname'].nodeResourceGroup" -o tsv
$aksnp   = az vmss list -g "$aksnprg" --query "[?starts_with(name, 'aks-nodepool1-')].name" -o tsv
$miid    = az identity list -g "$resourcegroup" --query "[?name == 'myaksblobmi'].id" -o tsv
az vmss identity assign -g "$aksnprg" -n "$aksnp" --identities "$miid"

# get credentials
az aks get-credentials --admin -g "$resourcegroup" -n "$aksname"

Write-Host ("Managed Identity Object ID is:  " + (az identity list -g "$resourcegroup" --query "[?name == 'myaksblobmi'].principalId" -o tsv))

# create pv & pvc through template
$t = (Get-Content .\volumes-template.yaml)
$t = $t.Replace('replace-this-guid-xxxxxx-xxxx-xxxxxxxxxxx-xxxxxxx-xxxxx', (az identity list -g "$resourcegroup" --query "[?name == 'myaksblobmi'].principalId" -o tsv))
$t = $t.Replace('replace-this-rg-aks-fuseblob-mi', $resourcegroup)
$t = $t.Replace('replace-this-sa-myaksblob', $storageaccountname)
$t = $t.Replace('replace-this-container-mycontainer', 'mycontainer')
$t | Set-Content .\volumes.yaml
kubectl.exe apply -f .\volumes.yaml 
kubectl.exe get pv -A
kubectl.exe get pvc -A
# kubectl.exe describe pv

# create deployment
kubectl.exe apply -f .\deployment.yaml 
kubectl.exe get pods -A
# kubectl.exe describe pod ((kubectl.exe get pods -l app=nginx-app1 -o name) -split "`n")[0].Substring(4)

Write-Host ("Please surf to: http://" + (kubectl.exe get service --field-selector  metadata.name==nginx-app1 -o 'jsonpath={.items[*].status.loadBalancer.ingress[*].ip}').Trim() + "/test.htm ")

# kubectl.exe delete deployment nginx-app1 ; kubectl.exe delete pvc pvc-blob1 ; kubectl.exe delete pv pv-blob1

