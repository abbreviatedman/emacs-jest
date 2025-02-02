;;; emacs-jest.el --- Jest testing framework in GNU Emacs                     -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Yev Barkalov

;; Author: Yev Barkalov <yev@yev.bar>
;; Keywords: lisp
;; Version: 0.0.1

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a way to use Jest in emacs.
;; Note, this refers to the JavaScript testing framework <https://jestjs.io/>

;;; Code:

(require 'noflet)
(require 'compile)
(require 'xml)
(require 'dom)
(require 'highlight)
(require 'dash)
(require 'linum)
(require 'projectile)
;; (require 'helm-projectile)

;;; Custom vars
(defgroup emacs-jest nil
  "Tools for running jest tests"
  :group 'tools)

(defcustom emacs-jest-environment-vars nil
  "Environment variables that get applied to all jest calls"
  :type 'string
  :group 'emacs-jest)

(defcustom emacs-jest-default-args nil
  "Arguments that get applied to all jest calls"
  :type 'string
  :group 'emacs-jest)

(defcustom emacs-jest-coverage-default-args nil
  "Arguments that get applied to all jest --coverage calls"
  :type 'string
  :group 'emacs-jest)

(defcustom emacs-jest-coverage-directory "coverage"
  "The `coverageDirectory` value in your jest config file"
  :type 'string
  :group 'emacs-jest)

;; TODO - save historical results as custom config
;; TODO - if ^ then make chart to show jest coverage change over time (per branch etc)

;;; General utils
(defvar emacs-jest-node-error-regexp
  "^[  ]+at \\(?:[^\(\n]+ \(\\)?\\(\\(?:[a-zA-Z]:\\)?[a-zA-Z\.0-9_/\\-]+\\):\\([0-9]+\\):\\([0-9]+\\)\)?"
  "Regular expression to match NodeJS errors.
From http://benhollis.net/blog/2015/12/20/nodejs-stack-traces-in-emacs-compilation-mode/")

(defvar emacs-jest-node-error-regexp-alist
  `((,node-error-regexp 1 2 3)))

;; Takes a buffer name and kills if exists
;; Also takes optional boolean to raise error if buffer exists instead of killing it
(defun emacs-jest-check-buffer-does-not-exist (buffer-name &optional error-if-exists)
  (let ((buffer-exists (get-buffer buffer-name)))
    (cond
     ((and buffer-exists error-if-exists)
      (error (concat "Buffer " buffer-name " already exists")))
     (buffer-exists
      (kill-buffer buffer-name)))))

;; Replaces in string
;; Graciously taken from https://stackoverflow.com/a/17325791/16587811
(defun emacs-jest-replace-in-string (what with in)
  (replace-regexp-in-string (regexp-quote what) with in nil 'literal))

;; If whole number, returns as is
;; Otherwise formats up to two decimal places
(defun emacs-jest-format-decimal (value)
  (cond
   ((eq 0 value)
    "0%")
   (t
    (concat (format "%.4g" value) "%"))))

(defun emacs-jest-get-percentage (portion total)
  (cond
   ((eq 0 portion)
    (format-decimal 0))
   ((eq 0 total)
    (format-decimal 0))
   ((eq portion total)
    (format-decimal 100))
   (t
    (format-decimal (* 100 (/ (float portion) total))))))

(defun emacs-jest-last-character (str)
  (substring str -1 nil))

(defun emacs-jest-is-percentage (str)
  (string-equal (last-character str) "%"))

(defun emacs-jest-extract-percentage (percentage-string)
  (string-to-number (substring percentage-string 0 -1)))

(defun emacs-jest-string-to-list (str)
  (mapcar 'char-to-string str))

(defun emacs-jest-index-of-first-deviating-character (str1 str2)
  (let ((zipped (-zip (string-to-list str1) (string-to-list str2))))
    (-find-index
     (lambda (x) (not (string-equal (car x) (cdr x))))
     zipped)))

(defun emacs-jest-pad-string-until-length (str desired-length)
  (let* ((difference (- desired-length (length str)))
	 (to-pad-left (/ difference 2))
	 (to-pad-right (- difference to-pad-left)))
    (concat (make-string to-pad-left (string-to-char " ")) str (make-string to-pad-right (string-to-char " ")))))

(defun emacs-jest-truthy-string (str)
  (and str (> (length str) 0)))

;;; Related to the compilation buffer
(defun emacs-jest-compilation-filter ()
  "Filter function for compilation output."
  (ansi-color-apply-on-region compilation-filter-start (point-max)))

(defun emacs-jest-after-completion (buffer desc))

(define-compilation-mode emacs-jest-compilation-mode "Jest"
  "Jest compilation mode."
  (progn
    (set (make-local-variable 'compilation-error-regexp-alist) node-error-regexp-alist)
    (set (make-local-variable 'compilation-finish-functions) 'emacs-jest-after-completion)
    (add-hook 'compilation-filter-hook 'emacs-jest-compilation-filter nil t)
    ))

;;; Related to actually running jest
(defun emacs-jest-get-jest-executable ()
  (let ((project-provided-jest-path (concat default-directory "node_modules/.bin/jest")))
    (cond
     ;; Check to see if an executable exists within the `default-directory` value
     ((file-exists-p project-provided-jest-path) project-provided-jest-path)
     ;; Check to see if there's a global jest executable
     ((executable-find "jest") "jest")
     ;; Otherwise we throw an error
     (t (error "Failed to find jest executable")))))

(defun emacs-jest-with-coverage-args (&optional arguments)
  (let* ((minimum-args (list "--coverage"))
	 (with-default-args (if (truthy-string emacs-jest-coverage-default-args)
				(append minimum-args (list emacs-jest-coverage-default-args))
			      minimum-args))
	 (with-args (if (truthy-string arguments)
			(append arguments with-default-args)
		      with-default-args)))
    with-args))

(defun emacs-jest-get-jest-arguments (&optional arguments)
  (if arguments
      (string-join
       (flatten-list
	(list
	 emacs-jest-environment-vars
	 arguments
	 emacs-jest-default-args)) " ")
    ""))

;; Takes optional list of tuples and applies them to jest command
(defun emacs-jest-generate-jest-command (&optional arguments)
  (let ((jest-executable (emacs-jest-get-jest-executable))
	(jest-arguments (emacs-jest-get-jest-arguments arguments)))
    (string-join `(,jest-executable ,jest-arguments) " ")))

(defun emacs-jest-run-jest-command (&optional arguments)
  ;; Check there are no unsaved buffers
  (save-some-buffers (not compilation-ask-about-save)
                     (when (boundp 'compilation-save-buffers-predicate)
                       compilation-save-buffers-predicate))

  ;; Kill previous test buffer if exists
  (check-buffer-does-not-exist "*jest tests*")

  ;; Storing `target-directory` since this changes when
  ;; we change window if there's more than one buffer
  (let ((target-directory (projectile-project-root)))
    (unless (eq 1 (length (window-list)))
      (select-window (previous-window)))

    ;; Create new buffer and run command
    (with-current-buffer (get-buffer-create "*jest tests*")
      (switch-to-buffer "*jest tests*")
      (let ((default-directory target-directory) (compilation-scroll-output t))
	(compilation-start
	 (emacs-jest-generate-jest-command arguments)
	 'emacs-jest-compilation-mode
	 (lambda (m) (buffer-name)))))))

(defun emacs-jest-test-file (&optional filename)
  (interactive)
  (cond
   ((not filename)
    (let ((helm-projectile-sources-list
	   '(helm-source-projectile-buffers-list
	     helm-source-projectile-files-list)))
      (noflet ((helm-find-file-or-marked (candidate) (emacs-jest-test-file candidate))
	       (helm-buffer-switch-buffers (candidate) (emacs-jest-test-file (buffer-file-name candidate))))
	(helm-projectile))))
   ((file-exists-p filename)
    (emacs-jest-run-jest-command `(,filename)))
   (t
    (error "Invalid file provided"))))

(defun emacs-jest-test-current-file ()
  (interactive)
  (emacs-jest-test-file buffer-file-name))

(defun emacs-jest-test-directory (&optional directory)
  (interactive)
  (unless directory (setq directory (read-directory-name "Test directory:")))
  (emacs-jest-run-jest-command `(,directory)))

(defun emacs-jest-test-current-directory ()
  (interactive)
  (emacs-jest-test-directory default-directory))

(defun emacs-jest-test-coverage ()
  (interactive)
  (emacs-jest-run-jest-command (with-coverage-args)))

(defun emacs-jest-present-coverage-as-org-table (columns table)
  (insert (concat "|" (string-join columns "|") "|"))
  (newline)

  (insert "|-")
  (newline)

  (mapc
   (lambda (row)
     (progn
       (insert "|")
       (insert (string-join row "|"))
       (insert "|")
       (newline)))
   table)

  ;; Deleting the last (newline) call
  (delete-backward-char 1)

  (org-mode)
  (org-table-align)
  (add-coverage-table-color-indicators)

  ;; Adding hook so highlights can be re-introduced even after sorting column
  (add-hook 'org-ctrl-c-ctrl-c-hook 'add-coverage-table-color-indicators)

  ;; Moving to start of file
  (beginning-of-buffer))

(defun emacs-jest-present-coverage-as-table (title columns table &optional table-type)
  (when (= (length columns) 0)
    (error "Invalid columns passed in"))

  (let ((desired-buffer-name (concat "coverage: " title)))
    (check-buffer-does-not-exist desired-buffer-name)

    (with-current-buffer (get-buffer-create desired-buffer-name)
      (switch-to-buffer desired-buffer-name)
      (present-coverage-as-org-table columns table))))

(defun emacs-jest-get-highlight-color-from-percentage (value)
  (cond
   ((>= value 80)
    "green")
   ((>= value 60)
    "yellow")
   (t
    "red")))

(defun emacs-jest-add-coverage-table-color-indicators ()
  (interactive)
  (let* ((tree (org-element-parse-buffer))
         (tables (org-element-map tree 'table 'identity)))
    (org-element-map (car tables) 'table-cell
      (lambda (x)
	(let ((cell-value (car (org-element-contents x)))
	      (cell-start (org-element-property :begin x))
	      (cell-end (- (org-element-property :end x) 1)))
	  (when (is-percentage cell-value)
	    (let* ((percentage (extract-percentage cell-value))
		   (color-to-apply (get-highlight-color-from-percentage percentage)))
	      (hlt-highlight-region cell-start cell-end `((t (:foreground "black" :background ,color-to-apply)))))))))))

(defun emacs-jest-format-meta-category-stat (category-element)
  (let* ((info-elements (dom-by-tag category-element 'span))
	 (info-texts (mapcar 'dom-text info-elements)))
    (concat (first info-texts) (second info-texts) " (" (third info-texts) ")")))

;; This takes an lcov-report HTML and returns
;; ("<title>", "X% <category> (M/N)", "X% <category> (M/N)", "X% <category> (M/N)")
(defun emacs-jest-parse--lcov-report-meta (lcov-report-html)
  (let* ((title-text (dom-text (first (dom-by-tag lcov-report-html 'h1))))
	 (trimmed-title-text (string-join
			      (-filter
			       (lambda (x) (not (string-equal "/" x)))
			       (split-string title-text))
			      " "))
	 (title
	  (cond
	   ((string-equal trimmed-title-text "All files")
	    trimmed-title-text)
	   ((dom-by-class lcov-report-html "coverage-summary")
	    (concat trimmed-title-text "/"))
	   (t
	    trimmed-title-text)))
	 (category-tags (dom-by-class lcov-report-html "space-right2"))
	 (category-stats (string-join
			  (mapcar 'format-meta-category-stat category-tags)
			  ", ")))
    (list title category-stats)))

(defun emacs-jest-parse--lcov-report-row-identifier (lcov-report-row)
  (let* ((a-tag (first (dom-by-tag lcov-report-row 'a)))
	 (a-href (dom-attr a-tag 'href)))
    (if (string-suffix-p "index.html" a-href)
	(substring a-href 0 -10)
      (substring a-href 0 -5))))

(defun emacs-jest-parse--lcov-report-row (lcov-report-row)
  (let ((identifier (emacs-jest-parse--lcov-report-row-identifier lcov-report-row))
	(data (mapcar 'dom-text (cdr (cdr (dom-by-tag lcov-report-row 'td))))))
    (append (list identifier) data)))

;; Takes the lcov-report HTML and returns the rows to be rendered in a table
;; (("<identifier", "X%", "A/B", "Y%", "C/D"...),
;;  ("<identifier", "X%", "A/B", "Y%", "C/D"...)...)
(defun emacs-jest-parse--lcov-report-rows (lcov-report-html)
  (let* ((table-body (first (dom-by-tag lcov-report-html 'tbody)))
	 (table-rows (dom-by-tag table-body 'tr)))
    (mapcar 'emacs-jest-parse--lcov-report-row table-rows)))

(defun emacs-jest-parse--lcov-report-summary (lcov-report-html)
  (let ((meta (emacs-jest-parse--lcov-report-meta lcov-report-html))
	(rows (emacs-jest-parse--lcov-report-rows lcov-report-html)))
    (let ((desired-buffer-name (concat "coverage <" (first meta) ">")))
      (check-buffer-does-not-exist desired-buffer-name)

      (with-current-buffer (get-buffer-create desired-buffer-name)
	(switch-to-buffer desired-buffer-name)

	;; Insert metadata
	(insert (first meta))
	(newline)
	(insert (second meta))
	(newline)
	(newline)

	;; Insert table with coverage info
	(present-coverage-as-org-table
	 (list "File" "Statements Covered" "Statements" "Branches Covered" "Branches" "Functions Covered" "Functions" "Lines Covered" "Lines")
	 rows)))))

(defun emacs-jest-get-relevant-cline-class (dom-element)
  (let ((classes (dom-attr dom-element 'class)))
    (cond
     ((string-match-p (regexp-quote "cline-no") classes)
      "cline-no")
     ((string-match-p (regexp-quote "cline-yes") classes)
      "cline-yes"))))

(defun emacs-jest-format-line-annotation-content (dom-element)
  (replace-in-string "\u00A0" "" (dom-text dom-element)))

;; TODO - define minor mode to handle interactions + syntax highlighting
(defun emacs-jest-parse--lcov-report-file (lcov-report-html)
  (let* ((td-elements (dom-by-tag lcov-report-html 'td))
	 (line-coverage-section (second td-elements))
	 (obtained-line-coverage-items (dom-by-tag line-coverage-section 'span))
	 (line-coverage-items (mapcar (lambda (span-element)
					(list
					 (get-relevant-cline-class span-element)
					 (format-line-annotation-content span-element)))
				      obtained-line-coverage-items))
	 (longest-line-coverage-text-length (-max (mapcar (lambda (x) (length (second x))) line-coverage-items)))
	 (code-section (first (dom-by-tag (third td-elements) 'pre)))
	 (code-lines (split-string (dom-texts code-section) "\n"))
	 (code-lines-without-uncovered (split-string (dom-text code-section) "\n"))
	 (joined-code-coverage (-zip code-lines code-lines-without-uncovered))
	 (title-text (dom-text (first (dom-by-tag lcov-report-html 'h1))))
	 (filename (string-join
		    (-filter
		     (lambda (x) (not (string-equal "/" x)))
		     (split-string title-text))
		    " "))
	 (desired-buffer-name (concat "coverage <" filename ">")))
    (check-buffer-does-not-exist desired-buffer-name)

    (with-current-buffer (get-buffer-create desired-buffer-name)
      (switch-to-buffer desired-buffer-name)

      (linum-mode t)
      (setf linum-format
	    (lambda (line)
	      (let* ((annotation (nth (1- line) line-coverage-items))
		     (annotation-class (first annotation))
		     (annotation-content (second annotation))
		     (content (pad-string-until-length annotation-content (+ longest-line-coverage-text-length 1)))
		     (face-to-apply (cond
				     ((string-equal annotation-class "cline-no")
				      `((t (:background "red"))))
				     ((string-equal annotation-class "cline-yes")
				      `((t (:foreground "black" :background "green"))))
				      (t
				       'linum))))
		(propertize content 'face face-to-apply))))

      (mapc
       (lambda (joined-code-coverage-item)
	 (let ((code-content (car joined-code-coverage-item))
	       (code-without-uncovered (cdr joined-code-coverage-item)))
	   (insert (replace-in-string "\u00A0" "" code-content))

	   (cond
	    ;; Do nothing if there are no uncovered snippets in the current line
	    ((string-equal code-content code-without-uncovered))
	    ;; If entire line is uncovered
	    ((string-equal (string-trim code-without-uncovered) "")
	     (let ((start-index (line-beginning-position))
		   (end-index (+ (line-beginning-position) (length (string-trim-right code-content)))))
	       (put-text-property start-index end-index 'face (cons 'background-color "red"))))
	    ;; If uncovered section is at end of line
	    ((string-prefix-p code-without-uncovered code-content)
	     (let ((start-index (+ (line-beginning-position) (length code-without-uncovered)))
		   (end-index (+ (line-beginning-position) (length (string-trim-right code-content)))))
	       (put-text-property start-index end-index 'face (cons 'background-color "red"))

	       ;; Deleting the additional space that comes from dom-text/dom-texts difference
	       (goto-char start-index)
	       (delete-backward-char 1)
	       (move-end-of-line nil)))

	    ;; If uncovered section is in middle of line
	    (t
	     (let* ((start-of-deviation (index-of-first-deviating-character code-content code-without-uncovered))
		    (start-index (+ (line-beginning-position) start-of-deviation))
		    (end-of-deviation (index-of-first-deviating-character (reverse code-content) (reverse code-without-uncovered)))
		    (end-index (- (+ (line-beginning-position) (length (string-trim-right code-content))) end-of-deviation)))
	       (put-text-property start-index end-index 'face (cons 'background-color "red"))

	       ;; Deleting the additional spaces that come from dom-text/dom-texts difference
	       (goto-char start-index)
	       (delete-backward-char 1)
	       (goto-char end-index)
	       (delete-backward-char 1)
	       (move-end-of-line nil))))
	   (newline)))
       joined-code-coverage)

      ;; Deleting the last newline call as well as empty line at end of file
      (delete-backward-char 2)
      (beginning-of-buffer))))

(defun emacs-jest-parse--lcov-report (lcov-report-html)
  (if (dom-by-class lcov-report-html "coverage-summary")
      (emacs-jest-parse--lcov-report-summary lcov-report-html)
    (emacs-jest-parse--lcov-report-file lcov-report-html)))

(defun emacs-jest-parse--lcov-report-target (&optional target)
  (let* ((target-file (cond
		      ((null target)
		       "index.html")
		      ((string-suffix-p "/" target)
		       (concat target "index.html"))
		      (t
		       (concat target ".html"))))
	 (target-filepath (concat (projectile-project-root) emacs-jest-coverage-directory "/" target-file))
	 (xml-dom-tree (with-temp-buffer
			   (insert-file-contents target-filepath)
			   (libxml-parse-html-region (point-min) (point-max)))))
    (emacs-jest-parse--lcov-report xml-dom-tree)))

(defun emacs-jest-get-coverage ()
  (interactive)
  (emacs-jest-parse--lcov-report-target))

(defun emacs-jest-parse--coverage-target-from-buffer (target)
  (if (string-match-p (regexp-quote "<All files>") (buffer-name))
      target
    (concat (substring (buffer-name) (+ 1 (string-match-p (regexp-quote "<") (buffer-name))) -1) target)))

(defun emacs-jest-get-target-coverage ()
  (interactive)
  (when (org-table-p)
    (let* ((row-identifier (org-table-get nil 1))
	   (identifier (parse--coverage-target-from-buffer row-identifier)))
      (emacs-jest-parse--lcov-report-target identifier))))

(global-unset-key (kbd "C-c c"))
(global-set-key (kbd "C-c c") 'get-target-coverage)

(provide 'emacs-jest)
;;; emacs-jest.el ends here
