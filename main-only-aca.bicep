targetScope = 'subscription'

@description('デプロイするリージョン')
param location string = 'japaneast'

@description('リソースグループ名のプレフィックス')
param resourceGroupPrefix string = 'rg'

@description('IPアドレスのプレフィックス')
param ipPrefix string = '10.99'

@description('ストレージアカウント名のベース')
param storageAccountBase string = 'acadifytest'

@description('ストレージアカウントのコンテナ名')
param storageAccountContainer string = 'dfy'

@description('Redis名のベース')
param redisNameBase string = 'acadifyredis'

@description('PostgreSQL名のベース')
param psqlFlexibleBase string = 'acadifypsql'

@description('PostgreSQLユーザー名')
param pgsqlUser string = 'user'

@description('PostgreSQLパスワード')
@secure()
param pgsqlPassword string = '#QWEASDasdqwe'

@description('ACA環境名')
param acaEnvName string = 'dify-aca-env'

@description('ACA Log Analyticsワークスペース名')
param acaLogaName string = 'dify-loga'

@description('独自証明書を提供するかどうか')
param isProvidedCert bool = true

@description('証明書の内容 (Base64エンコード)')
@secure()
param acaCertBase64Value string = ''

@description('証明書のパスワード')
@secure()
param acaCertPassword string = 'password'

@description('Difyのカスタムドメイン')
param acaDifyCustomerDomain string = 'dify.example.com'

@description('ACAアプリの最小インスタンス数')
param acaAppMinCount int = 0

@description('ACAを有効にするかどうか')
param isAcaEnabled bool = false

@description('Dify APIイメージ')
param difyApiImage string = 'langgenius/dify-api:1.1.2'

@description('Dify サンドボックスイメージ')
param difySandboxImage string = 'langgenius/dify-sandbox:0.2.10'

@description('Dify Webイメージ')
param difyWebImage string = 'langgenius/dify-web:1.1.2'

@description('Dify Plugin Daemonイメージ')
param difyPluginDaemonImage string = 'langgenius/dify-plugin-daemon:0.0.6-local'

@description('ACAサブネットID')
param acaSubnetId string

@description('ストレージアカウントキー')
@secure()
param storageAccountKey string

@description('ストレージアカウント名')
param storageAccountName string

@description('Nginxファイル共有名')
param nginxShareName string

@description('Sandboxファイル共有名')
param sandboxShareName string

@description('SSRFプロキシファイル共有名')
param ssrfproxyShareName string

@description('プラグインファイル共有名')
param pluginStorageShareName string

@description('PostgreSQLサーバーFQDN')
param postgresServerFqdn string

@description('Redisホスト名')
param redisHostName string

@description('Redisプライマリキー')
@secure()
param redisPrimaryKey string

@description('Blobエンドポイント')
param blobEndpoint string

// リソースグループを作成
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: '${resourceGroupPrefix}-${location}'
  location: location
}

// 一意のリソース名のためのハッシュを生成
var rgNameHex = uniqueString(subscription().id, rg.name)

// ACA環境とアプリをデプロイ
module acaModule './modules/aca-env.bicep' = {
  name: 'acaEnvDeploy'
  scope: rg
  params: {
    location: location
    acaEnvName: acaEnvName
    acaLogaName: acaLogaName
    acaSubnetId: acaSubnetId
    isProvidedCert: isProvidedCert
    acaCertBase64Value: acaCertBase64Value
    acaCertPassword: acaCertPassword
    acaDifyCustomerDomain: acaDifyCustomerDomain
    acaAppMinCount: acaAppMinCount
    storageAccountName: storageAccountName
    storageAccountKey: storageAccountKey
    storageContainerName: storageAccountContainer
    nginxShareName: nginxShareName
    sandboxShareName: sandboxShareName
    ssrfProxyShareName: ssrfproxyShareName
    pluginStorageShareName: pluginStorageShareName
    postgresServerFqdn: postgresServerFqdn
    postgresAdminLogin: pgsqlUser
    postgresAdminPassword: pgsqlPassword
    postgresDifyDbName: 'dify'
    postgresVectorDbName: 'vector'
    redisHostName: redisHostName
    redisPrimaryKey: redisPrimaryKey
    difyApiImage: difyApiImage
    difySandboxImage: difySandboxImage
    difyWebImage: difyWebImage
    difyPluginDaemonImage: difyPluginDaemonImage
    blobEndpoint: blobEndpoint
  }
}

// デプロイ後の出力
output difyAppUrl string = acaModule.outputs.difyAppUrl
