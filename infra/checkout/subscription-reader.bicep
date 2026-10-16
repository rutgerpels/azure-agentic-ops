// Observability Agent prerequisite: read alerts and resources at subscription scope.
targetScope = 'subscription'

param principalId string

var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

resource grant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output assignmentId string = grant.id
