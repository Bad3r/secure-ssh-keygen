#!/usr/bin/env bash
set -euo pipefail

declare -ar VALID_PROFILES=(
  ed25519
  software
  fido-ecdsa
  hardware
  fido-ed25519
  rsa3072
  compat
  rsa4096
  fips
)

declare -A cli_values=()
declare -A cli_set=()
declare -A config_values=()
declare -A config_set=()

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

join_profiles() {
  local first=1
  local profile

  for profile in "${VALID_PROFILES[@]}"; do
    if [[ "$first" -eq 1 ]]; then
      printf '%s' "$profile"
      first=0
    else
      printf ', %s' "$profile"
    fi
  done
}

usage() {
  cat <<'EOF'
Usage: ./sss-ssh-keygen.sh [options] [-- <extra ssh-keygen args>]

Options:
  --config PATH                load defaults from an assignment-only config file
  --config=PATH                load defaults from an assignment-only config file
  --profile PROFILE            ed25519 | software | fido-ecdsa | hardware
                               | fido-ed25519 | rsa3072 | compat | rsa4096 | fips
  --output PATH                private key output path
  --comment TEXT               full key comment override
  --comment-user TEXT          override the generated comment username
  --comment-host TEXT          override the generated comment hostname
  --comment-email TEXT         append email to the generated comment
  --rounds N                   bcrypt_pbkdf rounds
  --cipher NAME                private-key encryption cipher, default aes256-ctr
  --rsa-bits N                 RSA bits for rsa* profiles
  --empty-passphrase           pass -N ""
  --use-xdg-output             place default keys under XDG_CONFIG_HOME/ssh
  --fido-algorithm NAME        ecdsa-sk | ed25519-sk, used with --profile hardware
  --fido-resident              add -O resident for FIDO profiles
  --no-fido-verify-required    omit -O verify-required for FIDO profiles
  --dry-run                    print the command and exit
  --quiet                      add -q
  --force-overwrite            atomically replace existing key material
  --help                       show this help

Config:
  The wrapper resolves the config path in this order:
    1. --config / --config=
    2. SSS_SSH_KEYGEN_CONFIG
    3. SSH_KEYGEN_SECURE_CONFIG
    4. ./sss-ssh-keygen.conf in the script directory

  Config files are parsed as assignment-only files. Supported variables:
    SSH_KEYGEN_PROFILE
    SSH_KEYGEN_OUTPUT
    SSH_KEYGEN_COMMENT
    SSH_KEYGEN_COMMENT_USER
    SSH_KEYGEN_COMMENT_HOST
    SSH_KEYGEN_COMMENT_EMAIL
    SSH_KEYGEN_KDF_ROUNDS
    SSH_KEYGEN_CIPHER
    SSH_KEYGEN_RSA_BITS
    SSH_KEYGEN_EMPTY_PASSPHRASE
    SSH_KEYGEN_QUIET
    SSH_KEYGEN_DRY_RUN
    SSH_KEYGEN_USE_XDG_OUTPUT
    SSH_KEYGEN_FIDO_ALGORITHM
    SSH_KEYGEN_FIDO_APPLICATION
    SSH_KEYGEN_FIDO_VERIFY_REQUIRED
    SSH_KEYGEN_FIDO_RESIDENT

  Extra ssh-keygen arguments passed after -- are an expert escape hatch.
  They are forwarded as-is and may override the wrapper's managed defaults.
EOF
}

