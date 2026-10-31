// Assigns built-in roles to one principal at the scope of the resource group this module targets.
targetScope = 'resourceGroup'

param principalId string
param roleIds array
@allowed(['User', 'ServicePrincipal', 'Group'])
param principalType string = 'ServicePrincipal'

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in roleIds: {
  name: guid(resourceGroup().id, principalId, role)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: principalId
    principalType: principalType
  }
}]

output assignmentIds array = [for (role, i) in roleIds: assignments[i].id]
