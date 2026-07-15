$wslIp = (wsl hostname -I).Trim().Split(' ')[0]

if (-not $wslIp) {
    Write-Error "Could not determine WSL IP address."
    exit 1
}

route delete 172.20.20.0 2>$null
route add 172.20.20.0 mask 255.255.255.0 $wslIp

Write-Host "AtlasLab route installed:"
Write-Host "172.20.20.0/24 via $wslIp"