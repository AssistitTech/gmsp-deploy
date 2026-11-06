// GMSP: one-click Azure installation (the "Deploy to Azure" button).
//
// Creates, in ONE new resource group, exactly what `python scripts/install_azure.py` (stage 1) plus
// `--connect-github <owner>/<fork>` create for a fresh install, with the same names:
//
//   gmspfn<suffix>                 storage account of the Function App
//   gmsp-logs-<suffix>             Log Analytics workspace (in this resource group, never Azure's DefaultResourceGroup)
//   gmsp-api-<suffix>              Application Insights (workspace-based) + Flex Consumption plan (FC1) + Function App
//                                  (Python 3.12, system-assigned managed identity: the keyless bridge to Google, and
//                                  the identity the app reaches its own storage with: no storage key anywhere)
//   gmsp-plan-<suffix>             the Flex Consumption plan (one app per plan; billed per execution, no always-ready
//                                  instances)
//   gmsp-portal-<suffix>           Static Web App (Standard) with the Function App linked as its backend; the link
//                                  locks the Function App to portal traffic (App Service Authentication)
//   gmsp-db-<suffix>               PostgreSQL flexible server (the size YOU chose; never a silent upgrade) + database
//                                  `gmsp` + the "Azure services" firewall rule
//   gmsp-github-deploy-<suffix>    user-assigned identity + federated credential for repo:<owner>/<fork>:ref:refs/heads/main
//                                  + Website Contributor (Function App) and Contributor (Static Web App) only
//
// The database password and the secret-store key are generated here and written only into the Function App's app
// settings: never shown, never an output. The code itself arrives through your fork's GitHub Actions workflow (outputs
// list the repository variables it needs). Compile: `bicep build gmsp.bicep --outfile azuredeploy.json`.
//
// Hosting plan (v1.0.2): Flex Consumption, not the Linux Consumption plan (Y1 / Dynamic). New subscriptions get a Y1
// quota of 0 ("SubscriptionIsOverQuotaForSku ... Y1 VMs") and Microsoft calls Consumption the legacy plan. Flex runs only
// in some regions (the wizard checks the chosen one); the shape below follows Microsoft's Flex Consumption samples
// (Azure-Samples/azure-functions-flex-consumption-samples, IaC/bicep) and its list of deprecated Flex settings: no
// FUNCTIONS_WORKER_RUNTIME / FUNCTIONS_EXTENSION_VERSION / SCM_DO_BUILD_DURING_DEPLOYMENT / ENABLE_ORYX_BUILD /
// WEBSITE_RUN_FROM_PACKAGE app settings and no linuxFxVersion / ftpsState: the runtime is functionAppConfig.runtime.

targetScope = 'resourceGroup'

@description('Region of the Function App, its storage and logs, and the deploy identity. It must offer the Flex Consumption plan (az functionapp list-flexconsumption-locations); the Deploy to Azure wizard checks it.')
param location string = resourceGroup().location

@description('Short name suffix, lowercase letters and digits; the default is derived from the resource group, so names are unique and stable.')
@minLength(3)
@maxLength(13)
param suffix string = take(uniqueString(resourceGroup().id), 5)

@description('PostgreSQL size. Standard_B1ms (Burstable) is the recommended size for one MSP.')
@allowed([
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_B2ms'
  'Standard_D2s_v3'
  'Standard_D2ds_v4'
])
param dbSkuName string = 'Standard_B1ms'

@description('Region of the database server; empty means the same region as everything else.')
param databaseLocation string = ''

@description('Database storage in GB (the install wizard uses 32).')
@allowed([
  32
  64
  128
])
param dbStorageGb int = 32

@description('PostgreSQL major version (both installers use 17, generally available on flexible server; the guided form and the command-line installer check that the database region offers it before anything is created).')
@allowed([
  '16'
  '17'
])
param postgresVersion string = '17'

@description('Region of the Static Web App resource (the portal itself is served worldwide).')
@allowed([
  'westus2'
  'centralus'
  'eastus2'
  'westeurope'
  'eastasia'
])
param staticWebAppLocation string = 'eastus2'