trim_ascii_whitespace() {
  local value="$1"

  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

set_cli_value() {
  cli_values["$1"]="$2"
  cli_set["$1"]=1
}

set_config_value() {
  config_values["$1"]="$2"
  config_set["$1"]=1
}

valid_profiles_csv="$(join_profiles)"

parse_config_value() {
  local key="$1"
  local raw="$2"
  local config_path="$3"
  local line_number="$4"
  local first_char=""
  local last_char=""
  local length="${#raw}"

  if [[ "$length" -gt 0 ]]; then
    first_char="${raw:0:1}"
    last_char="${raw: -1}"
  fi

  if [[ "$first_char" == '"' ]]; then
    [[ "$length" -ge 2 && "$last_char" == '"' ]] ||
      die "Invalid double-quoted value for $key in $config_path:$line_number"
    printf '%s' "${raw:1:length-2}"
    return 0
  fi

  if [[ "$first_char" == "'" ]]; then
    [[ "$length" -ge 2 && "$last_char" == "'" ]] ||
      die "Invalid single-quoted value for $key in $config_path:$line_number"
    printf '%s' "${raw:1:length-2}"
    return 0
  fi

  [[ "$raw" != *$'\t'* && "$raw" != *' '* && "$raw" != *$'\r'* && "$raw" != *$'\n'* ]] ||
    die "Unquoted whitespace is not allowed for $key in $config_path:$line_number"

  printf '%s' "$raw"
}

config_field_for_key() {
  case "$1" in
  SSH_KEYGEN_PROFILE) printf 'profile' ;;
  SSH_KEYGEN_OUTPUT) printf 'output' ;;
  SSH_KEYGEN_COMMENT) printf 'comment' ;;
  SSH_KEYGEN_COMMENT_USER) printf 'comment_user' ;;
  SSH_KEYGEN_COMMENT_HOST) printf 'comment_host' ;;
  SSH_KEYGEN_COMMENT_EMAIL) printf 'comment_email' ;;
  SSH_KEYGEN_KDF_ROUNDS) printf 'rounds' ;;
  SSH_KEYGEN_CIPHER) printf 'cipher' ;;
  SSH_KEYGEN_RSA_BITS) printf 'rsa_bits' ;;
  SSH_KEYGEN_EMPTY_PASSPHRASE) printf 'empty_passphrase' ;;
  SSH_KEYGEN_QUIET) printf 'quiet' ;;
  SSH_KEYGEN_DRY_RUN) printf 'dry_run' ;;
  SSH_KEYGEN_USE_XDG_OUTPUT) printf 'use_xdg_output' ;;
  SSH_KEYGEN_FIDO_ALGORITHM) printf 'fido_algorithm' ;;
  SSH_KEYGEN_FIDO_APPLICATION) printf 'fido_application' ;;
  SSH_KEYGEN_FIDO_VERIFY_REQUIRED) printf 'fido_verify_required' ;;
  SSH_KEYGEN_FIDO_RESIDENT) printf 'fido_resident' ;;
  *)
    return 1
    ;;
  esac
}

