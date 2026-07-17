;;; pgsql-test.el --- Deterministic tests for pgsql.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Unit tests for PostgreSQL framing, codecs, authentication, and request
;; synchronization.  These tests do not require a PostgreSQL server.

;;; Code:

(require 'ert)
(require 'pgsql)

(defun pgsql-test--bytes (text)
  "Encode TEXT as an exact unibyte string."
  (encode-coding-string text 'binary t))

(defun pgsql-test--uint16 (number)
  "Encode NUMBER as an unsigned 16-bit network integer."
  (unibyte-string (logand (ash number -8) 255)
                  (logand number 255)))

(defun pgsql-test--uint32 (number)
  "Encode NUMBER as an unsigned 32-bit network integer."
  (unibyte-string (logand (ash number -24) 255)
                  (logand (ash number -16) 255)
                  (logand (ash number -8) 255)
                  (logand number 255)))

(defun pgsql-test--message (type payload)
  "Build an exact backend message of TYPE containing PAYLOAD."
  (concat (unibyte-string type)
          (pgsql-test--uint32 (+ 4 (string-bytes payload)))
          payload))

(defmacro pgsql-test--with-connection (connection &rest body)
  "Bind CONNECTION to isolated protocol state while evaluating BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((input (generate-new-buffer " *pgsql test input*"))
          (,connection
           (pgsql--make-connection
            :process 'pgsql-test-process
            :input-buffer input
            :parameters (make-hash-table :test #'equal)
            :read-timeout 1
            :busy-p nil)))
     (with-current-buffer input
       (set-buffer-multibyte nil)
       (buffer-disable-undo))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p input)
         (kill-buffer input)))))

(ert-deftest pgsql-test-framing-supports-fragmentation-and-coalescing ()
  "Frames should be independent of process-filter chunk boundaries."
  (pgsql-test--with-connection connection
    (let* ((ready (unibyte-string ?Z 0 0 0 5 ?I))
           (complete (concat (unibyte-string ?C 0 0 0 13)
                             (pgsql-test--bytes "SELECT 1\0"))))
      (dotimes (offset (1- (length ready)))
        (pgsql--receive connection (substring ready offset (1+ offset)))
        (should-not (pgsql--take-message connection)))
      (pgsql--receive connection
                      (concat (substring ready -1) complete))
      (should (equal (pgsql--take-message connection)
                     (cons ?Z (unibyte-string ?I))))
      (should (equal (pgsql--take-message connection)
                     (cons ?C (pgsql-test--bytes "SELECT 1\0"))))
      (should-not (pgsql--take-message connection)))))

