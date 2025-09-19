# The Evidence-Based RCA Protocol

This document is governed by the meta-protocol defined in `RCA_MANAGEMENT.md`. All RCA activities must be logged and tracked according to that protocol.

This document outlines a mandatory, rigorous, and generic process for diagnosing and resolving script and system failures. Its objective is to prevent repeated, superficial fixes by forcing a deep, evidence-based analysis of the system's state and control flow *before* a root cause is declared. This is a template to be followed for each new incident.

---

## **Phase 1: Triage & Reconnaissance**

### **Step 1: Define the Problem**
-   **Symptom:** What is the exact, observable failure? State the error message, exit code, and any other anomalous behavior.
-   **Expectation:** What was the expected outcome?
-   **Impact:** What is the consequence of this failure?

### **Step 2: Gather Initial Evidence**
-   **Logs:** Collate all relevant log output from the failed run.
-   **State:** Document the state of the system. This includes relevant file permissions, running processes (`ps`, `systemctl status`), network listeners (`lsof`, `netstat`), and environment variables.

### **Step 3: Map the Execution Flow & Data Flow**
-   **Objective:** Build a "bird's-eye view" of the entire workflow to understand the context of the failure.
-   **Action (Control Flow):** Starting from the entry-point script, trace and list every sub-script, function, and external command that is called in the execution path leading to the failure. Read the *full contents* of every script in this path to understand its role and logic.
-   **Action (Data Flow):** For each interface between scripts/functions, document the data being passed. Note how `stdout` from one script is used by another, how environment variables are set and consumed, and how arguments are passed and parsed.

## **Phase 2: Analysis & Hypothesis**

### **Step 4: Synthesize the Causal Chain**
-   **Objective:** Explicitly document the end-to-end logic of the workflow as a cause-and-effect narrative.
-   **Action:** Write a step-by-step story of the intended behavior. Example: "1. The `main` script calls `get_endpoints.sh`. 2. `get_endpoints.sh` is designed to output a list of URLs, one per line. 3. The `main` script reads this list into a variable and loops through it, calling `curl` on each URL."
-   **Identify Contradictions:** Based on the narrative and the evidence, explicitly look for potential logical contradictions, race conditions, or fragile assumptions between steps. *Pay close attention to mismatches in data format between what a script produces and what the consuming script expects.*

### **Step 5: Interactive Analysis & Hypothesis Refinement**

-   **Objective:** If the causal chain is unclear or the evidence is ambiguous, actively seek external input or add instrumentation to clarify the failure.
-   **Action (Seek External Input):** Present the evidence and the synthesized causal chain to a peer or user. Ask them to challenge the assumptions or point out potential blind spots. A fresh perspective is invaluable for breaking through complex problems.
-   **Action (Instrument for Clarity):** If a failure is silent, slow, or generic (e.g., a timeout, zero-value result, "not found"), modify the code to make it fail faster and more explicitly. Add temporary, targeted logging or introduce strict assertions (e.g., "exit if function X returns 0 more than 3 times"). This transforms an ambiguous symptom into a precise, actionable error message.
-   **Action (Iterative Hypothesis):** The first hypothesis is often incomplete. Treat the RCA process as a loop. If a fix attempt fails but *changes the symptom*, this is not a failure but *new evidence*. Integrate this new evidence and refine the hypothesis.

### **Step 6: Formulate a Root Cause Hypothesis**
-   **Hypothesis:** Formulate a single, testable hypothesis that explains how a specific contradiction or flaw leads to the observed symptom.
-   **Desk Check (Simulation):** Manually trace the script's execution path with the evidence gathered. For each step, document the values of relevant variables and positional parameters (`$1`, `$2`, etc.), paying special attention to values passed *across script boundaries*. Pinpoint the *exact line* where the script's actual state diverged from the expected state. This is the **Implementation Flaw**.
-   **Root Cause Declaration:**
    -   **Implementation Flaw:** The specific line or block of code that is incorrect.
    -   **Reasoning Flaw:** The flawed assumption or knowledge gap that led to the incorrect code being written in the first place (e.g., "Assuming `grep` output will always be a single line"). This is the true **Root Cause**.

### **Step 7: Challenge the Hypothesis**
-   **The Counter-Factual:** Ask, "What is the most likely *alternative* explanation?" Use the evidence from the Desk Check to prove why that alternative is incorrect. This step is crucial to prevent confirmation bias.

## **Phase 3: Remediation & Validation**

### **Step 8: Devise a Solution**
-   **The Fix:** Propose a single, surgical change to correct the identified Implementation Flaw.
-   **Defensive Programming:** In addition to the direct fix, add input validation or sanity checks at the point of failure to prevent similar issues. The goal is to make the script fail explicitly and immediately if it receives malformed data, rather than proceeding to a silent failure or timeout.
-   **Systemic Search:** Search the entire codebase for other instances of the same flawed logic or code pattern. A fix should address the problem systemically, not just at the point of failure.
-   **Remediation Plan:** The final plan must include the validated surgical fix, any defensive additions, and a list of all other identified locations of the flawed pattern to be corrected.

### **Step 9: Validate the Solution (Pre-Flight Check)**
-   **Validation Desk Check:** Before applying any changes, perform a new desk check. Manually trace the execution path with the proposed fix applied to prove that it resolves the primary failure.
-   **Regression Desk Check:** Mentally run through at least two other valid use cases or invocation patterns to ensure the comprehensive fix does not introduce a new bug.

### **Step 10: Execute and Verify**
-   **Implementation:** Apply the changes as defined in the remediation plan.
-   **Verification Run:** Execute the script or test case that originally produced the failure.
-   **Symptom Analysis:**
    -   **If the symptom is GONE:** The fix is verified. Proceed to the Regression Run.
    -   **If the symptom PERSISTS:** The hypothesis was wrong. Compare the *full output* of the new failed run with the original. If the output is identical, the fix had no effect. If the output has changed (e.g., the script fails at a later stage), this is new evidence. The RCA process must restart from Phase 2 (Analysis & Hypothesis) with this new knowledge.
-   **Regression Run:** Run a broader set of tests to ensure no new bugs were introduced.
-   **New Failure Protocol:** If the `Verification Run` or `Regression Run` produces a **new and unexpected symptom**, the current RCA process must be aborted. A new, separate RCA process must be initiated from Phase 1 for this new symptom. The "Gather Initial Evidence" step of the new RCA must include the context and the failed fix attempt from the previous RCA as part of its evidence. Do not attempt to fix the new failure outside of this formal process.