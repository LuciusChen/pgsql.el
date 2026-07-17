;;; pgsql-live-test.el --- PostgreSQL live tests for pgsql.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Live PostgreSQL tests.  Set PGSQL_TEST_HOST, PGSQL_TEST_PORT,
;; PGSQL_TEST_USER, PGSQL_TEST_PASSWORD, and PGSQL_TEST_DATABASE before
;; running this file.  PGSQL_TEST_SSLMODE is optional and defaults to prefer.

;;; Code:

(require 'ert)
(require 'pgsql)
(require 'timer)

(defun pgsql-live-test--configuration ()
  "Return connection arguments from the PGSQL_TEST_* environment.
Skip the current test when required live-test configuration is absent."
  (let ((host (getenv "PGSQL_TEST_HOST"))
        (port-text (getenv "PGSQL_TEST_PORT"))
        (user (getenv "PGSQL_TEST_USER"))
        (password (getenv "PGSQL_TEST_PASSWORD"))
        (database (getenv "PGSQL_TEST_DATABASE"))
        (sslmode-text (getenv "PGSQL_TEST_SSLMODE")))
    (unless (and host port-text user password database)
      (ert-skip
       "Set PGSQL_TEST_HOST, PORT, USER, PASSWORD, and DATABASE for live tests"))
    (unless (string-match-p "\\`[0-9]+\\'" port-text)
      (ert-fail "PGSQL_TEST_PORT must be a decimal port number"))
    (let ((port (string-to-number port-text))
          (sslmode (if sslmode-text
                       (intern (downcase sslmode-text))
                     'prefer)))
      (unless (and (> port 0) (<= port 65535))
        (ert-fail "PGSQL_TEST_PORT must be between 1 and 65535"))
      (list :host host
            :port port
            :user user
            :password password
            :database database
            :sslmode sslmode
            :connect-timeout 10
            :read-timeout 10
            :application-name "pgsql-live-test"))))

(defmacro pgsql-live-test--with-connection (connection &rest body)
  "Bind CONNECTION to a live PostgreSQL connection while running BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,connection
          (apply #'pgsql-connect (pgsql-live-test--configuration))))
     (unwind-protect
         (progn ,@body)
       (pgsql-disconnect ,connection))))

(defun pgsql-live-test--single-row (result)
  "Return RESULT's sole row, failing when its shape is different."
  (let ((rows (pgsql-result-rows result)))
    (unless (= (length rows) 1)
      (ert-fail (format "Expected one PostgreSQL row, got %S" rows)))
    (car rows)))

(ert-deftest pgsql-live-test-connects-with-scram-credentials ()
  :tags '(:live)
  "Connect to a server configured for SCRAM-SHA-256 password authentication."
  (pgsql-live-test--with-connection connection
    (should (pgsql-live-p connection))
    (should-not (pgsql-busy-p connection))
    (should (eq (pgsql-transaction-status connection) 'idle))
    (should (equal (pgsql-parameter connection "client_encoding") "UTF8"))
    (should
     (equal
      (pgsql-result-rows (pgsql-exec connection "SHOW password_encryption"))
      '(("scram-sha-256"))))))

(ert-deftest pgsql-live-test-scram-prepares-non-ascii-passwords ()
  :tags '(:live)
  "Authenticate with a password whose SASLprep form differs from its input."
  (let* ((role (format "pgsql_saslprep_live_%d_%d"
                       (emacs-pid) (random 1000000000)))
         (password "space\u00a0password")
         (configuration (pgsql-live-test--configuration))
         (admin (apply #'pgsql-connect configuration))
         connection
         created-role-p)
    (unwind-protect
        (progn
          (pgsql-exec admin
                      (format "CREATE ROLE %s LOGIN PASSWORD %s"
                              (pgsql-escape-identifier role)
                              (pgsql-escape-literal password)))
          (setq created-role-p t)
          (setq configuration (plist-put configuration :user role)
                configuration (plist-put configuration :password password)
                connection (apply #'pgsql-connect configuration))
          (should (equal (pgsql-result-rows
                          (pgsql-exec connection "SELECT current_user"))
                         `((,role))))
          (should (pgsql-live-p connection)))
      (when connection
        (pgsql-disconnect connection))
      (when (and created-role-p (pgsql-live-p admin))
        (pgsql-exec admin
                    (format "DROP ROLE %s"
                            (pgsql-escape-identifier role))))
      (pgsql-disconnect admin))))

(ert-deftest pgsql-live-test-empty-parameter-status-values-keep-session-live ()
  :tags '(:live)
  "Empty startup and runtime ParameterStatus values should be valid."
  (let ((connection
         (apply #'pgsql-connect
                (plist-put (pgsql-live-test--configuration)
                           :application-name ""))))
    (unwind-protect
        (progn
          (should (equal (pgsql-parameter connection "application_name") ""))
          (pgsql-exec connection "SET application_name TO ''")
          (should (equal (pgsql-parameter connection "application_name") ""))
          (should (equal (pgsql-result-rows
                          (pgsql-exec connection "SELECT 1::int4"))
                         '((1))))
          (should (pgsql-live-p connection)))
      (pgsql-disconnect connection))))

(ert-deftest pgsql-live-test-simple-query-and-unicode ()
  :tags '(:live)
  "Return typed scalar and Unicode values through the simple-query path."
  (pgsql-live-test--with-connection connection
    (let* ((text "你好，PostgreSQL ✓")
           (result
            (pgsql-exec
             connection
             (format "SELECT 42::int4 AS answer, %s::text AS greeting"
                     (pgsql-escape-literal text)))))
      (should (equal (mapcar #'pgsql-column-name
                             (pgsql-result-columns result))
                     '("answer" "greeting")))
      (should (equal (pgsql-result-rows result) `((42 ,text))))
      (should (equal (pgsql-result-command-tag result) "SELECT 1"))
      (should (= (pgsql-result-affected-rows result) 1)))))

(ert-deftest pgsql-live-test-prepared-scalar-null-false-and-array ()
  :tags '(:live)
  "Keep scalar, SQL NULL, false, array, and Unicode parameters distinct."
  (pgsql-live-test--with-connection connection
    (should
     (equal
      (pgsql-result-rows
       (pgsql-exec-params
        connection "SELECT pg_typeof($1)::text, $1"
        (list (cons 42 "int4"))))
      '(("integer" 42))))
    (let* ((text "参数✓")
           (array (vector 1 2 pgsql-null 4))
           (result
            (pgsql-exec-params
             connection
             "SELECT $1::int4, $2::text, $3::text, $4::boolean, $5::int4[]"
             (list (cons 42 "int4")
                   (cons text "text")
                   (cons pgsql-null "text")
                   (cons nil "bool")
                   (cons array "int4[]"))))
           (row (pgsql-live-test--single-row result)))
      (should (= (nth 0 row) 42))
      (should (equal (nth 1 row) text))
      (should (pgsql-null-p (nth 2 row)))
      (should-not (nth 3 row))
      (should-not (pgsql-null-p (nth 3 row)))
      (should (equal (nth 4 row) array)))))

(ert-deftest pgsql-live-test-exact-and-session-dependent-codecs ()
  :tags '(:live)
  "Preserve numeric, bytea, and legal non-ISO temporal server values."
  (pgsql-live-test--with-connection connection
    (let* ((numeric "12345678901234567890.12345678901234567890")
           (bytes (unibyte-string 0 #xff ?\\ ?A)))
      (should
       (equal
        (pgsql-result-rows
         (pgsql-exec connection (format "SELECT %s::numeric" numeric)))
        `((,numeric))))
      (should
       (equal
        (pgsql-result-rows
         (pgsql-exec-params connection "SELECT $1"
                            (list (cons bytes "bytea"))))
        `((,bytes))))
      (pgsql-exec connection "SET bytea_output TO escape")
      (should
       (equal
        (pgsql-result-rows
         (pgsql-exec connection "SELECT decode('00ff5c41', 'hex')"))
        `((,bytes))))
      (pgsql-exec connection "SET DateStyle TO SQL, DMY")
      (should
       (equal
        (pgsql-result-rows
         (pgsql-exec connection
                     "SELECT DATE '2026-07-17', 'infinity'::timestamp"))
        '(("17/07/2026" "infinity"))))
      (should (pgsql-live-p connection)))))

(ert-deftest pgsql-live-test-ready-for-query-transaction-states ()
  :tags '(:live)
  "Track ReadyForQuery I, T, and E and reuse the connection after rollback."
  (pgsql-live-test--with-connection connection
    (should (eq (pgsql-transaction-status connection) 'idle))
    (pgsql-exec connection "BEGIN")
    (should (eq (pgsql-transaction-status connection) 'in-transaction))
    (let* ((error-value
            (should-error (pgsql-exec connection "SELECT 1 / 0")
                          :type 'pgsql-server-error))
           (fields (pgsql-error-fields error-value)))
      (should (equal (plist-get fields :sqlstate) "22012")))
    (should (eq (pgsql-transaction-status connection) 'failed-transaction))
    (pgsql-exec connection "ROLLBACK")
    (should (eq (pgsql-transaction-status connection) 'idle))
    (should (equal (pgsql-result-rows
                    (pgsql-exec connection "SELECT 7::int4"))
                   '((7))))
    (should (pgsql-live-p connection))))

(ert-deftest pgsql-live-test-server-error-keeps-autocommit-connection-reusable ()
  :tags '(:live)
  "Drain a server error through ReadyForQuery before reusing the connection."
  (pgsql-live-test--with-connection connection
    (let* ((error-value
            (should-error
             (pgsql-exec connection "SELECT 'not-an-integer'::integer")
             :type 'pgsql-server-error))
           (fields (pgsql-error-fields error-value)))
      (should (equal (plist-get fields :sqlstate) "22P02")))
    (should (eq (pgsql-transaction-status connection) 'idle))
    (should-not (pgsql-busy-p connection))
    (should (equal (pgsql-result-rows
                    (pgsql-exec connection "SELECT 8::int4"))
                   '((8))))))

(ert-deftest pgsql-live-test-cancel-keeps-connection-reusable ()
  :tags '(:live)
  "Cancel pg_sleep over a second connection, then reuse the original one."
  (pgsql-live-test--with-connection connection
    (let (cancel-result cancel-error timer)
      (unwind-protect
          (progn
            (setq timer
                  (run-at-time
                   0.2 nil
                   (lambda ()
                     (condition-case error-value
                         (setq cancel-result (pgsql-cancel connection))
                       (error
                        (setq cancel-error error-value))))))
            (let* ((error-value
                    (should-error
                     (pgsql-exec connection "SELECT pg_sleep(5)")
                     :type 'pgsql-server-error))
                   (fields (pgsql-error-fields error-value)))
              (should (equal (plist-get fields :sqlstate) "57014")))
            (when cancel-error
              (ert-fail
               (format "Cancellation request failed: %s"
                       (error-message-string cancel-error))))
            (should cancel-result)
            (should-not (pgsql-busy-p connection))
            (should (eq (pgsql-transaction-status connection) 'idle))
            (should (equal (pgsql-result-rows
                            (pgsql-exec connection "SELECT 9::int4"))
                           '((9))))
            (should (pgsql-live-p connection)))
        (when timer
          (cancel-timer timer))))))

(ert-deftest pgsql-live-test-keyboard-quit-cancels-and-keeps-session-reusable ()
  :tags '(:live)
  "A real keyboard quit should drain cancellation before returning control."
  (pgsql-live-test--with-connection connection
    (let (caught timer)
      (unwind-protect
          (progn
            (setq timer (run-at-time 0.2 nil #'keyboard-quit))
            (condition-case nil
                (pgsql-exec connection "SELECT pg_sleep(5)")
              (quit (setq caught t)))
            (should caught)
            (should-not (pgsql-busy-p connection))
            (should (eq (pgsql-transaction-status connection) 'idle))
            (should (equal (pgsql-result-rows
                            (pgsql-exec connection "SELECT 10::int4"))
                           '((10))))
            (should (pgsql-live-p connection)))
        (when timer
          (cancel-timer timer))))))

(provide 'pgsql-live-test)
;;; pgsql-live-test.el ends here
