#Requires -RunAsAdministrator
<#
.SYNOPSIS
  이메일 스케줄러 TLS 전용: ALTOSEC_EMAIL_DEPLOY_DOMAIN 시스템 변수 + Runner 재시작. (프록시 ALTOSEC_DEPLOY_DOMAIN 은 건드리지 않음.)

.DESCRIPTION
  TLS + 공개 FQDN 이 필요한 이메일 배포 경로만. HTTP-only 이메일에는 불필요.
  프록시 도메인은 Altosec-proxy-server 쪽 스크립트에서 관리한다 — 이 스크립트는 ALTOSEC_DEPLOY_DOMAIN 을 쓰지 않는다.
  비공개 GHCR 정책: TLS·pull·compose 는 GitHub Actions Deploy 로 수행.
  파라미터 없이 실행(예: iex(irm raw URL))하면 Read-Host 로 새 FQDN 을 묻는다.

.PARAMETER NewFqdn
  새 공개 FQDN. 비우면 대화형 입력.
#>
[CmdletBinding()]
param(
    [string] $NewFqdn = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($NewFqdn)) {
    $NewFqdn = Read-Host 'New public FQDN (DNS A -> this server)'
}

$v = $NewFqdn.Trim().ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($v)) { throw 'FQDN is required.' }

[Environment]::SetEnvironmentVariable('ALTOSEC_EMAIL_DEPLOY_DOMAIN', $v, 'Machine')
Write-Host "Machine ALTOSEC_EMAIL_DEPLOY_DOMAIN=$v (proxy ALTOSEC_DEPLOY_DOMAIN unchanged)"

Get-Service 'actions.runner*' | Restart-Service
Write-Host 'Runner service restarted.'

Write-Host @'

다음 단계 (필수): GitHub → Actions → Deploy (self-hosted Windows) → workflow_dispatch
  • 비공개 GHCR: 이 잡만 docker login + pull + start-with-tls.ps1 + compose 를 수행합니다.

'@
