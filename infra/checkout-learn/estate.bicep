targetScope = 'resourceGroup'

param environmentName string
param location string
param tags object
param alertEmail string
param adminPublicKey string
param vmSize string = 'Standard_B2s'
param posIntervalSeconds int = 3
param vmAdminUsername string = 'retailtxadmin'
@description('Reserved; ownership is carried by tags.')
param ownerToken string

var suffix = take(uniqueString(resourceGroup().id), 6)
var stem = 'retailtx-checkout-${environmentName}'
var backendIp = '10.61.0.10'
var alertName = 'alert-checkout-latency-${environmentName}'
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

// Declared per-country price routes; scripts/Sync-CheckoutRoutes.ps1 applies the same file.
var priceRoutes = loadJsonContent('../checkout/price-routes.json')

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
        { name: 'PRICE_ROUTE_BE', value: priceRoutes.PRICE_ROUTE_BE }
        { name: 'PRICE_ROUTE_NL', value: priceRoutes.PRICE_ROUTE_NL }
        { name: 'ROUTE_CHANGE_REF', value: priceRoutes.ROUTE_CHANGE_REF }
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
var arcScript = '#!/bin/bash\nset -euo pipefail\n'
var cloudInit = replace(replace(replace(replace(loadTextContent('../checkout/dc1-cloud-init.yaml'),
  '__PRICE_BACKEND__', loadFileAsBase64('../../app/checkout/onprem/price_backend.py')),
  '__POS_SIM__', loadFileAsBase64('../../app/checkout/onprem/pos_sim.py')),
  '__POS_CONFIG__', base64(posConfig)),
  '__ARC_BOOTSTRAP__', base64(replace(arcScript, '\r\n', '\n')))

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: 'vm-rtx-erp-${environmentName}'
  location: location
  tags: union(dcTags, { component: 'erp-price' })
  identity: { type: 'None' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
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
        provisionVMAgent: true
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
          query: 'AppRequests | where Name == "POST /checkout" and Success == true | extend country = tostring(Properties["retail.country"]) | where isnotempty(country) | summarize p95 = percentile(DurationMs, 95), n = count() by country | where n >= 5 and p95 > 1000'
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

output webAppName string = web.name
output webAppUrl string = 'https://${web.properties.defaultHostName}'
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output alertRuleId string = latencyAlert.id
output alertRuleName string = latencyAlert.name
output actionGroupId string = actionGroup.id
output vmName string = vm.name
