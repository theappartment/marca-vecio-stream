# Shared by the desktop app and the isolated update worker.
$script:AppVersion = '1.3.0'
$script:UpdateRepository = 'theappartment/marca-vecio-stream'

function Save-UpdateCredential([string]$Root,[string]$Token) {
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $path = Join-Path $Root 'github-update.credential'
    if ([string]::IsNullOrWhiteSpace($Token)) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        return
    }
    $encrypted = ConvertFrom-SecureString (ConvertTo-SecureString $Token.Trim() -AsPlainText -Force)
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,$encrypted)
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,$null) }
        else { [IO.File]::Move($temporary,$path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-UpdateCredential([string]$Root) {
    $path = Join-Path $Root 'github-update.credential'
    if (-not [IO.File]::Exists($path)) { return '' }
    $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($path))
    return (New-Object Management.Automation.PSCredential('github',$secure)).GetNetworkCredential().Password
}

function Get-UpdateProperty($Object,[string]$Name,$Default = $null) {
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function ConvertTo-UpdateRelease($Release,[string]$CurrentVersion = $script:AppVersion) {
    if ((Get-UpdateProperty $Release 'draft' $false) -or (Get-UpdateProperty $Release 'prerelease' $false)) {
        throw 'La release non e una versione stabile.'
    }
    $tag = [string](Get-UpdateProperty $Release 'tag_name' '')
    if ($tag -notmatch '^v?(\d+\.\d+\.\d+(?:\.\d+)?)$') { throw 'Versione della release non valida.' }
    $version = $Matches[1]
    $candidate = [version]$version
    $current = [version]$CurrentVersion
    # Normalize 1.3.0 and 1.3.0.0 to the same version.
    $newer = ([version]('{0}.{1}.{2}.{3}' -f $candidate.Major,$candidate.Minor,[Math]::Max(0,$candidate.Build),[Math]::Max(0,$candidate.Revision))) -gt
        ([version]('{0}.{1}.{2}.{3}' -f $current.Major,$current.Minor,[Math]::Max(0,$current.Build),[Math]::Max(0,$current.Revision)))
    $info = [ordered]@{ version=$version; available=$newer; releaseUrl="https://github.com/$script:UpdateRepository/releases/tag/$tag"; notes=[string](Get-UpdateProperty $Release 'body' '') }
    if (-not $newer) { return [pscustomobject]$info }
    $assets = @((Get-UpdateProperty $Release 'assets' @()) | Where-Object { $_.name -ceq 'MarcaVecioStream-Setup.exe' -and $_.state -eq 'uploaded' })
    if ($assets.Count -ne 1) { throw 'La nuova release non contiene un installer Windows completo.' }
    $asset = $assets[0]
    $digest = [string](Get-UpdateProperty $asset 'digest' '')
    if ($digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Installer privo di verifica SHA256. Ripubblicare il pacchetto completo su GitHub.' }
    $info.sha256 = $Matches[1].ToLowerInvariant()
    $id = [long]$asset.id
    $size = [long]$asset.size
    if ($id -le 0 -or $size -lt 2 -or $size -gt 536870912) { throw 'Dimensioni o identificativo installer non validi.' }
    $info.assetId=$id; $info.size=$size
    return [pscustomobject]$info
}

function Open-UpdateResponse([string]$Url,[string]$Token,[bool]$Binary = $false) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri = [uri]$Url
    for ($hop=0; $hop -lt 6; $hop++) {
        $api = $uri.Host -eq 'api.github.com'
        $assetHost = $uri.Host -eq 'github.com' -or $uri.Host -eq 'release-assets.githubusercontent.com' -or $uri.Host -eq 'objects.githubusercontent.com'
        if ($uri.Scheme -ne 'https' -or (-not $api -and -not ($Binary -and $assetHost))) { throw 'Destinazione download GitHub non valida.' }
        if ($api -and -not $uri.AbsolutePath.StartsWith("/repos/$script:UpdateRepository/",[StringComparison]::Ordinal)) { throw 'Repository di aggiornamento non valido.' }
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.UserAgent='MarcaVecioStream-Updater/' + $script:AppVersion
        $request.AllowAutoRedirect=$false; $request.Timeout=30000; $request.ReadWriteTimeout=30000
        $request.Accept=if ($Binary) { 'application/octet-stream' } else { 'application/vnd.github+json' }
        if ($api) {
            $request.Headers['X-GitHub-Api-Version']='2022-11-28'
            if ($Token) { $request.Headers['Authorization']='Bearer ' + $Token }
        }
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($_.Exception.Response) { $_.Exception.Response.Dispose() }
            if ($status -eq 401 -or $status -eq 404) { throw 'GitHub non accessibile: salva un token con accesso in lettura al repository privato, oppure verifica che esista una release.' }
            if ($status -eq 403 -or $status -eq 429) { throw 'GitHub ha limitato le richieste o il token non ha accesso. Riprova piu tardi o verifica il token.' }
            throw 'Connessione a GitHub non riuscita. Controlla la rete e riprova.'
        }
        $code=[int]$response.StatusCode
        if ($code -in @(301,302,303,307,308)) {
            try { $uri = New-Object uri($uri,$response.Headers['Location']) } finally { $response.Dispose() }
            continue
        }
        return $response
    }
    throw 'Troppi reindirizzamenti durante il download.'
}

function Get-LatestUpdate([string]$Token = '',[string]$CurrentVersion = $script:AppVersion) {
    $response = Open-UpdateResponse "https://api.github.com/repos/$script:UpdateRepository/releases/latest" $Token
    $reader = $null
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        $json = $reader.ReadToEnd()
        return ConvertTo-UpdateRelease ($json | ConvertFrom-Json) $CurrentVersion
    } finally { if ($reader) { $reader.Dispose() }; $response.Dispose() }
}

function Assert-UpdatePackage([string]$Path,$Release) {
    if ((Get-Item -LiteralPath $Path).Length -ne $Release.size) { throw 'Download incompleto: dimensioni diverse dalla release. Riprova.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Release.sha256) { throw 'Verifica SHA256 fallita. Il pacchetto non verra eseguito.' }
    $stream=[IO.File]::OpenRead($Path)
    try { if ($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) { throw 'Il file scaricato non e un installer Windows.' } } finally { $stream.Dispose() }
}

function Save-UpdatePackage($Release,[string]$Directory,[string]$Token = '') {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $path=Join-Path $Directory ('MarcaVecioStream-Setup-' + $Release.version + '.exe')
    $temporary=$path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $response=$null; $inputStream=$null; $outputStream=$null
    try {
        $response=Open-UpdateResponse "https://api.github.com/repos/$script:UpdateRepository/releases/assets/$($Release.assetId)" $Token $true
        $inputStream=$response.GetResponseStream()
        $outputStream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536; $total=[long]0
        while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $Release.size) { throw 'Download piu grande del pacchetto dichiarato.' }
            $outputStream.Write($buffer,0,$read)
        }
        $outputStream.Dispose(); $outputStream=$null
        Assert-UpdatePackage $temporary $Release
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,$null) } else { [IO.File]::Move($temporary,$path) }
        return $path
    } finally {
        if ($outputStream) { $outputStream.Dispose() }; if ($inputStream) { $inputStream.Dispose() }; if ($response) { $response.Dispose() }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
