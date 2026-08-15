# Monetization and App Store Entitlements

PasteBuddy uses verified App Store subscriptions without a separate PasteBuddy account system. Entitlement state is stored in the local snapshot; payment details and signed transaction payloads are not persisted by the app.

## Product catalog

- `com.pastebuddy.ai.byok.annual`: recurring annual subscription; unlocks BYOK only.
- `com.pastebuddy.ai.cloud.monthly`: recurring monthly subscription; unlocks PasteBuddy Cloud and BYOK.
- `com.pastebuddy.ai.cloud.annual`: recurring annual subscription; unlocks PasteBuddy Cloud and BYOK.
- A verified introductory trial on a Cloud product unlocks Cloud and BYOK until its StoreKit transaction expires.

There is no lifetime, one-time, or locally simulated trial product. Personal subscription capabilities fail closed when the verified transaction is revoked, lacks an expiration date, or reaches its expiration date. Local clipboard history, semantic records, embeddings, and API keys are not treated as proof of entitlement.

## Implemented flow

- StoreKit 2 product lookup, purchase, restore/sync, verified transaction mapping, and transaction-update observation.
- Contextual plan/setup sheet from Settings, Shelf, and Side Panel.
- Current-plan state, plan switching, restore, and the system App Store subscription-management link.
- Capability gates separated into BYOK access and Cloud access.
- App Store signed app/entitlement transaction exchange for a short-lived Cloud gateway token.
- No local activation helpers: production and tests apply verified entitlement objects through the StoreKit-facing store methods.

## Security boundary

PasteBuddy does not store payment card data, App Store receipts, signed transaction payloads, billing-provider tokens, or invoice credentials. The Cloud gateway verifies signed transactions for every short-lived token and accepts only the two Cloud product identifiers. BYOK Annual cannot authorize the gateway.

API keys are separate from entitlement state and remain in the device-only Keychain. Losing subscription access does not silently delete local data or credentials; users retain explicit deletion controls, while all AI inference and semantic search remain locked.

## External configuration still required

- Create the three matching auto-renewable subscriptions in App Store Connect and place them in the intended subscription group.
- Configure introductory offers only on Cloud products when the trial must unlock both capabilities.
- Complete localized App Store product names, prices, review metadata, and purchase sandbox verification.
- Deploy the stateless gateway at `ai.nebula-spaces.com`, sourcing runtime secrets from Google Secret Manager project `general-secrets-store`.

The legacy Team metadata remains separate from this personal AI subscription catalog and is not an App Store Cloud-gateway entitlement.
