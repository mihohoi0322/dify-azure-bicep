# Azure CLI による Dify のデプロイ手順

このドキュメントでは、Azure CLI を使用して Dify アプリケーションをデプロイする手順を説明します。この手順は `deploy.sh` スクリプトが使用している Bicep テンプレートと同等の機能を提供します。

## 前提条件

- Azure CLI がインストールされていること (`az --version` で確認)
- jq がインストールされていること (`jq --version` で確認)
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

```bash
LOCATION=$(jq -r '.parameters.location.value // "japaneast"' ./parameters.json)
RESOURCE_GROUP_PREFIX=$(jq -r '.parameters.resourceGroupPrefix.value // "rg"' ./parameters.json)
PGSQL_USER=$(jq -r '.parameters.pgsqlUser.value // "user"' ./parameters.json)
PGSQL_PASSWORD=$(jq -r '.parameters.pgsqlPassword.value // "#QWEASDasdqwe"' ./parameters.json)
IS_PROVIDED_CERT=$(jq -r '.parameters.isProvidedCert.value // false' ./parameters.json)
ACA_CERT_PASSWORD=$(jq -r '.parameters.acaCertPassword.value // "password"' ./parameters.json)
ACA_DIFY_CUSTOMER_DOMAIN=$(jq -r '.parameters.acaDifyCustomerDomain.value // "dify.example.com"' ./parameters.json)
ACA_APP_MIN_COUNT=$(jq -r '.parameters.acaAppMinCount.value // 0' ./parameters.json)
IS_ACA_ENABLED=$(jq -r '.parameters.isAcaEnabled.value // false' ./parameters.json)

# デフォルト値の設定
STORAGE_ACCOUNT_BASE="acadifytest"
STORAGE_ACCOUNT_CONTAINER="dfy"
REDIS_NAME_BASE="acadifyredis"
PSQL_FLEXIBLE_BASE="acadifypsql"
ACA_ENV_NAME="dify-aca-env"
ACA_LOGA_NAME="dify-loga"
IP_PREFIX="10.99"

DIFY_API_IMAGE="langgenius/dify-api:1.1.2"
DIFY_SANDBOX_IMAGE="langgenius/dify-sandbox:0.2.10"
DIFY_WEB_IMAGE="langgenius/dify-web:1.1.2"
DIFY_PLUGIN_DAEMON_IMAGE="langgenius/dify-plugin-daemon:0.0.6-local"

# リソースグループ名の設定
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_PREFIX}-${LOCATION}"
```

## Azure へのログイン

```bash
# Azure CLIのサインイン状態を確認
LOGIN_STATUS=$(az account show --query "name" -o tsv 2>/dev/null || echo "")
if [ -z "$LOGIN_STATUS" ]; then
  echo "Azure CLIにログインします..."
  az login
fi
```

## 1. リソースグループの作成

```bash
# リソースグループが存在するか確認
RG_EXISTS=$(az group exists --name "$RESOURCE_GROUP_NAME")
if [ "$RG_EXISTS" = "true" ]; then
  echo "既存のリソースグループを使用します: $RESOURCE_GROUP_NAME"
else
  echo "リソースグループを作成します: $RESOURCE_GROUP_NAME"
  az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"
fi
```

## 2. 一意の識別子の生成

Bicep の uniqueString() 関数と同様の機能を実現するために、サブスクリプション ID とリソースグループ名からハッシュを生成します。

```bash
# サブスクリプションIDの取得
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)

# ハッシュ生成
RG_NAME_HEX=$(echo -n "${SUBSCRIPTION_ID}${RESOURCE_GROUP_NAME}" | md5sum | head -c 13)
```

## 3. 仮想ネットワークとサブネットの作成

```bash
# 仮想ネットワークの作成
az network vnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "vnet-${LOCATION}" \
  --address-prefix "${IP_PREFIX}.0.0/16" \
  --location "$LOCATION"

# プライベートリンク用サブネット作成
az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --vnet-name "vnet-${LOCATION}" \
  --name "PrivateLinkSubnet" \
  --address-prefix "${IP_PREFIX}.0.0/24" \
  --disable-private-endpoint-network-policies true

# ACA用サブネット作成
az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --vnet-name "vnet-${LOCATION}" \
  --name "ACASubnet" \
  --address-prefix "${IP_PREFIX}.2.0/23"

# PostgreSQL用サブネット作成
az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --vnet-name "vnet-${LOCATION}" \
  --name "PostgresSubnet" \
  --address-prefix "${IP_PREFIX}.4.0/24" \
  --service-endpoints "Microsoft.Storage" \
  --delegations "Microsoft.DBforPostgreSQL/flexibleServers"

# サブネットIDの取得
VNET_ID=$(az network vnet show --resource-group "$RESOURCE_GROUP_NAME" --name "vnet-${LOCATION}" --query "id" -o tsv)
PRIVATE_LINK_SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "vnet-${LOCATION}" --name "PrivateLinkSubnet" --query "id" -o tsv)
ACA_SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "vnet-${LOCATION}" --name "ACASubnet" --query "id" -o tsv)
POSTGRES_SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "vnet-${LOCATION}" --name "PostgresSubnet" --query "id" -o tsv)
```

