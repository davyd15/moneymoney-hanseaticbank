# Security Policy

## Credential Model

This extension uses three static values to identify itself as an API client to
Hanseatic Bank's authorization server:

| Constant | Role |
|----------|------|
| `BASIC_AUTH` | Base64-encoded `client_id:client_secret` sent in the `Authorization` header of OAuth2 token requests |
| `CL_ID` | OAuth2 `client_id` (plain form, used in certain token request bodies) |
| `CL_SC` | OAuth2 `client_secret` (plain form) |

These values are **not user credentials**. They are the functional equivalent of a
registered OAuth2 client and are embedded in Hanseatic Bank's own web portal. They
are intentionally included in this repository because the extension cannot communicate
with the bank's API without them, and because every user who installs the extension
receives them in plain text on their local machine.

Possession of these values alone grants no access to any account. A valid end-user
login ID and password — stored exclusively in MoneyMoney's built-in secure
keychain — are required for every authenticated request.

## User Credential Handling

- **Login ID and password** are entered by the user directly into MoneyMoney's
  credential dialog and stored in MoneyMoney's encrypted local keychain. They are
  never written to disk by this extension.
- During the authentication flow the password is held in `LocalStorage` only for
  the duration of the token request and is cleared immediately afterwards.
- No user data is transmitted to any server other than `connecthb.hanseaticbank.de`
  (Hanseatic Bank's own API) and `meine.hanseaticbank.de`.

## Reporting a Vulnerability

If you discover a security issue in this extension, please **do not open a public
GitHub issue**. Instead, report it via
[GitHub's private vulnerability reporting](https://github.com/davyd15/moneymoney-hanseaticbank/security/advisories/new).

Please include:

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- The version of the extension you are using

You can expect an acknowledgement within 72 hours.

## Automated Scanning

Static secret scanners (e.g. GitGuardian, TruffleHog) may flag `BASIC_AUTH` as an
exposed credential. This is a **false positive**: the value is a public OAuth2 client
identifier, not a personal secret. See `.gitguardian.yaml` for the suppression rule
and rationale.
