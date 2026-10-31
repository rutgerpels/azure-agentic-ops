param location string
param stem string
param tags object
param nsgName string
param ruleName string
param adminObjectId string
param adminPrincipalType string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-sre-${stem}'
  location: location
  tags: tags
}
resource rule 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' existing = {
  name: '${nsgName}/${ruleName}'
}
resource repairRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, 'orderflow-rule-repair')
  properties: {
    roleName: 'OrderFlow rule repair ${stem}'
    description: 'Can update one pre-existing demo rule; assignment is scoped to that rule.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: [
        'Microsoft.Network/networkSecurityGroups/securityRules/read'
        'Microsoft.Network/networkSecurityGroups/securityRules/write'
      ]
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}
resource repairGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: rule
  name: guid(rule.id, identity.id, repairRole.id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', repairRole.name)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
var readRoles = [
  'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  '73c42c96-874c-492b-b04d-ab87d138a893'
]
resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in readRoles: {
  name: guid(resourceGroup().id, identity.id, role)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]
resource agent 'Microsoft.App/agents@2026-01-01' = {
  name: 'sre-${stem}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    actionConfiguration: { identity: identity.id, accessLevel: 'Low', mode: 'Review' }
    knowledgeGraphConfiguration: { identity: identity.id, managedResources: [resourceGroup().id] }
    #disable-next-line BCP037
    incidentManagementConfiguration: { type: 'AzMonitor', connectionName: 'azmonitor' }
    upgradeChannel: 'Stable'
  }
  dependsOn: [readers, repairGrant]
}
resource systemReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in readRoles: {
  name: guid(resourceGroup().id, agent.id, role)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: agent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]
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
output identityId string = identity.id
output principalId string = identity.properties.principalId
output repairRoleId string = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', repairRole.name)
output repairAssignmentId string = repairGrant.id