## 4. ストレージアカウントとプライベートエンドポイントの作成

```bash
# ストレージアカウント名の作成
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_BASE}${RG_NAME_HEX}"

# ストレージアカウントの作成
az storage account create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$STORAGE_ACCOUNT_NAME" \
  --location "$LOCATION" \
  --sku "Standard_LRS" \
  --kind "StorageV2" \
  --enable-large-file-share \
  --enable-hierarchical-namespace false

# ストレージコンテナの作成
STORAGE_ACCOUNT_KEY=$(az storage account keys list --resource-group "$RESOURCE_GROUP_NAME" --account-name "$STORAGE_ACCOUNT_NAME" --query "[0].value" -o tsv)

az storage container create \
  --name "$STORAGE_ACCOUNT_CONTAINER" \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --account-key "$STORAGE_ACCOUNT_KEY"

# Blob用プライベートDNSゾーンの作成
az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "privatelink.blob.${az cloud show --query suffixes.storage -o tsv}"

# File用プライベートDNSゾーンの作成
az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "privatelink.file.${az cloud show --query suffixes.storage -o tsv}"

# Blob用プライベートDNSゾーンと仮想ネットワークのリンク
az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --zone-name "privatelink.blob.${az cloud show --query suffixes.storage -o tsv}" \
  --name "blob-dns-link" \
  --virtual-network "$VNET_ID" \
  --registration-enabled false

# File用プライベートDNSゾーンと仮想ネットワークのリンク
az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --zone-name "privatelink.file.${az cloud show --query suffixes.storage -o tsv}" \
  --name "file-dns-link" \
  --virtual-network "$VNET_ID" \
  --registration-enabled false

# Blob用プライベートエンドポイント作成
BLOB_PE_NAME="pe-blob"
az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$BLOB_PE_NAME" \
  --location "$LOCATION" \
  --subnet "$PRIVATE_LINK_SUBNET_ID" \
  --private-connection-resource-id $(az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "id" -o tsv) \
  --group-id blob \
  --connection-name "psc-blob"

# File用プライベートエンドポイント作成
FILE_PE_NAME="pe-file"
az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$FILE_PE_NAME" \
  --location "$LOCATION" \
  --subnet "$PRIVATE_LINK_SUBNET_ID" \
  --private-connection-resource-id $(az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "id" -o tsv) \
  --group-id file \
  --connection-name "psc-file"

# Blob用プライベートDNSゾーングループの作成
az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --endpoint-name "$BLOB_PE_NAME" \
  --name "pdz-blob" \
  --private-dns-zone "privatelink.blob.${az cloud show --query suffixes.storage -o tsv}" \
  --zone-name "config1"

# File用プライベートDNSゾーングループの作成
az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --endpoint-name "$FILE_PE_NAME" \
  --name "pdz-file" \
  --private-dns-zone "privatelink.file.${az cloud show --query suffixes.storage -o tsv}" \
  --zone-name "config1"

# BlobエンドポイントのURL取得
BLOB_ENDPOINT=$(az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "primaryEndpoints.blob" -o tsv)
```

## 5. ファイル共有の作成

```bash
# 接続文字列の取得
CONNECTION_STRING=$(az storage account show-connection-string --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "connectionString" -o tsv)

# Nginx用ファイル共有作成
NGINX_SHARE_NAME="nginx"
az storage share create --name "$NGINX_SHARE_NAME" --connection-string "$CONNECTION_STRING"

# Sandbox用ファイル共有作成
SANDBOX_SHARE_NAME="sandbox"
az storage share create --name "$SANDBOX_SHARE_NAME" --connection-string "$CONNECTION_STRING"

# SSRFプロキシ用ファイル共有作成
SSRFPROXY_SHARE_NAME="ssrfproxy"
az storage share create --name "$SSRFPROXY_SHARE_NAME" --connection-string "$CONNECTION_STRING"

# プラグイン用ファイル共有作成
PLUGIN_STORAGE_SHARE_NAME="pluginstorage"
az storage share create --name "$PLUGIN_STORAGE_SHARE_NAME" --connection-string "$CONNECTION_STRING"
```

