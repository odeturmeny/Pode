function ConvertTo-PodeOAContentTypeSchema
{
    param(
        [Parameter(ValueFromPipeline=$true)]
        [hashtable]
        $Schemas
    )

    if (Test-PodeIsEmpty $Schemas) {
        return $null
    }

    # ensure all content types are valid
    foreach ($type in $Schemas.Keys) {
        if ($type -inotmatch '^\w+\/[\w\.\+-]+$') {
            throw "Invalid content-type found for schema: $($type)"
        }
    }

    # convert each schema to openapi format
    return (ConvertTo-PodeOAObjectSchema -Schemas $Schemas)
}

function ConvertTo-PodeOAHeaderSchema
{
    param(
        [Parameter(ValueFromPipeline=$true)]
        [hashtable]
        $Schemas
    )

    if (Test-PodeIsEmpty $Schemas) {
        return $null
    }

    # convert each schema to openapi format
    return (ConvertTo-PodeOAObjectSchema -Schemas $Schemas)
}

function ConvertTo-PodeOAObjectSchema
{
    param(
        [Parameter(ValueFromPipeline=$true)]
        [hashtable]
        $Schemas
    )

    # convert each schema to openapi format
    $obj = @{}
    foreach ($type in $Schemas.Keys) {
        $obj[$type] = @{
            schema = $null
        }

        # add a shared component schema reference
        if ($Schemas[$type] -is [string]) {
            if (!(Test-PodeOAComponentSchema -Name $Schemas[$type])) {
                throw "The OpenApi component schema doesn't exist: $($Schemas[$type])"
            }

            $obj[$type].schema = @{
                '$ref' = "#/components/schemas/$($Schemas[$type])"
            }
        }

        # add a set schema object
        else {
            $obj[$type].schema = ($Schemas[$type] | ConvertTo-PodeOASchemaProperty)
        }
    }

    return $obj
}

function Test-PodeOAComponentSchema
{
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $Name
    )

    return $PodeContext.Server.OpenAPI.components.schemas.ContainsKey($Name)
}

function Test-PodeOAComponentResponse
{
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $Name
    )

    return $PodeContext.Server.OpenAPI.components.responses.ContainsKey($Name)
}

function Test-PodeOAComponentRequestBody
{
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $Name
    )

    return $PodeContext.Server.OpenAPI.components.requestBodies.ContainsKey($Name)
}

function Test-PodeOAComponentParameter
{
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $Name
    )

    return $PodeContext.Server.OpenAPI.components.parameters.ContainsKey($Name)
}

function ConvertTo-PodeOASchemaProperty
{
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [hashtable]
        $Property
    )

    # base schema type
    $schema = @{
        type = $Property.type
        format = $Property.format
    }

    # are we using an array?
    if ($Property.array) {
        $Property.array = $false

        $schema = @{
            type = 'array'
            items = ($Property | ConvertTo-PodeOASchemaProperty)
        }
    }

    # are we using an object?
    if ($Property.object) {
        $Property.object = $false

        $schema = @{
            type = 'object'
            properties = (ConvertTo-PodeOASchemaObjectProperty -Properties $Property)
        }

        if ($Property.required) {
            $schema['required'] = @($Property.name)
        }
    }

    if ($Property.type -ieq 'object') {
        $schema['properties'] = (ConvertTo-PodeOASchemaObjectProperty -Properties $Property.properties)
        $schema['required'] = @(($Property.properties | Where-Object { $_.required }).name)
    }

    return $schema
}

function ConvertTo-PodeOASchemaObjectProperty
{
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]
        $Properties
    )

    $schema = @{}

    foreach ($prop in $Properties) {
        $schema[$prop.name] = ($prop | ConvertTo-PodeOASchemaProperty)
    }

    return $schema
}

