;;; org-drill-rephrase.el --- org-drill session with LLM-rephrased cards -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Your Name
;; Assisted-by: Claude:claude-sonnet-4-6
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (gptel "0.9") (org-drill "2.7"))
;; Keywords: org, drill, flashcards, llm, ai
;; URL: https://github.com/yourusername/org-drill-rephrase

;;; Commentary:

;; org-drill-rephrase is a drop-in replacement for `org-drill' that rephrases
;; every flashcard question via an LLM before showing it to the user.  The
;; user never sees the original wording, which forces genuine recall rather
;; than pattern-matching on familiar phrasing.
;;
;; The rephrasing is never written to disk.  Before org-drill moves on to the
;; next card (i.e. when you rate the current one), the original text is
;; silently restored in the buffer.
;;
;; Requirements:
;;   - gptel (https://github.com/karthink/gptel) configured with an LLM backend
;;
;; Usage:
;;   (require 'org-drill-rephrase)
;;   M-x org-drill-rephrase
;;
;; Customization:
;;   M-x customize-group RET org-drill-rephrase RET

;;; Code:

(require 'gptel)
(require 'org-drill)

;;;; Customization

(defgroup org-drill-rephrase nil
  "org-drill sessions with LLM-rephrased card questions."
  :group 'org-drill
  :prefix "org-drill-rephrase-")

(defcustom org-drill-rephrase-prompt
  "Rephrase the following flashcard question to test the same knowledge \
but with different wording. Keep it concise. \
Return only the rephrased question, nothing else.\n\nQuestion: %s"
  "Prompt template sent to the LLM.
Must contain exactly one `%s' placeholder for the original question text."
  :type 'string
  :group 'org-drill-rephrase)

;;;; Internal state

(defvar org-drill-rephrase--buffer nil
  "The org buffer in which the current drill session runs.")

(defvar org-drill-rephrase--active nil
  "Non-nil while a rephrased question is showing in the buffer.")

(defvar org-drill-rephrase--card-marker nil
  "Marker pointing to the heading of the card currently being rephrased.")

;;;; Question body helpers

(defun org-drill-rephrase--question-bounds ()
  "Return (BEG . END) of the question text in the current card.
The question is the body text after the heading (and its property drawer)
up to the first subheading (** or deeper), which marks the answer."
  (save-excursion
    (org-back-to-heading t)
    (forward-line 1)
    ;; Skip SCHEDULED/DEADLINE/CLOSED planning lines
    (while (looking-at-p "[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):")
      (forward-line 1))
    ;; Skip property drawer
    (when (looking-at-p "[ \t]*:PROPERTIES:")
      (re-search-forward "[ \t]*:END:[ \t]*\n" nil t))
    (let ((beg (point))
          (end (save-excursion
                 ;; Find first subheading or end of subtree
                 (if (re-search-forward "^\\*\\*+" nil t)
                     (line-beginning-position)
                   (org-end-of-subtree t)
                   (point)))))
      (cons beg end))))