## 6. PostgreSQLフレキシブルサーバーの作成

```bash
# PostgreSQLサーバー名の設定
PSQL_SERVER_NAME="${PSQL_FLEXIBLE_BASE}${RG_NAME_HEX}"

# プライベートDNSゾーンの作成
az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "privatelink.postgres.database.azure.com"

# 仮想ネットワークとのリンク作成
az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --zone-name "privatelink.postgres.database.azure.com" \
  --name "postgres-dns-link" \
  --virtual-network "$VNET_ID" \
  --registration-enabled false

# PostgreSQLフレキシブルサーバーの作成
az postgres flexible-server create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$PSQL_SERVER_NAME" \
  --location "$LOCATION" \
  --admin-user "$PGSQL_USER" \
  --admin-password "$PGSQL_PASSWORD" \
  --sku-name "Standard_B1ms" \
  --tier "Burstable" \
  --version "14" \
  --storage-size 32 \
  --subnet "$POSTGRES_SUBNET_ID" \
  --private-dns-zone "privatelink.postgres.database.azure.com" \
  --high-availability Disabled

# Difyデータベースの作成
az postgres flexible-server db create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --server-name "$PSQL_SERVER_NAME" \
  --database-name "dify" \
  --charset "UTF8" \
  --collation "en_US.utf8"

# Vectorデータベースの作成
az postgres flexible-server db create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --server-name "$PSQL_SERVER_NAME" \
  --database-name "vector" \
  --charset "UTF8" \
  --collation "en_US.utf8"

# PostgreSQLサーバーのFQDNを取得
POSTGRES_SERVER_FQDN=$(az postgres flexible-server show --resource-group "$RESOURCE_GROUP_NAME" --name "$PSQL_SERVER_NAME" --query "fullyQualifiedDomainName" -o tsv)
```

## 7. Redisキャッシュの作成（オプション）

```bash
if [ "$IS_ACA_ENABLED" = "true" ]; then
  # Redis名の設定
  REDIS_NAME="${REDIS_NAME_BASE}${RG_NAME_HEX}"
  
  # プライベートDNSゾーンの作成
  az network private-dns zone create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "privatelink.redis.cache.windows.net"
  
  # 仮想ネットワークとのリンク作成
  az network private-dns link vnet create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --zone-name "privatelink.redis.cache.windows.net" \
    --name "redis-dns-link" \
    --virtual-network "$VNET_ID" \
    --registration-enabled false
  
  # Redisキャッシュの作成
  az redis create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "$REDIS_NAME" \
    --location "$LOCATION" \
    --sku "Standard" \
    --vm-size "C0" \
    --enable-non-ssl-port \
    --minimum-tls-version "1.2" \
    --public-network-access "Disabled" \
    --redis-version "6"
  
  # Redisプライベートエンドポイントの作成
  REDIS_PE_NAME="pe-redis"
  az network private-endpoint create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "$REDIS_PE_NAME" \
    --location "$LOCATION" \
    --subnet "$PRIVATE_LINK_SUBNET_ID" \
    --private-connection-resource-id $(az redis show --resource-group "$RESOURCE_GROUP_NAME" --name "$REDIS_NAME" --query "id" -o tsv) \
    --group-id "redisCache" \
    --connection-name "psc-redis"
  
  # RedisプライベートDNSゾーングループの作成
  az network private-endpoint dns-zone-group create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --endpoint-name "$REDIS_PE_NAME" \
    --name "pdz-stor" \
    --private-dns-zone "privatelink.redis.cache.windows.net" \
    --zone-name "config1"
  
  # Redis情報の取得
  REDIS_HOST_NAME=$(az redis show --resource-group "$RESOURCE_GROUP_NAME" --name "$REDIS_NAME" --query "hostName" -o tsv)
  REDIS_PRIMARY_KEY=$(az redis list-keys --resource-group "$RESOURCE_GROUP_NAME" --name "$REDIS_NAME" --query "primaryKey" -o tsv)
else
  REDIS_HOST_NAME=""
  REDIS_PRIMARY_KEY=""
fi
```

## 8. ACE環境の作成

