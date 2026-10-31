// Shared OrderFlow GitOps resources: registry, Cosmos DB, identities, OIDC federation, SRE Agent.
targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param environmentName string
@minLength(1)
param ownerToken string
param location string = resourceGroup().location
@description('GitHub repository as owner/repo; used for the default federated subjects.')
param githubRepository string
param prodResourceGroup string
param testResourceGroup string
param adminObjectId string
@allowed(['User', 'ServicePrincipal'])
param adminPrincipalType string = 'User'
param prodFederatedSubject string = 'repo:${githubRepository}:environment:orderflow-prod'
param testFederatedSubject string = 'repo:${githubRepository}:environment:orderflow-test'
param includeSre bool = true
param sreLocation string = location

var suffix = uniqueString(subscription().id, ownerToken)
var tags = {
  scenario: 'orderflow-gitops'
  managedBy: 'invoke-orderflow-gitops'
  ownerToken: ownerToken
  environment: environmentName
  stage: 'shared'
}
var stages = ['prod', 'test']
var envGroups = { prod: prodResourceGroup, test: testResourceGroup }
var subjects = { prod: prodFederatedSubject, test: testFederatedSubject }
var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43d6c4ea6b5f'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  managedIdentityOperator: 'f1a07417-d97a-45cb-824c-7a7467783830'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: 'crofg${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: 'cosmos-ofg-${suffix}'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    disableKeyBasedMetadataWriteAccess: true
    // Public endpoint with Entra-only data access: reached through outbound internet from the apps subnet.
    publicNetworkAccess: 'Enabled'
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0 }]
    capabilities: [{ name: 'EnableServerless' }]
    minimalTlsVersion: 'Tls12'
  }
}

resource databases 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = [for stage in stages: {
  parent: cosmos
  name: 'orderflow-${stage}'
  properties: { resource: { id: 'orderflow-${stage}' } }
}]

resource products 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = [for (stage, i) in stages: {
  parent: databases[i]
  name: 'products'
  properties: { resource: { id: 'products', partitionKey: { paths: ['/category'], kind: 'Hash' } } }
}]

resource orders 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = [for (stage, i) in stages: {
  parent: databases[i]
  name: 'orders'
  properties: {
    resource: { id: 'orders', partitionKey: { paths: ['/id'], kind: 'Hash' }, defaultTtl: 86400 }
  }
}]

resource appIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for stage in stages: {
  name: 'id-ofg-app-${stage}'
  location: location
  tags: union(tags, { stage: stage })
}]

resource deployIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for stage in stages: {
  name: 'id-ofg-deploy-${stage}'
  location: location
  tags: union(tags, { stage: stage })
}]

@batchSize(1)
resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for (stage, i) in stages: {
  parent: deployIdentities[i]
  name: 'github-orderflow-${stage}'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    audiences: ['api://AzureADTokenExchange']
    subject: subjects[stage]
  }
}]

// Data-plane access is limited to the stage's own database.
@batchSize(1)
resource cosmosGrants 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = [for (stage, i) in stages: {
  parent: cosmos
  name: guid(cosmos.id, appIdentities[i].id, 'data')
  properties: {
    principalId: appIdentities[i].properties.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: '${cosmos.id}/dbs/orderflow-${stage}'
  }
  dependsOn: [databases]
}]

resource pullGrants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (stage, i) in stages: {
  scope: registry
  name: guid(registry.id, appIdentities[i].id, roles.acrPull)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: appIdentities[i].properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

// Only the production deployer may push images; the test deployer can read (pull) only.
resource pushGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, deployIdentities[0].id, roles.acrPush)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPush)
    principalId: deployIdentities[0].properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// The test deployer only verifies that the CD-built image tag exists.
resource testDeployPullGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, deployIdentities[1].id, roles.acrPull)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: deployIdentities[1].properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource sharedReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (stage, i) in stages: {
  name: guid(resourceGroup().id, deployIdentities[i].id, roles.reader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.reader)
    principalId: deployIdentities[i].properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource identityOperators 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (stage, i) in stages: {
  scope: appIdentities[i]
  name: guid(appIdentities[i].id, deployIdentities[i].id, roles.managedIdentityOperator)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.managedIdentityOperator)
    principalId: deployIdentities[i].properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

module envContributors 'modules/rg-roles.bicep' = [for (stage, i) in stages: {
  name: 'ofg-deploy-roles-${stage}'
  scope: resourceGroup(envGroups[stage])
  params: {
    principalId: deployIdentities[i].properties.principalId
    roleIds: [roles.contributor]
  }
}]

module sre 'sre.bicep' = if (includeSre) {
  name: 'ofg-sre'
  params: {
    location: sreLocation
    suffix: suffix
    tags: tags
    prodResourceGroup: prodResourceGroup
    adminObjectId: adminObjectId
    adminPrincipalType: adminPrincipalType
  }
}

output suffix string = suffix
output acrName string = registry.name
output acrLoginServer string = registry.properties.loginServer
output cosmosAccountName string = cosmos.name
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output appIdentityIdProd string = appIdentities[0].id
output appIdentityIdTest string = appIdentities[1].id
output appClientIdProd string = appIdentities[0].properties.clientId
output appClientIdTest string = appIdentities[1].properties.clientId
output deployClientIdProd string = deployIdentities[0].properties.clientId
output deployClientIdTest string = deployIdentities[1].properties.clientId
output deployPrincipalIdProd string = deployIdentities[0].properties.principalId
output deployPrincipalIdTest string = deployIdentities[1].properties.principalId
output tenantId string = tenant().tenantId
output sreAgentId string = includeSre ? sre!.outputs.agentId : ''
output sreAgentName string = includeSre ? sre!.outputs.agentName : ''
output sreIdentityId string = includeSre ? sre!.outputs.identityId : ''
output srePrincipalId string = includeSre ? sre!.outputs.principalId : ''




