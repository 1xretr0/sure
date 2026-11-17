# Santander MX bank sync — design

## Context

Santander Mexico offers no customer API. Its card and account notification emails are
read and parsed by a separate service, `santander-mx-gmail-parser`
([its design](../../../../santander-mx-gmail-parser/docs/superpowers/specs/2026-11-11-santander-mx-gmail-parser-design.md)),
which exposes `GET /transactions`. This spec adds a native Sure provider, `santander_mx`,
that calls that service and plugs into Sure's existing bank sync: Sync buttons, Sync all,
the nightly job, login auto-sync, per-connection `SyncSchedule`, last-sync and health on
the connection card.

This lives in a personal fork and is not meant for upstream. The parser service is out of
scope except for the one contract change below.

The owner has three Santander products: two credit cards (`SANTANDER LIKEU`,
`SANTANDER GOLD`) and one debit account (`SANTANDER`). They create the three Sure accounts
by hand first and link them afterwards. The feed has no balances and no card payments; the
owner records payments and other balance changes by hand and reconciles against monthly
statements.

## Decisions

- **One connection per family.** It holds the service URL and API token. Enforced in `SantanderMxItemsController#create` (refused while an active, non-scheduled-for-deletion item exists) and by hiding the add form in the providers panel; there is no model validation because existing model tests build several items per family.
- **A product is identified by the feed's `account` name only.** `account_last4` is
  stored for display. A missing last4 or an additional card cannot split a product.
- **The sign comes from `type`, not from `amount`.** See the contract below.
- **Linked, but the balance is ledger-driven.** The provider never writes a balance.
  Santander-linked accounts calculate balances forward from their opening balance, like
  manual accounts, and keep the manual "New balance" / "New transaction" actions.
- **Only the link-existing-account flow.** No "create a Sure account from the provider"
  flow.
- **No throttle.** Each sync makes one request covering a few days; the default triggers
  give about 1–3 calls a day.

## Parser service contract

Sure consumes the service's contract as specified there, with one change made in the
service repo: **`amount` is always positive, and `type` carries the direction.**
`to_generic` stops negating, and its test and mapping table are updated. Sure applies
`abs` regardless, so it is correct before and after that change.

Fields Sure uses from each transaction: `id`, `account`, `account_last4`, `date`,
`amount`, `currency`, `type`, `description`, `details`. It also reads the top-level
`unparsed` list.

## Architecture

The provider key is `santander_mx`, the same as the feed's `source`. The layout follows the
Fio provider (`FioItem`, `FioAccount`, `Provider::Fio`, `Provider::FioAdapter`,
`FioItemsController`).

| Unit | Responsibility |
|---|---|
| `Provider::SantanderMx` | HTTP client for the service. `get_transactions(since:)` sends `GET {base_url}/transactions?since=YYYY-MM-DD` with `Authorization: Bearer <api_token>` and returns the parsed `{transactions, unparsed}`. It retries network errors with backoff and maps statuses to typed errors (`AuthenticationError` for 401, `ReauthorizationRequiredError` for 503, `Error` otherwise). It knows nothing about Sure's models. |
| `SantanderMxItem` | One connection. Includes `Syncable, Provided, Unlinking, Encryptable, DestroyableLater`. `scope :syncable, -> { active }`. `status` is `good` or `requires_update`. |
| `SantanderMxItem::Importer` | Computes the window, calls the client, groups rows by `account`, upserts `SantanderMxAccount`s, merges raw rows and advances the cursor. |
| `SantanderMxItem::Syncer` | Runs one sync: import, collect setup stats, process linked accounts, schedule account syncs with the sync's window, collect transaction and health stats. Same order as `FioItem::Syncer`. |
| `SantanderMxAccount` | One per product. Joins to a Sure `Account` through `AccountProvider`. |
| `SantanderMxAccount::Transactions::Processor` | Replays the account's stored rows through `SantanderMxEntry::Processor`, counting imported, skipped and failed rows. |
| `SantanderMxEntry::Processor` | Maps one row to `Account::ProviderImportAdapter#import_transaction`. |
| `Provider::SantanderMxAdapter` | `Provider::Factory.register("SantanderMxAccount", self)`. Supported types `CreditCard` and `Depository`. Its `connection_configs` provide `existing_account_path` only. `reports_balance?` is `false`. Also defines `provider_name`, `sync_path` and `item`. |
| `SantanderMxItemsController` | `create`, `update`, `destroy`, `sync`, `select_existing_account`, `link_existing_account`. Everything is scoped to `Current.family`. |

### Data

`santander_mx_items`:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `family_id` | uuid, not null, indexed | |
| `name` | string, not null | |
| `base_url` | string, not null | Absolute `http`/`https` URL with a host. |
| `api_token` | text, not null | Encrypted. |
| `sync_start_date` | date | First-sync start. The form defaults it to 90 days ago. |
| `transactions_synced_through` | date | Cursor. Null until the first successful import. |
| `status` | string, not null, default `good`, indexed | |
| `scheduled_for_deletion` | boolean, not null, default false | |
| timestamps | | |

