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

- Bash is required; the wrapper is implemented as a Bash script and remains
  compatible with Bash 3.2 for stock macOS `/bin/bash`.
- OpenSSH is required. FIDO-backed SSH keys require OpenSSH 8.2 or newer.
- The default `verify-required` hardware mode requires OpenSSH 8.4 or newer.
- The `hardware` profile uses a configurable FIDO algorithm and defaults to
  `ed25519-sk`. Use this when your authenticator and estate support
  Ed25519-backed FIDO SSH credentials.
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

Generate a named software key for a specific provider or account:

```sh
./sss-ssh-keygen.sh --output-suffix github_unsigned_sh --comment 'github <@> unsigned.sh'
```

Generate the default hardware-backed key:

```sh
./sss-ssh-keygen.sh --profile hardware
```

Place the default key under the XDG config directory:

```sh
./sss-ssh-keygen.sh --use-xdg-output
```

Generate an RSA fallback key:

```sh
./sss-ssh-keygen.sh --profile fips
```

## Default profiles

| Profile                | Default algorithm               | Intended use                                            | Compatibility note                                               |
| ---------------------- | ------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------- |
| `ed25519` / `software` | `ed25519`                       | General-purpose software key                            | Preferred default for modern OpenSSH estates                     |
| `hardware`             | `ed25519-sk -O verify-required` | Modern FIDO-backed key with configurable FIDO algorithm | Defaults to `ed25519-sk`, can be switched to `ecdsa-sk`          |
| `fido-ed25519`         | `ed25519-sk -O verify-required` | Fixed Ed25519 FIDO-backed key                           | Always uses `ed25519-sk`                                         |
| `fido-ecdsa`           | `ecdsa-sk -O verify-required`   | Hardware-backed compatibility path                      | Use for older authenticators or estates without `ed25519-sk`     |
| `rsa3072` / `compat`   | `rsa -b 3072`                   | Conservative compatibility path                         | Uses RSA with SHA-2 signatures and forces 3072 bits              |
| `rsa4096`              | `rsa -b 4096`                   | Policy-driven larger RSA key                            | Use only when an explicit standard requires it; forces 4096 bits |
| `fips`                 | `rsa -b 3072`                   | FIPS-oriented or policy-constrained estate              | Provided as an explicit RSA alias                                |

The shipped defaults are:

- Software key default: `ed25519`
- Hardware key default: `ed25519-sk -O verify-required`
- Hardware fallback: `ecdsa-sk -O verify-required`
- RSA fallback: `rsa -b 3072`
- Avoid for new keys: `dsa`, `xmss`, PEM output, and legacy `ssh-rsa`/SHA-1

## Configuration model

The wrapper loads `sss-ssh-keygen.conf` from the directory that holds the
script by default, and continues with built-in defaults after a warning when
that file is absent. When the script is started through a symbolic link, for
example one placed in a directory on `PATH`, the directory of the link is
checked first and then the directory of the script the link points to. Use `--config PATH`, `--config=PATH`, or the
`SSS_SSH_KEYGEN_CONFIG` environment variable to load an alternate file; the
older `SSH_KEYGEN_SECURE_CONFIG` variable is still read at lower precedence. An
alternate file that does not exist is an error. Config files are
assignment-only: use plain `KEY=VALUE` lines, optionally quoted, and avoid
shell syntax or commands.

Exported `SSH_KEYGEN_*` variables remain supported for one-off overrides. The
effective precedence is: built-in defaults, then config-file values, then
exported environment overrides, then explicit CLI flags.

Supported configuration variables include:

- `SSH_KEYGEN_PROFILE`
- `SSH_KEYGEN_OUTPUT`
- `SSH_KEYGEN_OUTPUT_SUFFIX`
- `SSH_KEYGEN_COMMENT`
- `SSH_KEYGEN_COMMENT_USER`
- `SSH_KEYGEN_COMMENT_HOST`
- `SSH_KEYGEN_COMMENT_EMAIL`
- `SSH_KEYGEN_KDF_ROUNDS`
- `SSH_KEYGEN_CIPHER`
- `SSH_KEYGEN_RSA_BITS`
- `SSH_KEYGEN_EMPTY_PASSPHRASE`
- `SSH_KEYGEN_QUIET`
- `SSH_KEYGEN_DRY_RUN`
- `SSH_KEYGEN_USE_XDG_OUTPUT`
- `SSH_KEYGEN_FIDO_ALGORITHM`
- `SSH_KEYGEN_FIDO_APPLICATION`
- `SSH_KEYGEN_FIDO_VERIFY_REQUIRED`
- `SSH_KEYGEN_FIDO_RESIDENT`

