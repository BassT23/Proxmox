# Trusted reverse-proxy authentication

## Feature

Set `UU_AUTH_BACKEND=trusted_proxy` only when the browser UI is behind a
trusted authentication gateway (for example an OIDC-enabled forward-auth proxy).
This is not an OIDC implementation inside Ultimate Updater; the gateway owns
OIDC redirects, tokens, session lifetime and MFA.

Required environment settings:

- `UU_TRUSTED_PROXY_CIDRS`: comma-separated source CIDRs of the *actual*
  reverse proxy peers, not the public clients or untrusted forwarded IPs.
- `UU_TRUSTED_PROXY_ALLOWED_USERS`: comma-separated exact case-sensitive
  identities permitted to operate Ultimate Updater. All accepted identities
  have existing administrator-level Web UI access; restrict to administrators.
- `UU_TRUSTED_PROXY_USER_HEADER`: optional identity header name; default
  `Remote-User`. The gateway must strip all client-supplied instances and
  replace them with exactly one verified identity header.

Additional mandatory gateway credential: `UU_TRUSTED_PROXY_ASSERTION_FILE`
must reference a regular private file owned by the Web UI service UID and
mode 0600. Its contents MUST be a high-entropy, URL-safe 43 to 128 character
value. Caddy MUST replace (never forward) any client-supplied
`X-UU-Gateway-Assertion` with exactly one value from a protected credential
mount. Never put that credential in Git, logs or unrelated containers.

Requests outside the configured source CIDRs, without an identity header,
with duplicate/malformed identity headers or a non-allowlisted identity
are denied. `X-Forwarded-For` never grants trust. The UI issues its existing
short-lived local session cookie and CSRF token only after verifying the
gateway source and mapped identity; every subsequent session request rechecks
the same identity. State-changing routes keep the existing origin/CSRF gates.

The mode is opt-in and isolated: `proxmox`, `pam` and `internal` backends
remain the default/supported recovery modes. Native credential login is
disabled when trusted proxy SSO is selected. Local logout invalidates only
the Ultimate Updater session; actual OIDC logout is owned by the gateway.

**Critical deployment prerequisite:** the gateway assertion is mandatory
because Docker shared NAT makes a source-CIDR allowlist insufficient.
It is a confidential bearer capability, not a signed timestamped claim.
Protect the gateway-to-backend transport, restrict backend exposure where
possible, and prove that an unrelated container cannot authenticate with
forged identity or assertion headers. Do not activate before live negative-path acceptance.
Test a denied direct backend request and both a privileged authorized UI action and rejected
unauthorized/CSRF request before retiring any existing recovery path.

Automated acceptance: `python3 tests/test-trusted-proxy-auth.py`.
