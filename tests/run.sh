#!/usr/bin/env bash
set -uo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
script_path="$repo_root/sss-ssh-keygen.sh"
if [[ -n "${TEST_BASH:-}" ]]; then
  test_bash="$TEST_BASH"
elif [[ -x /bin/bash ]]; then
  test_bash="/bin/bash"
else
  test_bash="bash"
fi

failures=0
test_count=0

cleanup_paths=()
cleanup_paths_present=0

cleanup() {
  local path=""

  if [[ "$cleanup_paths_present" -ne 1 ]]; then
    return 0
  fi

  for path in "${cleanup_paths[@]}"; do
    rm -rf -- "$path"
  done
}

trap cleanup EXIT

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_script() {
  local target="$1"
  shift

  "$test_bash" "$target" "$@"
}

run_wrapper() {
  run_script "$script_path" "$@"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  local label="$3"

  if ! grep -Fq -- "$needle" "$file"; then
    record_failure "$label"
    printf '  expected to find: %s\n' "$needle" >&2
    printf '  file contents:\n' >&2
    sed 's/^/    /' "$file" >&2
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  local label="$3"

  if grep -Fq -- "$needle" "$file"; then
    record_failure "$label"
    printf '  unexpected content: %s\n' "$needle" >&2
    printf '  file contents:\n' >&2
    sed 's/^/    /' "$file" >&2
  fi
}

assert_no_match() {
  local pattern="$1"
  local file="$2"
  local label="$3"

  if grep -Eq "$pattern" "$file"; then
    record_failure "$label"
    printf '  unexpected pattern: %s\n' "$pattern" >&2
    printf '  file contents:\n' >&2
    sed 's/^/    /' "$file" >&2
  fi
}

assert_not_exists() {
  local path="$1"
  local label="$2"

  if [[ -e "$path" ]]; then
    record_failure "$label"
    printf '  unexpected path exists: %s\n' "$path" >&2
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$expected" != "$actual" ]]; then
    record_failure "$label"
    printf '  expected: %s\n' "$expected" >&2
    printf '  actual:   %s\n' "$actual" >&2
  fi
}

new_tempdir() {
  local dir
  dir="$(mktemp -d)"
  cleanup_paths+=("$dir")
  cleanup_paths_present=1
  printf '%s' "$dir"
}

write_stub_binaries() {
  local bin_dir="$1"

  cat >"$bin_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SSS_TEST_SSH_VERSION:-OpenSSH_10.2p1, OpenSSL test}" >&2
EOF

  cat >"$bin_dir/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
comment=""
log_path="${SSS_TEST_SSH_KEYGEN_LOG:-}"

while (($#)); do
  case "$1" in
  -f)
    output="$2"
    shift 2
    ;;
  -C)
    comment="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

if [[ -n "$log_path" ]]; then
  {
    printf 'output=%s\n' "$output"
    printf 'comment=%s\n' "$comment"
  } >"$log_path"
fi

case "${SSS_TEST_SSH_KEYGEN_MODE:-success}" in
success)
  printf '%s\n' "${SSS_TEST_PRIVATE_CONTENT:-stub-private}" >"$output"
  printf '%s\n' "${SSS_TEST_PUBLIC_CONTENT:-stub-public}" >"${output}.pub"
  ;;
fail)
  printf 'stub ssh-keygen failure\n' >&2
  exit 1
  ;;
*)
  printf 'unknown stub mode\n' >&2
  exit 2
  ;;
esac
EOF

  chmod +x "$bin_dir/ssh" "$bin_dir/ssh-keygen"
}

write_no_double_dash_shim() {
  local bin_dir="$1"
  local command_name="$2"
  local real_path="$3"
  local original_path="$4"

  cat >"$bin_dir/$command_name" <<EOF
#!/bin/sh
set -eu

for arg in "\$@"; do
  if [ "\$arg" = "--" ]; then
    printf 'shim-%s: unsupported --\n' "$command_name" >&2
    exit 64
  fi
done

PATH='$original_path'
export PATH
exec "$real_path" "\$@"
EOF

  chmod +x "$bin_dir/$command_name"
}

