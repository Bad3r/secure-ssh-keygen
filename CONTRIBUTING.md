# Contributing

## Scope

This project aims to keep SSH key generation predictable, reviewable, and
boring. Contributions should favor small, explicit changes over broad behavior
shifts.

## Before opening a pull request

Run the relevant checks from the repository root:

```sh
bash -n sss-ssh-keygen.sh
./sss-ssh-keygen.sh --dry-run
./sss-ssh-keygen.sh --profile hardware --dry-run
./sss-ssh-keygen.sh --profile fips --dry-run
```

If you change validation or profile logic, test both success and refusal paths.

## Pull request expectations

- keep changes focused on one logical concern
- document user-visible behavior changes in `README.md`
- preserve explicit, fail-closed behavior
- avoid committing generated keys, passphrases, PINs, or host-specific configs

## Security-sensitive changes

Changes to default algorithms, FIDO behavior, passphrase handling, overwrite
rules, or output paths should include a short rationale and an authoritative
source when possible.
