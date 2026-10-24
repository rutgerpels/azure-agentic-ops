targetScope = 'resourceGroup'

param alertName string
param location string
param tags object
param workspaceId string
param actionGroupId string

resource latencyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: alertName
  location: location
  tags: tags
  properties: {
    displayName: alertName
    description: 'Checkout p95 latency above 1 s for a country (n >= 5, 5 minutes).'
    severity: 2
    enabled: true
    scopes: [workspaceId]
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
    actions: { actionGroups: [actionGroupId] }
  }
}
