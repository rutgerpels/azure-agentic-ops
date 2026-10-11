targetScope = 'subscription'

param environmentName string
param location string = 'swedencentral'
param ownerToken string
param expiresAt string
param adminSshPublicKey string
param agentPrincipalId string
param assignRetainedReader bool = true
param withMonitoring bool = false
@allowed(['Public', 'Private'])
param monitorTransport string = 'Private'

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'guest-service'
  managedBy: 'retailtx'
  ownerToken: ownerToken
  expiresAt: expiresAt
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-retailtx-guest-${environmentName}-${location}'
  location: location
  tags: tags
}

module fixture 'guest-service-target.bicep' = {
  name: 'guest-service-target'
  scope: group
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    adminSshPublicKey: adminSshPublicKey
    agentPrincipalId: agentPrincipalId
    assignRetainedReader: assignRetainedReader
    withMonitoring: withMonitoring
    monitorTransport: monitorTransport
  }
}

output groupId string = group.id
output vmId string = fixture.outputs.vmId
output readerAssignmentId string = fixture.outputs.readerAssignmentId
