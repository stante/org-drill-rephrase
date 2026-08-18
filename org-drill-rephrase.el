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

(defvar org-drill-rephrase--original-heading nil
  "Original heading text of the card currently being displayed.")

(defvar org-drill-rephrase--active nil
  "Non-nil while a rephrased heading is showing in the buffer.")

;;;; Heading helpers

(defun org-drill-rephrase--get-heading ()
  "Return the title of the org entry at point (no stars, no tags)."
  (save-excursion
    (org-back-to-heading t)
    (org-get-heading t t t t)))

(defun org-drill-rephrase--set-heading (new-text)
  "Replace the title of the org entry at point with NEW-TEXT."
  (save-excursion
    (org-back-to-heading t)
    (let ((line-end (line-end-position)))
      (re-search-forward "\\*+ +" line-end t)
      (let* ((title-start (point))
             (title-end (or (and (re-search-forward
                                  "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*$"
                                  line-end t)
                                 (match-beginning 0))
                            line-end)))
        (delete-region title-start title-end)
        (goto-char title-start)
        (insert new-text)))))

;;;; Restore logic

(defun org-drill-rephrase--restore ()
  "Silently restore the original heading text in the drill buffer."
  (when (and org-drill-rephrase--active
             org-drill-rephrase--original-heading
             (buffer-live-p org-drill-rephrase--buffer))
    (with-current-buffer org-drill-rephrase--buffer
      (org-drill-rephrase--set-heading org-drill-rephrase--original-heading)))
  (setq org-drill-rephrase--active nil
        org-drill-rephrase--original-heading nil))

(defun org-drill-rephrase--before-reschedule (&rest _)
  "Restore original heading before org-drill rates and advances the card."
  (org-drill-rephrase--restore))

;;;; Rephrase-and-show logic

(defun org-drill-rephrase--rephrase-current-card ()
  "Rephrase the heading of the card at point and display the result.
Shows a placeholder immediately, then updates asynchronously via gptel."
  (setq org-drill-rephrase--buffer (current-buffer))
  (let* ((original (org-drill-rephrase--get-heading))
         (prompt   (format org-drill-rephrase-prompt original)))
    (setq org-drill-rephrase--original-heading original
          org-drill-rephrase--active t)
    ;; Show placeholder while waiting for LLM
    (org-drill-rephrase--set-heading "[…]")
    (gptel-request prompt
      :buffer (current-buffer)
      :callback
      (lambda (response info)
        (if (not response)
            (progn
              (message "org-drill-rephrase: LLM request failed: %s"
                       (plist-get info :status))
              ;; Fall back to original so the user can still study
              (org-drill-rephrase--restore))
          (when (buffer-live-p org-drill-rephrase--buffer)
            (with-current-buffer org-drill-rephrase--buffer
              (org-drill-rephrase--set-heading (string-trim response)))))))))

;;;; Hook into org-drill's card display

;; org-drill calls `org-drill-present-card' for each card.  We wrap it so
;; that immediately after the card is shown we replace the heading.
;;
;; We also hook `org-drill-reschedule' (called when the user rates a card)
;; to restore the original text before org-drill touches the entry again.

(defun org-drill-rephrase--around-present-card (orig &rest args)
  "Around advice for `org-drill-present-card'.
Restore any previous rephrase first, then call ORIG, then rephrase the new card."
  ;; Restore previous card's heading (belt-and-suspenders; reschedule should
  ;; have already done this, but not all exit paths go through reschedule).
  (org-drill-rephrase--restore)
  (let ((result (apply orig args)))
    ;; After the card is rendered, rephrase it.
    (org-drill-rephrase--rephrase-current-card)
    result))

;;;; Session entry point

;;;###autoload
(defun org-drill-rephrase (&optional scope drill-sparingly)
  "Start an org-drill session where every card's question is rephrased by an LLM.

The user never sees the original heading wording; only the LLM rephrasing is
shown.  Original text is restored silently before each card is rated, so no
changes are ever persisted.

SCOPE and DRILL-SPARINGLY are passed through to `org-drill' unchanged."
  (interactive)
  (unless (bound-and-true-p gptel-backend)
    (user-error "org-drill-rephrase: gptel is not configured.  \
Set up a backend first with e.g. `gptel-make-openai'"))
  (advice-add 'org-drill-present-card :around
              #'org-drill-rephrase--around-present-card)
  (advice-add 'org-drill-reschedule :before
              #'org-drill-rephrase--before-reschedule)
  (unwind-protect
      (org-drill scope drill-sparingly)
    ;; Always clean up advice and restore heading when the session ends.
    (advice-remove 'org-drill-present-card
                   #'org-drill-rephrase--around-present-card)
    (advice-remove 'org-drill-reschedule
                   #'org-drill-rephrase--before-reschedule)
    (org-drill-rephrase--restore)))

(provide 'org-drill-rephrase)
;;; org-drill-rephrase.el ends here
