### Topology
Front-end access:
- nginx -> Azure Container Apps (Serverless)

Back-end components:
- web -> Azure Container Apps (Serverless)
- api -> Azure Container Apps (Serverless)
- worker -> Azure Container Apps (minimum of 1 instance)
- sandbox -> Azure Container Apps (Serverless)
- ssrf_proxy -> Azure Container Apps (Serverless)
- db -> Azure Database for PostgreSQL
- vectordb -> Azure Database for PostgreSQL
- redis -> Azure Cache for Redis

### Azure CLI
Azure CLI のドキュメントは [こちら](https://learn.microsoft.com/ja-jp/cli/azure/) です。

2025年5月27日現在のバージョンは以下の通りです。
```bash
azure-cli                         2.73.0

core                              2.73.0
telemetry                          1.1.0

Extensions:
aks-preview                     18.0.0b3
alb                                2.0.0
azure-firewall                     1.2.3
connectedk8s                      1.10.7
containerapp                     1.1.0b5
init                               0.1.0
ssh                                2.0.6

Dependencies:
msal                              1.32.3
azure-mgmt-resource               23.3.0

Python location '/opt/homebrew/Cellar/azure-cli/2.73.0/libexec/bin/python'
Config directory '/Users/miho/.azure'
Extensions directory '/Users/miho/.azure/cliextensions'

Python (Darwin) 3.12.10 (main, Apr  8 2025, 11:35:47) [Clang 17.0.0 (clang-1700.0.13.3)]

Legal docs and information: aka.ms/AzureCliLegal


Your CLI is up-to-date.
```

とくに影響がありそうな azure CLI については、次のドキュメントを参照してください

- /knowledge/azcli_containerapp.md

