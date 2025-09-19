# Root Cause Analysis (RCA) Protocol

This document outlines the mandatory process for diagnosing and resolving script failures. The objective is to efficiently identify the fundamental root cause by analyzing the direct causal chain from symptom to implementation error.

## The 3-Layer Causal Chain RCA Process

1.  **Detect Failure**: When any executed script fails, all modification activities will cease immediately.

2.  **Perform 3-Layer RCA**: A root cause analysis will be conducted by drilling down through three distinct layers of causality.

    *   ### Layer 1: The "What" - Symptom Analysis
        *   **Symptom**: State the exact error message, line number, and command that was run.
        *   **Direct Technical Cause**: What does this error mean in the context of the shell/language? (e.g., "An 'unbound variable' error means `set -u` is active and a variable was used before it was assigned a value.")

    *   ### Layer 2: The "How" - Implementation Analysis
        *   **Code Path Trace**: How did the execution flow reach the failing line?
        *   **State Analysis**: What was the state of the relevant variables and positional parameters (`$@`, `$1`, etc.) at the time of failure? This step **must** involve a mental simulation of the code's logic, including argument shifting and variable assignments.
        *   **Implementation Flaw**: Based on the trace and state analysis, what is the specific line or block of code that is incorrect?

    *   ### Layer 3: The "Why" - Reasoning Analysis
        *   **Flawed Assumption**: Why was this incorrect code written? What flawed assumption, knowledge gap, or logical error in my own reasoning led to this implementation flaw?
        *   **Root Cause**: The single, actionable principle that must be corrected in my process to prevent this entire class of error from recurring.

3.  **Present RCA for Review**: The completed 3-Layer RCA will be presented to the user for review.

4.  **Propose Surgical Fix-Plan**: Based *only* on the identified Root Cause and Implementation Flaw. The plan **must** include a simulation of the final code's state and a mental parsing of it against *multiple known invocation patterns* (regression testing) to prove its validity.

5.  **Await Approval**: The proposed change will not be applied until explicit approval is received.

6.  **Apply and Validate**: Once approved, only the single proposed change will be applied. The script will then be executed to validate the fix.

7.  **Iterate on Failure**: If the script fails again, the entire process (starting from Step 1) will be repeated for the new failure.