write_bsd_portability_shims() {
  local bin_dir="$1"
  local original_path="$PATH"

  write_no_double_dash_shim "$bin_dir" "chmod" "$(command -v chmod)" "$original_path"
  write_no_double_dash_shim "$bin_dir" "mkdir" "$(command -v mkdir)" "$original_path"
  write_no_double_dash_shim "$bin_dir" "mv" "$(command -v mv)" "$original_path"
  write_no_double_dash_shim "$bin_dir" "rmdir" "$(command -v rmdir)" "$original_path"
}

run_case() {
  local name="$1"
  shift

  test_count=$((test_count + 1))
  printf 'ok: %s\n' "$name"
  "$@"
}

case_no_bash4_assoc_arrays() {
  assert_not_contains "declare -A" "$script_path" "wrapper should avoid Bash-4-only associative arrays"
}

case_no_gnu_only_double_dash_for_path_utils() {
  assert_no_match '\\b(chmod|mkdir|mv|rmdir|dirname|basename|stat)\\b[^[:cntrl:]]* -- ' \
    "$script_path" \
    "wrapper should avoid GNU-only double-dash usage in path utilities"
}

case_missing_profile_value() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --profile >"$out" 2>"$err"
  rc=$?
  assert_equals "2" "$rc" "missing profile should exit 2"
  assert_contains "--profile requires a value" "$err" "missing profile should report usage error"
}

case_missing_config_value() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --config >"$out" 2>"$err"
  rc=$?
  assert_equals "2" "$rc" "missing config value should exit 2"
  assert_contains "--config requires a path" "$err" "missing config value should report usage error"
}

case_config_equals() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --config="$repo_root/sss-ssh-keygen.conf" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "config= should succeed"
  assert_contains "profile: ed25519" "$out" "config= should still load defaults"
}

case_missing_config() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --config "$tmp/missing.conf" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "missing config should exit 1"
  assert_contains "Config file not found" "$err" "missing config should fail loudly"
}

case_missing_implicit_default_config_warns() {
  local tmp script_copy out err rc

  tmp="$(new_tempdir)"
  script_copy="$tmp/sss-ssh-keygen.sh"
  out="$tmp/out"
  err="$tmp/err"

  cp "$script_path" "$script_copy"
  chmod +x "$script_copy"

  HOME="$tmp/home" USER="alice" HOSTNAME="host" run_script "$script_copy" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "missing implicit default config should fall back to built-in defaults"
  assert_contains "warning: Default config file not found: $tmp/sss-ssh-keygen.conf; continuing with built-in defaults" "$err" "missing implicit default config should warn"
  assert_contains "profile: ed25519" "$out" "missing implicit default config should still use built-in defaults"
  assert_contains "-a 100" "$out" "missing implicit default config should preserve built-in rounds"
}

case_config_not_executed() {
  local tmp cfg marker out err rc

  tmp="$(new_tempdir)"
  cfg="$tmp/custom.conf"
  marker="$tmp/marker"
  out="$tmp/out"
  err="$tmp/err"

  cat >"$cfg" <<EOF
SSH_KEYGEN_PROFILE=ed25519
SSH_KEYGEN_COMMENT="\$(touch \"$marker\")"
EOF

  run_wrapper --config "$cfg" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "literal config values should parse"
  assert_not_exists "$marker" "config parsing must not execute command substitutions"
  assert_contains "touch" "$out" "literal config text should flow through to dry-run output"
}

