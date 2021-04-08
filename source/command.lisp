;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(defvar *command-list* '()
  "The list of known commands, for internal use only.")

(define-class command ()
  ((name (error "Command name required.")
         :export t
         :type symbol
         :documentation "Name of the command.
This is useful to build commands out of anonymous functions.")
   (docstring ""
              :type string
              :documentation "Documentation of the command.")
   (fn (error "Function required.")
     :type function
     :documentation "Function wrapped by the command.")
   (sexp nil
         :type t
         :documentation "S-expression of the definition of top-level commands or
commands wrapping over lambdas.
This is nil for local commands that wrap over named functions.")
   (last-access (local-time:now)
                :type local-time:timestamp
                :documentation "Last time this command was called from prompt buffer.
This can be used to order the commands."))
  (:metaclass closer-mop:funcallable-standard-class)
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name))
  (:export-class-name-p t)
  (:documentation "Commands are interactive functions.
(As in Emacs.)

Commands are funcallable.

We need a `command' class for multiple reasons:
- Identify commands uniquely.

- Customize prompt buffer display value with properties.

- Last access: This is useful to sort command by the time they were last
  called.  The only way to do this is to persist the command instances."))

(defmethod initialize-instance :after ((command command) &key)
  (closer-mop:set-funcallable-instance-function command (fn command)))

(defmethod print-object ((command command) stream)
  (print-unreadable-object (command stream :type t :identity t)
    (format stream "~a" (name command))))

(define-condition documentation-style-warning (style-warning)
  ((name :initarg :name :reader name)
   (subject-type :initarg :subject-type :reader subject-type))
  (:report
   (lambda (condition stream)
     (format stream
             "~:(~A~) ~A doesn't have a documentation string"
             (subject-type condition)
             (name condition)))))

(define-condition command-documentation-style-warning  ; TODO: Remove and force docstring instead.
    (documentation-style-warning)
  ((subject-type :initform 'command)))

(export-always 'make-command)
(defmacro make-command (name arglist &body body)
  "Return a new local `command' named NAME.

With BODY, the command binds ARGLIST and executes the body.
The first string in the body is used to fill the `help' slot.

Without BODY, NAME must be a function symbol and the command wraps over it
against ARGLIST, if specified. "
  (let ((documentation (if (stringp (first body))
                           (first body)
                           "")))
    (alex:with-gensyms (fn sexp)
      `(let ((,fn nil)
             (,sexp nil))
         (cond
           ((and ',arglist ',body)
            (setf ,fn (lambda (,@arglist) ,@body)
                  ,sexp '(lambda (,@arglist) ,@body)))
           ((and ',arglist (typep ',name 'function-symbol))
            (setf ,fn (lambda (,@arglist) (funcall ',name ,@arglist))
                  ,sexp '(lambda (,@arglist) (funcall ,name ,@arglist))))
           ((and (null ',arglist) (typep ',name 'function-symbol))
            (setf ,fn (symbol-function ',name)))
           (t (error "Either NAME must be a function symbol, or ARGLIST and BODY must be set properly.")))
         (make-instance 'command
                        :name ',name
                        :docstring ,documentation
                        :fn ,fn
                        :sexp ,sexp)))))

(export-always 'make-mapped-command)
(defmacro make-mapped-command (function-symbol)
  "Define a command which `mapcar's FUNCTION-SYMBOL over a list of arguments."
  (let ((name (intern (str:concat (string FUNCTION-SYMBOL) "-*"))))
    `(make-command ,name (arg-list)
       (mapcar ',function-symbol arg-list))))

(export-always 'make-unmapped-command)
(defmacro make-unmapped-command (function-symbol)
  "Define a command which calls FUNCTION-SYMBOL over the first element of a list
of arguments."
  (let ((name (intern (str:concat (string FUNCTION-SYMBOL) "-1"))))
    `(make-command ,name (arg-list)
       (,function-symbol (first arg-list)))))

(export-always 'define-command)
(defmacro define-command (name (&rest arglist) &body body)
  "Define new command NAME.
`define-command' has a syntax similar to `defun'.
ARGLIST must be a list of optional arguments or key arguments.
This macro also defines two hooks, NAME-before-hook and NAME-after-hook.
When run, the command always returns the last expression of BODY.

Example:

\(define-command play-video-in-current-page (&optional (buffer (current-buffer)))
  \"Play video in the currently open buffer.\"
  (uiop:run-program (list \"mpv\" (object-string (url buffer)))))"
  (let ((documentation (if (stringp (first body))
                           (prog1
                               (list (first body))
                             (setf body (rest body)))
                           (warn (make-condition
                                  'command-documentation-style-warning
                                  :name name))))
        (declares (when (and (listp (first body))
                             (eq 'declare (first (first body))))
                    (prog1
                        (first body)
                      (setf body (rest body)))))
        (before-hook (intern (str:concat (symbol-name name) "-BEFORE-HOOK")))
        (after-hook (intern (str:concat (symbol-name name) "-AFTER-HOOK"))))
    `(progn
       (export-always ',before-hook)
       (defparameter ,before-hook (hooks:make-hook-void))
       (export-always ',after-hook)
       (defparameter ,after-hook (hooks:make-hook-void))
       (export-always ',name (symbol-package ',name))
       ;; We define the function at compile-time so that macros from the same
       ;; file can find the symbol function.
       (eval-when (:compile-toplevel :load-toplevel :execute)
         ;; We use defun to define the command instead of storing a lambda because we want
         ;; to be able to call the foo command from Lisp with (FOO ...).
         (defun ,name ,arglist
           ,@documentation
           ,declares
           (handler-case
               (progn
                 (hooks:run-hook ,before-hook)
                 ;; (log:debug "Calling command ~a." ',name)
                 ;; TODO: How can we print the arglist as well?
                 ;; (log:debug "Calling command (~a ~a)." ',name (list ,@arglist))
                 (prog1
                     (progn
                       ,@body)
                   (hooks:run-hook ,after-hook)))
             (nyxt-condition (c)
               (format t "~s" c)))))
       ;; Overwrite previous command:
       (setf *command-list* (delete ',name *command-list* :key #'name))
       (push (make-instance 'command
                            :name ',name
                            :docstring ,@documentation
                            :fn (symbol-function ',name)
                            :sexp '(define-command (,@arglist) ,@body))
             *command-list*))))

;; TODO: Update define-deprecated-command
(defmacro define-deprecated-command (name (&rest arglist) &body body)
  "Define NAME, a deprecated command.
This is just like a command.  It's recommended to explain why the function is
deprecated and by what in the docstring."
  (let ((documentation (if (stringp (first body))
                           (first body)
                           (warn (make-condition
                                  'command-documentation-style-warning
                                  :name name))))
        (body (if (stringp (first body))
                  (rest body)
                  body)))
    `(progn
       (define-command ,name ,arglist
         ,documentation
         (progn
           ;; TODO: Implement `warn'.
           (echo-warning "~a is deprecated." ',name)
           ,@body)))))

(defun nyxt-packages ()                 ; TODO: Export a customizable *nyxt-packages* instead?
  "Return all package designators that start with 'nyxt' plus Nyxt own libraries."
  (mapcar #'package-name
          (append (delete-if
                   (lambda (p)
                     (not (str:starts-with-p "NYXT" (package-name p))))
                   (list-all-packages))
                  (mapcar #'find-package
                          '(class-star
                            download-manager
                            history-tree
                            keymap
                            scheme
                            password
                            analysis
                            text-buffer)))))

(defun package-defined-symbols (&optional (external-package-designators (nyxt-packages))
                                  (user-package-designators '(:nyxt-user)))
  "Return the list of all external symbols interned in EXTERNAL-PACKAGE-DESIGNATORS
and all (possibly unexported) symbols in USER-PACKAGE-DESIGNATORS."
  (let ((symbols))
    (dolist (package (mapcar #'find-package external-package-designators))
      (do-external-symbols (s package symbols)
        (pushnew s symbols)))
    (dolist (package (mapcar #'find-package user-package-designators))
      (do-symbols (s package symbols)
        (when (eq (symbol-package s) package)
          (pushnew s symbols))))
    symbols))

(defun package-variables ()
  "Return the list of variable symbols in Nyxt-related-packages."
  (delete-if (complement #'boundp) (package-defined-symbols)))

(defun package-functions ()
  "Return the list of function symbols in Nyxt-related packages."
  (delete-if (complement #'fboundp) (package-defined-symbols)))

(defun package-classes ()
  "Return the list of class symbols in Nyxt-related-packages."
  (delete-if (lambda (sym)
               (not (and (find-class sym nil)
                         ;; Discard non-standard objects such as structures or
                         ;; conditions because they don't have public slots.
                         (mopu:subclassp (find-class sym) (find-class 'standard-object)))))
             (package-defined-symbols)))

(define-class slot ()
  ((name nil
         :type (or symbol null))
   (class-sym nil
              :type (or symbol null)))
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name)))

(defmethod object-string ((slot slot))
  (string-downcase (write-to-string (name slot))))

(defmethod object-display ((slot slot))
  (string-downcase (format nil "~s (~s)"
                           (name slot)
                           (class-sym slot))))

(defmethod prompter:object-attributes ((slot slot))
  `(("Name" ,(name slot))
    ("Class" ,(class-sym slot))))

(defun exported-p (sym)
  (eq :external
      (nth-value 1 (find-symbol (string sym)
                                (symbol-package sym)))))

(defun class-public-slots (class-sym)
  "Return the list of exported slots."
  (delete-if
   (complement #'exported-p)
   (mopu:slot-names class-sym)))

(defun package-slots ()
  "Return the list of all slot symbols in `:nyxt' and `:nyxt-user'."
  (alex:mappend (lambda (class-sym)
                  (mapcar (lambda (slot) (make-instance 'slot
                                                        :name slot
                                                        :class-sym class-sym))
                          (class-public-slots class-sym)))
                (package-classes)))

(defun package-methods ()               ; TODO: Unused.  Remove?
  (loop for sym in (package-defined-symbols)
        append (ignore-errors
                (closer-mop:generic-function-methods (symbol-function sym)))))

(defmethod mode-toggler-p ((command command))
  "Return non-nil if COMMAND is a mode toggler.
A mode toggler is a command of the same name as its associated mode."
  (ignore-errors
   (closer-mop:subclassp (find-class (name command) nil)
                         (find-class 'root-mode))))

(defun list-commands (&rest mode-symbols)
  "List commands.
Commands are instances of the `command' class.  When MODE-SYMBOLS are provided,
list only the commands that belong to the corresponding mode packages or of a
parent mode packages.  Otherwise list all commands.

If 'BASE-MODE is in MODE-SYMBOLS, mode togglers and commands from the
`nyxt-user' package are included.  This is useful since mode togglers are
usually part of their own mode / package and would not be listed otherwise.
For `nyxt-user' commands, users expect them to be listed out of the box without
extra fiddling."
  ;; TODO: Make sure we list commands of inherited modes.
  (let ((list-togglers-p (member 'base-mode mode-symbols)))
    (if mode-symbols
        (remove-if (lambda (c)
                     (and (or (not list-togglers-p)
                              (and (not (mode-toggler-p c))
                                   (not (eq (find-package 'nyxt-user)
                                            (symbol-package (name c))))))
                          (notany (lambda (m)
                                    (eq (symbol-package (name c))
                                        ;; root-mode does not have a mode-command.
                                        (alex:when-let ((mc (and (not (eq m 'root-mode))
                                                                 (mode-command m))))
                                          (symbol-package (name mc)))))
                                  mode-symbols)))
                   *command-list*)
        *command-list*)))

(defmethod object-string ((command command))
  (str:downcase (name command)))

(declaim (ftype (function (function) (or null command)) function-command))
(defun function-command (function)
  "Return the command associated to FUNCTION, if any."
  (find-if (lambda (cmd)
             (eq function (fn cmd)))
           (list-commands)))


(defun run (command &rest args)
  "Run COMMAND over ARGS and return its result.
This is blocking, see `run-async' for an asynchronous way to run commands."
  (let ((channel (make-channel 1)))
    (run-thread
      (calispel:! channel
               ;; Bind current buffer for the duration of the command.  This
               ;; way, if the user switches buffer after running a command
               ;; but before command termination, `current-buffer' will
               ;; return the buffer from which the command was invoked.
               (with-current-buffer (current-buffer)
                 (handler-case (apply #'funcall command args)
                   (nyxt-prompt-buffer-canceled ()
                     (log:debug "Prompt buffer interrupted")
                     nil)))))
    (calispel:? channel)))

(defun run-async (command &rest args)
  "Run COMMAND over ARGS asynchronously.
See `run' for a way to run commands in a synchronous fashion and return the
result."
  (run-thread
    (with-current-buffer (current-buffer) ; See `run' for why we bind current buffer.
      (handler-case (apply #'funcall command args)
        (nyxt-prompt-buffer-canceled ()
          (log:debug "Prompt buffer interrupted")
          nil)))))

(define-command noop ()                 ; TODO: Replace with ESCAPE special command that allows dispatched to cancel current key stack.
  "A command that does nothing.
This is useful to override bindings to do nothing."
  (values))
