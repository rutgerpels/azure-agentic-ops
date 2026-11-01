// Private data path for one OrderFlow GitOps stage: Cosmos DB private endpoint and DNS.
// Deployed only by the presenter lifecycle (Up) after env.bicep, because approving a private
// endpoint on the shared Cosmos DB account needs rights the GitHub deploy identities do not hold.
// CI/CD redeploys env.bicep in incremental mode, which keeps these resources and the data subnet.
targetScope = 'resourceGroup'

@allowed(['prod', 'test'])
param stage string
@minLength(1)
param sharedResourceGroup string
@minLength(13)
@maxLength(13)
param suffix string
@minLength(1)
param ownerToken string
@minLength(3)
@maxLength(12)
param environmentName string
param location string = resourceGroup().location

var tags = {
  scenario: 'orderflow-gitops'
  managedBy: 'invoke-orderflow-gitops'
  ownerToken: ownerToken
  environment: environmentName
  stage: stage
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: 'cosmos-ofg-${suffix}'
  scope: resourceGroup(sharedResourceGroup)
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: 'vnet-ofg-${stage}'
}
resource dataSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'data'
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
  tags: tags
}
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'vnet-ofg-${stage}'
  location: 'global'
  tags: tags
  properties: { registrationEnabled: false, virtualNetwork: { id: vnet.id } }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-ofg-cosmos-${stage}'
  location: location
  tags: tags
  properties: {
    subnet: { id: dataSubnet.id }
    privateLinkServiceConnections: [{
      name: 'cosmos'
      properties: { privateLinkServiceId: cosmos.id, groupIds: ['Sql'] }
    }]
  }
}
resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'cosmos'
  properties: { privateDnsZoneConfigs: [{ name: 'documents', properties: { privateDnsZoneId: zone.id } }] }
  dependsOn: [link]
}

output privateEndpointName string = endpoint.name
