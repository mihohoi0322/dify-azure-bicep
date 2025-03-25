@description('リソースの場所')
param location string

@description('ACA Log Analyticsワークスペース名')
param acaLogaName string

@description('ACA環境名')
param acaEnvName string

@description('ACAサブネットID')
param acaSubnetId string

@description('ストレージアカウント名')
param storageAccountName string

@description('ストレージアカウントキー')
@secure()
param storageAccountKey string

@description('ストレージコンテナ名')
param storageContainerName string

@description('Redisホスト名')
param redisHostName string = ''

@description('Redisプライマリキー')
@secure()
param redisPrimaryKey string = ''

@description('PostgreSQLサーバー完全修飾ドメイン名')
param postgresServerFqdn string

@description('PostgreSQL管理者ログイン')
param postgresAdminLogin string

@description('PostgreSQL管理者パスワード')
@secure()
param postgresAdminPassword string

@description('PostgresのDifyデータベース名')
param postgresDifyDbName string

@description('PostgresのVectorデータベース名')
param postgresVectorDbName string

@description('Nginxファイル共有名')
param nginxShareName string

@description('SSRFプロキシファイル共有名')
param ssrfProxyShareName string

@description('Sandboxファイル共有名')
param sandboxShareName string

@description('プラグインファイル共有名')
param pluginStorageShareName string

@description('独自証明書を提供するかどうか')
param isProvidedCert bool = false

@description('証明書の内容 (Base64エンコード)')
@secure()
param acaCertBase64Value string = ''

@description('証明書のパスワード')
@secure()
param acaCertPassword string = ''

@description('Difyのカスタムドメイン')
param acaDifyCustomerDomain string = ''

@description('ACAアプリの最小インスタンス数')
param acaAppMinCount int = 0

@description('Dify APIイメージ')
param difyApiImage string

@description('Dify サンドボックスイメージ')
param difySandboxImage string

@description('Dify Webイメージ')
param difyWebImage string

@description('Dify Plugin Daemonイメージ')
param difyPluginDaemonImage string

@description('Blobエンドポイント')
param blobEndpoint string

// Log Analyticsワークスペースを作成
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: acaLogaName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ACA環境を作成
resource acaEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: acaEnvName
  location: location
  properties: {
    // 最新のAPIに合わせて構造を修正
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    // workloadProfilesの代わりにこれを使用
    zoneRedundant: false
    // サブネット接続の指定方法を修正
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnetId
      internal: false
    }
  }
}

// Nginxファイル共有をACA環境にマウント
resource nginxFileShare 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  name: 'nginxshare'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: nginxShareName
      accessMode: 'ReadWrite'
    }
  }
}

// 証明書をACA環境に追加（条件付き）
resource difyCerts 'Microsoft.App/managedEnvironments/certificates@2023-05-01' = if (isProvidedCert) {
  name: 'difycerts'
  parent: acaEnv
  properties: {
    password: acaCertPassword
    value: acaCertBase64Value
  }
}

// Nginxアプリのリソース定義を変更
resource nginxApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'nginx'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        customDomains: isProvidedCert ? [
          {
            name: acaDifyCustomerDomain
            certificateId: difyCerts.id
          }
        ] : []
      }
    }
    template: {
      containers: [
        {
          name: 'nginx'
          image: 'nginx:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          volumeMounts: [
            {
              volumeName: 'nginxconf'
              mountPath: '/custom-nginx' // マウントポイントを変更
            }
          ]
          command: [
            '/bin/bash'
            '-c'
            'cp -rf /custom-nginx/* /etc/nginx/ && nginx -g "daemon off;"'
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'nginx'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'nginxconf'
          storageType: 'AzureFile'
          storageName: nginxFileShare.name
        }
      ]
    }
  }
}

// SSRFプロキシ用ファイル共有をACA環境にマウント
resource ssrfProxyFileShare 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  name: 'ssrfproxyfileshare'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: ssrfProxyShareName
      accessMode: 'ReadWrite'
    }
  }
}

// SSRFプロキシアプリをデプロイ
resource ssrfProxyApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ssrfproxy'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 3128
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'ssrfproxy'
          image: 'ubuntu/squid:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          volumeMounts: [
            {
              volumeName: 'ssrfproxy'
              mountPath: '/etc/squid'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'ssrfproxy'
            tcp: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'ssrfproxy'
          storageType: 'AzureFile'
          storageName: ssrfProxyFileShare.name
        }
      ]
    }
  }
}

