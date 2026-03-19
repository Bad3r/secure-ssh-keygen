# sss-ssh-keygen

`sss-ssh-keygen` is an opinionated wrapper around OpenSSH `ssh-keygen` for
consistent, reviewable SSH key-generation defaults. It standardizes software
and FIDO-backed key creation, keeps OpenSSH-native private-key formats, and
defaults to conservative behavior around passphrases and overwrites.

## Scope

This project standardizes key generation only. It does not replace SSH client
or server hardening, does not manage `ssh_config` or `sshd_config`, and does
not provision or reset hardware tokens. Use it to create keys with known-good
defaults, then manage transport policy and token lifecycle separately.

## Requirements and compatibility

- Bash is required; the wrapper is implemented as a Bash script.
- OpenSSH is required. FIDO-backed SSH keys require OpenSSH 8.2 or newer.
- The `verify-required` option used by the hardware profiles requires OpenSSH
  8.3 or newer.
- The default hardware profile uses `ed25519-sk`. Use this when your
  authenticator and estate support Ed25519-backed FIDO SSH credentials.
- Use `fido-ecdsa` or `--fido-algorithm ecdsa-sk` for older tokens or for
  environments that do not support `ed25519-sk`.
- Use the `fips` or `rsa3072` profile when policy or interoperability requires
  RSA.

## Quick start

Review the shipped defaults:

```sh
$EDITOR sss-ssh-keygen.conf
```

Preview the default command without generating a key:

```sh
./sss-ssh-keygen.sh --dry-run
```

Generate the default software key:

```sh
./sss-ssh-keygen.sh
```

Generate the default hardware-backed key:

```sh
./sss-ssh-keygen.sh --profile hardware
```

Generate an RSA fallback key:

```sh
./sss-ssh-keygen.sh --profile fips
```

## Default profiles

| Profile | Default algorithm | Intended use | Compatibility note |
| --- | --- | --- | --- |
| `ed25519` / `software` | `ed25519` | General-purpose software key | Preferred default for modern OpenSSH estates |
| `hardware` / `fido-ed25519` | `ed25519-sk -O verify-required` | Modern FIDO-backed key | Requires token and estate support for Ed25519 FIDO SSH keys |
| `fido-ecdsa` | `ecdsa-sk -O verify-required` | Hardware-backed compatibility path | Use for older authenticators or estates without `ed25519-sk` |
| `rsa3072` / `compat` | `rsa -b 3072` | Conservative compatibility path | Uses RSA with SHA-2 signatures |
| `rsa4096` | `rsa -b 4096` | Policy-driven larger RSA key | Use only when an explicit standard requires it |
| `fips` | `rsa -b 3072` | FIPS-oriented or policy-constrained estate | Provided as an explicit RSA alias |

The shipped defaults are:

- Software key default: `ed25519`
- Hardware key default: `ed25519-sk -O verify-required`
- Hardware fallback: `ecdsa-sk -O verify-required`
- RSA fallback: `rsa -b 3072`
- Avoid for new keys: `dsa`, `xmss`, PEM output, and legacy `ssh-rsa`/SHA-1

## Configuration model

The wrapper loads `sss-ssh-keygen.conf` from the repository root by default.
That file is intended to be edited directly when you want a persistent local
policy.

Supported configuration variables include:

- `SSH_KEYGEN_PROFILE`
- `SSH_KEYGEN_OUTPUT`
- `SSH_KEYGEN_COMMENT`
- `SSH_KEYGEN_KDF_ROUNDS`
- `SSH_KEYGEN_CIPHER`
- `SSH_KEYGEN_RSA_BITS`
- `SSH_KEYGEN_EMPTY_PASSPHRASE`
- `SSH_KEYGEN_QUIET`
- `SSH_KEYGEN_DRY_RUN`
- `SSH_KEYGEN_FIDO_ALGORITHM`
- `SSH_KEYGEN_FIDO_APPLICATION`
- `SSH_KEYGEN_FIDO_VERIFY_REQUIRED`
- `SSH_KEYGEN_FIDO_RESIDENT`

To use a different config file for a specific run:

```sh
./sss-ssh-keygen.sh --config /path/to/custom.conf --dry-run
```

## Operational notes

- Passphrase prompting is the default. Use `--empty-passphrase` only for
  machine accounts or non-interactive workflows that require it.
- Existing output paths are protected by default. Use `--force-overwrite` only
  when replacement is intentional.
- The wrapper uses the OpenSSH private-key format and explicitly sets
  `aes256-ctr` for private-key encryption.
- The shipped KDF default is `100` bcrypt_pbkdf rounds. OpenSSH defaults to
  `16`; this project raises the cost as a practical baseline for current
  workstations.
- Resident keys are not the default. Enable them explicitly with
  `--fido-resident` if portability across hosts is worth the theft tradeoff for
  your use case.

## Repository contents

- `sss-ssh-keygen.sh`: canonical wrapper
- `sss-ssh-keygen.conf`: shipped default configuration

## Sources

- OpenSSH `ssh-keygen(1)`:
  https://man.openbsd.org/OpenBSD-current/ssh-keygen.1
- OpenSSH release notes:
  https://www.openssh.org/releasenotes.html
- OpenSSH post-quantum guidance:
  https://www.openssh.org/pq.html
- Mozilla OpenSSH guidance:
  https://infosec.mozilla.org/guidelines/openssh
- Yubico SSH with FIDO2 guidance:
  https://developers.yubico.com/SSH/Securing_SSH_with_FIDO2.html
