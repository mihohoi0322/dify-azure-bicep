# Azure CLI による Dify のデプロイ手順（PowerShell版）

このドキュメントでは、PowerShell環境でAzure CLI を使用して Dify アプリケーションをデプロイする手順を説明します。この手順は `deploy.sh` スクリプトが使用している Bicep テンプレートと同等の機能を提供します。

## 前提条件

- Azure CLI がインストールされていること (`az --version` で確認)
- PowerShell 5.1 以上または PowerShell Core 6.0 以上
- 有効な Azure サブスクリプション
- パラメータファイル（parameters.json）が存在すること
- ファイル共有にアップロードするための設定ファイルが「mountfiles」ディレクトリに存在すること

## デプロイの概要

このドキュメントに記載されているコマンドは、以下のリソースを作成します：

1. リソースグループ
2. 仮想ネットワークとサブネット（プライベートリンク、ACA、PostgreSQL用）
3. ストレージアカウントとプライベートエンドポイント
4. ファイル共有（Nginx、Sandbox、SSRFプロキシ、プラグイン用）
5. PostgreSQLフレキシブルサーバーとデータベース
6. Redis Cache（オプション）
7. Azure Container Apps環境
8. 各種コンテナアプリ（Nginx、SSRFプロキシ、Sandbox、API、Worker、Web）
9. 設定ファイルのアップロードと初期設定

## パラメータの読み込み

まず、parameters.json からパラメータを読み込みます。

```powershell
# parameters.jsonの内容を読み込み
$parametersJson = Get-Content -Path "./parameters.json" -Raw | ConvertFrom-Json

# パラメータの取得とデフォルト値の設定
$LOCATION = if ($parametersJson.parameters.location.value) { $parametersJson.parameters.location.value } else { "japaneast" }
$RESOURCE_GROUP_PREFIX = if ($parametersJson.parameters.resourceGroupPrefix.value) { $parametersJson.parameters.resourceGroupPrefix.value } else { "rg" }
$PGSQL_USER = if ($parametersJson.parameters.pgsqlUser.value) { $parametersJson.parameters.pgsqlUser.value } else { "user" }
$PGSQL_PASSWORD = if ($parametersJson.parameters.pgsqlPassword.value) { $parametersJson.parameters.pgsqlPassword.value } else { "#QWEASDasdqwe" }
$IS_PROVIDED_CERT = if ($parametersJson.parameters.isProvidedCert.value) { $parametersJson.parameters.isProvidedCert.value } else { $false }
$ACA_CERT_PASSWORD = if ($parametersJson.parameters.acaCertPassword.value) { $parametersJson.parameters.acaCertPassword.value } else { "password" }
$ACA_DIFY_CUSTOMER_DOMAIN = if ($parametersJson.parameters.acaDifyCustomerDomain.value) { $parametersJson.parameters.acaDifyCustomerDomain.value } else { "dify.example.com" }
$ACA_APP_MIN_COUNT = if ($parametersJson.parameters.acaAppMinCount.value) { $parametersJson.parameters.acaAppMinCount.value } else { 0 }
$IS_ACA_ENABLED = if ($parametersJson.parameters.isAcaEnabled.value) { $parametersJson.parameters.isAcaEnabled.value } else { $false }

# デフォルト値の設定
$STORAGE_ACCOUNT_BASE = "acadifytest"
$STORAGE_ACCOUNT_CONTAINER = "dfy"
$REDIS_NAME_BASE = "acadifyredis"
$PSQL_FLEXIBLE_BASE = "acadifypsql"
$ACA_ENV_NAME = "dify-aca-env"
$ACA_LOGA_NAME = "dify-loga"
$IP_PREFIX = "10.99"

$DIFY_API_IMAGE = "langgenius/dify-api:1.1.2"
$DIFY_SANDBOX_IMAGE = "langgenius/dify-sandbox:0.2.10"
$DIFY_WEB_IMAGE = "langgenius/dify-web:1.1.2"
$DIFY_PLUGIN_DAEMON_IMAGE = "langgenius/dify-plugin-daemon:0.0.6-local"

# リソースグループ名の設定
$RESOURCE_GROUP_NAME = "$RESOURCE_GROUP_PREFIX-$LOCATION"
```

## Azure へのログイン

```powershell
# Azure CLIのサインイン状態を確認
az account show --query "name" -o tsv
```

## 1. リソースグループの作成

```powershell
# リソースグループの作成
az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"
Write-Output "リソースグループ $RESOURCE_GROUP_NAME を作成しました"
```

## 2. 一意の識別子の生成

リソース名を一意に識別するために、サブスクリプション ID とリソースグループ名からハッシュを生成します。

```powershell
# サブスクリプションIDの取得
$SUBSCRIPTION_ID = az account show --query "id" -o tsv

# ハッシュ生成（PowerShellのGet-FileHashを使用）
$hashInput = "$SUBSCRIPTION_ID$RESOURCE_GROUP_NAME"
$hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
$hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($hashBytes)
$RG_NAME_HEX = ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 13).ToLower()

Write-Output "生成されたハッシュ: $RG_NAME_HEX"
```

## 3. 仮想ネットワークとサブネットの作成

```powershell
# 仮想ネットワークの作成
az network vnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "vnet-$LOCATION" `
  --address-prefix "${IP_PREFIX}.0.0/16" `
  --location "$LOCATION"

# プライベートリンク用サブネット作成
az network vnet subnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --vnet-name "vnet-$LOCATION" `
  --name "PrivateLinkSubnet" `
  --address-prefix "${IP_PREFIX}.0.0/24" `
  --disable-private-endpoint-network-policies true

# ACA用サブネット作成
az network vnet subnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --vnet-name "vnet-$LOCATION" `
  --name "ACASubnet" `
  --address-prefix "${IP_PREFIX}.2.0/23"
  --delegations "Microsoft.App/environments"

# PostgreSQL用サブネット作成
az network vnet subnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --vnet-name "vnet-$LOCATION" `
  --name "PostgresSubnet" `
  --address-prefix "${IP_PREFIX}.4.0/24" `
  --service-endpoints "Microsoft.Storage" `
  --delegations "Microsoft.DBforPostgreSQL/flexibleServers"

