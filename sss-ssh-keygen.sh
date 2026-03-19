#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./sss-ssh-keygen.sh [options] [-- <extra ssh-keygen args>]

Options:
  --config PATH                source defaults from a shell-style config file
  --profile PROFILE            ed25519 | software | fido-ecdsa | hardware
                               | fido-ed25519 | rsa3072 | compat | rsa4096 | fips
  --output PATH                private key output path
  --comment TEXT               key comment
  --rounds N                   bcrypt_pbkdf rounds
  --cipher NAME                private-key encryption cipher, default aes256-ctr
  --rsa-bits N                 RSA bits for rsa* profiles
  --empty-passphrase           pass -N ""
  --fido-algorithm NAME        ecdsa-sk | ed25519-sk, used with --profile hardware
  --fido-resident              add -O resident for FIDO profiles
  --no-fido-verify-required    omit -O verify-required for FIDO profiles
  --dry-run                    print the command and exit
  --quiet                      add -q
  --force-overwrite            replace existing key material at output path
  --help                       show this help

Config:
  The wrapper loads SSS_SSH_KEYGEN_CONFIG if set, otherwise it looks for
  ./sss-ssh-keygen.conf in the script directory. Supported variables:
    SSH_KEYGEN_PROFILE
    SSH_KEYGEN_OUTPUT
    SSH_KEYGEN_COMMENT
    SSH_KEYGEN_KDF_ROUNDS
    SSH_KEYGEN_CIPHER
    SSH_KEYGEN_RSA_BITS
    SSH_KEYGEN_EMPTY_PASSPHRASE
    SSH_KEYGEN_QUIET
    SSH_KEYGEN_DRY_RUN
    SSH_KEYGEN_FIDO_ALGORITHM
    SSH_KEYGEN_FIDO_APPLICATION
    SSH_KEYGEN_FIDO_VERIFY_REQUIRED
    SSH_KEYGEN_FIDO_RESIDENT
EOF
}

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
config_path="${SSS_SSH_KEYGEN_CONFIG:-${SSH_KEYGEN_SECURE_CONFIG:-$script_dir/sss-ssh-keygen.conf}}"
args=("$@")

for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[i]}" == "--config" ]]; then
    ((i + 1 < ${#args[@]})) || die "--config requires a path"
    config_path="${args[i+1]}"
    break
  fi
done

if [[ -f "$config_path" ]]; then
  # shellcheck disable=SC1090
  . "$config_path"
fi

profile="${SSH_KEYGEN_PROFILE:-ed25519}"
rounds="${SSH_KEYGEN_KDF_ROUNDS:-100}"
rsa_bits="${SSH_KEYGEN_RSA_BITS:-3072}"
cipher="${SSH_KEYGEN_CIPHER:-aes256-ctr}"
comment="${SSH_KEYGEN_COMMENT:-}"
output="${SSH_KEYGEN_OUTPUT:-}"
empty_passphrase="${SSH_KEYGEN_EMPTY_PASSPHRASE:-0}"
quiet="${SSH_KEYGEN_QUIET:-0}"
dry_run="${SSH_KEYGEN_DRY_RUN:-0}"
fido_algorithm="${SSH_KEYGEN_FIDO_ALGORITHM:-ed25519-sk}"
fido_verify_required="${SSH_KEYGEN_FIDO_VERIFY_REQUIRED:-1}"
fido_resident="${SSH_KEYGEN_FIDO_RESIDENT:-0}"
fido_application="${SSH_KEYGEN_FIDO_APPLICATION:-ssh:}"
force_overwrite=0

extra_ssh_keygen_args=()

while (($#)); do
  case "$1" in
  --config)
    shift 2
    ;;
  --profile)
    profile="$2"
    shift 2
    ;;
  --output)
    output="$2"
    shift 2
    ;;
  --comment)
    comment="$2"
    shift 2
    ;;
  --rounds)
    rounds="$2"
    shift 2
    ;;
  --cipher)
    cipher="$2"
    shift 2
    ;;
  --rsa-bits)
    rsa_bits="$2"
    shift 2
    ;;
  --empty-passphrase)
    empty_passphrase=1
    shift
    ;;
  --fido-algorithm)
    fido_algorithm="$2"
    shift 2
    ;;
  --fido-resident)
    fido_resident=1
    shift
    ;;
  --no-fido-verify-required)
    fido_verify_required=0
    shift
    ;;
  --dry-run)
    dry_run=1
    shift
    ;;
  --quiet)
    quiet=1
    shift
    ;;
  --force-overwrite)
    force_overwrite=1
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  --)
    shift
    extra_ssh_keygen_args=("$@")
    break
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

case "$profile" in
ed25519 | software)
  key_type="ed25519"
  canonical_profile="ed25519"
  default_output="$HOME/.ssh/id_ed25519"
  ;;
