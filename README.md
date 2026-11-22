# keyvault-acmebot-synology-sync

Fetch a Let's Encrypt certificate issued via Azure Key Vault + [Acmebot](https://github.com/shibayan/keyvault-acmebot), and auto-deploy it to Synology DSM.

> **Japanese article:** [証明書短命化時代に、Key Vault + Acmebotで自宅NASまで証明書を配り切る](https://zenn.dev/yotan/articles/keyvault-acmebot-nas-cert-sync)

## Files

| File | Description |
|---|---|
| `kv2dsm.sh` | Fetch the latest PFX from Key Vault, verify it, and import it into Synology DSM |
| `kv2dsm.conf.example` | Config file template |

## Requirements

- Azure Key Vault with a certificate already issued (e.g. via Acmebot)
- An Entra ID app registration (service principal) with read access to the certificate secret
- `curl`, `jq`, `openssl`
- Synology DSM with a dedicated account (2FA disabled - the DSM Web API login does not support 2FA)

## Setup

### 1. Configure

```bash
cp kv2dsm.conf.example kv2dsm.conf
# edit kv2dsm.conf with your tenant/client credentials, vault, and DSM account
```

### 2. Dry run

```bash
./kv2dsm.sh --dry-run
```

This fetches and verifies the certificate, logs into DSM, and locates the certificate to replace, without importing it.

### 3. Run

```bash
./kv2dsm.sh
```

The script compares the Key Vault secret's version against a local state file and skips import if nothing changed. Set `FORCE=1` to import anyway.

### 4. Schedule

Run it periodically via DSM's own Task Scheduler (GUI). Editing crontab directly over SSH does not persist on DSM - `synoscheduler` manages `/etc/crontab` and overwrites manual edits.

## Notes

- The Key Vault PFX secret is assumed to have no password (Acmebot stores it that way).
- `KV2DSM_DIR` (default `/var/services/homes/fsadmin/scripts`) controls where `kv2dsm.conf` and the `last_version` state file live.
- Before importing, the script checks (a) the certificate isn't expiring within 24 hours, (b) the SAN contains the expected domain, and (c) the certificate and private key match.
- The script replaces the existing DSM certificate by its internal `id`, so any service assignment (reverse proxy, DSM itself, etc.) stays intact across renewals.
- DSM login uses username/password - the account must have 2FA disabled, since the Web API doesn't support it. Scope this account to certificate management only, not a general admin account.
- Key Vault access uses an Entra ID client-credentials flow (service principal), since Managed Identity isn't available outside Azure. Scope this SP's role as tightly as possible - ideally to a single secret via an [ABAC condition](https://learn.microsoft.com/azure/key-vault/general/azure-rbac).
- Key Vault's network firewall doesn't help here (a home connection's dynamic IP can't be allow-listed), so the SP's credential is effectively the only thing standing between the internet and this secret. Treat `CLIENT_SECRET` accordingly.

## License

MIT