```bash
# Log Analytics workspaceの作成
az monitor log-analytics workspace create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --workspace-name "$ACA_LOGA_NAME" \
  --location "$LOCATION"

LOG_ANALYTICS_WORKSPACE_CLIENT_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$ACA_LOGA_NAME" --query "customerId" -o tsv)
LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET=$(az monitor log-analytics workspace get-shared-keys --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$ACA_LOGA_NAME" --query "primarySharedKey" -o tsv)

# Container Apps環境の作成
az containerapp env create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$ACA_ENV_NAME" \
  --location "$LOCATION" \
  --logs-destination "log-analytics" \
  --logs-workspace-id "$LOG_ANALYTICS_WORKSPACE_CLIENT_ID" \
  --logs-workspace-key "$LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET" \
  --infrastructure-subnet-resource-id "$ACA_SUBNET_ID"

# ストレージのマウント
az containerapp env storage set \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$ACA_ENV_NAME" \
  --storage-name "nginxshare" \
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" \
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" \
  --azure-file-share-name "$NGINX_SHARE_NAME" \
  --access-mode "ReadWrite"

az containerapp env storage set \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$ACA_ENV_NAME" \
  --storage-name "ssrfproxyshare" \
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" \
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" \
  --azure-file-share-name "$SSRFPROXY_SHARE_NAME" \
  --access-mode "ReadWrite"

az containerapp env storage set \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$ACA_ENV_NAME" \
  --storage-name "sandboxshare" \
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" \
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" \
  --azure-file-share-name "$SANDBOX_SHARE_NAME" \
  --access-mode "ReadWrite"

az containerapp env storage set \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$ACA_ENV_NAME" \
  --storage-name "pluginstorageshare" \
  --azure-file-account-name "$STORAGE_ACCOUNT_NAME" \
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" \
  --azure-file-share-name "$PLUGIN_STORAGE_SHARE_NAME" \
  --access-mode "ReadWrite"

# 証明書の追加（条件付き）
if [ "$IS_PROVIDED_CERT" = "true" ]; then
  az containerapp env certificate set \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --environment "$ACA_ENV_NAME" \
    --name "difycerts" \
    --password "$ACA_CERT_PASSWORD" \
    --value "$ACA_CERT_BASE64_VALUE"
fi
```

## 9. Nginxコンテナアプリケーションのデプロイ

```bash
# nginxアプリケーションの作成
az containerapp create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "nginx" \
  --environment "$ACA_ENV_NAME" \
  --image "nginx:latest" \
  --ingress "external" \
  --target-port 80 \
  --transport "auto" \
  --min-replicas "$ACA_APP_MIN_COUNT" \
  --max-replicas 10 \
  --cpu "0.5" \
  --memory "1Gi" \
  --command "/bin/bash" \
  --arg "-c" \
  --arg "mkdir -p /etc/nginx/conf.d /etc/nginx/modules && 
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
nginx -g \"daemon off;\""

# ストレージマウントを含むNginxアプリケーションの更新
# 注: 環境にストレージを設定した後、コンテナアプリにマウントする方法は環境によって異なります。
# 現在、Azure CLIではコンテナアプリケーションにストレージをマウントする直接的なコマンドは提供されていません。
# 以下のいずれかの方法を使用してください:
# 1. Azure Portal を使用してマウントを設定する
# 2. YAML定義ファイルを使用してアプリケーションを更新する
# 3. Azure Resource Manager (ARM) テンプレートを使用する
# 4. Azure RESTful API を使用する
#
# 詳細なガイダンスについては次のドキュメントを参照してください:
# https://learn.microsoft.com/azure/container-apps/storage-mounts
```

## 10. SSRFプロキシコンテナアプリケーションのデプロイ

```bash
# SSRFプロキシアプリケーションの作成
az containerapp create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "ssrfproxy" \
  --environment "$ACA_ENV_NAME" \
  --image "ubuntu/squid:latest" \
  --ingress "internal" \
  --target-port 3128 \
  --transport "tcp" \
  --min-replicas "$ACA_APP_MIN_COUNT" \
  --max-replicas 10 \
  --cpu "0.5" \
  --memory "1Gi" \
  --command "/bin/bash" \
  --arg "-c" \
  --arg "if [ -f \"/etc/squid/squid.conf\" ]; then
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

# ストレージマウントを含むSSRFプロキシアプリケーションの更新
# 注: 環境にストレージを設定した後、コンテナアプリにマウントする方法は環境によって異なります。
# 現在、Azure CLIではコンテナアプリケーションにストレージをマウントする直接的なコマンドは提供されていません。
# 以下のいずれかの方法を使用してください:
# 1. Azure Portal を使用してマウントを設定する
# 2. YAML定義ファイルを使用してアプリケーションを更新する
# 3. Azure Resource Manager (ARM) テンプレートを使用する
# 4. Azure RESTful API を使用する
#
# 詳細なガイダンスについては次のドキュメントを参照してください:
# https://learn.microsoft.com/azure/container-apps/storage-mounts
```

## 11. Sandboxコンテナアプリケーションのデプロイ