fido-ecdsa)
  key_type="ecdsa-sk"
  canonical_profile="fido-ecdsa"
  default_output="$HOME/.ssh/id_ecdsa_sk"
  ;;
hardware)
  case "$fido_algorithm" in
  ecdsa-sk | ed25519-sk)
    key_type="$fido_algorithm"
    ;;
  *)
    die "--fido-algorithm must be ecdsa-sk or ed25519-sk"
    ;;
  esac
  canonical_profile="hardware"
  default_output="$HOME/.ssh/id_${key_type//-/_}"
  ;;
fido-ed25519)
  key_type="ed25519-sk"
  canonical_profile="fido-ed25519"
  default_output="$HOME/.ssh/id_ed25519_sk"
  ;;
rsa3072 | compat)
  key_type="rsa"
  canonical_profile="rsa3072"
  rsa_bits=3072
  default_output="$HOME/.ssh/id_rsa_3072"
  ;;
rsa4096)
  key_type="rsa"
  canonical_profile="rsa4096"
  rsa_bits=4096
  default_output="$HOME/.ssh/id_rsa_4096"
  ;;
fips)
  key_type="rsa"
  canonical_profile="fips"
  default_output="$HOME/.ssh/id_rsa_fips"
  ;;
*)
  printf 'Unsupported profile: %s\n' "$profile" >&2
  exit 2
  ;;
esac

if [[ ! "$rounds" =~ ^[0-9]+$ ]] || [[ "$rounds" -lt 1 ]]; then
  printf 'Invalid rounds value: %s\n' "$rounds" >&2
  exit 2
fi

case "$empty_passphrase" in
0 | 1) ;;
*) die "SSH_KEYGEN_EMPTY_PASSPHRASE must be 0 or 1" ;;
esac
case "$quiet" in
0 | 1) ;;
*) die "SSH_KEYGEN_QUIET must be 0 or 1" ;;
esac
case "$dry_run" in
0 | 1) ;;
*) die "SSH_KEYGEN_DRY_RUN must be 0 or 1" ;;
esac
case "$fido_verify_required" in
0 | 1) ;;
*) die "SSH_KEYGEN_FIDO_VERIFY_REQUIRED must be 0 or 1" ;;
esac
case "$fido_resident" in
0 | 1) ;;
*) die "SSH_KEYGEN_FIDO_RESIDENT must be 0 or 1" ;;
esac
case "$fido_application" in
ssh:*) ;;
*) die "SSH_KEYGEN_FIDO_APPLICATION must start with ssh:" ;;
esac

if [[ "$key_type" == "rsa" ]]; then
  if [[ ! "$rsa_bits" =~ ^[0-9]+$ ]] || [[ "$rsa_bits" -lt 3072 ]]; then
    printf 'Invalid RSA bit size: %s\n' "$rsa_bits" >&2
    exit 2
  fi
fi

output="${output:-$default_output}"
output_dir="$(dirname -- "$output")"

if [[ -z "$comment" ]]; then
  comment="ssh-${canonical_profile}-$(date +%F)"
fi

cmd=(ssh-keygen -o -t "$key_type" -a "$rounds" -Z "$cipher" -C "$comment" -f "$output")

if [[ "$key_type" == "rsa" ]]; then
  cmd+=(-b "$rsa_bits")
fi

if [[ "$empty_passphrase" -eq 1 ]]; then
  cmd+=(-N "")
fi

if [[ "$quiet" -eq 1 ]]; then
  cmd+=(-q)
fi

if [[ "$key_type" == *"-sk" ]]; then
  cmd+=(-O "application=${fido_application}")
  if [[ "$fido_verify_required" -eq 1 ]]; then
    cmd+=(-O verify-required)
  fi
  if [[ "$fido_resident" -eq 1 ]]; then
    cmd+=(-O resident)
  fi
fi

if ((${#extra_ssh_keygen_args[@]})); then
  cmd+=("${extra_ssh_keygen_args[@]}")
fi

umask 077

if [[ "$dry_run" -eq 1 ]]; then
  printf 'profile: %s\n' "$canonical_profile"
  printf 'output: %s\n' "$output"
  printf 'command:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  exit 0
fi

if [[ ! -d "$output_dir" ]]; then
  mkdir -p -- "$output_dir"
fi
if [[ "$output_dir" == "$HOME/.ssh" && -w "$output_dir" ]]; then
  chmod 700 -- "$output_dir"
fi

if [[ -e "$output" || -e "${output}.pub" ]] && [[ "$force_overwrite" -ne 1 ]]; then
  printf 'Refusing to overwrite existing key material at %s\n' "$output" >&2
  printf 'Use --force-overwrite if replacement is intentional.\n' >&2
  exit 1
fi

if [[ "$force_overwrite" -eq 1 ]]; then
  rm -f -- "$output" "${output}.pub"
fi

printf 'Executing:'
printf ' %q' "${cmd[@]}"
printf '\n'
exec "${cmd[@]}"
