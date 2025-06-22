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
  --address-prefix "${IP_PREFIX}.2.0/23" `
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

# クライアントIPを取得してファイアウォールに追加
try {
    $CLIENT_IP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
    Write-Output "現在のIPアドレス: $CLIENT_IP をストレージアカウントのファイアウォールに追加します"
    
    az storage account network-rule add `
      --account-name "$STORAGE_ACCOUNT_NAME" `
      --resource-group "$RESOURCE_GROUP_NAME" `
      --ip-address "$CLIENT_IP"
} catch {
    Write-Warning "クライアントIPの取得に失敗しました: $($_.Exception.Message)"
}

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

## 6. 設定ファイルのアップロード

```powershell
# 一時ディレクトリを作成
$TEMP_DIR = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }

try {
    # Nginxの設定ファイルをアップロード
    Write-Output "Nginxの設定ファイルをアップロード中..."
    
    $nginxFiles = @("mountfiles/nginx/*.conf", "mountfiles/nginx/mime.types", "mountfiles/nginx/start.sh")
    foreach ($pattern in $nginxFiles) {
        $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $filename = $file.Name
            Write-Output "ファイルをアップロード: $filename"
            
            # 改行コードを修正（CRLF → LF）
            $content = Get-Content -Path $file.FullName -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $filename

            # BOMなしUTF-8で書き出す
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBomEncoding)
            
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

            # BOMなしUTF-8で書き出す
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBomEncoding)

            # base64エンコード
            $bytes = [System.IO.File]::ReadAllBytes($tempFile)
            $base64Content = [System.Convert]::ToBase64String($bytes)
            $base64File = "$tempFile.b64"

            # BOMなしUTF-8で書き出す
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($base64File, $base64Content, $utf8NoBomEncoding)

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

            # BOMなしUTF-8で書き出す
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBomEncoding)
            
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
    
    $ssrfProxyFiles = @("mountfiles/ssrfproxy/squid.conf", "mountfiles/ssrfproxy/errorpage.css", "mountfiles/ssrfproxy/start.sh")
    foreach ($filePath in $ssrfProxyFiles) {
        if (Test-Path $filePath) {
            $filename = Split-Path $filePath -Leaf
            Write-Output "ファイルをアップロード: $filename"
            
            # 改行コードを修正
            $content = Get-Content -Path $filePath -Raw
            $content = $content -replace "`r`n", "`n"
            $tempFile = Join-Path $TEMP_DIR.FullName $filename

            # BOMなしUTF-8で書き出す
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBomEncoding)
            
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

            # BOMなしUTF-8で書き出す
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBomEncoding)
            
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

        # BOMなしUTF-8で書き出す
        $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBomEncoding)
        
        az storage file upload --source "$tempFile" --share-name "$SANDBOX_SHARE_NAME" `
          --path "python-requirements.txt" --connection-string "$CONNECTION_STRING"
    }
    
} finally {
    # 一時ディレクトリをクリーンアップ
    Remove-Item -Path $TEMP_DIR.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
```

## 7. PostgreSQLフレキシブルサーバーの作成

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

## 8. Azure Cache for Redisの作成

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

## 9. Azure Container Appsの作成

