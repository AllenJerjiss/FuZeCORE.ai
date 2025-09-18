# IMPROVE_CODE_COVERAGE Protocol

## Purpose
This protocol guides an interactive approach for maximizing code coverage in Rust projects. It is designed to:
- Analyze current coverage reports
- Identify untested code paths and error branches
- Suggest and implement improvements in both code and test suites
- Validate increased coverage after changes

## Steps
1. **Analyze Coverage**: Review the latest coverage report and list all uncovered lines and branches.
2. **Identify Opportunities**: For each uncovered region, determine if it is due to missing tests, unreachable code, or error handling.
3. **Suggest Improvements**: Propose specific changes to code or tests to cover these regions. Prioritize decision/branch coverage.
4. **Implement Changes**: Add or refactor tests and code to cover the identified gaps. Use property-based, edge case, and integration tests as needed.
5. **Validate**: Re-run coverage tools and confirm that coverage has increased. Report new uncovered regions if any remain.
6. **Iterate**: Repeat steps 1-5 until coverage goals are met or all practical paths are covered.

## Interactive Method
- Prompt the user for permission before making changes.
- Present a summary of uncovered regions and proposed improvements.
- Allow the user to select which improvements to apply.
- After each iteration, show updated coverage metrics and next steps.

## Example Prompts
- "Would you like to add a test for the error branch in function X?"
- "The following lines are not covered: ... Would you like to generate property-based tests for these?"
- "Coverage increased to 85%. Would you like to continue improving?"

## Enforcement
- The protocol must be followed whenever IMPROVE_CODE_COVERAGE is invoked.
- All changes must be validated by running the coverage tool and reporting results.
- The process is iterative and user-driven.

---
Use this protocol to maximize code coverage and maintain high reliability in your Rust codebase.
