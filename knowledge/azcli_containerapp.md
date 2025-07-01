
```bash
az containerapp --help

Group
    az containerapp : Manage Azure Container Apps.

Subgroups:
    add-on                   [Preview] : Commands to manage add-ons available within the
                                         environment.
    arc                      [Preview] : Install prerequisites for Kubernetes cluster on
                                         Arc.
    auth                               : Manage containerapp authentication and authorization.
    compose                            : Commands to create Azure Container Apps from Compose
                                         specifications.
    connected-env            [Preview] : Commands to manage Container Apps Connected
                                         environments for use with Arc enabled Container Apps.
    connection                         : Commands to manage containerapp connections.
    dapr                               : Commands to manage Dapr. To manage Dapr components, see `az
                                         containerapp env dapr-component`.
    env                                : Commands to manage Container Apps environments.
    github-action                      : Commands to manage GitHub Actions.
    hostname                           : Commands to manage hostnames of a container app.
    identity                           : Commands to manage managed identities.
    ingress                            : Commands to manage ingress and traffic-splitting.
    java                               : Commands to manage Java workloads.
    job                                : Commands to manage Container Apps jobs.
    label-history            [Preview] : Show the history for one or more labels on the
                                         Container App.
    logs                               : Show container app logs.
    patch                    [Preview] : Patch Azure Container Apps. Patching is only
                                         available for the apps built using the source to cloud
                                         feature. See https://aka.ms/aca-local-source-to-cloud.
    registry                 [Preview] : Commands to manage container registry information.
    replica                            : Manage container app replicas.
    resiliency               [Preview] : Commands to manage resiliency policies for a
                                         container app.
    revision                           : Commands to manage revisions.
    secret                             : Commands to manage secrets.
    session                            : Commands to manage sessions.To learn more about individual
                                         commands under each subgroup run containerapp session
                                         [subgroup name] --help.
    sessionpool                        : Commands to manage session pools.
    ssl                                : Upload certificate to a managed environment, add hostname
                                         to an app in that environment, and bind the certificate to
                                         the hostname.

Commands:
    browse                             : Open a containerapp in the browser, if possible.
    create                             : Create a container app.
    debug                    [Preview] : Open an SSH-like interactive shell within a
                                         container app debug console.
    delete                             : Delete a container app.
    exec                               : Open an SSH-like interactive shell within a container app
                                         replica.
    list                               : List container apps.
    list-usages                        : List usages of subscription level quotas in specific
                                         region.
    show                               : Show details of a container app.
    show-custom-domain-verification-id : Show the verification id for binding app or environment
                                         custom domains.
    up                                 : Create or update a container app as well as any associated
                                         resources (ACR, resource group, container apps environment,
                                         GitHub Actions, etc.).
    update                             : Update a container app. In multiple revisions mode, create
                                         a new revision based on the latest revision.

To search AI knowledge base for examples, use: az find "az containerapp"
```