For fixed RSA profiles, the profile name wins over `SSH_KEYGEN_RSA_BITS`:
`rsa3072` always uses 3072 bits and `rsa4096` always uses 4096 bits. Use the
`fips` profile when you need a configurable RSA bit size.

To use a different config file for a specific run:

```sh
./sss-ssh-keygen.sh --config /path/to/custom.conf --dry-run
```

Use `--use-xdg-output` when you want the default output path under
`$XDG_CONFIG_HOME/ssh` or, if that is unset, `$HOME/.config/ssh`.

Use `--output-suffix` or `SSH_KEYGEN_OUTPUT_SUFFIX` to keep the
profile-specific basename while adding a provider, account, or purpose slug.
For example, `--output-suffix github_unsigned_sh` creates
`id_ed25519_github_unsigned_sh` for the default software profile and
`id_ed25519_sk_github_unsigned_sh` for the default hardware profile. Suffixes
must start with a letter or digit and may contain only letters, digits, dots,
underscores, and hyphens. Two consecutive dots are rejected. Use
`--output PATH` instead when you need an exact path. An exact path replaces a
suffix from a less specific source, so `--output` or an exported
`SSH_KEYGEN_OUTPUT` still works when the config file sets
`SSH_KEYGEN_OUTPUT_SUFFIX`. A path and a suffix from the same source, or a
suffix on top of a path from a less specific source, are rejected.

Output paths are used literally. A config file is not shell-expanded, so
`SSH_KEYGEN_OUTPUT=~/.ssh/id_work` or a value that starts with `$` is rejected
instead of creating a directory with that name. Give a full path, or prefix
`./` when such a name is intentional.

The generated comment defaults to `user@host - YYYY-MM-DD`. Use
`--comment-user`, `--comment-host`, or `--comment-email` to refine the auto
comment without replacing it entirely. Use `--comment` for a full override.

## Operational notes

- Passphrase prompting is the default. Use `--empty-passphrase` only for
  machine accounts or non-interactive workflows that require it.
- Existing output paths are protected by default, including dangling symlinks
  that `ssh-keygen` would otherwise write through. Use `--force-overwrite` only
  when replacement is intentional. A symbolic link at the output path is
  replaced itself; the file it points to is left alone.
- `--force-overwrite` generates the new pair in a `.sss-ssh-keygen.*` staging
  directory next to the output and replaces the old pair only after
  `ssh-keygen` has produced both files. If a rename fails or the wrapper is
  interrupted, the previous files are put back and the new pair is discarded.
  The two renames remain separate steps: a wrapper that is killed outright
  between them, for example by `SIGKILL` or a power loss, can leave the new
  private key next to the old public key. The previous private key and the new
  public key are then still in the staging directory, and
  `ssh-keygen -y -f PATH` rebuilds a public key from the private key in place.
- The wrapper uses the OpenSSH private-key format and explicitly sets
  `aes256-ctr` for private-key encryption, matching current `ssh-keygen`
  defaults.
- The shipped KDF default is `100` bcrypt_pbkdf rounds. OpenSSH defaults to
  `16`; this project raises the cost as a practical baseline for current
  workstations.
- Extra arguments after `--` are an expert escape hatch. They are forwarded as
  given and can override wrapper-managed `ssh-keygen` options. The wrapper
  interprets two of them: `-f PATH` replaces the output path and receives the
  same overwrite protection, and `-t TYPE`, in any spelling `ssh-keygen`
  accepts, selects which type-specific defaults apply. An RSA type keeps the configured bit size, and a FIDO type keeps the
  application, `verify-required`, and resident settings. Use
  `--no-fido-verify-required` to create a FIDO key without `verify-required`.
- Resident keys are not the default. Enable them explicitly with
  `--fido-resident` if portability across hosts is worth the theft tradeoff for
  your use case.

## Repository contents

- `sss-ssh-keygen.sh`: canonical wrapper
- `sss-ssh-keygen.conf`: shipped default configuration
- `tests/run.sh`: shell test harness

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
