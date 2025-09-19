# RCA Lifecycle Management Protocol

This document defines the meta-protocol for managing, tracking, and logging all Root Cause Analysis (RCA) cycles. It is designed to run in conjunction with a specific RCA process (e.g., `RCAL5DRILLDOWN.md`). Its purpose is to provide a persistent, auditable trail of the diagnostic process, especially for complex, recursive, or frequently failing systems.

---

## 1. Core Components

### 1.1. RCA State File

A single JSON file, `rca_state.json`, located in `/FuZe/VIBE/`, acts as the single source of truth for the status of all RCA cycles.

-   **`current_rca_id`**: (String) The ID of the currently active RCA cycle (e.g., "2.1").
-   **`rca_cycles`**: (Array of Objects) A list of all top-level RCA cycles.
    -   **`id`**: (String) The top-level ID (e.g., "1", "2").
    -   **`status`**: (String) "in-progress", "completed", "aborted".
    -   **`start_timestamp`**: (String) ISO 8601 timestamp.
    -   **`end_timestamp`**: (String) ISO 8601 timestamp (null if in-progress).
    -   **`sub_cycles`**: (Array of Objects) A nested list of sub-cycles, following the same structure.

**Example `rca_state.json`:**
```json
{
  "current_rca_id": "2.1",
  "rca_cycles": [
    {
      "id": "1",
      "status": "completed",
      "start_timestamp": "2025-09-19T05:00:00Z",
      "end_timestamp": "2025-09-19T06:00:00Z",
      "sub_cycles": []
    },
    {
      "id": "2",
      "status": "in-progress",
      "start_timestamp": "2025-09-19T06:15:00Z",
      "end_timestamp": null,
      "sub_cycles": [
        {
          "id": "2.1",
          "status": "in-progress",
          "start_timestamp": "2025-09-19T06:30:00Z",
          "end_timestamp": null,
          "sub_cycles": []
        }
      ]
    }
  ]
}
```

### 1.2. Conversation Log Files

All interactions (user requests, agent responses, tool calls, and results) for an RCA cycle are logged in a corresponding file in `/FuZe/VIBE/logs/`.

-   **Naming Convention:** `rca-log-<ID>.log`. For example, `rca-log-1.log`, `rca-log-1.1.log`.

---

## 2. Workflow and Procedures

### 2.1. Initializing a New Top-Level RCA

This occurs when a new, distinct problem is presented.

1.  **Update State File:**
    -   Increment the top-level RCA number (e.g., if the last was "2", the new one is "3").
    -   Add a new object to the `rca_cycles` array with the new ID, status "in-progress", and the current timestamp.
    -   Set `current_rca_id` to this new ID (e.g., "3").
2.  **Initialize Log File:**
    -   Create a new log file named `rca-log-<ID>.log` (e.g., `rca-log-3.log`).
    -   Write an initial entry: `[<Timestamp>] Initializing RCA Cycle <ID>`.

### 2.2. Starting a New Sub-Cycle

This occurs when a validation step within an active RCA fails, requiring a recursive loop back to the analysis phase.

1.  **Update State File:**
    -   Identify the current active cycle from `current_rca_id` (e.g., "2.1").
    -   Generate the new sub-cycle ID by appending a new sub-level (e.g., if current is "2", new is "2.1"; if current is "2.1", new is "2.1.1").
    -   Find the parent cycle in the `rca_cycles` tree and add a new object to its `sub_cycles` array.
    -   Set `current_rca_id` to this new sub-cycle ID (e.g., "2.1.1").
2.  **Initialize Sub-Log File:**
    -   Create a new log file `rca-log-<ID>.log` (e.g., `rca-log-2.1.1.log`).
    -   Write an initial entry: `[<Timestamp>] Starting Sub-Cycle <ID> from parent <Parent_ID>`.

### 2.3. Completing a Sub-Cycle

This occurs when a sub-cycle's fix is validated successfully.

1.  **Finalize Sub-Log:**
    -   Append the entire content of the sub-cycle's log file (e.g., `rca-log-2.1.1.log`) to its parent's log file (e.g., `rca-log-2.1.log`).
    -   Add a concluding entry to the parent log: `[<Timestamp>] Completed Sub-Cycle <ID>. Returning to parent cycle.`.
    -   Delete the sub-cycle log file.
2.  **Update State File:**
    -   Find the completed sub-cycle in the `rca_cycles` tree.
    -   Set its `status` to "completed" and record the `end_timestamp`.
    -   Update `current_rca_id` to the parent's ID.

### 2.4. Completing a Top-Level RCA

This occurs when the initial problem is fully resolved and validated.

1.  **Finalize Log:**
    -   Add a final entry to the top-level log file: `[<Timestamp>] RCA Cycle <ID> Completed Successfully.`.
2.  **Update State File:**
    -   Find the top-level cycle in the `rca_cycles` array.
    -   Set its `status` to "completed" and record the `end_timestamp`.
    -   Set `current_rca_id` to `null`.