作成
```bash
az containerapp create --help                             zsh   100  15:16:05 
The behavior of this command has been altered by the following extension: containerapp

Command
    az containerapp create : Create a container app.

Arguments
    --name -n                                                     [Required] : The name of the
                                                                               Containerapp. A name
                                                                               must consist of lower
                                                                               case alphanumeric
                                                                               characters or '-',
                                                                               start with a letter,
                                                                               end with an
                                                                               alphanumeric
                                                                               character, cannot
                                                                               have '--', and must
                                                                               be less than 32
                                                                               characters.
    --resource-group -g                                           [Required] : Name of resource
                                                                               group. You can
                                                                               configure the default
                                                                               group using `az
                                                                               configure --defaults
                                                                               group=<name>`.
    --allow-insecure                                                         : Allow insecure
                                                                               connections for
                                                                               ingress traffic.
                                                                               Allowed values:
                                                                               false, true.
    --artifact                                                     [Preview] : Local path
                                                                               to the application
                                                                               artifact for building
                                                                               the container image.
                                                                               See the supported
                                                                               artifacts here: https
                                                                               ://aka.ms/SourceToClo
                                                                               udSupportedArtifacts.
        Argument '--artifact' is in preview and under development. Reference and support
        levels: https://aka.ms/CLI_refstatus
    --build-env-vars                                               [Preview] : A list of
                                                                               environment
                                                                               variable(s) for the
                                                                               build. Space-
                                                                               separated values in
                                                                               'key=value' format.
        Argument '--build-env-vars' is in preview and under development. Reference and support
        levels: https://aka.ms/CLI_refstatus
    --environment                                                            : Name or resource ID
                                                                               of the container
                                                                               app's environment.
    --environment-type                                             [Preview] : Type of
                                                                               environment.  Allowed
                                                                               values: connected,
                                                                               managed.  Default:
                                                                               managed.
        Argument '--environment-type' is in preview and under development. Reference and
        support levels: https://aka.ms/CLI_refstatus
    --kind                                                         [Preview] : Set to
                                                                               'functionapp' to get
                                                                               built in support and
                                                                               autoscaling to run
                                                                               Azure functions on
                                                                               Azure Container apps.
        Argument '--kind' is in preview and under development. Reference and support levels:
        https://aka.ms/CLI_refstatus
    --max-inactive-revisions                                       [Preview] : Max inactive
                                                                               revisions a Container
                                                                               App can have.
        Argument '--max-inactive-revisions' is in preview and under development. Reference and
        support levels: https://aka.ms/CLI_refstatus
    --no-wait                                                                : Do not wait for the
                                                                               long-running
                                                                               operation to finish.
    --secret-volume-mount                                                    : Path to mount all
                                                                               secrets e.g.
                                                                               mnt/secrets.
    --source                                                       [Preview] : Local
                                                                               directory path
                                                                               containing the
                                                                               application source
                                                                               and Dockerfile for
                                                                               building the
                                                                               container image.
                                                                               Preview: If no
                                                                               Dockerfile is
                                                                               present, a container
                                                                               image is generated
                                                                               using buildpacks. If
                                                                               Docker is not running
                                                                               or buildpacks cannot
                                                                               be used, Oryx will be
                                                                               used to generate the
                                                                               image. See the
                                                                               supported Oryx
                                                                               runtimes here: https:
                                                                               //aka.ms/SourceToClou
                                                                               dSupportedVersions.
        Argument '--source' is in preview and under development. Reference and support levels:
        https://aka.ms/CLI_refstatus
    --tags                                                                   : Space-separated tags:
                                                                               key[=value]
                                                                               [key[=value] ...].
                                                                               Use '' to clear
                                                                               existing tags.
    --target-label                                                 [Preview] : The label to
                                                                               apply to new
                                                                               revisions. Required
                                                                               for revisions-mode
                                                                               'labels'.
        Argument '--target-label' is in preview and under development. Reference and support
        levels: https://aka.ms/CLI_refstatus
    --termination-grace-period --tgp                                         : Duration in seconds a
                                                                               replica is given to
                                                                               gracefully shut down
                                                                               before it is
                                                                               forcefully
                                                                               terminated. (Default:
                                                                               30).
    --workload-profile-name -w                                               : Name of the workload
                                                                               profile to run the
                                                                               app on.
    --yaml                                                                   : Path to a .yaml file
                                                                               with the
                                                                               configuration of a
                                                                               container app. All
                                                                               other parameters will
                                                                               be ignored. For an
                                                                               example, see  https:/
                                                                               /learn.microsoft.com/
                                                                               azure/container-
                                                                               apps/azure-resource-
                                                                               manager-api-
                                                                               spec#examples.

Configuration Arguments
    --registry-identity                                                      : The managed identity
                                                                               with which to
                                                                               authenticate to the
                                                                               Azure Container
                                                                               Registry (instead of
                                                                               username/password).
                                                                               Use 'system' for a
                                                                               system-defined
                                                                               identity, Use
                                                                               'system-environment'
                                                                               for an environment
                                                                               level system-defined
                                                                               identity or a
                                                                               resource id for a
                                                                               user-defined environm
                                                                               ent/containerapp
                                                                               level identity. The
                                                                               managed identity
                                                                               should have been
                                                                               assigned acrpull
                                                                               permissions on the
                                                                               ACR before deployment
                                                                               (use 'az role
                                                                               assignment create
                                                                               --role acrpull ...').
    --registry-password                                                      : The password to log
                                                                               in to container
                                                                               registry. If stored
                                                                               as a secret, value
                                                                               must start with
                                                                               'secretref:' followed
                                                                               by the secret name.
    --registry-server                                                        : The container
                                                                               registry server
                                                                               hostname, e.g. myregi
                                                                               stry.azurecr.io.
    --registry-username                                                      : The username to log
                                                                               in to container
                                                                               registry.
    --revisions-mode                                                         : The active revisions
                                                                               mode for the
                                                                               container app.
                                                                               Allowed values:
                                                                               labels, multiple,
                                                                               single.  Default:
                                                                               single.
    --secrets -s                                                             : A list of secret(s)
                                                                               for the container
                                                                               app. Space-separated
                                                                               values in 'key=value'
                                                                               format.

Container Arguments
    --args                                                                   : A list of container
                                                                               startup command
                                                                               argument(s). Space-
                                                                               separated values e.g.
                                                                               "-c" "mycommand".
                                                                               Empty string to clear
                                                                               existing values.
    --command                                                                : A list of supported
                                                                               commands on the
                                                                               container that will
                                                                               executed during
                                                                               startup. Space-
                                                                               separated values e.g.
                                                                               "/bin/queue"
                                                                               "mycommand". Empty
                                                                               string to clear
                                                                               existing values.
    --container-name                                                         : Name of the
                                                                               container.
    --cpu                                                                    : Required CPU in cores
                                                                               from 0.25 - 2.0, e.g.
                                                                               0.5.
    --env-vars                                                               : A list of environment
                                                                               variable(s) for the
                                                                               container. Space-
                                                                               separated values in
                                                                               'key=value' format.
                                                                               Empty string to clear
                                                                               existing values.
                                                                               Prefix value with
                                                                               'secretref:' to
                                                                               reference a secret.
    --image -i                                                               : Container image, e.g.
                                                                               publisher/image-
                                                                               name:tag.
    --memory                                                                 : Required memory from
                                                                               0.5 - 4.0 ending with
                                                                               "Gi", e.g. 1.0Gi.
    --revision-suffix                                                        : User friendly suffix
                                                                               that is appended to
                                                                               the revision name.

Dapr Arguments
    --dal --dapr-enable-api-logging                                          : Enable API logging
                                                                               for the Dapr sidecar.
    --dapr-app-id                                                            : The Dapr application
                                                                               identifier.
    --dapr-app-port                                                          : The port Dapr uses to
                                                                               talk to the
                                                                               application.
    --dapr-app-protocol                                                      : The protocol Dapr
                                                                               uses to talk to the
                                                                               application.  Allowed
                                                                               values: grpc, http.
    --dapr-http-max-request-size --dhmrs                                     : Increase max size of
                                                                               request body http and
                                                                               grpc servers
                                                                               parameter in MB to
                                                                               handle uploading of
                                                                               big files.
    --dapr-http-read-buffer-size --dhrbs                                     : Dapr max size of http
                                                                               header read buffer in
                                                                               KB to handle when
                                                                               sending multi-KB
                                                                               headers..
    --dapr-log-level                                                         : Set the log level for
                                                                               the Dapr sidecar.
                                                                               Allowed values:
                                                                               debug, error, info,
                                                                               warn.
    --enable-dapr                                                            : Boolean indicating if
                                                                               the Dapr side car is
                                                                               enabled.  Allowed
                                                                               values: false, true.

GitHub Repository Arguments
    --branch -b                                                    [Preview] : Branch in
                                                                               the provided GitHub
                                                                               repository. Assumed
                                                                               to be the GitHub
                                                                               repository's default
                                                                               branch if not
                                                                               specified.
        Argument '--branch' is in preview and under development. Reference and support levels:
        https://aka.ms/CLI_refstatus
    --context-path                                                 [Preview] : Path in the
                                                                               repository to run
                                                                               docker build.
                                                                               Defaults to "./".
                                                                               Dockerfile is assumed
                                                                               to be named
                                                                               "Dockerfile" and in
                                                                               this directory.
        Argument '--context-path' is in preview and under development. Reference and support
        levels: https://aka.ms/CLI_refstatus
    --repo                                                         [Preview] : Create an
                                                                               app via GitHub
                                                                               Actions in the
                                                                               format: https://githu
                                                                               b.com/owner/repositor
                                                                               y-name or
                                                                               owner/repository-
                                                                               name.
        Argument '--repo' is in preview and under development. Reference and support levels:
        https://aka.ms/CLI_refstatus
    --service-principal-client-id --sp-cid                         [Preview] : The service
                                                                               principal client ID.
                                                                               Used by GitHub
                                                                               Actions to
                                                                               authenticate with
                                                                               Azure.
        Argument '--service-principal-client-id' is in preview and under development. Reference
        and support levels: https://aka.ms/CLI_refstatus
    --service-principal-client-secret --sp-sec                     [Preview] : The service
                                                                               principal client
                                                                               secret. Used by
                                                                               GitHub Actions to
                                                                               authenticate with
                                                                               Azure.
        Argument '--service-principal-client-secret' is in preview and under development.
        Reference and support levels: https://aka.ms/CLI_refstatus
    --service-principal-tenant-id --sp-tid                         [Preview] : The service
                                                                               principal tenant ID.
                                                                               Used by GitHub
                                                                               Actions to
                                                                               authenticate with
                                                                               Azure.
        Argument '--service-principal-tenant-id' is in preview and under development. Reference
        and support levels: https://aka.ms/CLI_refstatus
    --token                                                        [Preview] : A Personal
                                                                               Access Token with
                                                                               write access to the
                                                                               specified repository.
                                                                               For more information:
                                                                               https://help.github.c
                                                                               om/en/github/authenti
                                                                               cating-to-
                                                                               github/creating-a-
                                                                               personal-access-
                                                                               token-for-the-
                                                                               command-line. If not
                                                                               provided or not found
                                                                               in the cache (and
                                                                               using --repo), a
                                                                               browser page will be
                                                                               opened to
                                                                               authenticate with
                                                                               Github.
        Argument '--token' is in preview and under development. Reference and support levels:
        https://aka.ms/CLI_refstatus

Identity Arguments
    --system-assigned                                                        : Boolean indicating
                                                                               whether to assign
                                                                               system-assigned
                                                                               identity.
    --user-assigned                                                          : Space-separated user
                                                                               identities to be
                                                                               assigned.

Ingress Arguments
    --exposed-port                                                           : Additional exposed
                                                                               port. Only supported
                                                                               by tcp transport
                                                                               protocol. Must be
                                                                               unique per
                                                                               environment if the
                                                                               app ingress is
                                                                               external.
    --ingress                                                                : The ingress type.
                                                                               Allowed values:
                                                                               external, internal.
    --target-port                                                            : The application port
                                                                               used for ingress
                                                                               traffic.
    --transport                                                              : The transport
                                                                               protocol used for
                                                                               ingress traffic.
                                                                               Allowed values: auto,
                                                                               http, http2, tcp.
                                                                               Default: auto.

Runtime Arguments
    --enable-java-agent                                                      : Boolean indicating
                                                                               whether to enable
                                                                               Java agent for the
                                                                               app. Only applicable
                                                                               for Java runtime.
                                                                               Allowed values:
                                                                               false, true.
    --enable-java-metrics                                                    : Boolean indicating
                                                                               whether to enable
                                                                               Java metrics for the
                                                                               app. Only applicable
                                                                               for Java runtime.
                                                                               Allowed values:
                                                                               false, true.
    --runtime                                                                : The runtime of the
                                                                               container app.
                                                                               Allowed values:
                                                                               generic, java.

Scale Arguments
    --max-replicas                                                           : The maximum number of
                                                                               replicas.
    --min-replicas                                                           : The minimum number of
                                                                               replicas.
    --scale-rule-auth --sra                                                  : Scale rule auth
                                                                               parameters. Auth
                                                                               parameters must be in
                                                                               format "{triggerParam
                                                                               eter}={secretRef} {tr
                                                                               iggerParameter}={secr
                                                                               etRef} ...".
    --scale-rule-http-concurrency --scale-rule-tcp-concurrency --srhc --srtc : The maximum number of
                                                                               concurrent requests
                                                                               before scale out.
                                                                               Only supported for
                                                                               http and tcp scale
                                                                               rules.
    --scale-rule-identity --sri                                    [Preview] : Resource ID
                                                                               of a managed identity
                                                                               to authenticate with
                                                                               Azure scaler
                                                                               resource(storage
                                                                               account/eventhub or
                                                                               else), or System to
                                                                               use a system-assigned
                                                                               identity.
        Argument '--scale-rule-identity' is in preview and under development. Reference and
        support levels: https://aka.ms/CLI_refstatus
    --scale-rule-metadata --srm                                              : Scale rule metadata.
                                                                               Metadata must be in
                                                                               format "{key}={value}
                                                                               {key}={value} ...".
    --scale-rule-name --srn                                                  : The name of the scale
                                                                               rule.
    --scale-rule-type --srt                                                  : The type of the scale
                                                                               rule. Default: http.
                                                                               For more information
                                                                               please visit https://
                                                                               learn.microsoft.com/a
                                                                               zure/container-
                                                                               apps/scale-app#scale-
                                                                               triggers.

Service Binding Arguments
    --bind                                                         [Preview] : Space
                                                                               separated list of
                                                                               services, bindings or
                                                                               Java components to be
                                                                               connected to this
                                                                               app. e.g. SVC_NAME1[:
                                                                               BIND_NAME1] SVC_NAME2
                                                                               [:BIND_NAME2]...
        Argument '--bind' is in preview and under development. Reference and support levels:
        https://aka.ms/CLI_refstatus
    --customized-keys                                              [Preview] : The
                                                                               customized keys used
                                                                               to change default
                                                                               configuration names.
                                                                               Key is the original
                                                                               name, value is the
                                                                               customized name.
        Argument '--customized-keys' is in preview and under development. Reference and support
        levels: https://aka.ms/CLI_refstatus

Global Arguments
    --debug                                                                  : Increase logging
                                                                               verbosity to show all
                                                                               debug logs.
    --help -h                                                                : Show this help
                                                                               message and exit.
    --only-show-errors                                                       : Only show errors,
                                                                               suppressing warnings.
    --output -o                                                              : Output format.
                                                                               Allowed values: json,
                                                                               jsonc, none, table,
                                                                               tsv, yaml, yamlc.
                                                                               Default: json.
    --query                                                                  : JMESPath query
                                                                               string. See
                                                                               http://jmespath.org/
                                                                               for more information
                                                                               and examples.
    --subscription                                                           : Name or ID of
                                                                               subscription. You can
                                                                               configure the default
                                                                               subscription using
                                                                               `az account set -s
                                                                               NAME_OR_ID`.
    --verbose                                                                : Increase logging
                                                                               verbosity. Use
                                                                               --debug for full
                                                                               debug logs.

Examples
    Create a container app and retrieve its fully qualified domain name.
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image myregistry.azurecr.io/my-app:v1.0 --environment MyContainerappEnv \
            --ingress external --target-port 80 \
            --registry-server myregistry.azurecr.io --registry-username myregistry --registry-
        password $REGISTRY_PASSWORD \
            --query properties.configuration.ingress.fqdn


    Create a container app with resource requirements and replica count limits.
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image nginx --environment MyContainerappEnv \
            --cpu 0.5 --memory 1.0Gi \
            --min-replicas 4 --max-replicas 8


    Create a container app with secrets and environment variables.
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-app:v1.0 --environment MyContainerappEnv \
            --secrets mysecret=secretvalue1 anothersecret="secret value 2" \
            --env-vars GREETING="Hello, world" SECRETENV=secretref:anothersecret


    Create a container app using a YAML configuration. Example YAML configuration -
    https://aka.ms/azure-container-apps-yaml
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --environment MyContainerappEnv \
            --yaml "path/to/yaml/file.yml"


    Create a container app with an http scale rule
        az containerapp create -n myapp -g mygroup --environment myenv --image nginx \
            --scale-rule-name my-http-rule \
            --scale-rule-http-concurrency 50


    Create a container app with a custom scale rule
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-queue-processor --environment MyContainerappEnv \
            --min-replicas 4 --max-replicas 8 \
            --scale-rule-name queue-based-autoscaling \
            --scale-rule-type azure-queue \
            --scale-rule-metadata "accountName=mystorageaccountname" \
                                  "cloud=AzurePublicCloud" \
                                  "queueLength=5" "queueName=foo" \
            --scale-rule-auth "connection=my-connection-string-secret-name"


    Create a container app with a custom scale rule using identity to authenticate
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-queue-processor --environment MyContainerappEnv \
            --user-assigned myUserIdentityResourceId --min-replicas 4 --max-replicas 8 \
            --scale-rule-name queue-based-autoscaling \
            --scale-rule-type azure-queue \
            --scale-rule-metadata "accountName=mystorageaccountname" \
                                  "cloud=AzurePublicCloud" \
                                  "queueLength=5" "queueName=foo" \
            --scale-rule-identity myUserIdentityResourceId


    Create a container app with secrets and mounts them in a volume.
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-app:v1.0 --environment MyContainerappEnv \
            --secrets mysecret=secretvalue1 anothersecret="secret value 2" \
            --secret-volume-mount "mnt/secrets"


    Create a container app hosted on a Connected Environment.
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-app:v1.0 --environment MyContainerappConnectedEnv \
            --environment-type connected


    Create a container app from a new GitHub Actions workflow in the provided GitHub repository
        az containerapp create -n my-containerapp -g MyResourceGroup \
        --environment MyContainerappEnv --registry-server MyRegistryServer \
        --registry-user MyRegistryUser --registry-pass MyRegistryPass \
        --repo https://github.com/myAccount/myRepo


    Create a Container App from the provided application source
        az containerapp create -n my-containerapp -g MyResourceGroup \
        --environment MyContainerappEnv --registry-server MyRegistryServer \
        --registry-user MyRegistryUser --registry-pass MyRegistryPass \
        --source .


    Create a container app with java metrics enabled
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-app:v1.0 --environment MyContainerappEnv \
            --enable-java-metrics


    Create a container app with java agent enabled
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-app:v1.0 --environment MyContainerappEnv \
            --enable-java-agent


    Create a container app with kind as functionapp
        az containerapp create -n my-containerapp -g MyResourceGroup \
            --image my-app:v1.0 --environment MyContainerappEnv \
            --kind functionapp


To search AI knowledge base for examples, use: az find "az containerapp create"
```
