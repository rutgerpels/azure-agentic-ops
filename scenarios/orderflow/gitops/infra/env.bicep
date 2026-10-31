// One OrderFlow GitOps stage (prod or test). Same template for both; deployed by GitHub Actions.
targetScope = 'resourceGroup'

@allowed(['prod', 'test'])
param stage string
@description('Stage VNet range; prod 10.60.0.0/24, test 10.61.0.0/24.')
param addressPrefix string
param alertsEnabled bool
@minLength(1)
param sharedResourceGroup string
@minLength(13)
@maxLength(13)
param suffix string
@minLength(9)
@description('Presenter IPv4 CIDR allowed to reach the portal; broad ranges are rejected.')
param presenterCidr string
@minLength(20)
@maxLength(20)
param imageTag string
@minLength(7)
param deploySha string
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
// The reviewed surface: rules removed from this file are removed from the NSG on deploy.
var networkRules = loadJsonContent('../deploy/network-rules.json').rules
var image = '${registry.properties.loginServer}/orderflow:${imageTag}'
var apiUrl = 'http://orderflow-api'
// Broad presenter ranges become an invalid value so the deployment fails instead of opening the portal.
var cidrParts = split(presenterCidr, '/')
var presenterRange = length(cidrParts) == 1 || int(cidrParts[1]) >= 16 ? presenterCidr : 'rejected-broad-presenter-cidr'
var registries = [{ server: registry.properties.loginServer, identity: appIdentity.id }]
var identity = { type: 'UserAssigned', userAssignedIdentities: { '${appIdentity.id}': {} } }
var resources = { cpu: json('0.25'), memory: '0.5Gi' }
var commonEnv = [
  { name: 'DEPLOY_SHA', value: deploySha }
  { name: 'ORDERFLOW_STAGE', value: stage }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
]
var appEnv = concat(commonEnv, [
  { name: 'AZURE_CLIENT_ID', value: appIdentity.properties.clientId }
  { name: 'COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
  { name: 'COSMOS_DATABASE', value: 'orderflow-${stage}' }
  { name: 'ORDER_API_URL', value: apiUrl }
])

// Process-only TCP probes: a revision whose dependencies are unreachable must still go live.
func tcpProbes(port int) array => [
  { type: 'Startup', tcpSocket: { port: port }, initialDelaySeconds: 1, periodSeconds: 5, failureThreshold: 24 }
  { type: 'Liveness', tcpSocket: { port: port }, periodSeconds: 10, failureThreshold: 3 }
  { type: 'Readiness', tcpSocket: { port: port }, periodSeconds: 10, failureThreshold: 3 }
]

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: 'crofg${suffix}'
  scope: resourceGroup(sharedResourceGroup)
}
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: 'cosmos-ofg-${suffix}'
  scope: resourceGroup(sharedResourceGroup)
}
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'id-ofg-app-${stage}'
  scope: resourceGroup(sharedResourceGroup)
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-ofg-${stage}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}
resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-ofg-${stage}'
  location: location
  tags: tags
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: workspace.id }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-ofg-${stage}'
  location: location
  tags: tags
  properties: {
    securityRules: [for rule in networkRules: { name: rule.name, properties: rule.properties }]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-ofg-${stage}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [{
      name: 'apps'
      properties: {
        addressPrefix: cidrSubnet(addressPrefix, 27, 0)
        networkSecurityGroup: { id: nsg.id }
        delegations: [{ name: 'containerapps', properties: { serviceName: 'Microsoft.App/environments' } }]
      }
    }]
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: 'cae-ofg-${stage}'
  location: location
  tags: tags
  properties: {
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    vnetConfiguration: { infrastructureSubnetId: vnet.properties.subnets[0].id, internal: false }
    // External workload-profile ingress uses the managed public IP, not the subnet NSG, so no inbound rule is needed.
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

resource api 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'orderflow-api'
  location: location
  tags: tags
  identity: identity
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      // Environment-internal only; plain HTTP so the portal reaches exactly http://orderflow-api.
      ingress: { external: false, targetPort: 8080, transport: 'http', allowInsecure: true }
      registries: registries
    }
    template: {
      containers: [{
        name: 'api'
        image: image
        command: ['uvicorn']
        args: ['backend:app', '--host', '0.0.0.0', '--port', '8080']
        env: appEnv
        resources: resources
        probes: tcpProbes(8080)
      }]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource portal 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'orderflow-portal'
  location: location
  tags: tags
  identity: identity
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'http'
        allowInsecure: false
        ipSecurityRestrictions: [{
          name: 'Presenter'
          description: 'Presenter workstation only'
          ipAddressRange: presenterRange
          action: 'Allow'
        }]
      }
      registries: registries
    }
    template: {
      containers: [{
        name: 'portal'
        image: image
        command: ['gunicorn']
        args: ['portal:app', '-k', 'uvicorn.workers.UvicornWorker', '-w', '1', '-b', '0.0.0.0:8000']
        env: appEnv
        resources: resources
        probes: tcpProbes(8000)
      }]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [api]
}

resource smoke 'Microsoft.App/jobs@2025-07-01' = {
  name: 'orderflow-smoke'
  location: location
  tags: tags
  identity: identity
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 120
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: registries
    }
    template: {
      containers: [{
        name: 'smoke'
        image: image
        command: ['python', 'smoke.py']
        env: concat(commonEnv, [{ name: 'SMOKE_API_URL', value: apiUrl }])
        resources: resources
      }]
    }
  }
  dependsOn: [api]
}

// Same signal as option 1: repeated failed real dependency calls from the portal or API.
resource alert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (alertsEnabled) {
  name: 'alert-ofg-${stage}-dependency'
  location: location
  tags: tags
  properties: {
    displayName: 'OrderFlow ${stage} ordering dependency unavailable'
    description: 'Repeated real dependency probes failed. Investigate customer impact and recent changes.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [workspace.id]
    autoMitigate: true
    criteria: {
      allOf: [{
        query: 'AppTraces | where TimeGenerated > ago(5m) | where Message == "orderflow_dependency" | where tostring(Properties["success"]) == "false"'
        timeAggregation: 'Count'
        operator: 'GreaterThanOrEqual'
        threshold: 3
        failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
      }]
    }
  }
  dependsOn: [insights]
}

output portalFqdn string = portal.properties.configuration.ingress.fqdn
output portalUrl string = 'https://${portal.properties.configuration.ingress.fqdn}'
output smokeJobName string = smoke.name
output nsgName string = nsg.name
output appInsightsName string = insights.name
output alertId string = alertsEnabled ? alert.id : ''