load_config_file() {
  local config_path="$1"
  local line=""
  local trimmed=""
  local key=""
  local raw_value=""
  local parsed_value=""
  local field=""
  local line_number=0
  declare -A seen_keys=()

  [[ -e "$config_path" ]] || die "Config file not found: $config_path"
  [[ -r "$config_path" ]] || die "Config file is not readable: $config_path"
  [[ -f "$config_path" ]] || die "Config file must be a regular file: $config_path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    trimmed="$(trim_ascii_whitespace "$line")"

    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

    if [[ ! "$trimmed" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      die "Invalid config syntax in $config_path:$line_number"
    fi

    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"

    field="$(config_field_for_key "$key")" ||
      die "Unsupported config key $key in $config_path:$line_number"

    [[ -z "${seen_keys[$key]:-}" ]] ||
      die "Duplicate config key $key in $config_path:$line_number"
    seen_keys["$key"]=1

    parsed_value="$(parse_config_value "$key" "$raw_value" "$config_path" "$line_number")"
    set_config_value "$field" "$parsed_value"
  done < "$config_path"
}

parse_cli() {
  local option_value=""

  while (($#)); do
    case "$1" in
    --config)
      (($# >= 2)) || usage_error "--config requires a path"
      [[ -n "$2" ]] || usage_error "--config requires a path"
      set_cli_value "config_path" "$2"
      shift 2
      ;;
    --config=*)
      option_value="${1#*=}"
      [[ -n "$option_value" ]] || usage_error "--config requires a path"
      set_cli_value "config_path" "$option_value"
      shift
      ;;
    --profile)
      (($# >= 2)) || usage_error "--profile requires a value"
      set_cli_value "profile" "$2"
      shift 2
      ;;
    --profile=*)
      set_cli_value "profile" "${1#*=}"
      shift
      ;;
    --output)
      (($# >= 2)) || usage_error "--output requires a value"
      set_cli_value "output" "$2"
      shift 2
      ;;
    --output=*)
      set_cli_value "output" "${1#*=}"
      shift
      ;;
    --comment)
      (($# >= 2)) || usage_error "--comment requires a value"
      set_cli_value "comment" "$2"
      shift 2
      ;;
    --comment=*)
      set_cli_value "comment" "${1#*=}"
      shift
      ;;
    --comment-user)
      (($# >= 2)) || usage_error "--comment-user requires a value"
      set_cli_value "comment_user" "$2"
      shift 2
      ;;
    --comment-user=*)
      set_cli_value "comment_user" "${1#*=}"
      shift
      ;;
    --comment-host)
      (($# >= 2)) || usage_error "--comment-host requires a value"
      set_cli_value "comment_host" "$2"
      shift 2
      ;;
    --comment-host=*)
      set_cli_value "comment_host" "${1#*=}"
      shift
      ;;
    --comment-email)
      (($# >= 2)) || usage_error "--comment-email requires a value"
      set_cli_value "comment_email" "$2"
      shift 2
      ;;
    --comment-email=*)
      set_cli_value "comment_email" "${1#*=}"
      shift
      ;;
    --rounds)
      (($# >= 2)) || usage_error "--rounds requires a value"
      set_cli_value "rounds" "$2"
      shift 2
      ;;
    --rounds=*)
      set_cli_value "rounds" "${1#*=}"
      shift
      ;;
    --cipher)
      (($# >= 2)) || usage_error "--cipher requires a value"
      set_cli_value "cipher" "$2"
      shift 2
      ;;
    --cipher=*)
      set_cli_value "cipher" "${1#*=}"
      shift
      ;;
    --rsa-bits)
      (($# >= 2)) || usage_error "--rsa-bits requires a value"
      set_cli_value "rsa_bits" "$2"
      shift 2
      ;;
    --rsa-bits=*)
      set_cli_value "rsa_bits" "${1#*=}"
      shift
      ;;
    --empty-passphrase)
      set_cli_value "empty_passphrase" "1"
      shift
      ;;
    --use-xdg-output)
      set_cli_value "use_xdg_output" "1"
      shift
      ;;
    --fido-algorithm)
      (($# >= 2)) || usage_error "--fido-algorithm requires a value"
      set_cli_value "fido_algorithm" "$2"
      shift 2
      ;;
    --fido-algorithm=*)
      set_cli_value "fido_algorithm" "${1#*=}"
      shift
      ;;
    --fido-resident)
      set_cli_value "fido_resident" "1"
      shift
      ;;
    --no-fido-verify-required)
      set_cli_value "fido_verify_required" "0"
      shift
      ;;
    --dry-run)
      set_cli_value "dry_run" "1"
      shift
      ;;
    --quiet)
      set_cli_value "quiet" "1"
      shift
      ;;
    --force-overwrite)
      set_cli_value "force_overwrite" "1"
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
      usage_error "Unknown option: $1"
      ;;
    esac
  done
}

