<#
.SYNOPSIS
    Local CI/CD Deployment Script for .NET Framework 4.8 (.NET Framework / Web / Service)
.DESCRIPTION
    Builds the solution, packages artifacts into individual zip files, uploads to S3, and dispatches an AWS SSM command (or runs locally) for deployment.
#>

[CmdletBinding()]
param(
    [string]$ServerType = "Web", # Options: "Web" or "Service"
    [string]$InstanceId = "localhost",
    [string]$S3Bucket = "corsium-release",
    [string]$AwsRegion = "ap-south-1"
)

if ($InstanceId -eq "localhost") {
    Write-Host " Starting Localhost Deployment Script ($ServerType) " -ForegroundColor Cyan
}

$ErrorActionPreference = "Stop"
$script_zipFile = ""

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Starting Local Deployment Script ($ServerType) " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 1. Determine solution name and workspace
$workspace = Get-Location
$slnFiles = Get-ChildItem -Filter "*.sln"
if ($slnFiles.Count -eq 0) { throw "No .sln file found in current directory." }
$solutionName = $slnFiles[0].Name

# 2. Build and Zip Binaries based on Server Type
Write-Host "[1/5] Building and packaging solution..." -ForegroundColor Yellow
if ($ServerType -eq "Service") {
    msbuild $solutionName /p:Configuration=Release /p:Platform="x64" /verbosity:minimal
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed for Service build." }

    Compress-Archive -Path "DMSWindowsService/bin/*" -DestinationPath "DMSWindowsService-Release.zip" -Force
    $script_zipFile = "DMSWindowsService-Release.zip"
} 
else {
    $projectPublishPaths = @("Webi2iPublish","WebAPIPublish","ManagementPublish")
    $projectPaths = @("Webi2i/Webi2i.csproj","ISCAPI/WebAPI.csproj","Management/Management/Management.csproj")
    $zipFiles = @("Webi2i.zip","WebAPI.zip","Management.zip")
    $webAppsDir = "WebApps"
    
    Remove-Item -Path $webAppsDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $webAppsDir -Force | Out-Null
    
    for ($i = 0; $i -lt $projectPaths.Count; $i++) {
        $projectPublishPath = $projectPublishPaths[$i]
        $publishDir = Join-Path -Path $workspace -ChildPath $projectPublishPath
        
        if ($projectPaths[$i] -like "Management*") {
            $targetSolutionDir = Join-Path -Path $workspace -ChildPath "Management"
            Remove-Item -Path "Management/Management/obj", "Management/Management/bin" -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            $targetSolutionDir = $workspace
        }
        
        $msbuildArgs = @(
            $projectPaths[$i]
            "/t:Rebuild;WebPublish"
            "/p:Configuration=Release"
            "/p:Platform=x64"
            "/p:DeployOnBuild=true"
            "/p:PublishUrl=$publishDir"
            "/p:WebPublishMethod=FileSystem"
            "/p:DeployTarget=WebPublish"
            "/p:SolutionDir=$targetSolutionDir/"
            "/p:AutoParameterizationWebConfigConnectionStrings=false"
            "/verbosity:minimal"
        )

        & msbuild @msbuildArgs
        if ($LASTEXITCODE -ne 0) { throw "MSBuild failed for Web Publish." }

        if (-not (Test-Path -Path "$publishDir\*")) {
            throw "Publish directory '$publishDir' does not exist or is empty."
        }

        $zipSource = Join-Path -Path $publishDir -ChildPath "*"
        $script_zipFile = Join-Path -Path $webAppsDir -ChildPath $zipFiles[$i]
        Compress-Archive -Path $zipSource -DestinationPath $script_zipFile -Force
        Write-Host "Zip created: $script_zipFile" -ForegroundColor Green
        
        Remove-Item -Path $publishDir -Recurse -Force 
        Write-Host "Deleted publish Dir: $publishDir"
    }
}

Write-Host "Artifact packaged successfully." -ForegroundColor Green

# 3. Upload Zips to S3 individually
Write-Host "[2/5] Uploading packages to S3..." -ForegroundColor Yellow
if ($ServerType -eq "Service") {
    aws s3 cp $script_zipFile "s3://$S3Bucket/$script_zipFile"
    if ($LASTEXITCODE -ne 0) { throw "AWS S3 upload failed for $script_zipFile." }
} else {
    foreach ($zipFile in $zipFiles) {
        $localZip = Join-Path -Path $webAppsDir -ChildPath $zipFile
        aws s3 cp $localZip "s3://$S3Bucket/$webAppsDir/$zipFile"
        if ($LASTEXITCODE -ne 0) { throw "AWS S3 upload failed for $zipFile." }
    }
}
Write-Host "Upload completed successfully." -ForegroundColor Green