# サブネットIDの取得
$VNET_ID = az network vnet show --resource-group "$RESOURCE_GROUP_NAME" --name "vnet-$LOCATION" --query "id" -o tsv
$PRIVATE_LINK_SUBNET_ID = az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "vnet-$LOCATION" --name "PrivateLinkSubnet" --query "id" -o tsv
$ACA_SUBNET_ID = az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "vnet-$LOCATION" --name "ACASubnet" --query "id" -o tsv
$POSTGRES_SUBNET_ID = az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "vnet-$LOCATION" --name "PostgresSubnet" --query "id" -o tsv
```

## 4. ストレージアカウントとプライベートエンドポイントの作成

```powershell
# ストレージアカウント名の作成
$STORAGE_ACCOUNT_NAME = "${STORAGE_ACCOUNT_BASE}${RG_NAME_HEX}"

# ストレージアカウントの作成
az storage account create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$STORAGE_ACCOUNT_NAME" `
  --location "$LOCATION" `
  --sku "Standard_LRS" `
  --kind "StorageV2" `
  --enable-large-file-share `
  --enable-hierarchical-namespace false

# ストレージアカウントのマネージドIDを使用するための準備
# 注意：セキュリティベストプラクティスとして、アカウントキーの代わりにマネージドIDを使用することを推奨
$STORAGE_ACCOUNT_KEY = az storage account keys list --resource-group "$RESOURCE_GROUP_NAME" --account-name "$STORAGE_ACCOUNT_NAME" --query "[0].value" -o tsv

# Blob用プライベートDNSゾーンの作成
# 正しいsuffixを取得
$STORAGE_SUFFIX = az cloud show --query "suffixes.storageEndpoint" -o tsv
$STORAGE_SUFFIX = $STORAGE_SUFFIX -replace '^https://', ''
$STORAGE_SUFFIX = $STORAGE_SUFFIX -replace '/$', ''
$BLOB_DNS_ZONE = "privatelink.blob.${STORAGE_SUFFIX}"
$FILE_DNS_ZONE = "privatelink.file.${STORAGE_SUFFIX}"

az network private-dns zone create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$BLOB_DNS_ZONE"

# File用プライベートDNSゾーンの作成
az network private-dns zone create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$FILE_DNS_ZONE"

# Blob用プライベートDNSゾーンと仮想ネットワークのリンク
az network private-dns link vnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --zone-name "$BLOB_DNS_ZONE" `
  --name "blob-dns-link" `
  --virtual-network "$VNET_ID" `
  --registration-enabled false

# File用プライベートDNSゾーンと仮想ネットワークのリンク
az network private-dns link vnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --zone-name "$FILE_DNS_ZONE" `
  --name "file-dns-link" `
  --virtual-network "$VNET_ID" `
  --registration-enabled false

# ストレージコンテナの作成（プライベートエンドポイント作成後に実行）
az storage container create `
  --name "$STORAGE_ACCOUNT_CONTAINER" `
  --account-name "$STORAGE_ACCOUNT_NAME" `
  --account-key "$STORAGE_ACCOUNT_KEY"

# Blob用プライベートエンドポイント作成
$BLOB_PE_NAME = "pe-blob"
az network private-endpoint create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$BLOB_PE_NAME" `
  --location "$LOCATION" `
  --subnet "$PRIVATE_LINK_SUBNET_ID" `
  --private-connection-resource-id $(az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "id" -o tsv) `
  --group-id blob `
  --connection-name "psc-blob"

# File用プライベートエンドポイント作成
$FILE_PE_NAME = "pe-file"
az network private-endpoint create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$FILE_PE_NAME" `
  --location "$LOCATION" `
  --subnet "$PRIVATE_LINK_SUBNET_ID" `
  --private-connection-resource-id $(az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "id" -o tsv) `
  --group-id file `
  --connection-name "psc-file"

# Blob用プライベートDNSゾーングループの作成
az network private-endpoint dns-zone-group create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --endpoint-name "$BLOB_PE_NAME" `
  --name "pdz-blob" `
  --private-dns-zone "$BLOB_DNS_ZONE" `
  --zone-name "config1"

# File用プライベートDNSゾーングループの作成
az network private-endpoint dns-zone-group create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --endpoint-name "$FILE_PE_NAME" `
  --name "pdz-file" `
  --private-dns-zone "$FILE_DNS_ZONE" `
  --zone-name "config1"

# BlobエンドポイントのURL取得
$BLOB_ENDPOINT = az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "primaryEndpoints.blob" -o tsv
```

## 5. ファイル共有の作成

```powershell
# 接続文字列の取得
$CONNECTION_STRING = az storage account show-connection-string --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "connectionString" -o tsv

# ファイル共有作成関数の定義
function Create-FileShareIfNotExists {
    param(
        [string]$ShareName,
        [string]$ConnectionString
    )
    
    Write-Output "ファイル共有 '$ShareName' を作成中..."
    az storage share create --name "$ShareName" --connection-string "$ConnectionString"
    Write-Output "ファイル共有 '$ShareName' が作成されました"
}

# 各ファイル共有の作成
$NGINX_SHARE_NAME = "nginx"
$SANDBOX_SHARE_NAME = "sandbox"
$SSRFPROXY_SHARE_NAME = "ssrfproxy"
$PLUGIN_STORAGE_SHARE_NAME = "pluginstorage"

Create-FileShareIfNotExists -ShareName $NGINX_SHARE_NAME -ConnectionString $CONNECTION_STRING
Create-FileShareIfNotExists -ShareName $SANDBOX_SHARE_NAME -ConnectionString $CONNECTION_STRING
Create-FileShareIfNotExists -ShareName $SSRFPROXY_SHARE_NAME -ConnectionString $CONNECTION_STRING
Create-FileShareIfNotExists -ShareName $PLUGIN_STORAGE_SHARE_NAME -ConnectionString $CONNECTION_STRING
```

## 6. PostgreSQLフレキシブルサーバーの作成

```powershell
# PostgreSQLサーバー名の設定
$PSQL_SERVER_NAME = "${PSQL_FLEXIBLE_BASE}${RG_NAME_HEX}"

# プライベートDNSゾーンの作成
az network private-dns zone create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "privatelink.postgres.database.azure.com"

# 仮想ネットワークとのリンク作成
az network private-dns link vnet create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --zone-name "privatelink.postgres.database.azure.com" `
  --name "postgres-dns-link" `
  --virtual-network "$VNET_ID" `
  --registration-enabled false

# PostgreSQLフレキシブルサーバーの作成
az postgres flexible-server create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$PSQL_SERVER_NAME" `
  --location "$LOCATION" `
  --admin-user "$PGSQL_USER" `
  --admin-password "$PGSQL_PASSWORD" `
  --sku-name "Standard_B1ms" `
  --tier "Burstable" `
  --version "14" `
  --storage-size 32 `
  --subnet "$POSTGRES_SUBNET_ID" `
  --private-dns-zone "privatelink.postgres.database.azure.com" `
  --high-availability Disabled

# Difyデータベースの作成
az postgres flexible-server db create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --server-name "$PSQL_SERVER_NAME" `
  --database-name "dify" `
  --charset "UTF8" `
  --collation "en_US.utf8"