apply_config_values() {
  [[ "${config_set[profile]:-0}" == 1 ]] && profile="${config_values[profile]}"
  [[ "${config_set[output]:-0}" == 1 ]] && output="${config_values[output]}"
  [[ "${config_set[comment]:-0}" == 1 ]] && comment="${config_values[comment]}"
  [[ "${config_set[comment_user]:-0}" == 1 ]] && comment_user="${config_values[comment_user]}"
  [[ "${config_set[comment_host]:-0}" == 1 ]] && comment_host="${config_values[comment_host]}"
  [[ "${config_set[comment_email]:-0}" == 1 ]] && comment_email="${config_values[comment_email]}"
  [[ "${config_set[rounds]:-0}" == 1 ]] && rounds="${config_values[rounds]}"
  [[ "${config_set[cipher]:-0}" == 1 ]] && cipher="${config_values[cipher]}"
  [[ "${config_set[rsa_bits]:-0}" == 1 ]] && rsa_bits="${config_values[rsa_bits]}"
  [[ "${config_set[empty_passphrase]:-0}" == 1 ]] && empty_passphrase="${config_values[empty_passphrase]}"
  [[ "${config_set[quiet]:-0}" == 1 ]] && quiet="${config_values[quiet]}"
  [[ "${config_set[dry_run]:-0}" == 1 ]] && dry_run="${config_values[dry_run]}"
  [[ "${config_set[use_xdg_output]:-0}" == 1 ]] && use_xdg_output="${config_values[use_xdg_output]}"
  [[ "${config_set[fido_algorithm]:-0}" == 1 ]] && fido_algorithm="${config_values[fido_algorithm]}"
  [[ "${config_set[fido_application]:-0}" == 1 ]] && fido_application="${config_values[fido_application]}"
  [[ "${config_set[fido_verify_required]:-0}" == 1 ]] && fido_verify_required="${config_values[fido_verify_required]}"
  [[ "${config_set[fido_resident]:-0}" == 1 ]] && fido_resident="${config_values[fido_resident]}"
  return 0
}

apply_cli_values() {
  [[ "${cli_set[profile]:-0}" == 1 ]] && profile="${cli_values[profile]}"
  [[ "${cli_set[output]:-0}" == 1 ]] && output="${cli_values[output]}"
  [[ "${cli_set[comment]:-0}" == 1 ]] && comment="${cli_values[comment]}"
  [[ "${cli_set[comment_user]:-0}" == 1 ]] && comment_user="${cli_values[comment_user]}"
  [[ "${cli_set[comment_host]:-0}" == 1 ]] && comment_host="${cli_values[comment_host]}"
  [[ "${cli_set[comment_email]:-0}" == 1 ]] && comment_email="${cli_values[comment_email]}"
  [[ "${cli_set[rounds]:-0}" == 1 ]] && rounds="${cli_values[rounds]}"
  [[ "${cli_set[cipher]:-0}" == 1 ]] && cipher="${cli_values[cipher]}"
  [[ "${cli_set[rsa_bits]:-0}" == 1 ]] && rsa_bits="${cli_values[rsa_bits]}"
  [[ "${cli_set[empty_passphrase]:-0}" == 1 ]] && empty_passphrase="${cli_values[empty_passphrase]}"
  [[ "${cli_set[quiet]:-0}" == 1 ]] && quiet="${cli_values[quiet]}"
  [[ "${cli_set[dry_run]:-0}" == 1 ]] && dry_run="${cli_values[dry_run]}"
  [[ "${cli_set[use_xdg_output]:-0}" == 1 ]] && use_xdg_output="${cli_values[use_xdg_output]}"
  [[ "${cli_set[fido_algorithm]:-0}" == 1 ]] && fido_algorithm="${cli_values[fido_algorithm]}"
  [[ "${cli_set[fido_application]:-0}" == 1 ]] && fido_application="${cli_values[fido_application]}"
  [[ "${cli_set[fido_verify_required]:-0}" == 1 ]] && fido_verify_required="${cli_values[fido_verify_required]}"
  [[ "${cli_set[fido_resident]:-0}" == 1 ]] && fido_resident="${cli_values[fido_resident]}"
  [[ "${cli_set[force_overwrite]:-0}" == 1 ]] && force_overwrite="${cli_values[force_overwrite]}"
  return 0
}

require_boolean() {
  local value="$1"
  local name="$2"

  case "$value" in
  0 | 1) ;;
  *)
    die "$name must be 0 or 1"
    ;;
  esac
}