@description('Email address of the first Owner: the first sign-in with exactly this address becomes Owner (one time).')
@minLength(3)
param ownerEmail string

@description('Your fork of the GMSP distribution repository, as owner/name. Its workflow deploys GMSP here.')
@minLength(3)
param githubRepository string

@description('narrow: Website Contributor on the Function App + Contributor on the Static Web App. resource-group: Contributor on the whole resource group.')
@allowed([
  'narrow'
  'resource-group'
])
param githubRoleScope string = 'narrow'

@description('Daily ingestion cap of the Log Analytics workspace, in GB ("-1" = no cap). Keeps the logs bill bounded.')
@allowed([
  '0.1'
  '0.25'
  '0.5'
  '1'
  '-1'
])
param logDailyCapGb string = '0.25'

@description('Generated; leave as is. The database password: upper, lower, digits and a symbol (Azure wants three of the four), URL-safe so the database URL needs no escaping. Never shown, never an output.')
@secure()
param dbAdminPassword string = 'Gm-${newGuid()}-${toUpper(uniqueString(newGuid()))}'

@description('Generated; leave as is. The secret-store key GMSP_SECRET_KEY: two GUIDs, not a Fernet key, so GMSP derives one from it with HKDF-SHA256 (gmsp/secretstore.py). Never shown, never an output.')
@secure()
param secretStoreKey string = '${newGuid()}${newGuid()}'

var tags = {
  app: 'gmsp'
}
var funcName = 'gmsp-api-${suffix}'
var swaName = 'gmsp-portal-${suffix}'
var dbName = 'gmsp-db-${suffix}'
var storageName = 'gmspfn${suffix}' // storage names: 3-24 lowercase letters and digits
var logsName = 'gmsp-logs-${suffix}'
var planName = 'gmsp-plan-${suffix}'
// Flex Consumption keeps the deployed package in a blob container of the app's own storage account.
var deploymentContainerName = 'app-package-${funcName}'
// Flex scale: 2048 MB is Microsoft's recommended default instance size (512 MB is too small for GMSP's Python API with
// the Google client libraries); a low ceiling of on-demand instances bounds the bill, and there are NO always-ready
// instances (those are billed around the clock).
var instanceMemoryMB = 2048
var maximumInstanceCount = 10
var deployIdentityName = 'gmsp-github-deploy-${suffix}'
var dbLocation = empty(databaseLocation) ? location : databaseLocation
var dbTier = startsWith(dbSkuName, 'Standard_B') ? 'Burstable' : 'GeneralPurpose'
var dbAdmin = 'gmspadmin'
var githubSubject = 'repo:${githubRepository}:ref:refs/heads/main'
var federatedCredentialName = take(replace(replace(replace('github-${githubRepository}-main', '/', '-'), '.', '-'), '_', '-'), 120)
var websiteContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'de139f84-1756-47ae-9be6-808fbbe84772')
var contributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
// The Function App's own identity on its storage account, as Microsoft documents for identity-based host storage
// (AzureWebJobsStorage__*) and the Flex deployment container: blob (owner: the host takes blob leases, e.g. for the
// timer's singleton lock, and the deployment package), queue and table.
var storageRoles = {
  blobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  queueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  tableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // the app reaches its storage with its managed identity only
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: json(logDailyCapGb)
    }
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: funcName
  location: location
  tags: union(tags, {
    'hidden-link:${resourceId('Microsoft.Web/sites', funcName)}': 'Resource'
  })
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true // Linux (Flex Consumption is Linux only)
  }
}

resource funcApp 'Microsoft.Web/sites@2024-04-01' = {
  name: funcName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: insights.properties.ConnectionString
        }
        {
          name: 'GMSP_DATABASE_URL'
          value: 'postgresql+psycopg://${dbAdmin}:${dbAdminPassword}@${postgres.properties.fullyQualifiedDomainName}:5432/gmsp?sslmode=require'
        }
        {
          name: 'GMSP_ENV'
          value: 'prod'
        }
        {
          name: 'GMSP_SECRET_KEY'
          value: secretStoreKey
        }
        {
          name: 'GMSP_BOOTSTRAP_OWNER'
          value: toLower(trim(ownerEmail))
        }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