# Vectorデータベースの作成
az postgres flexible-server db create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --server-name "$PSQL_SERVER_NAME" `
  --database-name "vector" `
  --charset "UTF8" `
  --collation "en_US.utf8"

# PostgreSQLサーバーのFQDNを取得
$POSTGRES_SERVER_FQDN = az postgres flexible-server show --resource-group "$RESOURCE_GROUP_NAME" --name "$PSQL_SERVER_NAME" --query "fullyQualifiedDomainName" -o tsv
```

## 7. Redisキャッシュの作成

```powershell
# Redis関連変数の初期化
$REDIS_HOST_NAME = ""
$REDIS_PRIMARY_KEY = ""

# ACA有効時のみRedisを作成
if ($IS_ACA_ENABLED -eq $true) {
    # Redis名の設定
    $REDIS_NAME = "$REDIS_NAME_BASE$RG_NAME_HEX"
    
    # プライベートDNSゾーンの作成
    az network private-dns zone create `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --name "privatelink.redis.cache.windows.net"
    
    # 仮想ネットワークとのリンク作成
    az network private-dns link vnet create `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --zone-name "privatelink.redis.cache.windows.net" `
      --name "redis-dns-link" `
      --virtual-network "$VNET_ID" `
      --registration-enabled false
    
    # Redisキャッシュの作成
    az redis create `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --name "$REDIS_NAME" `
      --location "$LOCATION" `
      --sku "Standard" `
      --vm-size "C0" `
      --enable-non-ssl-port `
      --minimum-tls-version "1.2" `
      --redis-version "6"
    
    # RedisリソースIDの取得
    $REDIS_RESOURCE_ID = az redis show --resource-group "$RESOURCE_GROUP_NAME" --name "$REDIS_NAME" --query "id" -o tsv
    
    # Redisプライベートエンドポイントの作成
    $REDIS_PE_NAME = "pe-redis"
    az network private-endpoint create `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --name "$REDIS_PE_NAME" `
      --location "$LOCATION" `
      --subnet "$PRIVATE_LINK_SUBNET_ID" `
      --private-connection-resource-id "$REDIS_RESOURCE_ID" `
      --group-id "redisCache" `
      --connection-name "psc-redis"
    
    # RedisプライベートDNSゾーングループの作成
    az network private-endpoint dns-zone-group create `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --endpoint-name "$REDIS_PE_NAME" `
      --name "pdz-stor" `
      --private-dns-zone "privatelink.redis.cache.windows.net" `
      --zone-name "config1"
    
    # Redis情報の取得
    $REDIS_HOST_NAME = az redis show --resource-group "$RESOURCE_GROUP_NAME" --name "$REDIS_NAME" --query "hostName" -o tsv
    $REDIS_PRIMARY_KEY = az redis list-keys --resource-group "$RESOURCE_GROUP_NAME" --name "$REDIS_NAME" --query "primaryKey" -o tsv
}
```

## 8. ACE環境の作成

```powershell
# Log Analytics workspaceの作成
az monitor log-analytics workspace create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --workspace-name "$ACA_LOGA_NAME" `
  --location "$LOCATION"

$LOG_ANALYTICS_WORKSPACE_CLIENT_ID = az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$ACA_LOGA_NAME" --query "customerId" -o tsv
$LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET = az monitor log-analytics workspace get-shared-keys --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$ACA_LOGA_NAME" --query "primarySharedKey" -o tsv

# Container Apps環境の作成
az containerapp env create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_NAME" `
  --location "$LOCATION" `
  --logs-destination "log-analytics" `
  --logs-workspace-id "$LOG_ANALYTICS_WORKSPACE_CLIENT_ID" `
  --logs-workspace-key "$LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET" `
  --infrastructure-subnet-resource-id "$ACA_SUBNET_ID"

