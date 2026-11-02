// Read-only SRE Agent for the production stage. Deployed as a module of shared.bicep in the shared RG.
// It investigates and files GitHub issues; it has no Azure write role.
targetScope = 'resourceGroup'

param location string
param suffix string
param tags object
param prodResourceGroup string
param adminObjectId string
@allowed(['User', 'ServicePrincipal'])
param adminPrincipalType string = 'User'

var reader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var prodReadRoles = [
  reader
  '43d0d8ad-25c7-4714-9337-8ba259a9fe05' // Monitoring Reader
  '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Reader
]

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-ofg-sre'
  location: location
  tags: tags
}

module prodReaders 'modules/rg-roles.bicep' = {
  name: 'ofg-sre-prod-readers'
  scope: resourceGroup(prodResourceGroup)
  params: {
    principalId: identity.properties.principalId
    roleIds: prodReadRoles
  }
}

resource sharedReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, reader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', reader)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agent 'Microsoft.App/agents@2026-01-01' = {
  name: 'sre-ofg-${suffix}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    actionConfiguration: { identity: identity.id, accessLevel: 'Low', mode: 'Review' }
    knowledgeGraphConfiguration: {
      identity: identity.id
      managedResources: ['${subscription().id}/resourceGroups/${prodResourceGroup}']
    }
    #disable-next-line BCP037
    incidentManagementConfiguration: { type: 'AzMonitor', connectionName: 'azmonitor' }
    upgradeChannel: 'Stable'
  }
  dependsOn: [prodReaders, sharedReader]
}

module systemProdReaders 'modules/rg-roles.bicep' = {
  name: 'ofg-sre-system-prod-readers'
  scope: resourceGroup(prodResourceGroup)
  params: {
    principalId: agent.identity.principalId
    roleIds: prodReadRoles
  }
}

resource admin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: agent
  name: guid(agent.id, adminObjectId, 'admin')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')
    principalId: adminObjectId
    principalType: adminPrincipalType
  }
}

output agentId string = agent.id
output agentName string = agent.name
output identityId string = identity.id
output principalId string = identity.properties.principalId
