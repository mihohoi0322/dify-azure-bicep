@description('リソースの場所')
param location string

@description('Redis名')
param redisName string

@description('プライベートリンクサブネットID')
param privateLinkSubnetId string

@description('仮想ネットワークID')
param vnetId string

// プライベートDNSゾーン
resource redisDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.cache.windows.net'
  location: 'global'
}

// 仮想ネットワークリンク
resource redisVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'redis-dns-link'
  parent: redisDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// Redisキャッシュ
resource redisCache 'Microsoft.Cache/Redis@2023-08-01' = {
  name: redisName
  location: location
  properties: {
    sku: {
      name: 'Standard'
      family: 'C'
      capacity: 0
    }
    enableNonSslPort: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    redisVersion: '6'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'
    }
  }
}

// プライベートエンドポイント
resource redisPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-redis'
  location: location
  properties: {
    subnet: {
      id: privateLinkSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-redis'
        properties: {
          privateLinkServiceId: redisCache.id
          groupIds: [
            'redisCache'
          ]
        }
      }
    ]
  }
}

// プライベートエンドポイントDNSグループ
resource privateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  name: 'pdz-stor'
  parent: redisPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: redisDnsZone.id
        }
      }
    ]
  }
}

// 出力
output redisHostName string = redisCache.properties.hostName
output redisPrimaryKey string = listKeys(redisCache.id, redisCache.apiVersion).primaryKey
