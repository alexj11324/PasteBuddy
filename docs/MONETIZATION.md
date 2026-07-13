# Monetization And Team Plans

PasteBuddy now has a local entitlement model for personal and team packaging.
The model is stored with the local snapshot. When encrypted local storage is
enabled, entitlement metadata is covered by the same AES-GCM envelope as the
rest of the clipboard configuration.

## Implemented Locally

- One-time local 7-day trial lifecycle: StoreKit current-entitlement check,
  start date, end date, expiration, persistence, and access evaluation. This
  trial does not create a subscription or charge automatically.
- Personal plans: monthly, annual, lifetime, and family entitlement concepts.
- Restore purchases state: not started, in progress, restored, and failed.
- Cross-device entitlement flag for the same account.
- StoreKit product configuration for monthly, annual, lifetime, and family
  product IDs.
- StoreKit 2 adapter for product lookup, purchase, transaction verification,
  current-entitlement refresh, restore/sync, and verified entitlement mapping.
- StoreKit transaction update observer for renewals, refunds, revocations, and
  family-sharing entitlement changes.
- A dedicated native macOS paywall that renders only products returned by
  StoreKit, including App Store display prices and subscription periods. Empty
  or failed product loads remain visibly unavailable and expose no purchase
  action.
- Hard access enforcement after trial/entitlement expiry for clipboard capture,
  Iroh sync, Shelf, Side Panel, Paste Stack, and MCP tools while retaining local
  clipboard data.
- Personal entitlement overview for Settings and tests. It turns raw
  entitlement state into user-facing trial reminders, trial end behavior,
  cross-device unlock copy, restore guidance for reinstall/device-change cases,
  and purchase option summaries for monthly, annual, lifetime, and family.
- Team plan metadata: team name, admin email, total seats, assigned seats,
  per-seat price, currency, single invoice, managed distribution, and monthly
  invoice calculation.
- Team plan overview: purchase positioning distinct from personal plans,
  admin-visible seat/license state, billing/distribution summaries, and shared
  pinboard value propositions around ideas, links, files, screenshots, snippets,
  and staying in sync.
- Settings UI for current plan/dates, navigation to the separate paywall, and
  verified StoreKit restore with scoped error/success feedback. Settings does
  not contain product purchase buttons.

## Security Boundary

PasteBuddy does not store payment card data, App Store receipts, billing
provider tokens, App Store signed transaction payloads, or invoice credentials.
Only the verified entitlement state needed by the app is stored, and it is
encrypted at rest when encrypted local storage is enabled.

The entitlement overview intentionally does not persist or display payment card
data, App Store receipts, signed transaction payloads, billing tokens, or
invoice credentials. Restore and purchase flows fail closed until StoreKit
returns a verified active entitlement.

## Verified App Store Connect State (2026-07-12)

Read-only `asc` queries against app `6780560937` verified:

- App: `PasteBuddy Clipboard`, bundle ID `com.alexjiang.PasteBuddy.iOS`.
- Configured App Store platform: iOS only.
- Subscription groups: 0.
- In-app purchases: 0.

Therefore the production purchase path is not yet available. The paywall must
show its explicit unavailable state until App Store Connect returns matching
products. A successful local build or fake StoreKit provider test is not
evidence that production purchasing works.

## External Configuration Still Required

- Decide and configure the native macOS App Store/universal-purchase identity;
  the current production macOS bundle identity is not represented by the
  iOS-only App Store record above.
- Configure real App Store Connect products after the platform identity is
  correct. The approved United States base prices are US$1.99 monthly and
  US$10.99 annually; localized storefront prices must be configured by App
  Store Connect and rendered from StoreKit rather than hardcoded in the app.
  Monthly and annual are recurring subscriptions,
  lifetime is a non-consumable purchase, and the family product type/sharing
  contract must be chosen explicitly. The code requests all four identifiers
  but never invents missing products.
- Verify product loading, purchase, relaunch entitlement refresh, restore,
  renewal, expiration, and revocation with an App Store sandbox/TestFlight
  account for the final signed product identity.
- Server-side receipt validation or App Store Server API handling if the product
  needs account-level entitlement reconciliation across Mac, iPhone, and iPad.
- Team billing backend for seat assignment, managed distribution, single
  invoice issuance, tax/VAT handling, and admin identity.
- Policies that map specific paid tiers to feature gates.

## Integration Point

`PasteBuddyApp` refreshes current StoreKit entitlements before trial eligibility,
starts `StoreTransactionUpdateObserver`, and uses
`AppleStoreKitEntitlementProvider` for product loading, purchase, and restore.
Tests use fakes to prove state transitions, but production acceptance still
requires the matching App Store product identity described above.