`santander_mx_accounts`:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `santander_mx_item_id` | uuid, not null | Unique together with `name`. |
| `name` | string, not null | The feed's `account`. |
| `last4` | string | The `account_last4` of the response's newest row (by `date`) that has one. Deviation: not "last seen". |
| `currency` | string | The currency of the response's newest row that has one. Deviation: not "last seen". |
| `raw_transactions_payload` | jsonb, nullable, no default (read as `{}`) | Encrypted. Rows keyed by Gmail `id`. |
| timestamps | | |

Both migrations use the current Rails migration version.

### Shared registrations

Following the Fio commit (985b51207):

- `Family`: `include SantanderMxConnectable` (`has_many :santander_mx_items`)
- `Provider::Metadata::REGISTRY`: domain `santander.com.mx`
- `ProviderConnectionStatus`
- `Settings::ProvidersController` and `SettingsHelper`
- `AccountsController` and `accounts/index`
- `Family::FinancialDataReset`
- routes: `resources :santander_mx_items` with member `sync` and collection
  `select_existing_account` / `link_existing_account`
- `config/locales` (English)

## Sync flow

**Triggers.** All the existing triggers, unchanged. Each sync makes one service request.

**Window.**

- First sync (`transactions_synced_through` is null): `since = sync_start_date`, or
  90 days ago when that is blank.
- Later syncs: `since = transactions_synced_through - 3 days` (constant `LOOKBACK_DAYS = 3`).
- `until` is never sent.
- After a successful response, `transactions_synced_through = Date.current`. A failed sync
  leaves it unchanged. Deviation: the date is captured before the request is made (not after
  the response), so a sync that crosses midnight re-reads that day instead of skipping it.

**Import.** For each row, group by `account`. Find or create the `SantanderMxAccount` by
`name`. Set `last4` and `currency` when the row has them. Merge the row into
`raw_transactions_payload` under its `id`, replacing any older copy.

Deviations from the original text, all in the importer:

- `account` must be a String and is trimmed with a Unicode-aware trim (a no-break space
  does not split a product); `id` must be a non-blank String or an Integer. Other rows are
  skipped and logged once.
- The merge runs in a transaction that takes a row lock (`SELECT ... FOR UPDATE`) on the
  item, serialising overlapping syncs.
- A stored `raw_transactions_payload` that is not a Hash is replaced by the merged Hash even
  when its product gets no rows, and the processor treats it as empty.

If `unparsed` is non-empty, write one `DebugLogEntry` (`category: "provider_sync"`,
`level: "warn"`, `provider_key: "santander_mx"`, `family`) whose metadata lists each
message's `id`, `subject` and `received_at`, and add `unparsed_count` to the sync stats.
Unparsed messages do not fail the sync.

**Processing.** Only provider accounts that have an `AccountProvider` are processed. Unlinked
products keep accumulating rows, which are imported once linked, because linking calls
`sync_later` and the processor replays the whole payload.

For each stored row, `SantanderMxEntry::Processor` calls:

| `import_transaction` argument | Value |
|---|---|
| `external_id` | `id` |
| `source` | `"santander_mx"` |
| `amount` | `purchase` → `amount.abs`; `transfer_out` → `amount.abs`; `transfer_in` → `-amount.abs` |
| `date` | `Date.parse(date)` |
| `currency` | `currency`; the linked Sure account's currency when the row has none (deviation) |
| `name` | `description`, or `t("santander_mx.entry.fallback_name.<type>")` when blank |
| `extra` | `{ "santander_mx" => { "type", "last4", "details" } }` |
| `replace_extra_namespaces` | `["santander_mx"]` |

A row with a blank `id`, an unparseable `date` or `amount`, or an unknown `type` is skipped,
counted in `skipped` and logged with `DebugLogEntry` (with `account_provider`). It is not
counted as failed: the payload is replayed on every sync, so a failure would fail every
later sync (the same reasoning as `FioAccount::Transactions::Processor`). Only an
exception while saving counts as failed. A zero-amount row is booked as a 0.00 entry; that is
current behaviour, not a requirement.

The adapter's existing duplicate handling is relied on as is:

- a row already imported matches on (`external_id`, `source`);
- a hand-entered or CSV-imported entry with the same date, amount and currency and no
  `external_id` is claimed rather than duplicated;
- user-modified, locked or excluded entries keep the user's values.

Entries are never deleted: the feed has no notion of a removed transaction.

**Errors.** The cursor never moves on failure.

