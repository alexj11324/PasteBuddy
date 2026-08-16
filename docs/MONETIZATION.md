# Monetization, Auth, and RevenueCat contract

## WP0 status

This is the target contract for Supabase Auth, RevenueCat, and cloud
entitlements. It creates no product, StoreKit configuration, RevenueCat
project, or Edge verifier. Existing local entitlement code is migration input,
not evidence that this contract is live.

The [Cloud Sync and AI Refactor Plan](architecture/PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
controls implementation scope and order. This document controls the commercial
identity, purchase, and entitlement boundary.

## Account and purchase identity

The user must sign in before buying a cloud plan. The Supabase Auth UUID is
the canonical account identity and MUST be supplied as the RevenueCat App User
ID. A purchase must not create an anonymous RevenueCat customer that later
needs to be merged.

The purchase flow is: authenticate, configure RevenueCat with that Supabase
UUID, purchase or restore, fetch canonical RevenueCat CustomerInfo, reconcile
the complete entitlement set to Supabase, then refresh the app capability
snapshot. Product identifiers, prices, and the existing capability mapping
remain App Store configuration and migration inputs.

Supported sign-in providers are Apple, Google, and Email Magic Link. Magic Link
delivery uses Resend SMTP. These are Auth inputs to the same Supabase UUID; they
do not create separate purchase identities.

RevenueCat CustomerInfo is the canonical purchase reconciliation input. Every
purchase, restore, transaction update, reorder, expiry, and revocation
recomputes the complete set. A stale local cache, one expired transaction, an
installation date, a StoreKit product lookup, or a local trial flag cannot
grant cloud access.

A verified signed RevenueCat webhook is only a wakeup. The owner must refetch
complete canonical CustomerInfo; fetch failure is retried and never grants an
entitlement. Client CustomerInfo may refresh the UI quickly, but Supabase
`entitlements` remains the cloud, RLS, and AI authorization truth.

## Capabilities and cloud truth

| Capability | Source | Scope |
| --- | --- | --- |
| local | no account | local capture, history, search, and privacy controls |
| cloud_sync | verified active Cloud plan or verified active BYOK Annual | PowerSync cloud data, quota, and private attachments |
| platform_ai | verified active Cloud plan | OpenRouter platform AI |
| byok_ai | verified active BYOK Annual | the user's OpenRouter Vault credential |

Supabase entitlements are the cloud authorization truth after RevenueCat
reconciliation. The client may cache a display snapshot but may not use that
cache, a local API key, or a RevenueCat SDK callback alone to authorize a
server action. Cloud and AI checks are operation-specific.

Cloud plans grant cloud_sync and platform_ai. BYOK Annual grants cloud_sync
and byok_ai, but not platform_ai. No account grants local only. Quotas are
5,000 cloud clipboard items and 250,000,000 attachment bytes. Free hosting is
Dev/Alpha only; a Pro Supabase plan is required before a formal paid launch.

## Expiry, restore, and account switching

At expiry, revoke, suspension, or failed entitlement refresh, Supabase
entitlements remove cloud_sync, platform_ai, and byok_ai. Local capture,
history, and offline search continue. Existing local data is not deleted just
because a plan expires. An invalid Supabase session is denied.

An account switch requires explicit confirmation. The app stops the old
PowerSync tenant connection, keeps local data separated, and reconfigures
RevenueCat with the new Supabase UUID. It must never merge CustomerInfo,
PowerSync rows, or local tenant state across users.

No-account local-only mode never prompts for a cloud entitlement and remains
complete. Purchase, restore, expiry, switch, offline, and relaunch behavior
must be proven on macOS and iOS in WP3/WP6.

## BYOK boundary

V1 BYOK accepts only an OpenRouter credential. Supabase Vault stores the raw
secret. A server-only opaque Vault credential reference/mapping may connect the
secret to `ai_profiles`; that reference and raw secret never enter the client
or PowerSync stream. `ai_profiles` exposes only fingerprint and status. The
client can test, replace, or destroy the credential but never reads it back.
OpenRouter zero-data-retention policy is required for BYOK just as for platform
AI; see the [official OpenRouter ZDR documentation](https://openrouter.ai/docs/features/zdr).
Deleting a BYOK credential is an authenticated cleanup action that removes the
secret, server mapping, and fingerprint only after verification.

This architecture does not use a custom device-proof exchange, ECDH
enrollment, or a server-recoverable AES-GCM account-key protocol.

RevenueCat webhook, OpenRouter platform, and Resend SMTP secrets are injected
temporarily from `general-secrets-store` at deployment time and never stored
in the repository.

## Verification boundary

WP3 owns the formal Supabase Auth and RevenueCat adapter, canonical
CustomerInfo reconciliation, and capability mapping. WP6 proves the real
purchase/restore/account-switch UI and the no-account/offline path. A source
token or fake CustomerInfo object is intermediate evidence only.

References: [RevenueCat documentation](https://www.revenuecat.com/docs/),
[Supabase Auth](https://supabase.com/docs/guides/auth), and
[StoreKit](https://developer.apple.com/storekit/).
