;;; org-drill-rephrase.el --- org-drill session with LLM-rephrased cards -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Your Name
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
  "Marker pointing to the heading of the card currently being rephrased.
Used by the async callback and restore logic to navigate back to the right
position regardless of where point ends up after org-drill starts waiting
for input.")

;;;; Question body helpers

(defun org-drill-rephrase--question-bounds ()
  "Return (BEG . END) of the question text in the current card.
The question is the body text after the heading (and its property drawer)
up to the first subheading (** or deeper), which marks the answer."
  (save-excursion
    (org-back-to-heading t)
    (forward-line 1)
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
  "Return the question text of the current card.
Returns a cons (TEXT . REGION) where TEXT is the trimmed question string
and REGION is the (BEG . END) bounds, so callers can restore exactly."
  (let* ((bounds (org-drill-rephrase--question-bounds))
         (raw    (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (cons (string-trim raw) bounds)))

(defun org-drill-rephrase--set-question (new-text bounds)
  "Replace the question body region BOUNDS with NEW-TEXT.
BOUNDS is a (BEG . END) cons as returned by `org-drill-rephrase--question-bounds'.
The replacement preserves the leading and trailing whitespace of the original
region so the buffer structure is not disturbed.
Point is preserved: the caller's position is not affected."
  (let* ((pos     (point-marker))
         (beg     (car bounds))
         (end     (cdr bounds))
         (raw     (buffer-substring-no-properties beg end))
         ;; Measure leading/trailing whitespace of the original region.
         (lead    (and (string-match "\\`\\([ \t\n]*\\)" raw)
                       (match-string 1 raw)))
         (trail   (and (string-match "\\([ \t\n]*\\)\\'" raw)
                       (match-string 1 raw))))
    (delete-region beg end)
    (goto-char beg)
    (insert lead new-text trail)
    (goto-char pos)
    (set-marker pos nil)))

;;;; Restore logic

(defvar org-drill-rephrase--original-question nil
  "Original question body text (trimmed string) of the card currently displayed.")

(defvar org-drill-rephrase--original-bounds nil
  "Original (BEG . END) region of the question body, as buffer positions.
Stored alongside `org-drill-rephrase--original-question' so restore can
write back into exactly the same region without adding extra whitespace.")

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
        ;; Recompute bounds: after placeholder insertion the buffer positions
        ;; have shifted, so we must re-derive them from the heading.
        (org-drill-rephrase--set-question
         org-drill-rephrase--original-question
         (org-drill-rephrase--question-bounds)))))
  (setq org-drill-rephrase--active nil
        org-drill-rephrase--original-question nil
        org-drill-rephrase--original-bounds nil))

(defun org-drill-rephrase--before-reschedule (&rest _)
  "Restore original question before org-drill rates and advances the card."
  (org-drill-rephrase--restore))

;;;; Rephrase-and-show logic

(defun org-drill-rephrase--rephrase-current-card ()
  "Rephrase the question body of the card at point and display the result.
Shows a placeholder immediately, then updates asynchronously via gptel."
  (setq org-drill-rephrase--buffer (current-buffer))
  (let* ((q-data  (org-drill-rephrase--get-question))
         (original (car q-data))
         (bounds   (cdr q-data))
         (prompt   (format org-drill-rephrase-prompt original)))
    ;; Save a marker to the heading so the async callback and restore logic
    ;; can navigate back to the right card regardless of where point ends up.
    (setq org-drill-rephrase--card-marker (save-excursion
                                            (org-back-to-heading t)
                                            (point-marker))
          org-drill-rephrase--original-question original
          org-drill-rephrase--original-bounds   bounds
          org-drill-rephrase--active t)
    ;; Show placeholder while waiting for LLM
    (org-drill-rephrase--set-question "[…]" bounds)
    (gptel-request prompt
      :buffer org-drill-rephrase--buffer
      :callback
      (lambda (response info)
        (if (not response)
            (progn
              (message "org-drill-rephrase: LLM request failed: %s"
                       (plist-get info :status))
              ;; Fall back to original so the user can still study
              (org-drill-rephrase--restore))
          (when (and (buffer-live-p org-drill-rephrase--buffer)
                     org-drill-rephrase--active)
            (with-current-buffer org-drill-rephrase--buffer
              ;; Navigate to the card heading before calling set-question,
              ;; since point may have moved while the async request was in flight.
              (save-excursion
                (goto-char org-drill-rephrase--card-marker)
                (org-drill-rephrase--set-question
                 (string-trim response)
                 (org-drill-rephrase--question-bounds))))))))))

;;;; Hook into org-drill's card display

;; org-drill 2.7 dispatches all card types through `org-drill-entry-f', which
;; calls `org-narrow-to-subtree', `org-show-subtree', and then the card-type
;; presentation function (e.g. `org-drill-present-simple-card').  That
;; presentation function sets up hide/show overlays and then calls
;; `org-drill-presentation-prompt'.
;;
;; We must rephrase the question body BEFORE the presentation function runs,
;; so that org-drill's overlays are placed on top of already-rephrased text.
;; If we rephrase after the overlays are placed (e.g. in a :before advice on
;; `org-drill-presentation-prompt'), the buffer-text change shifts the overlay
;; positions and breaks the hide/show logic (answer becomes visible).
;;
;; Solution: :before advice on `org-drill-entry-f', which runs after the
;; subtree is narrowed/shown but before any presentation function or overlay.
;;
;; We also hook `org-drill-reschedule' (called when the user rates a card)
;; to restore the original text before org-drill touches the entry again.

(defun org-drill-rephrase--before-entry-f (_session complete-func)
  "Before advice for `org-drill-entry-f'.
Restore any previous rephrase first, then rephrase the current card.
Runs after the subtree is narrowed but before any overlays are placed,
so the hide/show overlay positions are correct over the rephrased text.
Only fires for card presentation calls, not for reschedule calls."
  (when (not (eq complete-func 'org-drill-reschedule))
    (org-drill-rephrase--restore)
    (org-drill-rephrase--rephrase-current-card)))

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
Set up a backend first with e.g. `gptel-make-openai'"))
  (advice-add 'org-drill-entry-f :before
              #'org-drill-rephrase--before-entry-f)
  (advice-add 'org-drill-reschedule :before
              #'org-drill-rephrase--before-reschedule)
  (unwind-protect
      (org-drill scope drill-sparingly)
    ;; Always clean up advice and restore heading when the session ends.
    (advice-remove 'org-drill-entry-f
                   #'org-drill-rephrase--before-entry-f)
    (advice-remove 'org-drill-reschedule
                   #'org-drill-rephrase--before-reschedule)
    (org-drill-rephrase--restore)))

(provide 'org-drill-rephrase)
;;; org-drill-rephrase.el ends here
