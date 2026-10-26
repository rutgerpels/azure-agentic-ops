param environmentName string
param location string
param nameSuffix string
param tags object
param serverFarmId string

var webName = 'app-rtx-teams-${environmentName}-${nameSuffix}'

resource botIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-retailtx-incident-${environmentName}-teams'
  location: location
  tags: tags
}

resource web 'Microsoft.Web/sites@2024-04-01' = {
  name: webName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${botIdentity.id}': {} }
  }
  properties: {
    serverFarmId: serverFarmId
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'python teams_server.py'
      alwaysOn: true
      healthCheckPath: '/health/live'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      numberOfWorkers: 1
    }
  }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: web
  name: 'scm'
  properties: { allow: false }
}

resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: web
  name: 'ftp'
  properties: { allow: false }
}

// Only this separate host uses channel JWT authentication. Browser Easy Auth is unchanged.
resource auth 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: web
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: false }
    httpSettings: { requireHttps: true }
  }
}

resource logs 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: web
  name: 'logs'
  properties: {
    applicationLogs: { fileSystem: { level: 'Information' } }
    httpLogs: { fileSystem: { enabled: false } }
    detailedErrorMessages: { enabled: false }
    failedRequestsTracing: { enabled: false }
  }
}

resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: 'bot-rtx-incident-${environmentName}-${nameSuffix}'
  location: 'global'
  tags: tags
  kind: 'azurebot'
  sku: { name: 'F0' }
  properties: {
    displayName: 'Retailx incident assistant'
    endpoint: 'https://${web.properties.defaultHostName}/api/messages'
    msaAppType: 'UserAssignedMSI'
    msaAppId: botIdentity.properties.clientId
    msaAppTenantId: tenant().tenantId
    msaAppMSIResourceId: botIdentity.id
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource channel 'Microsoft.BotService/botServices/channels@2022-09-15' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: { isEnabled: true }
  }
}

output webAppName string = web.name
output webAppId string = web.id
output webAppUrl string = 'https://${web.properties.defaultHostName}'
output scmUrl string = 'https://${first(filter(web.properties.enabledHostNames, hostname => contains(hostname, '.scm.')))}'
output runtimePrincipalId string = web.identity.principalId
output botClientId string = botIdentity.properties.clientId
output botIdentityId string = botIdentity.id
output botId string = bot.id
output possibleOutboundIps array = split(web.properties.possibleOutboundIpAddresses, ',')
