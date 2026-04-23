-- ============================================================
-- MoneyMoney Web Banking Extension
-- Hanseatic Bank (HB) Germany – Meine Hanseatic Bank
-- Version: 3.82
--
-- Credentials:
--   Username: Login ID (10-digit number, e.g. 5101821536)
--   Password: Your Hanseatic Bank password
--
-- Changes in 3.82:
--   - Non-interactive guard moved before fast path: prevents spurious SCA
--     push during background syncs (fast path POST always triggers a push).
--   - Fast path now handles id_token response: bank requires SCA even with
--     deviceToken. Reuse the SCA from the fast path POST instead of sending
--     a second login POST (was causing two pushes per sync).
--   - deviceToken no longer cleared when bank returns id_token (it is valid;
--     was being deleted on every sync, so it never persisted).
--
-- Changes in 3.81:
--   - needSessionSCA no longer cleared in EndSession — persists until
--     the next interactive sync picks it up (was lost between sessions).
--   - Session SCA in fast path only triggers when interactive=true.
--
-- Changes in 3.80:
--   - Fast path now also triggers session SCA when needed (full history).
--     Phase B handles subsequent steps as before.
--
-- Changes in 3.79:
--   - Device token fast path: store DEVICETOKEN after SCA and reuse
--     it on subsequent syncs to skip the SCA push entirely.
--     Fallback to full SCA if the token is invalidated by the bank.
--   - Non-interactive guard: no SCA push during background/auto syncs.
--   - Removed unused refresh token handling.
--
-- Changes in 3.73:
--   - Steps 2+ now use LocalStorage state instead of step numbers.
--     MoneyMoney always increments the step on each dialog, so
--     the previous step-number-based APP polling broke when the
--     pending dialog caused a step increment before login was done.
--     State-based dispatch fixes APP polling for both login SCA
--     and session SCA regardless of how many steps are needed.
--
-- Changes in 3.72:
--   - Step 1 now triggers login and SCA immediately, returning
--     the OTP input or app confirmation dialog directly.
--     This keeps the dialog window open for user interaction
--     and prevents other extensions from interleaving during
--     bulk refresh (Rundruf).
-- ============================================================