```powershell
# 1. parameter.jsonをparameters.only-aca.jsonという名前でコピー
Copy-Item -Path "parameters.json" -Destination "parameters-only-aca.json"

# 2. parameters.only-aca.jsonに対して $ACA_SUBNET_ID の値を acaSubnetId というキー名としてJSONに追記
# 変数名とparameters.jsonのキー名の対応表
$paramMap = @{
    "ACA_SUBNET_ID"        = "acaSubnetId"
    "STORAGE_ACCOUNT_KEY"  = "storageAccountKey"
    "STORAGE_ACCOUNT_NAME" = "storageAccountName"
    "NGINX_SHARE_NAME"    = "nginxShareName"
    "SANDBOX_SHARE_NAME"  = "sandboxShareName"
    "SSRFPROXY_SHARE_NAME" = "ssrfproxyShareName"
    "PLUGIN_STORAGE_SHARE_NAME" = "pluginStorageShareName"
    "POSTGRES_SERVER_FQDN" = "postgresServerFqdn"
    "REDIS_HOST_NAME" = "redisHostName"
    "REDIS_PRIMARY_KEY" = "redisPrimaryKey"
    "BLOB_ENDPOINT" = "blobEndpoint"
}

$paramFile = "parameters-only-aca.json"
$params = Get-Content $paramFile | ConvertFrom-Json

foreach ($varName in $paramMap.Keys) {
    $paramName = $paramMap[$varName]
    $value = Get-Variable -Name $varName -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $value) {
        $params.parameters | Add-Member -MemberType NoteProperty -Name $paramName -Value @{ "value" = $value } -Force
    }
}

$params | ConvertTo-Json -Depth 10 | Set-Content $paramFile -Encoding UTF8

# bicepを使用してContainer Apps環境、および関連リソースをデプロイ
$DEPLOYMENT_NAME = "dify-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
az deployment sub create --name $DEPLOYMENT_NAME --location $LOCATION --template-file main-only-aca.bicep --parameters parameters-only-aca.json

# デプロイ完了後、parameters.only-aca.jsonを削除
Remove-Item -Path $paramFile -Force
```

## 10. デプロイ後の設定と動作確認

```powershell
# ストレージアカウントの監査ログを有効化
az storage account update `
  --name "$STORAGE_ACCOUNT_NAME" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --enable-local-user true

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

# デプロイされたアプリケーションのURLを取得
$DIFY_URL = az containerapp show --name "nginx" --resource-group "$RESOURCE_GROUP_NAME" --query "properties.configuration.ingress.fqdn" -o tsv
Write-Output "==============================================="
Write-Output "Difyアプリケーションは次のURLでアクセスできます："
Write-Output ("https://{0}" -f $DIFY_URL)
Write-Output "==============================================="
```

## 11. 各種サービスの閉域化

```powershell
# ストレージアカウントへのパブリックアクセスを無効化
az storage account update `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$STORAGE_ACCOUNT_NAME" `
  --public-network-access "Disabled"

# PostgreSQLサーバーへのパブリックアクセスは既定で無効化済み

# Container Apps拡張機能のインストール
az extension add --name containerapp --upgrade --allow-preview true

# Container Apps環境へのパブリックネットワークアクセスを無効化
az containerapp env update `
  --name "$ACA_ENV_NAME" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --public-network-access "Disabled" `
  --internal-only true

# プライベートエンドポイントを構成する
# （Container Apps環境へのパブリックアクセスが無効化された後でのみ、プライベートエンドポイントを作成可能）
$ACA_ENV_PE_NAME = "pe-aca-env"
az network private-endpoint create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_PE_NAME" `
  --location "$LOCATION" `
  --subnet "$PRIVATE_LINK_SUBNET_ID" `
  --private-connection-resource-id $(az containerapp env show --resource-group "$RESOURCE_GROUP_NAME" --name "$ACA_ENV_NAME" --query "id" -o tsv) `
  --group-id managedEnvironments `
  --connection-name "psc-aca-env"

# ACA Managed Environment 用プライベートDNSゾーンの作成
$ACA_ENV_DNS_ZONE = "privatelink.${LOCATION}.azurecontainerapps.io"
az network private-dns zone create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_DNS_ZONE"

# プライベートDNSゾーンと仮想ネットワークのリンク
az network private-dns link vnet create `
  --resource-group $RESOURCE_GROUP_NAME `
  --zone-name $ACA_ENV_DNS_ZONE `
  --name "aca-env-dns-link" `
  --virtual-network $VNET_ID `
  --registration-enabled false

# プライベートDNSゾーングループの作成
az network private-endpoint dns-zone-group create `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --endpoint-name "$ACA_ENV_PE_NAME" `
  --name "pdz-aca-env" `
  --private-dns-zone "$ACA_ENV_DNS_ZONE" `
  --zone-name "config1"

# DNSレコード名の取得
$ENVIRONMENT_ID = (az containerapp env show `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --name "$ACA_ENV_NAME" `
  --query "id" `
  -o tsv
)

