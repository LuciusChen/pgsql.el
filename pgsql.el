;;; pgsql.el --- Native PostgreSQL protocol client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Lucius Chen <chenyh572@gmail.com>
;; Maintainer: Lucius Chen <chenyh572@gmail.com>
;; Assisted-by: OpenAI Codex:gpt-5.5
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, data
;; URL: https://github.com/LuciusChen/pgsql.el

;; This file is part of pgsql.el.

;; pgsql.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; pgsql.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with pgsql.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; pgsql.el is a synchronous PostgreSQL protocol 3.0 client.  It keeps
;; framing, authentication, request synchronization, type conversion, and
;; cancellation behind a small public API.  A request returns or signals only
;; after its ReadyForQuery message has been consumed.

;;; Code:

(require 'cl-lib)
(require 'gnutls)
(require 'json)
(require 'parse-time)
(require 'pgsql-saslprep)
(require 'subr-x)

(defgroup pgsql nil
  "Native PostgreSQL protocol client."
  :group 'data)

(defcustom pgsql-connect-timeout 10
  "Maximum seconds to establish and authenticate a connection.
Zero means no timeout."
  :type 'number
  :group 'pgsql)

(defcustom pgsql-read-timeout 30
  "Maximum idle seconds while waiting for a PostgreSQL response.
Zero means no timeout."
  :type 'number
  :group 'pgsql)

(defconst pgsql--cancel-recovery-timeout 10
  "Maximum seconds to cancel and resynchronize an interrupted request.")

(defcustom pgsql-sslmode 'prefer
  "Default PostgreSQL transport security mode."
  :type '(choice (const disable) (const prefer) (const require)
                 (const verify-full))
  :group 'pgsql)

(defcustom pgsql-application-name "pgsql.el"
  "Application name reported to PostgreSQL during startup."
  :type 'string
  :group 'pgsql)

(defun pgsql--timeout-p (value)
  "Return non-nil when VALUE is a valid nonnegative timeout in seconds."
  (and (numberp value) (>= value 0)))

(defcustom pgsql-max-message-bytes (* 128 1024 1024)
  "Largest accepted PostgreSQL message, including its length word."
  :type 'natnum
  :group 'pgsql)

(defvar pgsql-notice-functions nil
  "Functions called with a connection and a PostgreSQL notice plist.")

(defconst pgsql-null (make-symbol "pgsql-null")
  "Unique value representing SQL NULL in parameters and results.")

(defun pgsql-null-p (value)
  "Return non-nil when VALUE represents SQL NULL."
  (eq value pgsql-null))

(define-error 'pgsql-error "PostgreSQL error")
(define-error 'pgsql-connection-error "PostgreSQL connection error" 'pgsql-error)
(define-error 'pgsql-timeout "PostgreSQL timeout" 'pgsql-connection-error)
(define-error 'pgsql-protocol-error "PostgreSQL protocol error" 'pgsql-error)
(define-error 'pgsql-authentication-error "PostgreSQL authentication error" 'pgsql-error)
(define-error 'pgsql-server-error "PostgreSQL server error" 'pgsql-error)

(cl-defstruct (pgsql-connection
               (:constructor pgsql--make-connection)
               (:conc-name pgsql--connection-)
               (:predicate pgsql--connection-p)
               (:copier nil))
  "Opaque PostgreSQL connection state."
  process
  input-buffer
  (read-position 1)
  host
  port
  user
  database
  sslmode
  connect-timeout
  connect-deadline
  read-timeout
  application-name
  parameters
  backend-pid
  secret-key
  transaction-status
  busy-p
  broken-p
  closing-p)

(cl-defstruct (pgsql-result
               (:constructor pgsql--make-result)
               (:conc-name pgsql--result-)
               (:predicate pgsql--result-p)
               (:copier nil))
  "Result of a PostgreSQL query."
  columns
  rows
  command-tag
  affected-rows)

(defun pgsql-connection-p (value)
  "Return non-nil when VALUE is a PostgreSQL connection."
  (pgsql--connection-p value))

(defun pgsql-result-p (value)
  "Return non-nil when VALUE is a PostgreSQL result."
  (pgsql--result-p value))

(defun pgsql-result-columns (result)
  "Return column metadata from RESULT."
  (pgsql--result-columns result))

(defun pgsql-result-rows (result)
  "Return decoded rows from RESULT."
  (pgsql--result-rows result))

(defun pgsql-result-command-tag (result)
  "Return PostgreSQL's command tag from RESULT."
  (pgsql--result-command-tag result))

(defun pgsql-result-affected-rows (result)
  "Return the affected-row count from RESULT, or nil."
  (pgsql--result-affected-rows result))

(defconst pgsql--error-field-names
  '((?S . :severity-localized)
    (?V . :severity)
    (?C . :sqlstate)
    (?M . :message)
    (?D . :detail)
    (?H . :hint)
    (?P . :position)
    (?p . :internal-position)
    (?q . :internal-query)
    (?W . :where)
    (?s . :schema)
    (?t . :table)
    (?c . :column)
    (?d . :data-type)
    (?n . :constraint)
    (?F . :file)
    (?L . :line)
    (?R . :routine))
  "Mapping from ErrorResponse field bytes to public plist keys.")

(defconst pgsql--type-names
  '((16 . "bool") (17 . "bytea") (18 . "char") (19 . "name")
    (20 . "int8") (21 . "int2") (23 . "int4") (25 . "text")
    (26 . "oid") (114 . "json") (142 . "xml") (199 . "_json")
    (700 . "float4") (701 . "float8") (790 . "money")
    (1000 . "_bool") (1001 . "_bytea") (1002 . "_char")
    (1003 . "_name") (1005 . "_int2") (1007 . "_int4")
    (1009 . "_text") (1014 . "_bpchar") (1015 . "_varchar")
    (1016 . "_int8") (1021 . "_float4") (1022 . "_float8")
    (1028 . "_oid") (1042 . "bpchar") (1043 . "varchar")
    (1082 . "date") (1083 . "time") (1114 . "timestamp")
    (1115 . "_timestamp") (1182 . "_date") (1183 . "_time")
    (1184 . "timestamptz") (1185 . "_timestamptz")
    (1186 . "interval") (1231 . "_numeric") (1700 . "numeric")
    (2950 . "uuid") (2951 . "_uuid") (3802 . "jsonb")
    (3807 . "_jsonb"))
  "Names for PostgreSQL core type OIDs handled by pgsql.el.")

(defconst pgsql--type-oids
  (append
   (mapcar (lambda (entry) (cons (cdr entry) (car entry)))
           pgsql--type-names)
   '(("boolean" . 16)
     ("smallint" . 21)
     ("integer" . 23)
     ("bigint" . 20)
     ("real" . 700)
     ("double precision" . 701)
     ("decimal" . 1700)
     ("character" . 1042)
     ("character varying" . 1043)
     ("boolean[]" . 1000)
     ("smallint[]" . 1005)
     ("integer[]" . 1007)
     ("bigint[]" . 1016)
     ("real[]" . 1021)
     ("double precision[]" . 1022)
     ("decimal[]" . 1231)
     ("character[]" . 1014)
     ("character varying[]" . 1015)))
  "PostgreSQL built-in parameter type names mapped to OIDs.")

(defconst pgsql--array-element-oids
  '((199 . 114) (1000 . 16) (1001 . 17) (1002 . 18) (1003 . 19)
    (1005 . 21) (1007 . 23) (1009 . 25) (1014 . 1042) (1015 . 1043)
    (1016 . 20) (1021 . 700) (1022 . 701) (1028 . 26) (1115 . 1114)
    (1182 . 1082) (1183 . 1083) (1185 . 1184) (1231 . 1700)
    (2951 . 2950) (3807 . 3802))
  "Mapping from PostgreSQL array OIDs to element OIDs.")

;;;; Byte framing

(defun pgsql--uint16 (number)
  "Encode NUMBER as an unsigned 16-bit network integer."
  (unibyte-string (logand (ash number -8) 255)
                  (logand number 255)))

(defun pgsql--uint32 (number)
  "Encode NUMBER as an unsigned 32-bit network integer."
  (unibyte-string (logand (ash number -24) 255)
                  (logand (ash number -16) 255)
                  (logand (ash number -8) 255)
                  (logand number 255)))

(defun pgsql--read-uint16 (bytes offset)
  "Read an unsigned 16-bit integer from BYTES at OFFSET."
  (+ (ash (aref bytes offset) 8)
     (aref bytes (1+ offset))))

(defun pgsql--read-uint32 (bytes offset)
  "Read an unsigned 32-bit integer from BYTES at OFFSET."
  (+ (ash (aref bytes offset) 24)
     (ash (aref bytes (+ offset 1)) 16)
     (ash (aref bytes (+ offset 2)) 8)
     (aref bytes (+ offset 3))))

(defun pgsql--read-int16 (bytes offset)
  "Read a signed 16-bit integer from BYTES at OFFSET."
  (let ((value (pgsql--read-uint16 bytes offset)))
    (if (>= value #x8000) (- value #x10000) value)))

(defun pgsql--read-int32 (bytes offset)
  "Read a signed 32-bit integer from BYTES at OFFSET."
  (let ((value (pgsql--read-uint32 bytes offset)))
    (if (>= value #x80000000) (- value #x100000000) value)))

(defun pgsql--text-bytes (text)
  "Encode TEXT as unibyte UTF-8."
  (encode-coding-string text 'utf-8 t))

(defun pgsql--cstring (text)
  "Encode TEXT as a UTF-8 C string."
  (when (string-search (string 0) text)
    (signal 'pgsql-error (list "PostgreSQL C strings cannot contain NUL")))
  (concat (pgsql--text-bytes text) (unibyte-string 0)))

(defun pgsql--validate-sql (sql)
  "Validate SQL for a PostgreSQL frontend query message."
  (unless (stringp sql)
    (signal 'wrong-type-argument (list 'stringp sql)))
  (when (string-search (string 0) sql)
    (signal 'pgsql-error (list "PostgreSQL SQL cannot contain NUL"))))

(defun pgsql--message (type payload)
  "Return a frontend message of TYPE containing PAYLOAD."
  (concat (unibyte-string type)
          (pgsql--uint32 (+ 4 (string-bytes payload)))
          payload))

(defun pgsql--receive (connection bytes)
  "Append process filter BYTES to CONNECTION without parsing them."
  (when (buffer-live-p (pgsql--connection-input-buffer connection))
    (with-current-buffer (pgsql--connection-input-buffer connection)
      (goto-char (point-max))
      (insert (encode-coding-string bytes 'binary t)))))

(defun pgsql--available-bytes (connection)
  "Return unread byte count buffered for CONNECTION."
  (with-current-buffer (pgsql--connection-input-buffer connection)
    (- (point-max) (pgsql--connection-read-position connection))))

(defun pgsql--compact-input (connection)
  "Discard bytes already consumed by CONNECTION when worthwhile."
  (let ((position (pgsql--connection-read-position connection)))
    (when (> position 65536)
      (with-current-buffer (pgsql--connection-input-buffer connection)
        (delete-region (point-min) position))
      (setf (pgsql--connection-read-position connection) 1))))

(defun pgsql--take-bytes (connection count)
  "Consume and return COUNT buffered bytes from CONNECTION."
  (when (>= (pgsql--available-bytes connection) count)
    (let* ((start (pgsql--connection-read-position connection))
           (end (+ start count))
           (bytes (with-current-buffer (pgsql--connection-input-buffer connection)
                    (buffer-substring-no-properties start end))))
      (setf (pgsql--connection-read-position connection) end)
      (pgsql--compact-input connection)
      bytes)))

(defun pgsql--take-message (connection)
  "Consume one complete backend message from CONNECTION, or return nil."
  (when (>= (pgsql--available-bytes connection) 5)
    (let* ((start (pgsql--connection-read-position connection))
           (header (with-current-buffer (pgsql--connection-input-buffer connection)
                     (buffer-substring-no-properties start (+ start 5))))
           (type (aref header 0))
           (length (pgsql--read-uint32 header 1)))
      (when (< length 4)
        (signal 'pgsql-protocol-error
                (list (format "Invalid PostgreSQL message length: %d" length))))
      (when (> length pgsql-max-message-bytes)
        (signal 'pgsql-protocol-error
                (list (format "PostgreSQL message exceeds %d bytes"
                              pgsql-max-message-bytes))))
      (when (>= (pgsql--available-bytes connection) (1+ length))
        (pgsql--take-bytes connection 5)
        (cons type (pgsql--take-bytes connection (- length 4)))))))

(defun pgsql--remaining-time (deadline)
  "Return seconds remaining before DEADLINE, or nil without a deadline."
  (when deadline
    (max 0.0 (- deadline (float-time)))))

(defun pgsql--wait-for-input (connection deadline)
  "Wait for more bytes on CONNECTION until DEADLINE."
  (let ((process (pgsql--connection-process connection))
        (remaining (pgsql--remaining-time deadline)))
    (unless (process-live-p process)
      (signal 'pgsql-connection-error
              (list "PostgreSQL connection closed while reading")))
    (when (and remaining (zerop remaining))
      (signal 'pgsql-timeout (list "PostgreSQL response timed out")))
    (accept-process-output process remaining)))

(defun pgsql--read-bytes (connection count &optional timeout deadline)
  "Read COUNT bytes from CONNECTION within TIMEOUT or before DEADLINE."
  (let ((deadline (or deadline
                      (and timeout (> timeout 0) (+ (float-time) timeout))))
        bytes)
    (while (not (setq bytes (pgsql--take-bytes connection count)))
      (pgsql--wait-for-input connection deadline))
    bytes))

(defun pgsql--read-message (connection &optional timeout deadline)
  "Read a CONNECTION message within TIMEOUT or before absolute DEADLINE."
  (let ((deadline (or deadline
                      (and timeout (> timeout 0) (+ (float-time) timeout))))
        message)
    (while (not (setq message (pgsql--take-message connection)))
      (pgsql--wait-for-input connection deadline))
    message))

(defun pgsql--read-message-idle (connection timeout)
  "Read one backend message from CONNECTION with idle TIMEOUT seconds.
Progress receiving a fragmented message restarts the timeout."
  (let* ((available (pgsql--available-bytes connection))
         (deadline (and (> timeout 0) (+ (float-time) timeout)))
         message)
    (while (not (setq message (pgsql--take-message connection)))
      (pgsql--wait-for-input connection deadline)
      (let ((now-available (pgsql--available-bytes connection)))
        (when (> now-available available)
          (setq available now-available
                deadline (and (> timeout 0) (+ (float-time) timeout))))))
    message))

(defun pgsql--send (connection bytes)
  "Send unibyte BYTES over CONNECTION."
  (unless (process-live-p (pgsql--connection-process connection))
    (signal 'pgsql-connection-error (list "PostgreSQL connection is closed")))
  (process-send-string (pgsql--connection-process connection) bytes))

(defun pgsql--cstring-at (bytes offset)
  "Return a C string and next offset from BYTES starting at OFFSET."
  (let ((end (string-search (unibyte-string 0) bytes offset)))
    (unless end
      (signal 'pgsql-protocol-error (list "Unterminated PostgreSQL string")))
    (cons (decode-coding-string (substring bytes offset end) 'utf-8)
          (1+ end))))

(defun pgsql--cstrings (bytes &optional offset)
  "Return all C strings in BYTES beginning at OFFSET."
  (let ((offset (or offset 0))
        values)
    (while (< offset (length bytes))
      (pcase-let ((`(,value . ,next) (pgsql--cstring-at bytes offset)))
        (setq offset next)
        (if (string-empty-p value)
            (unless (= offset (length bytes))
              (signal 'pgsql-protocol-error
                      (list "Data follows a PostgreSQL string terminator")))
          (push value values))))
    (nreverse values)))

;;;; Connection transport and startup

(defun pgsql--process-sentinel (connection process _event)
  "Update CONNECTION when PROCESS exits unexpectedly."
  (when (and (eq process (pgsql--connection-process connection))
             (not (pgsql--connection-closing-p connection))
             (memq (process-status process) '(closed failed exit signal)))
    (setf (pgsql--connection-broken-p connection) t)
    ;; An active request owns cleanup so it may first consume bytes already
    ;; delivered by the process filter.  With no request, nothing can consume
    ;; the hidden input buffer after the peer disappears.
    (unless (pgsql--connection-busy-p connection)
      (setf (pgsql--connection-closing-p connection) t)
      (when (buffer-live-p (pgsql--connection-input-buffer connection))
        (kill-buffer (pgsql--connection-input-buffer connection))))))

(defun pgsql--await-process-open (process deadline label)
  "Wait until DEADLINE for PROCESS to connect.
LABEL identifies the operation in connection errors."
  (while (eq (process-status process) 'connect)
    (let ((remaining (pgsql--remaining-time deadline)))
      (when (and remaining (zerop remaining))
        (signal 'pgsql-timeout (list (format "%s timed out" label))))
      (accept-process-output process
                             (if remaining (min remaining 0.05) 0.05))))
  (unless (memq (process-status process) '(open run))
    (signal 'pgsql-connection-error
            (list (format "%s failed: %s" label (process-status process)))))
  process)

(defun pgsql--open-process (connection)
  "Open the TCP process owned by CONNECTION."
  (let ((process
          (make-network-process
           :name (format "pgsql:%s:%s"
                         (pgsql--connection-host connection)
                         (pgsql--connection-port connection))
           :host (pgsql--connection-host connection)
           :service (pgsql--connection-port connection)
           :coding 'binary
           :nowait t
           :noquery t
           :filter (lambda (_process bytes)
                     (pgsql--receive connection bytes))
           :sentinel (lambda (process event)
                       (pgsql--process-sentinel connection process event))))
         (deadline (pgsql--connection-connect-deadline connection)))
    (setf (pgsql--connection-process connection) process)
    (set-process-query-on-exit-flag process nil)
    (pgsql--await-process-open process deadline "PostgreSQL connection")))

(defun pgsql--tls-options (connection)
  "Return GnuTLS negotiation options for CONNECTION."
  (append (list :process (pgsql--connection-process connection)
                :hostname (pgsql--connection-host connection))
          (when (eq (pgsql--connection-sslmode connection) 'verify-full)
            '(:verify-error t :verify-hostname-error t))))

(defun pgsql--negotiate-tls (connection)
  "Apply CONNECTION's PostgreSQL SSL negotiation mode."
  (unless (eq (pgsql--connection-sslmode connection) 'disable)
    (unless (gnutls-available-p)
      (signal 'pgsql-connection-error
              (list "PostgreSQL TLS requires GnuTLS support in Emacs")))
    (pgsql--send connection
                 (concat (pgsql--uint32 8) (pgsql--uint32 80877103)))
    (pcase (aref (pgsql--read-bytes
                  connection 1 nil
                  (pgsql--connection-connect-deadline connection))
                 0)
      (?S
       (unless (zerop (pgsql--available-bytes connection))
         (signal 'pgsql-protocol-error
                 (list "PostgreSQL sent plaintext after the TLS response")))
       (condition-case err
           (let ((remaining
                  (pgsql--remaining-time
                   (pgsql--connection-connect-deadline connection))))
             (when (and remaining (zerop remaining))
               (signal 'pgsql-timeout
                       (list "PostgreSQL TLS negotiation timed out")))
             (if remaining
                 (with-timeout
                     (remaining
                      (signal 'pgsql-timeout
                              (list "PostgreSQL TLS negotiation timed out")))
                   (apply #'gnutls-negotiate
                          (pgsql--tls-options connection)))
               (apply #'gnutls-negotiate (pgsql--tls-options connection))))
         (gnutls-error
          (signal 'pgsql-connection-error
                  (list (format "PostgreSQL TLS negotiation failed: %s"
                                (error-message-string err)))))))
      (?N
       (unless (eq (pgsql--connection-sslmode connection) 'prefer)
         (signal 'pgsql-connection-error
                 (list "PostgreSQL server refused TLS"))))
      (response
       (signal 'pgsql-protocol-error
               (list (format "Invalid PostgreSQL SSL response: %S" response)))))))

(defun pgsql--startup-message (user database application-name)
  "Build a StartupMessage for USER, DATABASE, and APPLICATION-NAME."
  (let ((payload (concat (pgsql--uint32 #x00030000)
                         (pgsql--cstring "user") (pgsql--cstring user)
                         (pgsql--cstring "database") (pgsql--cstring database)
                         (pgsql--cstring "application_name")
                         (pgsql--cstring application-name)
                         (pgsql--cstring "client_encoding")
                         (pgsql--cstring "UTF8")
                         (pgsql--cstring "DateStyle")
                         (pgsql--cstring "ISO")
                         (unibyte-string 0))))
    (concat (pgsql--uint32 (+ 4 (string-bytes payload))) payload)))

(defun pgsql--error-fields (payload)
  "Parse ErrorResponse or NoticeResponse PAYLOAD into a plist."
  (let ((offset 0)
        fields)
    (while (< offset (length payload))
      (let ((code (aref payload offset)))
        (cl-incf offset)
        (if (zerop code)
            (unless (= offset (length payload))
              (signal 'pgsql-protocol-error
                      (list "Data follows PostgreSQL error terminator")))
          (pcase-let ((`(,value . ,next) (pgsql--cstring-at payload offset)))
            (setq offset next)
            (setq fields
                  (plist-put fields
                             (or (alist-get code pgsql--error-field-names)
                                 (intern (format ":field-%c" code)))
                             value))))))
    fields))

(defun pgsql--server-error-message (fields)
  "Return the primary error string from PostgreSQL FIELDS."
  (let ((severity (or (plist-get fields :severity)
                      (plist-get fields :severity-localized)))
        (message (or (plist-get fields :message) "PostgreSQL server error"))
        (sqlstate (plist-get fields :sqlstate)))
    (string-join (delq nil (list severity message
                                  (and sqlstate (format "[%s]" sqlstate))))
                 ": ")))

(defun pgsql--signal-server-error (fields)
  "Signal a structured server error using FIELDS."
  (signal 'pgsql-server-error
          (list (pgsql--server-error-message fields) fields)))

(defun pgsql-error-fields (error-value)
  "Return structured fields from caught PostgreSQL ERROR-VALUE.
ERROR-VALUE is the value bound by `condition-case'."
  (when (eq (car-safe error-value) 'pgsql-server-error)
    (nth 2 error-value)))

(defun pgsql--parse-parameter-status (connection payload)
  "Record one ParameterStatus PAYLOAD on CONNECTION."
  (pcase-let* ((`(,name . ,value-offset) (pgsql--cstring-at payload 0))
               (`(,value . ,end) (pgsql--cstring-at payload value-offset)))
    (unless (= end (length payload))
      (signal 'pgsql-protocol-error
              (list "Invalid PostgreSQL ParameterStatus message")))
    (puthash name value (pgsql--connection-parameters connection))))

(defun pgsql--handle-side-message (connection type payload)
  "Handle an asynchronous TYPE and PAYLOAD for CONNECTION.
Return non-nil when the message was handled."
  (pcase type
    (?N
     (run-hook-with-args 'pgsql-notice-functions
                         connection (pgsql--error-fields payload))
     t)
    (?S
     (pgsql--parse-parameter-status connection payload)
     t)
    (_ nil)))

;;;; Authentication

(defun pgsql--password-string (password)
  "Resolve PASSWORD to a string."
  (let ((value (if (functionp password) (funcall password) password)))
    (cond
     ((stringp value)
      (when (string-search (string 0) value)
        (signal 'pgsql-authentication-error
                (list "PostgreSQL passwords cannot contain NUL")))
      value)
     ((null value) "")
     (t (signal 'pgsql-authentication-error
                (list "PostgreSQL password is not a string"))))))

(defun pgsql--password-message (payload &optional cstring-p)
  "Build a PasswordMessage containing PAYLOAD.
Append a zero byte when CSTRING-P is non-nil."
  (pgsql--message ?p
                  (if cstring-p
                      (concat (encode-coding-string payload 'binary t)
                              (unibyte-string 0))
                    (encode-coding-string payload 'binary t))))

(defun pgsql--md5-password (user password salt)
  "Return PostgreSQL's MD5 response for USER, PASSWORD, and SALT."
  (concat "md5" (md5 (concat (md5 (concat password user)) salt))))

(defun pgsql--xor-bytes (left right)
  "Return the bytewise XOR of equal-length strings LEFT and RIGHT."
  (unless (= (string-bytes left) (string-bytes right))
    (signal 'pgsql-protocol-error (list "SCRAM byte strings differ in length")))
  (let ((result (make-string (string-bytes left) 0)))
    (cl-loop for position below (length result)
             do (aset result position
                      (logxor (aref left position) (aref right position))))
    result))

(defun pgsql--hmac-sha256 (key data)
  "Return raw HMAC-SHA-256 for KEY and DATA."
  (gnutls-hash-mac 'SHA256 (copy-sequence key) data))

(defconst pgsql--max-scram-iterations 1000000
  "Largest accepted PostgreSQL SCRAM iteration count.")

(defun pgsql--pbkdf2-sha256 (password salt iterations &optional deadline)
  "Return PBKDF2-HMAC-SHA-256 for PASSWORD, SALT, and ITERATIONS.
When non-nil, DEADLINE bounds the synchronous computation."
  (unless (> iterations 0)
    (signal 'pgsql-authentication-error
            (list "PostgreSQL SCRAM iteration count is not positive")))
  (let* ((first (pgsql--hmac-sha256
                 password (concat salt (pgsql--uint32 1))))
         (previous first)
         (result (copy-sequence first)))
    (cl-loop for iteration from 1 below iterations
             do
      (when (and deadline
                 (zerop (logand iteration 255))
                 (zerop (pgsql--remaining-time deadline)))
        (signal 'pgsql-timeout
                (list "PostgreSQL SCRAM authentication timed out")))
      (setq previous (pgsql--hmac-sha256 password previous)
            result (pgsql--xor-bytes result previous))
             finally return result)))

(defun pgsql--scram-escape (text)
  "Escape TEXT for a SCRAM username attribute."
  (string-replace "," "=2C" (string-replace "=" "=3D" text)))

(defun pgsql--nonce ()
  "Return a fresh printable SCRAM nonce."
  (substring
   (base64-encode-string
    (secure-hash 'sha256
                 (format "%s:%s:%s:%s"
                         (current-time) (emacs-pid) (random) (user-uid))
                 nil nil t)
    t)
   0 32))

(defvar pgsql--nonce-function #'pgsql--nonce
  "Function used to generate a SCRAM nonce.")

(defun pgsql--scram-start (user)
  "Return SCRAM state and SASL initial payload for USER."
  (let* ((nonce (funcall pgsql--nonce-function))
         (bare (format "n=%s,r=%s" (pgsql--scram-escape user) nonce))
         (first (concat "n,," bare)))
    (cons (list :nonce nonce :client-first-bare bare)
          (concat (pgsql--cstring "SCRAM-SHA-256")
                  (pgsql--uint32 (string-bytes first))
                  (pgsql--text-bytes first)))))

(defun pgsql--scram-attributes (message)
  "Parse SCRAM MESSAGE into an alist of one-character keys."
  (mapcar
   (lambda (part)
     (unless (and (>= (length part) 3) (= (aref part 1) ?=))
       (signal 'pgsql-authentication-error
               (list "Malformed PostgreSQL SCRAM attribute")))
     (cons (aref part 0) (substring part 2)))
   (split-string message "," t)))

(defun pgsql--scram-continue (state password server-first &optional deadline)
  "Return updated SCRAM STATE and response for SERVER-FIRST.
Use PASSWORD to compute the client proof before optional DEADLINE."
  (let* ((attributes (pgsql--scram-attributes server-first))
         (nonce (alist-get ?r attributes))
         (salt64 (alist-get ?s attributes))
         (iterations-text (alist-get ?i attributes))
         (client-nonce (plist-get state :nonce)))
    (unless (and nonce salt64 iterations-text
                 (string-prefix-p client-nonce nonce)
                 (> (length nonce) (length client-nonce)))
      (signal 'pgsql-authentication-error
              (list "Invalid PostgreSQL SCRAM server-first message")))
    (unless (and (<= (length iterations-text) 7)
                 (string-match-p "\\`[0-9]+\\'" iterations-text)
                 (> (string-to-number iterations-text) 0)
                 (<= (string-to-number iterations-text)
                     pgsql--max-scram-iterations))
      (signal 'pgsql-authentication-error
              (list "Invalid PostgreSQL SCRAM iteration count")))
    (let* ((salt (condition-case nil
                     (base64-decode-string salt64)
                   (error
                    (signal 'pgsql-authentication-error
                            (list "Invalid PostgreSQL SCRAM salt")))))
           (iterations (string-to-number iterations-text))
           (prepared-password (pgsql--saslprep password))
           (salted (pgsql--pbkdf2-sha256
                    prepared-password salt iterations deadline))
           (client-key (pgsql--hmac-sha256 salted "Client Key"))
           (stored-key (secure-hash 'sha256 client-key nil nil t))
           (server-key (pgsql--hmac-sha256 salted "Server Key"))
           (final-bare (format "c=biws,r=%s" nonce))
           (auth-message (string-join
                          (list (plist-get state :client-first-bare)
                                server-first final-bare)
                          ","))
           (client-signature (pgsql--hmac-sha256 stored-key auth-message))
           (proof (pgsql--xor-bytes client-key client-signature))
           (server-signature (pgsql--hmac-sha256 server-key auth-message))
           (response (format "%s,p=%s" final-bare
                             (base64-encode-string proof t))))
      (cons (plist-put state :server-signature server-signature)
            (pgsql--text-bytes response)))))

(defun pgsql--scram-finish (state server-final)
  "Verify SERVER-FINAL against SCRAM STATE."
  (let* ((attributes (pgsql--scram-attributes server-final))
         (server-error (alist-get ?e attributes))
         (verifier (alist-get ?v attributes)))
    (when server-error
      (signal 'pgsql-authentication-error
              (list (format "PostgreSQL SCRAM failed: %s" server-error))))
    (unless (and verifier
                 (string= verifier
                          (base64-encode-string
                           (plist-get state :server-signature) t)))
      (signal 'pgsql-authentication-error
              (list "PostgreSQL SCRAM server signature is invalid")))))

(defun pgsql--authentication-request
    (connection payload user password scram-state &optional deadline)
  "Handle AuthenticationRequest PAYLOAD for CONNECTION.
USER and PASSWORD are startup credentials.  Return updated SCRAM-STATE.
Optional DEADLINE bounds SCRAM proof computation."
  (when (< (length payload) 4)
    (signal 'pgsql-protocol-error
            (list "Invalid PostgreSQL AuthenticationRequest")))
  (let ((method (pgsql--read-uint32 payload 0)))
    (pcase method
      (0
       (when (and scram-state (not (plist-get scram-state :verified)))
         (signal 'pgsql-authentication-error
                 (list "PostgreSQL did not verify its SCRAM identity")))
       scram-state)
      (3
       (pgsql--send connection (pgsql--password-message password t))
       scram-state)
      (5
       (unless (= (length payload) 8)
         (signal 'pgsql-protocol-error
                 (list "Invalid PostgreSQL MD5 authentication request")))
       (pgsql--send connection
                    (pgsql--password-message
                     (pgsql--md5-password user password (substring payload 4)) t))
       scram-state)
      (10
       (unless (member "SCRAM-SHA-256" (pgsql--cstrings payload 4))
         (signal 'pgsql-authentication-error
                 (list "PostgreSQL server offers no supported SASL mechanism")))
       (pcase-let ((`(,state . ,initial) (pgsql--scram-start user)))
         (pgsql--send connection (pgsql--password-message initial))
         state))
      (11
       (unless scram-state
         (signal 'pgsql-protocol-error
                 (list "Unexpected PostgreSQL SCRAM continuation")))
       (pcase-let ((`(,state . ,response)
                     (pgsql--scram-continue
                     scram-state password
                      (decode-coding-string (substring payload 4) 'utf-8)
                      deadline)))
         (pgsql--send connection (pgsql--password-message response))
         state))
      (12
       (unless scram-state
         (signal 'pgsql-protocol-error
                 (list "Unexpected PostgreSQL SCRAM final message")))
       (pgsql--scram-finish
        scram-state (decode-coding-string (substring payload 4) 'utf-8))
       (plist-put scram-state :verified t))
      (_
       (signal 'pgsql-authentication-error
               (list (format "Unsupported PostgreSQL authentication method: %d"
                             method)))))))

(defun pgsql--ready-status (payload)
  "Return transaction status symbol represented by ReadyForQuery PAYLOAD."
  (unless (= (length payload) 1)
    (signal 'pgsql-protocol-error
            (list "Invalid PostgreSQL ReadyForQuery message")))
  (pcase (aref payload 0)
    (?I 'idle)
    (?T 'in-transaction)
    (?E 'failed-transaction)
    (status
     (signal 'pgsql-protocol-error
             (list (format "Invalid PostgreSQL transaction status: %S" status))))))

(defun pgsql--startup (connection password)
  "Authenticate and synchronize CONNECTION using PASSWORD."
  (let ((deadline (pgsql--connection-connect-deadline connection))
        scram-state
        authenticated)
    (pgsql--send
     connection
     (pgsql--startup-message
      (pgsql--connection-user connection)
      (pgsql--connection-database connection)
      (pgsql--connection-application-name connection)))
    (cl-loop
     for message = (pgsql--read-message connection nil deadline)
     for type = (car message)
     for payload = (cdr message)
     do
     (pcase type
       (?R
        (when authenticated
          (signal 'pgsql-protocol-error
                  (list "PostgreSQL sent authentication after AuthenticationOk")))
        (setq scram-state
              (pgsql--authentication-request
               connection payload (pgsql--connection-user connection)
               password scram-state deadline))
        (when (zerop (pgsql--read-uint32 payload 0))
          (setq authenticated t)))
       (?K
        (unless (= (length payload) 8)
          (signal 'pgsql-protocol-error
                  (list "Invalid PostgreSQL BackendKeyData message")))
        (setf (pgsql--connection-backend-pid connection)
              (pgsql--read-uint32 payload 0)
              (pgsql--connection-secret-key connection)
              (pgsql--read-uint32 payload 4)))
       (?E
        (pgsql--signal-server-error (pgsql--error-fields payload)))
       (?Z
        (unless authenticated
          (signal 'pgsql-authentication-error
                  (list "PostgreSQL became ready before authentication completed")))
        (when (and scram-state (not (plist-get scram-state :verified)))
          (signal 'pgsql-authentication-error
                  (list "PostgreSQL did not verify its SCRAM identity")))
        (setf (pgsql--connection-transaction-status connection)
              (pgsql--ready-status payload)
              (pgsql--connection-busy-p connection) nil)
        (cl-return connection))
       (?v
        (unless (>= (length payload) 8)
          (signal 'pgsql-protocol-error
                  (list "Invalid PostgreSQL protocol negotiation message")))
        (let ((minor-version (pgsql--read-uint32 payload 0))
              (option-count (pgsql--read-uint32 payload 4))
              (unsupported-options (pgsql--cstrings payload 8)))
          (unless (and (zerop minor-version)
                       (= option-count (length unsupported-options))
                       (zerop option-count))
          (signal 'pgsql-protocol-error
                    (list "PostgreSQL rejected protocol 3.0 startup options")))))
       (_
        (unless (pgsql--handle-side-message connection type payload)
          (signal 'pgsql-protocol-error
                  (list (format "Unexpected PostgreSQL startup message: %c"
                                type)))))))))

;;;; Text codecs

(defun pgsql-type-name (oid)
  "Return the built-in PostgreSQL type name for OID, or nil."
  (alist-get oid pgsql--type-names))

(defun pgsql-column-name (column)
  "Return COLUMN's name."
  (plist-get column :name))

(defun pgsql-column-type-oid (column)
  "Return COLUMN's PostgreSQL type OID."
  (plist-get column :type-oid))

(defun pgsql-column-type-name (column)
  "Return COLUMN's built-in PostgreSQL type name, or nil."
  (pgsql-type-name (pgsql-column-type-oid column)))

(defun pgsql--decode-bytea (text)
  "Decode PostgreSQL hex or escape BYTEA TEXT into an unibyte string."
  (if (string-prefix-p "\\x" text)
      (let* ((hex (substring text 2))
             (length (length hex))
             (bytes (make-string (/ length 2) 0)))
        (unless (zerop (% length 2))
          (signal 'pgsql-protocol-error
                  (list "PostgreSQL bytea value has an odd hex length")))
        (cl-labels ((nibble (char)
                      (cond
                       ((and (>= char ?0) (<= char ?9)) (- char ?0))
                       ((and (>= char ?a) (<= char ?f)) (+ 10 (- char ?a)))
                       ((and (>= char ?A) (<= char ?F)) (+ 10 (- char ?A)))
                       (t
                        (signal
                         'pgsql-protocol-error
                         (list "PostgreSQL bytea value contains non-hex data"))))))
          (dotimes (index (/ length 2))
            (let ((offset (* index 2)))
              (aset bytes index
                    (+ (ash (nibble (aref hex offset)) 4)
                       (nibble (aref hex (1+ offset))))))))
        bytes)
    (let ((position 0)
          (count 0)
          (bytes (make-string (length text) 0)))
      (while (< position (length text))
        (let ((char (aref text position)))
          (if (/= char ?\\)
              (progn
                (when (> char 255)
                  (signal 'pgsql-protocol-error
                          (list "Invalid PostgreSQL bytea escape data")))
                (aset bytes count char)
                (cl-incf count)
                (cl-incf position))
            (cond
             ((and (< (1+ position) (length text))
                   (= (aref text (1+ position)) ?\\))
              (aset bytes count ?\\)
              (cl-incf count)
              (cl-incf position 2))
             ((and (<= (+ position 4) (length text))
                   (string-match-p
                    "\\`[0-3][0-7][0-7]\\'"
                    (substring text (1+ position) (+ position 4))))
              (aset bytes count
                    (string-to-number
                     (substring text (1+ position) (+ position 4)) 8))
              (cl-incf count)
              (cl-incf position 4))
             (t
              (signal 'pgsql-protocol-error
                      (list "Invalid PostgreSQL bytea escape data")))))))
      (substring bytes 0 count))))

(defun pgsql--decode-timestamptz (text)
  "Decode PostgreSQL timestamp-with-time-zone TEXT when representable."
  (let ((iso (replace-regexp-in-string " " "T" text t t)))
    (condition-case nil
        (parse-iso8601-time-string iso t)
      (error
       text))))

(defun pgsql--decode-json (text)
  "Decode PostgreSQL JSON TEXT while preserving SQL NULL distinction."
  (json-parse-string text
                     :object-type 'hash-table
                     :array-type 'array
                     :null-object :null
                     :false-object :false))

(defun pgsql--decode-scalar (bytes oid)
  "Decode text-format BYTES for PostgreSQL type OID."
  (let ((text (decode-coding-string bytes 'utf-8)))
    (pcase oid
      ((or 20 21 23 26) (string-to-number text))
      ((or 700 701)
       (pcase text
         ("Infinity" 1.0e+INF)
         ("-Infinity" -1.0e+INF)
         ("NaN" 0.0e+NaN)
         (_ (string-to-number text))))
      (1700 text)
      (16
       (pcase text
         ((or "t" "true") t)
         ((or "f" "false") nil)
         (_ (signal 'pgsql-protocol-error
                    (list (format "Malformed PostgreSQL boolean: %s" text))))))
      (17 (pgsql--decode-bytea text))
      ((or 114 3802) (pgsql--decode-json text))
      ((or 1082 1114) text)
      (1184 (pgsql--decode-timestamptz text))
      (_ text))))

(defun pgsql--parse-array (text element-oid)
  "Parse PostgreSQL array TEXT using ELEMENT-OID."
  (let* ((text (if (string-match
                    "\\`\\(?:\\[[+-]?[0-9]+:[+-]?[0-9]+\\]\\)+=" text)
                   (substring text (match-end 0))
                 text))
         (length (length text))
         (position 0))
    (cl-labels
        ((parse-element ()
           (if (= (aref text position) ?{)
               (parse-level)
             (let ((quoted (= (aref text position) ?\"))
                   (chars nil))
               (when quoted (cl-incf position))
               (catch 'done
                 (while (< position length)
                   (let ((char (aref text position)))
                     (cond
                      ((and quoted (= char ?\\))
                       (cl-incf position)
                       (when (>= position length)
                         (signal 'pgsql-protocol-error
                                 (list "Incomplete PostgreSQL array escape")))
                       (push (aref text position) chars)
                       (cl-incf position))
                      ((and quoted (= char ?\"))
                       (cl-incf position)
                       (throw 'done nil))
                      ((and (not quoted) (memq char '(?, ?})))
                       (throw 'done nil))
                      (t
                       (push char chars)
                       (cl-incf position))))))
               (when (and quoted
                          (or (zerop position)
                              (/= (aref text (1- position)) ?\")))
                 (signal 'pgsql-protocol-error
                         (list "Unterminated PostgreSQL array quote")))
               (let ((value (apply #'string (nreverse chars))))
                 (if (and (not quoted) (string= value "NULL"))
                     pgsql-null
                   (pgsql--decode-scalar (pgsql--text-bytes value)
                                         element-oid))))))
         (parse-level ()
           (unless (and (< position length) (= (aref text position) ?{))
             (signal 'pgsql-protocol-error
                     (list "PostgreSQL array is missing an opening brace")))
           (cl-incf position)
           (let (values done)
             (while (not done)
               (when (>= position length)
                 (signal 'pgsql-protocol-error
                         (list "Unterminated PostgreSQL array")))
               (if (= (aref text position) ?})
                   (progn (cl-incf position) (setq done t))
                 (push (parse-element) values)
                 (when (>= position length)
                   (signal 'pgsql-protocol-error
                           (list "Unterminated PostgreSQL array")))
                 (pcase (aref text position)
                   (?, (cl-incf position))
                   (?} (cl-incf position) (setq done t))
                   (_ (signal 'pgsql-protocol-error
                              (list "Invalid PostgreSQL array separator"))))))
             (vconcat (nreverse values)))))
      (let ((result (parse-level)))
        (unless (= position length)
          (signal 'pgsql-protocol-error
                  (list "Data follows PostgreSQL array value")))
        result))))

(defun pgsql--decode-value (bytes oid)
  "Decode text-format BYTES for PostgreSQL OID."
  (if-let* ((element-oid (alist-get oid pgsql--array-element-oids)))
      (pgsql--parse-array (decode-coding-string bytes 'utf-8) element-oid)
    (pgsql--decode-scalar bytes oid)))

(defun pgsql--array-type-p (type)
  "Return non-nil when TYPE names a PostgreSQL array."
  (and (stringp type)
       (or (string-prefix-p "_" type)
           (string-suffix-p "[]" type))))

(defun pgsql--array-element-type (type)
  "Return the element type name for PostgreSQL array TYPE."
  (if (string-prefix-p "_" type)
      (substring type 1)
    (substring type 0 -2)))

(defun pgsql--encode-float (value)
  "Return PostgreSQL text for floating-point VALUE."
  (cond
   ((isnan value) "NaN")
   ((= value 1.0e+INF) "Infinity")
   ((= value -1.0e+INF) "-Infinity")
   (t (number-to-string value))))

(defun pgsql--encode-bytea (value)
  "Return VALUE as PostgreSQL's hex BYTEA text representation."
  (unless (stringp value)
    (signal 'wrong-type-argument (list 'stringp value)))
  (let* ((bytes (if (multibyte-string-p value)
                    (encode-coding-string value 'utf-8 t)
                  value))
         (digits "0123456789abcdef")
         (hex (make-string (* 2 (length bytes)) 0)))
    (dotimes (index (length bytes))
      (let ((byte (aref bytes index))
            (offset (* index 2)))
        (aset hex offset (aref digits (ash byte -4)))
        (aset hex (1+ offset) (aref digits (logand byte 15)))))
    (concat "\\x" hex)))

(defun pgsql--encode-scalar (value type)
  "Return the PostgreSQL text representation of VALUE for TYPE."
  (let ((type (and (stringp type) (downcase (string-trim type)))))
    (cond
     ((equal type "bytea") (pgsql--encode-bytea value))
     ((stringp value) value)
     ((eq value t) "true")
     ((null value) "false")
     ((integerp value) (number-to-string value))
     ((floatp value) (pgsql--encode-float value))
     ((member type '("json" "jsonb"))
      (json-serialize value :null-object :null :false-object :false))
     (t (format "%s" value)))))

(defun pgsql--quote-array-element (text)
  "Quote TEXT for a PostgreSQL array literal."
  (concat "\""
          (string-replace "\"" "\\\""
                          (string-replace "\\" "\\\\" text))
          "\""))

(defun pgsql--encode-array (value element-type)
  "Encode sequence VALUE as a PostgreSQL array of ELEMENT-TYPE."
  (unless (or (vectorp value) (listp value))
    (signal 'wrong-type-argument (list 'sequencep value)))
  (concat
   "{"
   (mapconcat
    (lambda (element)
      (cond
       ((pgsql-null-p element) "NULL")
       ((or (numberp element) (eq element t) (null element))
        (pgsql--encode-scalar element element-type))
       ((or (vectorp element) (listp element))
        (pgsql--encode-array element element-type))
       (t
        (pgsql--quote-array-element
         (pgsql--encode-scalar element element-type)))))
    (if (vectorp value) (append value nil) value)
    ",")
   "}"))

(defun pgsql-array-literal (value type)
  "Return a PostgreSQL array literal for sequence VALUE of array TYPE.
TYPE may use PostgreSQL's internal `_element' name or SQL `element[]'
spelling."
  (unless (pgsql--array-type-p type)
    (signal 'wrong-type-argument (list 'pgsql-array-type-p type)))
  (pgsql--encode-array value (pgsql--array-element-type type)))

(defun pgsql--encode-parameter (parameter)
  "Encode typed PARAMETER as text or return nil for SQL NULL.
PARAMETER is a cons of value and optional PostgreSQL type name."
  (pcase-let ((`(,value . ,type) parameter))
    (unless (pgsql-null-p value)
      (pgsql--text-bytes
       (if (and (pgsql--array-type-p type)
                (or (vectorp value) (listp value)))
           (pgsql-array-literal value type)
         (pgsql--encode-scalar value type))))))

(defun pgsql--parameter-type-oid (type)
  "Return the built-in PostgreSQL OID named by TYPE.
Return zero for nil or non-built-in TYPE so PostgreSQL may infer it."
  (if (null type)
      0
    (unless (stringp type)
      (signal 'wrong-type-argument (list 'stringp type)))
    (let* ((name (downcase (string-trim type)))
           (oid (or (alist-get name pgsql--type-oids nil nil #'string=)
                    (and (string-suffix-p "[]" name)
                         (alist-get (concat "_" (substring name 0 -2))
                                    pgsql--type-oids nil nil #'string=)))))
      (or oid 0))))

;;;; Backend result parsing

(defun pgsql--parse-columns (payload)
  "Parse a RowDescription PAYLOAD into column plists."
  (when (< (length payload) 2)
    (signal 'pgsql-protocol-error
            (list "Invalid PostgreSQL RowDescription")))
  (let ((count (pgsql--read-uint16 payload 0))
        (offset 2)
        columns)
    (dotimes (_ count)
      (pcase-let ((`(,name . ,next) (pgsql--cstring-at payload offset)))
        (setq offset next)
        (when (> (+ offset 18) (length payload))
          (signal 'pgsql-protocol-error
                  (list "Truncated PostgreSQL RowDescription")))
        (push (list :name name
                    :table-oid (pgsql--read-uint32 payload offset)
                    :attribute-number (pgsql--read-int16 payload (+ offset 4))
                    :type-oid (pgsql--read-uint32 payload (+ offset 6))
                    :type-size (pgsql--read-int16 payload (+ offset 10))
                    :type-modifier (pgsql--read-int32 payload (+ offset 12))
                    :format (pgsql--read-uint16 payload (+ offset 16)))
              columns)
        (cl-incf offset 18)))
    (unless (= offset (length payload))
      (signal 'pgsql-protocol-error
              (list "Data follows PostgreSQL RowDescription")))
    (nreverse columns)))

(defun pgsql--parse-row (payload columns)
  "Parse a DataRow PAYLOAD according to COLUMNS."
  (when (< (length payload) 2)
    (signal 'pgsql-protocol-error (list "Invalid PostgreSQL DataRow")))
  (let ((count (pgsql--read-uint16 payload 0))
        (offset 2)
        values)
    (unless (= count (length columns))
      (signal 'pgsql-protocol-error
              (list "PostgreSQL DataRow column count does not match metadata")))
    (dolist (column columns)
      (when (> (+ offset 4) (length payload))
        (signal 'pgsql-protocol-error
                (list "Truncated PostgreSQL DataRow length")))
      (let ((length (pgsql--read-int32 payload offset)))
        (cl-incf offset 4)
        (cond
         ((= length -1) (push pgsql-null values))
         ((< length -1)
          (signal 'pgsql-protocol-error
                  (list "Invalid PostgreSQL DataRow value length")))
         ((> (+ offset length) (length payload))
          (signal 'pgsql-protocol-error
                  (list "Truncated PostgreSQL DataRow value")))
         (t
          (push (pgsql--decode-value
                 (substring payload offset (+ offset length))
                 (pgsql-column-type-oid column))
                values)
          (cl-incf offset length)))))
    (unless (= offset (length payload))
      (signal 'pgsql-protocol-error
              (list "Data follows PostgreSQL DataRow")))
    (nreverse values)))

(defun pgsql--affected-rows (command-tag)
  "Return affected row count from COMMAND-TAG, or nil."
  (when (and command-tag
             (string-match "\\(?:^\\| \\)\\([0-9]+\\)\\'" command-tag))
    (string-to-number (match-string 1 command-tag))))

(defun pgsql--collect-result (connection &optional deadline)
  "Collect one CONNECTION response through ReadyForQuery.
Return a cons of result and structured server error fields.
Optional absolute DEADLINE bounds the whole recovery exchange."
  (let ((timeout (pgsql--connection-read-timeout connection))
        columns rows
        final-columns final-rows command-tag server-error terminal-seen)
    (cl-loop
     for message = (progn
                     (when (and deadline
                                (zerop (pgsql--remaining-time deadline)))
                       (signal 'pgsql-timeout
                               (list "PostgreSQL recovery timed out")))
                     (if deadline
                         (pgsql--read-message connection nil deadline)
                       (pgsql--read-message-idle connection timeout)))
     for type = (car message)
     for payload = (cdr message)
     do
     (pcase type
       (?T
        (setq columns (pgsql--parse-columns payload)
              rows nil
              terminal-seen nil))
       (?D
        (unless columns
          (signal 'pgsql-protocol-error
                  (list "PostgreSQL sent DataRow before RowDescription")))
        (push (pgsql--parse-row payload columns) rows))
       (?C
        (pcase (pgsql--cstrings payload)
          (`(,tag)
           (setq command-tag tag
                 final-columns columns
                 final-rows (nreverse rows)
                 columns nil
                 rows nil
                 terminal-seen t))
          (_ (signal 'pgsql-protocol-error
                     (list "Invalid PostgreSQL CommandComplete")))))
       (?I
        (unless (zerop (length payload))
          (signal 'pgsql-protocol-error
                  (list "Invalid PostgreSQL EmptyQueryResponse")))
        (setq command-tag "EMPTY"
              final-columns nil
              final-rows nil
              columns nil
              rows nil
              terminal-seen t))
       (?E
        (unless server-error
          (setq server-error (pgsql--error-fields payload)))
        (setq terminal-seen t))
       (?Z
        (unless terminal-seen
          (signal 'pgsql-protocol-error
                  (list "PostgreSQL response ended without a query result")))
        (setf (pgsql--connection-transaction-status connection)
              (pgsql--ready-status payload))
        (cl-return
         (cons (pgsql--make-result
                :columns final-columns
                :rows final-rows
                :command-tag command-tag
                :affected-rows (pgsql--affected-rows command-tag))
               server-error)))
       ((or ?1 ?2 ?3 ?n)
        (unless (zerop (length payload))
          (signal 'pgsql-protocol-error
                  (list "Invalid PostgreSQL completion message"))))
       (_
        (unless (pgsql--handle-side-message connection type payload)
          (signal 'pgsql-protocol-error
                  (list (format "Unexpected PostgreSQL query message: %c"
                                type)))))))))

(defun pgsql--mark-broken (connection)
  "Mark CONNECTION broken and release its transport resources."
  (setf (pgsql--connection-broken-p connection) t
        (pgsql--connection-closing-p connection) t
        (pgsql--connection-busy-p connection) nil)
  (when-let* ((process (pgsql--connection-process connection)))
    (when (process-live-p process)
      (delete-process process)))
  (when (buffer-live-p (pgsql--connection-input-buffer connection))
    (kill-buffer (pgsql--connection-input-buffer connection))))

(defun pgsql--cancel-and-drain (connection)
  "Cancel CONNECTION's active request and drain it through ReadyForQuery.
Return non-nil only when the connection is synchronized again."
  (let* ((deadline (+ (float-time) pgsql--cancel-recovery-timeout))
         (inhibit-quit t)
         synchronized)
    (condition-case nil
        (progn
          (pgsql--cancel-with-deadline connection deadline)
          (pgsql--collect-result connection deadline)
          (setq synchronized t))
      (error nil))
    synchronized))

(defun pgsql--request (connection bytes)
  "Send request BYTES on CONNECTION and return its synchronized result."
  (unless (pgsql-live-p connection)
    (signal 'pgsql-connection-error (list "PostgreSQL connection is not live")))
  (when (pgsql--connection-busy-p connection)
    (signal 'pgsql-connection-error (list "PostgreSQL connection is busy")))
  (setf (pgsql--connection-busy-p connection) t)
  (let (sent synchronized response)
    (unwind-protect
        (condition-case err
            (progn
              (setq sent t)
              (pgsql--send connection bytes)
              (setq response (pgsql--collect-result connection)
                    synchronized t)
              (if (cdr response)
                  (pgsql--signal-server-error (cdr response))
                (car response)))
          (pgsql-error
           (signal (car err) (cdr err)))
          (quit
           (when (or (not sent)
                     (pgsql--cancel-and-drain connection))
             (setq synchronized t))
           (signal (car err) (cdr err)))
          (error
           (signal 'pgsql-connection-error
                   (list (format "PostgreSQL request failed: %s"
                                 (error-message-string err))))))
      (if synchronized
          (setf (pgsql--connection-busy-p connection) nil)
        (pgsql--mark-broken connection)))))

;;;; Public connection and query API

;;;###autoload
(cl-defun pgsql-connect
    (&key database user password
          (host "localhost") (port 5432)
          (sslmode pgsql-sslmode)
          (connect-timeout pgsql-connect-timeout)
          (read-timeout pgsql-read-timeout)
          (application-name pgsql-application-name))
  "Connect to DATABASE as USER and return a PostgreSQL connection.
PASSWORD may be a string or a zero-argument function.  HOST and PORT
select the TCP endpoint.  SSLMODE is one of `disable', `prefer',
`require', or `verify-full'.  CONNECT-TIMEOUT and READ-TIMEOUT are
seconds, where zero disables the corresponding timeout.
APPLICATION-NAME is reported in the startup packet."
  (unless (and (stringp database) (not (string-empty-p database)))
    (signal 'wrong-type-argument (list 'stringp database)))
  (unless (and (stringp user) (not (string-empty-p user)))
    (signal 'wrong-type-argument (list 'stringp user)))
  (unless (and (stringp host) (not (string-empty-p host)))
    (signal 'wrong-type-argument (list 'stringp host)))
  (unless (and (integerp port) (> port 0) (<= port 65535))
    (signal 'wrong-type-argument (list 'pgsql-port-p port)))
  (unless (pgsql--timeout-p connect-timeout)
    (signal 'wrong-type-argument (list 'pgsql--timeout-p connect-timeout)))
  (unless (pgsql--timeout-p read-timeout)
    (signal 'wrong-type-argument (list 'pgsql--timeout-p read-timeout)))
  (unless (stringp application-name)
    (signal 'wrong-type-argument (list 'stringp application-name)))
  (dolist (value (list database user host application-name))
    (when (string-search (string 0) value)
      (signal 'pgsql-error
              (list "PostgreSQL startup parameters cannot contain NUL"))))
  (unless (memq sslmode '(disable prefer require verify-full))
    (signal 'wrong-type-argument
            (list '(member disable prefer require verify-full) sslmode)))
  (let* ((password (pgsql--password-string password))
         (deadline (and (> connect-timeout 0)
                        (+ (float-time) connect-timeout)))
         (input (generate-new-buffer " *pgsql input*"))
         (connection
          (pgsql--make-connection
           :input-buffer input
           :host host
           :port port
           :user user
           :database database
           :sslmode sslmode
           :connect-timeout connect-timeout
           :connect-deadline deadline
           :read-timeout read-timeout
           :application-name application-name
           :parameters (make-hash-table :test #'equal)
           :transaction-status nil
           :busy-p t)))
    (with-current-buffer input
      (set-buffer-multibyte nil)
      (buffer-disable-undo))
    (let (connected)
      (unwind-protect
          (condition-case err
              (prog1
                  (progn
                    (pgsql--open-process connection)
                    (pgsql--negotiate-tls connection)
                    (pgsql--startup connection password))
                (setq connected t))
            (pgsql-error
             (signal (car err) (cdr err)))
            (quit
             (signal (car err) (cdr err)))
            (error
             (signal 'pgsql-connection-error
                     (list (format "PostgreSQL connection failed: %s"
                                   (error-message-string err))))))
        (unless connected
          (pgsql--mark-broken connection))))))

(defun pgsql-live-p (connection)
  "Return non-nil when CONNECTION is synchronized and usable."
  (and (pgsql-connection-p connection)
       (not (pgsql--connection-broken-p connection))
       (process-live-p (pgsql--connection-process connection))))

(defun pgsql-busy-p (connection)
  "Return non-nil while CONNECTION has a request in flight."
  (and (pgsql-connection-p connection)
       (pgsql--connection-busy-p connection)))

(defun pgsql-transaction-status (connection)
  "Return CONNECTION's last ReadyForQuery transaction status.
The value is `idle', `in-transaction', or `failed-transaction'."
  (pgsql--connection-transaction-status connection))

(defun pgsql-set-read-timeout (connection seconds)
  "Set CONNECTION's response idle timeout to SECONDS.
Zero disables the timeout."
  (unless (pgsql--timeout-p seconds)
    (signal 'wrong-type-argument (list 'pgsql--timeout-p seconds)))
  (setf (pgsql--connection-read-timeout connection) seconds))

(defun pgsql-set-connect-timeout (connection seconds)
  "Set CONNECTION's auxiliary connection timeout to SECONDS.
This timeout bounds future cancellation connections.  Zero disables it."
  (unless (pgsql--timeout-p seconds)
    (signal 'wrong-type-argument (list 'pgsql--timeout-p seconds)))
  (setf (pgsql--connection-connect-timeout connection) seconds))

(defun pgsql-parameter (connection name)
  "Return server parameter NAME recorded for CONNECTION."
  (gethash name (pgsql--connection-parameters connection)))

(defun pgsql-user (connection)
  "Return the login user for CONNECTION."
  (pgsql--connection-user connection))

(defun pgsql-host (connection)
  "Return the TCP host for CONNECTION."
  (pgsql--connection-host connection))

(defun pgsql-port (connection)
  "Return the TCP port for CONNECTION."
  (pgsql--connection-port connection))

(defun pgsql-database (connection)
  "Return the database name for CONNECTION."
  (pgsql--connection-database connection))

(defun pgsql-disconnect (connection)
  "Close CONNECTION and release its process and input buffer."
  (when (pgsql-connection-p connection)
    (setf (pgsql--connection-closing-p connection) t)
    (when-let* ((process (pgsql--connection-process connection)))
      (when (process-live-p process)
        (unless (pgsql--connection-busy-p connection)
          (ignore-error process-error
            (process-send-string process (pgsql--message ?X ""))))
        (delete-process process)))
    (when (buffer-live-p (pgsql--connection-input-buffer connection))
      (kill-buffer (pgsql--connection-input-buffer connection)))
    (setf (pgsql--connection-busy-p connection) nil))
  nil)

(defun pgsql-exec (connection sql)
  "Execute SQL on CONNECTION using PostgreSQL's simple-query protocol."
  (pgsql--validate-sql sql)
  (pgsql--request
   connection
   (pgsql--message ?Q (concat (pgsql--text-bytes sql) (unibyte-string 0)))))

(defun pgsql-exec-params (connection sql typed-parameters)
  "Execute SQL with TYPED-PARAMETERS on CONNECTION.
Each parameter is a cons of VALUE and an optional PostgreSQL type name.
Recognized built-in names are sent in Parse; PostgreSQL infers other
types from SQL context.  Use `pgsql-null' for SQL NULL; Lisp nil is
PostgreSQL boolean false."
  (pgsql--validate-sql sql)
  (let* ((encoded (mapcar #'pgsql--encode-parameter typed-parameters))
         (type-oids
          (mapcar (lambda (parameter)
                    (pgsql--parameter-type-oid (cdr parameter)))
                  typed-parameters))
         (parse (pgsql--message
                 ?P (concat (unibyte-string 0)
                            (pgsql--text-bytes sql) (unibyte-string 0)
                            (pgsql--uint16 (length type-oids))
                            (mapconcat #'pgsql--uint32 type-oids ""))))
         (bind-payload
          (concat
           (unibyte-string 0 0)
           (pgsql--uint16 0)
           (pgsql--uint16 (length encoded))
           (mapconcat
            (lambda (value)
              (if value
                  (concat (pgsql--uint32 (string-bytes value)) value)
                (pgsql--uint32 #xffffffff)))
            encoded "")
           (pgsql--uint16 0)))
         (bind (pgsql--message ?B bind-payload))
         (describe (pgsql--message ?D (unibyte-string ?P 0)))
         (execute (pgsql--message ?E
                                  (concat (unibyte-string 0)
                                          (pgsql--uint32 0))))
         (sync (pgsql--message ?S "")))
    (pgsql--request connection (concat parse bind describe execute sync))))

(defun pgsql-escape-identifier (identifier)
  "Quote PostgreSQL IDENTIFIER."
  (unless (stringp identifier)
    (signal 'wrong-type-argument (list 'stringp identifier)))
  (concat "\"" (string-replace "\"" "\"\"" identifier) "\""))

(defun pgsql-escape-literal (value)
  "Quote string VALUE as a PostgreSQL literal."
  (unless (stringp value)
    (signal 'wrong-type-argument (list 'stringp value)))
  (if (string-search "\\" value)
      (concat "E'"
              (string-replace "'" "''" (string-replace "\\" "\\\\" value))
              "'")
    (concat "'" (string-replace "'" "''" value) "'")))

(defun pgsql--cancel-with-deadline (connection deadline)
  "Cancel CONNECTION over an auxiliary socket before absolute DEADLINE."
  (unless (and (pgsql-live-p connection)
               (integerp (pgsql--connection-backend-pid connection))
               (integerp (pgsql--connection-secret-key connection)))
    (signal 'pgsql-connection-error
            (list "PostgreSQL connection has no cancellation key")))
  (condition-case err
      (let (process)
        (unwind-protect
            (progn
              (setq process
                    (make-network-process
                     :name "pgsql-cancel"
                     :host (pgsql--connection-host connection)
                     :service (pgsql--connection-port connection)
                     :coding 'binary
                     :nowait t
                     :noquery t))
              (set-process-query-on-exit-flag process nil)
              (pgsql--await-process-open
               process deadline
               "PostgreSQL cancellation connection")
              (process-send-string
               process
               (concat
                (pgsql--uint32 16)
                (pgsql--uint32 80877102)
                (pgsql--uint32 (pgsql--connection-backend-pid connection))
                (pgsql--uint32 (pgsql--connection-secret-key connection)))))
          (when (and process (process-live-p process))
            (delete-process process))))
    (pgsql-error
     (signal (car err) (cdr err)))
    (quit
     (signal (car err) (cdr err)))
    (error
     (signal 'pgsql-connection-error
             (list (format "PostgreSQL cancellation failed: %s"
                           (error-message-string err))))))
  t)

(defun pgsql-cancel (connection)
  "Request cancellation of CONNECTION's active PostgreSQL command.
The CancelRequest is sent over a separate short-lived TCP connection."
  (let ((timeout (pgsql--connection-connect-timeout connection)))
    (pgsql--cancel-with-deadline
     connection
     (and (> timeout 0) (+ (float-time) timeout)))))

(provide 'pgsql)
;;; pgsql.el ends here
