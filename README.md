# org-drill-rephrase

Drop-in replacement for `org-drill` that rephrases every flashcard question via an LLM before showing it to the user.

The user **never sees the original wording**, which prevents pattern-matching on familiar phrasing and forces genuine recall.  The rephrasing is never written to disk — original text is silently restored before each card is rated.

## How it works

1. `M-x org-drill-rephrase` starts a normal org-drill session
2. Before each card is shown, the question body is sent to the LLM synchronously (no placeholder is inserted)
3. The LLM response replaces the question body — the user sees only the rephrased question
4. When the user rates the card, the original text is restored silently before org-drill saves
5. No changes are ever saved

## Requirements

- Emacs 27.1+
- [org-drill](https://gitlab.com/phillord/org-drill)
- [gptel](https://github.com/karthink/gptel) configured with a backend (OpenAI, Claude, Ollama, etc.)

## Installation

### Manual

```elisp
(add-to-list 'load-path "/path/to/org-drill-rephrase")
(require 'org-drill-rephrase)
```

### use-package

```elisp
(use-package org-drill-rephrase
  :load-path "/path/to/org-drill-rephrase"
  :after (org-drill gptel))
```

## Configuration

Make sure gptel is set up with a backend:

```elisp
;; OpenAI
(setq gptel-api-key "YOUR_API_KEY")

;; local Ollama
(gptel-make-ollama "Ollama" :host "localhost:11434" :models '(llama3.2))
```

## Usage

```
M-x org-drill-rephrase
```

Accepts the same prefix arguments as `org-drill` (scope, drill-sparingly).

## Customization

```
M-x customize-group RET org-drill-rephrase RET
```

| Variable | Description |
|---|---|
| `org-drill-rephrase-prompt` | Prompt template sent to the LLM; `%s` is replaced with the original question |
