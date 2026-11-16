<#
  Points the website (Vercel) at a VM, with no stored key: Vercel's OIDC token is exchanged for
  short-lived Google credentials of the rdp-website service account (Workload Identity Federation).
  New Google accounts block service-account keys by default, and this is safer anyway.
  Creates the pool/provider if missing, lets only the rdp-admin production deployment impersonate
  rdp-website, stores the settings in Vercel (production) and .env.local, then redeploys.
  restore.ps1 calls this; run it alone after a manual move:

      .\ops\point-website.ps1 -Project new-project-id -Account new@gmail.com

  Needs: Vercel project → Settings → Security → OIDC Federation in Team mode (the default).
#>
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$Account,
  [string]$Zone = "europe-west1-b",
  [string]$Vm = "rdp-desktop",
  [string]$VercelTeam = "infolabtn",
  [string]$VercelProject = "rdp-admin",
  [switch]$NoDeploy
)

. "$PSScriptRoot\settings.ps1"
$Project = $PSBoundParameters["Project"]
$Zone = if ($PSBoundParameters["Zone"]) { $PSBoundParameters["Zone"] } else { "europe-west1-b" }
$Vm = if ($PSBoundParameters["Vm"]) { $PSBoundParameters["Vm"] } else { "rdp-desktop" }
$ErrorActionPreference = "Stop"
$env:CLOUDSDK_CORE_ACCOUNT = $Account
$env:CLOUDSDK_CORE_PROJECT = $Project
$repo = Split-Path $PSScriptRoot
$siteSa = "rdp-website@$Project.iam.gserviceaccount.com"
$number = (GJson projects describe $Project).projectNumber
$subject = "owner:${VercelTeam}:project:${VercelProject}:environment:production"

Step "Workload Identity: Vercel ($VercelTeam/$VercelProject, production) -> $siteSa"
G services enable sts.googleapis.com iamcredentials.googleapis.com | Out-Null
if (-not (GOk iam workload-identity-pools describe vercel --location=global)) {
  G iam workload-identity-pools create vercel --location=global --display-name=Vercel | Out-Null
}
if (-not (GOk iam workload-identity-pools providers describe vercel --location=global --workload-identity-pool=vercel)) {
  G iam workload-identity-pools providers create-oidc vercel --location=global --workload-identity-pool=vercel `
    --issuer-uri="https://oidc.vercel.com/$VercelTeam" --allowed-audiences="https://vercel.com/$VercelTeam" `
    --attribute-mapping="google.subject=assertion.sub" --attribute-condition="assertion.sub=='$subject'" | Out-Null
}
G iam service-accounts add-iam-policy-binding $siteSa --role=roles/iam.workloadIdentityUser `
  --member="principal://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/vercel/subject/$subject" | Out-Null

Step "Vercel environment (production)"
$vals = [ordered]@{
  GCP_PROJECT_ID = $Project; GCE_ZONE = $Zone; GCE_INSTANCE = $Vm
  GCP_PROJECT_NUMBER = "$number"; GCP_WORKLOAD_IDENTITY_POOL_ID = "vercel"
  GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID = "vercel"; GCP_SERVICE_ACCOUNT_EMAIL = $siteSa
}
Push-Location $repo
try {
  foreach ($k in $vals.Keys) {
    # Feed the value through node so it reaches Vercel without the newline PowerShell pipes add.
    $env:RDP_VAL = $vals[$k]
    node -e "const r=require('child_process').spawnSync('npx',['-y','vercel@latest','env','add','$k','production','--force'],{input:process.env.RDP_VAL,shell:true,encoding:'utf8'});process.exit(r.status)"
    if ($LASTEXITCODE -ne 0) { throw "Could not set $k in Vercel" }
    Write-Host "  $k set"
  }
  Remove-Item Env:RDP_VAL
  # A key for another project would only confuse things; the app ignores it once the pool is set.
  node -e "require('child_process').spawnSync('npx',['-y','vercel@latest','env','rm','GCP_SA_KEY_B64','production','--yes'],{shell:true})"

  # Keep .env.local's names in sync (local dev still needs a key or `vercel env pull`).
  $envPath = Join-Path $repo ".env.local"
  if (Test-Path $envPath) {
    $text = [IO.File]::ReadAllText($envPath)
    foreach ($k in "GCP_PROJECT_ID", "GCE_ZONE", "GCE_INSTANCE") { $text = [regex]::Replace($text, "(?m)^$k=.*$", "$k=$($vals[$k])") }
    [IO.File]::WriteAllText($envPath, $text)
  }

  if (-not $NoDeploy) {
    Step "Redeploying (environment changes only apply to new builds)"
    npx -y vercel@latest deploy --prod --yes 2>&1 | Select-Object -Last 2
  }
} finally { Pop-Location }