// Sandbox用ファイル共有をACA環境にマウント
resource sandboxFileShare 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  name: 'sandbox'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: sandboxShareName
      accessMode: 'ReadWrite'
    }
  }
}

// Sandboxアプリをデプロイ
resource sandboxApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'sandbox'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 8194
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difySandboxImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'API_KEY'
              value: 'dify-sandbox'
            }
            {
              name: 'GIN_MODE'
              value: 'release'
            }
            {
              name: 'WORKER_TIMEOUT'
              value: '15'
            }
            {
              name: 'ENABLE_NETWORK'
              value: 'true'
            }
            {
              name: 'HTTP_PROXY'
              value: 'http://ssrfproxy:3128'
            }
            {
              name: 'HTTPS_PROXY'
              value: 'http://ssrfproxy:3128'
            }
            {
              name: 'SANDBOX_PORT'
              value: '8194'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'sandbox'
              mountPath: '/dependencies'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'sandbox'
            tcp: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'sandbox'
          storageType: 'AzureFile'
          storageName: sandboxFileShare.name
        }
      ]
    }
  }
}

// ワーカーアプリをデプロイ
resource workerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'worker'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {}
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyApiImage
          resources: {
            cpu: json('2')
            memory: '4Gi'
          }
          env: [
            {
              name: 'MODE'
              value: 'worker'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
            {
              name: 'SECRET_KEY'
              value: 'sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U'
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '5432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '6379'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'false'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'redis://:${redisPrimaryKey}@${redisHostName}:6379/1'
            }
            {
              name: 'STORAGE_TYPE'
              value: 'azure-blob'
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_NAME'
              value: storageAccountName
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_KEY'
              value: storageAccountKey
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_URL'
              value: blobEndpoint
            }
            {
              name: 'AZURE_BLOB_CONTAINER_NAME'
              value: storageContainerName
            }
            {
              name: 'VECTOR_STORE'
              value: 'pgvector'
            }
            {
              name: 'PGVECTOR_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'PGVECTOR_PORT'
              value: '5432'
            }
            {
              name: 'PGVECTOR_USER'
              value: postgresAdminLogin
            }
            {
              name: 'PGVECTOR_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'PGVECTOR_DATABASE'
              value: postgresVectorDbName
            }
            {
              name: 'INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH'
              value: '1000'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'worker'
            tcp: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// APIアプリをデプロイ
resource apiApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'api'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 5001
        exposedPort: 5001
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyApiImage
          resources: {
            cpu: json('2')
            memory: '4Gi'
          }
          env: [
            {
              name: 'MODE'
              value: 'api'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
            {
              name: 'SECRET_KEY'
              value: 'sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U'
            }
            {
              name: 'CONSOLE_WEB_URL'
              value: ''
            }
            {
              name: 'INIT_PASSWORD'
              value: ''
            }
            {
              name: 'CONSOLE_API_URL'
              value: ''
            }
            {
              name: 'SERVICE_API_URL'
              value: ''
            }
            {
              name: 'APP_WEB_URL'
              value: ''
            }
            {
              name: 'FILES_URL'
              value: ''
            }
            {
              name: 'FILES_ACCESS_TIMEOUT'
              value: '300'
            }
            {
              name: 'MIGRATION_ENABLED'
              value: 'true'
            }
            {
              name: 'SENTRY_DSN'
              value: ''
            }
            {
              name: 'SENTRY_TRACES_SAMPLE_RATE'
              value: '1.0'
            }
            {
              name: 'SENTRY_PROFILES_SAMPLE_RATE'
              value: '1.0'
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '5432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'WEB_API_CORS_ALLOW_ORIGINS'
              value: '*'
            }
            {
              name: 'CONSOLE_CORS_ALLOW_ORIGINS'
              value: '*'
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '6379'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'false'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'redis://:${redisPrimaryKey}@${redisHostName}:6379/1'
            }
            {
              name: 'STORAGE_TYPE'
              value: 'azure-blob'
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_NAME'
              value: storageAccountName
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_KEY'
              value: storageAccountKey
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_URL'
              value: blobEndpoint
            }
            {
              name: 'AZURE_BLOB_CONTAINER_NAME'
              value: storageContainerName
            }
            {
              name: 'VECTOR_STORE'
              value: 'pgvector'
            }
            {
              name: 'PGVECTOR_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'PGVECTOR_PORT'
              value: '5432'
            }
            {
              name: 'PGVECTOR_USER'
              value: postgresAdminLogin
            }
            {
              name: 'PGVECTOR_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'PGVECTOR_DATABASE'
              value: postgresVectorDbName
            }
            {
              name: 'CODE_EXECUTION_API_KEY'
              value: 'dify-sandbox'
            }
            {
              name: 'CODE_EXECUTION_ENDPOINT'
              value: 'http://sandbox:8194'
            }
            {
              name: 'CODE_MAX_NUMBER'
              value: '9223372036854775807'
            }
            {
              name: 'CODE_MIN_NUMBER'
              value: '-9223372036854775808'
            }
            {
              name: 'CODE_MAX_STRING_LENGTH'
              value: '80000'
            }
            {
              name: 'TEMPLATE_TRANSFORM_MAX_LENGTH'
              value: '80000'
            }
            {
              name: 'CODE_MAX_OBJECT_ARRAY_LENGTH'
              value: '30'
            }
            {
              name: 'CODE_MAX_STRING_ARRAY_LENGTH'
              value: '30'
            }
            {
              name: 'CODE_MAX_NUMBER_ARRAY_LENGTH'
              value: '1000'
            }
            {
              name: 'INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH'
              value: '1000'
            }
            {
              name: 'PLUGIN_DAEMON_URL'
              value: 'http://plugin:5002'
            }
            {
              name: 'PLUGIN_DAEMON_KEY'
              value: 'lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi'
            }
            {
              name: 'INNER_API_KEY_FOR_PLUGIN'
              value: '-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'api'
            tcp: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// プラグイン用ファイル共有をACA環境にマウント
resource pluginstorageFileShare 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  name: 'pluginstoragefileshare'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: pluginStorageShareName
      accessMode: 'ReadWrite'
    }
  }
}

// プラグインデーモンアプリをデプロイ
resource pluginDaemonApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'plugin'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 5002
        exposedPort: 5002
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyPluginDaemonImage
          resources: {
            cpu: json('2')
            memory: '4Gi'
          }
          volumeMounts: [
            {
              volumeName: 'pluginstorage'
              mountPath: '/app/storage'
            }
          ]
          env: [
            {
              name: 'GIN_MODE'
              value: 'release'
            }
            {
              name: 'SERVER_PORT'
              value: '5002'
            }
            {
              name: 'SERVER_KEY'
              value: 'lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi'
            }
            {
              name: 'PLATFORM'
              value: 'local'
            }
            {
              name: 'DIFY_INNER_API_KEY'
              value: '-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1'
            }
            {
              name: 'DIFY_INNER_API_URL'
              value: 'http://api:5001'
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '5432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '6379'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'false'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'redis://:${redisPrimaryKey}@${redisHostName}:6379/1'
            }
            {
              name: 'PLUGIN_STORAGE_TYPE'
              value: 'local'
            }
            {
              name: 'PLUGIN_WORKING_PATH'
              value: 'cwd'
            }
            {
              name: 'PLUGIN_INSTALLED_PATH'
              value: 'plugin'
            }
            {
              name: 'DB_SSL_MODE'
              value: 'require'
            }
            {
              name: 'PLUGIN_WEBHOOK_ENABLED'
              value: 'true'
            }
            {
              name: 'PLUGIN_REMOTE_INSTALLING_ENABLED'
              value: 'true'
            }
            {
              name: 'PLUGIN_REMOTE_INSTALLING_HOST'
              value: '127.0.0.1'
            }
            {
              name: 'PLUGIN_REMOTE_INSTALLING_PORT'
              value: '5003'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'api'
            tcp: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'pluginstorage'
          storageType: 'AzureFile'
          storageName: pluginstorageFileShare.name
        }
      ]
    }
  }
}

// Webアプリをデプロイ
resource webApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'web'
  location: location
  properties: {
    environmentId: acaEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 3000
        exposedPort: 3000
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyWebImage
          resources: {
            cpu: json('1')
            memory: '2Gi'
          }
          env: [
            {
              name: 'CONSOLE_API_URL'
              value: ''
            }
            {
              name: 'APP_API_URL'
              value: ''
            }
            {
              name: 'SENTRY_DSN'
              value: ''
            }
            {
              name: 'MARKETPLACE_API_URL'
              value: 'https://marketplace.dify.ai'
            }
            {
              name: 'MARKETPLACE_URL'
              value: 'https://marketplace.dify.ai'            
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: 10
        rules: [
          {
            name: 'web'
            tcp: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// デプロイ出力
output difyAppUrl string = nginxApp.properties.configuration.ingress.fqdn