```bash
# Sandboxアプリケーションの作成
az containerapp create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "sandbox" \
  --environment "$ACA_ENV_NAME" \
  --image "$DIFY_SANDBOX_IMAGE" \
  --ingress "internal" \
  --target-port 8194 \
  --transport "tcp" \
  --min-replicas "$ACA_APP_MIN_COUNT" \
  --max-replicas 10 \
  --cpu "2" \
  --memory "4Gi" \
  --env-vars \
    "LOG_LEVEL=INFO" \
    "ENABLE_NETWORK=true" \
    "HTTP_PROXY=http://ssrfproxy:3128" \
    "HTTPS_PROXY=http://ssrfproxy:3128" \
    "SANDBOX_PORT=8194" \
  --scale-rule-name "sandbox" \
  --scale-rule-type "tcp" \
  --scale-rule-metadata "concurrentRequests=10"

# ストレージマウントを含むSandboxアプリケーションの更新
# 注: 環境にストレージを設定した後、コンテナアプリにマウントする方法は環境によって異なります。
# 現在、Azure CLIではコンテナアプリケーションにストレージをマウントする直接的なコマンドは提供されていません。
# 以下のいずれかの方法を使用してください:
# 1. Azure Portal を使用してマウントを設定する
# 2. YAML定義ファイルを使用してアプリケーションを更新する
# 3. Azure Resource Manager (ARM) テンプレートを使用する
# 4. Azure RESTful API を使用する
#
# 詳細なガイダンスについては次のドキュメントを参照してください:
# https://learn.microsoft.com/azure/container-apps/storage-mounts
```

## 12. Workerコンテナアプリケーションのデプロイ

```bash
# Workerアプリケーションの作成
az containerapp create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "worker" \
  --environment "$ACA_ENV_NAME" \
  --image "$DIFY_API_IMAGE" \
  --min-replicas "$ACA_APP_MIN_COUNT" \
  --max-replicas 10 \
  --cpu "2" \
  --memory "4Gi" \
  --env-vars \
    "MODE=worker" \
    "LOG_LEVEL=INFO" \
    "SECRET_KEY=sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U" \
    "DB_USERNAME=$PGSQL_USER" \
    "DB_PASSWORD=$PGSQL_PASSWORD" \
    "DB_HOST=$POSTGRES_SERVER_FQDN" \
    "DB_PORT=5432" \
    "DB_DATABASE=dify" \
    "REDIS_HOST=$REDIS_HOST_NAME" \
    "REDIS_PORT=6380" \
    "REDIS_PASSWORD=$REDIS_PRIMARY_KEY" \
    "REDIS_USE_SSL=true" \
    "REDIS_DB=0" \
    "CELERY_BROKER_URL=$([ -z "$REDIS_HOST_NAME" ] && echo "" || echo "rediss://:${REDIS_PRIMARY_KEY}@${REDIS_HOST_NAME}:6380/1")" \
    "STORAGE_TYPE=azure-blob" \
    "AZURE_BLOB_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME" \
    "AZURE_BLOB_ACCOUNT_KEY=$STORAGE_ACCOUNT_KEY" \
    "AZURE_BLOB_ACCOUNT_URL=$BLOB_ENDPOINT" \
    "AZURE_BLOB_CONTAINER_NAME=$STORAGE_ACCOUNT_CONTAINER" \
    "VECTOR_STORE=pgvector" \
    "PGVECTOR_HOST=$POSTGRES_SERVER_FQDN" \
    "PGVECTOR_PORT=5432" \
    "PGVECTOR_USER=$PGSQL_USER" \
    "PGVECTOR_PASSWORD=$PGSQL_PASSWORD" \
    "PGVECTOR_DATABASE=vector" \
    "INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH=1000" \
  --scale-rule-name "worker" \
  --scale-rule-type "tcp" \
  --scale-rule-metadata "concurrentRequests=10"
```

## 13. APIコンテナアプリケーションのデプロイ

