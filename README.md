# MoneyMoney Extension – Hanseatic Bank

A [MoneyMoney](https://moneymoney-app.com) extension for **Hanseatic Bank (HB) Germany** that connects to the [Meine Hanseatic Bank](https://meine.hanseaticbank.de) portal to import account balances and transactions.

---

## Features

- Supports **credit card, overnight money, and loan** accounts in EUR
- Fetches paginated transaction history including reservations and enriched merchant data
- Appends city and foreign currency amount to transaction details
- Confirmation dialog before OTP request — prevents simultaneous pushes when refreshing all accounts at once
- Full transaction history (beyond the standard page limit) via optional session SCA — only required on the first sync

## How It Works

The extension communicates with Hanseatic Bank's private JSON REST API at `connecthb.hanseaticbank.de` using OAuth2-style token flows.

### Authentication

| Step | Action |
|------|--------|
| 1 | Confirmation dialog shown — no request sent yet (prevents simultaneous OTP triggers on bulk refresh) |
| 2 | `POST /token` with `grant_type=hbSCACustomPassword`, credentials, and Basic Auth → triggers app push or SMS OTP; response contains a signed JWT with `sca_id` and `sca_type` |
| 3 | **SMS:** `POST /token` with `otp` and `scaId` → access token. **APP:** `GET /openScaBroker/1.0/customer/{loginId}/status/{scaId}` via client-credentials token to poll confirmation status, then `POST /token` with `devicetoken` from result → access token |
| 4 | *(First sync only)* `POST /scaBroker/1.0/session` → session SCA for full history; confirmed via app push or SMS OTP |

The access token is stored in `LocalStorage` and reused across `ListAccounts` and `RefreshAccount` within the same session. The password is held in `LocalStorage` only for the duration of the login flow and cleared immediately after the token is obtained.

`historyLoaded` is persisted in `LocalStorage` after the first full history sync — subsequent syncs skip the session SCA step entirely and require only a single confirmation.

### Data Retrieval

- **Accounts:** `POST /customerinfo/1.0/initCustomer` — returns credit, overnight, and loan accounts
- **Transactions:** `GET /transaction/1.0/transactionsEnriched/{accountNumber}?page=N&withReservations=true&withEnrichments=true`, paginated (up to 50 pages as a safety limit)

The `moreWithSCA` flag in the transaction response signals that older transactions exist behind an SCA gate. The extension records this and requests a session SCA on the next login — but only once.

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS (any recent version)
- A **Meine Hanseatic Bank** account
- Your **10-digit Login ID** and **password**

> **Note:** This extension uses the same API as the Hanseatic Bank web portal. Hanseatic Bank App users with app-based SCA enabled will receive a push notification instead of an SMS.

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
5. Click **Done** — a confirmation request will be sent to your app or via SMS
6. Confirm in the Hanseatic Bank app (or enter the SMS OTP) and click **Done** again

## Supported Account Types

| Type | Description |
|------|-------------|
| Credit Card | Hanseatic Bank Visa/Mastercard (GenialCard, CreditCard) |
| Overnight Account | Hanseatic Bank overnight money (Tagesgeld) |
| Loan | Hanseatic Bank installment loan |

## Limitations

- **EUR only** — foreign currency amounts are appended to the transaction note but not mapped as separate currency fields
- Transaction history beyond the standard page limit requires a one-time session SCA confirmation (first sync only)
- The tokenised PAN (`tpan`) returned by the API has non-digit characters replaced with `X` — the real card number is not available via the API

## Troubleshooting

**"Login failed" / credentials rejected**
- Make sure you are using your **Meine Hanseatic Bank Login ID** (10-digit number) and password
- Try logging in at [meine.hanseaticbank.de](https://meine.hanseaticbank.de) in your browser to verify

**Extension not appearing in MoneyMoney**
- Confirm the `.lua` file is in the correct Extensions folder (see Installation above)
- Reload extensions or restart MoneyMoney

**App push not received**
- Open the Hanseatic Bank app once to ensure push notifications are enabled
- If no push arrives, the bank may fall back to SMS

## Changelog

| Version | Changes |
|---------|---------|
| 3.71 | Added confirmation dialog before OTP request to prevent simultaneous triggers on bulk refresh |
| 3.70 | Initial public release |

## Contributing

Bug reports and pull requests are welcome. If the bank changes its login flow or API, please open an issue with the MoneyMoney log output — that makes it much easier to diagnose.

To test changes locally, copy the `.lua` file into the Extensions folder and reload extensions in MoneyMoney.

## Disclaimer

This extension is an independent community project and is **not affiliated with, endorsed by, or supported by Hanseatic Bank** or the MoneyMoney developers. Use at your own risk. Credentials are handled solely by MoneyMoney's built-in secure storage and are never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
