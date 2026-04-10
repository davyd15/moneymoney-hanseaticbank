# MoneyMoney Extension – Hanseatic Bank

A [MoneyMoney](https://moneymoney-app.com) extension for **Hanseatic Bank (HB) Germany** that connects to the [Meine Hanseatic Bank](https://meine.hanseaticbank.de) portal to import account balances and transactions.

---

## Features

- Supports **credit card, overnight money, and loan** accounts in EUR
- Fetches paginated transaction history including reservations and enriched merchant data
- Appends city and foreign currency amount to transaction details
- **Device token fast path** — re-authenticates with stored credentials and device token; SCA push skipped on every subsequent sync
- Non-interactive guard — never triggers an unexpected push notification during background/scheduled syncs
- Full transaction history (beyond the standard page limit) via optional session SCA — only required on the first sync

## How It Works

The extension communicates with Hanseatic Bank's private JSON REST API at `connecthb.hanseaticbank.de` using OAuth2-style token flows.

### Authentication

On every sync the extension tries the device token fast path before falling back to a full SCA:

| Condition | Action |
|-----------|--------|
| Device token stored | `POST /token` with `grant_type=hbSCACustomPassword`, credentials, and `devicetoken` header → access token, no SCA push |
| No device token (first sync, or token invalidated) | Full SCA login (see below) |

Credentials are re-submitted on every sync; only the SCA push is skipped.

If the device token fast path is unavailable or fails, a full SCA login is performed:

| Step | Action |
|------|--------|
| 1 | `POST /token` with `grant_type=hbSCACustomPassword`, credentials, and Basic Auth → triggers app push or SMS OTP; response contains a signed JWT with `sca_id` and `sca_type` |
| 2a | **SMS:** `POST /token` with `otp` and `scaId` → access token |
| 2b | **APP:** `GET /openScaBroker/1.0/customer/{loginId}/status/{scaId}` (polled with a client-credentials token, up to 15 attempts) until status is `complete`, then `POST /token` with `devicetoken` from result → access token |
| 3 | *(First sync only)* `POST /scaBroker/1.0/session` → session SCA for full transaction history; confirmed via app push or SMS OTP |

The device token is stored in `LocalStorage` and reused across syncs. The access token and refresh token are not persisted — a fresh token is obtained on every sync using the device token. The password is held in `LocalStorage` only for the duration of the login flow and cleared immediately after the token is obtained.

### Device Token

After the first successful app SCA the device token returned by the bank is stored in `LocalStorage`. On subsequent syncs the extension re-authenticates with your credentials and this token — the bank recognises the device and skips the SCA push.

If the bank invalidates the device token (e.g. after a password change or security reset), the extension automatically falls back to a full SCA and stores a new device token after confirmation.

### Session SCA for Full History

`historyLoaded` is persisted in `LocalStorage` after the first full history sync — subsequent syncs skip the session SCA step entirely and require only a single confirmation.

The `moreWithSCA` flag in the transaction response signals that older transactions exist behind an SCA gate. The extension records this in `LocalStorage` and requests a session SCA on the next login. This repeats until the session SCA is successfully completed, after which `historyLoaded` is set permanently.

### Data Retrieval

- **Accounts:** `POST /customerinfo/1.0/initCustomer` — returns credit, overnight, and loan accounts
- **Transactions:** `GET /transaction/1.0/transactionsEnriched/{accountNumber}?page=N&withReservations=true&withEnrichments=true`, paginated (up to 50 pages as a safety limit)

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS (any recent version)
- A **Meine Hanseatic Bank** account
- Your **10-digit Login ID** and **password**

> **Note:** This extension uses the same API as the Hanseatic Bank web portal. If you have the Hanseatic Bank app installed with push notifications enabled, you will receive an in-app confirmation request. Otherwise, the bank sends an SMS OTP.

## Installation

### Option A — Direct download

1. Download [`HanseaticGenialcard.lua`](HanseaticGenialcard.lua)
2. Move it into MoneyMoney's Extensions folder:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```
3. Reload extensions: right-click any account in MoneyMoney → **Reload Extensions** (or restart the app)

### Option B — Clone the repository

```bash
git clone https://github.com/davyd15/moneymoney-hanseaticbank.git
cp moneymoney-hanseaticbank/HanseaticGenialcard.lua \
  ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/
```

## Setup in MoneyMoney

1. Open MoneyMoney → **File → Add Account…**
2. Search for **"Hanseatic Bank"**
3. Select **Hanseatic Bank**
4. Enter your **10-digit Login ID** and **password**
5. Click **Done** — the extension will trigger a confirmation request (app push or SMS, depending on your Hanseatic Bank setup)
6. Confirm in the Hanseatic Bank app, or enter the SMS OTP, then click **Done** again

## Supported Account Types

| Type | Description |
|------|-------------|
| Credit Card | Hanseatic Bank Visa/Mastercard (GenialCard, CreditCard) |
| Overnight Account | Hanseatic Bank overnight money (Tagesgeld) |
| Loan | Hanseatic Bank installment loan |

## Limitations

- **EUR only** — foreign currency amounts are appended to the transaction note but not mapped as separate currency fields
- Full transaction history (beyond the first few pages) requires a session SCA confirmation — this happens automatically on the first sync and is not repeated once completed
- The API returns a tokenised card number (`tpan`) with the middle digits already masked; non-digit placeholder characters are normalised to `X` (e.g. `415299XXXXXX9866`). The real card number is not accessible via the API
- The device token setting can only be changed by removing and re-adding the account in MoneyMoney

## Troubleshooting

**"Login failed" / credentials rejected**
- Make sure you are using your **Meine Hanseatic Bank Login ID** (10-digit number) and password
- Try logging in at [meine.hanseaticbank.de](https://meine.hanseaticbank.de) in your browser to verify

**Extension not appearing in MoneyMoney**
- Confirm the `.lua` file is in the correct Extensions folder (see Installation above)
- Reload extensions or restart MoneyMoney

**App push not received**
- Open the Hanseatic Bank app once to ensure push notifications are enabled
- If no push arrives within a few seconds, the bank falls back to SMS automatically

**2FA switched from app to SMS**
- This can happen when the bank's backend detects repeated SCA requests from an unrecognised device (e.g. after using the extension without a persistent device token). To restore app-based 2FA, log into the Hanseatic Bank web portal, navigate to security settings, and re-register the Hanseatic Secure App as the preferred SCA device
- Enabling the device token (see above) prevents this from recurring

**SCA required on every sync**
- The device token may have been invalidated by the bank (e.g. after a password change or security reset). The extension will automatically fall back to a full SCA and store a new device token after the next successful confirmation

**Full transaction history not loading**
- On the first sync, the extension requests a session SCA after the regular login — confirm it in the app or via SMS when prompted
- If you cancel the session SCA, it will be requested again on the next sync until completed successfully

## Changelog

| Version | Changes |
|---------|---------|
| 3.79 | Device token fast path — re-authenticates with stored credentials and device token, skipping SCA push on every subsequent sync; non-interactive guard against background SCA pushes |
| 3.78 | State-based SCA with German UI |
| 3.73 | State-based dispatch replaces step-number-based polling — fixes APP polling when pending dialog caused step increment before login completed |
| 3.72 | HTTP login sent in step 1 to keep dialog open and prevent extension interleaving during bulk refresh |
| 3.71 | Added confirmation dialog before OTP request to prevent simultaneous triggers on bulk refresh |
| 3.70 | Initial public release |

## Contributing

Bug reports and pull requests are welcome. If the bank changes its login flow or API, please open an issue with the MoneyMoney log output — that makes it much easier to diagnose.

To test changes locally, copy the `.lua` file into the Extensions folder and reload extensions in MoneyMoney.

## Security

The extension contains three static OAuth2 client values (`BASIC_AUTH`, `CL_ID`, `CL_SC`) that identify the Hanseatic Bank web portal as an API client. These are **not user credentials** — they are embedded in the bank's own web application and confer no account access without a valid end-user login. User credentials are stored exclusively in MoneyMoney's encrypted keychain and are never written to disk or transmitted to any third party.

For full details on the credential model, user data handling, and how to report a vulnerability, see [SECURITY.md](SECURITY.md).

## Disclaimer

This extension is an independent community project and is **not affiliated with, endorsed by, or supported by Hanseatic Bank** or the MoneyMoney developers. Use at your own risk. Credentials are handled solely by MoneyMoney's built-in secure storage and are never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
