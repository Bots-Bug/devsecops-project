<powershell>
Start-Transcript -Path "C:\jenkins-agent-userdata.log" -Append
Write-Host "=== Jenkins Windows Agent started: $(Get-Date) ==="

$MasterIP    = "${jenkins_master_private_ip}"
$AwsRegion   = "${aws_region}"
$Environment = "${environment}"
$AgentName   = "windows-agent-1"
$AgentHome   = "C:\jenkins-agent"

# ── STEP 1: Create directories ───────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $AgentHome | Out-Null
New-Item -ItemType Directory -Force -Path "$AgentHome\workspace" | Out-Null

# ── STEP 2: Install Chocolatey ───────────────────────────────────────────
Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# ── STEP 3: Install Java 21 ──────────────────────────────────────────────
choco install corretto21 -y --no-progress

# Dynamically detect JAVA_HOME
$JavaHome = (Get-ChildItem "C:\Program Files\Amazon Corretto\" | 
             Where-Object { $_.Name -like "jdk21*" } | 
             Select-Object -First 1).FullName

$JavaExe = "$JavaHome\bin\java.exe"

Write-Host "JAVA_HOME = $JavaHome"

# ── STEP 4: Install tools ────────────────────────────────────────────────
choco install git awscli nssm -y --no-progress

# ── STEP 5: Wait for Jenkins master ──────────────────────────────────────
$MasterReady = $false
for ($i = 1; $i -le 90; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "http://$MasterIP:8080/login" -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200) {
      $MasterReady = $true
      Write-Host "Master reachable"
      break
    }
  } catch {
    Write-Host "Waiting for master ($i/90)..."
    Start-Sleep -Seconds 10
  }
}

if (-not $MasterReady) {
  Write-Host "ERROR: Master not reachable"
  exit 1
}

# ── STEP 6: Download agent.jar ───────────────────────────────────────────
Invoke-WebRequest -Uri "http://$MasterIP:8080/jnlpJars/agent.jar" `
  -OutFile "$AgentHome\agent.jar"

# ── STEP 7: Fetch agent secret ───────────────────────────────────────────
$AgentSecret = ""
for ($i = 1; $i -le 120; $i++) {
  try {
    $secretJson = aws secretsmanager get-secret-value `
      --secret-id "jenkins-$Environment/agents/$AgentName/secret" `
      --region $AwsRegion `
      --query SecretString `
      --output text 2>$null

    if ($secretJson) {
      $parsed = $secretJson | ConvertFrom-Json
      $AgentSecret = $parsed.secret
    }

    if ($AgentSecret) {
      Write-Host "Secret retrieved"
      break
    }
  } catch {}

  Write-Host "Waiting for secret ($i/120)..."
  Start-Sleep -Seconds 30
}

if (-not $AgentSecret) {
  Write-Host "ERROR: Failed to get agent secret"
  exit 1
}

# ── STEP 8: Configure NSSM service ───────────────────────────────────────
$nssm = (Get-Command nssm).Source

& $nssm install JenkinsAgent $JavaExe
& $nssm set JenkinsAgent AppParameters "-jar `"$AgentHome\agent.jar`" -url http://$MasterIP:8080/ -name $AgentName -secret $AgentSecret -workDir `"$AgentHome\workspace`""
& $nssm set JenkinsAgent Start SERVICE_AUTO_START

# ── STEP 9: Start service ────────────────────────────────────────────────
Start-Service JenkinsAgent

Write-Host ""
Write-Host "============================================================"
Write-Host " Jenkins Windows Agent setup COMPLETE"
Write-Host " Agent Name: $AgentName"
Write-Host "============================================================"

Stop-Transcript
</powershell>