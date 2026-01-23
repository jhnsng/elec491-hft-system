# Contributing to HFT FPGA Project

Welcome! This document explains how to contribute safely to this repository and maintain a clean, collaborative workflow.

---

## Branching Strategy

We use **component-based long-lived branches** along with a protected `main` branch:

| Branch      | Purpose |
|------------|---------|
| `main`      | Stable, known-good state. Only merge when changes are verified. |
| `top`       | Top-level FPGA module work. |
| `algorithm` | Algorithm module work. |
| `orderbook` | Orderbook module work. |
| `netio`     | Network I/O module work. |
| `exchange`  | Exchange interface module work. |

### Guidelines

- Do not commit directly to `main`.
- All work should be done on your component branch.
- Pull `main` into your branch regularly to avoid conflicts.
- Merge into `main` only when the code compiles and is verified.
- Use Pull Requests if branch protection is enabled.

---

## Working on a Branch

### Step 1 — Sync with main

`git checkout main`
`git pull`

---

### Step 2 — Switch to your component branch

`git checkout orderbook # replace with your branch`
`git merge main`

---

### Step 3 — Do your work

Edit files in the appropriate subdirectories. For example:

`hw/orderbook/src/rtl/`
`hw/orderbook/src/tb/`


---

### Step 4 — Commit your changes

`git add hw/orderbook/src/rtl`
`git commit -m "Orderbook: add price-level comparator"`

---

### Step 5 — Push your branch

`git push origin orderbook`


---

## `.gitkeep` Files

- Empty directories are preserved using `.gitkeep` files.
- Once you add real source files to a folder, you may delete the `.gitkeep` file in the same commit.
- This ensures the repo remains clean while keeping the intended folder structure for new files.

---

## Conflict Resolution

- RTL conflicts: resolve as usual.
- `.qsys` or `.qsf` conflicts: coordinate with the team before merging.
- If unsure → stop and ask a teammate.

---

## What Not to Commit

Avoid committing generated/build files:

- Quartus build folders: `db/`, `incremental_db/`, `output_files/`
- Simulation output: `sim/modelsim/work/`
- Generated IP: `.sopcinfo`, `.rpt`, `.csv`
- Other temporary files: `.log`, `.bak`, `.tmp`

Only commit source files, constraints, scripts, and `.qsys` or `.tcl` inputs.

---

## Optional GUI Workflow

- You are free to use VSCode Git extensions, GitHub Desktop, or the GitHub web GUI.
- You may explore ChatGPT or Git documentation for guidance if unfamiliar.
- The key is still to follow branch ownership and never push unverified changes directly to `main`.

---

## Summary

- Work on your component branch.
- Merge `main` → branch regularly.
- Merge branch → `main` only when code is verified.
- Delete `.gitkeep` when adding real files.
- Avoid committing build outputs and generated files.
- Use GUI or command line — your choice.
- Ask first if you are unsure about `.qsys` / `.qsf` merges.

---

Thanks for contributing and helping keep the repo clean and safe for everyone!