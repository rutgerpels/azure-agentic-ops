targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param environmentName string
param ownerToken string
param location string = resourceGroup().location
@description('Presenter IPv4 CIDR; never 0.0.0.0/0. Also used for SCM access.')
param presenterCidr string
@description('Public SSH key only. The VM has no inbound public IP or SSH rule.')
param sshPublicKey string
param adminObjectId string
param vmAdminUsername string = 'demoadmin'
@allowed(['User', 'ServicePrincipal'])
param adminPrincipalType string = 'User'

var suffix = uniqueString(resourceGroup().id, ownerToken)
var stem = 'of-${environmentName}-${suffix}'
var tags = {
  scenario: 'orderflow'
  managedBy: 'invoke-orderflow'
  ownerToken: ownerToken
  environment: environmentName
}
var apiAddress = '10.42.2.4'
var ruleName = 'PortalToOrderApi'
var baseline = loadJsonContent('network-baseline.json')
var cloudInit = replace(replace(replace(replace(replace(loadTextContent('cloud-init.yml'),
  '__BACKEND__', base64(loadTextContent('../app/backend.py'))),
  '__REQUIREMENTS__', base64(loadTextContent('../app/requirements.txt'))),
  '__COSMOS_ENDPOINT__', cosmos.properties.documentEndpoint),
  '__CLIENT_ID__', backendIdentity.properties.clientId),
  '__COMMON__', base64(loadTextContent('../app/common.py')))

resource outboundIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${stem}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-${stem}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: outboundIp.id }]
  }
}
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${stem}'
  location: location
  tags: tags
  properties: {}
}
resource apiRule 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  parent: nsg
  name: ruleName
  properties: baseline
}
resource denyOther 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  parent: nsg
  name: 'DenyOtherInbound'
  properties: {
    priority: 4096
    direction: 'Inbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${stem}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.42.0.0/16'] }
    subnets: [
      {
        name: 'portal'
        properties: {
          addressPrefix: '10.42.1.0/24'
          delegations: [{
            name: 'appservice'
            properties: { serviceName: 'Microsoft.Web/serverFarms' }
          }]
        }
      }
      {
        name: 'api'
        properties: {
          addressPrefix: '10.42.2.0/24'
          networkSecurityGroup: { id: nsg.id }
          natGateway: { id: nat.id }
          defaultOutboundAccess: false
          serviceEndpoints: [{ service: 'Microsoft.AzureCosmosDB' }]
        }
      }
    ]
  }
}
resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-api-${stem}'
  location: location
  tags: tags
}
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: 'cosmos-${suffix}'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    isVirtualNetworkFilterEnabled: true
    virtualNetworkRules: [{ id: '${vnet.id}/subnets/api' }]
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0 }]
    capabilities: [{ name: 'EnableServerless' }]
    minimalTlsVersion: 'Tls12'
  }
}
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: 'orderflow'
  properties: { resource: { id: 'orderflow' } }
}
resource products 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: 'products'
  properties: { resource: { id: 'products', partitionKey: { paths: ['/category'], kind: 'Hash' } } }
}
resource orders 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: 'orders'
  properties: { resource: { id: 'orders', partitionKey: { paths: ['/id'], kind: 'Hash' }, defaultTtl: 86400 } }
}
resource cosmosGrant 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, backendIdentity.id, 'data')
  properties: {
    principalId: backendIdentity.properties.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: '${cosmos.id}/dbs/orderflow'
  }
}
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${stem}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [{
      name: 'private'
      properties: {
        privateIPAllocationMethod: 'Static'
        privateIPAddress: apiAddress
        subnet: { id: '${vnet.id}/subnets/api' }
      }
    }]
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-${stem}'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${backendIdentity.id}': {} } }
  properties: {
    hardwareProfile: { vmSize: 'Standard_B2s' }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: 'order-api'
      adminUsername: vmAdminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${vmAdminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
  dependsOn: [cosmosGrant, products, orders, apiRule, denyOther]
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${stem}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}
resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${stem}'
  location: location
  tags: tags
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: workspace.id }
}
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${stem}'
  location: location
  tags: tags
  kind: 'linux'
  sku: { name: 'B1', tier: 'Basic' }
  properties: { reserved: true }
}
resource portal 'Microsoft.Web/sites@2023-12-01' = {
  name: 'portal-${stem}'
  location: location
  tags: tags
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: '${vnet.id}/subnets/portal'
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appCommandLine: 'gunicorn --bind 0.0.0.0:8000 --workers 1 --worker-class uvicorn.workers.UvicornWorker portal:app'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsUseMain: true
      ipSecurityRestrictions: [{
        name: 'Presenter'
        ipAddress: presenterCidr
        action: 'Allow'
        priority: 100
      }]
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ORDER_API_URL', value: 'http://${apiAddress}:8080' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
      ]
    }
  }
}
resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: portal
  name: 'ftp'
  properties: { allow: false }
}
resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: portal
  name: 'scm'
  properties: { allow: false }
}
resource alert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'orderflow-dependency-unavailable-${suffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'OrderFlow ordering dependency unavailable'
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
}

module sre 'sre.bicep' = {
  name: 'sre'
  params: {
    location: location
    stem: stem
    tags: tags
    nsgName: nsg.name
    ruleName: ruleName
    adminObjectId: adminObjectId
    adminPrincipalType: adminPrincipalType
  }
  dependsOn: [apiRule]
}
output webAppName string = portal.name
output webAppUrl string = 'https://${portal.properties.defaultHostName}'
output webAppId string = portal.id
output vmId string = vm.id
output nsgId string = nsg.id
output ruleId string = apiRule.id
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output alertId string = alert.id
output alertName string = alert.name
output agentId string = sre.outputs.agentId
output sreIdentityId string = sre.outputs.identityId
output srePrincipalId string = sre.outputs.principalId
output repairRoleId string = sre.outputs.repairRoleId
output repairAssignmentId string = sre.outputs.repairAssignmentId
