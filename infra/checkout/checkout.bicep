targetScope = 'resourceGroup'

param environmentName string
param location string
param observabilityLocation string
param tags object
param alertEmail string
param adminObjectId string
param adminPrincipalType string
param adminPublicKey string
param vmSize string = 'Standard_B2s'
param posIntervalSeconds int = 3
param vmAdminUsername string = 'retailtxadmin'

var suffix = take(uniqueString(resourceGroup().id), 6)
var stem = 'retailtx-checkout-${environmentName}'
var backendIp = '10.61.0.10'
var alertName = 'alert-checkout-latency-${environmentName}'
var readerRole = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRole = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logAnalyticsReaderRole = '73c42c96-874c-492b-b04d-ab87d138a893'
var monitoringContributorRole = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var websiteContributorRole = 'de139f84-1756-47ae-9be6-808fbbe84772'
var sreAdministratorRole = 'e79298df-d852-4c6d-84f9-5d13249d1e55'
var cloudTags = union(tags, { system: 'CAP', site: 'cloud' })
var dcTags = union(tags, { system: 'ERP', site: 'dc1' })

// ---------- Telemetry ----------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${stem}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${stem}'
  location: location
  tags: cloudTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${stem}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take('rtx${environmentName}', 12)
    enabled: true
    emailReceivers: [
      { name: 'presenter', emailAddress: alertEmail, useCommonAlertSchema: true }
    ]
  }
}

// ---------- Networks: Azure "cloud" and simulated datacenter "dc1" ----------
resource cloudVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${stem}-cloud'
  location: location
  tags: cloudTags
  properties: {
    addressSpace: { addressPrefixes: ['10.60.0.0/24'] }
    subnets: [
      {
        name: 'app'
        properties: {
          addressPrefix: '10.60.0.0/26'
          delegations: [{ name: 'web', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
        }
      }
    ]
  }
}

resource egressIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${stem}-dc1-egress'
  location: location
  tags: dcTags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-${stem}-dc1'
  location: location
  tags: dcTags
  sku: { name: 'Standard' }
  properties: { publicIpAddresses: [{ id: egressIp.id }] }
}

resource backendNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${stem}-dc1'
  location: location
  tags: dcTags
  properties: {
    securityRules: [
      {
        name: 'allow-cloud-price-lookups'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.60.0.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: backendIp
          destinationPortRanges: ['8080', '8081']
        }
      }
      {
        name: 'deny-other-vnet-inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource dcVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${stem}-dc1'
  location: location
  tags: dcTags
  properties: {
    addressSpace: { addressPrefixes: ['10.61.0.0/24'] }
    subnets: [
      {
        name: 'backend'
        properties: {
          addressPrefix: '10.61.0.0/26'
          natGateway: { id: nat.id }
          networkSecurityGroup: { id: backendNsg.id }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

resource cloudToDc 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: cloudVnet
  name: 'cloud-to-dc1'
  properties: {
    remoteVirtualNetwork: { id: dcVnet.id }
    allowVirtualNetworkAccess: true
  }
}

resource dcToCloudPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: dcVnet
  name: 'dc1-to-cloud'
  properties: {
    remoteVirtualNetwork: { id: cloudVnet.id }
    allowVirtualNetworkAccess: true
  }
}

// ---------- Cloud front end: App Service ----------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${stem}'
  location: location
  tags: cloudTags
  kind: 'linux'
  sku: { name: 'B1' }
  properties: { reserved: true }
}

resource web 'Microsoft.Web/sites@2024-04-01' = {
  name: 'app-rtx-checkout-${environmentName}-${suffix}'
  location: location
  tags: union(cloudTags, { component: 'checkout-web' })
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: '${cloudVnet.id}/subnets/app'
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'gunicorn --workers 2 --threads 1 --worker-class uvicorn.workers.UvicornWorker --timeout 60 --bind 0.0.0.0:8000 app:app'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: false
      healthCheckPath: '/health'
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'OTEL_SERVICE_NAME', value: 'checkout-web' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'PRICE_PRIMARY_URL', value: 'http://${backendIp}:8080' }
        { name: 'PRICE_LEGACY_URL', value: 'http://${backendIp}:8081' }
        { name: 'PRICE_ROUTE_BE', value: 'primary' }
        { name: 'PRICE_ROUTE_NL', value: 'primary' }
        { name: 'ROUTE_CHANGE_REF', value: 'baseline' }
      ]
    }
  }
  dependsOn: [cloudToDc, dcToCloudPeering]
}

// ---------- Simulated datacenter host ----------
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${stem}-dc1'
  location: location
  tags: dcTags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: backendIp
          subnet: { id: '${dcVnet.id}/subnets/backend' }
        }
      }
    ]
  }
}

