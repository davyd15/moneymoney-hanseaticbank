-- ============================================================
-- MoneyMoney Web Banking Extension
-- Hanseatic Bank (HB) Germany – Meine Hanseatic Bank
-- Version: 3.71
--
-- Credentials:
--   Username: Login ID (10-digit number, e.g. 5101821536)
--   Password: Your Hanseatic Bank password
--
-- Changes in 3.71:
--   - Added confirmation dialog before OTP request to prevent
--     simultaneous OTP triggers when refreshing all accounts
-- ============================================================

WebBanking{
  version     = 3.71,
  url         = "https://meine.hanseaticbank.de",
  services    = {"Hanseatic Bank"},
  description = "Hanseatic Bank credit card (App SCA or SMS OTP)"
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local API        = "https://connecthb.hanseaticbank.de"
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

        -- Determine transaction type
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
      if page > 50 then break end  -- safety limit
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
  Login flow (up to 4 steps):

  Step 1: Show confirmation dialog (no HTTP request)
          -> Prevents simultaneous OTP requests on bulk refresh

  Step 2: Request login token + trigger SCA
          -> SMS: OTP input dialog
          -> APP: "Confirm in app" dialog

  Step 3: Complete login + optionally start session SCA
          -> If needSessionSCA set: start session SCA
            -> SMS: OTP input dialog for transactions
            -> APP: "Confirm in app" dialog
          -> Otherwise: done (single confirmation)

  Step 4: Complete session SCA (only if started)
          -> SMS: PUT with OTP
          -> APP: GET status poll
          -> Set historyLoaded to "yes"

  needSessionSCA is set when:
    - moreWithSCA=true on transaction fetch
    - AND historyLoaded is not yet "yes"
  -> Only on first sync with full history
]]

