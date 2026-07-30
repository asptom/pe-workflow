# Camunda Enrollment Framework: 855I, 855A, and 855B

This document outlines the architectural plan for creating a scalable, modular Camunda 8 process framework to handle multiple CMS provider enrollment types.

## 1. Architectural Overview: The Orchestrator Pattern
To maximize reuse and maintainability, the framework follows a **Modular Orchestrator Pattern**.

*   **The Orchestrator**: A top-level "Master" process that manages the application lifecycle. It identifies the enrollment type, manages the application lifecycle state (e.g., `status: IN_REVIEW`, `status: SITE_VISIT_PENDING`), and invokes the correct Delegate.
*   **Enrollment Delegates**: Specialized sub-processes (855I, 855A, 855B) that contain logic unique to each enrollment type.
*   **Shared Services**: Reusable components (Intake, OIG Screening, SA Referral) used across all Delegates.
*   **Camunda Forms**: A UI layer for every human interaction, providing a consistent experience for reviewers.
*   **DMN Decisions**: A data-driven approach for handling varying documentation and eligibility rules.

### Design Decisions

#### A. Data Contracts
All process variables use **nested objects** (`provider`, `validation`, `verification`) across all forms and BPMN scripts to prevent naming collisions and ensure scalability across enrollment types.

#### B. Error Handling & Compensation
All External Service and Script tasks include **BPMN Error Events** for system failures (e.g., OIG/SAM API timeouts). A centralized `Error_Handling.bpmn` sub-process manages retries and alerts. **Compensation Events** are used to roll back state if a DMN decision fails.

#### C. Orchestrator DMN Integration
The Orchestrator calls the final eligibility DMN **after** the Delegate completes its specific validation but **before** the CMS decision. This allows the Delegate to update data (e.g., `providerRiskScore`, `enrollmentType`) based on its internal checks, ensuring the Orchestrator's decision DMN has the most accurate data.

---

## 2. Phase 1: Extraction of Shared Logic
The first step is to isolate the universal lifecycle components.

*   **Action**: Extract the following into a `shared/` folder:
    *   `Shared_Intake.bpmn`: Application logging and tracking.
    *   `Shared_OIG_Screening.bpmn`: OIG/SAM exclusion and NPI/TIN verification.
    *   `Shared_SA_Referral.bpmn`: The 45-day referral loop and escalation logic.
*   **Data Contract**: Define a standardized set of process variables (e.g., `provider`, `validation`, `verification`, `referral`) to ensure smooth hand-offs. **Avoid flat variables.**

---

## 3. Phase 2: Camunda Forms & Test Data
Every human interaction in the process will be backed by a Camunda Form.

### Forms to Create:
1.  **`enrollment-start.form`**
    *   **Purpose**: Master intake for all enrollment types.
    *   **Fields**: `enrollmentType` (Dropdown: 855I, 855A, 855B), `npi`, `tin`, `legalName`, `filingDate`.
    *   **Test Data**: `{ "enrollmentType": "855A", "npi": "1234567890", "tin": "98-7654321", "legalName": "Metro Surgical Center", "filingDate": "2026-07-15" }`

2.  **`review-validation.form`**
    *   **Purpose**: For Expert Review of the automated validation results.
    *   **Fields**: `validationSummary`, `comments`, `approvalDecision` (Approve/Deny).
    *   **Test Data**: `{ "validationSummary": "NPI Active, TIN Verified", "comments": "All data matches external databases.", "approvalDecision": "Approve" }`

3.  **`site-visit-report.form`**
    *   **Purpose**: Specifically for 855A/B facility-based enrollments.
    *   **Fields**: `siteVerified` (Boolean), `deficienciesFound`, `correctiveActionPlan`.
    *   **Test Data**: `{ "siteVerified": true, "deficienciesFound": "None", "correctiveActionPlan": "" }`

### Action:
*   Author these as `.form` JSON files.
*   Link them to the BPMN tasks via `<zeebe:formDefinition formId="..." />`.

---

## 4. Phase 3: DMN-Driven Business Logic
Use DMN to handle the "Decision Points" that change between forms.

*   **`Enrollment_Documentation.dmn`**:
    *   **Input**: `enrollmentType`
    *   **Output**: `requiredDocumentList`
    *   **Example**: 855A requires a "Fire Safety Inspection", while 855I does not.
*   **`Eligibility_Rules.dmn`**:
    *   **Input**: `enrollmentType`, `providerRiskScore`
    *   **Output**: `eligibilityStatus`, `siteVisitRequired`
*   **`Processing_Timeline.dmn`**:
    *   **Input**: `submissionMethod`, `siteVisitRequired`, `applicationIncomplete`
    *   **Output**: Processing days for each step and total estimate
    *   **Purpose**: Provide real-time processing updates to the provider via the Orchestrator.

---

## 5. Phase 4: The Orchestrator and Delegates
The core BPMN implementation.

*   **`Enrollment_Orchestrator.bpmn`**:
    *   Starts with the `enrollment-start.form`.
    *   Calls the DMN to determine the required documentation.
    *   Uses a **Call Activity** to invoke the appropriate Delegate (855I, 855A, or 855B).
*   **`Delegate_855I.bpmn`**: Focuses on individual practitioner license and board certification.
*   **`Delegate_855A.bpmn`**: Includes the `site-visit-report.form` and facility-specific physical location checks.
*   **`Delegate_855B.bpmn`**: Focuses on DMEPOS bonding and state-specific equipment licensure.

---

## 6. Phase 5: Validation and Linting
Ensure the framework is production-ready.

*   **Structural Lint**: Run `c8ctl bpmn lint` on all `.bpmn` files.
*   **DMN Lint**: Run `npx dmnlint` on all `.dmn` files.
*   **Variable Check**: Verify that the variables in the `.form` files match the `formId` and the process variables defined in Phase 1.

---

## 7. Implementation Steps
1.  Create the `shared/`, `delegates/`, `forms/`, and `decisions/` directories.
2.  Build the shared logic BPMN files (`Shared_Intake.bpmn`, `Shared_OIG_Screening.bpmn`, `Shared_SA_Referral.bpmn`).
3.  Author the three Camunda Forms with test data (ensuring nested variable structure).
4.  Build the DMN decision tables.
5.  Assemble the `Enrollment_Orchestrator.bpmn` and the three Delegate processes.
6.  Add Error Handling and Compensation events.
7.  Final Lint and Verification.
