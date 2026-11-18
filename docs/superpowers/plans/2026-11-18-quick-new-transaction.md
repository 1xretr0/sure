# Quick "new transaction" access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open the new-transaction modal from the nav on every page (desktop left nav, raised "+" in the mobile-web bottom bar) and stop the Description combobox from going full-screen on mobile web.

**Architecture:** One new nav item hash from `ApplicationHelper`, rendered through the existing `layouts/shared/nav_item` partial, which gains `frame:` (turbo frame target) and `raised:` (mobile styling) locals. The layout inserts it after Budgets/Plan on desktop and at the midpoint of the mobile bar. The combobox fix is a `mobile_at:` option on one `f.combobox` call.

**Tech Stack:** Rails ERB, Turbo frames, hotwire_combobox 0.4.0, Minitest.

**Spec:** `docs/superpowers/specs/2026-11-18-quick-new-transaction-design.md`

## Global Constraints
- Web app only; no Flutter/mobile-app changes.
- DS functional tokens only (`bg-inverse`, `text-inverse`, …); no raw palette classes or hex; `icon` helper only.
- User-facing strings via `t()`; label key `layouts.application.nav.new_transaction` = "New".
- No changes to `sure-design-system.css` / `application.css`.
- Intro layout (`ui_layout: intro`) shows no new-transaction nav entry.

## Review Focus
- Mobile bar with preview features on (Bills present, 6 items + "+") still fits at 375px — manual check in browser devtools.
- "+" must open the modal, not navigate the page — pinned by `data-turbo-frame="modal"` assertion (Task 1).
- `aria-current` must never be set on the "+" (it is an action, not a page) — pinned in Task 1 partial test.
- "+" sits in the middle regardless of item count — pinned by index assertion (Task 1).
- Description suggestions still work inline on mobile (free text + list) — manual check; dialog-off pinned in Task 2.

---

### Task 1: New-transaction nav entry

**Files:**
- Modify: `app/helpers/application_helper.rb` (next to `plan_nav_item`)
- Modify: `app/views/layouts/shared/_nav_item.html.erb`
- Modify: `app/views/layouts/application.html.erb:5-22, 226-231`
- Modify: `config/locales/views/layout/en.yml` (`nav:` block)
- Test: `test/views/layouts/shared/nav_item_view_test.rb`, `test/controllers/pages_controller_test.rb`

**Interfaces:**
- Produces: `new_transaction_nav_item -> Hash` with `name: t("layouts.application.nav.new_transaction"), path: new_transaction_path, icon: "plus", icon_custom: false, active: false, frame: :modal`.
- Partial locals added: `frame: nil` (sets `data-turbo-frame` on the link), `raised: false` (round `bg-inverse` icon container, `text-inverse` icon, lifted with negative top margin; label unchanged).

- [ ] **Step 1: Write failing tests**

`nav_item_view_test.rb`:
```ruby
test "frame targets the link at a turbo frame and omits aria-current" do
  html = render(partial: "layouts/shared/nav_item", locals: {
    name: "New", path: "/transactions/new", icon: "plus", icon_custom: false, active: false, frame: :modal
  })
  assert_includes html, "data-turbo-frame=\"modal\""
  assert_not_includes html, "aria-current"
end

test "raised draws the inverse round icon container" do
  html = render(partial: "layouts/shared/nav_item", locals: {
    name: "New", path: "/transactions/new", icon: "plus", icon_custom: false, active: false, raised: true
  })
  assert_includes html, "bg-inverse"
end
```

`pages_controller_test.rb` (signed-in dashboard user):
```ruby
test "nav offers new transaction in the desktop rail and the middle of the mobile bar" do
  get root_path
  assert_select "nav a[href=?][data-turbo-frame=modal]", new_transaction_path, count: 2
  hrefs = css_select("nav[data-viewport-target=bottomNav] > a").map { _1["href"] }
  assert_equal (hrefs.size - 1) / 2, hrefs.index(new_transaction_path)
end
```
Plus one test signing in `users(:intro_user)` asserting `count: 0` for the same selector.

- [ ] **Step 2: Run, expect FAIL**

Run: `bin/rails test test/views/layouts/shared/nav_item_view_test.rb test/controllers/pages_controller_test.rb`

- [ ] **Step 3: Implement**
- Helper `new_transaction_nav_item` as above.
- Partial: accept `frame: nil, raised: false`; `link_to path, data: { turbo_frame: frame }`; `raised` swaps the icon container classes to `w-11 h-11 -mt-4 rounded-full bg-inverse` and icon color to `"white"` (maps to `text-inverse`).
- Layout (non-intro branch only): insert `new_transaction_nav_item` after `plan_nav_item` for desktop; build the bottom bar list as `mobile_nav_items.reject { desktop_only }`, then `insert(list.size / 2, new_transaction_nav_item.merge(raised: true))`. Desktop item is never in the mobile list and vice versa (no duplicates).
- en.yml: `new_transaction: New` under `nav:` (other locales fall back).

- [ ] **Step 4: Run, expect PASS** (same command)

- [ ] **Step 5: Commit** — `Add new transaction entry to desktop and mobile nav`

### Task 2: Inline Description combobox on mobile web

**Files:**
- Modify: `app/views/transactions/_form.html.erb:29`
- Test: `test/controllers/transactions_controller_test.rb` (near "new form wires the currency select…")

- [ ] **Step 1: Write failing test**
```ruby
test "new form keeps the description combobox inline on small screens" do
  get new_transaction_path
  assert_select "fieldset[data-hw-combobox-small-viewport-max-width-value=?]", "0px"
end
```
- [ ] **Step 2: Run, expect FAIL** — `bin/rails test test/controllers/transactions_controller_test.rb -n /inline/`
- [ ] **Step 3: Implement** — add `mobile_at: "0px"` to the `f.combobox :name` call.
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** — `Keep transaction description combobox inline on mobile`

### Task 3: Verify
- [ ] `bin/rails test` green; `bin/rubocop`, `bundle exec erb_lint` on changed files; `npm run lint` (Biome) unchanged JS.
- [ ] Manual (devtools, 375px and desktop): "+" centered and opens modal; Description typing stays inline with keyboard up.
