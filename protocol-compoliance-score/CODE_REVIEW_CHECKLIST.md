# Code Review & Cleanup Checklist

Use this checklist for every code change before merging or deploying:

## 1. Dependency Hygiene
- [ ] All imports are used and necessary
- [ ] No unused dependencies in Cargo.toml
- [ ] No duplicate or redundant code

## 2. Build & Test
- [ ] `build.sh` passes with no warnings
- [ ] All unit and integration tests pass
- [ ] Static analysis (`cargo clippy`) shows no errors

## 3. Code Quality
- [ ] Functions are documented
- [ ] Critical imports and dependencies are commented
- [ ] Error handling is robust and clear
- [ ] No commented-out or dead code

## 4. Peer Review
- [ ] At least one peer has reviewed the code
- [ ] All review comments addressed

## 5. Protocol Compliance
- [ ] Protocol logic matches latest spec
- [ ] Compliance tests cover all decision branches

---
Add checklist updates and review notes below for traceability.
