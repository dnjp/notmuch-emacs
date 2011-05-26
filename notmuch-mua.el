;; notmuch-mua.el --- emacs style mail-user-agent
;;
;; Copyright © David Edmondson
;;
;; This file is part of Notmuch.
;;
;; Notmuch is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Notmuch is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Notmuch.  If not, see <http://www.gnu.org/licenses/>.
;;
;; Authors: David Edmondson <dme@dme.org>

(require 'message)

(require 'notmuch-lib)
(require 'notmuch-address)

;;

(defcustom notmuch-mua-send-hook '(notmuch-mua-message-send-hook)
  "Hook run before sending messages."
  :group 'notmuch
  :type 'hook)

(defcustom notmuch-mua-user-agent-function 'notmuch-mua-user-agent-full
  "Function used to generate a `User-Agent:' string. If this is
`nil' then no `User-Agent:' will be generated."
  :group 'notmuch
  :type 'function
  :options '(notmuch-mua-user-agent-full
	     notmuch-mua-user-agent-notmuch
	     notmuch-mua-user-agent-emacs))

(defcustom notmuch-mua-hidden-headers '("^User-Agent:")
  "Headers that are added to the `message-mode' hidden headers
list."
  :group 'notmuch
  :type '(repeat string))

;;

(defun notmuch-mua-user-agent-full ()
  "Generate a `User-Agent:' string suitable for notmuch."
  (concat (notmuch-mua-user-agent-notmuch)
	  " "
	  (notmuch-mua-user-agent-emacs)))

(defun notmuch-mua-user-agent-notmuch ()
  "Generate a `User-Agent:' string suitable for notmuch."
  (concat "Notmuch/" (notmuch-version) " (http://notmuchmail.org)"))

(defun notmuch-mua-user-agent-emacs ()
  "Generate a `User-Agent:' string suitable for notmuch."
  (concat "Emacs/" emacs-version " (" system-configuration ")"))

(defun notmuch-mua-add-more-hidden-headers ()
  "Add some headers to the list that are hidden by default."
  (mapc (lambda (header)
	  (when (not (member header 'message-hidden-headers))
	    (push header message-hidden-headers)))
	notmuch-mua-hidden-headers))

(defun notmuch-mua-reply (query-string &optional sender)
  (let (headers
	body
	(args '("reply")))
    (if notmuch-show-process-crypto
	(setq args (append args '("--decrypt"))))
    (setq args (append args (list query-string)))
    ;; This make assumptions about the output of `notmuch reply', but
    ;; really only that the headers come first followed by a blank
    ;; line and then the body.
    (with-temp-buffer
      (apply 'call-process (append (list notmuch-command nil (list t t) nil) args))
      (goto-char (point-min))
      (if (re-search-forward "^$" nil t)
	  (save-excursion
	    (save-restriction
	      (narrow-to-region (point-min) (point))
	      (goto-char (point-min))
	      (setq headers (mail-header-extract)))))
      (forward-line 1)
      (setq body (buffer-substring (point) (point-max))))
    ;; If sender is non-nil, set the From: header to its value.
    (when sender
      (mail-header-set 'from sender headers))
    (let
	;; Overlay the composition window on that being used to read
	;; the original message.
	((same-window-regexps '("\\*mail .*")))
      (notmuch-mua-mail (mail-header 'to headers)
			(mail-header 'subject headers)
			(message-headers-to-generate headers t '(to subject))))
    ;; insert the message body - but put it in front of the signature
    ;; if one is present
    (goto-char (point-max))
    (if (re-search-backward message-signature-separator nil t)
	  (forward-line -1)
      (goto-char (point-max)))
    (insert body))
  (set-buffer-modified-p nil)

  (message-goto-body))

(defun notmuch-mua-forward-message ()
  (message-forward)

  (when notmuch-mua-user-agent-function
    (let ((user-agent (funcall notmuch-mua-user-agent-function)))
      (when (not (string= "" user-agent))
	(message-add-header (format "User-Agent: %s" user-agent)))))
  (message-sort-headers)
  (message-hide-headers)
  (set-buffer-modified-p nil)

  (message-goto-to))

(defun notmuch-mua-mail (&optional to subject other-headers continue
				   switch-function yank-action send-actions)
  "Invoke the notmuch mail composition window."
  (interactive)

  (when notmuch-mua-user-agent-function
    (let ((user-agent (funcall notmuch-mua-user-agent-function)))
      (when (not (string= "" user-agent))
	(push (cons "User-Agent" user-agent) other-headers))))

  (unless (mail-header 'from other-headers)
    (push (cons "From" (concat
			(notmuch-user-name) " <" (notmuch-user-primary-email) ">")) other-headers))

  (message-mail to subject other-headers continue
		switch-function yank-action send-actions)
  (message-sort-headers)
  (message-hide-headers)
  (set-buffer-modified-p nil)

  (message-goto-to))

(defcustom notmuch-identities nil
  "Identities that can be used as the From: address when composing a new message.

If this variable is left unset, then a list will be constructed from the
name and addresses configured in the notmuch configuration file."
  :group 'notmuch
  :type '(repeat string))

(defcustom notmuch-always-prompt-for-sender nil
  "Always prompt for the From: address when composing a new message."
  :group 'notmuch
  :type 'boolean)

(defun notmuch-mua-sender-collection ()
  (if notmuch-identities
      notmuch-identities
    (mapcar (lambda (address)
	      (concat (notmuch-user-name) " <" address ">"))
	    (cons (notmuch-user-primary-email) (notmuch-user-other-email)))))

(defvar notmuch-mua-sender-history nil)

(defun notmuch-mua-prompt-for-sender ()
  (interactive)
  (let ((collection (notmuch-mua-sender-collection)))
    (ido-completing-read "Send mail From: " collection
			 nil 'confirm nil 'notmuch-mua-sender-history (car collection))))

(defun notmuch-mua-new-mail (&optional prompt-for-sender)
  "Invoke the notmuch mail composition window.

If PROMPT-FOR-SENDER is non-nil, the user will be prompted for
the From: address first."
  (interactive "P")
  (let ((other-headers
	 (when (or prompt-for-sender notmuch-always-prompt-for-sender)
	   (list (cons 'from (notmuch-mua-prompt-for-sender))))))
    (notmuch-mua-mail nil nil other-headers)))

(defun notmuch-mua-new-forward-message (&optional prompt-for-sender)
  "Invoke the notmuch message forwarding window.

If PROMPT-FOR-SENDER is non-nil, the user will be prompted for
the From: address first."
  (interactive "P")
  (if (or prompt-for-sender notmuch-always-prompt-for-sender)
      (let* ((sender (notmuch-mua-prompt-for-sender))
	     (address-components (mail-extract-address-components sender))
	     (user-full-name (car address-components))
	     (user-mail-address (cadr address-components)))
	(notmuch-mua-forward-message))
    (notmuch-mua-forward-message)))

(defun notmuch-mua-new-reply (query-string &optional prompt-for-sender)
  "Invoke the notmuch reply window."
  (interactive "P")
  (let ((sender
	 (when (or prompt-for-sender notmuch-always-prompt-for-sender)
	   (notmuch-mua-prompt-for-sender))))
    (notmuch-mua-reply query-string sender)))

(defun notmuch-mua-send-and-exit (&optional arg)
  (interactive "P")
  (message-send-and-exit arg))

(defun notmuch-mua-kill-buffer ()
  (interactive)
  (message-kill-buffer))

(defun notmuch-mua-message-send-hook ()
  "The default function used for `notmuch-mua-send-hook', this
simply runs the corresponding `message-mode' hook functions."
  (run-hooks 'message-send-hook))

;;

(define-mail-user-agent 'notmuch-user-agent
  'notmuch-mua-mail 'notmuch-mua-send-and-exit
  'notmuch-mua-kill-buffer 'notmuch-mua-send-hook)

;; Add some more headers to the list that `message-mode' hides when
;; composing a message.
(notmuch-mua-add-more-hidden-headers)

;;

(provide 'notmuch-mua)
