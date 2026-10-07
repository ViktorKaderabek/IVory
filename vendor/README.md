# Vendored code

## altsign-cli

[altsign-cli](https://github.com/xhzq233/altsign-cli) signs WebDriverAgent with the user's own Apple ID.
`altsign-cli/` is its source **unchanged** at upstream commit
`476eaddd84cf3a833550e074fd2b1d12aec3b0a1` (AGPL-3.0, see `altsign-cli/LICENSE`). Keeping it here means a
build never depends on someone else's repository, and anyone can check the exact code IVory ships.

IVory's changes are all in [`altsign-cli.patch`](altsign-cli.patch), applied by `scripts/build_wda_runtime.sh`:

- never revokes a development certificate another program made (only its own: *IVory*, or *AltSign Device* from IVory 1.4.0), and
  picks the certificate it just created by its serial number;
- puts the user's keychain search list back after signing instead of replacing it; random passwords for
  the throwaway signing keychain and `.p12`;
- logs to stderr only, never to the macOS unified log, and without the Apple ID, DSID, device UDID,
  Apple's 2FA responses or the private key;
- wipes the password-derived key material and the SRP context from memory, and checks the size of what
  Apple's server sends before using it;
- the session file keeps no machine identifiers and is excluded from Time Machine backups.

The source was reviewed line by line on 2026-10-07: it talks only to `gsa.apple.com` and
`developerservices2.apple.com`, sends the password only as an SRP proof, and stores it nowhere.

To move to a newer upstream version: replace `altsign-cli/` with that commit, re-review the diff, update
the commit above and make `altsign-cli.patch` apply again.
