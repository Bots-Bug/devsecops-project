<powershell>
# ─────────────────────────────────────────────────────────────────────────
# Jenkins Windows Agent — User Data Script
# OS: Windows Server 2022
#
# Terraform template variables (injected by templatefile):
#   ${jenkins_master_private_ip}
#   ${aws_region}
#   ${environment}
#
# NOTE: Windows userdata runs as SYSTEM at instance launch.
# NOTE: Chocolatey installs may take 5-10 minutes on first run.
# ─────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

# ── Terraform-injected values ─────────────────────────────────────────────
$MasterIP    = "${jenkins_master_private_ip}"
$AwsRegion   = "${aws_region}"
$Environment = "${environment}"
$AgentName   = "windows-agent-1"
$AgentHome   = "C:\jenkins-agent"

# SCALE NOTE:
#   For multiple Windows agents, parameterize $AgentName (e.g. windows-agent-2)
#   by adding an agent_number variable, same as the Linux agent script.
#   Each agent must have a unique node name in Jenkins and a unique secret.

# ── Create Directories ────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $AgentHome | Out-Null
New-Item -ItemType Directory -Force -Path "$AgentHome\workspace" | Out-Null

# ── Install Chocolatey ────────────────────────────────────────────────────
Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-Expression (
  (New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
)

# Reload path so choco is available
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

# ── Install Java 17 ────────────────────────────────────────────────────────
# Using Amazon Corretto — free, production-grade OpenJDK from AWS
# ENTERPRISE NOTE: pin a specific version for reproducibility
#   e.g.: choco install corretto17 --version 17.0.10.7 -y
choco install corretto17 -y --no-progress

# Reload environment after Java install
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
$JavaExe = (Get-ChildItem "C:\Program Files\Amazon Corretto" -Filter "java.exe" -Recurse |
            Select-Object -First 1).FullName

if (-not $JavaExe) {
  Write-Error "Java not found after install. Exiting."
  exit 1
}

Write-Host "Java found at: $JavaExe"

# ── Install Git ───────────────────────────────────────────────────────────
choco install git -y --no-progress

# ── Install AWS CLI ───────────────────────────────────────────────────────
choco install awscli -y --no-progress
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

# ── Install NSSM (service manager for Jenkins agent) ─────────────────────
# NSSM wraps any EXE as a Windows service with restart behavior
choco install nssm -y --no-progress
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

# ── Wait for Jenkins Master ────────────────────────────────────────────────
Write-Host "Waiting for Jenkins master at $MasterIP..."
$attempt = 0
$ready = $false
while (-not $ready -and $attempt -lt 60) {
  try {
    $r = Invoke-WebRequest -Uri "http://$MasterIP:8080/login" -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200) { $ready = $true }
  } catch {
    $attempt++
    Write-Host "Attempt $attempt/60 — waiting 5s..."
    Start-Sleep -Seconds 5
  }
}

if (-not $ready) {
  Write-Warning "Master not reachable. Agent service will fail to start. Investigate master first."
}

# ── Download Agent JAR ────────────────────────────────────────────────────
Invoke-WebRequest `
  -Uri "http://$MasterIP:8080/jnlpJars/agent.jar" `
  -OutFile "$AgentHome\agent.jar" `
  -UseBasicParsing

# ── Fetch Agent Secret from AWS Secrets Manager ───────────────────────────
# Secret must be created AFTER Jenkins node is configured in the UI.
# See Step 10 in the setup guide for how to populate this secret.
#
# SECRET PATH: jenkins-{env}/agents/windows-agent-1/secret

$AgentSecret = ""
$attempt = 0
while ([string]::IsNullOrEmpty($AgentSecret) -and $attempt -lt 60) {
  try {
    $json = aws secretsmanager get-secret-value `
      --secret-id "jenkins-$Environment/agents/$AgentName/secret" `
      --region $AwsRegion `
      --query SecretString `
      --output text 2>$null
    if ($json) {
      $AgentSecret = ($json | ConvertFrom-Json).secret
    }
  } catch {
    $attempt++
    Write-Host "Attempt $attempt/60 — secret not yet available, waiting 30s..."
    Start-Sleep -Seconds 30
  }
}

# ── Install Jenkins Agent as Windows Service via NSSM ─────────────────────
$ServiceName = "JenkinsAgent"
$LogFile     = "$AgentHome\agent.log"

nssm install $ServiceName $JavaExe
nssm set $ServiceName AppParameters "-jar `"$AgentHome\agent.jar`" -url http://$MasterIP:8080/ -name $AgentName -secret $AgentSecret -workDir `"$AgentHome\workspace`" -failIfWorkDirIsMissing"
nssm set $ServiceName AppDirectory $AgentHome
nssm set $ServiceName AppStdout $LogFile
nssm set $ServiceName AppStderr $LogFile
nssm set $ServiceName AppRotateFiles 1
nssm set $ServiceName AppRotateSeconds 86400
nssm set $ServiceName Start SERVICE_AUTO_START
nssm set $ServiceName AppExit Default Restart
nssm set $ServiceName AppRestartDelay 30000

if (-not [string]::IsNullOrEmpty($AgentSecret)) {
  Start-Service -Name $ServiceName
  Write-Host "Jenkins Windows agent '$AgentName' service started."
} else {
  Write-Warning "Secret not found. Service installed but NOT started."
  Write-Warning "After storing the secret, run: Start-Service $ServiceName"
}
</powershell>