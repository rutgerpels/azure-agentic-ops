// Temporary learning copy of the checkout latency estate. No SRE Agent, no Observability
// Agent, no Arc, no subscription-level settings. Configure the SRE Agent by hand in the portal.
targetScope = 'subscription'

@minLength(3)
@maxLength(12)
param environmentName string
param location string = 'swedencentral'
param alertEmail string
param adminPublicKey string
param expiresAt string
param ownerToken string

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'checkout-learn'
  managedBy: 'invoke-checkoutlearn'
  expiresAt: expiresAt
  ownerToken: ownerToken
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-retailtx-checkout-${environmentName}-${location}'
  location: location
  tags: tags
}

module estate 'estate.bicep' = {
  scope: group
  name: 'checkout-learn-estate'
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    alertEmail: alertEmail
    adminPublicKey: adminPublicKey
    ownerToken: ownerToken
  }
}

output webAppName string = estate.outputs.webAppName
output webAppUrl string = estate.outputs.webAppUrl
output appInsightsName string = estate.outputs.appInsightsName
output workspaceId string = estate.outputs.workspaceId
output workspaceCustomerId string = estate.outputs.workspaceCustomerId
output alertRuleId string = estate.outputs.alertRuleId
output alertRuleName string = estate.outputs.alertRuleName
output vmName string = estate.outputs.vmName
