# Verification Plan

1. **Existing tests pass** — `swift test --package-path apps/swift` (340 tests)
2. **Manifest decoding** — manifests without `decisions` field still decode (backward compat)
3. **Manifest with decisions** — test that `decisions.approve.label` and `decisions.request_changes.description` are read correctly
4. **Prompt content** — existing prompt tests verify manifest schema instructions include `decisions`
5. **Visual** — restart app, re-fire test delegation with decisions in manifest, verify labels appear