case_config_rejects_unknown_key() {
  local tmp cfg out err rc

  tmp="$(new_tempdir)"
  cfg="$tmp/custom.conf"
  out="$tmp/out"
  err="$tmp/err"

  cat >"$cfg" <<'EOF'
SSH_KEYGEN_PROFILE=ed25519
SSH_KEYGEN_UNKNOWN=1
EOF

  run_wrapper --config "$cfg" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "unknown config keys should fail"
  assert_contains "Unsupported config key" "$err" "unknown config key should be reported"
}

case_config_rejects_duplicates() {
  local tmp cfg out err rc

  tmp="$(new_tempdir)"
  cfg="$tmp/custom.conf"
  out="$tmp/out"
  err="$tmp/err"

  cat >"$cfg" <<'EOF'
SSH_KEYGEN_PROFILE=ed25519
SSH_KEYGEN_PROFILE=hardware
EOF

  run_wrapper --config "$cfg" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "duplicate config keys should fail"
  assert_contains "Duplicate config key" "$err" "duplicate config key should be reported"
}

case_fixed_profile_overrides_cli_rsa_bits() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --rsa-bits 4096 --profile rsa3072 --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "fixed-size rsa profile should override cli rsa bits"
  assert_contains "profile: rsa3072" "$out" "fixed-size rsa profile should remain selected"
  assert_contains "-b 3072" "$out" "fixed-size rsa profile should force 3072 bits"
}

case_env_fixed_profile_overrides_rsa_bits() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  SSH_KEYGEN_RSA_BITS=4096 run_wrapper --profile rsa3072 --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "fixed-size rsa profile should override env rsa bits"
  assert_contains "profile: rsa3072" "$out" "env rsa bits should not change the selected profile"
  assert_contains "-b 3072" "$out" "env rsa bits should be ignored for fixed-size profiles"
}

case_config_fixed_profile_overrides_rsa_bits() {
  local tmp cfg out err rc

  tmp="$(new_tempdir)"
  cfg="$tmp/custom.conf"
  out="$tmp/out"
  err="$tmp/err"

  cat >"$cfg" <<'EOF'
SSH_KEYGEN_PROFILE=rsa3072
SSH_KEYGEN_RSA_BITS=4096
EOF

  run_wrapper --config "$cfg" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "fixed-size rsa profile should override config rsa bits"
  assert_contains "profile: rsa3072" "$out" "config rsa bits should not change the selected profile"
  assert_contains "-b 3072" "$out" "config rsa bits should be ignored for fixed-size profiles"
}

case_default_config_allows_rsa4096() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --profile rsa4096 --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "default config should not block rsa4096"
  assert_contains "-b 4096" "$out" "rsa4096 should still force 4096 bits"
}

case_template_copy_allows_rsa4096() {
  local tmp cfg out err rc

  tmp="$(new_tempdir)"
  cfg="$tmp/sss-ssh-keygen.conf"
  out="$tmp/out"
  err="$tmp/err"

  sed 's/^SSH_KEYGEN_PROFILE=.*/SSH_KEYGEN_PROFILE=rsa4096/' "$repo_root/sss-ssh-keygen.conf" >"$cfg"

  run_wrapper --config "$cfg" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "template-derived config should allow rsa4096"
  assert_contains "profile: rsa4096" "$out" "template-derived config should select rsa4096"
  assert_contains "-b 4096" "$out" "template-derived config should still force 4096 bits"
}

case_fips_stays_configurable() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  run_wrapper --profile fips --rsa-bits 4096 --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "fips should remain configurable"
  assert_contains "-b 4096" "$out" "fips should honor explicit rsa bits"
}

case_env_profile_override() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  SSH_KEYGEN_PROFILE=rsa4096 run_wrapper --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "exported profile override should still work"
  assert_contains "profile: rsa4096" "$out" "exported profile override should change the selected profile"
}

case_env_output_override() {
  local tmp target out err rc

  tmp="$(new_tempdir)"
  target="$tmp/custom/id_ed25519"
  out="$tmp/out"
  err="$tmp/err"

  HOME="" SSH_KEYGEN_OUTPUT="$target" run_wrapper --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "exported output override should bypass HOME-based default resolution"
  assert_contains "output: $target" "$out" "exported output override should be reflected in dry-run output"
}

