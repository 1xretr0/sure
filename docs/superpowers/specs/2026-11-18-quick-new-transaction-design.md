# Quick "new transaction" access (web app)

## Intent
Creating transactions is the most-used daily action, but the only entry point is the
Transactions page. Make it reachable from every page of the responsive web app
(desktop and mobile browsers). The Flutter mobile app is out of scope.

## Goals
- Desktop: a "New" entry in the left nav, right after Budgets/Plan.
- Mobile web: a raised round "+" in the middle of the bottom nav; all existing items stay.
- Both open the existing `new_transaction_path` form in the `modal` turbo frame.
- Mobile web: the Description field no longer opens hotwire_combobox's full-screen
  dialog; it behaves like a normal input with inline suggestions.

## Non-goals / anti-goals
- No change to the form fields or create flow.
- No floating action button; no hiding the Assistant nav item.
- Existing "New transaction" buttons (Transactions page, account activity) stay.
- Other comboboxes (holdings, convert-to-trade) keep their mobile dialog.

## Approaches
1. **Raised "+" centered in the bottom bar** (picked): always visible, covers no content,
   familiar finance-app pattern. Costs some width (6–7 items at 375px).
2. Floating bubble on every page: bar unchanged, but overlaps rows, the selection bar
   and chat input; needs per-page hide rules.
3. Replace a bar item with "+": loses a destination.

Hiding Assistant when inactive was rejected: on mobile the bar item is its only entry point.

## Decisions
- Nav item gets an optional turbo frame so it can open the modal instead of navigating.
- "+" inserted at the middle index of the mobile items; hidden in intro layout.
- Label "New", translated via `layouts.application.nav`.
- Description fix: `mobile_at: "0px"` on that combobox only.

## Left to the builder
Exact markup/classes for the raised button (DS tokens only), test placement.