(defun org-drill-rephrase--get-question ()
  "Return a cons (TEXT . BOUNDS) for the current card's question body.
TEXT is the trimmed question string; BOUNDS is (BEG . END)."
  (let* ((bounds (org-drill-rephrase--question-bounds))
         (raw    (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (cons (string-trim raw) bounds)))

(defun org-drill-rephrase--set-question (new-text bounds)
  "Replace the question body region BOUNDS with NEW-TEXT.
Preserves the leading and trailing whitespace of the original region
so the buffer structure is not disturbed.
Point is preserved: the caller's position is not affected."
  (let* ((pos   (point-marker))
         (beg   (car bounds))
         (end   (cdr bounds))
         (raw   (buffer-substring-no-properties beg end))
         (lead  (and (string-match "\\`\\([ \t\n]*\\)" raw)
                     (match-string 1 raw)))
         (trail (and (string-match "\\([ \t\n]*\\)\\'" raw)
                     (match-string 1 raw))))
    (delete-region beg end)
    (goto-char beg)
    (insert lead new-text trail)
    (goto-char pos)
    (set-marker pos nil)))

;;;; Restore logic

(defvar org-drill-rephrase--original-question nil
  "Original question body text (trimmed) of the card currently displayed.")

(defvar org-drill-rephrase--original-bounds nil
  "Original (BEG . END) bounds of the question body before rephrasing.")

(defun org-drill-rephrase--restore ()
  "Silently restore the original question text in the drill buffer."
  (when (and org-drill-rephrase--active
             org-drill-rephrase--original-question
             org-drill-rephrase--original-bounds
             (buffer-live-p org-drill-rephrase--buffer)
             (markerp org-drill-rephrase--card-marker)
             (marker-position org-drill-rephrase--card-marker))
    (with-current-buffer org-drill-rephrase--buffer
      (save-excursion
        (goto-char org-drill-rephrase--card-marker)
        ;; Recompute bounds: buffer positions shift after rephrase insertion.
        (org-drill-rephrase--set-question
         org-drill-rephrase--original-question
         (org-drill-rephrase--question-bounds)))))
  (setq org-drill-rephrase--active nil
        org-drill-rephrase--original-question nil
        org-drill-rephrase--original-bounds nil))

(defun org-drill-rephrase--before-reschedule (&rest _)
  "Restore original question before org-drill rates and advances the card."
  (org-drill-rephrase--restore))

;;;; Rephrase logic

(defun org-drill-rephrase--rephrase-current-card ()
  "Rephrase the question body of the card at point via the LLM.
Blocks synchronously until the response arrives, then replaces the question
body before org-drill sets up its display overlays."
  (setq org-drill-rephrase--buffer (current-buffer))
  (let* ((q-data   (org-drill-rephrase--get-question))
         (original (car q-data))
         (bounds   (cdr q-data))
         (prompt   (format org-drill-rephrase-prompt original))
         (done     nil)
         (result   nil))
    (setq org-drill-rephrase--card-marker (save-excursion
                                            (org-back-to-heading t)
                                            (point-marker))
          org-drill-rephrase--original-question original
          org-drill-rephrase--original-bounds   bounds
          org-drill-rephrase--active t)
    (gptel-request prompt
      :buffer org-drill-rephrase--buffer
      :stream nil
      :callback
      (lambda (response _info)
        (setq result response
              done t)))
    ;; `url-retrieve' is event-driven; we must yield to the Emacs event loop
    ;; so the HTTP response sentinel can fire and invoke the callback.
    ;; `sit-for' with NODISP=nil processes all pending events including
    ;; network I/O.  We loop until done, ignoring user input (C-g aside).
    (let ((inhibit-quit t))
      (while (not done)
        (sit-for 0.05)))
    (if (not (stringp result))
        (message "org-drill-rephrase: LLM request failed, showing original")
      (org-drill-rephrase--set-question (string-trim result) bounds))))

;;;; Hook into org-drill's card display

;; org-drill 2.7 dispatches all card types through `org-drill-entry-f'.
;; Inside it, `org-narrow-to-subtree' and `org-show-subtree' run first,
;; then the card-type presentation function sets up hide/show overlays.
;;
;; We use an :around advice on `org-drill-entry-f' so we can rephrase
;; BEFORE the presentation function places its overlays.  Rephrasing after
;; overlay setup shifts the overlay positions, causing the answer subheading
;; to become visible.
;;
;; The :around advice also lets us skip rephrasing for reschedule calls
;; (org-drill-entry-f is called a second time with 'org-drill-reschedule
;; as complete-func to show the answer and collect a rating).

(defun org-drill-rephrase--around-entry-f (orig session complete-func)
  "Around advice for `org-drill-entry-f'.
Rephrase the question before org-drill renders the card."
  (org-drill-rephrase--rephrase-current-card)
  (funcall orig session complete-func))

;;;; Session entry point

;;;###autoload
(defun org-drill-rephrase (&optional scope drill-sparingly)
  "Start an org-drill session where every card's question body is rephrased by an LLM.

The user never sees the original question wording; only the LLM rephrasing is
shown.  Original text is restored silently before each card is rated, so no
changes are ever persisted.

SCOPE and DRILL-SPARINGLY are passed through to `org-drill' unchanged."
  (interactive)
  (unless (bound-and-true-p gptel-backend)
    (user-error "org-drill-rephrase: gptel is not configured.  \
Set up a backend first with e.g. `gptel-make-anthropic'"))
  (advice-add 'org-drill-entry-f :around
              #'org-drill-rephrase--around-entry-f)
  (advice-add 'org-drill-reschedule :before
              #'org-drill-rephrase--before-reschedule)
  (unwind-protect
      (org-drill scope drill-sparingly)
    ;; Always clean up advices and restore text when the session ends.
    (advice-remove 'org-drill-entry-f
                   #'org-drill-rephrase--around-entry-f)
    (advice-remove 'org-drill-reschedule
                   #'org-drill-rephrase--before-reschedule)
    (org-drill-rephrase--restore)))

(provide 'org-drill-rephrase)
;;; org-drill-rephrase.el ends here
