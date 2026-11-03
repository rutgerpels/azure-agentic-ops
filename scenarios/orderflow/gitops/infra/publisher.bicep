// Presenter-owned issue publisher. Independent network: the demo NSG fault must not block handoff.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param environmentName string
param ownerToken string
param suffix string
param githubRepository string
param githubAppId string
param githubInstallationId string
param githubRepositoryId string
param acrName string
param deployPublisher bool = false
@description('Immutable image reference from the owned registry, required for Deploy.')
param publisherImage string = ''

var tags = {
  scenario: 'orderflow-gitops'
  managedBy: 'invoke-orderflow-gitops'
  ownerToken: ownerToken
  environment: environmentName
  stage: 'shared'
}
var secretReaderRole = '4633458b-17de-408a-b874-0445c86b69e6'
var blobContributorRole = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource publisherIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-ofg-issue-publisher'
  location: location
  tags: tags
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-ofgp-${suffix}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Container Apps resolves these references with its UAMI, not the SRE identity.
    publicNetworkAccess: 'Enabled'
    accessPolicies: []
  }
}

resource secretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, publisherIdentity.id, secretReaderRole)
  properties: {
    principalId: publisherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretReaderRole)
  }
}

resource receipts 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stofgp${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: receipts
  name: 'default'
}

resource incidents 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'incidents'
  properties: { publicAccess: 'None' }
}

resource receiptWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: incidents
  name: guid(incidents.id, publisherIdentity.id, blobContributorRole)
  properties: {
    principalId: publisherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRole)
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
}

resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, publisherIdentity.id, acrPullRole)
  properties: {
    principalId: publisherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-ofg-publisher'
  location: location
  tags: tags
  properties: {
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
  }
}

resource publisher 'Microsoft.App/containerApps@2025-01-01' = if (deployPublisher) {
  name: 'orderflow-issue-publisher'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${publisherIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        allowInsecure: false
        targetPort: 8080
        transport: 'http'
      }
      registries: [{ server: registry.properties.loginServer, identity: publisherIdentity.id }]
      secrets: [
        {
          name: 'github-app-private-key'
          keyVaultUrl: '${vault.properties.vaultUri}secrets/github-app-private-key'
          identity: publisherIdentity.id
        }
        {
          name: 'publisher-key'
          keyVaultUrl: '${vault.properties.vaultUri}secrets/publisher-key'
          identity: publisherIdentity.id
        }
      ]
    }
    template: {
      containers: [{
        name: 'publisher'
        image: publisherImage
        resources: { cpu: json('0.25'), memory: '0.5Gi' }
        env: [
          { name: 'GITHUB_APP_ID', value: githubAppId }
          { name: 'GITHUB_INSTALLATION_ID', value: githubInstallationId }
          { name: 'GITHUB_REPOSITORY_ID', value: githubRepositoryId }
          { name: 'GITHUB_REPOSITORY', value: githubRepository }
          { name: 'GITHUB_APP_PRIVATE_KEY', secretRef: 'github-app-private-key' }
          { name: 'ORDERFLOW_PUBLISHER_KEY', secretRef: 'publisher-key' }
          { name: 'ORDERFLOW_GENERATION', value: ownerToken }
          { name: 'AZURE_CLIENT_ID', value: publisherIdentity.properties.clientId }
          { name: 'ORDERFLOW_RECEIPT_ACCOUNT_URL', value: receipts.properties.primaryEndpoints.blob }
          { name: 'ORDERFLOW_RECEIPT_CONTAINER', value: incidents.name }
        ]
        probes: [
          {
            type: 'Readiness'
            httpGet: { path: '/healthz', port: 8080, scheme: 'HTTP' }
            initialDelaySeconds: 5
            periodSeconds: 10
          }
        ]
      }]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [secretReader, receiptWriter, pull]
}

output vaultName string = vault.name
output vaultId string = vault.id
output storageAccountName string = receipts.name
output publisherIdentityId string = publisherIdentity.id
output publisherClientId string = publisherIdentity.properties.clientId
output publisherUrl string = deployPublisher ? 'https://${publisher!.properties.configuration.ingress.fqdn}/mcp' : ''
