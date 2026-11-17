# Santander MX Bank Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native `santander_mx` provider that pulls Santander MX transactions from the
`santander-mx-gmail-parser` service into linked Sure accounts. Their balances stay
ledger-driven (forward-calculated, editable by hand).

**Architecture:** A Fio-shaped provider: `SantanderMxItem` (connection, Syncable) →
`SantanderMxItem::Importer` (one HTTP call through `Provider::SantanderMx`, rows grouped
by product into `SantanderMxAccount`s) → `SantanderMxEntry::Processor` →
`Account::ProviderImportAdapter#import_transaction`. A new adapter capability,
`reports_balance?`, lets linked accounts keep the manual (forward) balance path.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, HTTParty, Hotwire/ERB with `DS::*`
components.

**Spec:** `docs/superpowers/specs/2026-11-15-santander-mx-bank-sync-design.md`. Read it
before starting any task. The Fio provider is the reference implementation throughout:
`app/models/fio_item.rb`, `app/models/fio_item/*`, `app/models/fio_account*`,
`app/models/fio_entry/processor.rb`, `app/models/provider/fio*.rb`,
`app/controllers/fio_items_controller.rb`, `app/views/fio_items/*`,
`app/views/settings/providers/_fio_panel.html.erb`, and commit `985b51207`.

## Global Constraints

- Provider key `santander_mx` everywhere: entry `source`, `DebugLogEntry` `provider_key`,
  `Provider::Metadata` key, settings panel key.
- Each sync makes one service request: `GET {base_url}/transactions?since=YYYY-MM-DD`
  with `Authorization: Bearer <api_token>`. `until` is never sent.
- `LOOKBACK_DAYS = 3`. The default first window is 90 days.
- Sign comes from `type`: `purchase` → `amount.abs`, `transfer_out` → `amount.abs`,
  `transfer_in` → `-amount.abs`.
- The Santander provider never writes a balance. `Provider::SantanderMxAdapter#reports_balance?`
  is `false`.
- The API token never appears in URLs, exception messages, logs or `DebugLogEntry`
  metadata.
- Supported account types: `CreditCard`, `Depository`. Only the link-existing-account
  flow exists.
- Migrations use `ActiveRecord::Migration[8.1]`. Do not run `db:migrate` automatically;
  ask the human first (AGENTS.md). Tests use `db/schema.rb`, so each migration task also
  hand-edits `db/schema.rb` and bumps its version.
- UI: `DS::*` components, the `icon` helper, `t()` for every string, functional tokens
  only. English locales only.
- Use `Current.family`. Every controller action is scoped to it and requires an admin
  (`require_admin!`), as in `FioItemsController`.
- Run single tests with `bin/rails test path/to/test.rb`. Commits use imperative subjects
  of at most 72 characters.
- Locales: every `santander_mx` key lives in the one file
  `config/locales/views/santander_mx_items/en.yml` (the layout Fio uses). Each task adds
  the keys its own code uses, creating the file on first use. Merge into the existing
  mappings and never re-declare a key: `test/i18n_test.rb` fails on duplicate keys.
- The working tree holds unrelated uncommitted changes. Stage only the files your task
  created or modified (`git add <paths>`), never `git add -A` or `git commit -a`.

## Review Focus

1. **A row whose `account` is null or blank.** It is skipped and logged. No blank-named
   `SantanderMxAccount` is created (that would raise and fail the whole import). Test in
   Task 6.
2. **The same Gmail `id` arriving under a different `account`** (after a parser fix). The
   row moves: it is removed from the old product's payload, so it can't be replayed into
   two accounts. Test in Task 6.
3. **`base_url` with a trailing slash or a path prefix** (`http://parser:5000/`,
   `https://host/santander`). The request goes to `{base_url without trailing
   slash}/transactions`. Test in Task 3.
4. **A late-evening transaction** (`"2026-11-03T23:50:00"`). It is booked on 2026-11-03,
   never shifted by a time-zone conversion. Parse with `Date.parse` on the string. Test in
   Task 5.
5. **A successful response with no transactions.** The cursor still advances, stored
   payloads are untouched, and the import doesn't fail. Test in Task 6.

---

### Task 1: Ledger-driven balance capability