$DNS_RECORD_NAME = (
  (az containerapp env show `
    --id $ENVIRONMENT_ID `
    --query 'properties.defaultDomain' `
    --output tsv
  ) -replace '\..*',''
)

# プライベートDNSゾーンにAレコードを追加
$PRIVATE_ENDPOINT_IP_ADDRESS = (az network private-endpoint show `
  --name $ACA_ENV_PE_NAME `
  --resource-group $RESOURCE_GROUP_NAME `
  --query 'customDnsConfigs[0].ipAddresses[0]' `
  --output tsv
)

az network private-dns record-set a add-record `
  --resource-group $RESOURCE_GROUP_NAME `
  --zone-name "privatelink.japaneast.azurecontainerapps.io" `
  --record-set-name $DNS_RECORD_NAME `
  --ipv4-address $PRIVATE_ENDPOINT_IP_ADDRESS

# Azure Monitor プライベートリンクスコープの作成
$properties = @"
{\"accessModeSettings\": {\"queryAccessMode\":\"PrivateOnly\", \"ingestionAccessMode\":\"PrivateOnly\"}}
"@
$AMPLS_NAME = "monitor-pls"
az resource create ` 
-g $RESOURCE_GROUP_NAME `
--name $AMPLS_NAME ` 
-l global `
--api-version "2021-07-01-preview" `
--resource-type Microsoft.Insights/privateLinkScopes `
--properties $properties

# Log Analytics WorkspaceのIDを取得
$LOG_ANALYTICS_WS_ID = az monitor log-analytics workspace show `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --workspace-name "$ACA_LOGA_NAME" `
  --query "id" -o tsv

# Log Analytics Workspaceをプライベートリンクスコープに関連付け
az monitor private-link-scope scoped-resource create `
  -g "$RESOURCE_GROUP_NAME" --scope-name "$AMPLS_NAME" `
  -n "${ACA_LOGA_NAME}-connection" `
  --linked-resource "$LOG_ANALYTICS_WS_ID"

$SCOPE_ID = az monitor private-link-scope show -g "$RESOURCE_GROUP_NAME" -n "$AMPLS_NAME" --query id -o tsv

# AMPLSのプライベートエンドポイントを作成
$AMPLS_PE_NAME = "pe-ampls"
az network private-endpoint create  `
  -g "$RESOURCE_GROUP_NAME" -n "$AMPLS_PE_NAME" `
  --vnet-name "vnet-$LOCATION" --subnet "$PRIVATE_LINK_SUBNET_ID" `
  --private-connection-resource-id "$SCOPE_ID" `
  --group-id azuremonitor `
  --connection-name "$AMPLS_PE_NAME-conn"

# AMPLSのプライベートDNSゾーンを作成
az network private-endpoint dns-zone-group create `
  -g "$RESOURCE_GROUP_NAME" `
  --endpoint-name "$AMPLS_PE_NAME" `
  -n "ampls-zonegrp" `
  --zone-name "config1" `
  --private-dns-zone "privatelink.monitor.azure.com" `
  --private-dns-zone "privatelink.ods.opinsights.azure.com" `
  --private-dns-zone "privatelink.oms.opinsights.azure.com" `
  --private-dns-zone "privatelink.agentsvc.azure-automation.net" `
  --private-dns-zone "privatelink.blob.core.windows.net"

# AMPLSにPrivate Endpointを関連付け（接続の承認）
$PE_CONNECTION_NAME = (az monitor private-link-scope private-endpoint-connection list `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --scope-name "$AMPLS_NAME" `
  --query "[0].name" -o tsv)

# プライベートエンドポイント接続を承認
az monitor private-link-scope private-endpoint-connection approve `
  --name "$PE_CONNECTION_NAME" `
  --resource-group "$RESOURCE_GROUP_NAME" `
  --scope-name "$AMPLS_NAME"
```

```powershell
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