;;; org-drill-rephrase-tests.el --- ERT tests for org-drill-rephrase -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the command line:
;;
;;   emacs -Q --batch \
;;     --eval "(add-to-list 'load-path \".\")" \
;;     -l org-drill-rephrase-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'org-drill-rephrase)

;;;; Helpers

(defmacro with-org-drill-buffer (content &rest body)
  "Run BODY in a temporary org-mode buffer pre-filled with CONTENT.
Point is placed at the first heading."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     (re-search-forward "^\\*" nil t)
     (beginning-of-line)
     ,@body))

;;;; Tests: org-drill-rephrase--question-bounds

(ert-deftest org-drill-rephrase--question-bounds/simple ()
  "Basic card: heading, question, answer subheading."
  (with-org-drill-buffer
      "* Card\nWhat is 2+2?\n** Answer\n4\n"
    (let* ((bounds (org-drill-rephrase--question-bounds))
           (text   (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (should (string= (string-trim text) "What is 2+2?")))))

(ert-deftest org-drill-rephrase--question-bounds/with-properties ()
  "Card with a PROPERTIES drawer — drawer must be skipped."
  (with-org-drill-buffer
      "* Card\n:PROPERTIES:\n:DRILL_CARD_TYPE: simple\n:END:\nWhat is 3+3?\n** Answer\n6\n"
    (let* ((bounds (org-drill-rephrase--question-bounds))
           (text   (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (should (string= (string-trim text) "What is 3+3?")))))

(ert-deftest org-drill-rephrase--question-bounds/with-scheduled ()
  "Card with a SCHEDULED planning line — it must be skipped."
  (with-org-drill-buffer
      "* Card\nSCHEDULED: <2026-01-01>\nWhat is 4+4?\n** Answer\n8\n"
    (let* ((bounds (org-drill-rephrase--question-bounds))
           (text   (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (should (string= (string-trim text) "What is 4+4?")))))

(ert-deftest org-drill-rephrase--question-bounds/no-subheading ()
  "Card without a subheading — bounds must reach end of subtree."
  (with-org-drill-buffer
      "* Card\nWhat is 5+5?\n"
    (let* ((bounds (org-drill-rephrase--question-bounds))
           (text   (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (should (string= (string-trim text) "What is 5+5?")))))

(ert-deftest org-drill-rephrase--question-bounds/multiline-question ()
  "Multi-line question body is captured in full."
  (with-org-drill-buffer
      "* Card\nLine one.\nLine two.\nLine three.\n** Answer\nyes\n"
    (let* ((bounds (org-drill-rephrase--question-bounds))
           (text   (string-trim
                    (buffer-substring-no-properties (car bounds) (cdr bounds)))))
      (should (string-match-p "Line one" text))
      (should (string-match-p "Line two" text))
      (should (string-match-p "Line three" text)))))

(ert-deftest org-drill-rephrase--question-bounds/does-not-include-answer ()
  "Answer subheading text must not appear in the question bounds."
  (with-org-drill-buffer
      "* Card\nThe question.\n** Answer\nThe answer.\n"
    (let* ((bounds (org-drill-rephrase--question-bounds))
           (text   (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (should-not (string-match-p "The answer" text)))))

;;;; Tests: org-drill-rephrase--get-question

(ert-deftest org-drill-rephrase--get-question/returns-cons ()
  "Return value is a cons of (string . (beg . end))."
  (with-org-drill-buffer
      "* Card\nQuestion text.\n** Answer\nAnswer.\n"
    (let ((result (org-drill-rephrase--get-question)))
      (should (consp result))
      (should (stringp (car result)))
      (should (consp (cdr result))))))

(ert-deftest org-drill-rephrase--get-question/text-is-trimmed ()
  "Returned text must be trimmed of surrounding whitespace."
  (with-org-drill-buffer
      "* Card\n\n  Question text.  \n\n** Answer\nAnswer.\n"
    (let ((text (car (org-drill-rephrase--get-question))))
      (should (string= text "Question text.")))))

(ert-deftest org-drill-rephrase--get-question/bounds-are-integers ()
  "Bounds must be integer buffer positions."
  (with-org-drill-buffer
      "* Card\nQuestion.\n** Answer\nAnswer.\n"
    (let* ((result (org-drill-rephrase--get-question))
           (bounds (cdr result)))
      (should (integerp (car bounds)))
      (should (integerp (cdr bounds)))
      (should (< (car bounds) (cdr bounds))))))

;;;; Tests: org-drill-rephrase--set-question

(ert-deftest org-drill-rephrase--set-question/replaces-text ()
  "Replacement text appears in buffer after set-question."
  (with-org-drill-buffer
      "* Card\nOriginal question.\n** Answer\nAnswer.\n"
    (let* ((q-data (org-drill-rephrase--get-question))
           (bounds (cdr q-data)))
      (org-drill-rephrase--set-question "Rephrased question." bounds)
      (let* ((new-bounds (org-drill-rephrase--question-bounds))
             (new-text   (string-trim
                          (buffer-substring-no-properties
                           (car new-bounds) (cdr new-bounds)))))
        (should (string= new-text "Rephrased question."))))))

(ert-deftest org-drill-rephrase--set-question/preserves-whitespace-structure ()
  "Leading/trailing whitespace of the original region is preserved."
  (with-org-drill-buffer
      "* Card\nOriginal question.\n** Answer\nAnswer.\n"
    (let* ((q-data  (org-drill-rephrase--get-question))
           (bounds  (cdr q-data))
           (beg     (car bounds))
           (end     (cdr bounds))
           (raw-before (buffer-substring-no-properties beg end)))
      (org-drill-rephrase--set-question "New question." bounds)
      ;; Re-read the same region width
      (let* ((new-bounds (org-drill-rephrase--question-bounds))
             (raw-after  (buffer-substring-no-properties
                          (car new-bounds) (cdr new-bounds))))
        ;; Leading and trailing whitespace characters should match
        (should (string= (and (string-match "\\`\\([ \t\n]*\\)" raw-before)
                              (match-string 1 raw-before))
                         (and (string-match "\\`\\([ \t\n]*\\)" raw-after)
                              (match-string 1 raw-after))))))))

(ert-deftest org-drill-rephrase--set-question/preserves-point ()
  "Point must be unchanged after set-question."
  (with-org-drill-buffer
      "* Card\nOriginal question.\n** Answer\nAnswer.\n"
    (let* ((q-data (org-drill-rephrase--get-question))
           (bounds (cdr q-data))
           (pos-before (point)))
      (org-drill-rephrase--set-question "New question." bounds)
      (should (= (point) pos-before)))))

(ert-deftest org-drill-rephrase--set-question/roundtrip ()
  "Setting question to original text leaves buffer content unchanged."
  (with-org-drill-buffer
      "* Card\nOriginal question.\n** Answer\nAnswer.\n"
    (let* ((content-before (buffer-string))
           (q-data  (org-drill-rephrase--get-question))
           (original (car q-data))
           (bounds  (cdr q-data)))
      (org-drill-rephrase--set-question "Something else." bounds)
      ;; Now restore
      (org-drill-rephrase--set-question
       original (org-drill-rephrase--question-bounds))
      (should (string= (buffer-string) content-before)))))

;;;; Tests: org-drill-rephrase--restore

(ert-deftest org-drill-rephrase--restore/no-op-when-inactive ()
  "restore must be a no-op when --active is nil."
  (with-org-drill-buffer
      "* Card\nOriginal.\n** Answer\nAnswer.\n"
    (let ((org-drill-rephrase--active nil))
      ;; Should not signal any error
      (should (null (org-drill-rephrase--restore))))))

(ert-deftest org-drill-rephrase--restore/restores-original-text ()
  "restore puts back the saved original question."
  (with-org-drill-buffer
      "* Card\nOriginal question.\n** Answer\nAnswer.\n"
    (let* ((q-data   (org-drill-rephrase--get-question))
           (original (car q-data))
           (bounds   (cdr q-data))
           ;; Set up state as rephrase-current-card would
           (org-drill-rephrase--buffer          (current-buffer))
           (org-drill-rephrase--active          t)
           (org-drill-rephrase--original-question original)
           (org-drill-rephrase--original-bounds   bounds)
           (org-drill-rephrase--buffer-modified   nil)
           (org-drill-rephrase--card-marker
            (save-excursion (org-back-to-heading t) (point-marker))))
      ;; Simulate a rephrase
      (org-drill-rephrase--set-question "Rephrased version." bounds)
      ;; Now restore
      (org-drill-rephrase--restore)
      (let* ((new-bounds (org-drill-rephrase--question-bounds))
             (text-after (string-trim
                          (buffer-substring-no-properties
                           (car new-bounds) (cdr new-bounds)))))
        (should (string= text-after original))))))

(ert-deftest org-drill-rephrase--restore/clears-state-vars ()
  "restore sets all internal state vars back to nil."
  (with-org-drill-buffer
      "* Card\nOriginal.\n** Answer\nAnswer.\n"
    (let* ((q-data   (org-drill-rephrase--get-question))
           (original (car q-data))
           (bounds   (cdr q-data))
           (org-drill-rephrase--buffer          (current-buffer))
           (org-drill-rephrase--active          t)
           (org-drill-rephrase--original-question original)
           (org-drill-rephrase--original-bounds   bounds)
           (org-drill-rephrase--buffer-modified   nil)
           (org-drill-rephrase--card-marker
            (save-excursion (org-back-to-heading t) (point-marker))))
      (org-drill-rephrase--restore)
      (should (null org-drill-rephrase--active))
      (should (null org-drill-rephrase--original-question))
      (should (null org-drill-rephrase--original-bounds))
      (should (null org-drill-rephrase--buffer-modified)))))

(provide 'org-drill-rephrase-tests)
;;; org-drill-rephrase-tests.el ends here
