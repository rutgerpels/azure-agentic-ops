// Subscription singleton. The lifecycle deploys it only when absent and removes
// it on Down only when it still points to this environment's workspace.
// Shape: https://learn.microsoft.com/azure/azure-monitor/aiops/issues-how-to
targetScope = 'subscription'

param monitorWorkspaceId string

#disable-next-line BCP081
resource settings 'Microsoft.Monitor/settings@2025-06-03-preview' = {
  name: 'default'
  properties: {
    defaultAzureMonitorWorkspace: monitorWorkspaceId
  }
}