function Get-PodeOpenApiDefinitionInternal
{
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $Title,

        [Parameter()]
        [string]
        $Version,

        [Parameter()]
        [string]
        $Description,

        [Parameter()]
        [string]
        $RouteFilter,

        [Parameter()]
        $Protocol,

        [Parameter()]
        $Address,

        [switch]
        $RestrictRoutes
    )

    # set the openapi version
    $def = @{
        openapi = '3.0.2'
    }

    # metadata
    $def['info'] = @{
        title = $Title
        version = $Version
        description = $Description
    }

    # servers
    $def['servers'] = $null
    if (!$RestrictRoutes -and (@($PodeContext.Server.Endpoints).Length -gt 1)) {
        $def.servers = @(foreach ($endpoint in $PodeContext.Server.Endpoints) {
            @{
                url = $endpoint.Url
                description = (Protect-PodeValue -Value $endpoint.Description -Default $endpoint.Name)
            }
        })
    }

    # components
    $def['components'] = $PodeContext.Server.OpenAPI.components

    # auth/security components
    if ($PodeContext.Server.Authentications.Count -gt 0) {
        foreach ($authName in $PodeContext.Server.Authentications.Keys) {
            $authType = (Find-PodeAuth -Name $authName).Type

            $def.components.securitySchemas[($authName -replace '\s+', '')] = @{
                type = $authType.Scheme.ToLowerInvariant()
                scheme = $authType.Name.ToLowerInvariant()
            }
        }

        $def['security'] = $PodeContext.Server.OpenAPI.security
    }

    # paths
    $def['paths'] = @{}
    $filter = "^$($RouteFilter)"

    foreach ($method in $PodeContext.Server.Routes.Keys) {
        foreach ($path in $PodeContext.Server.Routes[$method].Keys) {
            # does it match the route?
            if ($path -inotmatch $filter) {
                continue
            }

            # the current route
            $_routes = @($PodeContext.Server.Routes[$method][$path])
            if ($RestrictRoutes) {
                $_routes = @(Get-PodeRoutesByUrl -Routes $_routes -Protocol $Protocol -Address $Address)
            }

            # continue if no routes
            if (($_routes.Length -eq 0) -or ($null -eq $_routes[0])) {
                continue
            }

            # get the first route for base definition
            $_route = $_routes[0]

            # do nothing if it has no responses set
            if ($_route.OpenApi.Responses.Count -eq 0) {
                continue
            }

            # add path to defintion
            if ($null -eq $def.paths[$_route.OpenApi.Path]) {
                $def.paths[$_route.OpenApi.Path] = @{}
            }

            # add path's http method to defintition
            $def.paths[$_route.OpenApi.Path][$method] = @{
                summary = $_route.OpenApi.Summary
                description = $_route.OpenApi.Description
                tags = @($_route.OpenApi.Tags)
                deprecated = $_route.OpenApi.Deprecated
                responses = $_route.OpenApi.Responses
                parameters = $_route.OpenApi.Parameters
                requestBody = $_route.OpenApi.RequestBody
                servers = $null
                security = @($_route.OpenApi.Authentication)
            }

            # add any custom server endpoints for route
            foreach ($_route in $_routes) {
                if ([string]::IsNullOrWhiteSpace($_route.Endpoint.Address) -or ($_route.Endpoint.Address -ieq '*:*')) {
                    continue
                }

                if ($null -eq $def.paths[$_route.OpenApi.Path][$method].servers) {
                    $def.paths[$_route.OpenApi.Path][$method].servers = @()
                }

                $def.paths[$_route.OpenApi.Path][$method].servers += @{
                    url = "$($_route.Endpoint.Protocol)://$($_route.Endpoint.Address)"
                }
            }
        }
    }

    # remove all null values (swagger hates them)
    $def | Remove-PodeNullKeysFromHashtable
    return $def
}

function ConvertTo-PodeOAPropertyFromCmdletParameter
{
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [System.Management.Automation.ParameterMetadata]
        $Parameter
    )

    if ($Parameter.SwitchParameter -or ($Parameter.ParameterType.Name -ieq 'boolean')) {
        New-PodeOABoolProperty -Name $Parameter.Name
    }
    else {
        switch ($Parameter.ParameterType.Name) {
            { @('int32', 'int64') -icontains $_ } {
                New-PodeOAIntProperty -Name $Parameter.Name -Format $_
            }

            { @('double', 'float') -icontains $_ } {
                New-PodeOANumberProperty -Name $Parameter.Name -Format $_
            }
        }
    }

    New-PodeOAStringProperty -Name $Parameter.Name
}

function Get-PodeOABaseObject
{
    return @{
        Path = $null
        Title = $null
        components = @{
            schemas = @{}
            responses = @{}
            securitySchemas = @{}
            requestBodies = @{}
            parameters = @{}
        }
        security = @()
    }
}

function Set-PodeOAAuth
{
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [ValidateNotNullOrEmpty()]
        [hashtable[]]
        $Route,

        [Parameter()]
        [string[]]
        $Name
    )

    foreach ($n in @($Name)) {
        if (!(Test-PodeAuth -Name $n)) {
            throw "Authentication method does not exist: $($n)"
        }
    }

    foreach ($r in @($Route)) {
        $r.OpenApi.Authentication = @(foreach ($n in @($Name)) {
            @{
                "$($n -replace '\s+', '')" = @()
            }
        })
    }
}

function Set-PodeOAGlobalAuth
{
    param(
        [Parameter()]
        [string[]]
        $Name
    )

    foreach ($n in @($Name)) {
        if (!(Test-PodeAuth -Name $n)) {
            throw "Authentication method does not exist: $($n)"
        }
    }

    $PodeContext.Server.OpenAPI.security = @(foreach ($n in @($Name)) {
        @{
            "$($n -replace '\s+', '')" = @()
        }
    })
}