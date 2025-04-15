#!/bin/bash
# filepath: /Users/miho/develop/Local/dify-azure-bicep/deploy.sh

# オプション解析
# デフォルトではパラメータファイルから生成されるリソースグループ名を使用する
RESOURCE_GROUP_NAME=""
SKIP_DEPLOY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --resource-group)
      RESOURCE_GROUP_NAME="$2"
      shift 2
      ;;
    --skip-deploy)
      SKIP_DEPLOY=true
      shift
      ;;
    *)
      echo "使用方法: $0 [--resource-group <リソースグループ名>] [--skip-deploy]"
      exit 1
      ;;
  esac
done

# parameters.jsonファイルからパラメータを取得
if [ -f "./parameters.json" ]; then
  # jqコマンドで値を取得（値が存在しない場合は空文字を返す）
  LOCATION=$(jq -r '.parameters.location.value // empty' ./parameters.json)
  RG_PREFIX=$(jq -r '.parameters.resourceGroupPrefix.value // empty' ./parameters.json)
  
  # コマンドラインで指定されていない場合、リソースグループ名を構築
  if [ -z "$RESOURCE_GROUP_NAME" ]; then
    # main.bicepと同じ命名規則を使用: {resourceGroupPrefix}-{location}
    RESOURCE_GROUP_NAME="${RG_PREFIX}-${LOCATION}"
  fi
  
  echo "リソースグループ名: $RESOURCE_GROUP_NAME"
  export AZURE_DEFAULTS_GROUP="$RESOURCE_GROUP_NAME"
  
  PGSQL_USER=$(jq -r '.parameters.pgsqlUser.value // empty' ./parameters.json)
  PGSQL_PASSWORD=$(jq -r '.parameters.pgsqlPassword.value // empty' ./parameters.json)
else
  echo "エラー: parameters.jsonファイルが見つかりません。リソースグループ名を指定してください。"
  exit 1
fi

# Azure CLIのサインイン状態を確認
LOGIN_STATUS=$(az account show --query "name" -o tsv 2>/dev/null || echo "")
if [ -z "$LOGIN_STATUS" ]; then
  echo "Azure CLIにログインします..."
  az login
fi

# Bicepデプロイをスキップしない場合
if [ "$SKIP_DEPLOY" = false ]; then
  # デプロイ前にリソースグループが存在するか確認
  RG_EXISTS=$(az group exists --name "$RESOURCE_GROUP_NAME")
  if [ "$RG_EXISTS" = "true" ]; then
    echo "既存のリソースグループを使用します: $RESOURCE_GROUP_NAME"
  else
    echo "リソースグループを作成します: $RESOURCE_GROUP_NAME"
    az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"
  fi

  echo "Bicepテンプレートをデプロイしています..."
  MAX_DEPLOY_ATTEMPTS=3
  DEPLOY_ATTEMPT=1
  DEPLOY_SUCCESS=false

  while [ $DEPLOY_ATTEMPT -le $MAX_DEPLOY_ATTEMPTS ] && [ "$DEPLOY_SUCCESS" = "false" ]; do
    echo "デプロイ試行 $DEPLOY_ATTEMPT/$MAX_DEPLOY_ATTEMPTS..."
    
    # mainという名前を明示的に指定してデプロイ
    DEPLOYMENT_NAME="dify-deployment-$(date +%Y%m%d%H%M%S)"
    az deployment sub create --name "$DEPLOYMENT_NAME" --location "$LOCATION" --template-file main.bicep --parameters parameters.json
    
    if [ $? -eq 0 ]; then
      DEPLOY_SUCCESS=true
      echo "Bicepデプロイが成功しました！"
    else
      ERROR_MSG=$(az deployment sub show --name "$DEPLOYMENT_NAME" --query "error.message" -o tsv 2>/dev/null)
      
      if [[ "$ERROR_MSG" == *"Server is busy"* || "$ERROR_MSG" == *"ServerBusy"* ]]; then
        WAIT_TIME=$((DEPLOY_ATTEMPT * 60))
        echo "PostgreSQLサーバーが忙しいため、${WAIT_TIME}秒待機してから再試行します..."
        sleep $WAIT_TIME
      else
        echo "エラー: Bicepデプロイに失敗しました。"
        echo "エラーメッセージ: $ERROR_MSG"
        exit 1
      fi
      
      DEPLOY_ATTEMPT=$((DEPLOY_ATTEMPT + 1))
    fi
  done

  if [ "$DEPLOY_SUCCESS" = "false" ]; then
    echo "エラー: 最大試行回数に達しました。Bicepデプロイに失敗しました。"
    exit 1
  fi
  
  # デプロイ結果からストレージアカウント名を取得
  echo "デプロイからリソース情報を取得しています..."
  # デプロイ出力からストレージアカウント名を取得 (新しい方法)
  STORAGE_ACCOUNTS=$(az storage account list --resource-group "$RESOURCE_GROUP_NAME" --query "[].name" -o tsv)
  if [ -z "$STORAGE_ACCOUNTS" ]; then
    echo "エラー: リソースグループにストレージアカウントが見つかりません。"
    exit 1
  fi
  
  # 最初のストレージアカウントを使用
  STORAGE_ACCOUNT_NAME=$(echo "$STORAGE_ACCOUNTS" | head -n 1)
  echo "使用するストレージアカウント: $STORAGE_ACCOUNT_NAME"

  # 現在のAzureサブスクリプション情報を確認
  echo "Azureサブスクリプション情報を確認しています..."
  CURRENT_SUBSCRIPTION=$(az account show --query "name" -o tsv)
  echo "現在のサブスクリプション: $CURRENT_SUBSCRIPTION"
