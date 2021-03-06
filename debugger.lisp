;;;; debugger.lisp

(in-package #:portable-condition-system)

;;; Debugger interface

(defvar *debugger-hook* nil)

(defgeneric invoke-debugger (datum))

(defmethod invoke-debugger ((condition condition))
  (when *debugger-hook*
    (let ((hook *debugger-hook*)
          (*debugger-hook* nil))
      (funcall hook condition hook)))
  (standard-debugger condition))

(defmethod invoke-debugger (datum)
  (let* ((datum (or datum "Debug"))
         (condition (coerce-to-condition datum '() 'simple-condition 'debug)))
    (standard-debugger condition)))

(defun break (&optional (format-control "Break") &rest format-arguments)
  (with-simple-restart (continue "Return from BREAK.")
    (invoke-debugger
     (make-condition 'simple-condition
                     :format-control format-control
                     :format-arguments format-arguments)))
  nil)

;;; DEFINE-COMMAND

(defgeneric run-debugger-command (command stream condition &rest arguments)
  (:method (command stream condition &rest arguments)
    (declare (ignore arguments))
    (format stream "~&;; Unknown command: ~S~%" command)))

(defmacro define-command (name (stream condition &rest arguments) &body body)
  (let ((command (gensym "COMMAND"))
        (arguments-var (gensym "ARGUMENTS")))
    `(defmethod run-debugger-command
         ((,command (eql ,name)) ,stream ,condition &rest ,arguments-var)
       (destructuring-bind ,arguments ,arguments-var ,@body))))

;;; Debugger commands

(defvar *debug-level* 0)

(define-command :eval (stream condition &optional form)
  (let ((level *debug-level*))
    (with-simple-restart (abort "Return to debugger level ~D." level)
      (let* ((real-form (or form (read stream)))
             (- real-form)
             (values (multiple-value-list (eval real-form))))
        (format stream "~&~{~S~^~%~}" values)
        (values values real-form)))))

(define-command :report (stream condition &optional (level *debug-level*))
  (format stream "~&;; Debugger level ~D entered on ~S:~%"
          level (type-of condition))
  (handler-case (let* ((report (princ-to-string condition))
                       (lines (split-sequence #\Newline report
                                              :remove-empty-subseqs t)))
                  (format stream "~&~{;; ~A~%~}" lines))
    (error () (format stream "~&;; #<error while printing condition>~%"))))

(define-command :condition (stream condition)
  (run-debugger-command :eval stream condition condition))

(define-command :abort (stream condition)
  (let ((restart (find-restart 'abort condition)))
    (if restart
        (invoke-restart-interactively restart)
        (format stream "~&;; There is no active ABORT restart.~%"))))

(define-command :q (stream condition)
  (run-debugger-command :abort stream condition))

(define-command :continue (stream condition)
  (let ((restart (find-restart 'continue condition)))
    (if restart
        (invoke-restart-interactively restart)
        (format stream "~&;; There is no active CONTINUE restart.~%"))))

(define-command :c (stream condition)
  (run-debugger-command :c stream condition))

(defun restart-max-name-length (restarts)
  (flet ((name-length (restart) (length (string (restart-name restart)))))
    (reduce #'max (mapcar #'name-length restarts))))

(define-command :restarts (stream condition)
  (format stream "~&;; Available restarts:~%")
  (loop with restarts = (compute-restarts condition)
        with max-name-length = (restart-max-name-length restarts)
        for i from 0
        for restart in restarts
        do (format stream ";; ~2,' D: [~vA] ~A~%"
                   i max-name-length (restart-name restart) restart)))

(define-command :restart (stream condition &optional n)
  (let* ((n (or n (read stream)))
         (restart (nth n (compute-restarts condition))))
    (if restart
        (invoke-restart-interactively restart)
        (format stream "~&;; There is no restart with number ~D." n))))

(defvar *help-hooks* '())

(define-command :help (stream condition)
  (format stream "~&~
;; This is the standard debugger of the Portable Condition System.
;; The debugger read-eval-print loop supports the standard REPL variables:
;;   *   **   ***   +   ++   +++   /   //   ///   -
;;
;; Available debugger commands:
;;  :HELP              Show this text.
;;  :EVAL <form>       Evaluate a form typed after the :EVAL command.
;;  :REPORT            Report the condition the debugger was invoked with.
;;  :CONDITION         Return the condition the debugger was invoked with.
;;  :RESTARTS          Print available restarts.
;;  :RESTART <n>, <n>  Invoke a restart with the given number.")
  (when (find-restart 'abort condition)
    (format stream "~&;;  :ABORT, :Q         Invoke an ABORT restart.~%"))
  (when (find-restart 'continue condition)
    (format stream "~&;;  :CONTINUE, :C      Invoke a CONTINUE restart.~%"))
  (dolist (hook *help-hooks*)
    (funcall hook stream condition))
  (format stream "~&~
;;
;; Any non-keyword non-integer form is evaluated."))

;;; Debugger implementation

(defun read-eval-print-command (stream condition)
  (format t "~&[~D] Debug> "*debug-level*)
  (let* ((thing (read stream)))
    (multiple-value-bind (values actual-thing)
        (typecase thing
          (keyword (run-debugger-command thing stream condition))
          (integer (run-debugger-command :restart stream condition thing))
          (t (run-debugger-command :eval stream condition thing)))
      (unless actual-thing (setf actual-thing thing))
      (prog1 values
        (shiftf /// // / values)
        (shiftf *** ** * (first values))
        (shiftf +++ ++ + actual-thing)))))

(defun standard-debugger (condition &optional (stream *debug-io*))
  (let ((*debug-level* (1+ *debug-level*)))
    (run-debugger-command :report stream condition *debug-level*)
    (format stream "~&;; Type :HELP for available commands.~%")
    (loop (read-eval-print-command stream condition))))
