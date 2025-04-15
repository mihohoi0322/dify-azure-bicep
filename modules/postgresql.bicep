@description('リソースの場所')
param location string

@description('PostgreSQLサーバー名')
param serverName string

@description('PostgreSQL管理者ログイン')
param administratorLogin string

@description('PostgreSQL管理者パスワード')
@secure()
param administratorLoginPassword string

@description('PostgreSQLサブネットID')
param postgresSubnetId string

@description('仮想ネットワークID')
param vnetId string

// プライベートDNSゾーン
resource postgresDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
}

// 仮想ネットワークリンク
resource postgresVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'postgres-dns-link'
  parent: postgresDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// PostgreSQL Flexible Server
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-03-01-preview' = {
  name: serverName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '14'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: postgresSubnetId
      privateDnsZoneArmResourceId: postgresDnsZone.id
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

// Difyデータベース
resource difyDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-03-01-preview' = {
  name: 'dify'
  parent: postgresServer
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Vectorデータベース
resource vectorDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-03-01-preview' = {
  name: 'vector'
  parent: postgresServer
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// 注: パラメータ設定はdeploy.shで行います
// PGVector拡張と必要な拡張機能の設定はBicepから削除
// shared_preload_librariesの設定もBicepから削除

// 出力
output serverFqdn string = postgresServer.properties.fullyQualifiedDomainName
output difyDbName string = difyDatabase.name
output vectorDbName string = vectorDatabase.name