stat_mode() {
  local target="$1"
  local mode=""

  mode="$(stat -c '%a' -- "$target" 2>/dev/null || true)"
  if [[ -n "$mode" ]]; then
    printf '%s' "$mode"
    return 0
  fi

  mode="$(stat -f '%Lp' -- "$target" 2>/dev/null || true)"
  if [[ -n "$mode" ]]; then
    printf '%s' "$mode"
    return 0
  fi

  return 1
}

resolve_default_output_dir() {
  if [[ "$use_xdg_output" -eq 1 ]]; then
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
      printf '%s/ssh' "$XDG_CONFIG_HOME"
      return 0
    fi

    [[ -n "${HOME:-}" ]] ||
      die "XDG output requested but neither XDG_CONFIG_HOME nor HOME is set"

    printf '%s/.config/ssh' "$HOME"
    return 0
  fi

  [[ -n "${HOME:-}" ]] ||
    die "HOME must be set unless --output or SSH_KEYGEN_OUTPUT specifies a path"

  printf '%s/.ssh' "$HOME"
}

repair_managed_dir_permissions() {
  local directory="$1"
  local mode=""

  [[ -n "$directory" && -d "$directory" ]] || return 0

  mode="$(stat_mode "$directory")" ||
    die "Unable to determine permissions for $directory"

  if [[ "$mode" != "700" ]]; then
    warn "Correcting permissions on $directory to 700"
    chmod 700 -- "$directory"
  fi
}

resolve_identity_user() {
  if [[ -n "$comment_user" ]]; then
    printf '%s' "$comment_user"
    return 0
  fi

  if [[ -n "${USER:-}" ]]; then
    printf '%s' "$USER"
    return 0
  fi

  id -un 2>/dev/null || true
}

resolve_identity_host() {
  if [[ -n "$comment_host" ]]; then
    printf '%s' "$comment_host"
    return 0
  fi

  if [[ -n "${HOSTNAME:-}" ]]; then
    printf '%s' "$HOSTNAME"
    return 0
  fi

  hostname 2>/dev/null || true
}

build_default_comment() {
  local resolved_user=""
  local resolved_host=""
  local today=""

  resolved_user="$(resolve_identity_user)"
  resolved_host="$(resolve_identity_host)"
  today="$(date +%F)"

  [[ -n "$resolved_user" ]] ||
    die "Unable to determine a default comment user; use --comment or --comment-user"
  [[ -n "$resolved_host" ]] ||
    die "Unable to determine a default comment host; use --comment or --comment-host"

  if [[ -n "$comment_email" ]]; then
    printf '%s@%s - %s - %s' "$resolved_user" "$resolved_host" "$comment_email" "$today"
    return 0
  fi

  printf '%s@%s - %s' "$resolved_user" "$resolved_host" "$today"
}

