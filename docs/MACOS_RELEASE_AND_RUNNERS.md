# Local CI runners and macOS release

## Trust model

GitHub Actions is the control plane; the local Apple Silicon Mac is the build
plane. A self-hosted runner can execute repository code with the permissions of
its macOS account, so pull-request events never automatically run on this
personal machine.

Ordinary CI requires the repository owner to approve one exact commit SHA:

```bash
script/dispatch_local_ci.sh [commit-or-HEAD]
```

The workflow creates a check named `CI / verify` on that exact SHA, runs
`script/ci.sh`, and completes the same check. A changed PR head needs a new
approval. The ordinary CI job has no release credentials and only
`contents: read` plus `checks: write`.

## Runner accounts and labels

Use two separate standard macOS accounts and work directories. Do not run either
runner as an administrator or from the daily developer account.

| Runner | Lifecycle | Custom labels | Credentials |
| --- | --- | --- | --- |
| Ordinary CI | Persistent service | `pastebuddy-ci`, `xcode-27` | None |
| Release | Offline by default; start only for an approved release | `pastebuddy-release`, `xcode-27` | Temporary Keychain and OIDC-restored files only |

For each account:

1. Open GitHub repository **Settings → Actions → Runners → New self-hosted
   runner** and select macOS/ARM64.
2. Follow GitHub's generated download and checksum commands from that page; do
   not copy a stale runner URL from this repository.
3. Configure with the repository URL, a unique runner name, and the custom
   labels from the table. Keep default `self-hosted`, `macOS`, and `ARM64`.
4. Ensure Xcode 27, `gh`, `gcloud`, Swift, Ruby, and Python 3 are available to
   that account. Accept the Xcode license before starting the runner.
5. Install ordinary CI as a service. Start release with `run.sh` only when a
   protected release is waiting, then stop it afterward.

Never give ordinary CI access to the developer's Keychain,
`~/Library/Application Support/PasteBuddy*`, or `/Applications/PasteBuddy
Dev.app`. The canonical CI command only uses a fresh temporary directory and
does not install or launch the app.

## GitHub repository controls

After the first real `CI / verify` check exists, protect `main` with:

- pull requests required;
- branch must be up to date;
- `CI / verify` required;
- conversation resolution required;
- force pushes and branch deletion disabled.

Create these protected environments:

- `testflight`: deployments only from `main`;
- `macos-production`: deployments only from tags matching `v*`.

The current private-repository plan supports deployment source policies but
rejects required reviewers and wait timers. The live repository therefore uses
the source restrictions above plus owner-only dispatch and confirmation inputs.
Treat environment reviewer approval as pending a GitHub plan upgrade; do not
describe it as active before the API confirms it.

This is currently a single-maintainer repository, so a mandatory second reviewer
would deadlock releases. Keep explicit owner dispatch and environment gates now;
add a second trusted reviewer and prevent self-review when another maintainer is
available.

## Developer ID secret inventory

Long-lived credentials belong only in Google Secret Manager project
`general-secrets-store`. The macOS workflow expects:

- `pastebuddy-developer-id-application-p12`;
- `pastebuddy-developer-id-p12-password`;
- `pastebuddy-developer-id-provisioning-profile`;
- repository Actions variable `ASC_API_KEY_SECRET`, pointing to the existing
  notarization key in `general-secrets-store`.

At implementation time, only the ASC key existed. Until the three Developer ID
assets are provisioned, the macOS workflow is intentionally not executable and
must fail before signing. Create/export those assets through Apple Developer and
a trusted local Keychain; never print values or store them in the repository.

The Developer ID profile must authorize `com.alexjiang.PasteBuddy`, CloudKit
container `iCloud.com.alexjiang.PasteBuddy`, the shared Keychain group,
production CloudKit environment, and Team `72UN4PF4BL`.

## Publishing a macOS release

1. Merge a fully verified commit to protected `main`.
2. Create and push a signed or annotated `v<semver>` tag pointing to that main
   commit.
3. Start the `pastebuddy-release` runner.
4. Dispatch **Release notarized macOS app**, provide the tag, and type `RELEASE`.
5. Pass the `macos-production` environment gate.
6. Verify the GitHub Release contains the notarized ZIP, `.sha256`, provenance
   JSON, and notarization log.

The workflow creates a temporary Keychain, imports Developer ID, builds/signs
nested code from the inside out, notarizes, staples, validates with Gatekeeper,
publishes the Release, and deletes the temporary Keychain and credential files
in an `always()` cleanup step.

## Rotation and rollback

- Rotate by adding a new GSM secret version, running a real notarization release,
  and only then revoking the old Apple certificate/profile.
- On runner compromise, stop and remove it from **Settings → Actions → Runners**,
  revoke registration, disable its GCP workload identity binding, and rotate all
  release credentials it could access.
- A failed notarization must not create a GitHub Release. Do not distribute its
  ZIP.
- Removing a runner must never delete PasteBuddy user data, the developer's
  default Keychain, or `/Applications/PasteBuddy Dev.app`.