# ストレージのマウント
az containerapp env storage set `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_NAME" `
  --storage-name "nginxshare" `
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" `
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" `
  --azure-file-share-name "$NGINX_SHARE_NAME" `
  --access-mode "ReadWrite"

az containerapp env storage set `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_NAME" `
  --storage-name "ssrfproxyshare" `
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" `
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" `
  --azure-file-share-name "$SSRFPROXY_SHARE_NAME" `
  --access-mode "ReadWrite"

az containerapp env storage set `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_NAME" `
  --storage-name "sandboxshare" `
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" `
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" `
  --azure-file-share-name "$SANDBOX_SHARE_NAME" `
  --access-mode "ReadWrite"

az containerapp env storage set `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_NAME" `
  --storage-name "pluginstorageshare" `
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" `
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" `
  --azure-file-share-name "$PLUGIN_STORAGE_SHARE_NAME" `
  --access-mode "ReadWrite"

# 証明書の追加（条件付き）
if ($IS_PROVIDED_CERT -eq $true) {
  az containerapp env certificate set `
    --resource-group "$RESOURCE_GROUP_NAME" `
    --environment "$ACA_ENV_NAME" `
    --name "difycerts" `
    --password "$ACA_CERT_PASSWORD" `
    --value "$ACA_CERT_BASE64_VALUE"
}
```

## 9. Nginxコンテナアプリケーションのデプロイ

```powershell
# nginx起動コマンドの定義
$NGINX_COMMAND = @"
mkdir -p /etc/nginx/conf.d /etc/nginx/modules && 
for encoded_file in /custom-nginx/*.b64; do
  if [ -f \"$encoded_file\" ]; then
    dest_file=\"/etc/nginx/$(basename \"$encoded_file\" .b64)\"
    echo \"デコード中: $(basename \"$encoded_file\") → $(basename \"$dest_file\")\"
    base64 -d \"$encoded_file\" > \"$dest_file\"
  fi
done &&

if [ ! -f \"/etc/nginx/fastcgi_params\" ]; then
  cat > /etc/nginx/fastcgi_params << EOF
fastcgi_param  QUERY_STRING       \$query_string;
fastcgi_param  REQUEST_METHOD     \$request_method;
fastcgi_param  CONTENT_TYPE       \$content_type;
fastcgi_param  CONTENT_LENGTH     \$content_length;
fastcgi_param  SCRIPT_NAME        \$fastcgi_script_name;
fastcgi_param  REQUEST_URI        \$request_uri;
fastcgi_param  DOCUMENT_URI       \$document_uri;
fastcgi_param  DOCUMENT_ROOT      \$document_root;
fastcgi_param  SERVER_PROTOCOL    \$server_protocol;
fastcgi_param  REQUEST_SCHEME     \$scheme;
fastcgi_param  HTTPS              \$https if_not_empty;
fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/\$nginx_version;
fastcgi_param  REMOTE_ADDR        \$remote_addr;
fastcgi_param  REMOTE_PORT        \$remote_port;
fastcgi_param  SERVER_ADDR        \$server_addr;
fastcgi_param  SERVER_PORT        \$server_port;
fastcgi_param  SERVER_NAME        \$server_name;
fastcgi_param  REDIRECT_STATUS    200;
EOF
fi &&

if [ ! -f \"/etc/nginx/scgi_params\" ]; then
  cat > /etc/nginx/scgi_params << EOF
scgi_param  REQUEST_METHOD     \$request_method;
scgi_param  REQUEST_URI        \$request_uri;
scgi_param  QUERY_STRING       \$query_string;
scgi_param  CONTENT_TYPE       \$content_type;
scgi_param  DOCUMENT_URI       \$document_uri;
scgi_param  DOCUMENT_ROOT      \$document_root;
scgi_param  SCGI               1;
scgi_param  SERVER_PROTOCOL    \$server_protocol;
scgi_param  REQUEST_SCHEME     \$scheme;
scgi_param  HTTPS              \$https if_not_empty;
scgi_param  REMOTE_ADDR        \$remote_addr;
scgi_param  REMOTE_PORT        \$remote_port;
scgi_param  SERVER_PORT        \$server_port;
scgi_param  SERVER_NAME        \$server_name;
EOF
fi &&

if [ ! -f \"/etc/nginx/uwsgi_params\" ]; then
  cat > /etc/nginx/uwsgi_params << EOF
uwsgi_param  QUERY_STRING       \$query_string;
uwsgi_param  REQUEST_METHOD     \$request_method;
uwsgi_param  CONTENT_TYPE       \$content_type;
uwsgi_param  CONTENT_LENGTH     \$content_length;
uwsgi_param  REQUEST_URI        \$request_uri;
uwsgi_param  PATH_INFO          \$document_uri;
uwsgi_param  DOCUMENT_ROOT      \$document_root;
uwsgi_param  SERVER_PROTOCOL    \$server_protocol;
uwsgi_param  REQUEST_SCHEME     \$scheme;
uwsgi_param  HTTPS              \$https if_not_empty;
uwsgi_param  REMOTE_ADDR        \$remote_addr;
uwsgi_param  REMOTE_PORT        \$remote_port;
uwsgi_param  SERVER_PORT        \$server_port;
uwsgi_param  SERVER_NAME        \$server_name;
EOF
fi &&

# 通常の設定ファイルをコピー
for conf_file in /custom-nginx/*.conf; do
  if [ -f \"\$conf_file\" ]; then
    cp \"\$conf_file\" /etc/nginx/
  fi
done &&

for file in /custom-nginx/conf.d/*.conf; do
  if [ -f \"\$file\" ]; then
    cp \"\$file\" /etc/nginx/conf.d/
  fi
done &&

# mime.typesをコピー
if [ -f \"/custom-nginx/mime.types\" ]; then
  cp \"/custom-nginx/mime.types\" /etc/nginx/mime.types
fi &&

# modulesをコピー
if [ -d \"/custom-nginx/modules\" ] && [ \"$(ls -A /custom-nginx/modules)\" ]; then
  cp /custom-nginx/modules/* /etc/nginx/modules/ 2>/dev/null || true
fi &&

echo \"設定が完了しました。Nginxを起動します...\" &&
nginx -g \"daemon off;\"
"@

# nginxアプリケーションの作成
az containerapp create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "nginx" `
  --environment "$ACA_ENV_NAME" `
  --image "nginx:latest" `
  --ingress "external" `
  --target-port 80 `
  --transport "auto" `
  --min-replicas "$ACA_APP_MIN_COUNT" `
  --max-replicas 10 `
  --cpu "0.5" `
  --memory "1Gi" `
  --command "/bin/bash -c" `
  --arg $NGINX_COMMAND

# 1. 基本設定ファイルを作成（ストレージマウント設定を含む）
@'
properties:
  configuration:
    ingress:
      external: true
      targetPort: 80
      transport: auto
    secrets:
      - name: "storage-key"
        value: "<placeholder for $STORAGE_ACCOUNT_KEY>"
  template:
    containers:
      - name: nginx
        image: nginx:latest
        command:
          - /bin/bash
        args:
          - -c
          - |
            mkdir -p /etc/nginx/conf.d /etc/nginx/modules
            
            # Base64エンコードされたファイルをデコード
            for encoded_file in /custom-nginx/*.b64; do
              if [ -f "$encoded_file" ]; then
                dest_file="/etc/nginx/$(basename "$encoded_file" .b64)"
                echo "デコード中: $(basename "$encoded_file") → $(basename "$dest_file")"
                base64 -d "$encoded_file" > "$dest_file"
              fi
            done
            
            # デフォルトのパラメータファイルを作成（存在しない場合）
            if [ ! -f "/etc/nginx/fastcgi_params" ]; then
              cat > /etc/nginx/fastcgi_params << 'INNER_EOF'
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
            INNER_EOF
            fi
            
            # 設定ファイルをコピー
            for conf_file in /custom-nginx/*.conf; do
              if [ -f "$conf_file" ]; then
                cp "$conf_file" /etc/nginx/
              fi
            done
            
            for file in /custom-nginx/conf.d/*.conf; do
              if [ -f "$file" ]; then
                cp "$file" /etc/nginx/conf.d/
              fi
            done
            
            # mime.typesをコピー
            if [ -f "/custom-nginx/mime.types" ]; then
              cp "/custom-nginx/mime.types" /etc/nginx/mime.types
            fi
            
            # modulesをコピー
            if [ -d "/custom-nginx/modules" ] && [ "$(ls -A /custom-nginx/modules)" ]; then
              cp /custom-nginx/modules/* /etc/nginx/modules/ 2>/dev/null || true
            fi
            
            echo "設定が完了しました。Nginxを起動します..."
            nginx -g "daemon off;"
        volumeMounts:
          - volumeName: nginxshare
            mountPath: /custom-nginx
        resources:
          cpu: 0.5
          memory: 1Gi
    scale:
      minReplicas: 1
      maxReplicas: 10
    volumes:
      - name: nginxshare
        storageName: nginxshare
        storageType: AzureFile
'@ | Set-Content -Encoding String nginx-config.yaml

# 2. 基本設定ファイルを使用してコンテナアプリを更新
az containerapp update `
  --name "nginx" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --yaml nginx-config.yaml

# 3. ストレージアカウントキーをシークレットとして設定
az containerapp secret set `
  --name "nginx" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --secrets `
    "storage-key=$STORAGE_ACCOUNT_KEY"
```

## 10. SSRFプロキシコンテナアプリケーションのデプロイ

```powershell
# SSRFプロキシの起動コマンド
$SSRF_PROXY_COMMAND = @'
"if [ -f \"/etc/squid/squid.conf\" ]; then
  echo 'Using custom squid.conf'
  cp /etc/squid/squid.conf /etc/squid/squid.conf.default
fi &&
if [ -f \"/etc/squid/errorpage.css\" ]; then
  echo 'Using custom errorpage.css'
  mkdir -p /usr/share/squid/
  cp /etc/squid/errorpage.css /usr/share/squid/errorpage.css
fi &&
if [ -d \"/etc/squid/conf.d\" ] && [ \"$(ls -A /etc/squid/conf.d)\" ]; then
  echo 'Found custom conf.d files'
  mkdir -p /etc/squid/conf.d
  cp /etc/squid/conf.d/* /etc/squid/conf.d/
fi &&
echo 'Starting squid...' &&
squid -NYC"
'@

# SSRFプロキシアプリケーションの作成
az containerapp create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "ssrfproxy" `
  --environment "$ACA_ENV_NAME" `
  --image "ubuntu/squid:latest" `
  --ingress "internal" `
  --target-port 3128 `
  --transport "tcp" `
  --min-replicas "$ACA_APP_MIN_COUNT" `
  --max-replicas 10 `
  --cpu "0.5" `
  --memory "1Gi" `
  --command "/bin/bash -c" `
  --arg "$SSRF_PROXY_COMMAND"

# ストレージマウントを含むSSRFプロキシアプリケーションの更新
# YAMLを使用してストレージマウントを設定
# 1. YAML定義ファイルを作成
@'
properties:
  configuration:
    ingress:
      external: false
      targetPort: 3128
      transport: tcp
  template:
    volumes:
      - name: "ssrfproxyshare"
        storageName: "ssrfproxyshare"
        storageType: "AzureFile"
        mountPath: "/etc/squid"
'@ | Set-Content -Encoding String ssrfproxy-update.yaml

# 2. YAMLファイルを使用してコンテナアプリを更新
az containerapp update `
  --name "ssrfproxy" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --yaml ssrfproxy-update.yaml
```

## 11. Sandboxコンテナアプリケーションのデプロイ

```powershell
# Sandboxアプリケーションの作成
az containerapp create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "sandbox" `
  --environment "$ACA_ENV_NAME" `
  --image "$DIFY_SANDBOX_IMAGE" `
  --ingress "internal" `
  --target-port 8194 `
  --transport "tcp" `
  --min-replicas "$ACA_APP_MIN_COUNT" `
  --max-replicas 10 `
  --cpu "2" `
  --memory "4Gi" `
  --env-vars `
    "LOG_LEVEL=INFO" `
    "ENABLE_NETWORK=true" `
    "HTTP_PROXY=http://ssrfproxy:3128" `
    "HTTPS_PROXY=http://ssrfproxy:3128" `
    "SANDBOX_PORT=8194" `
  --scale-rule-name "sandbox" `
  --scale-rule-type "tcp" `
  --scale-rule-metadata "concurrentRequests=10"

# ストレージマウントを含むSandboxアプリケーションの更新
# YAMLを使用してストレージマウントを設定
# 1. YAML定義ファイルを作成
@'
properties:
  configuration:
    ingress:
      external: false
      targetPort: 8194
      transport: tcp
  template:
    volumes:
      - name: "sandboxshare"
        storageName: "sandboxshare"
        storageType: "AzureFile"
        mountPath: "/data"
'@ | Set-Content -Encoding String sandbox-update.yaml

# 2. YAMLファイルを使用してコンテナアプリを更新
az containerapp update `
  --name "sandbox" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --yaml sandbox-update.yaml
```

## 12. Workerコンテナアプリケーションのデプロイ

```powershell
# CeleryブローカーURLの設定
$CELERY_BROKER_URL = if ($REDIS_HOST_NAME) { "rediss://:$REDIS_PRIMARY_KEY@${REDIS_HOST_NAME}:6380/1" } else { "" }

# Workerアプリケーションの作成
az containerapp create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "worker" `
  --environment "$ACA_ENV_NAME" `
  --image "$DIFY_API_IMAGE" `
  --min-replicas "$ACA_APP_MIN_COUNT" `
  --max-replicas 10 `
  --cpu "2" `
  --memory "4Gi" `
  --env-vars `
    "MODE=worker" `
    "LOG_LEVEL=INFO" `
    "SECRET_KEY=sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U" `
    "DB_USERNAME=$PGSQL_USER" `
    "DB_PASSWORD=$PGSQL_PASSWORD" `
    "DB_HOST=$POSTGRES_SERVER_FQDN" `
    "DB_PORT=5432" `
    "DB_DATABASE=dify" `
    "REDIS_HOST=$REDIS_HOST_NAME" `
    "REDIS_PORT=6380" `
    "REDIS_PASSWORD=$REDIS_PRIMARY_KEY" `
    "REDIS_USE_SSL=true" `
    "REDIS_DB=0" `
    "CELERY_BROKER_URL=$CELERY_BROKER_URL" `
    "STORAGE_TYPE=azure-blob" `
    "AZURE_BLOB_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME" `
    "AZURE_BLOB_ACCOUNT_KEY=$STORAGE_ACCOUNT_KEY" `
    "AZURE_BLOB_ACCOUNT_URL=$BLOB_ENDPOINT" `
    "AZURE_BLOB_CONTAINER_NAME=$STORAGE_ACCOUNT_CONTAINER" `
    "VECTOR_STORE=pgvector" `
    "PGVECTOR_HOST=$POSTGRES_SERVER_FQDN" `
    "PGVECTOR_PORT=5432" `
    "PGVECTOR_USER=$PGSQL_USER" `
    "PGVECTOR_PASSWORD=$PGSQL_PASSWORD" `
    "PGVECTOR_DATABASE=vector" `
    "INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH=1000"
```

## 13. APIコンテナアプリケーションのデプロイ

```powershell
# APIアプリケーションの作成
az containerapp create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "api" `
  --environment "$ACA_ENV_NAME" `
  --image "$DIFY_API_IMAGE" `
  --ingress "internal" `
  --target-port 5001 `
  --exposed-port 5001 `
  --transport "tcp" `
  --min-replicas "$ACA_APP_MIN_COUNT" `
  --max-replicas 10 `
  --cpu "2" `
  --memory "4Gi" `
  --env-vars `
    "MODE=api" `
    "LOG_LEVEL=INFO" `
    "API_SERVER_HOST=0.0.0.0" `
    "API_SERVER_PORT=5001" `
    "SECRET_KEY=sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U" `
    "DB_USERNAME=$PGSQL_USER" `
    "DB_PASSWORD=$PGSQL_PASSWORD" `
    "DB_HOST=$POSTGRES_SERVER_FQDN" `
    "DB_PORT=5432" `
    "DB_DATABASE=dify" `
    "REDIS_HOST=$REDIS_HOST_NAME" `
    "REDIS_PORT=6380" `
    "REDIS_PASSWORD=$REDIS_PRIMARY_KEY" `
    "REDIS_USE_SSL=true" `
    "REDIS_DB=0" `
    "CELERY_BROKER_URL=$CELERY_BROKER_URL" `
    "STORAGE_TYPE=azure-blob" `
    "AZURE_BLOB_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME" `
    "AZURE_BLOB_ACCOUNT_KEY=$STORAGE_ACCOUNT_KEY" `
    "AZURE_BLOB_ACCOUNT_URL=$BLOB_ENDPOINT" `
    "AZURE_BLOB_CONTAINER_NAME=$STORAGE_ACCOUNT_CONTAINER" `
    "VECTOR_STORE=pgvector" `
    "PGVECTOR_HOST=$POSTGRES_SERVER_FQDN" `
    "PGVECTOR_PORT=5432" `
    "PGVECTOR_USER=$PGSQL_USER" `
    "PGVECTOR_PASSWORD=$PGSQL_PASSWORD" `
    "PGVECTOR_DATABASE=vector" `
    "PLUGIN_WEBHOOK_ENABLED=true" `
    "PLUGIN_REMOTE_INSTALLING_ENABLED=true" `
    "PLUGIN_REMOTE_INSTALLING_HOST=127.0.0.1" `
    "PLUGIN_REMOTE_INSTALLING_PORT=5003"

# API用YAML設定ファイルの作成
$apiConfigYaml = @"
properties:
  configuration:
    ingress:
      external: false
      targetPort: 5001
      transport: tcp
  template:
    containers:
      - name: api
        image: $DIFY_API_IMAGE
        volumeMounts:
          - volumeName: pluginstorageshare
            mountPath: /app/plugins
        resources:
          cpu: 2
          memory: 4Gi
    scale:
      minReplicas: $ACA_APP_MIN_COUNT
      maxReplicas: 10
    volumes:
      - name: pluginstorageshare
        storageName: pluginstorageshare
        storageType: AzureFile
"@

# YAML設定をファイルに出力
$apiConfigYaml | Out-File -FilePath "api-update.yaml" -Encoding String

# YAMLファイルを使用してコンテナアプリを更新
az containerapp update `
  --name "api" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --yaml "api-update.yaml"
```

## 14. Webコンテナアプリケーションのデプロイ

```powershell
# Webアプリケーションの作成
az containerapp create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "web" `
  --environment "$ACA_ENV_NAME" `
  --image "$DIFY_WEB_IMAGE" `
  --ingress "internal" `
  --target-port 3000 `
  --transport "auto" `
  --min-replicas "$ACA_APP_MIN_COUNT" `
  --max-replicas 10 `
  --cpu "1" `
  --memory "2Gi" `
  --env-vars `
    "CONSOLE_API_URL=http://api:5001" `
    "CONSOLE_API_PREFIX=/console/api" `
    "SERVICE_API_PREFIX=/api"

# カスタムドメインの設定（条件付き）
if ($IS_PROVIDED_CERT -eq $true) {
    az containerapp hostname add `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --name "nginx" `
      --hostname "$ACA_DIFY_CUSTOMER_DOMAIN"
    
    az containerapp hostname bind `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --name "nginx" `
      --hostname "$ACA_DIFY_CUSTOMER_DOMAIN" `
      --environment "$ACA_ENV_NAME" `
      --certificate "difycerts"
}
```

## 15. デプロイ後の設定

```powershell
# ストレージアカウントの監査ログを有効化
az storage account update `
  --name "$STORAGE_ACCOUNT_NAME" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --enable-local-user true

# クライアントIPを取得してファイアウォールに追加
try {
    $CLIENT_IP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
    Write-Output "現在のIPアドレス: $CLIENT_IP をストレージアカウントのファイアウォールに追加します"
    
    az storage account network-rule add `
      --account-name "$STORAGE_ACCOUNT_NAME" `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --ip-address "$CLIENT_IP"
    
    # PostgreSQLサーバーのファイアウォールにクライアントIPを追加
    az postgres flexible-server firewall-rule create `
      -- "ClientIPAccess" `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --name "$PSQL_SERVER_NAME" `
      --start-ip-address "$CLIENT_IP" `
      --end-ip-address "$CLIENT_IP"
} catch {
    Write-Warning "クライアントIPの取得に失敗しました: $($_.Exception.Message)"
}

# PostgreSQLサーバーのパラメータを設定
az postgres flexible-server parameter set `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --server-name "$PSQL_SERVER_NAME" `
  --name "azure.extensions" `
  --value "uuid-ossp"

# アプリケーションの再起動
$AppNames = @("nginx", "ssrfproxy", "sandbox", "worker", "api", "web")
foreach ($AppName in $AppNames) {
    az containerapp update `
      --name "$AppName" `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --set "properties.template.scale.minReplicas=1"
}

# デプロイされたアプリケーションのURLを取得
$DIFY_URL = az containerapp show --name "nginx" --resource-group "$RESOURCE_GROUP_NAME" --query "properties.configuration.ingress.fqdn" -o tsv
Write-Output "==============================================="
Write-Output "Difyアプリケーションは次のURLでアクセスできます："
Write-Output "https://$DIFY_URL"
Write-Output "==============================================="
```

## 16. 設定ファイルのアップロード

```powershell
# 一時ディレクトリを作成
$TEMP_DIR = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }

try {
    # Nginxの設定ファイルをアップロード
    Write-Output "Nginxの設定ファイルをアップロード中..."
    
    $nginxFiles = @("mountfiles/nginx/*.conf", "mountfiles/nginx/mime.types")
    foreach ($pattern in $nginxFiles) {
        $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $filename = $file.Name
            Write-Output "ファイルをアップロード: $filename"
            
            # 改行コードを修正（CRLF → LF）
            $content = Get-Content -Path $file.FullName -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $filename
            [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
            
            # 修正したファイルをアップロード
            az storage file upload --source "$tempFile" --share-name "$NGINX_SHARE_NAME" `
              --path "$filename" --connection-string "$CONNECTION_STRING"
        }
    }
    
    # 特殊パラメータファイルをチェックして処理
    $paramFiles = @("fastcgi_params", "scgi_params", "uwsgi_params")
    foreach ($paramFile in $paramFiles) {
        $fullPath = "mountfiles/nginx/$paramFile"
        
        if (Test-Path $fullPath) {
            Write-Output "特殊ファイルをアップロード: $paramFile"
            
            # 改行コードを修正
            $content = Get-Content -Path $fullPath -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $paramFile
            [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
            
            # base64エンコード
            $bytes = [System.IO.File]::ReadAllBytes($tempFile)
            $base64Content = [System.Convert]::ToBase64String($bytes)
            $base64File = "$tempFile.b64"
            [System.IO.File]::WriteAllText($base64File, $base64Content, [System.Text.Encoding]::UTF8)
            
            # エンコードしたファイルをアップロード
            az storage file upload --source "$base64File" --share-name "$NGINX_SHARE_NAME" `
              --path "$paramFile.b64" --connection-string "$CONNECTION_STRING"
        }
    }
    
    # conf.dディレクトリのファイルをアップロード
    Write-Output "conf.dディレクトリのファイルをアップロード中..."
    if (Test-Path "mountfiles/nginx/conf.d") {
        # conf.dディレクトリを作成
        az storage directory create --name "conf.d" --share-name "$NGINX_SHARE_NAME" `
          --connection-string "$CONNECTION_STRING"
        
        $confDFiles = Get-ChildItem -Path "mountfiles/nginx/conf.d/*" -File -ErrorAction SilentlyContinue
        foreach ($file in $confDFiles) {
            $filename = $file.Name
            Write-Output "ファイルをアップロード: conf.d/$filename"
            
            # 改行コードを修正
            $content = Get-Content -Path $file.FullName -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $filename
            [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
            
            az storage file upload --source "$tempFile" --share-name "$NGINX_SHARE_NAME" `
              --path "conf.d/$filename" --connection-string "$CONNECTION_STRING"
        }
    }
    
    # modulesディレクトリのファイルをアップロード
    Write-Output "modulesディレクトリのファイルをアップロード中..."
    if (Test-Path "mountfiles/nginx/modules") {
        # modulesディレクトリを作成
        az storage directory create --name "modules" --share-name "$NGINX_SHARE_NAME" `
          --connection-string "$CONNECTION_STRING"
        
        $moduleFiles = Get-ChildItem -Path "mountfiles/nginx/modules/*" -File -ErrorAction SilentlyContinue
        foreach ($file in $moduleFiles) {
            $filename = $file.Name
            Write-Output "ファイルをアップロード: modules/$filename"
            az storage file upload --source $file.FullName --share-name "$NGINX_SHARE_NAME" `
              --path "modules/$filename" --connection-string "$CONNECTION_STRING"
        }
    }
    
    # SSRFプロキシの設定ファイルをアップロード
    Write-Output "SSRFプロキシの設定ファイルをアップロード中..."
    # conf.dディレクトリを作成
    az storage directory create --name "conf.d" --share-name "$SSRFPROXY_SHARE_NAME" `
      --connection-string "$CONNECTION_STRING"
    
    $ssrfProxyFiles = @("mountfiles/ssrfproxy/squid.conf", "mountfiles/ssrfproxy/errorpage.css")
    foreach ($filePath in $ssrfProxyFiles) {
        if (Test-Path $filePath) {
            $filename = Split-Path $filePath -Leaf
            Write-Output "ファイルをアップロード: $filename"
            
            # 改行コードを修正
            $content = Get-Content -Path $filePath -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $filename
            [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
            
            az storage file upload --source "$tempFile" --share-name "$SSRFPROXY_SHARE_NAME" `
              --path "$filename" --connection-string "$CONNECTION_STRING"
        }
    }
    
    # SSRFプロキシのconf.dディレクトリのファイルをアップロード
    if (Test-Path "mountfiles/ssrfproxy/conf.d") {
        $ssrfConfDFiles = Get-ChildItem -Path "mountfiles/ssrfproxy/conf.d/*" -File -ErrorAction SilentlyContinue
        foreach ($file in $ssrfConfDFiles) {
            $filename = $file.Name
            Write-Output "ファイルをアップロード: conf.d/$filename"
            
            # 改行コードを修正
            $content = Get-Content -Path $file.FullName -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $filename
            [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
            
            az storage file upload --source "$tempFile" --share-name "$SSRFPROXY_SHARE_NAME" `
              --path "conf.d/$filename" --connection-string "$CONNECTION_STRING"
        }
    }
    
    # Sandbox用の設定ファイルをアップロード
    Write-Output "Sandboxの設定ファイルをアップロード中..."
    if (Test-Path "mountfiles/sandbox/python-requirements.txt") {
        # 改行コードを修正
        $content = Get-Content -Path "mountfiles/sandbox/python-requirements.txt" -Raw
        $content = $content -replace "`r`n", "`n"
        $tempFile = Join-Path $TEMP_DIR.FullName "python-requirements.txt"
        [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
        
        az storage file upload --source "$tempFile" --share-name "$SANDBOX_SHARE_NAME" `
          --path "python-requirements.txt" --connection-string "$CONNECTION_STRING"
    }
    
} finally {
    # 一時ディレクトリをクリーンアップ
    Remove-Item -Path $TEMP_DIR.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
```

## 17. データベース拡張機能のセットアップ（PostgreSQL psqlツールが必要）

```powershell
# PostgreSQLクライアントツールが必要です
# 環境変数を設定してpsqlコマンドを実行
$env:PGPASSWORD = $PGSQL_PASSWORD

# PostgreSQLデータベースのベクター拡張機能を有効化
psql -h "$POSTGRES_SERVER_FQDN" -U "$PGSQL_USER" -d "vector" -c "CREATE EXTENSION IF NOT EXISTS vector;"

# uuid-ossp拡張機能の有効化
psql -h "$POSTGRES_SERVER_FQDN" -U "$PGSQL_USER" -d "dify" -c "CREATE EXTENSION IF NOT EXISTS `"uuid-ossp`";"
psql -h "$POSTGRES_SERVER_FQDN" -U "$PGSQL_USER" -d "vector" -c "CREATE EXTENSION IF NOT EXISTS `"uuid-ossp`";"

# 環境変数をクリア
Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue
```

## **重要なセキュリティ注意事項**

⚠️ **本ドキュメントのコマンドを実行する前に以下のセキュリティ事項を必ずお読みください:**

1. **パスワードとシークレットの管理**:
   - `parameters.json`にパスワードを平文で記載することは本番環境では推奨されません
   - Azure Key Vaultを使用してシークレットを管理することを強く推奨します
   - コマンド履歴にパスワードが残らないよう注意してください

2. **Managed Identity の使用推奨**:
   - ストレージアカウントキーの代わりにManaged Identityの使用を推奨します
   - 本ドキュメントでは簡略化のためアカウントキーを使用していますが、実際の運用ではManaged Identityを設定してください

3. **ネットワークセキュリティ**:
   - プライベートエンドポイントを使用していますが、必要に応じてNetwork Security Groups (NSG)を追加で設定してください
   - ファイアウォール設定は最小権限の原則に従って設定してください

4. **監査とログ**:
   - 本番環境では必ず監査ログとアクティビティログを有効にしてください
   - Azure Monitor での監視設定を行ってください

## 注意事項

1. このドキュメントは、Bicepテンプレートを使用する代わりにAzure CLIコマンドでリソースを作成します。
2. パラメータファイル（parameters.json）から値を読み込みます。
3. 実際に実行する際は、必要に応じてパラメータやリソースのスペックを調整してください。
4. 認証情報（パスワードなど）は必ずセキュアに管理してください。
5. ファイル共有のマウントや設定ファイルのアップロードは、デプロイ後の重要なステップです。
6. コマンドを一括して実行する場合は、上記の内容をシェルスクリプトとして保存し実行することも可能です。

## トラブルシューティング

1. **リソースの競合エラー**：リソース名が既に使用されている場合は、`STORAGE_ACCOUNT_BASE`や`PSQL_FLEXIBLE_BASE`などのパラメータを変更してください。
2. **デプロイ失敗**：deploy.shスクリプトには再試行メカニズムがありますが、このドキュメントでは簡略化しています。コマンドが失敗した場合は、エラーメッセージを確認し、必要に応じて再実行してください。
3. **ネットワーク接続の問題**：プライベートエンドポイントを使用しているため、接続の問題が発生した場合は、DNSゾーンの設定とプライベートエンドポイントの設定を確認してください。
4. **PostgreSQLの拡張機能エラー**：拡張機能のインストールでエラーが発生する場合は、PostgreSQLサーバーの管理者権限があるか、`azure.extensions`パラメータが正しく設定されているかを確認してください。
5. **ストレージマウント**: Azure CLIではコンテナアプリケーションにストレージを直接マウントする単一のコマンドがありませんが、YAMLファイルを使用してストレージマウントを設定できます。もしYAMLファイルの適用中にエラーが発生した場合は、以下を確認してください：
   - コンテナアプリ環境にストレージが正しく設定されているか（`az containerapp env storage set`コマンドが成功しているか）
   - YAMLファイル内のプロパティ構造が適切か
   - ストレージ名（`storageName`）とコンテナアプリ環境のストレージ名が一致しているか

## デプロイ検証

デプロイが完了したら、以下のことを確認してください：

```powershell
# リソースの存在確認
Write-Output "必要なリソースの確認:"

try {
    $storageCheck = az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "name" -o tsv 2>$null
    Write-Output "1. ストレージアカウント: $(if ($storageCheck) { 'OK' } else { '未検出' })"
} catch {
    Write-Output "1. ストレージアカウント: 未検出"
}

try {
    $psqlCheck = az postgres flexible-server show --resource-group "$RESOURCE_GROUP_NAME" --name "$PSQL_SERVER_NAME" --query "name" -o tsv 2>$null
    Write-Output "2. PostgreSQLサーバー: $(if ($psqlCheck) { 'OK' } else { '未検出' })"
} catch {
    Write-Output "2. PostgreSQLサーバー: 未検出"
}

try {
    $acaCheck = az containerapp env show --resource-group "$RESOURCE_GROUP_NAME" --name "$ACA_ENV_NAME" --query "name" -o tsv 2>$null
    Write-Output "3. ACA環境: $(if ($acaCheck) { 'OK' } else { '未検出' })"
} catch {
    Write-Output "3. ACA環境: 未検出"
}

try {
    $appCheck = az containerapp show --resource-group "$RESOURCE_GROUP_NAME" --name "nginx" --query "name" -o tsv 2>$null
    Write-Output "4. Difyアプリケーション: $(if ($appCheck) { 'OK' } else { '未検出' })"
} catch {
    Write-Output "4. Difyアプリケーション: 未検出"
}
```

これにて、PowerShellでのAzure CLIを使用したDifyアプリケーションのデプロイ手順は完了です。

## エラーハンドリングとベストプラクティス

deploy.shスクリプトのように、実際の運用では以下のエラーハンドリングを追加することを推奨します：

```bash
# エラー時に即座に終了する設定
set -e

# 未定義変数の使用時にエラーとする
set -u

# パイプライン内のエラーを検出
set -o pipefail

# デプロイ試行回数の制御
MAX_DEPLOY_ATTEMPTS=3
DEPLOY_ATTEMPT=1

# リトライ関数の例
retry_command() {
    local max_attempts=$1
    local command_to_retry=$2
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "試行 $attempt/$max_attempts: $command_to_retry"
        if eval "$command_to_retry"; then
            echo "成功しました"
            return 0
        else
            echo "失敗しました。再試行します..."
            attempt=$((attempt + 1))
            sleep 5
        fi
    done
    
    echo "最大試行回数に達しました。処理を終了します。"
    return 1
}

# 使用例
# retry_command 3 "az storage share create --name '$NGINX_SHARE_NAME' --connection-string '$CONNECTION_STRING'"
```

### **差分チェック機能**

本番環境では、デプロイ前にwhat-ifチェックを実行することを推奨します：

```bash
# デプロイ前の検証（Bicepを使用する場合の例）
az deployment group what-if \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --template-file main.bicep \
  --parameters parameters.json
```