// The app's identity on its own storage account (host storage + the deployment container). No storage key is used.
resource funcStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in items(storageRoles): {
  scope: storage
  name: guid(storage.id, funcApp.id, role.value)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.value)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource portal 'Microsoft.Web/staticSites@2024-04-01' = {
  name: swaName
  location: staticWebAppLocation
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    allowConfigFileUpdates: true
    stagingEnvironmentPolicy: 'Disabled' // production only: no pull-request preview environments
  }
}

// Linking the backend also turns on App Service Authentication on the Function App with this Static Web App as the
// only provider, so a direct call to the Function App cannot forge the signed-in-user header. The fork's deploy
// workflow verifies that before it deploys any code.
resource backend 'Microsoft.Web/staticSites/linkedBackends@2024-04-01' = {
  parent: portal
  name: 'backend'
  properties: {
    backendResourceId: funcApp.id
    region: location
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: dbName
  location: dbLocation
  tags: tags
  sku: {
    name: dbSkuName
    tier: dbTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: dbAdmin
    administratorLoginPassword: dbAdminPassword
    storage: {
      storageSizeGB: dbStorageGb
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: 'gmsp'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// What `--public-access 0.0.0.0` creates: Azure services (the Function App) may connect; nothing else.
resource azureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgres
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource deployIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deployIdentityName
  location: location
  tags: tags
}

resource githubTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deployIdentity
  name: federatedCredentialName
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: githubSubject
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource deployOnFunctionApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (githubRoleScope == 'narrow') {
  scope: funcApp
  name: guid(funcApp.id, deployIdentity.id, websiteContributor)
  properties: {
    roleDefinitionId: websiteContributor
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployOnPortal 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (githubRoleScope == 'narrow') {
  scope: portal
  name: guid(portal.id, deployIdentity.id, contributor)
  properties: {
    roleDefinitionId: contributor
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployOnResourceGroup 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (githubRoleScope == 'resource-group') {
  name: guid(resourceGroup().id, deployIdentity.id, contributor)
  properties: {
    roleDefinitionId: contributor
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

var githubVariables = {
  AZURE_CLIENT_ID: deployIdentity.properties.clientId
  AZURE_TENANT_ID: deployIdentity.properties.tenantId
  AZURE_SUBSCRIPTION_ID: subscription().subscriptionId
  GMSP_RESOURCE_GROUP: resourceGroup().name
  GMSP_FUNCTION_APP: funcApp.name
  GMSP_STATIC_WEB_APP: portal.name
  GMSP_API_ACCESS: 'false'
}

@description('The portal. Open it after the first workflow run and sign in with the Owner email.')
output portalUrl string = 'https://${portal.properties.defaultHostname}'

@description('Repository VARIABLES for your fork (Settings > Secrets and variables > Actions > Variables). None is a secret.')
output githubVariables object = githubVariables

@description('The same variables as GitHub CLI commands (run after `gh auth login`).')
output ghVariableCommands string = join(map(items(githubVariables), v => 'gh variable set ${v.key} --repo ${githubRepository} --body "${v.value}"'), '\n')

@description('Where to add the variables in your fork.')
output forkVariablesUrl string = 'https://github.com/${githubRepository}/settings/variables/actions'

@description('Your fork\'s Actions tab: enable workflows, then Deploy GMSP > Run workflow.')
output forkActionsUrl string = 'https://github.com/${githubRepository}/actions'

@description('The federated credential subject the deploy identity trusts.')
output githubSubject string = githubSubject

@description('The first Owner (one-time bootstrap; sign in with exactly this address).')
output ownerEmail string = toLower(trim(ownerEmail))

@description('Names of what was created.')
output resources object = {
  functionApp: funcApp.name
  functionPlan: '${plan.name} (Flex Consumption, ${instanceMemoryMB} MB instances, at most ${maximumInstanceCount}, none always ready)'
  staticWebApp: portal.name
  database: postgres.name
  databaseSku: '${dbSkuName} (${dbTier})'
  databaseRegion: dbLocation
  deployIdentity: deployIdentity.name
  logAnalytics: logs.name
}