case_home_empty_fails() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  HOME="" run_wrapper --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "empty HOME should fail when using home defaults"
  assert_contains "HOME must be set" "$err" "empty HOME should produce a clear error"
}

case_xdg_toggle_uses_fallback() {
  local tmp home out err rc

  tmp="$(new_tempdir)"
  home="$tmp/home"
  mkdir -p "$home"
  out="$tmp/out"
  err="$tmp/err"

  HOME="$home" XDG_CONFIG_HOME="" run_wrapper --use-xdg-output --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "xdg toggle should succeed with HOME fallback"
  assert_contains "$home/.config/ssh/id_ed25519" "$out" "xdg toggle should fall back to HOME/.config"
}

case_output_override_beats_xdg_toggle() {
  local tmp home target out err rc

  tmp="$(new_tempdir)"
  home="$tmp/home"
  target="$tmp/custom/id_ed25519"
  mkdir -p "$home"
  out="$tmp/out"
  err="$tmp/err"

  HOME="$home" run_wrapper --use-xdg-output --output "$target" --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "explicit output should override xdg toggle"
  assert_contains "$target" "$out" "explicit output should be preserved"
}

case_comment_builder_supports_email() {
  local tmp out err rc

  tmp="$(new_tempdir)"
  out="$tmp/out"
  err="$tmp/err"

  USER="alice" HOSTNAME="builder" run_wrapper --comment-email alice@example.com --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "comment email should succeed"
  assert_contains "alice@builder\\ -\\ alice@example.com\\ -" "$out" "comment email should appear in the generated comment"
}

case_filesystem_utils_stay_portable_without_double_dash() {
  local tmp bin home target custom_target out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$home/.ssh/id_ed25519"
  custom_target="$tmp/custom/id_portable"
  mkdir -p "$bin" "$home/.ssh"
  write_stub_binaries "$bin"
  write_bsd_portability_shims "$bin"
  printf 'old-private\n' >"$target"
  printf 'old-public\n' >"${target}.pub"
  /bin/chmod 755 "$home/.ssh"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --force-overwrite >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "overwrite path should stay portable without GNU-only -- handling"
  assert_equals "stub-private" "$(tr -d '\n' <"$target")" "portable overwrite should still replace the private key"
  assert_equals "stub-public" "$(tr -d '\n' <"${target}.pub")" "portable overwrite should still replace the public key"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --output "$custom_target" >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "custom output path should stay portable without GNU-only -- handling"
  assert_equals "stub-private" "$(tr -d '\n' <"$custom_target")" "portable mkdir path should create the private key"
  assert_equals "stub-public" "$(tr -d '\n' <"${custom_target}.pub")" "portable mkdir path should create the public key"
}

case_fido_version_gates() {
  local tmp bin out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  write_stub_binaries "$bin"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" SSS_TEST_SSH_VERSION="OpenSSH_8.1p1, OpenSSL test" \
    run_wrapper --profile hardware --no-fido-verify-required --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "OpenSSH 8.1 should fail for FIDO keys"
  assert_contains "OpenSSH 8.2 or newer is required" "$err" "FIDO floor should be enforced"

  PATH="$bin:$PATH" SSS_TEST_SSH_VERSION="OpenSSH_8.3p1, OpenSSL test" \
    run_wrapper --profile hardware --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "verify-required should fail on OpenSSH 8.3"
  assert_contains "OpenSSH 8.4 or newer is required" "$err" "verify-required floor should be enforced"

  PATH="$bin:$PATH" SSS_TEST_SSH_VERSION="OpenSSH_8.3p1, OpenSSL test" \
    run_wrapper --profile hardware --no-fido-verify-required --dry-run >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "FIDO without verify-required should work on OpenSSH 8.3"

  PATH="$bin:$PATH" SSS_TEST_SSH_VERSION="OpenSSH_8.1p1, OpenSSL test" \
    run_wrapper --profile hardware --dry-run -- -t ed25519 >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "non-FIDO passthrough override should skip the FIDO version gate"
}