```bash
# APIアプリケーションの作成
az containerapp create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "api" \
  --environment "$ACA_ENV_NAME" \
  --image "$DIFY_API_IMAGE" \
  --ingress "internal" \
  --target-port 5001 \
  --exposed-port 5001 \
  --transport "tcp" \
  --min-replicas "$ACA_APP_MIN_COUNT" \
  --max-replicas 10 \
  --cpu "2" \
  --memory "4Gi" \
  --env-vars \
    "MODE=api" \
    "LOG_LEVEL=INFO" \
    "API_SERVER_HOST=0.0.0.0" \
    "API_SERVER_PORT=5001" \
    "SECRET_KEY=sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U" \
    "DB_USERNAME=$PGSQL_USER" \
    "DB_PASSWORD=$PGSQL_PASSWORD" \
    "DB_HOST=$POSTGRES_SERVER_FQDN" \
    "DB_PORT=5432" \
    "DB_DATABASE=dify" \
    "REDIS_HOST=$REDIS_HOST_NAME" \
    "REDIS_PORT=6380" \
    "REDIS_PASSWORD=$REDIS_PRIMARY_KEY" \
    "REDIS_USE_SSL=true" \
    "REDIS_DB=0" \
    "CELERY_BROKER_URL=$([ -z "$REDIS_HOST_NAME" ] && echo "" || echo "rediss://:${REDIS_PRIMARY_KEY}@${REDIS_HOST_NAME}:6380/1")" \
    "STORAGE_TYPE=azure-blob" \
    "AZURE_BLOB_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME" \
    "AZURE_BLOB_ACCOUNT_KEY=$STORAGE_ACCOUNT_KEY" \
    "AZURE_BLOB_ACCOUNT_URL=$BLOB_ENDPOINT" \
    "AZURE_BLOB_CONTAINER_NAME=$STORAGE_ACCOUNT_CONTAINER" \
    "VECTOR_STORE=pgvector" \
    "PGVECTOR_HOST=$POSTGRES_SERVER_FQDN" \
    "PGVECTOR_PORT=5432" \
    "PGVECTOR_USER=$PGSQL_USER" \
    "PGVECTOR_PASSWORD=$PGSQL_PASSWORD" \
    "PGVECTOR_DATABASE=vector" \
    "PLUGIN_WEBHOOK_ENABLED=true" \
    "PLUGIN_REMOTE_INSTALLING_ENABLED=true" \
    "PLUGIN_REMOTE_INSTALLING_HOST=127.0.0.1" \
    "PLUGIN_REMOTE_INSTALLING_PORT=5003" \
  --scale-rule-name "api" \
  --scale-rule-type "tcp" \
  --scale-rule-metadata "concurrentRequests=10"

# ストレージマウントを含むAPIアプリケーションの更新
# 注: 環境にストレージを設定した後、コンテナアプリにマウントする方法は環境によって異なります。
# 現在、Azure CLIではコンテナアプリケーションにストレージをマウントする直接的なコマンドは提供されていません。
# 以下のいずれかの方法を使用してください:
# 1. Azure Portal を使用してマウントを設定する
# 2. YAML定義ファイルを使用してアプリケーションを更新する
# 3. Azure Resource Manager (ARM) テンプレートを使用する
# 4. Azure RESTful API を使用する
#
# 詳細なガイダンスについては次のドキュメントを参照してください:
# https://learn.microsoft.com/azure/container-apps/storage-mounts
```

## 14. Webコンテナアプリケーションのデプロイ

```bash
# Webアプリケーションの作成
az containerapp create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "web" \
  --environment "$ACA_ENV_NAME" \
  --image "$DIFY_WEB_IMAGE" \
  --ingress "internal" \
  --target-port 3000 \
  --transport "auto" \
  --min-replicas "$ACA_APP_MIN_COUNT" \
  --max-replicas 10 \
  --cpu "1" \
  --memory "2Gi" \
  --env-vars \
    "CONSOLE_API_URL=http://api:5001" \
    "CONSOLE_API_PREFIX=/console/api" \
    "SERVICE_API_PREFIX=/api" \
  --scale-rule-name "web" \
  --scale-rule-type "tcp" \
  --scale-rule-metadata "concurrentRequests=10"

# カスタムドメインの設定（条件付き）
if [ "$IS_PROVIDED_CERT" = "true" ]; then
  az containerapp hostname add \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "nginx" \
    --hostname "$ACA_DIFY_CUSTOMER_DOMAIN"
  
  az containerapp hostname bind \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "nginx" \
    --hostname "$ACA_DIFY_CUSTOMER_DOMAIN" \
    --environment "$ACA_ENV_NAME" \
    --certificate "difycerts"
fi
```

## 15. デプロイ後の設定

