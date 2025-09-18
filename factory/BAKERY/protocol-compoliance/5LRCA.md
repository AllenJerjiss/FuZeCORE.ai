# 5-Level Root Cause Analysis Protocol for Code Hygiene

## Level 1: Immediate Technical Cause
- Always verify that all required imports and dependencies are present before building.
- Never remove an import or code segment without confirming it is truly unused.

## Level 2: Direct Human Error
- After any code cleanup, cross-check all function signatures and usages for required types and imports.
- Run a build/test after every change to catch missing dependencies immediately.

## Level 3: Process/Methodology Flaw
- Do not rely solely on compiler warnings for code cleanup; use static analysis tools to validate unused code.
- Maintain a checklist for code cleanup: dependency check, build/test, peer review.

## Level 4: Systemic/Project Management Issue
- Regularly refactor and document code to minimize legacy and orphaned imports.
- Enforce code review and automated CI pipeline for every change.
- Clearly document critical imports and their usage in code comments.

## Level 5: Organizational/Behavioral Root Cause
- Foster a culture of disciplined, test-driven development and thorough validation.
- Require post-change verification and peer review for all code changes.
- AI assistants and developers must follow a protocol of dependency validation, build/test after every change, and never skip verification steps.

## Action Items
- Implement automated dependency and unused code checks in CI.
- Enforce build/test after every code change.
- Require code review for all changes, especially cleanup/refactor.
- Document critical imports and dependencies.
- Train all contributors (human and AI) in disciplined engineering practices.
- Maintain and update this protocol as new issues are discovered.
