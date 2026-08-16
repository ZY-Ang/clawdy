## What changed

<!-- One or two lines. The diff says what; say why. -->

## Why

<!-- If this exists because something broke, say what broke. -->

## Checks

- [ ] `npm run check` passes (no drift)
- [ ] `npm test` passes (security rules still enforce what they claim)
- [ ] If `firestore.rules` changed, a test covers the change
- [ ] If this touches saving or the version guard, it was tried with two browsers open

<!--
Rules deploy on merge, not from this PR — preview channels share the production
database, so a branch's rules would apply to live data.
-->