var posConfig = string({ checkoutUrl: 'https://${web.properties.defaultHostName}', intervalSeconds: posIntervalSeconds })
var cloudInit = replace(replace(replace(loadTextContent('dc1-cloud-init.yaml'),
  '__PRICE_BACKEND__', loadFileAsBase64('../../app/checkout/onprem/price_backend.py')),
  '__POS_SIM__', loadFileAsBase64('../../app/checkout/onprem/pos_sim.py')),
  '__POS_CONFIG__', base64(posConfig))

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: 'vm-rtx-erp-${environmentName}'
  location: location
  tags: union(dcTags, { component: 'erp-price' })
  properties: {
    hardwareProfile: { vmSize: vmSize }
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
      computerName: 'erp-${environmentName}'
      adminUsername: vmAdminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [{ path: '/home/${vmAdminUsername}/.ssh/authorized_keys', keyData: adminPublicKey }]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

// ---------- Alert: Belgian checkout p95 latency ----------
resource latencyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: alertName
  location: location
  tags: tags
  properties: {
    displayName: alertName
    description: 'Checkout p95 latency above 1 s for a country (n >= 5, 5 minutes).'
    severity: 2
    enabled: true
    scopes: [workspace.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: 'AppRequests | where Name == "POST /checkout" | extend country = tostring(Properties["retail.country"]) | where isnotempty(country) | summarize p95 = percentile(DurationMs, 95), n = count() by country | where n >= 5 and p95 > 1000'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [{ name: 'country', operator: 'Include', values: ['*'] }]
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup.id] }
  }
}

// ---------- Observability Agent (built autonomous; presenter can also start on demand) ----------
resource obaIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${stem}-observability'
  location: location
  tags: tags
}

#disable-next-line BCP081
resource monitorWorkspace 'Microsoft.Monitor/accounts@2026-04-03-preview' = {
  name: 'amw-${stem}'
  location: observabilityLocation
  tags: tags
  properties: {
    publicNetworkAccess: 'Enabled'
    actions: { defaultActionGroups: [{ id: actionGroup.id }] }
  }
}

resource obaWorkspaceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: monitorWorkspace
  name: guid(monitorWorkspace.id, obaIdentity.id, monitoringContributorRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRole)
    principalId: obaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource obaTelemetryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, obaIdentity.id, monitoringReaderRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRole)
    principalId: obaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource obaLogRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, obaIdentity.id, logAnalyticsReaderRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRole)
    principalId: obaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

#disable-next-line BCP081
resource observabilityAgent 'Microsoft.Monitor/observabilityAgents@2026-05-01-preview' = {
  name: 'oba-${stem}'
  location: observabilityLocation
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${obaIdentity.id}': {} } }
  properties: {
    monitoringAccountId: monitorWorkspace.id
    enabled: true
    operations: [
      {
        type: 'IssueCreation'
        mode: 'Auto'
        instructions: 'Create one issue when ${alertName} fires for this resource group. Investigate checkout latency by country, the price-lookup dependencies (erp-price-service, legacy-price-gateway) and recent configuration changes. Do not change workloads or perform mitigations.'
      }
      { type: 'Investigation', mode: 'Auto' }
    ]
  }
  dependsOn: [obaWorkspaceRole, obaTelemetryRole, obaLogRole]
}

#disable-next-line BCP081
resource observedApp 'Microsoft.Monitor/observabilityAgents/monitoredResources@2026-05-01-preview' = {
  parent: observabilityAgent
  name: 'appi-${stem}'
  properties: { resourceId: appInsights.id, enabled: true, isAutonomous: true }
}

// The latency alert is scoped to the workspace (one-minute log alerts need workspace tables).
#disable-next-line BCP081
resource observedWorkspace 'Microsoft.Monitor/observabilityAgents/monitoredResources@2026-05-01-preview' = {
  parent: observabilityAgent
  name: 'log-${stem}'
  properties: { resourceId: workspace.id, enabled: true, isAutonomous: true }
}

// ---------- SRE Agent (Review mode; human approves the rollback) ----------
resource sreIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${stem}-sre'
  location: location
  tags: tags
}

resource sreGroupRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in [readerRole, monitoringReaderRole, logAnalyticsReaderRole]: {
  name: guid(resourceGroup().id, sreIdentity.id, role)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

// The only write permission: app settings on the checkout web app.
resource sreWebRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: web
  name: guid(web.id, sreIdentity.id, websiteContributorRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRole)
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource sre 'Microsoft.App/agents@2026-01-01' = {
  name: 'sre-${stem}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${sreIdentity.id}': {} }
  }
  properties: {
    actionConfiguration: {
      identity: sreIdentity.id
      accessLevel: 'Low'
      mode: 'Review'
    }
    knowledgeGraphConfiguration: {
      identity: sreIdentity.id
      managedResources: [resourceGroup().id]
    }
    #disable-next-line BCP037
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    upgradeChannel: 'Stable'
  }
  dependsOn: [sreGroupRoles, sreWebRole]
}

resource sreSystemRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in [readerRole, monitoringReaderRole, logAnalyticsReaderRole]: {
  name: guid(resourceGroup().id, sre.id, role)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: sre.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource sreAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sre
  name: guid(sre.id, adminObjectId, sreAdministratorRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAdministratorRole)
    principalId: adminObjectId
    principalType: adminPrincipalType
  }
}

output webAppName string = web.name
output webAppUrl string = 'https://${web.properties.defaultHostName}'
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output alertRuleId string = latencyAlert.id
output alertRuleName string = latencyAlert.name
output vmName string = vm.name
output agentName string = sre.name
output agentId string = sre.id
output agentEndpoint string = sre.properties.agentEndpoint
output observabilityAgentId string = observabilityAgent.id
output observabilityPrincipalId string = obaIdentity.properties.principalId
output monitorWorkspaceId string = monitorWorkspace.id