```bash
# ストレージアカウントの監査ログを有効化
az storage account update \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --enable-local-user true

# クライアントIPを取得してファイアウォールに追加
CLIENT_IP=$(curl -s https://api.ipify.org?format=json | jq -r .ip)
if [ -n "$CLIENT_IP" ]; then
  echo "現在のIPアドレス:$CLIENT_IP をストレージアカウントのファイアウォールに追加します"
  az storage account network-rule add \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --ip-address "$CLIENT_IP"
fi

# PostgreSQLサーバーのファイアウォールにクライアントIPを追加
if [ -n "$CLIENT_IP" ]; then
  az postgres flexible-server firewall-rule create \
    --name "ClientIPAccess" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --server-name "$PSQL_SERVER_NAME" \
    --start-ip-address "$CLIENT_IP" \
    --end-ip-address "$CLIENT_IP"
fi

# PostgreSQLサーバーのパラメータを設定
az postgres flexible-server parameter set \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --server-name "$PSQL_SERVER_NAME" \
  --name "azure.extensions" \
  --value "uuid-ossp"

# アプリケーションの再起動（ファイル共有マウント後に必要な場合）
for APP_NAME in nginx ssrfproxy sandbox worker api web; do
  az containerapp update \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --set "properties.template.scale.minReplicas=1"
done

# デプロイされたアプリケーションのURLを取得
DIFY_URL=$(az containerapp show --name "nginx" --resource-group "$RESOURCE_GROUP_NAME" --query "properties.configuration.ingress.fqdn" -o tsv)
echo "==============================================="
echo "Difyアプリケーションは次のURLでアクセスできます："
echo "https://$DIFY_URL"
echo "==============================================="
```

## 16. 設定ファイルのアップロード

次の手順では、Nginx、SSRFプロキシ、Sandboxなどの設定ファイルをアップロードします。これらのファイルは、`deploy.sh` スクリプトの中でもアップロードされています。

```bash
# 一時ディレクトリを作成
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Nginxの設定ファイルをアップロード
echo "Nginxの設定ファイルをアップロード中..."
for file in mountfiles/nginx/*.conf mountfiles/nginx/mime.types; do
  if [ -f "$file" ]; then
    filename=$(basename "$file")
    echo "ファイルをアップロード: $filename"
    
    # 改行コードを修正
    TEMP_FILE="$TEMP_DIR/$filename"
    tr -d '\r' < "$file" > "$TEMP_FILE"
    
    # 修正したファイルをアップロード
    az storage file upload --source "$TEMP_FILE" --share-name "$NGINX_SHARE_NAME" \
      --path "$filename" --connection-string "$CONNECTION_STRING"
  fi
done

# 特殊パラメータファイルをチェックして処理
for param_file in "fastcgi_params" "scgi_params" "uwsgi_params"; do
  full_path="mountfiles/nginx/${param_file}"
  
  if [ -f "$full_path" ]; then
    echo "特殊ファイルをアップロード: ${param_file}"
    
    # 改行コードを修正
    TEMP_FILE="$TEMP_DIR/${param_file}"
    tr -d '\r' < "$full_path" > "$TEMP_FILE"
    
    # base64エンコード
    base64 "$TEMP_FILE" > "${TEMP_FILE}.b64"
    
    # エンコードしたファイルをアップロード
    az storage file upload --source "${TEMP_FILE}.b64" --share-name "$NGINX_SHARE_NAME" \
      --path "${param_file}.b64" --connection-string "$CONNECTION_STRING"
  fi
done

# conf.dディレクトリのファイルをアップロード
echo "conf.dディレクトリのファイルをアップロード中..."
if [ -d "mountfiles/nginx/conf.d" ]; then
  # conf.dディレクトリを作成
  az storage directory create --name "conf.d" --share-name "$NGINX_SHARE_NAME" \
    --connection-string "$CONNECTION_STRING"
  
  for file in mountfiles/nginx/conf.d/*; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      echo "ファイルをアップロード: conf.d/$filename"
      
      # 改行コードを修正
      TEMP_FILE="$TEMP_DIR/$filename"
      tr -d '\r' < "$file" > "$TEMP_FILE"
      
      az storage file upload --source "$TEMP_FILE" --share-name "$NGINX_SHARE_NAME" \
        --path "conf.d/$filename" --connection-string "$CONNECTION_STRING"
    fi
  done
fi

# modulesディレクトリのファイルをアップロード
echo "modulesディレクトリのファイルをアップロード中..."
if [ -d "mountfiles/nginx/modules" ]; then
  # modulesディレクトリを作成
  az storage directory create --name "modules" --share-name "$NGINX_SHARE_NAME" \
    --connection-string "$CONNECTION_STRING"
  
  for file in mountfiles/nginx/modules/*; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      echo "ファイルをアップロード: modules/$filename"
      az storage file upload --source "$file" --share-name "$NGINX_SHARE_NAME" \
        --path "modules/$filename" --connection-string "$CONNECTION_STRING"
    fi
  done
fi

# SSRFプロキシの設定ファイルをアップロード
echo "SSRFプロキシの設定ファイルをアップロード中..."
# conf.dディレクトリを作成
az storage directory create --name "conf.d" --share-name "$SSRFPROXY_SHARE_NAME" \
  --connection-string "$CONNECTION_STRING"

if [ -f "mountfiles/ssrfproxy/squid.conf" ]; then
  # 改行コードを修正
  TEMP_FILE="$TEMP_DIR/squid.conf"
  tr -d '\r' < "mountfiles/ssrfproxy/squid.conf" > "$TEMP_FILE"
  
  az storage file upload --source "$TEMP_FILE" --share-name "$SSRFPROXY_SHARE_NAME" \
    --path "squid.conf" --connection-string "$CONNECTION_STRING"
fi

if [ -f "mountfiles/ssrfproxy/errorpage.css" ]; then
  # 改行コードを修正
  TEMP_FILE="$TEMP_DIR/errorpage.css"
  tr -d '\r' < "mountfiles/ssrfproxy/errorpage.css" > "$TEMP_FILE"
  
  az storage file upload --source "$TEMP_FILE" --share-name "$SSRFPROXY_SHARE_NAME" \
    --path "errorpage.css" --connection-string "$CONNECTION_STRING"
fi

# SSRFプロキシのconf.dディレクトリのファイルをアップロード
if [ -d "mountfiles/ssrfproxy/conf.d" ]; then
  for file in mountfiles/ssrfproxy/conf.d/*; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      echo "ファイルをアップロード: conf.d/$filename"
      
      # 改行コードを修正
      TEMP_FILE="$TEMP_DIR/$filename"
      tr -d '\r' < "$file" > "$TEMP_FILE"
      
      az storage file upload --source "$TEMP_FILE" --share-name "$SSRFPROXY_SHARE_NAME" \
        --path "conf.d/$filename" --connection-string "$CONNECTION_STRING"
    fi
  done
fi

# Sandbox用の設定ファイルをアップロード
echo "Sandboxの設定ファイルをアップロード中..."
if [ -f "mountfiles/sandbox/python-requirements.txt" ]; then
  # 改行コードを修正
  TEMP_FILE="$TEMP_DIR/python-requirements.txt"
  tr -d '\r' < "mountfiles/sandbox/python-requirements.txt" > "$TEMP_FILE"
  
  az storage file upload --source "$TEMP_FILE" --share-name "$SANDBOX_SHARE_NAME" \
    --path "python-requirements.txt" --connection-string "$CONNECTION_STRING"
fi
```

