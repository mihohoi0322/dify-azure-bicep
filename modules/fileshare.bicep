param storageAccountName string
param shareName string
param localMountDir string
param quota int = 50

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2022-05-01' = {
  name: 'default'
  parent: storageAccount
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2022-05-01' = {
  name: shareName
  parent: fileService
  properties: {
    shareQuota: quota
  }
}

// ファイル共有に対するファイルアップロードはBicepでは直接サポートされていないため、
// デプロイ後のスクリプトまたはAzure CLIコマンドで実行する必要があります

output shareName string = fileShare.name
output shareId string = fileShare.id