**Files:**
- Modify: `app/models/provider/base.rb` (next to `can_delete_holdings?`)
- Modify: `app/models/account/linkable.rb` (next to `linked?`)
- Modify: `app/models/account/syncer.rb:9,22`
- Modify: `app/models/account/current_balance_manager.rb:41`
- Modify: `app/views/accounts/_form.html.erb:16`
- Modify: `app/views/accounts/show/_activity.html.erb:7`
- Modify: `app/components/UI/account/activity_feed.html.erb:8,12`
- Modify: `app/models/assistant/function/set_opening_balance.rb:66`
- Test: `test/models/account/linkable_test.rb`, `test/models/account/syncer_test.rb`,
  `test/models/account/current_balance_manager_test.rb`,
  `test/controllers/accounts_controller_test.rb`

**Interfaces:**
- Produces: `Provider::Base#reports_balance? -> Boolean` (default `true`).
  `Account#balance_from_provider? -> Boolean`, defined as
  `linked? && providers.all?(&:reports_balance?)`.

Until Task 4 exists, tests get a non-reporting provider by linking an account to
`fio_accounts(:checking)` and stubbing
`Provider::FioAdapter.any_instance.stubs(:reports_balance?).returns(false)`.

- [ ] **Step 1: Write failing tests**
  - `linkable_test.rb`:
    - `balance_from_provider? is false for a manual account`
    - `balance_from_provider? is true for an account linked to a balance-reporting provider` (Fio-linked, no stub)
    - `balance_from_provider? is false when the linked provider does not report balances` (Fio-linked, stubbed)
  - `syncer_test.rb`:
    - `uses the forward strategy for a linked account whose provider does not report balances`: `Balance::Materializer.expects(:new).with(account, strategy: :forward, window_start_date: nil).returns(stub(materialize_balances: true))`
    - `still uses the reverse strategy for a balance-reporting linked account`: same, with `strategy: :reverse`
    - Both stub `Account::MarketDataImporter.any_instance.stubs(:import_all)` and call `perform_sync(OpenStruct.new(window_start_date: nil))`.
  - `current_balance_manager_test.rb`: `a linked account whose provider does not report balances takes the manual path`. A stubbed Fio-linked Depository account with an opening anchor; `set_current_balance(1500)` succeeds, `account.reload.has_current_anchor?` is false, and `account.balance == 1500`.
  - `accounts_controller_test.rb`: `shows New balance on a linked account whose provider does not report balances`. With the stub, `get account_path(account)` includes the text of `t("accounts.show.activity.new_balance")`.

- [ ] **Step 2: Run them; expect FAIL** (`NoMethodError: balance_from_provider?`, or the strategy expectation fails)

  Run: `bin/rails test test/models/account/linkable_test.rb test/models/account/syncer_test.rb test/models/account/current_balance_manager_test.rb test/controllers/accounts_controller_test.rb`

- [ ] **Step 3: Implement**
  - Add `reports_balance?` to `Provider::Base` and `balance_from_provider?` to `Account::Linkable`, with a one-line comment: "a linked account whose provider sends transactions but no balance keeps the manual, ledger-driven balance".
  - Replace `linked?` with `balance_from_provider?` at exactly the eight lines listed under Files. Every other `linked?` stays.
  - In `activity_feed.html.erb:8`, the crypto condition becomes `if !account.balance_from_provider? || !account.crypto?`.

- [ ] **Step 4: Run the same tests; expect PASS. Then run `bin/rails test test/models/account test/models/balance` to catch regressions; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Keep ledger-driven balances for providers without balances"`

---

### Task 2: Tables, models and family wiring

**Files:**
- Create: `db/migrate/20261115120000_create_santander_mx_items_and_accounts.rb`
- Modify: `db/schema.rb` (both tables, plus the version)
- Create: `app/models/santander_mx_item.rb`, `app/models/santander_mx_item/provided.rb`, `app/models/santander_mx_item/unlinking.rb`, `app/models/santander_mx_item/sync_complete_event.rb`
- Create: `app/models/santander_mx_account.rb`
- Create: `app/models/family/santander_mx_connectable.rb`
- Modify: `app/models/family.rb` (`include SantanderMxConnectable` beside `include FioConnectable`)
- Create: `test/fixtures/santander_mx_items.yml`, `test/fixtures/santander_mx_accounts.yml`
- Create: `config/locales/views/santander_mx_items/en.yml` (`family.santander_mx.create_santander_mx_item.default_name`: "Santander MX")
- Test: `test/models/santander_mx_item_test.rb`, `test/models/santander_mx_account_test.rb`
- Also run `bin/rails test test/models/family test/models/sync_test.rb`: the new fixture item is discovered reflectively by `Family::Syncer`, so family sync tests must stay green.