case_force_overwrite_preserves_existing_keys() {
  local tmp bin home target out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$home/.ssh/id_ed25519"
  mkdir -p "$bin" "$home/.ssh"
  write_stub_binaries "$bin"
  printf 'old-private\n' >"$target"
  printf 'old-public\n' >"${target}.pub"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" SSS_TEST_SSH_KEYGEN_MODE="fail" \
    run_wrapper --force-overwrite >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "overwrite failures should bubble up"
  assert_equals "old-private" "$(tr -d '\n' <"$target")" "existing private key should be preserved on failure"
  assert_equals "old-public" "$(tr -d '\n' <"${target}.pub")" "existing public key should be preserved on failure"
}

case_force_overwrite_replaces_after_success() {
  local tmp bin home target out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$home/.ssh/id_ed25519"
  mkdir -p "$bin" "$home/.ssh"
  write_stub_binaries "$bin"
  printf 'old-private\n' >"$target"
  printf 'old-public\n' >"${target}.pub"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --force-overwrite >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "overwrite success should exit 0"
  assert_equals "stub-private" "$(tr -d '\n' <"$target")" "private key should be replaced after success"
  assert_equals "stub-public" "$(tr -d '\n' <"${target}.pub")" "public key should be replaced after success"
}

case_force_overwrite_honors_passthrough_output() {
  local tmp bin home target out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$tmp/custom/id_override"
  mkdir -p "$bin" "$home/.ssh" "$(dirname -- "$target")"
  write_stub_binaries "$bin"
  printf 'old-private\n' >"$target"
  printf 'old-public\n' >"${target}.pub"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --force-overwrite -- -f "$target" >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "passthrough -f should participate in overwrite handling"
  assert_equals "stub-private" "$(tr -d '\n' <"$target")" "passthrough -f target private key should be replaced"
  assert_equals "stub-public" "$(tr -d '\n' <"${target}.pub")" "passthrough -f target public key should be replaced"
  assert_not_exists "$home/.ssh/id_ed25519" "passthrough -f should bypass the default output path"
  assert_not_contains "cannot stat" "$err" "passthrough -f overwrite should not fail during the rename step"
}

case_force_overwrite_rejects_private_directory_target() {
  local tmp bin home target out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$tmp/id_ed25519"
  mkdir -p "$bin" "$home/.ssh" "$target"
  write_stub_binaries "$bin"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --force-overwrite --output "$target" >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "directory private targets should be rejected"
  assert_contains "Refusing to overwrite directory target: $target" "$err" "directory private targets should report a clear error"
  assert_not_exists "$target/id_ed25519" "directory private targets should not receive nested key files"
}

case_force_overwrite_rejects_public_directory_target() {
  local tmp bin home target out err rc

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$tmp/id_ed25519"
  mkdir -p "$bin" "$home/.ssh" "${target}.pub"
  write_stub_binaries "$bin"
  printf 'old-private\n' >"$target"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --force-overwrite --output "$target" >"$out" 2>"$err"
  rc=$?
  assert_equals "1" "$rc" "directory public targets should be rejected"
  assert_contains "Refusing to overwrite directory target: ${target}.pub" "$err" "directory public targets should report a clear error"
  assert_equals "old-private" "$(tr -d '\n' <"$target")" "directory public target failures should preserve the private key"
  assert_not_exists "${target}.pub/id_ed25519.pub" "directory public targets should not receive nested public key files"
}