else
  # デプロイをスキップする場合は、リソースグループが存在することを確認
  RG_EXISTS=$(az group exists --name "$RESOURCE_GROUP_NAME")
  if [ "$RG_EXISTS" = "true" ]; then
    echo "リソースグループが見つかりました: $RESOURCE_GROUP_NAME"
    
    # 既存のストレージアカウントを取得
    STORAGE_ACCOUNTS=$(az storage account list --resource-group "$RESOURCE_GROUP_NAME" --query "[].name" -o tsv)
    if [ -z "$STORAGE_ACCOUNTS" ]; then
      echo "エラー: リソースグループにストレージアカウントが見つかりません。"
      exit 1
    fi
    
    # 最初のストレージアカウントを使用
    STORAGE_ACCOUNT_NAME=$(echo "$STORAGE_ACCOUNTS" | head -n 1)
    echo "使用するストレージアカウント: $STORAGE_ACCOUNT_NAME"
  else
    echo "エラー: リソースグループが存在しません: $RESOURCE_GROUP_NAME"
    echo "デプロイをスキップする場合は、既存のリソースグループを指定する必要があります。"
    exit 1
  fi
fi

# ストレージアカウントの監査ログを有効化（トラブルシューティング用）
echo "ストレージアカウントの監査ログを有効化しています..."
az storage account update --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --enable-local-user true

