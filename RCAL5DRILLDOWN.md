# The Evidence-Based RCA Protocol

This document outlines a mandatory, rigorous process for diagnosing and resolving script failures. Its objective is to prevent repeated, superficial fixes by forcing a deep, evidence-based analysis of the code's state and control flow *before* a root cause is declared.

## The RCA Process

### 1. Failure Triage
*   **Symptom**: State the exact error message, line number, and command that was run.
*   **State Capture**: Collate all relevant log output, exit codes, and other observable state at the time of failure.
*   **Initial Hypothesis**: Formulate a single, testable hypothesis about the direct technical cause of the symptom. (e.g., "Hypothesis: The script failed because variable `$stack` was unbound when the `case` statement was reached.")

### 2. Evidence Gathering & Analysis (The "Desk Check")
This is the most critical phase. I must prove the hypothesis by manually simulating the shell's behavior.

*   **Code Path Identification**: Identify the exact sequence of functions and code blocks that execute to produce the failure.
*   **State Reconstruction**: Create a step-by-step trace of the script's state leading to the error. For each step in the code path, I must document the values of relevant variables and, most importantly, the exact contents of the positional parameters (`$1`, `$2`, `$@`).
*   **Flaw Pinpointing**: Based on the state reconstruction, pinpoint the *exact line* where the script's actual state diverged from the expected state. This is the **Implementation Flaw**.

### 3. Counter-Factual Challenge
Before declaring a root cause, I must challenge my own conclusion.

*   **The Counter-Factual**: Ask "What is the most likely alternative explanation for this failure?" and then use the evidence from the Desk Check to prove why that alternative is incorrect. This prevents confirmation bias.

### 4. Root Cause Declaration
*   **Implementation Flaw**: Restate the specific line or block of code that is incorrect.
*   **Reasoning Flaw**: Why was this incorrect code written? What flawed assumption or knowledge gap in my own reasoning led to this implementation flaw?
*   **Root Cause**: The single, fundamental principle of shell scripting, control flow, or system interaction that I misunderstood, which, if corrected, will prevent this entire class of error from recurring.

### 5. Hypothesis Validation & Systemic Remediation
*   **The Fix**: Propose a single, surgical change to correct the identified Implementation Flaw.
*   **Hypothesis Validation (Desk Check)**: Before proceeding, I must perform a new desk check, manually tracing the execution path with the proposed fix applied. This simulation must prove that the fix resolves the primary failure.
*   **Systemic Pattern Search**: Once the fix is validated via desk check, I must search the entire codebase for other instances of the same flawed logic or code pattern.
*   **Remediation Plan**: The final plan must include the validated surgical fix, a list of all other identified locations of the flawed pattern, and a plan to correct them all simultaneously.
*   **Regression Test Simulation**: The plan must also include a desk check of at least two other valid invocation patterns to ensure the comprehensive fix does not introduce a new bug.

### 6. Execution
*   **Approval**: Await user approval for the fix-plan.
*   **Apply & Validate**: Apply the single change and run the validation command.
*   **Iterate**: If the validation fails, the entire Evidence-Based RCA process begins again from Step 1.
