# PasteBuddy AI Gateway

Stateless inference gateway for the local semantic clipboard index. It verifies App Store signed app/entitlement transactions, issues a ten-minute feature token, forwards bounded requests to an OpenAI-compatible multimodal/embedding provider, and never stores clipboard content or generated index documents.

Runtime secrets (`GATEWAY_JWT_SECRET`, `MODEL_API_KEY`) must be supplied from Google Secret Manager project `general-secrets-store`; do not commit them. Apple root certificates are mounted read-only and listed in `APPLE_ROOT_CA_PATHS`.

Only verified, unexpired `com.pastebuddy.ai.cloud.monthly` and `com.pastebuddy.ai.cloud.annual` transactions receive a token. Their App Store introductory offers naturally use the same verified subscription transactions; the gateway does not implement an installation-date or locally simulated trial. BYOK Annual never authorizes this gateway.

Deploy the container behind `ai.nebula-spaces.com` on OCI. Configure the upstream model account for zero data retention: `Cache-Control: no-store` prevents intermediary caching but cannot override a model provider's retention policy. The gateway has no database, object store, request-body logging, or background persistence.
