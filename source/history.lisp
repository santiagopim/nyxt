;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(define-class history-entry ()          ; TODO: Export?
  ((url (quri:uri "")
        :accessor nil
        :type (or quri:uri string))
   (title "")
   (last-access "" ; TODO: Remove with Nyxt 2.0?
                :type (or string local-time:timestamp)
                :export nil
                :documentation "This slot is only kept for backward
compatibility to import the old flat history.")
   ;; TODO: For now we never increment the explicit-visits count.  Maybe we
   ;; could use a new buffer slot to signal that the last load came from an
   ;; explicit request?
   (explicit-visits 0
                    :type integer
                    :documentation "
Number of times the URL was visited by a prompt-buffer request.  This does not
include implicit visits.")
   (implicit-visits 0
                    :type integer
                    :documentation "
Number of times the URL was visited by following a link on a page.  This does
not include explicit visits."))
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name))
  (:documentation "
Entry for the global history.
The total number of visit for a given URL is (+ explicit-visits implicit-visits)."))

(defmethod object-string ((entry history-entry))
  (object-string (url entry)))

(defmethod object-display ((entry history-entry))
  (format nil "~a  ~a" (object-display (url entry)) (title entry)))

(defmethod prompter:object-properties ((entry history-entry))
  (list :default (object-string (url entry)) ; TODO: Use object-properties instead?
        :title (title entry)))

(export-always 'equals)
(defmethod equals ((e1 history-entry) (e2 history-entry))
  (quri:uri= (url e1) (url e2)))

(defmethod url ((he history-entry))
  "This accessor ensures we always return a `quri:uri'.
This is useful in cases the URL is originally stored as a string (for instance
when deserializing a `history-entry').

We can't use `initialize-instance :after' to convert the URL because
`s-serialization:deserialize-sexp' sets the slots manually after making the
class."
  (unless (quri:uri-p (slot-value he 'url))
    (setf (slot-value he 'url) (ensure-url (slot-value he 'url))))
  (slot-value he 'url))

(defmethod s-serialization::serialize-sexp-internal ((uri quri:uri)
                                                     stream
                                                     serialization-state)
  "Serialize `history-entry' by turning the URL and last access into strings."
  (declare (ignore serialization-state))
  (prin1 (object-string uri) stream))

(defmethod s-serialization::serialize-sexp-internal ((timestamp local-time:timestamp)
                                                     stream
                                                     serialization-state)
  "Serialize `history-entry' by turning the URL and last access into strings."
  (declare (ignore serialization-state))
  (prin1 (local-time:format-timestring nil timestamp
                                       :timezone local-time:+utc-zone+)
         stream))

(defun history-tree-key (history-entry)
  (quri:render-uri (url history-entry)))

(defun make-history-tree (&optional (buffer (current-buffer)))
  "Return a new global history tree for `history-entry' data."
  (htree:make :key 'history-tree-key :current-owner-id (id buffer)))

(declaim (ftype (function (quri:uri &key (:title string) (:buffer buffer)) t) history-add))
(defun history-add (uri &key (title "") (buffer (current-buffer)))
  "Add URL to the global/buffer-local history.
The `implicit-visits' count is incremented."
  (with-data-access (history (history-path (current-buffer))
                     :default (make-history-tree))
    (unless (or (url-empty-p uri)
                ;; If buffer was not registered in the global history, don't
                ;; proceed.  See `buffer-make'.
                (not (htree:owner history (id buffer))))
      (htree:with-current-owner (history (id buffer))
        (htree:add-child (make-instance 'history-entry
                                        :url uri
                                        :title title)
                         history))
      (let* ((entry (htree:data (htree:current (htree:owner history (id buffer))))))
        (incf (implicit-visits entry))))))

(define-command delete-history-entry (&key (buffer (current-buffer)))
  "Delete queried history entries."
  (with-data-access (history (history-path buffer))
    (let ((entries (prompt
                    :prompt "Delete entries"
                    :sources (list (make-instance 'history-disowned-source
                                                  :buffer buffer)))))
      (dolist (entry entries)
        (htree:delete-data history entry)))))

(define-command reset-buffer-history (&optional buffer)
  "Set selected buffers history to the current URL only.
This removes the parenthood with the parent buffer, if there was any.

When called over many or all buffers, it may free many history entries which
then become available for deletion with `delete-history-entry'."
  (let ((buffers (or (alex:ensure-list buffer)
                     (prompt
                      :prompt "Reset histories of buffer(s)"
                      :sources (list (make-instance 'buffer-source
                                                    :actions '()))))))
    (with-data-access (history (history-path (current-buffer)))
      (dolist (buffer buffers)
        (htree:reset-owner history (id buffer))))))

(defun score-history-entry (htree-entry)
  "Return history ENTRY score.
The score gets higher for more recent entries and if they've been visited a
lot."
  ;; TODO: Or use current owner last access?  Or both?
  ;; WARNING: `htree:data-last-access' is slow, which is why we take a
  ;; htree-entry instead which has much faster access to the last access.
  (let* ((entry (htree:data htree-entry))
         (last-access (htree:last-access htree-entry)))
    (+ (* 0.1
          ;; Total number of visits.
          (+ (implicit-visits entry)
             (explicit-visits entry)))
       (if last-access
           (* 1.0
              ;; Inverse number of hours since the last access.
              (/ 1
                 (1+ (/ (local-time:timestamp-difference (local-time:now)
                                                         last-access)
                        (* 60 60)))))
           0))))

(defun history-initial-suggestions (&key prefix-urls) ; TODO: Rename?  Make this a preprocessor so that it runs in the background?
  "TODO: Complete me!"
  (with-data-unsafe (hist (history-path (current-buffer)))
    (let* ((all-history-entries (when hist
                                  (mapcar #'htree:data
                                          (sort (alex:hash-table-keys (htree:entries hist))
                                                (lambda (x y)
                                                  (> (score-history-entry x)
                                                     (score-history-entry y)))))))
           (prefix-urls (delete-if #'uiop:emptyp prefix-urls)))
      (when prefix-urls
        (setf all-history-entries (append (mapcar #'quri:url-decode prefix-urls)
                                          all-history-entries)))
      all-history-entries)))

(define-class history-disowned-source (prompter:source)
  ((prompter:name "Disowned History")
   (buffer :accessor buffer :initarg :buffer)
   (prompter:must-match-p t)
   (prompter:multi-selection-p t)
   (prompter:constructor
    (lambda (source)
      (with-data-unsafe (hist (history-path (buffer source)))
        (let ((owner-less-history-entries
                (when hist
                  (mapcar #'htree:data
                          (sort
                           (delete-if (lambda (entry) (htree:nodes entry))
                                      (alex:hash-table-keys (htree:entries hist)))
                           (lambda (x y)
                             (> (score-history-entry x)
                                (score-history-entry y))))))))
          owner-less-history-entries))))))

(defun history-html-list (&key (limit 100) ; Export?
                            (separator " → "))
  (with-data-unsafe (history (history-path (current-buffer)))
    (let* ((history (when history
                      (mapcar #'first
                              (sort (alex:hash-table-alist (htree:entries history))
                                    #'local-time:timestamp>
                                    :key (lambda (entry-nodes)
                                           (let ((nodes (rest entry-nodes)))
                                             (apply #'local-time:timestamp-maximum
                                                    (mapcar #'htree:last-access nodes)))))))))
      (loop for entry in (sera:take limit history)
            collect (markup:markup
                     (:li (title entry) (unless (str:emptyp (title entry)) separator)
                          (:a :href (object-string (url entry))
                              (object-string (url entry)))))))))

(defun history-stored-data (path)
  "Return the history data that needs to be serialized.
This data can be used to restore the session later, e.g. when starting a new
instance of Nyxt."
  (list +version+ (get-data path)))

(defmethod store ((profile data-profile) (path history-data-path) &key &allow-other-keys)
  "Store the global/buffer-local history to the PATH."
  (with-data-file (file path
                        :direction :output
                        :if-does-not-exist :create
                        :if-exists :overwrite)
    ;; We READ the output of serialize-sexp to make it more human-readable.
    (let ((*package* (find-package :nyxt))
          (*print-length* nil))
      ;; We need to make sure current package is :nyxt so that
      ;; symbols are printed with consistent namespaces.
      (format file
              "~s"
              (with-input-from-string (in (with-output-to-string (out)
                                            (s-serialization:serialize-sexp
                                             (history-stored-data path)
                                             out)))
                (read in))))))

;; REVIEW: This works around the issue of cl-prevalence to deserialize structs
;; with custom constructors: https://github.com/40ants/cl-prevalence/issues/16.
(setf (fdefinition 'quri.uri::make-uri) #'quri.uri::%make-uri)

;; Hack of cl-prevalence to support the history-tree custom hash tables:
(defun history-deserialize-sexp (stream &optional (serialization-state (s-serialization::make-serialization-state)))
  "Read and return an s-expression serialized version of a lisp object from stream, optionally reusing a serialization state"
  (s-serialization::reset serialization-state)
  (let ((sexp (read stream nil :eof)))
    (if (eq sexp :eof)
        nil
        (history-deserialize-sexp-internal sexp (s-serialization::get-hashtable serialization-state)))))

;; Hack of cl-prevalence to support the history-tree custom hash tables:
(defun history-deserialize-sexp-internal (sexp deserialized-objects)
  (if (atom sexp)
      sexp
      (ecase (first sexp)
        (:sequence (destructuring-bind (id &key class size elements) (rest sexp)
                     (cond
                       ((not class)
                        (error "Unknown sequence class"))
                       ((not size)
                        (error "Unknown sequence size"))
                       (t
                        (let ((sequence (make-sequence class size)))
                          (declare (ignorable sequence))
                          (setf (gethash id deserialized-objects) sequence)
                          (map-into sequence
                                    #'(lambda (x) (history-deserialize-sexp-internal x deserialized-objects))
                                    elements))))))
        (:hash-table (destructuring-bind (id &key test size rehash-size rehash-threshold entries) (rest sexp)
                       (cond
                         ((not test)
                          (error "Test function is unknown"))
                         ((not size)
                          (error "Hash table size is unknown"))
                         ((not rehash-size)
                          (error "Hash table's rehash-size is unknown"))
                         ((not rehash-threshold)
                          (error "Hash table's rehash-threshold is unknown"))
                         (t
                          (if (member test '(eq eql equal equalp))
                              (let ((hash-table (make-hash-table :size size
                                                                 :test test
                                                                 :rehash-size rehash-size
                                                                 :rehash-threshold rehash-threshold)))
                                (setf (gethash id deserialized-objects) hash-table)
                                (dolist (entry entries)
                                  (setf (gethash (history-deserialize-sexp-internal (first entry) deserialized-objects) hash-table)
                                        (history-deserialize-sexp-internal (rest entry) deserialized-objects)))
                                hash-table)
                              (let ((hash-table (htree::make-entry-hash-table)))
                                (cl-custom-hash-table:with-custom-hash-table
                                  (setf (gethash id deserialized-objects) hash-table)
                                  (dolist (entry entries)
                                    (setf (gethash (history-deserialize-sexp-internal (first entry) deserialized-objects) hash-table)
                                          (history-deserialize-sexp-internal (rest entry) deserialized-objects))))
                                hash-table))))))

        (:object (destructuring-bind (id &key class slots) (rest sexp)
                   (let ((object (s-serialization::deserialize-class class slots deserialized-objects)))
                     (setf (gethash id deserialized-objects) object)
                     (dolist (slot slots)
                       (when (slot-exists-p object (first slot))
                         (setf (slot-value object (first slot))
                               (history-deserialize-sexp-internal (rest slot) deserialized-objects))))
                     object)))
        (:struct (destructuring-bind (id &key class slots) (rest sexp)
                   (let ((object (s-serialization::deserialize-struct class slots deserialized-objects)))
                     (setf (gethash id deserialized-objects) object)
                     (dolist (slot slots)
                       (when (slot-exists-p object (first slot))
                         (setf (slot-value object (first slot))
                               (history-deserialize-sexp-internal (rest slot) deserialized-objects))))
                     object)))
        (:cons (destructuring-bind (id cons-car cons-cdr) (rest sexp)
                 (let ((conspair (cons nil nil)))
                   (setf (gethash id deserialized-objects)
                         conspair)
                   (rplaca conspair (history-deserialize-sexp-internal cons-car deserialized-objects))
                   (rplacd conspair (history-deserialize-sexp-internal cons-cdr deserialized-objects)))))
        (:ref (gethash (rest sexp) deserialized-objects)))))

(defmethod s-serialization::deserialize-class ((history (eql 'htree:history-tree)) slots deserialized-objects)
  ;; We need this specialization because
  ;; - `history-tree' cannot be make-instance'd without specifying some slots like `owners'.
  ;; - We need a history tree
  (declare (ignore slots deserialized-objects))
  (let ((history (make-history-tree)))
    history))

(defvar flat-history-path (make-instance 'history-data-path :basename "history") ; TODO: Move to global.lisp?
  "Global flat history that was used before the introduction of the global history tree.
This is deprecated.
We keep this variable as a means to import the old format to the new one.")

(defmethod restore ((profile data-profile) (path history-data-path)
                    &key restore-buffers-p &allow-other-keys)
  "Restore the global/buffer-local history and session from the PATH."
  (labels ((restore-buffers (history)
             "For each owner, make buffer, swap owner identifier for buffer id.
             Keep table of old-id -> new-id, then go through all the owners and update their creator."
             (let ((old-id->new-id (make-hash-table :test #'equalp))
                   (new-owners (make-hash-table :test #'equalp)))
               ;; We can't `maphash' over (htree:owners history) because
               ;; `make-buffer' modifies the owners hash table.
               (mapc (lambda-match
                       ((cons owner-id owner)
                        ;; `htree:+default-owner+' may be present if the
                        ;; history is created (e.g. restored) while no web
                        ;; buffer exists.  In all cases, this owner is
                        ;; uninteresting.
                        (unless (equal owner-id htree:+default-owner+)
                          (let ((current-node (htree:current
                                               (htree:owner history owner-id))))
                            ;; Node-less owners can safely be ignored.
                            (when current-node
                              (let ((new-buffer (make-buffer :title (title (htree:data current-node))
                                                             :url (url (htree:data current-node))
                                                             :load-url-p nil)))
                                (setf (gethash owner-id old-id->new-id) (id new-buffer))
                                (setf (gethash (id new-buffer) new-owners) owner)))))))
                     (alex:hash-table-alist (htree:owners history)))
               (maphash (lambda (_ owner)
                          (declare (ignore _))
                          (setf (htree:creator-id owner)
                                (gethash (htree:creator-id owner) old-id->new-id)))
                        (htree:owners history))
               ;; Current owner can be outdated.
               (sera:and-let* ((new-id (gethash (htree:current-owner-id history) old-id->new-id)))
                 (when (htree:owner history new-id)
                   (htree:set-current-owner history new-id)))
               (setf (htree:owners history) new-owners))
             (let ((latest-id (first (first (sort (alex:hash-table-alist (htree:owners history))
                                                  #'local-time:timestamp>
                                                  :key (alex:compose #'htree:last-access #'cdr))))))
               (switch-buffer :id latest-id)))

           (restore-history-tree (history)
             (echo "Loading history of ~a URLs from ~s."
                   (hash-table-count (htree:entries history))
                   (expand-path path))
             (setf (get-data path) history)
             (when restore-buffers-p
               (restore-buffers history))
             history)

           (restore-flat-history (old-history old-path)
             (echo "Importing deprecated global history of ~a URLs from ~s."
                   (hash-table-count old-history)
                   (expand-path old-path))
             ;; REVIEW: `with-data-access' relies on `restore', so it shouldn't
             ;; be used inside of what it relies on. That's a vicious circle.
             ;; TODO: Use `get-data' instead.
             (with-data-access (history path
                                :default (make-history-tree)) ; TODO: What shall the default owner be here?
               (maphash (lambda (key data)
                          (declare (ignore key))
                          (let ((last-access (last-access data)))
                            ;; Remove last-access from DATA to avoid storing it
                            ;; twice.
                            (setf (last-access data) "")
                            (htree:add-entry history data last-access)))
                        old-history)
               history)))
    (with-protect ("Failed to restore history from ~a: ~a"
                        (expand-path path) :condition)
      (let* ((path (if (uiop:file-exists-p (expand-path path))
                       path
                       flat-history-path))
             (data (with-data-file (file path
                                         :direction :input
                                         :if-does-not-exist nil)
                     (when file
                       ;; We need to make sure current package is :nyxt so that
                       ;; symbols are printed with consistent namespaces.
                       (let ((*package* (find-package :nyxt)))
                         (history-deserialize-sexp file))))))
        (match data
          (nil nil)
          ((guard (list version history) t)
           (unless (string= version +version+)
             (log:warn "History version ~s differs from current version ~s"
                       version +version+))
           (ctypecase history
             (htree:history-tree
              (restore-history-tree history))

             (hash-table
              (restore-flat-history history path))))
          (_ (progn
               (error "Expected (list version history) structure.")
               nil)))))))

(defun histories-list (&optional (buffer (current-buffer)))
  (let* ((path (expand-path (history-path buffer)))
         (dir (when path (uiop:pathname-directory-pathname path))))
    (when dir
      (mapcar #'pathname-name
              (remove-if
               #'(lambda (pathname)
                   (let ((type (pathname-type pathname)))
                     (or (not (stringp type))
                         (not (string-equal "lisp" type)))))
               (uiop:directory-files dir))))))

(define-class history-name-source (prompter:source)
  ((prompter:name "Histories")
   (prompter:must-match-p t)
   (prompter:constructor (histories-list))))

(define-command store-history-by-name ()
  "Store the history data in the file named by user input.
Useful for session snapshots, as `restore-history-by-name' will restore opened buffers."
  (with-data-access (history (history-path (current-buffer)))
    (sera:and-let* ((name (first (prompt
                                  :prompt "The name to store history with"
                                  :sources (list (make-instance 'prompter:raw-source)
                                                 (make-instance 'history-name-source)))))
                    (path (make-instance 'history-data-path
                                         :dirname (dirname (history-path (current-buffer)))
                                         :basename name)))
      (setf (get-data path) history)
      (store (data-profile (current-buffer)) path))))

(define-command restore-history-by-name ()
  "Delete all the buffers of the current session/history and import the history chosen by user.
The imported history file is untouched while the current one is overwritten.
If you want to save the current history file beforehand, call
`store-history-by-name' to save it under a new name."
  ;; TODO: backup current history?
  (sera:and-let* ((name (first (prompt
                                :prompt "The name of the history to restore"
                                :sources (list (make-instance 'history-name-source)))))
                  (path (make-instance 'history-data-path
                                       :dirname (dirname (history-path (current-buffer)))
                                       :basename name)))
    (let ((old-buffers (buffer-list)))
      (setf (get-data path) (make-history-tree))
      (sera:and-let* ((new-history (restore (data-profile (current-buffer)) path
                                            :restore-buffers-p t)))
        ;; TODO: Maybe modify `history-path' of all the buffers instead of polluting history?
        (setf (get-data (history-path (current-buffer))) new-history)
        (dolist (buffer old-buffers)
          (buffer-delete buffer))))))
