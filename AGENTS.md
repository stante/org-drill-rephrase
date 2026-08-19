# AGENTS.md

## Repo at a glance

Single-file Emacs Lisp package (`org-drill-rephrase.el`, ~187 lines). No build system, no test suite, no CI, no package manager.

Runtime dependencies (declared in file header):
- **gptel** ≥ 0.9 — LLM client
- **org-drill** ≥ 2.7 — spaced-repetition flashcard system

## Commands

There are no Makefile/taskfile targets. The only relevant shell command is optional byte-compilation:

```sh
emacs -Q --batch -f batch-byte-compile org-drill-rephrase.el
```

No linter, formatter, typecheck, or test runner is configured.

## Architecture

All logic is in `org-drill-rephrase.el`. Key facts:

- **Entry point:** `M-x org-drill-rephrase` (autoloaded interactive function) — wraps `org-drill` with advices installed for the session.
- **Hook mechanism:** Emacs advice, not hooks:
  - `:before` on `org-drill-presentation-prompt` — triggers LLM rephrasing on card display. **Note:** `org-drill-present-card` does not exist in org-drill 2.7; `org-drill-presentation-prompt` is the common call site across all card types.
  - `:before` on `org-drill-reschedule` — restores original text before rating/save.
- **What gets rephrased:** The question body (text between the heading and the first `**` subheading), not the heading title or answer.
- **Async flow:** `gptel-request` replaces body with `[…]` while waiting; callback swaps in the LLM response or restores original on failure.
- **Non-destructive:** Original text is always restored before any disk write. `unwind-protect` removes advices on exit even on error or quit.
- **`lexical-binding: t`** is required — closures in the `gptel-request` callback depend on it.

## Key internal symbols

| Symbol | Role |
|---|---|
| `org-drill-rephrase--buffer` | Reference to the active org buffer, passed explicitly to `gptel-request` for async safety |
| `org-drill-rephrase--active` | Guard flag; non-nil while a rephrase is showing |
| `org-drill-rephrase--original-question` | Saved original question text |
| `org-drill-rephrase-prompt` | User-customizable prompt template (single `%s` placeholder) |

## Conventions

- Commit style: conventional commits (`feat:`, `refactor:`, etc.).
- `gptel-backend` must be configured by the user before calling `M-x org-drill-rephrase`; the code `user-error`s if it is not.
- The placeholder `Your Name` / `yourusername` in the file header are unfilled template values.
- License: GPL-3.0 (consistent with MELPA requirements).