**Interfaces:**
- Produces:
  - Tables and columns as in the spec's Data section, except `raw_transactions_payload`:
    make it nullable `jsonb` with no default, exactly like `fio_accounts.raw_transactions_payload`
    (encrypted jsonb with a default is not something this repo does), and treat nil as `{}`
    everywhere it is read (`payload.to_h`). Use `ActiveRecord::Migration[8.1]`. The newest
    existing migration is `20261114233000`; if a newer one exists, pick a later timestamp and
    rename the file and its schema version accordingly. Follow `db/schema.rb`'s dump format
    (alphabetical columns, `ActiveRecord::Schema[8.1].define(version: ...)`). Unique index on `santander_mx_accounts (santander_mx_item_id, name)`; index on `santander_mx_items (family_id)` and `(status)`. FK `santander_mx_items.family_id → families`; FK `santander_mx_accounts.santander_mx_item_id → santander_mx_items`.
  - `SantanderMxItem`: includes `Syncable, Provided, Unlinking, Encryptable, DestroyableLater`. `enum :status, { good: "good", requires_update: "requires_update" }, default: :good`. `encrypts :api_token` when `encryption_ready?`. `belongs_to :family`. `has_many :santander_mx_accounts, dependent: :destroy`. `has_many :accounts, through: :santander_mx_accounts`. Scopes `active`, `syncable` (= `active`), `ordered`. `validates :name, :base_url, presence: true`. `validates :api_token, presence: true, on: :create`. `validate :base_url_is_http_url` (absolute `http`/`https` with a host). `credentials_configured? -> Boolean`. `linked_accounts_count`, `unlinked_accounts_count`, `total_accounts_count` (like Fio's, without `ignored`).
  - `SantanderMxItem::Provided#santander_mx_provider -> Provider::SantanderMx | nil` (nil unless `credentials_configured?`), and `#syncer -> SantanderMxItem::Syncer`.
  - `SantanderMxItem::Unlinking#unlink_all!(dry_run: false) -> Array<Hash>`, and `SantanderMxItem::SyncCompleteEvent#broadcast`. Copy Fio's with `SantanderMxAccount` names.
  - `SantanderMxAccount`: includes `Encryptable`. `encrypts :raw_transactions_payload`. `belongs_to :santander_mx_item`. `has_one :account_provider, as: :provider, dependent: :destroy`. `has_one :account, through: :account_provider`. `validates :name, presence: true, uniqueness: { scope: :santander_mx_item_id }`. `scope :unlinked`. `#current_account -> Account | nil`. `#ensure_account_provider!(account) -> AccountProvider`.
  - `Family::SantanderMxConnectable`: `has_many :santander_mx_items, dependent: :destroy`. `create_santander_mx_item!(base_url:, api_token:, item_name: nil, sync_start_date: nil) -> SantanderMxItem` creates the item and calls `sync_later`. The default name is `t("family.santander_mx.create_santander_mx_item.default_name")`, "Santander MX".
  - Fixtures `santander_mx_items(:one)` (family `dylan_family`, `base_url: "http://parser.test"`, `api_token: "santander-test-token"`) and `santander_mx_accounts(:gold)` (`name: "SANTANDER GOLD"`, `last4: "1234"`, `currency: MXN`).

- [ ] **Step 1: Write failing tests**
  - `santander_mx_item_test.rb`:
    - `rejects a base_url that is not an absolute http(s) URL`: `"parser:5000"`, `"ftp://x"` and `"http://"` are invalid.
    - `accepts http and https base URLs`: `"http://parser:5000"`, `"https://host/santander"`.
    - `requires an api_token on create`.
    - `is syncable unless scheduled for deletion`.
    - `counts linked and unlinked accounts`.
  - `santander_mx_account_test.rb`: `names are unique per item`, and `unlinked excludes accounts with an account provider`.
  - Add `santander_mx_items` to `Family::FinancialDataReset`'s test only if that test enumerates associations explicitly. Check `test/models/family/financial_data_reset_test.rb`; the reset itself discovers `*_items` reflectively.

- [ ] **Step 2: Run; expect FAIL** (`NameError: SantanderMxItem`)

  Run: `bin/rails test test/models/santander_mx_item_test.rb test/models/santander_mx_account_test.rb`

- [ ] **Step 3: Write the migration and the `db/schema.rb` entries, then the models, concerns and fixtures as listed under Interfaces.** Ask the human before running `bin/rails db:migrate` on their development database.

- [ ] **Step 4: Run the same tests; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Add Santander MX connection and account models"`

---

### Task 3: Parser service client

**Files:**
- Create: `app/models/provider/santander_mx.rb`
- Test: `test/models/provider/santander_mx_test.rb`

**Interfaces:**
- Produces:
  - `Provider::SantanderMx < Provider`, with `include HTTParty`, `extend SslConfigurable`, a 60s timeout and Fio's retry and backoff (`RETRYABLE_ERRORS`, `MAX_RETRIES = 3`).
  - `Provider::SantanderMx.new(base_url:, api_token:)` raises `Error` (`failure_code: :configuration_error`) if either is blank.
  - `#get_transactions(since: Date) -> ActiveSupport::HashWithIndifferentAccess` with keys `transactions` (Array) and `unparsed` (Array, `[]` when absent).
  - Errors: `Error = Class.new(Provider::Error)`, `AuthenticationError < Error` (401), `ReauthorizationRequiredError < Error` (503; the message is the body's `"error"` value), `Error` (`failure_code: :bad_request`) for 400 with the body's `"error"`, `Error` (`:server_error`) for 502 and other 5xx, `Error` (`:parse_error`) when the body isn't JSON or `transactions` isn't an Array, and `Error` (`:network_error`) after retries.
  - `DebugLogEntry.capture` with `provider_key: "santander_mx"` for unexpected statuses and parse failures, using metadata `{ operation: "GET transactions", status: }`. No URL, token or body PII.

Stub HTTP with `Provider::SantanderMx.stub(:get, ->(url, query:, headers:) { FakeResponse.new(...) })`, as in `test/models/provider/fio_test.rb`.

- [ ] **Step 1: Write failing tests**
  - `requests /transactions with since and the bearer token`: the URL is `"http://parser.test/transactions"`, `query == { since: "2026-11-01" }`, `headers["Authorization"] == "Bearer tok"`, and the result's `transactions.first["id"]` matches the body.
  - `joins the path onto a base_url with a trailing slash or a path prefix`: `"http://parser.test/"` gives `"http://parser.test/transactions"`; `"https://h/santander"` gives `"https://h/santander/transactions"`. (Review Focus 3)
  - `maps 401 to AuthenticationError`.
  - `maps 503 to ReauthorizationRequiredError carrying the service message`.
  - `maps 400 to Error with failure_code :bad_request`.
  - `maps 502 to Error with failure_code :server_error`.
  - `raises parse_error when transactions is not an array`.
  - `retries a network error then raises network_error`: stub `sleep`, raise `Errno::ECONNREFUSED` four times, and assert four calls.
  - `never includes the token in an error message`: the 401 error's `message` doesn't include `"tok"`.

- [ ] **Step 2: Run; expect FAIL.** `bin/rails test test/models/provider/santander_mx_test.rb`

- [ ] **Step 3: Implement**, following `Provider::Fio`'s structure (`with_retries`, `handle_response`, `parse_response_body`, `capture_request_error`). Build the URL as `"#{base_url.chomp('/')}/transactions"` and pass `since` as `query: { since: since.iso8601 }`.

- [ ] **Step 4: Run; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Add Santander MX parser service client"`

---

### Task 4: Adapter and provider registrations

**Files:**
- Create: `app/models/provider/santander_mx_adapter.rb`
- Modify: `app/models/provider/metadata.rb` (after the `fio:` line)
- Modify: `app/models/provider_connection_status.rb` (after the `fio` entry)
- Modify: `app/views/accounts/new/_method_selector.html.erb:29` (add `next if config[:new_account_path].blank?` before the `link_path` line; the selector currently calls `config[:new_account_path].call(...)` for every config, so the nil path below would crash the New Account page for Credit Card and Depository)
- Modify: `config/locales/views/santander_mx_items/en.yml` (`providers.santander_mx.name` "Santander México" and `providers.santander_mx.description`, used by the adapter)
- Modify: `app/models/data_enrichment.rb` (`santander_mx: "santander_mx"` in the sorted `source` enum). Required because `import_transaction` calls `enrich_attribute(:name, name, source:)`. `ProviderMerchant` is untouched because no merchants are created.
- Test: `test/models/provider/santander_mx_adapter_test.rb`

**Interfaces:**
- Consumes: `SantanderMxItem`, `SantanderMxAccount` (Task 2). `Provider::SantanderMx` (Task 3).
- Produces:
  - `Provider::SantanderMxAdapter < Provider::Base`, with `Provider::Factory.register("SantanderMxAccount", self)` and `include Provider::Syncable` as Fio does.
  - `self.supported_account_types -> %w[CreditCard Depository]`.
  - `self.connection_configs(family:) -> Array<Hash>`: one config per active, credentialed item, with `key: "santander_mx_#{item.id}"`, `name`, `description: t("providers.santander_mx.description")`, `can_connect: true`, `new_account_path: nil`, and `existing_account_path: ->(account_id) { select_existing_account_santander_mx_items_path(santander_mx_item_id: item.id, account_id:) }`.
  - `self.connection_item_class -> SantanderMxItem`.
  - `#provider_name -> "santander_mx"`, `#sync_path -> sync_santander_mx_item_path(item)`, `#item -> SantanderMxItem`, `#reports_balance? -> false`.
  - Metadata: `santander_mx: { region: "MX", kinds: %w[Bank], maturity: :alpha, logo_text: "SA", logo_color: "#ec0000", domain: "santander.com.mx", name: "Santander México" }`.
  - Connection status: `{ key: "santander_mx", type: "SantanderMxItem", association: :santander_mx_items, accounts: :santander_mx_accounts }`.

The route helpers come in Task 8. Until then, the adapter tests don't call `existing_account_path`.

- [ ] **Step 1: Write failing tests**
  - `is registered for SantanderMxAccount`: `Provider::Factory.create_adapter(santander_mx_accounts(:gold))` is a `Provider::SantanderMxAdapter`.
  - `supports credit cards and depository accounts`.
  - `does not report balances`.
  - `offers no new-account path`: each config's `new_account_path` is nil.
  - `a Santander-linked account has ledger-driven balances`: link a CreditCard account to `santander_mx_accounts(:gold)` and assert `refute account.balance_from_provider?`.
  - `the new credit card and depository pages render when the family has a Santander connection`: a controller test (in `test/controllers/accounts_controller_test.rb`) that signs in as an admin of the fixture family and GETs the new-account page that renders `_method_selector` for each of the two types (find the routes with `bin/rails routes`) and asserts `:success`.

- [ ] **Step 2: Run; expect FAIL.** `bin/rails test test/models/provider/santander_mx_adapter_test.rb`

- [ ] **Step 3: Implement** the adapter and the four registry lines, modelled on `Provider::FioAdapter`.

- [ ] **Step 4: Run it, then `bin/rails test test/models/provider test/models/provider_connection_status_test.rb`; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Register the Santander MX provider adapter"`

---

### Task 5: Entry and transactions processors

**Files:**
- Create: `app/models/santander_mx_entry/processor.rb`
- Create: `app/models/santander_mx_account/transactions/processor.rb`
- Modify: `config/locales/views/santander_mx_items/en.yml` (create; `en.santander_mx.entry.fallback_name.{purchase,transfer_in,transfer_out}` = "Santander purchase", "Santander incoming transfer", "Santander outgoing transfer")
- Test: `test/models/santander_mx_entry/processor_test.rb`, `test/models/santander_mx_account/transactions/processor_test.rb`

**Interfaces:**
- Consumes: `SantanderMxAccount#current_account`, `#raw_transactions_payload` (a Hash of Gmail id → row) from Task 2.
- Produces:
  - `SantanderMxEntry::Processor.new(row, santander_mx_account:)`. `#process -> Entry | nil` returns nil (after a `DebugLogEntry` with `account_provider`) when there is no linked account, or for a blank `id`, an unparseable `date`/`amount` or an unknown `type`. Otherwise it calls `import_transaction` with exactly the arguments in the spec's processing table.
  - `SIGNS = { "purchase" => 1, "transfer_out" => 1, "transfer_in" => -1 }.freeze`, and amount = `SIGNS.fetch(type) * BigDecimal(row["amount"].to_s).abs`.
  - `SantanderMxAccount::Transactions::Processor.new(santander_mx_account)`. `#process -> { success:, total:, imported:, skipped:, failed:, errors: }`. A nil from the entry processor counts as skipped; an exception counts as failed; `success` is `failed.zero?`. Same shape as `FioAccount::Transactions::Processor`.

Build rows in the tests as service rows, e.g. `{ "id" => "m1", "account" => "SANTANDER GOLD", "account_last4" => "1234", "date" => "2026-11-03T14:32:05", "amount" => 1250.0, "currency" => "MXN", "type" => "purchase", "description" => "EXAMPLE STORE", "details" => {} }`, against a CreditCard account linked to `santander_mx_accounts(:gold)`.

- [ ] **Step 1: Write failing tests** (entry processor)
  - `books a purchase as an outflow`: entry `amount == 1250`, `source == "santander_mx"`, `external_id == "m1"`, `name == "EXAMPLE STORE"`, `date == Date.new(2026, 11, 3)`.
  - `books transfer_out positive and transfer_in negative`.
  - `uses the absolute amount when the service still sends a signed one`: `-1250.0` with `purchase` gives `1250`.
  - `keeps a late-evening transaction on its own date`: `"2026-11-03T23:50:00"` gives `Date.new(2026, 11, 3)`. (Review Focus 4)
  - `skips an unknown type`, `skips a blank id` and `skips an unparseable amount`: each returns nil and creates no entry.
  - `falls back to a per-type name when description is blank`: `name == "Santander purchase"`.
  - `stores type, last4 and details under extra["santander_mx"]`.
  - `re-importing the same row does not duplicate`: processing twice leaves `account.entries.count` up by 1.
  - `claims a matching hand-entered entry`: an existing manual entry with the same date, amount and currency (no external_id) gets `external_id == "m1"`, and the count is unchanged.

- [ ] **Step 2: Write a failing test** (transactions processor)
  - `counts imported and skipped rows and stays successful`: a payload with one valid row and one unknown-type row gives `imported: 1, skipped: 1, failed: 0, success: true`.

- [ ] **Step 3: Run both; expect FAIL.** `bin/rails test test/models/santander_mx_entry test/models/santander_mx_account`

- [ ] **Step 4: Implement both processors, modelled on `FioEntry::Processor` and `FioAccount::Transactions::Processor`.** Parse `date` with `Date.parse(row["date"].to_s)` and rescue `Date::Error` to nil.

- [ ] **Step 5: Run; expect PASS.**

- [ ] **Step 6: Commit** `git commit -m "Import Santander MX rows into linked accounts"`

---

### Task 6: Importer

**Files:**
- Create: `app/models/santander_mx_item/importer.rb`
- Modify: `config/locales/views/santander_mx_items/en.yml` (`santander_mx_item.errors.unauthorized`, used by the importer)
- Test: `test/models/santander_mx_item/importer_test.rb`

**Interfaces:**
- Consumes: `Provider::SantanderMx#get_transactions` and its errors (Task 3). The models from Task 2.
- Produces:
  - `SantanderMxItem::Importer.new(santander_mx_item, provider:)`. `#import -> { success: true, accounts_seen: Integer, transactions_seen: Integer, unparsed_count: Integer }` or `{ success: false, error: String }`.
  - Constants `LOOKBACK_DAYS = 3` and `INITIAL_HISTORY_DAYS = 90`.
  - `#since -> Date`: `transactions_synced_through - LOOKBACK_DAYS` when the cursor is set, else `sync_start_date || Date.current - INITIAL_HISTORY_DAYS`.

Behaviour, in order:
1. Call `provider.get_transactions(since:)`.
2. Skip and log any row with a blank `account`.
3. Group the rest by `account` and `find_or_create_by!(name:)` each product. Update `last4` and `currency` when present.
4. Remove each row's id from the item's other products' payloads, then merge it into its own payload as `payload[id] = row`.
5. Log `unparsed`, if any.
6. Set `transactions_synced_through: Date.current, status: :good`.

Steps 3–6 run in a single transaction.

On `AuthenticationError` or `ReauthorizationRequiredError`: set `status: :requires_update` and return `success: false` with a translated message (`santander_mx_item.errors.unauthorized`, or the service's message for the reauthorization error). On any other `Provider::SantanderMx::Error`: return `success: false` and leave the status alone. The cursor is unchanged in every failure case.

Stub the provider with `mock` / `stubs(:get_transactions)`, as the Fio importer test does.

- [ ] **Step 1: Write failing tests**
  - `first sync reads from sync_start_date`: `provider.expects(:get_transactions).with(since: Date.new(2026, 10, 1))`.
  - `first sync defaults to 90 days back` (use `travel_to`).
  - `later syncs re-read three days before the cursor`.
  - `advances the cursor and marks the item good on success`.
  - `groups rows into one account per product and merges rows by id`: two GOLD rows and one SANTANDER row give two accounts, and GOLD's payload has 2 keys. Re-importing a changed copy of a row replaces it.
  - `skips a row with a blank account without creating an account`. (Review Focus 1)
  - `moves a row whose id now belongs to another product`. (Review Focus 2)
  - `an empty successful response advances the cursor and keeps payloads`. (Review Focus 5)
  - `logs unparsed messages`: `assert_difference -> { DebugLogEntry.where(provider_key: "santander_mx").count }, 1`, and the result's `unparsed_count == 1`.
  - `401 marks the item requires_update and keeps the cursor`.
  - `503 marks the item requires_update with the service message`.
  - `a server error keeps the status and the cursor`.

- [ ] **Step 2: Run; expect FAIL.** `bin/rails test test/models/santander_mx_item/importer_test.rb`

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Import Santander MX transactions with a lookback cursor"`

---

### Task 7: Item orchestration and syncer

**Files:**
- Modify: `app/models/santander_mx_item.rb`
- Create: `app/models/santander_mx_item/syncer.rb`
- Modify: `config/locales/views/santander_mx_items/en.yml` (`santander_mx_item.sync.status.*`, `santander_mx_item.errors.*`)
- Test: `test/models/santander_mx_item/syncer_test.rb`

**Interfaces:**
- Consumes: `SantanderMxItem::Importer` (Task 6), `SantanderMxAccount::Transactions::Processor` (Task 5).
- Produces:
  - `SantanderMxItem#import_latest_santander_mx_data -> Hash`: the importer result. It returns `{ success: false, error: }` when credentials are missing.
  - `#process_accounts -> Array<Hash>`: processes linked accounts whose Sure account is visible.
  - `#schedule_account_syncs(parent_sync:, window_start_date:, window_end_date:) -> Array<Hash>`.
  - All three follow `FioItem`, with `DebugLogEntry` on each failure.
  - `SantanderMxItem::Syncer`: `perform_sync(sync)` and `perform_post_sync`, with the stage order and error classes of `FioItem::Syncer`, minus its `pending_account_setup` and `ignored` handling. `collect_transaction_stats(..., source: "santander_mx")`, plus `merge_sync_stats(sync, "unparsed_count" => import_result[:unparsed_count])`.

- [ ] **Step 1: Write failing tests** (stub `import_latest_santander_mx_data`, as the Fio syncer test does)
  - `does not process unlinked products`: `SantanderMxAccount::Transactions::Processor.any_instance.expects(:process).never`, with sync stats `unlinked_accounts == 1`.
  - `processes linked products and schedules their account syncs`.
  - `records the unparsed count in sync stats`.
  - `fails the sync when the import fails`: the import returns `{ success: false, error: "x" }` and `perform_sync` raises `SantanderMxItem::Syncer::SyncError`.

- [ ] **Step 2: Run; expect FAIL.** `bin/rails test test/models/santander_mx_item/syncer_test.rb`

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run, then `bin/rails test test/models/santander_mx_item test/models/family/syncer_test.rb`; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Sync Santander MX connections through the item syncer"`

---

### Task 8: Connection controller, settings panel and linking dialog

**Files:**
- Create: `app/controllers/santander_mx_items_controller.rb`
- Modify: `config/routes.rb` (after `resources :fio_items` at ~line 1025)
- Create: `app/views/santander_mx_items/select_existing_account.html.erb` (modelled on `app/views/mercury_items/select_existing_account.html.erb`)
- Create: `app/views/settings/providers/_santander_mx_panel.html.erb` (modelled on `_fio_panel.html.erb`)
- Modify: `app/controllers/settings/providers_controller.rb` (every place `fio` appears: lines ~212, ~245, ~278, ~364, ~395)
- Modify: `app/helpers/settings_helper.rb` (a `when "santander_mx"` beside `when "fio"`)
- Modify: `config/locales/views/santander_mx_items/en.yml` (`santander_mx_items.*`: controller flashes and view strings)
- Modify: `config/locales/views/settings/en.yml` (provider description and `santander_mx_panel.step_1..3`)
- Test: `test/controllers/santander_mx_items_controller_test.rb`

**Interfaces:**
- Consumes: `Family#create_santander_mx_item!` (Task 2), `Provider::SantanderMxAdapter.supported_account_types` (Task 4).
- Produces:
  - Routes: `resources :santander_mx_items, only: %i[create update destroy]`, with collection `get :select_existing_account`, `post :link_existing_account` and member `post :sync`.
  - `create`: params `santander_mx_item[name, base_url, api_token, sync_start_date]`. Blank token → panel alert.
  - `update`: a blank `api_token` keeps the stored one. A new token resets `requires_update` to `good` and calls `sync_later`.
  - `destroy` (`unlink_all!` + `destroy_later`) and `sync`, as in Fio.
  - `select_existing_account`: params `account_id`, `santander_mx_item_id`. Lists `santander_mx_item.santander_mx_accounts.unlinked`.
  - `link_existing_account`: params `account_id`, `santander_mx_item_id`, `santander_mx_account_id`. The guards are copied from `FioItemsController#link_existing_account` (account already linked, product already linked, unsupported type, `RecordNotUnique`). It then calls `sync_later`.
  - The panel root element id is `santander-mx-providers-panel`, and the `Settings::ProvidersController` entry uses `turbo_id: "santander-mx"` (`render_provider_panel` replaces `"#{turbo_id}-providers-panel"`).
  - Panel form fields: `name`, `base_url` (url field), `api_token` (password field, never prefilled), `sync_start_date` (default `Date.current - 90`). The panel instructions explain deploying the parser service, copying its `API_TOKEN` and entering its URL.

- [ ] **Step 1: Write failing tests**
  - `create makes a connection and enqueues a sync`.
  - `create without a token shows an alert`.
  - `update with a blank token keeps the stored token`.
  - `update with a new token clears requires_update`.
  - `sync enqueues a sync`.
  - `select_existing_account lists only unlinked products`.
  - `link_existing_account links the product and syncs`.
  - `link_existing_account refuses an account already linked`.
  - `link_existing_account refuses a product already linked`.
  - `link_existing_account refuses an unsupported account type` (an Investment account).
  - `cannot reach another family's connection` (404).
  - `the providers settings page renders the Santander panel`: `get settings_providers_path` responds with success and includes `santander-mx-providers-panel`.

- [ ] **Step 2: Run; expect FAIL.** `bin/rails test test/controllers/santander_mx_items_controller_test.rb`

- [ ] **Step 3: Implement** the routes, controller, views, panel registration and locales.

- [ ] **Step 4: Run it, then `bin/rails test test/controllers/settings test/models/provider/santander_mx_adapter_test.rb`; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Add Santander MX connection settings and account linking"`

---

### Task 9: Accounts page card

**Files:**
- Create: `app/views/santander_mx_items/_santander_mx_item.html.erb` (modelled on `app/views/fio_items/_fio_item.html.erb`)
- Modify: `app/controllers/accounts_controller.rb` (the three Fio spots: ~36, ~529, ~819)
- Modify: `app/views/accounts/index.html.erb` (`@santander_mx_items.empty?` in the line-13 guard, and a render block after the Fio block at ~181)
- Modify: `config/locales/views/santander_mx_items/en.yml`
- Test: `test/controllers/accounts_controller_test.rb`

**Interfaces:**
- Consumes: `SantanderMxItem#unlinked_accounts_count`, `santander_mx_accounts.unlinked` (Task 2), `sync_santander_mx_item_path` (Task 8).
- Produces: the `_santander_mx_item` partial with locals `(santander_mx_item:, visible_accounts:)`. It shows:
  - `ProviderLogo.new(provider_key: :santander_mx)`, name, syncing/requires_update state and last sync;
  - a Sync button and `sync_schedule_menu_item`, as in `_fio_item`;
  - the linked accounts;
  - one line per unlinked product: `t(".waiting_to_link", name:, last4:)`.

- [ ] **Step 1: Write failing tests**
  - `accounts index shows a Santander connection card with waiting products`: the response includes `"SANTANDER GOLD"` and the waiting-to-link text.
  - `accounts index shows the requires update state`.

- [ ] **Step 2: Run; expect FAIL.** `bin/rails test test/controllers/accounts_controller_test.rb`

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run; expect PASS.**

- [ ] **Step 5: Commit** `git commit -m "Show Santander MX connections on the accounts page"`

---

### Task 10: Full verification

- [ ] **Step 1:** `bin/rails test`. Expect 0 failures and 0 errors.
- [ ] **Step 2:** `bin/rubocop -f github -a` and `bundle exec erb_lint <the santander and touched ERB files> -a` (not the whole tree: autocorrect must not touch unrelated files). Inspect any autocorrections. Expect no remaining offenses.
- [ ] **Step 3:** `npm run lint` and `bin/brakeman --no-pager`. Expect no new warnings.
- [ ] **Step 4:** Fix anything reported. Commit with `git commit -m "Fix lint findings for Santander MX sync"` if there were changes.
- [ ] **Step 5:** Hand back to the human for the manual check. They run the migration, add the connection, run a sync, link the three accounts, then add a hand-entered payment and confirm the balance moves at once.