## 17. データベース拡張機能のセットアップ（psqlコマンドがある場合）

```bash
# psqlコマンドが必要です
# PostgreSQLデータベースのベクター拡張機能を有効化
PGPASSWORD="$PGSQL_PASSWORD" psql -h "$POSTGRES_SERVER_FQDN" -U "$PGSQL_USER" -d "vector" -c "CREATE EXTENSION IF NOT EXISTS vector;"

# uuid-ossp拡張機能の有効化
PGPASSWORD="$PGSQL_PASSWORD" psql -h "$POSTGRES_SERVER_FQDN" -U "$PGSQL_USER" -d "dify" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
PGPASSWORD="$PGSQL_PASSWORD" psql -h "$POSTGRES_SERVER_FQDN" -U "$PGSQL_USER" -d "vector" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
```

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
5. **ストレージマウント**: Azure CLI では現在、コンテナアプリにストレージを直接マウントするためのコマンドが提供されていません。ストレージマウントが必要な場合は、Azure Portal、YAML定義ファイル、ARMテンプレート、または Azure REST APIを使用してマウントを設定してください。

## デプロイ検証

デプロイが完了したら、以下のことを確認してください：

```bash
# リソースの存在確認
echo "必要なリソースの確認:"
echo "1. ストレージアカウント: $(az storage account show --resource-group "$RESOURCE_GROUP_NAME" --name "$STORAGE_ACCOUNT_NAME" --query "name" -o tsv 2>/dev/null && echo "OK" || echo "未検出")"
echo "2. PostgreSQLサーバー: $(az postgres flexible-server show --resource-group "$RESOURCE_GROUP_NAME" --name "$PSQL_SERVER_NAME" --query "name" -o tsv 2>/dev/null && echo "OK" || echo "未検出")"
echo "3. ACA環境: $(az containerapp env show --resource-group "$RESOURCE_GROUP_NAME" --name "$ACA_ENV_NAME" --query "name" -o tsv 2>/dev/null && echo "OK" || echo "未検出")"
echo "4. Difyアプリケーション: $(az containerapp show --resource-group "$RESOURCE_GROUP_NAME" --name "nginx" --query "name" -o tsv 2>/dev/null && echo "OK" || echo "未検出")"
```

これにて、Azure CLIを使用したDifyアプリケーションのデプロイ手順は完了です。