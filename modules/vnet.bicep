@description('リソースグループの場所')
param location string

@description('IPプレフィックス')
param ipPrefix string

// 仮想ネットワークを作成
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet-${location}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '${ipPrefix}.0.0/16'
      ]
    }
    subnets: []
  }
}

// プライベートリンク用サブネット
resource privateLinkSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'PrivateLinkSubnet'
  parent: vnet
  properties: {
    addressPrefix: '${ipPrefix}.0.0/24'  // 10.99.0.0/24 に変更
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

// ACA用サブネット (/23は2つの連続する/24と同等)
resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'ACASubnet'
  parent: vnet
  properties: {
    addressPrefix: '${ipPrefix}.2.0/23'  // 10.99.2.0/23 (10.99.2.0/24 + 10.99.3.0/24の範囲)
    delegations: []
  }
  dependsOn: [
    privateLinkSubnet
  ]
}

// PostgreSQL用サブネット
resource postgresSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'PostgresSubnet'
  parent: vnet
  properties: {
    addressPrefix: '${ipPrefix}.4.0/24'  // 10.99.4.0/24 に変更 (ACASUbnetと重複しないよう変更)
    serviceEndpoints: [
      {
        service: 'Microsoft.Storage'
      }
    ]
    delegations: [
      {
        name: 'postgres-delegation'
        properties: {
          serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
        }
      }
    ]
  }
  dependsOn: [
    acaSubnet
  ]
}

// 出力
output vnetId string = vnet.id
output vnetName string = vnet.name
output privateLinkSubnetId string = privateLinkSubnet.id
output acaSubnetId string = acaSubnet.id
output postgresSubnetId string = postgresSubnet.id
