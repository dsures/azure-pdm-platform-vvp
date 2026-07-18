// Subscription-scope entry point: creates the resource group, then deploys
// the core landing-zone resources into it. Free-tier by design — no VPN
// Gateway or Event Hub resources are deployed here.

targetScope = 'subscription'

@description('Azure region for all resources')
param location string = 'uksouth'

@description('Short project prefix used in resource names')
param projectName string = 'pdmvvp'

@description('Environment tag')
param environment string = 'dev'

var rgName = 'rg-${projectName}-${environment}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: {
    project: 'azure-platform-vvp'
    environment: environment
  }
}

module coreResources 'resources.bicep' = {
  name: 'coreResourcesDeploy'
  scope: rg
  params: {
    location: location
    projectName: projectName
    environment: environment
  }
}

output resourceGroupName string = rg.name
output storageAccountName string = coreResources.outputs.storageAccountName
output keyVaultName string = coreResources.outputs.keyVaultName
output managedIdentityId string = coreResources.outputs.identityId