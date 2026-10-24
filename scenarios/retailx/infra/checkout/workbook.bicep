targetScope = 'resourceGroup'

param environmentName string
param location string
param tags object
param workspaceId string

var requests = '''
AppRequests
| where Name == "POST /checkout"
| extend country = tostring(Properties["retail.country"])
| where country in ("BE", "NL")
'''
var panels = [
  {
    name: 'checkout-latency'
    title: 'Successful checkout p95 by country (ms; at least 5 samples per minute)'
    query: replace('''
__REQUESTS__
| where Success == true
| summarize samples = count(), p95 = percentile(DurationMs, 95) by bin(TimeGenerated, 1m), country
| project TimeGenerated, country, p95 = iff(samples >= 5, p95, real(null))
| order by TimeGenerated asc
''', '__REQUESTS__', requests)
  }
  {
    name: 'price-dependency'
    title: 'Price lookup p95 by country and backend (ms; at least 5 samples per minute)'
    query: replace('''
let checkouts = __REQUESTS__
| where isnotempty(OperationId)
| distinct OperationId, country;
AppDependencies
| where Target in ("erp-price-service", "legacy-price-gateway")
| join kind=inner checkouts on OperationId
| summarize samples = count(), p95 = percentile(DurationMs, 95) by bin(TimeGenerated, 1m), country, Target
| project TimeGenerated, series = strcat(country, " / ", Target), p95 = iff(samples >= 5, p95, real(null))
| order by TimeGenerated asc
''', '__REQUESTS__', requests)
  }
  {
    name: 'checkout-success'
    title: 'Checkout success rate by country (%; at least 5 samples per minute)'
    query: replace('''
__REQUESTS__
| summarize samples = count(), successes = countif(Success == true) by bin(TimeGenerated, 1m), country
| project TimeGenerated, country, successPercent = iff(samples >= 5, 100.0 * successes / samples, real(null))
| order by TimeGenerated asc
''', '__REQUESTS__', requests)
  }
  {
    name: 'checkout-volume'
    title: 'Observed checkout requests per minute by country'
    query: replace('''
__REQUESTS__
| summarize requests = count() by bin(TimeGenerated, 1m), country
| order by TimeGenerated asc
''', '__REQUESTS__', requests)
  }
]

var chartItems = [for panel in panels: {
  type: 3
  name: panel.name
  content: {
    version: 'KqlItem/1.0'
    title: panel.title
    query: panel.query
    resourceType: 'microsoft.operationalinsights/workspaces'
    resources: [workspaceId]
    queryType: 0
    visualization: 'timechart'
    size: 0
    timeContext: { durationMs: 3600000 }
  }
}]

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'retailtx-checkout-workbook', environmentName)
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'RetailTx ${environmentName}: checkout health'
    category: 'workbook'
    sourceId: workspaceId
    serializedData: string({
      version: 'Notebook/1.0'
      isLocked: false
      fallbackResourceIds: [workspaceId]
      items: concat([
        {
          type: 1
          name: 'introduction'
          content: {
            json: '# Checkout health\nLast hour, in one-minute buckets. BE is the fault country; NL is the control. Refresh during the demo; ingestion and App Service restarts can delay the graphs. No data is unknown, not zero latency or 100% success. Rates and percentiles have gaps below five observed samples per bucket. Counts are observed telemetry, not a financial transaction total. These panels do not start agents or repair faults.'
          }
        }
        {
          type: 3
          name: 'freshness'
          content: {
            version: 'KqlItem/1.0'
            title: 'Evidence freshness (last 5 minutes)'
            query: replace('''
let recent = __REQUESTS__
| where TimeGenerated > ago(5m)
| summarize samples = count(), newest = max(TimeGenerated) by country;
datatable(country:string) ["BE", "NL"]
| join kind=leftouter recent on country
| project country, samples, newest, evidence = iff(coalesce(samples, 0) >= 5 and newest > ago(3m), "Fresh", "UNKNOWN / insufficient or stale data")
''', '__REQUESTS__', requests)
            resourceType: 'microsoft.operationalinsights/workspaces'
            resources: [workspaceId]
            queryType: 0
            visualization: 'table'
            size: 0
            timeContext: { durationMs: 300000 }
          }
        }
      ], chartItems)
    })
  }
}

output workbookId string = workbook.id