parse_openssh_version() {
  local version_output=""

  version_output="$(ssh -V 2>&1)" ||
    die "Failed to determine OpenSSH version via ssh -V"

  if [[ "$version_output" =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  die "Unable to parse OpenSSH version from: $version_output"
}

version_at_least() {
  local have_major="$1"
  local have_minor="$2"
  local need_major="$3"
  local need_minor="$4"

  if ((have_major > need_major)); then
    return 0
  fi

  if ((have_major < need_major)); then
    return 1
  fi

  ((have_minor >= need_minor))
}

validate_fido_version_requirements() {
  local version_fields=""
  local have_major=""
  local have_minor=""
  local minimum_major=8
  local minimum_minor=2
  local minimum_label="8.2"

  [[ "$key_type" == *"-sk" ]] || return 0

  if [[ "$fido_verify_required" -eq 1 ]]; then
    minimum_minor=4
    minimum_label="8.4"
  fi

  version_fields="$(parse_openssh_version)"
  have_major="${version_fields%% *}"
  have_minor="${version_fields##* }"

  if ! version_at_least "$have_major" "$have_minor" "$minimum_major" "$minimum_minor"; then
    die "OpenSSH $minimum_label or newer is required for the selected FIDO options"
  fi
}

create_temp_output_dir() {
  local output_dir="$1"
  mktemp -d "$output_dir/.sss-ssh-keygen.XXXXXX"
}

cleanup_temp_artifacts() {
  if [[ -n "${temp_output:-}" ]]; then
    rm -f -- "$temp_output" "${temp_output}.pub"
  fi

  if [[ -n "${temp_dir:-}" ]]; then
    rmdir -- "$temp_dir" 2>/dev/null || true
  fi
}

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
config_path="${SSS_SSH_KEYGEN_CONFIG:-${SSH_KEYGEN_SECURE_CONFIG:-$script_dir/sss-ssh-keygen.conf}}"
extra_ssh_keygen_args=()

parse_cli "$@"
[[ "${cli_set[config_path]:-0}" == 1 ]] && config_path="${cli_values[config_path]}"
load_config_file "$config_path"

profile="ed25519"
rounds="100"
rsa_bits="3072"
cipher="aes256-ctr"
comment=""
comment_user=""
comment_host=""
comment_email=""
output=""
empty_passphrase="0"
quiet="0"
dry_run="0"
force_overwrite="0"
use_xdg_output="0"
fido_algorithm="ed25519-sk"
fido_verify_required="1"
fido_resident="0"
fido_application="ssh:"

apply_config_values
apply_cli_values

config_rsa_bits_is_override=0
if [[ "${config_set[rsa_bits]:-0}" == 1 && "${config_values[rsa_bits]}" != "" && "${config_values[rsa_bits]}" != "3072" ]]; then
  config_rsa_bits_is_override=1
fi

require_boolean "$empty_passphrase" "SSH_KEYGEN_EMPTY_PASSPHRASE"
require_boolean "$quiet" "SSH_KEYGEN_QUIET"
require_boolean "$dry_run" "SSH_KEYGEN_DRY_RUN"
require_boolean "$force_overwrite" "--force-overwrite"
require_boolean "$use_xdg_output" "SSH_KEYGEN_USE_XDG_OUTPUT"
require_boolean "$fido_verify_required" "SSH_KEYGEN_FIDO_VERIFY_REQUIRED"
require_boolean "$fido_resident" "SSH_KEYGEN_FIDO_RESIDENT"

if [[ ! "$rounds" =~ ^[0-9]+$ ]] || [[ "$rounds" -lt 1 ]]; then
  usage_error "Invalid rounds value: $rounds"
fi

case "$profile" in
ed25519 | software)
  key_type="ed25519"
  canonical_profile="ed25519"
  default_output_basename="id_ed25519"
  ;;
fido-ecdsa)
  key_type="ecdsa-sk"
  canonical_profile="fido-ecdsa"
  default_output_basename="id_ecdsa_sk"
  ;;
hardware)
  case "$fido_algorithm" in
  ecdsa-sk | ed25519-sk)
    key_type="$fido_algorithm"
    ;;
  *)
    usage_error "--fido-algorithm must be ecdsa-sk or ed25519-sk"
    ;;
  esac
  canonical_profile="hardware"
  default_output_basename="id_${key_type//-/_}"
  ;;
fido-ed25519)
  key_type="ed25519-sk"
  canonical_profile="fido-ed25519"
  default_output_basename="id_ed25519_sk"
  ;;
rsa3072 | compat)
  key_type="rsa"
  canonical_profile="rsa3072"
  default_output_basename="id_rsa_3072"
  if [[ "${cli_set[rsa_bits]:-0}" == 1 && "${cli_values[rsa_bits]}" != "3072" ]]; then
    usage_error "--rsa-bits conflicts with the fixed-size $profile profile"
  fi
  if [[ "$config_rsa_bits_is_override" -eq 1 && "${config_values[rsa_bits]}" != "3072" ]]; then
    usage_error "SSH_KEYGEN_RSA_BITS conflicts with the fixed-size $profile profile"
  fi
  rsa_bits="3072"
  ;;
