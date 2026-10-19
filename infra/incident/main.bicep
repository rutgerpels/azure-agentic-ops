targetScope = 'resourceGroup'

param environmentName string
param location string = 'swedencentral'
param nameSuffix string
param tags object
param browserClientId string
param allowedOperatorId string
param ownerToken string
param runId string
param agentVersion string = ''

var stem = 'retailtx-incident-${environmentName}'
var webName = 'app-rtx-incident-${environmentName}-${nameSuffix}'
var accountName = 'aif-rtx-incident-${environmentName}-${nameSuffix}'
var runtimeRole = 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
var runtimeTags = union(tags, { system: 'CAP', site: 'cloud' })

resource authIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${stem}-auth'
  location: location
  tags: runtimeTags
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${stem}'
  location: location
  tags: runtimeTags
  kind: 'linux'
  sku: { name: 'B1' }
  properties: { reserved: true }
}

resource web 'Microsoft.Web/sites@2024-04-01' = {
  name: webName
  location: location
  tags: runtimeTags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${authIdentity.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'python -m uvicorn app:app --host 0.0.0.0 --port 8000 --workers 1 --proxy-headers --forwarded-allow-ips="*" --no-access-log'
      alwaysOn: true
      healthCheckPath: '/health/live'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
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

resource applicationLogs 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: web
  name: 'logs'
  properties: {
    applicationLogs: { fileSystem: { level: 'Information' } }
    httpLogs: { fileSystem: { enabled: false } }
    detailedErrorMessages: { enabled: false }
    failedRequestsTracing: { enabled: false }
  }
}

resource auth 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: web
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true, runtimeVersion: '~1' }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
      excludedPaths: ['/health/live']
    }
    httpSettings: { requireHttps: true }
    login: {
      tokenStore: { enabled: false }
      preserveUrlFragmentsForLogins: false
      cookieExpiration: { convention: 'FixedTime', timeToExpiration: '01:00:00' }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: browserClientId
          openIdIssuer: 'https://login.microsoftonline.com/${tenant().tenantId}/v2.0'
          clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
        }
        login: { loginParameters: ['scope=openid profile'] }
        validation: {
          allowedAudiences: [browserClientId, 'api://${browserClientId}']
          defaultAuthorizationPolicy: {
            allowedPrincipals: { identities: [allowedOperatorId] }
          }
        }
      }
    }
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${stem}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// Own Azure's default smart-detection resources instead of leaving untagged dependencies.
resource smartDetectionActions 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'Application Insights Smart Detection'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    groupShortName: 'SmartDetect'
    armRoleReceivers: [
      {
        name: 'Monitoring Contributor'
        roleId: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
        useCommonAlertSchema: true
      }
      {
        name: 'Monitoring Reader'
        roleId: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
        useCommonAlertSchema: true
      }
    ]
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${stem}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
  dependsOn: [smartDetectionActions]
}

resource failureAlert 'Microsoft.AlertsManagement/smartDetectorAlertRules@2021-04-01' = {
  name: 'Failure Anomalies - ${insights.name}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Detect unusual increases in failed incident-assistant requests or dependencies.'
    detector: { id: 'FailureAnomaliesDetector' }
    frequency: 'PT1M'
    scope: [insights.id]
    severity: 'Sev3'
    state: 'Enabled'
    actionGroups: { groupIds: [smartDetectionActions.id] }
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: map(split(web.properties.outboundIpAddresses, ','), address => { value: address })
    }
  }
}

resource model 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: 'incident-reasoner'
  sku: { name: 'DataZoneStandard', capacity: 50 }
  properties: {
    model: { format: 'OpenAI', name: 'gpt-5-mini', version: '2025-08-07' }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: 'incident'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'RetailTx incident management'
    description: 'Read-only evidence-based retail incident assistant.'
  }
  dependsOn: [model]
}

resource runtimeAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, web.id, runtimeRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', runtimeRole)
    principalId: web.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource settings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: web
  name: 'appsettings'
  properties: {
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    ENABLE_ORYX_BUILD: 'true'
    FOUNDRY_PROJECT_ENDPOINT: project.properties.endpoints['AI Foundry API']
    FOUNDRY_MODEL_DEPLOYMENT: model.name
    FOUNDRY_AGENT_NAME: 'incident-manager'
    FOUNDRY_AGENT_VERSION: agentVersion
    DEMO_TENANT_ID: tenant().tenantId
    DEMO_ALLOWED_OBJECT_ID: allowedOperatorId
    DEMO_OWNER_TOKEN: ownerToken
    DEMO_RUN_ID: runId
    DEMO_EVIDENCE_MODE: 'fixture'
    APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
    OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID: authIdentity.properties.clientId
    AZURE_TRACING_GEN_AI_CONTENT_RECORDING_ENABLED: 'false'
    OTEL_SERVICE_NAME: 'retailtx-incident'
    PYTHONUNBUFFERED: '1'
    WEBSITE_WARMUP_PATH: '/health/live'
    WEBSITE_WARMUP_STATUSES: '200'
  }
}

resource stickySettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: web
  name: 'slotConfigNames'
  properties: { appSettingNames: ['OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'] }
}

output webAppName string = web.name
output webAppId string = web.id
output webAppUrl string = 'https://${web.properties.defaultHostName}'
output scmUrl string = 'https://${first(filter(web.properties.enabledHostNames, hostname => contains(hostname, '.scm.')))}'
output runtimePrincipalId string = web.identity.principalId
output authIdentityId string = authIdentity.id
output authIdentityPrincipalId string = authIdentity.properties.principalId
output authIdentityClientId string = authIdentity.properties.clientId
output foundryAccountName string = foundry.name
output foundryAccountId string = foundry.id
output foundryProjectId string = project.id
output foundryProjectEndpoint string = project.properties.endpoints['AI Foundry API']
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsId string = insights.id
output modelName string = model.name
