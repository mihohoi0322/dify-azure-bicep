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
            '''
            mkdir -p /etc/nginx/conf.d /etc/nginx/modules && 
            # ベース64エンコードされたファイルがあればデコードする
            for encoded_file in /custom-nginx/*.b64; do
              if [ -f "$encoded_file" ]; then
                dest_file="/etc/nginx/$(basename "$encoded_file" .b64)"
                echo "デコード中: $(basename "$encoded_file") → $(basename "$dest_file")"
                base64 -d "$encoded_file" > "$dest_file"
              fi
            done &&
            
            # 通常のパラメータファイルが存在しない場合は、デフォルトファイルを作成する
            if [ ! -f "/etc/nginx/fastcgi_params" ]; then
              cat > /etc/nginx/fastcgi_params << EOF
fastcgi_param  QUERY_STRING       $query_string;
fastcgi_param  REQUEST_METHOD     $request_method;
fastcgi_param  CONTENT_TYPE       $content_type;
fastcgi_param  CONTENT_LENGTH     $content_length;
fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param  REQUEST_URI        $request_uri;
fastcgi_param  DOCUMENT_URI       $document_uri;
fastcgi_param  DOCUMENT_ROOT      $document_root;
fastcgi_param  SERVER_PROTOCOL    $server_protocol;
fastcgi_param  REQUEST_SCHEME     $scheme;
fastcgi_param  HTTPS              $https if_not_empty;
fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
fastcgi_param  REMOTE_ADDR        $remote_addr;
fastcgi_param  REMOTE_PORT        $remote_port;
fastcgi_param  SERVER_ADDR        $server_addr;
fastcgi_param  SERVER_PORT        $server_port;
fastcgi_param  SERVER_NAME        $server_name;
fastcgi_param  REDIRECT_STATUS    200;
EOF
            fi &&

            if [ ! -f "/etc/nginx/scgi_params" ]; then
              cat > /etc/nginx/scgi_params << EOF
scgi_param  REQUEST_METHOD     $request_method;
scgi_param  REQUEST_URI        $request_uri;
scgi_param  QUERY_STRING       $query_string;
scgi_param  CONTENT_TYPE       $content_type;
scgi_param  DOCUMENT_URI       $document_uri;
scgi_param  DOCUMENT_ROOT      $document_root;
scgi_param  SCGI               1;
scgi_param  SERVER_PROTOCOL    $server_protocol;
scgi_param  REQUEST_SCHEME     $scheme;
scgi_param  HTTPS              $https if_not_empty;
scgi_param  REMOTE_ADDR        $remote_addr;
scgi_param  REMOTE_PORT        $remote_port;
scgi_param  SERVER_PORT        $server_port;
scgi_param  SERVER_NAME        $server_name;
EOF
            fi &&

            if [ ! -f "/etc/nginx/uwsgi_params" ]; then
              cat > /etc/nginx/uwsgi_params << EOF
uwsgi_param  QUERY_STRING       $query_string;
uwsgi_param  REQUEST_METHOD     $request_method;
uwsgi_param  CONTENT_TYPE       $content_type;
uwsgi_param  CONTENT_LENGTH     $content_length;
uwsgi_param  REQUEST_URI        $request_uri;
uwsgi_param  PATH_INFO          $document_uri;
uwsgi_param  DOCUMENT_ROOT      $document_root;
uwsgi_param  SERVER_PROTOCOL    $server_protocol;
uwsgi_param  REQUEST_SCHEME     $scheme;
uwsgi_param  HTTPS              $https if_not_empty;
uwsgi_param  REMOTE_ADDR        $remote_addr;
uwsgi_param  REMOTE_PORT        $remote_port;
uwsgi_param  SERVER_PORT        $server_port;
uwsgi_param  SERVER_NAME        $server_name;
EOF
            fi &&

            if [ ! -f "/etc/nginx/conf.d/default.conf" ]; then 
               cat > /etc/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    
    location / {
        proxy_pass http://web:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /api {
        proxy_pass http://api:5001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
            fi && 
            # モジュールのコピー方法を修正
            if [ -d "/custom-nginx/modules" ]; then
              rm -f /etc/nginx/modules/* 2>/dev/null || true
              if [ -f "/etc/nginx/modules" ] && [ ! -d "/etc/nginx/modules" ]; then
                rm -f /etc/nginx/modules
                mkdir -p /etc/nginx/modules
              fi
              cp -f /custom-nginx/modules/* /etc/nginx/modules/ 2>/dev/null || echo "No modules to copy"
            fi &&
            # 他のファイルをコピー（modules以外）
            find /custom-nginx -maxdepth 1 -type f -not -name "*.b64" -exec cp -f {} /etc/nginx/ \; 2>/dev/null || echo "No root config files to copy" &&
            if [ -d "/custom-nginx/conf.d" ]; then
              cp -f /custom-nginx/conf.d/* /etc/nginx/conf.d/ 2>/dev/null || echo "No conf.d files to copy"
            fi &&
            nginx -g "daemon off;"
            '''
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
              mountPath: '/custom-squid'
            }
          ]
          command: [
            '/bin/bash'
            '-c'
            '''
            mkdir -p /etc/squid && mkdir -p /etc/squid/conf.d && 
            if [ ! -f "/custom-squid/squid.conf" ]; then 
              cat > /etc/squid/squid.conf << EOF
acl localnet src 0.0.0.1-0.255.255.255	# RFC 1122 "this" network (LAN)
acl localnet src 10.0.0.0/8		# RFC 1918 local private network (LAN)
acl localnet src 100.64.0.0/10		# RFC 6598 shared address space (CGN)
acl localnet src 169.254.0.0/16 	# RFC 3927 link-local (directly plugged) machines
acl localnet src 172.16.0.0/12		# RFC 1918 local private network (LAN)
acl localnet src 192.168.0.0/16		# RFC 1918 local private network (LAN)
acl localnet src fc00::/7       	# RFC 4193 local private network range
acl localnet src fe80::/10      	# RFC 4291 link-local (directly plugged) machines
acl SSL_ports port 443
acl Safe_ports port 80		# http
acl Safe_ports port 21		# ftp
acl Safe_ports port 443		# https
acl Safe_ports port 70		# gopher
acl Safe_ports port 210		# wais
acl Safe_ports port 1025-65535	# unregistered ports
acl Safe_ports port 280		# http-mgmt
acl Safe_ports port 488		# gss-http
acl Safe_ports port 591		# filemaker
acl Safe_ports port 777		# multiling http
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access allow localhost
include /etc/squid/conf.d/*.conf
http_access deny all
################################## Proxy Server ################################
http_port 3128
coredump_dir /var/spool/squid
refresh_pattern ^ftp:		1440	20%	10080
refresh_pattern ^gopher:	1440	0%	1440
refresh_pattern -i (/cgi-bin/|\?) 0	0%	0
refresh_pattern \/(Packages|Sources)(|\.bz2|\.gz|\.xz)$ 0 0% 0 refresh-ims
refresh_pattern \/Release(|\.gpg)$ 0 0% 0 refresh-ims
refresh_pattern \/InRelease$ 0 0% 0 refresh-ims
refresh_pattern \/(Translation-.*)(|\.bz2|\.gz|\.xz)$ 0 0% 0 refresh-ims
refresh_pattern .		0	20%	4320
################################## Reverse Proxy To Sandbox ################################
http_port 8194 accel vhost
cache_peer sandbox parent 8194 0 no-query originserver
acl src_all src all
http_access allow src_all
EOF
            else 
              cp -rf /custom-squid/* /etc/squid/ 2>/dev/null
            fi && 
            touch /etc/squid/conf.d/placeholder.conf && 
            squid -NYC
            '''
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
              value: '6380'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:6380/1'
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
              value: '6380'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:6380/1'
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
              value: '6380'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:6380/1'
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
