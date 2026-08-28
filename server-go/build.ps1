# Build + code-sign panel-server.exe
# Purpose: Go binaries are often false-flagged by heuristics (e.g. HEUR:VirTool/Obfuscator.a).
#          Authenticode signing greatly reduces such false positives.
# Usage: powershell -ExecutionPolicy Bypass -File .\build.ps1
$ErrorActionPreference = 'Stop'
$out       = Join-Path $PSScriptRoot 'panel-server.exe'
$pfxPath   = Join-Path $PSScriptRoot 'air724-sign.pfx'
$pfxPass   = 'air724ug'
$certName  = 'CN=Air724UG Panel'

# 1. Build (do NOT strip symbols - stripped Go exe triggers obfuscator heuristics)
Write-Host '==> go build panel-server.exe' -ForegroundColor Cyan
Push-Location $PSScriptRoot
go build -trimpath -o $out .
Pop-Location

if (-not (Test-Path $out)) {
    Write-Error 'Build output missing (likely removed by realtime AV). Add this dir to AV trust list and retry.'
}

# 2. Prepare code-signing PFX (reuse existing, or generate self-signed via pure .NET)
if (-not (Test-Path $pfxPath)) {
    Write-Host '==> Generating self-signed code-signing cert (5y)' -ForegroundColor Cyan
    Add-Type -AssemblyName System.Security
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($certName),
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    # add CodeSigning EKU (1.3.6.1.5.5.7.3.3)
    $ekuOids = [System.Security.Cryptography.OidCollection]::new()
    $ekuOids.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3')) | Out-Null
    $req.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $ekuOids, $false)) | Out-Null
    $now = [DateTimeOffset]::Now
    $cert = $req.CreateSelfSigned($now, $now.AddYears(5))
    $pfxBytes = $cert.Export(
        [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
        $pfxPass)
    [IO.File]::WriteAllBytes($pfxPath, $pfxBytes)
    $cert.Dispose(); $rsa.Dispose()
    Write-Host "    cert saved: $pfxPath"
}

# 3. Sign the exe with the PFX
Write-Host '==> Signing panel-server.exe' -ForegroundColor Cyan
$secure = ConvertTo-SecureString $pfxPass -AsPlainText -Force
$signCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    $pfxPath, $pfxPass,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
$sig = Set-AuthenticodeSignature -FilePath $out -Certificate $signCert -HashAlgorithm SHA256
if ($sig.Status -ne 'Valid') {
    Write-Warning "Signature status: $($sig.Status) ($($sig.StatusMessage))"
} else {
    Write-Host "Signed OK: $($sig.Status)" -ForegroundColor Green
}
Write-Host "Done: $out"