# 4. Construct Reusable Deployment Script Block
$deployScriptBlock = {
    param($zipFiles, $targetDirs, $s3Bucket, $webAppsDir)
    
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    if (-not (Test-Path "C:\WebApps")) {
        New-Item -ItemType Directory -Path "C:\WebApps" -Force | Out-Null
    }

    for ($i = 0; $i -lt $zipFiles.Count; $i++) {
        $zipFile = $zipFiles[$i]
        $targetDir = $targetDirs[$i]
        $s3Key = "$webAppsDir/$zipFile"
        $localZipPath = Join-Path "C:\WebApps" $zipFile

        # Download from S3
        aws s3 cp "s3://$s3Bucket/$s3Key" "$localZipPath"
        if ($LASTEXITCODE -ne 0) { throw "Failed to download $zipFile from S3." }

        # Safely stop app pool if it exists and is running
        $appPoolName = Split-Path $targetDir -Leaf
        try {
            $poolState = Get-WebAppPoolState -Name $appPoolName -ErrorAction SilentlyContinue
            if ($poolState -and $poolState.Value -eq 'Started') {
                Stop-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        } catch {
            # Ignore if app pool doesn't exist in IIS yet
        }

        # Backup existing web.config if present
        $configPath = "$targetDir\web.config"
        $backupPath = "$targetDir\web.config.bak"
        if (Test-Path $configPath) {
            Copy-Item -Path $configPath -Destination $backupPath -Force
        }

        # Ensure target directory exists and extract zip
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Expand-Archive -Path $localZipPath -DestinationPath $targetDir -Force
        Remove-Item -Path $localZipPath -Force

        # Set specific permissions if needed (e.g., Webi2i temp folder)
        if ($targetDir -like "*Webi2i*") {
            $tempDir = "$targetDir\Content\temp"
            if (-not (Test-Path $tempDir)) { [void](New-Item -ItemType Directory -Path $tempDir -Force) }
            icacls "$tempDir" /grant "IIS_IUSRS:(OI)(CI)F" /T /Q | Out-Null
        }

        # Config Merge (Preserve runtime and EF sections)
        if (Test-Path $backupPath) {
            try {
                $live = [xml](Get-Content $backupPath)
                $new  = [xml](Get-Content $configPath)

                foreach ($sec in @('runtime', 'entityFramework', 'system.data')) {
                    $nSec = $new.configuration.SelectSingleNode($sec)
                    if ($null -ne $nSec) {
                        $eSec = $live.configuration.SelectSingleNode($sec)
                        $imp = $live.ImportNode($nSec, $true)
                        if ($null -ne $eSec) {
                            [void]$live.configuration.ReplaceChild($imp, $eSec)
                        } else {
                            [void]$live.configuration.AppendChild($imp)
                        }
                    }
                }
                $live.Save($configPath)
            } finally {
                Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
            }
        }

        # Safely start app pool back up
        try {
            $poolState = Get-WebAppPoolState -Name $appPoolName -ErrorAction SilentlyContinue
            if ($poolState -and $poolState.Value -ne 'Started') {
                Start-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue
            }
        } catch {
            # Ignore if app pool doesn't exist
        }
    }
}

# 5. Execute Deployment (Locally or via AWS SSM)
Write-Host "[3/5] Preparing deployment payload for Instance: $InstanceId..." -ForegroundColor Yellow

$zipsParam = @("Webi2i.zip", "WebAPI.zip", "Management.zip")
$dirsParam = @("C:\inetpub\wwwroot\Webi2i", "C:\inetpub\wwwroot\WebAPI", "C:\inetpub\wwwroot\Management")

if ($InstanceId -eq "localhost") {
    Write-Host "[4/5] Executing deployment block locally on $env:COMPUTERNAME..." -ForegroundColor Yellow
    try {
        & $deployScriptBlock -zipFiles $zipsParam -targetDirs $dirsParam -s3Bucket $S3Bucket -webAppsDir "WebApps"
        Write-Host "[SUCCESS] Local deployment executed successfully." -ForegroundColor Green
    }
    catch {
        Write-Error "[ERROR] Local execution failed: $_"
        exit 1
    }
} 
else {
    $blockBody = $deployScriptBlock.ToString()
    $remoteScript = @"
`$ErrorActionPreference = 'Stop'
`$zipFiles = @('Webi2i.zip', 'WebAPI.zip', 'Management.zip')
`$targetDirs = @('C:\inetpub\wwwroot\Webi2i', 'C:\inetpub\wwwroot\WebAPI', 'C:\inetpub\wwwroot\Management')
`$s3Bucket = '$S3Bucket'
`$webAppsDir = 'WebApps'

`$deployScriptBlock = {
$blockBody
}

& `$deployScriptBlock -zipFiles `$zipFiles -targetDirs `$targetDirs -s3Bucket `$s3Bucket -webAppsDir `$webAppsDir
"@

    Write-Host "[4/5] Dispatches SSM command to instance $InstanceId..." -ForegroundColor Yellow
    $ssmPayload = @{
        DocumentName = "AWS-RunPowerShellScript"
        InstanceIds  = @("$InstanceId")
        Comment      = "Deploying web binaries via script block"
        Parameters   = @{
            commands = @($remoteScript)
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $requestFile = Join-Path -Path $env:TEMP -ChildPath "ssm-send-command.json"
    [System.IO.File]::WriteAllText($requestFile, $ssmPayload, (New-Object System.Text.UTF8Encoding($false)))

    $commandId = (& aws ssm send-command --cli-input-json "file://$requestFile" --query "Command.CommandId" --output text).Trim()

    if ([string]::IsNullOrWhiteSpace($commandId) -or $commandId -eq "None") {
        throw "Failed to create SSM command."
    }
    Write-Host "-> SSM Command ID: $commandId" -ForegroundColor DarkCyan

    Write-Host "[5/5] Waiting for remote execution to complete..." -ForegroundColor Yellow
    aws ssm wait command-executed --command-id $commandId --instance-id "$InstanceId"

    $status = (aws ssm get-command-invocation --command-id $commandId --instance-id "$InstanceId" --query "Status" -ErrorAction SilentlyContinue).Trim()
    if ($status -ne "Success") {
        aws ssm get-command-invocation --command-id $commandId --instance-id "$InstanceId" --query "[StandardOutputContent, StandardErrorContent]" -ErrorAction SilentlyContinue
        throw "Remote deployment failed with status: $status"
    }
}

Write-Host "========================================================" -ForegroundColor Green
Write-Host " Deployment Pipeline Completed Successfully!            " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green