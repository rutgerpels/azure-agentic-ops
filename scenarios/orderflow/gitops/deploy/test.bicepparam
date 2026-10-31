using '../infra/env.bicep'

// Non-identifying stage values only. Deployment-specific values come from GitHub environment
// variables (or the lifecycle script) at deploy time; a missing variable fails parameter build.
param stage = 'test'
param addressPrefix = '10.61.0.0/24'
param alertsEnabled = false
param sharedResourceGroup = readEnvironmentVariable('ORDERFLOW_SHARED_RG')
param suffix = readEnvironmentVariable('ORDERFLOW_SUFFIX')
param presenterCidr = readEnvironmentVariable('ORDERFLOW_PRESENTER_CIDR')
param imageTag = readEnvironmentVariable('ORDERFLOW_IMAGE_TAG')
param deploySha = readEnvironmentVariable('ORDERFLOW_DEPLOY_SHA')
param ownerToken = readEnvironmentVariable('ORDERFLOW_OWNER_TOKEN')
param environmentName = readEnvironmentVariable('ORDERFLOW_ENVIRONMENT_NAME')
