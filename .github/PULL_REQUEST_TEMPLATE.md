<!-- Thanks for contributing. Keep changes surgical and within scope. -->

## What and why

<!-- What does this change, and why? Link the issue it addresses (e.g. Closes #12). -->

## How I verified

<!-- The gate — all three must pass. Paste results or confirm. -->

- [ ] `bash -n force-close.sh` — clean
- [ ] `shellcheck -S warning force-close.sh` — clean
- [ ] `bats tests/` — all pass
- [ ] Manual check (if behavior changed): describe what you exercised

## Safety (required if you touched the kill path)

- [ ] No automated test signals anything it didn't spawn itself.
- [ ] Signaling stays subtree-based — no `kill -- -PGID` (process-group) reintroduced.
- [ ] I did not weaken the self-tree / session-leader guards.

## Checklist

- [ ] One logical change; commit subject uses a type prefix (`fix:`, `docs:`, `test:`).
- [ ] Updated `tests/force-close.bats` for any new pure-helper behavior.
- [ ] Updated the README changelog for any user-visible change.
- [ ] The change is surgical — I didn't refactor code it doesn't touch.