(ert-deftest pgsql-test-framing-rejects-invalid-lengths ()
  "Malformed and oversized frame lengths should fail before consumption."
  (pgsql-test--with-connection connection
    (pgsql--receive connection (unibyte-string ?D 0 0 0 3))
    (should-error (pgsql--take-message connection)
                  :type 'pgsql-protocol-error))
  (pgsql-test--with-connection connection
    (let ((pgsql-max-message-bytes 8))
      (pgsql--receive connection (unibyte-string ?D 0 0 0 9))
      (should-error (pgsql--take-message connection)
                    :type 'pgsql-protocol-error))))

(ert-deftest pgsql-test-data-row-distinguishes-null-empty-and-utf8 ()
  "DataRow decoding should preserve three distinguishable text values."
  (let* ((utf8 (encode-coding-string "你好" 'utf-8 t))
         (payload
          (concat (unibyte-string 0 3
                                  #xff #xff #xff #xff
                                  0 0 0 0
                                  0 0 0 6)
                  utf8))
         (columns '((:name "null" :type-oid 25)
                    (:name "empty" :type-oid 25)
                    (:name "utf8" :type-oid 25)))
         (row (pgsql--parse-row payload columns)))
    (should (= (length row) 3))
    (should (pgsql-null-p (nth 0 row)))
    (should (equal (nth 1 row) ""))
    (should (equal (nth 2 row) "你好"))))

(ert-deftest pgsql-test-row-description-rejects-binary-format ()
  "A binary RowDescription should fail before any DataRow is read."
  (let ((payload
         (concat (pgsql-test--uint16 1)
                 (pgsql-test--bytes "answer\0")
                 (pgsql-test--uint32 0)
                 (pgsql-test--uint16 0)
                 (pgsql-test--uint32 23)
                 (pgsql-test--uint16 4)
                 (pgsql-test--uint32 #xffffffff)
                 (pgsql-test--uint16 1))))
    (should-error (pgsql--parse-columns payload)
                  :type 'pgsql-protocol-error)))

(ert-deftest pgsql-test-public-values-keep-their-representation-opaque ()
  "Public connection and result accessors should remain ordinary functions."
  (pgsql-test--with-connection connection
    (let ((result (pgsql--make-result
                   :columns '((:name "answer" :type-oid 23))
                   :rows '((42))
                   :command-tag "SELECT 1"
                   :affected-rows 1)))
      (should (pgsql-connection-p connection))
      (should (pgsql-result-p result))
      (should (equal (pgsql-result-columns result)
                     '((:name "answer" :type-oid 23))))
      (should (equal (pgsql-result-rows result) '((42))))
      (should (equal (pgsql-result-command-tag result) "SELECT 1"))
      (should (= (pgsql-result-affected-rows result) 1))
      (dolist (symbol '(pgsql-connection-p
                        pgsql-result-p
                        pgsql-result-columns
                        pgsql-result-rows
                        pgsql-result-command-tag
                        pgsql-result-affected-rows))
        (should-not (get symbol 'compiler-macro))))))

(ert-deftest pgsql-test-array-codec-handles-quoting-nesting-and-null ()
  "Array codecs should preserve syntax-sensitive values and SQL NULL."
  (let ((decoded
         (pgsql--parse-array
          "{\"a,b\",\"quote\\\"slash\\\\\",\"NULL\",NULL,\"你好\"}"
          25)))
    (should (equal decoded
                   (vector "a,b" "quote\"slash\\" "NULL" pgsql-null "你好"))))
  (should (equal (pgsql--parse-array "{{1,2},{3,NULL}}" 23)
                 (vector (vector 1 2) (vector 3 pgsql-null))))
  (should (equal (pgsql--parse-array "[0:1]={left,right}" 25)
                 (vector "left" "right")))
  (should (equal (pgsql-array-literal
                  (vector "a,b" pgsql-null "NULL" (vector "x" "y"))
                  "text[]")
                 "{\"a,b\",NULL,\"NULL\",{\"x\",\"y\"}}"))
  (should (equal (pgsql-array-literal (vector nil pgsql-null) "_bool")
                 "{false,NULL}")))

(ert-deftest pgsql-test-scalar-codecs-preserve-exact-and-legal-values ()
  "Codecs should not lose precision or reject legal server text formats."
  (let ((numeric "12345678901234567890.12345678901234567890")
        (bytes (unibyte-string 0 #xff ?\\ ?A)))
    (should (equal (pgsql--decode-scalar (pgsql-test--bytes numeric) 1700)
                   numeric))
    (should (equal (pgsql--decode-scalar
                    (pgsql-test--bytes "17/07/2026") 1082)
                   "17/07/2026"))
    (should (equal (pgsql--decode-scalar
                    (pgsql-test--bytes "infinity") 1114)
                   "infinity"))
    (should (equal (pgsql--decode-scalar
                    (pgsql-test--bytes "2024-03-10 02:30:00") 1114)
                   "2024-03-10 02:30:00"))
    (should (equal (pgsql--decode-bytea "\\000\\377\\\\A") bytes))
    (should (equal (pgsql--decode-bytea "\\x00ff5c41") bytes))
    (should (equal (pgsql--encode-bytea bytes) "\\x00ff5c41"))))

(ert-deftest pgsql-test-startup-message-is-exact ()
  "StartupMessage should contain protocol 3.0 and terminated parameters."
  (let* ((payload
          (concat
           (unibyte-string 0 3 0 0)
           (pgsql-test--bytes
            (concat "user\0alice\0database\0app\0application_name\0tests\0"
                    "client_encoding\0UTF8\0DateStyle\0ISO\0\0"))))
         (expected (concat (pgsql-test--uint32 (+ 4 (length payload)))
                           payload)))
    (should (equal (pgsql--startup-message "alice" "app" "tests")
                   expected))))

(ert-deftest pgsql-test-parameter-status-preserves-empty-values ()
  "ParameterStatus should parse its fixed name/value pair exactly."
  (pgsql-test--with-connection connection
    (pgsql--parse-parameter-status
     connection (pgsql-test--bytes "application_name\0\0"))
    (should (equal (pgsql-parameter connection "application_name") ""))
    (should-error
     (pgsql--parse-parameter-status
      connection (pgsql-test--bytes "application_name\0value\0extra\0"))
     :type 'pgsql-protocol-error)))

(ert-deftest pgsql-test-notification-response-keeps-session-synchronized ()
  "NotificationResponse should deliver exact fields without ending a request."
  (pgsql-test--with-connection connection
    (let* ((notification-payload
            (concat (pgsql-test--uint32 4242)
                    (pgsql-test--bytes "jobs\0ready:你好\0")))
           (idle-notification-payload
            (concat (pgsql-test--uint32 4343)
                    (pgsql-test--bytes "alerts\0\0")))
           (transcript
            (concat (pgsql-test--message ?C (pgsql-test--bytes "LISTEN\0"))
                    (pgsql-test--message ?A notification-payload)
                    (pgsql-test--message ?Z (unibyte-string ?I))
                    (pgsql-test--message ?A idle-notification-payload)
                    (pgsql-test--message ?C (pgsql-test--bytes "SELECT 1\0"))
                    (pgsql-test--message ?Z (unibyte-string ?I))))
           notifications
           (pgsql-notification-functions
            (list (lambda (actual-connection value)
                    (push (list actual-connection value) notifications)))))
      (pgsql--receive connection transcript)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'process-send-string) #'ignore))
        (pgsql-exec connection "LISTEN jobs")
        (should (equal notifications
                       (list (list connection
                                   '(:pid 4242 :channel "jobs"
                                     :payload "ready:你好")))))
        (pgsql-exec connection "SELECT 1")
        (should
         (equal (nreverse notifications)
                (list (list connection
                            '(:pid 4242 :channel "jobs"
                              :payload "ready:你好"))
                      (list connection
                            '(:pid 4343 :channel "alerts" :payload ""))))))
      (dolist (payload (list (unibyte-string 0 0 0)
                             (concat notification-payload
                                     (unibyte-string 0))))
        (should-error
         (pgsql--handle-side-message connection ?A payload)
         :type 'pgsql-protocol-error)))))

(ert-deftest pgsql-test-idle-timeout-restarts-on-frame-progress ()
  "Fragment progress should restart a response idle timeout."
  (pgsql-test--with-connection connection
    (let ((now 100.0)
          (available '(0 1 2))
          (takes 0)
          deadlines)
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now))
                ((symbol-function 'pgsql--available-bytes)
                 (lambda (_connection) (pop available)))
                ((symbol-function 'pgsql--take-message)
                 (lambda (_connection)
                   (when (= (cl-incf takes) 3) '(?Z . "I"))))
                ((symbol-function 'pgsql--wait-for-input)
                 (lambda (_connection deadline)
                   (push deadline deadlines)
                   (cl-incf now 0.75))))
        (should (equal (pgsql--read-message-idle connection 1)
                       '(?Z . "I"))))
      (should (equal (nreverse deadlines) '(101.0 101.75))))))

(ert-deftest pgsql-test-unlimited-connect-timeout-still-polls-status ()
  "A zero connect timeout should poll instead of blocking for server output."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-connect-timeout connection) 0)
    (let ((statuses '(connect open))
          waits)
      (cl-letf (((symbol-function 'make-network-process)
                 (lambda (&rest _) 'new-process))
                ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
                ((symbol-function 'process-status)
                 (lambda (_process) (or (pop statuses) 'open)))
                ((symbol-function 'accept-process-output)
                 (lambda (_process seconds) (push seconds waits))))
        (should (eq (pgsql--open-process connection) 'new-process)))
      (should (equal waits '(0.05))))))

(ert-deftest pgsql-test-md5-password-matches-postgresql-algorithm ()
  "MD5 authentication should hash password, user, and raw server salt."
  (should
   (equal
    (pgsql--md5-password
     "alice" "secret" (unibyte-string #x12 #x34 #x56 #x78))
    "md51b28a7c92eb5e95d85e9b9093da502a9")))

(ert-deftest pgsql-test-clear-text-authentication-sends-exact-message ()
  "Clear-text authentication should send one exact PasswordMessage."
  (pgsql-test--with-connection connection
    (let (sent)
      (cl-letf (((symbol-function 'pgsql--send)
                 (lambda (_actual-connection bytes)
                   (setq sent bytes))))
        (should-not
         (pgsql--authentication-request
          connection (pgsql-test--uint32 3) "alice" "secret" nil))
        (should
         (equal sent
                (pgsql-test--message
                 ?p (pgsql-test--bytes "secret\0"))))))))

(ert-deftest pgsql-test-scram-sha256-matches-rfc-7677-vector ()
  "SCRAM-SHA-256 should match the RFC 7677 no-channel-binding exchange."
  (let* ((nonce "rOprNGfwEbeRWgbNEkqO")
         (server-first
          (concat
           "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
           "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
         (expected-final
          (concat
           "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
           "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="))
         (server-final "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
         (pgsql--nonce-function (lambda () nonce)))
    (pcase-let* ((`(,state . ,initial) (pgsql--scram-start "user"))
                 (`(,continued . ,response)
                  (pgsql--scram-continue state "pencil" server-first)))
      (should
       (equal initial
              (concat (pgsql-test--bytes "SCRAM-SHA-256\0")
                      (pgsql-test--uint32 32)
                      (pgsql-test--bytes
                       "n,,n=user,r=rOprNGfwEbeRWgbNEkqO"))))
      (should (equal (decode-coding-string response 'utf-8)
                     expected-final))
      (should-not (pgsql--scram-finish continued server-final))
      (should-error (pgsql--scram-finish continued "v=invalid")
                    :type 'pgsql-authentication-error))))

(ert-deftest pgsql-test-saslprep-matches-postgresql-password-semantics ()
  "SASLprep should normalize valid UTF-8 and preserve rejected input raw."
  (should (equal (pgsql--saslprep "plain ASCII") "plain ASCII"))
  (should (equal (pgsql--saslprep "a\u00a0b") "a b"))
  (should (equal (pgsql--saslprep "I\u00adX") "IX"))
  (should (equal (pgsql--saslprep "\u00aa") "a"))
  (dolist (password (list "\u00ad"
                          "a\ue000b"
                          "a\u0221b"
                          "a\u05d0"
                          "\u05d0a\u05d1"
                          "\u00a0\u0221"
                          (unibyte-string #xc3 #x28)))
    (should (equal (pgsql--saslprep password) password)))
  (should (equal (pgsql--saslprep "\u05d0\u05d1") "\u05d0\u05d1")))

(ert-deftest pgsql-test-ready-for-query-status-is-authoritative ()
  "ReadyForQuery should expose all transaction states and reject others."
  (should (eq (pgsql--ready-status (unibyte-string ?I)) 'idle))
  (should (eq (pgsql--ready-status (unibyte-string ?T)) 'in-transaction))
  (should (eq (pgsql--ready-status (unibyte-string ?E))
              'failed-transaction))
  (should-error (pgsql--ready-status (unibyte-string ?X))
                :type 'pgsql-protocol-error))

(ert-deftest pgsql-test-scram-requires-server-final-verification ()
  "AuthenticationOk must not bypass SCRAM server identity verification."
  (pgsql-test--with-connection connection
    (should-error
     (pgsql--authentication-request
      connection (pgsql-test--uint32 0) "user" "password"
      '(:nonce "client"))
     :type 'pgsql-authentication-error)
    (should
     (plist-get
      (pgsql--authentication-request
       connection (pgsql-test--uint32 0) "user" "password"
       '(:verified t))
      :verified))))

(ert-deftest pgsql-test-scram-rejects-invalid-iteration-counts ()
  "SCRAM iteration text must be bounded canonical decimal."
  (let ((state '(:nonce "client"
                 :client-first-bare "n=user,r=client")))
    (dolist (iterations '("4096junk" "0" "1000001"))
      (should-error
       (pgsql--scram-continue
        state "password"
        (format "r=clientserver,s=c2FsdA==,i=%s" iterations))
       :type 'pgsql-authentication-error))))

(ert-deftest pgsql-test-protocol-negotiation-uses-minor-version-fields ()
  "NegotiateProtocolVersion should parse Int32 minor and option fields."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-user connection) "user"
          (pgsql--connection-database connection) "db"
          (pgsql--connection-application-name connection) "test")
    (let ((messages
           (list (cons ?R (pgsql-test--uint32 0))
                 (cons ?v (concat (pgsql-test--uint32 0)
                                  (pgsql-test--uint32 0)))
                 (cons ?Z (unibyte-string ?I)))))
      (cl-letf (((symbol-function 'pgsql--send) #'ignore)
                ((symbol-function 'pgsql--read-message)
                 (lambda (&rest _) (pop messages))))
        (should (eq (pgsql--startup connection "password") connection)))))
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-user connection) "user"
          (pgsql--connection-database connection) "db"
          (pgsql--connection-application-name connection) "test")
    (let ((messages
           (list (cons ?R (pgsql-test--uint32 0))
                 (cons ?v (concat (pgsql-test--uint32 1)
                                  (pgsql-test--uint32 0))))))
      (cl-letf (((symbol-function 'pgsql--send) #'ignore)
                ((symbol-function 'pgsql--read-message)
                 (lambda (&rest _) (pop messages))))
        (should-error (pgsql--startup connection "password")
                      :type 'pgsql-protocol-error)))))

(ert-deftest pgsql-test-authentication-cannot-restart-after-success ()
  "AuthenticationOk must be the final authentication request."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-user connection) "user"
          (pgsql--connection-database connection) "db"
          (pgsql--connection-application-name connection) "test")
    (let ((messages
           (list (cons ?R (pgsql-test--uint32 0))
                 (cons ?R
                       (concat (pgsql-test--uint32 10)
                               (pgsql-test--bytes "SCRAM-SHA-256\0\0"))))))
      (cl-letf (((symbol-function 'pgsql--send) #'ignore)
                ((symbol-function 'pgsql--read-message)
                 (lambda (&rest _) (pop messages))))
        (should-error (pgsql--startup connection "password")
                      :type 'pgsql-protocol-error)))))

(ert-deftest pgsql-test-tls-prefer-downgrades-only-on-explicit-refusal ()
  "TLS prefer should accept N but never hide a failed TLS handshake."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-sslmode connection) 'prefer)
    (let (writes negotiated)
      (cl-letf (((symbol-function 'gnutls-available-p) (lambda () t))
                ((symbol-function 'pgsql--send)
                 (lambda (_connection bytes) (push bytes writes)))
                ((symbol-function 'pgsql--read-bytes)
                 (lambda (&rest _arguments) (unibyte-string ?N)))
                ((symbol-function 'gnutls-negotiate)
                 (lambda (&rest _arguments) (setq negotiated t))))
        (should-not (pgsql--negotiate-tls connection)))
      (should (= (length writes) 1))
      (should-not negotiated))
    (setf (pgsql--connection-sslmode connection) 'require)
    (cl-letf (((symbol-function 'gnutls-available-p) (lambda () t))
              ((symbol-function 'pgsql--send) #'ignore)
              ((symbol-function 'pgsql--read-bytes)
               (lambda (&rest _arguments) (unibyte-string ?N))))
      (should-error (pgsql--negotiate-tls connection)
                    :type 'pgsql-connection-error))
    (setf (pgsql--connection-sslmode connection) 'prefer)
    (cl-letf (((symbol-function 'gnutls-available-p) (lambda () t))
              ((symbol-function 'pgsql--send) #'ignore)
              ((symbol-function 'pgsql--read-bytes)
               (lambda (&rest _arguments) (unibyte-string ?S)))
              ((symbol-function 'gnutls-negotiate)
               (lambda (&rest _arguments)
                 (signal 'gnutls-error '("bad certificate")))))
      (should-error (pgsql--negotiate-tls connection)
                    :type 'pgsql-connection-error))))

(ert-deftest pgsql-test-server-errors-retain-structured-fields ()
  "Server errors should expose stable SQLSTATE and diagnostic fields."
  (let* ((payload
          (pgsql-test--bytes
           "SERROR\0VERROR\0C23505\0Mduplicate key\0taccounts\0nid_key\0\0"))
         (fields (pgsql--error-fields payload))
         caught)
    (should (equal (plist-get fields :severity) "ERROR"))
    (should (equal (plist-get fields :sqlstate) "23505"))
    (should (equal (plist-get fields :message) "duplicate key"))
    (should (equal (plist-get fields :table) "accounts"))
    (should (equal (plist-get fields :constraint) "id_key"))
    (condition-case error-value
        (pgsql--signal-server-error fields)
      (pgsql-server-error (setq caught error-value)))
    (should caught)
    (should (equal (pgsql-error-fields caught) fields))))

(ert-deftest pgsql-test-tls-rejects-buffered-plaintext-after-acceptance ()
  "TLS acceptance followed by buffered plaintext is a protocol violation."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-sslmode connection) 'require)
    (pgsql--receive connection (unibyte-string ?X))
    (cl-letf (((symbol-function 'gnutls-available-p) (lambda () t))
              ((symbol-function 'pgsql--send) #'ignore)
              ((symbol-function 'pgsql--read-bytes)
               (lambda (&rest _) (unibyte-string ?S))))
      (should-error (pgsql--negotiate-tls connection)
                    :type 'pgsql-protocol-error))))

(ert-deftest pgsql-test-extended-request-is-one-exact-write ()
  "Extended execution should batch Parse through Sync in one transport write."
  (pgsql-test--with-connection connection
    (let* ((sql "SELECT $1::bool, $2::text, $3::text")
           (false (pgsql-test--bytes "false"))
           (utf8 (encode-coding-string "你好" 'utf-8 t))
           (parse-payload
            (concat (unibyte-string 0)
                    (encode-coding-string sql 'utf-8 t)
                    (unibyte-string 0)
                    (pgsql-test--uint16 3)
                    (pgsql-test--uint32 16)
                    (pgsql-test--uint32 25)
                    (pgsql-test--uint32 25)))
           (bind-payload
            (concat (unibyte-string 0 0 0 0 0 3)
                    (pgsql-test--uint32 5) false
                    (pgsql-test--uint32 #xffffffff)
                    (pgsql-test--uint32 6) utf8
                    (unibyte-string 0 0)))
           (expected
            (concat (pgsql-test--message ?P parse-payload)
                    (pgsql-test--message ?B bind-payload)
                    (pgsql-test--message ?D (unibyte-string ?P 0))
                    (pgsql-test--message ?E (unibyte-string 0 0 0 0 0))
                    (pgsql-test--message ?S "")))
           (result (pgsql--make-result))
           writes)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'process-send-string)
                 (lambda (_process bytes) (push bytes writes)))
                ((symbol-function 'pgsql--collect-result)
                 (lambda (_connection) (cons result nil))))
        (should
         (eq (pgsql-exec-params
              connection sql
              (list (cons nil "bool")
                    (cons pgsql-null "text")
                    (cons "你好" "text")))
             result)))
      (should (= (length writes) 1))
      (should (equal (car writes) expected))
      (should-not (pgsql-busy-p connection)))))

(ert-deftest pgsql-test-error-drains-to-ready-before-reuse ()
  "A server error should signal only after synchronization and permit reuse."
  (pgsql-test--with-connection connection
    (let* ((error-payload
            (pgsql-test--bytes
             "SERROR\0VERROR\0C42601\0Msyntax error\0\0"))
           (parameter-payload
            (pgsql-test--bytes "application_name\0server-side\0"))
           (transcript
            (concat (pgsql-test--message ?E error-payload)
                    (pgsql-test--message ?S parameter-payload)
                    (pgsql-test--message ?Z (unibyte-string ?I))
                    (pgsql-test--message ?C
                                         (pgsql-test--bytes "SELECT 1\0"))
                    (pgsql-test--message ?Z (unibyte-string ?I))))
           writes caught)
      (pgsql--receive connection transcript)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'process-send-string)
                 (lambda (_process bytes) (push bytes writes))))
        (condition-case error-value
            (pgsql-exec connection "broken SQL")
          (pgsql-server-error (setq caught error-value)))
        (should caught)
        (should (equal (plist-get (pgsql-error-fields caught) :sqlstate)
                       "42601"))
        (should (eq (pgsql-transaction-status connection) 'idle))
        (should-not (pgsql-busy-p connection))
        (should-not (pgsql--connection-broken-p connection))
        (should (equal (pgsql-parameter connection "application_name")
                       "server-side"))
        (let ((result (pgsql-exec connection "SELECT 1")))
          (should (equal (pgsql-result-command-tag result) "SELECT 1")))
        (should (= (length writes) 2))
        (should-not (pgsql-busy-p connection))
        (should-not (pgsql--connection-broken-p connection))))))

(ert-deftest pgsql-test-unsynchronized-failure-breaks-connection ()
  "A request failure before ReadyForQuery should close the connection."
  (pgsql-test--with-connection connection
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'delete-process) #'ignore)
              ((symbol-function 'pgsql--collect-result)
               (lambda (_connection)
                 (signal 'pgsql-protocol-error '("truncated response")))))
      (should-error (pgsql-exec connection "SELECT 1")
                    :type 'pgsql-protocol-error))
    (should (pgsql--connection-broken-p connection))
    (should (pgsql--connection-closing-p connection))
    (should-not (pgsql-busy-p connection))
    (should-not (buffer-live-p (pgsql--connection-input-buffer connection)))))

(ert-deftest pgsql-test-nonlocal-request-exit-breaks-connection ()
  "A nonlocal exit before ReadyForQuery should still clean request state."
  (pgsql-test--with-connection connection
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'delete-process) #'ignore)
              ((symbol-function 'pgsql--collect-result)
               (lambda (_connection) (throw 'outside :escaped))))
      (should (eq (catch 'outside (pgsql-exec connection "SELECT 1"))
                  :escaped)))
    (should (pgsql--connection-broken-p connection))
    (should-not (pgsql-busy-p connection))
    (should-not (buffer-live-p (pgsql--connection-input-buffer connection)))))

(ert-deftest pgsql-test-ready-without-result-breaks-connection ()
  "ReadyForQuery alone must not manufacture a successful query result."
  (pgsql-test--with-connection connection
    (pgsql--receive connection
                    (pgsql-test--message ?Z (unibyte-string ?I)))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'delete-process) #'ignore))
      (should-error (pgsql-exec connection "UPDATE demo SET x = 1")
                    :type 'pgsql-protocol-error))
    (should (pgsql--connection-broken-p connection))))

(ert-deftest pgsql-test-connect-nonlocal-exit-cleans-transport ()
  "A connection callback nonlocal exit should release partial state."
  (let (captured)
    (cl-letf (((symbol-function 'pgsql--open-process)
               (lambda (connection) (setq captured connection)))
              ((symbol-function 'pgsql--negotiate-tls) #'ignore)
              ((symbol-function 'pgsql--startup)
               (lambda (&rest _) (throw 'outside :escaped))))
      (should
       (eq (catch 'outside
             (pgsql-connect :database "db" :user "user" :sslmode 'disable))
           :escaped)))
    (should (pgsql--connection-broken-p captured))
    (should-not (buffer-live-p (pgsql--connection-input-buffer captured)))))

(ert-deftest pgsql-test-connect-validates-state-before-opening-a-socket ()
  "Invalid connection state and embedded NUL should fail at the API boundary."
  (dolist (arguments '((:database "db" :user "user" :read-timeout nil)
                       (:database "db" :user "user" :port 0)
                       (:database "db" :user "user" :host "")))
    (should-error (apply #'pgsql-connect arguments)
                  :type 'wrong-type-argument))
  (should-error (pgsql-connect :database "db\0other" :user "user")
                :type 'pgsql-error)
  (pgsql-test--with-connection connection
    (should-error (pgsql-exec connection "SELECT 1\0SELECT 2")
                  :type 'pgsql-error)))

(ert-deftest pgsql-test-fractional-timeouts-and-runtime-setters ()
  "Timeout APIs should accept nonnegative fractional seconds."
  (let (connection)
    (unwind-protect
        (cl-letf (((symbol-function 'pgsql--open-process) #'ignore)
                  ((symbol-function 'pgsql--negotiate-tls) #'ignore)
                  ((symbol-function 'pgsql--startup)
                   (lambda (value _password) value)))
          (setq connection
                (pgsql-connect :database "db" :user "user"
                               :connect-timeout 0.5 :read-timeout 0.25))
          (should (= (pgsql--connection-connect-timeout connection) 0.5))
          (should (= (pgsql--connection-read-timeout connection) 0.25))
          (pgsql-set-connect-timeout connection 0.75)
          (pgsql-set-read-timeout connection 1.5)
          (should (= (pgsql--connection-connect-timeout connection) 0.75))
          (should (= (pgsql--connection-read-timeout connection) 1.5))
          (should-error (pgsql-set-connect-timeout connection -0.1)
                        :type 'wrong-type-argument)
          (should-error (pgsql-set-read-timeout connection nil)
                        :type 'wrong-type-argument))
      (when connection
        (pgsql-disconnect connection)))))

(ert-deftest pgsql-test-quit-cancels-drains-and-keeps-session-reusable ()
  "A quit should cancel and synchronize before it leaves the request."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-connect-timeout connection) 0
          (pgsql--connection-read-timeout connection) 300)
    (let ((pgsql--cancel-recovery-timeout 0.25)
          (collect-count 0)
          (cancel-count 0)
          cancel-deadline
          recovery-deadline
          caught)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'process-send-string) #'ignore)
                ((symbol-function 'pgsql--cancel-with-deadline)
                 (lambda (actual deadline)
                   (should (eq actual connection))
                   (setq cancel-deadline deadline)
                   (cl-incf cancel-count)
                   t))
                ((symbol-function 'pgsql--collect-result)
                 (lambda (_connection &optional deadline)
                   (pcase (cl-incf collect-count)
                     (1
                      (should-not deadline)
                      (signal 'quit nil))
                     (2
                      (setq recovery-deadline deadline)
                      (cons (pgsql--make-result) '(:sqlstate "57014")))
                     (_
                      (should-not deadline)
                      (cons (pgsql--make-result :command-tag "SELECT 1")
                            nil))))))
        (condition-case nil
            (pgsql-exec connection "SELECT pg_sleep(5)")
          (quit (setq caught t)))
        (should caught)
        (should (= cancel-count 1))
        (should cancel-deadline)
        (should recovery-deadline)
        (should (= cancel-deadline recovery-deadline))
        (should (= (pgsql--connection-connect-timeout connection) 0))
        (should (= (pgsql--connection-read-timeout connection) 300))
        (should-not (pgsql-busy-p connection))
        (should-not (pgsql--connection-broken-p connection))
        (should (buffer-live-p (pgsql--connection-input-buffer connection)))
        (should (equal (pgsql-result-command-tag
                        (pgsql-exec connection "SELECT 1"))
                       "SELECT 1"))))))

(ert-deftest pgsql-test-quit-recovery-failure-closes-the-session ()
  "A failed bounded quit recovery should close uncertain protocol state."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-connect-timeout connection) 42)
    (let (caught)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'process-send-string) #'ignore)
                ((symbol-function 'delete-process) #'ignore)
                ((symbol-function 'pgsql--cancel-with-deadline)
                 (lambda (_connection _deadline)
                   (signal 'pgsql-timeout '("cancel timed out"))))
                ((symbol-function 'pgsql--collect-result)
                 (lambda (_connection &optional _deadline)
                   (signal 'quit nil))))
        (condition-case nil
            (pgsql-exec connection "SELECT pg_sleep(5)")
          (quit (setq caught t))))
      (should caught)
      (should (= (pgsql--connection-connect-timeout connection) 42))
      (should (pgsql--connection-broken-p connection))
      (should (pgsql--connection-closing-p connection))
      (should-not (pgsql-busy-p connection))
      (should-not (buffer-live-p
                   (pgsql--connection-input-buffer connection))))))

(ert-deftest pgsql-test-connect-wraps-raw-transport-errors ()
  "Generic network errors should cross the public boundary as pgsql errors."
  (cl-letf (((symbol-function 'pgsql--open-process)
             (lambda (_connection)
               (signal 'file-error '("host lookup failed")))))
    (should-error
     (pgsql-connect :database "db" :user "user" :sslmode 'disable)
     :type 'pgsql-connection-error)))

(ert-deftest pgsql-test-connect-shares-one-absolute-deadline ()
  "TCP, TLS, and authentication should share one connection deadline."
  (let (deadlines connection)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'float-time)
                     (lambda (&optional _) 100.0))
                    ((symbol-function 'pgsql--open-process)
                     (lambda (value)
                       (push (pgsql--connection-connect-deadline value)
                             deadlines)))
                    ((symbol-function 'pgsql--negotiate-tls)
                     (lambda (value)
                       (push (pgsql--connection-connect-deadline value)
                             deadlines)))
                    ((symbol-function 'pgsql--startup)
                     (lambda (value _password)
                       (push (pgsql--connection-connect-deadline value)
                             deadlines)
                       value)))
            (setq connection
                  (pgsql-connect :database "db" :user "user"
                                 :connect-timeout 5)))
          (should (equal deadlines '(105.0 105.0 105.0))))
      (when connection
        (pgsql-disconnect connection)))))

(ert-deftest pgsql-test-idle-peer-close-releases-input-buffer ()
  "An unexpected idle peer close should release hidden transport state."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-busy-p connection) nil)
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'closed)))
      (pgsql--process-sentinel connection 'pgsql-test-process "closed"))
    (should (pgsql--connection-broken-p connection))
    (should-not (buffer-live-p (pgsql--connection-input-buffer connection)))))

(ert-deftest pgsql-test-cancel-request-uses-backend-key-on-new-process ()
  "Cancellation should send the exact backend key on a separate process."
  (pgsql-test--with-connection connection
    (setf (pgsql--connection-host connection) "db.example"
          (pgsql--connection-port connection) 5432
          (pgsql--connection-connect-timeout connection) 1
          (pgsql--connection-backend-pid connection) #x01020304
          (pgsql--connection-secret-key connection) #xa0b0c0d0)
    (let (network-arguments sent deleted)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'process-status) (lambda (_process) 'open))
                ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
                ((symbol-function 'make-network-process)
                 (lambda (&rest arguments)
                   (setq network-arguments arguments)
                   'cancel-process))
                ((symbol-function 'process-send-string)
                 (lambda (process bytes) (setq sent (cons process bytes))))
                ((symbol-function 'delete-process)
                 (lambda (process) (setq deleted process))))
        (should (pgsql-cancel connection)))
      (should (equal (plist-get network-arguments :host) "db.example"))
      (should (= (plist-get network-arguments :service) 5432))
      (should (eq (car sent) 'cancel-process))
      (should
       (equal (cdr sent)
              (unibyte-string 0 0 0 16 4 #xd2 #x16 #x2e
                              1 2 3 4 #xa0 #xb0 #xc0 #xd0)))
      (should (eq deleted 'cancel-process)))))

(provide 'pgsql-test)
;;; pgsql-test.el ends here