WebBanking{
  version     = 3.82,
  url         = "https://meine.hanseaticbank.de",
  services    = {"Hanseatic Bank"},
  description = "Hanseatic Bank credit card (App SCA or SMS OTP)"
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local API        = "https://connecthb.hanseaticbank.de"
-- BASIC_AUTH, CL_ID, and CL_SC are the OAuth2 client credentials of the Hanseatic Bank
-- web portal. They identify the API client to the bank's authorization server and are
-- embedded in the bank's own web application — they are not user credentials and confer
-- no account access on their own. User credentials (loginId, password) are passed through
-- MoneyMoney's secure keychain, held in LocalStorage only for the duration of the token
-- request, and cleared immediately afterwards. See SECURITY.md for the full credential model.
local BASIC_AUTH = "Basic bTZLVnV4ZVhoY1FYV0RHNWM5VWNDYVo1QnA0YTo0alhIUWRxMGhqdG9ibUNWZW11NlFWcGliX3dh"
local CL_ID      = "5bnQTsZSz_IixlE0YqX4CrVCjPca"
local CL_SC      = "cNLo9jjW9kpDkcf3VRnfmRXmXFoa"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local connection    = nil
local accessToken   = nil
local customerCache = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tryJSON(s)
  if not s or s == "" then return nil end
  local ok, j = pcall(JSON, s)
  if not ok then return nil end
  local ok2, d = pcall(function() return j:dictionary() end)
  return ok2 and d or nil
end

local function b64urlDecode(s)
  if not s then return nil end
  s = s:gsub("%-", "+"):gsub("_", "/")
  local pad = (4 - #s % 4) % 4
  s = s .. ("="):rep(pad)
  local ok, result = pcall(MM.base64decode, s)
  if ok and result then return result end
  return nil
end

local function extractJWTPayload(token)
  if not token then return nil end
  local parts = {}
  for p in token:gmatch("[^.]+") do parts[#parts+1] = p end
  if #parts < 2 then return nil end
  local decoded = b64urlDecode(parts[2])
  if not decoded then return nil end
  return tryJSON(decoded)
end

local function ue(s)
  return MM.urlencode(tostring(s or ""))
end

local function parseDate(s)
  if not s then return nil end
  local d, m, y = s:match("^(%d+)%.(%d+)%.(%d%d%d%d)")
  if d then
    return os.time{year=tonumber(y), month=tonumber(m),
                   day=tonumber(d), hour=0, min=0, sec=0}
  end
  local y2, m2, d2 = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if y2 then
    return os.time{year=tonumber(y2), month=tonumber(m2),
                   day=tonumber(d2), hour=0, min=0, sec=0}
  end
  return nil
end

local function isError(resp)
  if not resp then return true end
  local data = tryJSON(resp)
  if data and (data["error_code"] or data["error"]) then return true end
  return false
end

-- Make tokenised PAN human-readable: replace non-digit chars with X
-- e.g. "415299MTPQBJ9866" -> "415299XXXXXX9866"
local function formatTpan(tpan)
  if not tpan or tpan == "" then return "" end
  return tpan:gsub("[^%d]", "X")
end

-- Normalise BIC: strip trailing X
-- e.g. "HSTBDEHHXXX" -> "HSTBDEHH"
local function normalizeBic(bic)
  if not bic or bic == "" then return "" end
  return bic:gsub("X+$", "")
end

local function ensureConnection()
  if not connection then
    connection = Connection()
    -- Bank API requires German locale to return correct response structure
    connection.language  = "de-DE,de;q=0.9"
    connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         .. "AppleWebKit/537.36 (KHTML, like Gecko) "
                         .. "Chrome/146.0.0.0 Safari/537.36"
  end
end

--------------------------------------------------------------------------------
-- HTTP headers
--------------------------------------------------------------------------------

local function hdrBasic(extra)
  local h = {
    ["Accept"]        = "application/json",
    ["Content-Type"]  = "application/x-www-form-urlencoded; charset=UTF-8",
    ["Authorization"] = BASIC_AUTH,
    ["Origin"]        = "https://meine.hanseaticbank.de",
    ["Referer"]       = "https://meine.hanseaticbank.de/",
    ["Cache-Control"] = "no-cache",
    ["Pragma"]        = "no-cache",
    ["User-Agent"]    = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      .. "AppleWebKit/537.36 (KHTML, like Gecko) "
                      .. "Chrome/146.0.0.0 Safari/537.36",
  }
  if extra then for k, v in pairs(extra) do h[k] = v end end
  return h
end

local function hdrNoAuth()
  return {
    ["Accept"]        = "application/json",
    ["Content-Type"]  = "application/x-www-form-urlencoded; charset=UTF-8",
    ["Origin"]        = "https://meine.hanseaticbank.de",
    ["Referer"]       = "https://meine.hanseaticbank.de/",
    ["Cache-Control"] = "no-cache",
    ["Pragma"]        = "no-cache",
    ["User-Agent"]    = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      .. "AppleWebKit/537.36 (KHTML, like Gecko) "
                      .. "Chrome/146.0.0.0 Safari/537.36",
  }
end

local function hdrBearer(token)
  return {
    ["Accept"]        = "application/json",
    ["Content-Type"]  = "application/json",
    ["Authorization"] = "Bearer " .. (token or ""),
    ["Origin"]        = "https://meine.hanseaticbank.de",
    ["Referer"]       = "https://meine.hanseaticbank.de/",
    ["Cache-Control"] = "no-cache",
    ["Pragma"]        = "no-cache",
    ["User-Agent"]    = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      .. "AppleWebKit/537.36 (KHTML, like Gecko) "
                      .. "Chrome/146.0.0.0 Safari/537.36",
  }
end

--------------------------------------------------------------------------------
-- API helpers
--------------------------------------------------------------------------------

local function getClientToken()
  local resp = connection:request(
    "POST", API .. "/token",
    "grant_type=client_credentials"
    .. "&client_id="     .. ue(CL_ID)
    .. "&client_secret=" .. ue(CL_SC),
    "application/x-www-form-urlencoded; charset=UTF-8",
    hdrNoAuth()
  )
  local data = tryJSON(resp)
  return data and data["access_token"]
end

-- Load customer data with session cache.
-- Preloaded on login, reused in ListAccounts and RefreshAccount.
local function getCustomerData(token)
  if customerCache then return customerCache end
  local resp = connection:request(
    "POST", API .. "/customerinfo/1.0/initCustomer",
    -- "language":"de" is required by the bank API — does not affect returned data structure
    '{"initiator":"MHB","language":"de"}',
    "application/json",
    hdrBearer(token)
  )
  customerCache = tryJSON(resp)
  return customerCache
end

local function findBalance(cd, accountNumber)
  if not cd then return 0 end
  local accs = cd["accounts"] or {}
  local function searchIn(list)
    for _, a in ipairs(list or {}) do
      if a["accountNumber"] == accountNumber then
        return tonumber(a["saldo"]) or 0
      end
    end
    return nil
  end
  return searchIn(accs["creditAccounts"])
      or searchIn(accs["overnightAccounts"])
      or searchIn(accs["loanAccounts"])
      or 0
end

-- Start session SCA for full transaction history.
-- POST /scaBroker/1.0/session with Bearer token in body.
local function startSessionSCA(token)
  -- "lang":"de" is a required API field; does not change response structure
  local body = '{"initiator":"ton-sca-fe","lang":"de","session":"Bearer ' .. token .. '"}'
  local resp = connection:request(
    "POST", API .. "/scaBroker/1.0/session",
    body, "application/json",
    hdrBearer(token)
  )
  local data = tryJSON(resp)
  if not data then return nil, nil end
  return data["scaUniqueId"], data["scaType"]
end

-- Check session SCA status.
-- GET /scaBroker/1.0/status/{scaId}
local function checkSessionSCA(scaId, token)
  local resp = connection:request(
    "GET", API .. "/scaBroker/1.0/status/" .. scaId,
    nil, nil,
    hdrBearer(token)
  )
  local data = tryJSON(resp)
  if not data then return "error" end
  return data["status"]
end

-- Confirm session SCA with SMS OTP.
-- PUT /scaBroker/1.0/status/{scaId} with {"otp":"OTP"}
local function confirmSessionSCAWithOTP(scaId, otp, token)
  local body = '{"otp":"' .. otp .. '"}'
  local resp = connection:request(
    "PUT", API .. "/scaBroker/1.0/status/" .. scaId,
    body, "application/json",
    hdrBearer(token)
  )
  local data = tryJSON(resp)
  if not data then return false end
  return data["status"] == "complete"
end

-- Load all transactions with pagination.
local function loadAllTransactions(token, accountNumber, since)
  local transactions = {}
  local page         = 1
  local stop         = false
  local moreWithSCA  = false

  while not stop do
    local url = API .. "/transaction/1.0/transactionsEnriched/"
              .. ue(accountNumber)
              .. "?page=" .. page
              .. "&withReservations=true&withEnrichments=true"

    local tResp = connection:request("GET", url, nil, nil, hdrBearer(token))
    local data  = tryJSON(tResp)
    if not data then break end

    for _, tx in ipairs(data["transactions"] or {}) do
      local dateStr = tx["transactionDate"]
                   or (tx["transactionDateTime"] or ""):sub(1, 10)
      local dt = parseDate(dateStr)

      -- Only include transactions from since onwards
      if not (since and dt and dt < since) then
        local name    = tx["merchantName"] or tx["recipientName"] or ""
        local purpose = tx["description"]  or ""
        local city    = tx["city"]         or ""
        local fx      = tostring(tx["foreignAmount"] or "")
        local md      = tx["merchantData"]

        -- Use merchantData as fallback for merchant name
        if name == "" and md and type(md) == "table" and md["name"] then
          name = md["name"]
        end

        -- Append city
        if city ~= "" then
          purpose = purpose .. (purpose ~= "" and " " or "") .. "[" .. city .. "]"
        end

        -- Append foreign currency amount
        if fx ~= "" and fx ~= "0" and fx ~= "0.0" then
          purpose = purpose .. (purpose ~= "" and " " or "") .. "(" .. fx .. ")"
        end

        -- Determine transaction type from bank API enum (values are in German)
        -- GUTSCHRIFT = credit/refund, LS_EINZUG = direct debit, UEBERWEISUNG = transfer
        local cdk    = tx["creditDebitKeyPhraseCompatible"] or ""
        local txType = TransactionTypeOther
        if cdk == "GUTSCHRIFT" or cdk == "LS_EINZUG" then
          txType = TransactionTypeCredit
        elseif cdk == "UEBERWEISUNG" then
          txType = TransactionTypeTransfer
        elseif cdk ~= "" then
          txType = TransactionTypeDebit
        end

        transactions[#transactions+1] = {
          name          = name,
          accountNumber = tx["recipientIban"] or "",
          bankCode      = tx["recipientBic"]  or "",
          amount        = tonumber(tx["amount"]) or 0,
          currency      = "EUR",
          bookingDate   = dt,
          valueDate     = dt,
          purpose       = purpose,
          booked        = tx["booked"] ~= false,
          type          = txType,
        }
      end
    end

    -- Pagination
    if data["more"] == true then
      page = page + 1
      if page > 50 then break end  -- safety limit (~2500+ transactions)
    else
      if data["moreWithSCA"] == true then moreWithSCA = true end
      stop = true
    end
  end

  return transactions, moreWithSCA
end

--------------------------------------------------------------------------------
-- MoneyMoney WebBanking interface
--------------------------------------------------------------------------------

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Hanseatic Bank"
end

--[[
  Login flow:

  Step 1: HTTP-Login senden, SCA auslösen (Altzustand wird gelöscht)
          -> SMS: OTP-Eingabedialog (label gesetzt)
          -> APP: "In App bestätigen"-Dialog
          Der HTTP-Call in Step 1 hält das Fenster offen und verhindert,
          dass andere Extensions beim Rundruf dazwischenkommen.

  Steps 2+: Zustandsbasierte Verarbeitung (LocalStorage):

          Phase A — scaId gesetzt (Login-SCA ausstehend):
            SMS: OTP aus credentials[1] prüfen
            APP: SCA-Status abfragen; bei "open" pending-Dialog zurückgeben
                 (jeder Klick erhöht den Step, Zustand bleibt in LocalStorage)

          Phase B — sessionScaId gesetzt (Session-SCA ausstehend):
            SMS: OTP per PUT bestätigen
            APP: Status abfragen; bei "open" pending-Dialog zurückgeben

          Phase C — nichts ausstehend: Anmeldung abgeschlossen, nil zurück

  needSessionSCA wird gesetzt wenn:
    - moreWithSCA=true beim Transaktionsabruf
    - UND historyLoaded noch nicht "yes"
  -> Nur beim ersten Sync mit vollständiger Historie
]]

function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  ensureConnection()

  local loginId  = credentials[1]
  local password = credentials[2]

  -- ----------------------------------------------------------------
  -- STEP 1: Login-Request senden und SCA auslösen
  -- ----------------------------------------------------------------
  -- Zugangsdaten werden nur in Step 1 übergeben → sofort speichern.
  -- HTTP-Call in Step 1: MoneyMoney zeigt sofort das OTP-Eingabefeld
  -- oder die App-Bestätigung (EIN Fenster, kein Pre-Dialog).
  -- Altzustand aus früheren Sessions wird vollständig gelöscht.
  if step == 1 then
    LocalStorage.scaId          = nil
    LocalStorage.scaType        = nil
    LocalStorage.tries          = nil
    LocalStorage.accessToken    = nil
    LocalStorage.sessionScaId   = nil
    LocalStorage.sessionScaType = nil
    LocalStorage.sessionTries   = nil
    LocalStorage.userId = loginId
    LocalStorage.pw     = password

    -- Non-interactive guard: never trigger SCA pushes during background syncs.
    -- Even the device token POST triggers a push (bank returns id_token, not
    -- access_token directly), so we must guard before any network request.
    if not interactive then
      return LoginFailed
    end

    -- Device token: bank always requires SCA (returns id_token), but sending
    -- the stored token tells the bank which device to use. Reuse the SCA
    -- session from this POST instead of sending a second request.
    local storedToken = LocalStorage.deviceToken
    if storedToken then
      MM.printStatus("Anmeldung mit gespeichertem Geräteschlüssel...")
      local resp = connection:request(
        "POST", API .. "/token",
        "grant_type=hbSCACustomPassword"
        .. "&password=" .. ue(password)
        .. "&loginId="  .. ue(loginId),
        "application/x-www-form-urlencoded; charset=UTF-8",
        hdrBasic({["devicetoken"] = storedToken})
      )
      if not isError(resp) then
        local d   = tryJSON(resp)
        local tok = d and d["access_token"]
        if tok then
          -- Uncommon: bank accepted token without SCA.
          accessToken = tok
          LocalStorage.accessToken = tok
          LocalStorage.pw          = nil
          getCustomerData(tok)

          local doSessionSCA = LocalStorage.needSessionSCA == "yes"
          if doSessionSCA then LocalStorage.needSessionSCA = nil end

          if doSessionSCA then
            MM.printStatus("Bestätigung für vollständige Umsatzhistorie wird angefordert...")
            local sessionScaId, sessionScaType = startSessionSCA(tok)

            if sessionScaId then
              LocalStorage.sessionScaId   = sessionScaId
              LocalStorage.sessionScaType = sessionScaType or "APP"
              LocalStorage.sessionTries   = 0

              if sessionScaType == "SMS" then
                return {
                  title     = "SMS-OTP für Umsatzhistorie",
                  challenge = "Ein SMS-OTP für den Zugriff auf die vollständige\n"
                            .. "Umsatzhistorie wurde gesendet.\n\n"
                            .. "Bitte OTP eingeben:",
                  label     = "SMS-OTP",
                }
              else
                return {
                  title     = "App-Bestätigung für Umsätze",
                  challenge = "Bitte den Zugriff auf die Umsatzhistorie\n"
                            .. "in der Hanseatic Bank App bestätigen.",
                  values    = {"Bestätigung erteilt"},
                }
              end
            end
          end

          MM.printStatus("Erfolgreich angemeldet.")
          return nil
        end

        -- Bank requires SCA (returned id_token). Reuse this SCA session to
        -- avoid sending a second POST (which would trigger a second push).
        local idToken = d and d["id_token"]
        local payload = idToken and extractJWTPayload(idToken)
        local scaId   = payload and payload["sca_id"]
        local scaType = payload and (payload["sca_type"] or "APP")

        if scaId then
          -- deviceToken is valid; keep it for the final exchange in Phase A.
          LocalStorage.scaId   = scaId
          LocalStorage.scaType = scaType
          LocalStorage.tries   = 0
          if scaType == "SMS" then
            return {
              title     = "SMS-OTP eingeben",
              challenge = "Ein SMS-OTP wurde an Ihre hinterlegte Mobilnummer gesendet.\n\n"
                        .. "Bitte OTP eingeben:",
              label     = "SMS-OTP",
            }
          else
            return {
              title     = "App-Bestätigung erforderlich",
              challenge = "Eine Anmeldeanforderung wurde an die Hanseatic Bank App gesendet.\n\n"
                        .. "Bitte die App öffnen, die Anmeldung bestätigen\n"
                        .. "und dann auf 'Weiter' klicken."
            }
          end
        end
      end
      -- Actual error from bank (e.g. password change): token rejected.
      MM.printStatus("Geräteschlüssel ungültig — vollständige SCA erforderlich...")
      LocalStorage.deviceToken = nil
    end

    MM.printStatus("Anmeldung wird gesendet...")

    local resp = connection:request(
      "POST", API .. "/token",
      "grant_type=hbSCACustomPassword"
      .. "&password=" .. ue(password)
      .. "&loginId="  .. ue(loginId),
      "application/x-www-form-urlencoded; charset=UTF-8",
      hdrBasic()
    )

    if isError(resp) then
      return {
        title     = "Anmeldung fehlgeschlagen",
        challenge = "Bitte Login-ID und Passwort prüfen."
      }
    end

    local data    = tryJSON(resp)
    local idToken = data and data["id_token"]
    if not idToken then
      return { title="Fehler", challenge="Unerwartete Serverantwort." }
    end

    local payload = extractJWTPayload(idToken)
    if not payload then
      return { title="Fehler", challenge="JWT konnte nicht gelesen werden." }
    end

    local scaId   = payload["sca_id"]
    local scaType = payload["sca_type"] or "APP"
    if not scaId then
      return { title="Fehler", challenge="Keine SCA-ID erhalten." }
    end

    LocalStorage.scaId   = scaId
    LocalStorage.scaType = scaType
    LocalStorage.tries   = 0

    if scaType == "SMS" then
      return {
        title     = "SMS-OTP eingeben",
        challenge = "Ein SMS-OTP wurde an Ihre hinterlegte Mobilnummer gesendet.\n\n"
                  .. "Bitte OTP eingeben:",
        label     = "SMS-OTP",
      }
    else
      return {
        title     = "App-Bestätigung erforderlich",
        challenge = "Eine Anmeldeanforderung wurde an die Hanseatic Bank App gesendet.\n\n"
                  .. "Bitte die App öffnen, die Anmeldung bestätigen\n"
                  .. "und dann auf 'Weiter' klicken."
      }
    end
  end

  -- ----------------------------------------------------------------
  -- STEPS 2+: Zustandsbasierte Verarbeitung
  -- MoneyMoney erhöht die Schrittnummer bei jedem Dialog immer weiter.
  -- Daher wird der Zustand über LocalStorage verwaltet.
  -- ----------------------------------------------------------------

  -- ----------------------------------------------------------------
  -- PHASE A: Login-SCA abschließen (noch kein Access-Token)
  -- ----------------------------------------------------------------
  if LocalStorage.scaId then
    local scaId   = LocalStorage.scaId
    local scaType = LocalStorage.scaType or "APP"
    local uid     = LocalStorage.userId
    local pw      = LocalStorage.pw

    if not uid or not pw then return LoginFailed end

    local tok = nil

    -- SMS: verify OTP submitted by user
    if scaType == "SMS" then
      MM.printStatus("SMS-OTP wird geprüft...")
      local tan = (credentials[1] or ""):match("^%s*(.-)%s*$") or ""
      if tan == "" then
        return { title="OTP erforderlich",
                 challenge="Bitte SMS-OTP eingeben:", label="SMS-OTP" }
      end

      local resp = connection:request(
        "POST", API .. "/token",
        "grant_type=hbSCACustomPassword"
        .. "&loginId=" .. ue(uid)
        .. "&otp="     .. ue(tan)
        .. "&scaId="   .. ue(scaId),
        "application/x-www-form-urlencoded; charset=UTF-8",
        hdrBasic()
      )

      if isError(resp) then
        return { title="OTP ungültig oder abgelaufen",
                 challenge="Bitte erneut anmelden." }
      end

      local d = tryJSON(resp)
      tok = d and d["access_token"]

    -- APP: poll SCA status and get final token when complete
    else
      MM.printStatus("App-Bestätigung wird geprüft...")

      local clientToken = getClientToken()
      if not clientToken then return LoginFailed end

      local sResp = connection:request(
        "GET",
        API .. "/openScaBroker/1.0/customer/" .. ue(uid) .. "/status/" .. scaId,
        nil, nil, hdrBearer(clientToken)
      )

      local sca    = tryJSON(sResp)
      local status = sca and sca["status"]

      if status == "open" then
        local t = (LocalStorage.tries or 0) + 1
        LocalStorage.tries = t
        if t >= 15 then  -- max polling attempts reached
          LocalStorage.scaId = nil
          LocalStorage.pw    = nil
          return LoginFailed
        end
        -- Return pending dialog; MoneyMoney will increment step but
        -- Phase A will still apply on the next call (scaId still set).
        return {
          title     = string.format("App-Bestätigung ausstehend (%d/15)", t),
          challenge = "Bitte die Anmeldung in der Hanseatic Bank App bestätigen.",
          values    = {"Bestätigung erteilt"},
        }
      end

      if not sca or status ~= "complete" then return LoginFailed end

      local rd          = sca["resultData"] or {}
      local deviceToken = rd["DEVICETOKEN"] or ""
      local fExtra      = {}
      if deviceToken ~= "" then
        fExtra["devicetoken"]    = deviceToken
        LocalStorage.deviceToken = deviceToken  -- persist for future syncs
      end

      local fResp = connection:request(
        "POST", API .. "/token",
        "grant_type=hbSCACustomPassword"
        .. "&password=" .. ue(pw)
        .. "&loginId="  .. ue(uid),
        "application/x-www-form-urlencoded; charset=UTF-8",
        hdrBasic(fExtra)
      )

      if isError(fResp) then return LoginFailed end

      local d = tryJSON(fResp)
      tok = d and d["access_token"]
    end

    if not tok then return LoginFailed end

    -- Login successful: persist access token, clear login SCA state
    accessToken = tok
    LocalStorage.accessToken = tok
    LocalStorage.scaId       = nil
    LocalStorage.pw          = nil
    LocalStorage.tries       = nil

    -- Preload customer data and cache for ListAccounts
    getCustomerData(tok)

    -- Only start session SCA if moreWithSCA=true on last refresh
    -- AND full history has never been successfully loaded
    local doSessionSCA = LocalStorage.needSessionSCA == "yes"
    LocalStorage.needSessionSCA = nil  -- always reset

    if doSessionSCA then
      MM.printStatus("Bestätigung für vollständige Umsatzhistorie wird angefordert...")
      local sessionScaId, sessionScaType = startSessionSCA(tok)

      if sessionScaId then
        LocalStorage.sessionScaId   = sessionScaId
        LocalStorage.sessionScaType = sessionScaType or "APP"
        LocalStorage.sessionTries   = 0

        if sessionScaType == "SMS" then
          return {
            title     = "SMS-OTP für Umsatzhistorie",
            challenge = "Ein SMS-OTP für den Zugriff auf die vollständige\n"
                      .. "Umsatzhistorie wurde gesendet.\n\n"
                      .. "Bitte OTP eingeben:",
            label     = "SMS-OTP",
          }
        else
          return {
            title     = "App-Bestätigung für Umsätze",
            challenge = "Bitte den Zugriff auf die Umsatzhistorie\n"
                      .. "in der Hanseatic Bank App bestätigen.",
            values    = {"Bestätigung erteilt"},
          }
        end
      end
    end

    MM.printStatus("Erfolgreich angemeldet.")
    return nil
  end

  -- ----------------------------------------------------------------
  -- PHASE B: Complete session SCA (login done, session SCA pending)
  -- ----------------------------------------------------------------
  if LocalStorage.sessionScaId then
    local tok            = LocalStorage.accessToken
    local sessionScaId   = LocalStorage.sessionScaId
    local sessionScaType = LocalStorage.sessionScaType or "APP"

    if not tok then return LoginFailed end

    accessToken = tok

    -- SMS: confirm with OTP via PUT
    if sessionScaType == "SMS" then
      MM.printStatus("OTP für Umsatzhistorie wird geprüft...")
      local tan = (credentials[1] or ""):match("^%s*(.-)%s*$") or ""

      if tan == "" then
        return { title="OTP erforderlich",
                 challenge="Bitte SMS-OTP für die Umsatzhistorie eingeben:",
                 label="SMS-OTP" }
      end

      local success = confirmSessionSCAWithOTP(sessionScaId, tan, tok)

      if not success then
        local status = checkSessionSCA(sessionScaId, tok)
        if status ~= "complete" then
          local t = (LocalStorage.sessionTries or 0) + 1
          LocalStorage.sessionTries = t
          if t < 3 then
            return { title="OTP ungültig",
                     challenge="Bitte erneut versuchen.\nOTP eingeben:",
                     label="SMS-OTP" }
          end
          -- Nach 3 Fehlversuchen: ohne vollständige Historie fortfahren
        end
      end

    -- APP: poll status
    else
      MM.printStatus("App-Bestätigung für Umsätze wird geprüft...")
      local status = checkSessionSCA(sessionScaId, tok)

      if status == "open" then
        local t = (LocalStorage.sessionTries or 0) + 1
        LocalStorage.sessionTries = t
        if t >= 15 then  -- max polling attempts reached; continue without full history
          LocalStorage.sessionScaId = nil
          MM.printStatus("Erfolgreich angemeldet (ohne vollständige Umsatzhistorie).")
          return nil
        end
        -- Return pending dialog; Phase B still applies on next call (sessionScaId set).
        return {
          title     = string.format("App-Bestätigung ausstehend (%d/15)", t),
          challenge = "Bitte den Zugriff auf die Umsätze\n"
                    .. "in der Hanseatic Bank App bestätigen.",
          values    = {"Bestätigung erteilt"},
        }
      end
    end

    -- Session SCA erfolgreich abgeschlossen.
    -- historyLoaded markiert, dass die vollständige Historie geladen wurde
    -- -> zukünftige Syncs benötigen nur eine einzige Bestätigung
    LocalStorage.historyLoaded  = "yes"
    LocalStorage.sessionScaId   = nil
    LocalStorage.sessionScaType = nil
    LocalStorage.sessionTries   = nil

    MM.printStatus("Erfolgreich angemeldet.")
    return nil
  end

  -- ----------------------------------------------------------------
  -- PHASE C: Nothing pending (should not normally be reached)
  -- ----------------------------------------------------------------
  return LoginFailed
end

--------------------------------------------------------------------------------
-- List accounts
--------------------------------------------------------------------------------

function ListAccounts(knownAccounts)
  ensureConnection()
  accessToken = accessToken or LocalStorage.accessToken
  if not accessToken then return {} end

  MM.printStatus("Loading accounts...")

  -- Use cache (already loaded during login)
  local cd = getCustomerData(accessToken)
  if not cd then return {} end

  local result = {}
  local accs   = cd["accounts"] or {}

  -- Credit cards
  for _, a in ipairs(accs["creditAccounts"] or {}) do
    local cc = a["creditcard"] or {}
    result[#result+1] = {
      name             = a["productLabel"]  or "Hanseatic Bank Credit Card",
      owner            = a["accountHolder"] or "",
      accountNumber    = a["accountNumber"] or "",
      iban             = a["iban"]          or "",
      bic              = normalizeBic(a["bic"] or ""),
      currency         = "EUR",
      type             = AccountTypeCreditCard,
      -- tpan is a tokenised PAN (real card number not available via API)
      -- Non-digits replaced with X: "415299MTPQBJ9866" -> "415299XXXXXX9866"
      creditCardNumber = formatTpan(cc["tpan"] or ""),
    }
  end

  -- Overnight money accounts
  for _, a in ipairs(accs["overnightAccounts"] or {}) do
    result[#result+1] = {
      name          = a["productLabel"]  or "Hanseatic Bank Overnight Account",
      owner         = a["accountHolder"] or "",
      accountNumber = a["accountNumber"] or "",
      iban          = a["iban"]          or "",
      bic           = normalizeBic(a["bic"] or ""),
      currency      = "EUR",
      type          = AccountTypeSavings,
    }
  end

  -- Installment loans
  for _, a in ipairs(accs["loanAccounts"] or {}) do
    result[#result+1] = {
      name          = a["productLabel"]  or "Hanseatic Bank Loan",
      owner         = a["accountHolder"] or "",
      accountNumber = a["accountNumber"] or "",
      iban          = a["iban"]          or "",
      bic           = normalizeBic(a["bic"] or ""),
      currency      = "EUR",
      type          = AccountTypeLoan,
    }
  end

  return result
end

--------------------------------------------------------------------------------
-- Refresh account
--------------------------------------------------------------------------------

function RefreshAccount(account, since)
  ensureConnection()
  accessToken = accessToken or LocalStorage.accessToken
  if not accessToken then
    return nil, "No valid token — please log in again."
  end

  MM.printStatus("Loading account data...")

  -- Load customer data from cache or fresh
  local cd      = getCustomerData(accessToken)
  local balance = findBalance(cd, account.accountNumber)

  MM.printStatus("Loading transactions...")

  local transactions, moreWithSCA = loadAllTransactions(
    accessToken, account.accountNumber, since
  )

  -- Reset cache after refresh so next sync gets fresh data
  customerCache = nil

  -- Only request session SCA on next login if:
  -- 1. API reports moreWithSCA=true (older transactions exist)
  -- 2. AND full history has never been successfully loaded (historyLoaded not set)
  if moreWithSCA and not LocalStorage.historyLoaded then
    LocalStorage.needSessionSCA = "yes"
  end
  -- If historyLoaded="yes": needSessionSCA is never set again
  -- -> single confirmation from second sync onwards

  return {
    balance      = balance,
    transactions = transactions,
  }
end

--------------------------------------------------------------------------------
-- End session
--------------------------------------------------------------------------------

function EndSession()
  accessToken   = nil
  customerCache = nil
  LocalStorage.accessToken    = nil
  LocalStorage.scaId          = nil
  LocalStorage.scaType        = nil
  LocalStorage.userId         = nil
  LocalStorage.pw             = nil
  LocalStorage.tries          = nil
  LocalStorage.sessionScaId   = nil
  LocalStorage.sessionScaType = nil
  LocalStorage.sessionTries   = nil
  -- Intentionally NOT clearing historyLoaded, deviceToken, or needSessionSCA.
  -- historyLoaded:  future syncs need no session SCA confirmation.
  -- deviceToken:    future syncs can skip the SCA push entirely.
  -- needSessionSCA: persists until the next interactive sync picks it up.
  return nil
end