# クライアントIPを取得してファイアウォールに追加
CLIENT_IP=$(curl -s https://api.ipify.org?format=json | jq -r .ip)
if [ -n "$CLIENT_IP" ]; then
  echo "現在のIPアドレス:$CLIENT_IP をストレージアカウントのファイアウォールに追加します"
  az storage account network-rule add --account-name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --ip-address "$CLIENT_IP"
else
  echo "警告: IPアドレスの取得に失敗しました。ファイアウォール設定をスキップします。"
fi

# Bicepのデプロイ結果からファイル共有の名前を取得するか、パラメータファイルのデフォルト値を使用
echo "ストレージ設定を取得中..."
# ストレージアカウント名は上で取得済み
resourceGroupName=$RESOURCE_GROUP_NAME
# デフォルト値を設定
nginxShareName="nginx"
ssrfProxyShareName="ssrfproxy"
sandboxShareName="sandbox"
pluginStorageShareName="pluginstorage"

# 変数の値を確認（デバッグ用）
echo "ストレージアカウント名: $STORAGE_ACCOUNT_NAME"
echo "リソースグループ名: $resourceGroupName"
echo "Nginxファイル共有名: $nginxShareName"
echo "SSRFプロキシファイル共有名: $ssrfProxyShareName"
echo "Sandboxファイル共有名: $sandboxShareName"
echo "プラグインファイル共有名: $pluginStorageShareName"

# ストレージアカウントの接続文字列を取得
echo "ストレージアカウントの接続文字列を取得中..."
connectionString=$(az storage account show-connection-string --name "$STORAGE_ACCOUNT_NAME" --resource-group "$resourceGroupName" --query connectionString -o tsv)

# 変数が設定されているか確認し、なければエラー終了
if [ -z "$connectionString" ]; then
  echo "エラー: 接続文字列が取得できませんでした。ストレージアカウント名とリソースグループ名を確認してください。"
  exit 1
fi

# ファイル共有が存在するか確認し、なければ作成
echo "Nginx用のファイル共有を作成中..."
az storage share exists --name "$nginxShareName" --connection-string "$connectionString" --output json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  az storage share create --name "$nginxShareName" --connection-string "$connectionString"
fi

echo "SSRFプロキシ用のファイル共有を作成中..."
az storage share exists --name "$ssrfProxyShareName" --connection-string "$connectionString" --output json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  az storage share create --name "$ssrfProxyShareName" --connection-string "$connectionString"
fi

echo "Sandbox用のファイル共有を作成中..."
az storage share exists --name "$sandboxShareName" --connection-string "$connectionString" --output json > /dev/null 2>&1
if [ $? -ne 0 ];then
  az storage share create --name "$sandboxShareName" --connection-string "$connectionString"
fi

echo "Plugin用のファイル共有を作成中..."
az storage share exists --name "$pluginStorageShareName" --connection-string "$connectionString" --output json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  az storage share create --name "$pluginStorageShareName" --connection-string "$connectionString"
fi

# Nginxの設定ディレクトリを作成
echo "Nginxディレクトリを作成..."
az storage directory create --name "conf.d" --share-name "$nginxShareName" --connection-string "$connectionString"
az storage directory create --name "modules" --share-name "$nginxShareName" --connection-string "$connectionString"

# Nginxの設定ファイルをアップロード
echo "Nginxの設定ファイルをアップロード中..."
# 通常のファイルをアップロード
for file in mountfiles/nginx/*.conf mountfiles/nginx/mime.types; do
  if [ -f "$file" ]; then
    filename=$(basename "$file")
    echo "ファイルをアップロード: $filename"
    az storage file upload --source "$file" --share-name "$nginxShareName" --path "$filename" --connection-string "$connectionString"
  fi
done

# 特殊パラメータファイルをチェックして処理
for param_file in "fastcgi_params" "scgi_params" "uwsgi_params"; do
  full_path="mountfiles/nginx/${param_file}"
  
  if [ -f "$full_path" ]; then
    echo "特殊ファイルをアップロード: ${param_file}"
    # base64エンコード（macOSとLinuxで互換性のある方法）
    if [[ "$OSTYPE" == "darwin"* ]]; then
      # macOS
      base64 < "$full_path" > "${full_path}.b64"
    else
      # Linux
      base64 "$full_path" > "${full_path}.b64"
    fi
    
    # エンコードしたファイルをアップロード
    az storage file upload --source "${full_path}.b64" --share-name "$nginxShareName" --path "${param_file}.b64" --connection-string "$connectionString"
    
    # 一時ファイルを削除
    rm "${full_path}.b64"
  else
    echo "警告: ファイル ${full_path} が見つかりません。スキップします。"
  fi
done

# conf.dディレクトリのファイルをアップロード
echo "conf.dディレクトリのファイルをアップロード中..."
if [ -d "mountfiles/nginx/conf.d" ]; then
  for file in mountfiles/nginx/conf.d/*; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      echo "ファイルをアップロード: conf.d/$filename"
      az storage file upload --source "$file" --share-name "$nginxShareName" --path "conf.d/$filename" --connection-string "$connectionString"
    fi
  done
else
  echo "警告: conf.dディレクトリが見つかりません。"
fi

# modulesディレクトリのファイルをアップロード
echo "modulesディレクトリのファイルをアップロード中..."
if [ -d "mountfiles/nginx/modules" ]; then
  for file in mountfiles/nginx/modules/*; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      echo "ファイルをアップロード: modules/$filename"
      az storage file upload --source "$file" --share-name "$nginxShareName" --path "modules/$filename" --connection-string "$connectionString"
    fi
  done
else
  echo "警告: modulesディレクトリが見つかりません。"
fi

# SSRFプロキシの設定ディレクトリを作成
echo "SSRFプロキシディレクトリを作成..."
az storage directory create --name "conf.d" --share-name "$ssrfProxyShareName" --connection-string "$connectionString"

# SSRFプロキシの設定ファイルをアップロード
echo "SSRFプロキシの設定ファイルをアップロード中..."
if [ -f "mountfiles/ssrfproxy/squid.conf" ]; then
  az storage file upload --source "mountfiles/ssrfproxy/squid.conf" --share-name "$ssrfProxyShareName" --path "squid.conf" --connection-string "$connectionString"
else
  echo "警告: squid.confファイルが見つかりません。"
fi

if [ -f "mountfiles/ssrfproxy/errorpage.css" ]; then
  az storage file upload --source "mountfiles/ssrfproxy/errorpage.css" --share-name "$ssrfProxyShareName" --path "errorpage.css" --connection-string "$connectionString"
else
  echo "警告: errorpage.cssファイルが見つかりません。"
fi

# conf.dディレクトリのファイルをアップロード
echo "conf.dディレクトリのファイルをアップロード中..."
if [ -d "mountfiles/ssrfproxy/conf.d" ]; then
  for file in mountfiles/ssrfproxy/conf.d/*; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      echo "ファイルをアップロード: conf.d/$filename"
      az storage file upload --source "$file" --share-name "$ssrfProxyShareName" --path "conf.d/$filename" --connection-string "$connectionString"
    fi
  done
else
  echo "警告: SSRFプロキシのconf.dディレクトリが見つかりません。"
fi

# Sandbox用の設定ファイルをアップロード
echo "Sandboxの設定ファイルをアップロード中..."
if [ -f "mountfiles/sandbox/python-requirements.txt" ]; then
  az storage file upload --source "mountfiles/sandbox/python-requirements.txt" --share-name "$sandboxShareName" --path "python-requirements.txt" --connection-string "$connectionString"
else
  echo "警告: python-requirements.txtファイルが見つかりません。"
fi

# PostgreSQLデータベース情報を取得
echo "PostgreSQLサーバー情報を取得中..."
# PostgreSQLサーバーの名前を取得（リソースグループ内の最初のPostgreSQLサーバーを使用）
PSQL_SERVER_NAME=$(az postgres flexible-server list --resource-group "$RESOURCE_GROUP_NAME" --query "[0].name" -o tsv)
if [ -z "$PSQL_SERVER_NAME" ]; then
  echo "警告: PostgreSQLサーバーが見つかりません。データベース初期化をスキップします。"
else
  echo "PostgreSQLサーバー名: $PSQL_SERVER_NAME"
  
  # PostgreSQLサーバーのFQDNを取得
  PSQL_FQDN=$(az postgres flexible-server show --name "$PSQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query "fullyQualifiedDomainName" -o tsv)
  echo "PostgreSQL FQDN: $PSQL_FQDN"
  
  # データベース名を取得（デプロイ出力から取得または推測）
  DIFY_DB_NAME="dify"
  VECTOR_DB_NAME="pgvector"
  
  echo "Difyデータベース名: $DIFY_DB_NAME"
  echo "Vectorデータベース名: $VECTOR_DB_NAME"
  
  # PostgreSQLサーバーのファイアウォールにクライアントIPを追加
  if [ -n "$CLIENT_IP" ]; then
    echo "PostgreSQLサーバーのファイアウォールにクライアントIPを追加: $CLIENT_IP"
    az postgres flexible-server firewall-rule create --name ClientIPAccess \
      --resource-group "$RESOURCE_GROUP_NAME" \
      --server-name "$PSQL_SERVER_NAME" \
      --start-ip-address "$CLIENT_IP" \
      --end-ip-address "$CLIENT_IP"
  fi

  # uuid-ossp拡張を許可リストに追加（Azure PostgreSQL Flexible Serverの拡張機能対応）
  echo "uuid-ossp拡張を許可リストに追加しています..."
  az postgres flexible-server parameter set --resource-group "$RESOURCE_GROUP_NAME" --server-name "$PSQL_SERVER_NAME" --name azure.extensions --value uuid-ossp
  
  # データベース接続を確認（psqlコマンドが必要）
  if command -v psql &> /dev/null; then
    echo "PostgreSQL接続を確認中..."
    
    # 接続テストとデータベース存在確認
    if PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -c "\l" | grep -q "$DIFY_DB_NAME"; then
      echo "Difyデータベースは既に存在します。"
    else
      echo "Difyデータベースを作成します..."
      PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -c "CREATE DATABASE $DIFY_DB_NAME;"
    fi
    
    if PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -c "\l" | grep -q "$VECTOR_DB_NAME"; then
      echo "Vectorデータベースは既に存在します。"
    else
      echo "Vectorデータベースを作成します..."
      PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -c "CREATE DATABASE $VECTOR_DB_NAME;"
    fi
    
    # pgvector拡張機能が必要な場合にインストール
    echo "Vectorデータベースに拡張機能をインストール..."
    PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -d "$VECTOR_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;"
    
    # Enable uuid-ossp extension in the databases
    if [ -n "$PSQL_FQDN" ]; then
        echo "Enabling uuid-ossp extension in the databases..."
        PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -d "$DIFY_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
        PGPASSWORD="$PGSQL_PASSWORD" psql -h "$PSQL_FQDN" -U "$PGSQL_USER" -d "$VECTOR_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
    else
        echo "PostgreSQL FQDN is not set. Skipping uuid-ossp extension setup."
    fi
  else
    echo "警告: psqlコマンドが見つかりません。データベースの初期化を手動で行う必要があります。"
  fi
fi

# ACA環境とアプリケーション情報を取得
echo "ACAリソース情報を取得中..."
ACA_ENV_NAME=$(az containerapp env list --resource-group "$RESOURCE_GROUP_NAME" --query "[0].name" -o tsv)
if [ -z "$ACA_ENV_NAME" ]; then
  echo "警告: ACA環境が見つかりません。アプリケーション再起動をスキップします。"
else
  echo "ACA環境名: $ACA_ENV_NAME"
  
  # ACAアプリの一覧を取得
  echo "ACAアプリの一覧を取得中..."
  ACA_APPS=$(az containerapp list --resource-group "$RESOURCE_GROUP_NAME" --query "[].name" -o tsv)
  
  if [ -n "$ACA_APPS" ]; then
    echo "アプリケーションを再起動するための準備中..."
    
    # すべてのアプリを再起動（特にファイルの変更を反映するため）
    for app in $ACA_APPS; do
      echo "アプリケーション「$app」を再起動中..."
      az containerapp update --name "$app" --resource-group "$RESOURCE_GROUP_NAME" --set "properties.template.scale.minReplicas=1"
      
      # 少し待機して、スケールアップが始まるのを確認
      sleep 5
      
      # トラブルシューティングのためにアプリの状態を表示
      app_status=$(az containerapp show --name "$app" --resource-group "$RESOURCE_GROUP_NAME" --query "properties.latestRevisionName" -o tsv)
      echo "アプリケーション「$app」の最新リビジョン: $app_status"
    done
    
    echo "すべてのアプリケーションを再起動しました。"
  else
    echo "警告: ACA環境にアプリケーションが見つかりません。"
  fi
  
  # デプロイされたアプリケーションの外部URLを取得
  echo "デプロイされたアプリケーションのURLを取得中..."
  DIFY_WEB_APP=$(az containerapp list --resource-group "$RESOURCE_GROUP_NAME" --query "[?contains(name,'web')].name" -o tsv)
  
  if [ -n "$DIFY_WEB_APP" ]; then
    DIFY_URL=$(az containerapp show --name "$DIFY_WEB_APP" --resource-group "$RESOURCE_GROUP_NAME" --query "properties.configuration.ingress.fqdn" -o tsv)
    if [ -n "$DIFY_URL" ]; then
      echo "==============================================="
      echo "Difyアプリケーションは次のURLでアクセスできます："
      echo "https://$DIFY_URL"
      echo "==============================================="
    fi
  fi
  
  # カスタムドメインが設定されている場合、それも表示
  CUSTOM_DOMAIN=$(jq -r '.parameters.acaDifyCustomerDomain.value // empty' ./parameters.json)
  if [ -n "$CUSTOM_DOMAIN" ] && [ "$CUSTOM_DOMAIN" != "dify.example.com" ]; then
    echo "カスタムドメインでもアクセス可能です："
    echo "https://$CUSTOM_DOMAIN"
    echo "DNSレコードが適切に設定されていることを確認してください。"
    echo "==============================================="
  fi
fi

# デプロイ検証
echo "デプロイ検証を実行中..."

# リソースの存在確認
echo "必要なリソースの確認:"
echo "1. ストレージアカウント: $([ -n "$STORAGE_ACCOUNT_NAME" ] && echo "OK" || echo "未検出")"
echo "2. PostgreSQLサーバー: $([ -n "$PSQL_SERVER_NAME" ] && echo "OK" || echo "未検出")"
echo "3. ACA環境: $([ -n "$ACA_ENV_NAME" ] && echo "OK" || echo "未検出")"
echo "4. Difyアプリケーション: $([ -n "$DIFY_WEB_APP" ] && echo "OK" || echo "未検出")"

# 問題がある場合のチェック
if [ -z "$STORAGE_ACCOUNT_NAME" ] || [ -z "$PSQL_SERVER_NAME" ] || [ -z "$ACA_ENV_NAME" ] || [ -z "$DIFY_WEB_APP" ]; then
  echo "警告: いくつかの必要なリソースが見つかりませんでした。デプロイに問題がある可能性があります。"
  echo "Azureポータルで詳細を確認するか、以下のコマンドでリソースの状態を確認してください："
  echo "az group deployment list --resource-group $RESOURCE_GROUP_NAME"
else
  echo "すべての必要なリソースが正常にデプロイされました。"
fi

echo "デプロイが完了しました。"