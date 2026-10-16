targetScope = 'resourceGroup'

param machineName string
param workspaceName string
param actionPrincipalId string
param tags object
param commandRoleName string
param actionAssignmentName string
param alertName string
param actionGroupId string

resource machine 'Microsoft.HybridCompute/machines@2024-07-10' existing = {
  name: machineName
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}
resource rule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${machineName}'
  location: resourceGroup().location
  kind: 'Linux'
  tags: tags
  properties: {
    dataSources: {
      syslog: [{
        name: 'checkout-service'
        streams: ['Microsoft-Syslog']
        facilityNames: ['local0']
        logLevels: ['Info', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
      }]
    }
    destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspace.id }] }
    dataFlows: [{
      streams: ['Microsoft-Syslog']
      destinations: ['workspace']
      transformKql: 'source | where ProcessName == "RetailTxCheckout"'
    }]
  }
}
resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'checkout-service'
  scope: machine
  properties: { dataCollectionRuleId: rule.id }
}
resource monitor 'Microsoft.HybridCompute/machines/extensions@2024-07-10' = {
  parent: machine
  name: 'AzureMonitorLinuxAgent'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [association]
}
// This grants guest scripting on one Arc machine, not a service-only boundary.
resource commandRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: commandRoleName
  properties: {
    roleName: 'RetailTx checkout Arc command ${uniqueString(resourceGroup().id)}'
    description: 'Run and inspect approved commands on the disposable checkout Arc host.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: [
        'Microsoft.HybridCompute/machines/read'
        'Microsoft.HybridCompute/machines/runcommands/read'
        'Microsoft.HybridCompute/machines/runcommands/write'
      ]
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}
resource actionRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: actionAssignmentName
  scope: machine
  properties: {
    principalId: actionPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: commandRole.id
  }
}
resource serviceAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: alertName
  location: resourceGroup().location
  tags: tags
  properties: {
    displayName: alertName
    description: 'Shared checkout price dependency unavailable; investigate impact in both countries.'
    severity: 2
    enabled: true
    scopes: [workspace.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      allOf: [{
        query: 'AppRequests | where Name == "POST /checkout" | summarize n=count(), failed=countif(Success == false) | where n >= 5 and 100.0 * failed / n >= 20'
        timeAggregation: 'Count'
        operator: 'GreaterThan'
        threshold: 0
        failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
      }]
    }
    actions: { actionGroups: [actionGroupId] }
  }
}
output commandRoleId string = commandRole.id
output actionAssignmentId string = actionRole.id