case_managed_dir_permissions_warn_and_fix() {
  local tmp bin home out err rc mode

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  mkdir -p "$bin" "$home/.ssh"
  write_stub_binaries "$bin"
  chmod 755 "$home/.ssh"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "managed dir repair should still succeed"
  assert_contains "Correcting permissions on $home/.ssh to 700" "$err" "managed dir repair should warn"
  mode="$(stat -c '%a' "$home/.ssh" 2>/dev/null || stat -f '%Lp' "$home/.ssh")"
  assert_equals "700" "$mode" "managed dir should be repaired to 700"
}

case_explicit_managed_output_repairs_parent_dir() {
  local tmp bin home target out err rc mode

  tmp="$(new_tempdir)"
  bin="$tmp/bin"
  home="$tmp/home"
  target="$home/.ssh/work_key"
  mkdir -p "$bin" "$home/.ssh"
  write_stub_binaries "$bin"
  chmod 755 "$home/.ssh"
  out="$tmp/out"
  err="$tmp/err"

  PATH="$bin:$PATH" HOME="$home" USER="alice" HOSTNAME="host" \
    run_wrapper --output "$target" >"$out" 2>"$err"
  rc=$?
  assert_equals "0" "$rc" "explicit outputs under ~/.ssh should still succeed"
  assert_contains "Correcting permissions on $home/.ssh to 700" "$err" "explicit managed outputs should still repair ~/.ssh"
  mode="$(stat -c '%a' "$home/.ssh" 2>/dev/null || stat -f '%Lp' "$home/.ssh")"
  assert_equals "700" "$mode" "explicit managed outputs should still repair ~/.ssh to 700"
}

run_case "no bash4 associative arrays" case_no_bash4_assoc_arrays
run_case "no GNU-only double dash for path utils" case_no_gnu_only_double_dash_for_path_utils
run_case "missing profile value" case_missing_profile_value
run_case "missing config value" case_missing_config_value
run_case "config equals syntax" case_config_equals
run_case "missing config" case_missing_config
run_case "missing implicit default config warns" case_missing_implicit_default_config_warns
run_case "config parsing is non-executable" case_config_not_executed
run_case "config rejects unknown keys" case_config_rejects_unknown_key
run_case "config rejects duplicates" case_config_rejects_duplicates
run_case "fixed rsa profile overrides cli bits" case_fixed_profile_overrides_cli_rsa_bits
run_case "env fixed rsa profile overrides bits" case_env_fixed_profile_overrides_rsa_bits
run_case "config fixed rsa profile overrides bits" case_config_fixed_profile_overrides_rsa_bits
run_case "default config allows rsa4096" case_default_config_allows_rsa4096
run_case "template copy allows rsa4096" case_template_copy_allows_rsa4096
run_case "fips remains configurable" case_fips_stays_configurable
run_case "env profile override" case_env_profile_override
run_case "env output override" case_env_output_override
run_case "empty HOME fails" case_home_empty_fails
run_case "xdg toggle fallback" case_xdg_toggle_uses_fallback
run_case "output override beats xdg toggle" case_output_override_beats_xdg_toggle
run_case "comment builder supports email" case_comment_builder_supports_email
run_case "filesystem utils stay portable without double dash" case_filesystem_utils_stay_portable_without_double_dash
run_case "fido version gates" case_fido_version_gates
run_case "overwrite preserves existing keys" case_force_overwrite_preserves_existing_keys
run_case "overwrite replaces after success" case_force_overwrite_replaces_after_success
run_case "overwrite honors passthrough output" case_force_overwrite_honors_passthrough_output
run_case "overwrite rejects private directory targets" case_force_overwrite_rejects_private_directory_target
run_case "overwrite rejects public directory targets" case_force_overwrite_rejects_public_directory_target
run_case "managed dir warning and repair" case_managed_dir_permissions_warn_and_fix
run_case "explicit managed output repairs parent dir" case_explicit_managed_output_repairs_parent_dir

if [[ "$failures" -gt 0 ]]; then
  printf 'FAILED %s/%s tests\n' "$failures" "$test_count" >&2
  exit 1
fi

printf 'PASS %s tests\n' "$test_count"
