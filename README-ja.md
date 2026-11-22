# keyvault-acmebot-synology-sync

Azure Key Vault + [Acmebot](https://github.com/shibayan/keyvault-acmebot)で取得したLet's Encrypt証明書を、Synology DSMに自動配布するスクリプトです。

> **Zenn記事:** [証明書短命化時代に、Key Vault + Acmebotで自宅NASまで証明書を配り切る](https://zenn.dev/yotan/articles/keyvault-acmebot-nas-cert-sync)

## ファイル構成

| ファイル | 説明 |
|---|---|
| `kv2dsm.sh` | Key Vaultから最新のPFXを取得し、検証したうえでSynology DSMに登録する |
| `kv2dsm.conf.example` | 設定ファイルのテンプレート |

## 必要なもの

- 証明書がすでに格納されているAzure Key Vault（Acmebotなどで発行したもの）
- 証明書シークレットへの読み取り権限を持つEntra IDアプリ登録（サービスプリンシパル）
- `curl`、`jq`、`openssl`
- Synology DSMの専用アカウント（2FA無効。DSM Web APIのログインは2FAに対応していません）

## セットアップ

### 1. 設定

```bash
cp kv2dsm.conf.example kv2dsm.conf
# kv2dsm.conf をテナント/クライアント情報、Key Vault、DSMアカウントに合わせて編集する
```

### 2. ドライラン

```bash
./kv2dsm.sh --dry-run
```

証明書の取得・検証、DSMへのログイン、置き換え対象の証明書の特定まで行い、実際の登録は行いません。

### 3. 実行

```bash
./kv2dsm.sh
```

Key Vaultシークレットのバージョンをローカルの状態ファイルと比較し、変化がなければ登録をスキップします。強制的に登録したい場合は `FORCE=1` を付けてください。

### 4. 定期実行の設定

DSM本体のタスクスケジューラ（GUI）から定期実行してください。SSHで`crontab`を直接編集しても、DSMでは永続化されません。`/etc/crontab`は`synoscheduler`が管理していて、UIの内容で巻き戻ってしまいます。

## 注意点

- Key VaultのPFXシークレットはパスワード無しを前提にしています（Acmebotがそのように格納するため）
- `KV2DSM_DIR`（デフォルト `/var/services/homes/fsadmin/scripts`）で、`kv2dsm.conf`と状態ファイル`last_version`の置き場所を指定できます
- 登録前に、(a) 24時間以内に期限切れしないか、(b) SANに想定ドメインが含まれているか、(c) 証明書と秘密鍵が対応しているか、を検証します
- DSM上の既存証明書を内部`id`で上書きするため、サービスへの証明書割り当て（リバースプロキシ、DSM自体など）は更新後も維持されます
- DSMへのログインはユーザー名/パスワード認証のため、アカウントは2FAを無効にする必要があります。このアカウントには証明書管理の権限だけを与え、通常の管理者アカウントと兼用しないでください
- Key Vaultへのアクセスは、Managed IdentityがAzure外で使えないため、Entra IDのクライアントクレデンシャルフロー（サービスプリンシパル）を使っています。このSPの権限はできる限り絞ってください。理想は[ABAC条件](https://learn.microsoft.com/azure/key-vault/general/azure-rbac)でシークレット1つに限定することです
- Key Vaultのネットワークファイアウォールは今回のケースでは機能しません（自宅の動的IPは許可リストに入れられないため）。つまりこのSPの認証情報だけが、インターネットとこのシークレットの間にある実質的な防御線です。`CLIENT_SECRET`の扱いには注意してください

## ライセンス

MIT