| Response | Result |
|---|---|
| 401 | Sync fails. Item becomes `requires_update` ("the service rejected the API token"). |
| 503 | Sync fails. Item becomes `requires_update` with the service's re-authorize-Gmail message. |
| 400 | Sync fails. `DebugLogEntry` with the response body. |
| 502, other 5xx, network error after retries | Sync fails. Status unchanged. |
| 2xx with a body that is not `{transactions: [...]}` | Sync fails. `DebugLogEntry`. |
| Success | Item becomes `good`. |

Deviation: for a 400 the code logs only the `error` field of the response body, truncated to 200 characters, rather than the whole body, to avoid logging unvetted content.

## Ledger-driven balances

**Capability.** Provider adapters get `reports_balance?`, defaulting to `true` in
`Provider::Base` beside `can_delete_holdings?`. `Provider::SantanderMxAdapter` returns
`false`.

**Predicate.** `Account#balance_from_provider?` is `linked? && providers.all?(&:reports_balance?)`.

These balance gates switch from `linked?` to `balance_from_provider?`:

| Location | Effect for Santander-linked accounts |
|---|---|
| `Account::Syncer#materialize_balances` and its log line | Forward strategy |
| `Account::CurrentBalanceManager#set_current_balance` | Manual path (reconciliation or opening-balance adjustment); no `current_anchor` |
| `app/views/accounts/_form.html.erb` balance field | Shown |
| `app/views/accounts/show/_activity.html.erb` "New" menu | Shown |
| `app/components/UI/account/activity_feed.html.erb` "New balance" item | Shown |
| `Assistant::Function::SetOpeningBalance` | Allowed |

Unchanged `linked?` gates: account deletion, `select_provider`, account sync, read-only
fields on provider-imported entries (`Entry#linked?`), holdings strategy.

The balance and opening date given when the account was created are its opening anchor.
Imported rows and hand-recorded entries move it forward. A statement balance added with
"New balance" reconciles drift. Unlinking leaves an ordinary manual account.

## UI

All of it uses existing partials and `DS::*` components, the `icon` helper and `t()`.

- **`settings/providers/_santander_mx_panel`.** The setup form has `name`, `base_url`,
  `api_token` (a password field; blank on edit keeps the stored token) and `sync_start_date`.
  Connection rows reuse `_connection_row`, `_status_pill`, `_sync_button` and
  `_health_strip`, and render `ProviderLogo.new(provider_key: :santander_mx)`.
- **`santander_mx_items/_santander_mx_item`** on the Accounts page, modelled on `_fio_item`:
  - last sync, status, Sync button and `sync_schedule_menu_item`;
  - the `requires_update` message when that applies;
  - the products not yet linked, by name and last4.
- **`santander_mx_items/select_existing_account`**: a radio list of the unlinked products,
  modelled on Mercury's.
- **Security.** The token is sent only in the `Authorization` header. It never appears in
  exception messages, logs or `DebugLogEntry` metadata. `base_url` is validated on save and
  may be plain `http`, because the service can sit on a private Docker network.

## Testing

Minitest, with fixtures `santander_mx_items.yml` and `santander_mx_accounts.yml`. HTTP is
stubbed as in `test/models/provider/fio_test.rb`.

| Test | Covers |
|---|---|
| `Provider::SantanderMx` | Path, `since` query and bearer header. Mapping of 401, 503, 400 and 502. Retry on a network error. Malformed body. |
| `SantanderMxItem::Importer` | First window from `sync_start_date`, and from 90 days ago when it is blank. Later windows start at the cursor minus 3 days. The cursor is unchanged on failure. Rows are grouped by `account` and merged by `id`. `unparsed` produces a `DebugLogEntry`. |
| `SantanderMxEntry::Processor` | The sign for each type, including signed input. An unknown type is skipped, not failed. The name fallback. The `extra` namespace. A re-import does not duplicate. A hand entry with the same date and amount is claimed. |
| `SantanderMxItem::Syncer` | Unlinked products are not processed. `good` / `requires_update` transitions. |
| `Account` / `Account::Syncer` / `Account::CurrentBalanceManager` | `balance_from_provider?` is false for Santander-linked, true for Fio-linked and false for manual accounts. Forward strategy for Santander-linked, reverse still used for Fio-linked. The manual path in `set_current_balance` for Santander-linked. |
| `AccountsController` | The account page shows "New balance" for a Santander-linked account. |
| `SantanderMxItemsController` | Create, and update keeping a blank token. Sync. `select_existing_account` and `link_existing_account`: family scoping, refusal of an already-linked account or product, refusal of an unsupported account type. |

Before merging: `bin/rails test`, Ruby and ERB lint, Biome and Brakeman.

## Out of scope

- The "create a Sure account from the provider" flow (`select_accounts`, `setup_accounts`).
- Merchants, enrichment, pending and FX metadata.
- A minimum-interval throttle.
- Spanish locales.
- System tests.
- Fuzzy duplicate matching beyond the adapter's exact date and amount rule.
- Upstreaming.
