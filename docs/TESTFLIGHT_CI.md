# TestFlight CI

TestFlight is a manual, protected release workflow. It runs on the local
`pastebuddy-release` self-hosted macOS runner, so it does not consume GitHub-
hosted macOS minutes.

The normal entrypoint is:

```bash
script/push_testflight.sh
```

The wrapper verifies the committed `main` HEAD locally, pushes it, and
dispatches `.github/workflows/testflight.yml` with that exact 40-character SHA
and an explicit `UPLOAD` confirmation. The workflow independently proves that:

- the actor is the repository owner;
- the dispatch ref is `refs/heads/main`;
- `GITHUB_SHA`, checked-out HEAD, the approved input SHA, and `origin/main` are
  identical;
- the job passed the protected `testflight` environment gate;
- runner labels are `self-hosted`, `macOS`, `ARM64`, `pastebuddy-release`, and
  `xcode-27`.

Only after those checks does the job use GitHub OIDC to authenticate to Google
Cloud and restore the App Store Connect `.p8` key from
`general-secrets-store/asc-api-key-664UJQLMB2`. The key, archive, export, and
DerivedData live under `RUNNER_TEMP` and are deleted by an `always()` cleanup.

The upload job has `contents: read` and `id-token: write`. A separate job gets
`contents: write` only after successful upload and writes the corresponding
`ios-build-<number>` tag. Build numbers remain
`max(App Store Connect latest, highest ios-build tag) + 1`.

Required protected-environment secrets are:

- `ASC_KEY_ID` (`664UJQLMB2` at the time this document was updated);
- `ASC_ISSUER_ID`.

The `.p8` value must not be copied into GitHub Secrets, the repository, `.env`,
or a persistent runner directory.

If the release runner is offline, the workflow remains queued. Do not add a
GitHub-hosted macOS fallback. If an upload fails, inspect that run before
dispatching again so a successfully accepted build is not duplicated.
