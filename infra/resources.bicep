// Resource-group-scope module: the landing-zone-lite core.
// Free tier throughout — Standard_LRS storage, standard Key Vault,
// no premium SKUs, no VPN Gateway (GatewaySubnet is reserved but empty).

param location string
param projectName string
param environment string

var uniqueSuffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('st${projectName}${uniqueSuffix}')
var keyVaultName = toLower('kv-${projectName}-${uniqueSuffix}')
var identityName = 'id-${projectName}-${environment}'
var vnetName = 'vnet-${projectName}-${environment}'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.20.1.0/24'
        }
      }
      {
        // Reserved for a future VPN Gateway — the "designed, not deployed"
        // hybrid-networking piece. Left empty on purpose.
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.20.255.0/27'
        }
      }
    ]
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true // ADLS Gen2 (hierarchical namespace)
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storage
  name: 'default'
}

resource bronzeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'bronze'
}

resource silverContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'silver'
}

resource goldContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'gold'
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
  }
}

// Storage Blob Data Contributor
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, 'StorageBlobDataContributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, identity.id, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountName string = storage.name
output keyVaultName string = keyVault.name
output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId

var adfName = 'adf-${projectName}-${environment}-${uniqueSuffix}'

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: adfName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
}

resource adfStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, dataFactory.id, 'StorageBlobDataContributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: dataFactory.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output dataFactoryName string = dataFactory.name