rsa4096)
  key_type="rsa"
  canonical_profile="rsa4096"
  default_output_basename="id_rsa_4096"
  if [[ "${cli_set[rsa_bits]:-0}" == 1 && "${cli_values[rsa_bits]}" != "4096" ]]; then
    usage_error "--rsa-bits conflicts with the fixed-size $profile profile"
  fi
  if [[ "$config_rsa_bits_is_override" -eq 1 && "${config_values[rsa_bits]}" != "4096" ]]; then
    usage_error "SSH_KEYGEN_RSA_BITS conflicts with the fixed-size $profile profile"
  fi
  rsa_bits="4096"
  ;;
fips)
  key_type="rsa"
  canonical_profile="fips"
  default_output_basename="id_rsa_fips"
  ;;
*)
  usage_error "Unsupported profile: $profile. Valid profiles: $valid_profiles_csv"
  ;;
esac

if [[ "$key_type" == "rsa" ]]; then
  if [[ ! "$rsa_bits" =~ ^[0-9]+$ ]] || [[ "$rsa_bits" -lt 3072 ]]; then
    usage_error "Invalid RSA bit size: $rsa_bits"
  fi
fi

case "$fido_application" in
ssh:*) ;;
*)
  usage_error "SSH_KEYGEN_FIDO_APPLICATION must start with ssh:"
  ;;
esac

if [[ -z "$output" ]]; then
  managed_output_dir="$(resolve_default_output_dir)"
  output="$managed_output_dir/$default_output_basename"
else
  managed_output_dir=""
fi

output_dir="$(dirname -- "$output")"

if [[ -z "$comment" ]]; then
  comment="$(build_default_comment)"
fi

validate_fido_version_requirements

display_cmd=(ssh-keygen -o -t "$key_type" -a "$rounds" -Z "$cipher" -C "$comment" -f "$output")
if [[ "$key_type" == "rsa" ]]; then
  display_cmd+=(-b "$rsa_bits")
fi
if [[ "$empty_passphrase" -eq 1 ]]; then
  display_cmd+=(-N "")
fi
if [[ "$quiet" -eq 1 ]]; then
  display_cmd+=(-q)
fi
if [[ "$key_type" == *"-sk" ]]; then
  display_cmd+=(-O "application=${fido_application}")
  if [[ "$fido_verify_required" -eq 1 ]]; then
    display_cmd+=(-O verify-required)
  fi
  if [[ "$fido_resident" -eq 1 ]]; then
    display_cmd+=(-O resident)
  fi
fi
if ((${#extra_ssh_keygen_args[@]})); then
  display_cmd+=("${extra_ssh_keygen_args[@]}")
fi

if [[ "$dry_run" -eq 1 ]]; then
  printf 'profile: %s\n' "$canonical_profile"
  printf 'output: %s\n' "$output"
  printf 'command:'
  printf ' %q' "${display_cmd[@]}"
  printf '\n'
  exit 0
fi

umask 077

if [[ ! -d "$output_dir" ]]; then
  mkdir -p -- "$output_dir"
fi

repair_managed_dir_permissions "$managed_output_dir"

if [[ -e "$output" || -e "${output}.pub" ]] && [[ "$force_overwrite" -ne 1 ]]; then
  die "Refusing to overwrite existing key material at $output. Use --force-overwrite if replacement is intentional."
fi

temp_dir=""
temp_output=""
cmd_output="$output"
trap cleanup_temp_artifacts EXIT

if [[ "$force_overwrite" -eq 1 ]]; then
  temp_dir="$(create_temp_output_dir "$output_dir")"
  temp_output="$temp_dir/$(basename -- "$output")"
  cmd_output="$temp_output"
fi

cmd=(ssh-keygen -o -t "$key_type" -a "$rounds" -Z "$cipher" -C "$comment" -f "$cmd_output")
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

printf 'Executing:'
printf ' %q' "${display_cmd[@]}"
printf '\n'

"${cmd[@]}"

if [[ "$force_overwrite" -eq 1 ]]; then
  mv -f -- "$temp_output" "$output"
  mv -f -- "${temp_output}.pub" "${output}.pub"
  temp_output=""
  rmdir -- "$temp_dir"
  temp_dir=""
fi
