# Monetization And Team Plans

PasteBuddy now has a local entitlement model for personal and team packaging.
The model is stored with the local snapshot. When encrypted local storage is
enabled, entitlement metadata is covered by the same AES-GCM envelope as the
rest of the clipboard configuration.

## Implemented Locally

- Free trial lifecycle: start date, end date, cancel state, and access
  evaluation.
- Personal plans: monthly, annual, lifetime, and family entitlement concepts.
- Restore purchases state: not started, in progress, restored, and failed.
- Cross-device entitlement flag for the same account.
- StoreKit product configuration for monthly, annual, lifetime, and family
  product IDs.
- StoreKit 2 adapter for product lookup, purchase, transaction verification,
  restore/sync, and verified entitlement mapping.
- StoreKit transaction update observer for renewals, refunds, revocations, and
  family-sharing entitlement changes.
- Personal entitlement overview for Settings and tests. It turns raw
  entitlement state into user-facing trial reminders, trial end behavior,
  cross-device unlock copy, restore guidance for reinstall/device-change cases,
  and purchase option summaries for monthly, annual, lifetime, and family.
- Team plan metadata: team name, admin email, total seats, assigned seats,
  per-seat price, currency, single invoice, managed distribution, and monthly
  invoice calculation.
- Team plan overview: purchase positioning distinct from personal plans,
  admin-visible seat/license state, billing/distribution summaries, and shared
  pinboard value propositions around ideas, links, files, images, snippets,
  and staying in sync.
- Settings UI for plan status, trial actions, trial end outcome, personal plan
  options, same-account Mac/iPhone/iPad unlock behavior, restore state, restore
  retry guidance, encrypted billing-safety copy, team seat metadata, team
  onboarding copy, and admin-visible team plan summaries.

## Security Boundary

PasteBuddy does not store payment card data, App Store receipts, billing
provider tokens, App Store signed transaction payloads, or invoice credentials.
Only the verified entitlement state needed by the app is stored, and it is
encrypted at rest when encrypted local storage is enabled.

The entitlement overview intentionally does not persist or display payment card
data, App Store receipts, signed transaction payloads, billing tokens, or
invoice credentials. Restore and purchase flows fail closed until StoreKit
returns a verified active entitlement.

## External Configuration Still Required

- App Store Connect products for monthly, annual, lifetime, and family plans.
- Signed App Store/TestFlight build wiring with the production product IDs and
  purchase/restore UI.
- App lifecycle wiring that starts `StoreTransactionUpdateObserver` at launch and
  applies updates through `PasteBuddyStore.applyStoreEntitlementUpdate`.
- Server-side receipt validation or App Store Server API handling if the product
  needs account-level entitlement reconciliation across Mac, iPhone, and iPad.
- Team billing backend for seat assignment, managed distribution, single
  invoice issuance, tax/VAT handling, and admin identity.
- Policies that map specific paid tiers to feature gates.

## Integration Point

Use `AppleStoreKitEntitlementProvider` with `PasteBuddyStore.purchasePersonalPlan`
and `PasteBuddyStore.restorePurchases` in the signed app target. Start
`StoreTransactionUpdateObserver` with the same provider at app launch and apply
each update through `PasteBuddyStore.applyStoreEntitlementUpdate`. Tests use
fakes so the app can verify entitlement behavior without hitting the App Store.