function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  ensureConnection()

  local loginId  = credentials[1]
  local password = credentials[2]

  -- ----------------------------------------------------------------
  -- STEP 1: Confirmation dialog (no OTP trigger)
  -- ----------------------------------------------------------------
  if step == 1 then
    -- Save credentials here — MoneyMoney does not pass them to step 2
    LocalStorage.userId = loginId
    LocalStorage.pw     = password
    return {
      title     = "Hanseatic Bank – Login",
      challenge = "Login requires confirmation via app or SMS.\n\n"
                .. "Click 'Done' to start the login\n"
                .. "and trigger the confirmation request.",
    }
  end

  -- ----------------------------------------------------------------
  -- STEP 2: Request login token + trigger SCA
  -- ----------------------------------------------------------------
  if step == 2 then
    -- Read credentials from LocalStorage (saved in step 1)
    loginId  = LocalStorage.userId or loginId
    password = LocalStorage.pw     or password
    MM.printStatus("Sending login request...")

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
        title     = "Login failed",
        challenge = "Please check your Login ID and password."
      }
    end

    local data    = tryJSON(resp)
    local idToken = data and data["id_token"]
    if not idToken then
      return { title="Error", challenge="Unexpected server response." }
    end

    local payload = extractJWTPayload(idToken)
    if not payload then
      return { title="Error", challenge="Could not parse JWT." }
    end

    local scaId   = payload["sca_id"]
    local scaType = payload["sca_type"] or "APP"
    if not scaId then
      return { title="Error", challenge="No SCA ID received." }
    end

    -- Save login data for step 3
    LocalStorage.scaId   = scaId
    LocalStorage.scaType = scaType
    LocalStorage.userId  = loginId
    LocalStorage.pw      = password
    LocalStorage.tries   = 0

    if scaType == "SMS" then
      return {
        title     = "Enter SMS OTP",
        challenge = "An SMS OTP has been sent to your registered mobile number.\n\n"
                  .. "Please enter the OTP:",
        label     = "SMS OTP",
      }
    else
      return {
        title     = "App confirmation required",
        challenge = "A login request has been sent to the Hanseatic Bank app.\n\n"
                  .. "Please open the app, confirm the login,\n"
                  .. "and then click 'Done'."
      }
    end
  end

  -- ----------------------------------------------------------------
  -- STEP 3: Complete login + optionally start session SCA
  -- ----------------------------------------------------------------
  if step == 3 then
    local scaId   = LocalStorage.scaId
    local scaType = LocalStorage.scaType or "APP"
    local uid     = LocalStorage.userId
    local pw      = LocalStorage.pw

    if not scaId or not uid or not pw then return LoginFailed end

    local tok = nil

    -- SMS login: request token with OTP
    if scaType == "SMS" then
      MM.printStatus("Verifying SMS OTP...")
      local tan = (credentials[1] or ""):match("^%s*(.-)%s*$") or ""
      if tan == "" then
        return { title="OTP required",
                 challenge="Please enter the SMS OTP:", label="SMS OTP" }
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
        return { title="Invalid or expired OTP",
                 challenge="Please try logging in again." }
      end

      local d = tryJSON(resp)
      tok = d and d["access_token"]
      if tok then LocalStorage.refreshToken = d["refresh_token"] end

    -- APP login: check SCA status + get final token
    else
      MM.printStatus("Checking app confirmation...")

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
        if t >= 15 then
          LocalStorage.scaId = nil
          LocalStorage.pw    = nil
          return LoginFailed
        end
        return {
          title     = string.format("App confirmation pending (%d/15)", t),
          challenge = "Please confirm the login in the Hanseatic Bank app\n"
                    .. "and then click 'Done'."
        }
      end

      if not sca or status ~= "complete" then return LoginFailed end

      local rd          = sca["resultData"] or {}
      local deviceToken = rd["DEVICETOKEN"] or ""
      local fExtra      = {}
      if deviceToken ~= "" then fExtra["devicetoken"] = deviceToken end

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
      if tok then LocalStorage.refreshToken = d["refresh_token"] end
    end

    if not tok then return LoginFailed end

    -- Save token, clear sensitive data
    accessToken = tok
    LocalStorage.accessToken = tok
    LocalStorage.scaId       = nil
    LocalStorage.pw          = nil

    -- Preload customer data and cache for ListAccounts
    getCustomerData(tok)

    -- Only start session SCA if moreWithSCA=true on last refresh
    -- AND full history has never been successfully loaded
    local doSessionSCA = LocalStorage.needSessionSCA == "yes"
    LocalStorage.needSessionSCA = nil  -- always reset

    if doSessionSCA then
      MM.printStatus("Starting confirmation for full transaction history...")
      local sessionScaId, sessionScaType = startSessionSCA(tok)

      if sessionScaId then
        LocalStorage.sessionScaId   = sessionScaId
        LocalStorage.sessionScaType = sessionScaType or "APP"
        LocalStorage.sessionTries   = 0

        if sessionScaType == "SMS" then
          return {
            title     = "OTP for transaction history",
            challenge = "An SMS OTP for accessing the full\n"
                      .. "transaction history has been sent.\n\n"
                      .. "Please enter the OTP:",
            label     = "SMS OTP",
          }
        else
          return {
            title     = "App confirmation for transactions",
            challenge = "Please confirm access to the transaction history\n"
                      .. "in the Hanseatic Bank app\n"
                      .. "and then click 'Done'."
          }
        end
      end
    end

    MM.printStatus("Logged in successfully.")
    return nil
  end

  -- ----------------------------------------------------------------
  -- STEP 4: Complete session SCA
  -- ----------------------------------------------------------------
  if step == 4 then
    local tok            = LocalStorage.accessToken
    local sessionScaId   = LocalStorage.sessionScaId
    local sessionScaType = LocalStorage.sessionScaType or "APP"

    if not tok or not sessionScaId then
      MM.printStatus("Logged in successfully.")
      return nil
    end

    accessToken = tok

    -- SMS: confirm with OTP via PUT
    if sessionScaType == "SMS" then
      MM.printStatus("Confirming OTP for transaction history...")
      local tan = (credentials[1] or ""):match("^%s*(.-)%s*$") or ""

      if tan == "" then
        return { title="OTP required",
                 challenge="Please enter the SMS OTP for\ntransaction history:",
                 label="SMS OTP" }
      end

      local success = confirmSessionSCAWithOTP(sessionScaId, tan, tok)

      if not success then
        -- Check status once more
        local status = checkSessionSCA(sessionScaId, tok)
        if status ~= "complete" then
          local t = (LocalStorage.sessionTries or 0) + 1
          LocalStorage.sessionTries = t
          if t < 3 then
            return { title="Invalid OTP",
                     challenge="Please try again.\nEnter OTP:",
                     label="SMS OTP" }
          end
          -- After 3 failed attempts: continue without full history
        end
      end

    -- APP: poll status
    else
      MM.printStatus("Checking app confirmation for transactions...")
      local status = checkSessionSCA(sessionScaId, tok)

      if status == "open" then
        local t = (LocalStorage.sessionTries or 0) + 1
        LocalStorage.sessionTries = t
        if t >= 15 then
          -- Timeout: continue without full history
          LocalStorage.sessionScaId = nil
          MM.printStatus("Logged in successfully (without full transaction history).")
          return nil
        end
        return {
          title     = string.format("App confirmation pending (%d/15)", t),
          challenge = "Please confirm access to the transactions\n"
                    .. "in the Hanseatic Bank app\n"
                    .. "and then click 'Done'."
        }
      end
    end

    -- Session SCA completed successfully.
    -- historyLoaded marks that full history was loaded
    -- -> future syncs require only a single confirmation
    LocalStorage.historyLoaded  = "yes"
    LocalStorage.sessionScaId   = nil
    LocalStorage.sessionScaType = nil
    LocalStorage.sessionTries   = nil

    MM.printStatus("Logged in successfully.")
    return nil
  end

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
  LocalStorage.refreshToken   = nil
  LocalStorage.scaId          = nil
  LocalStorage.scaType        = nil
  LocalStorage.userId         = nil
  LocalStorage.pw             = nil
  LocalStorage.tries          = nil
  LocalStorage.sessionScaId   = nil
  LocalStorage.sessionScaType = nil
  LocalStorage.sessionTries   = nil
  LocalStorage.needSessionSCA = nil
  -- Intentionally NOT clearing historyLoaded.
  -- It persists permanently so future syncs need no second confirmation.
  return nil
end
