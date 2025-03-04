;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(define-class download ()
  ((uri (error "URI required.")
        :documentation "A string representation of a URL to be shown in the
interface.")
   (status :unloaded
           :reader status
           :type (member :unloaded
                         :loading
                         :finished
                         :failed
                         :canceled)
           :documentation "Status of the download.")
   (status-text (make-instance 'user-interface:paragraph))
   (completion-percentage 0.0
                          :reader completion-percentage
                          :type float
                          :documentation "A number between 0 and 100
showing the percentage a download is complete.")
   (destination-path :initarg :destination-path
                     :reader destination-path
                     :documentation "A string represent where the file
will be downloaded to on disk.")
   (cancel-function nil
                    :type (or null function)
                    :reader cancel-function
                    :documentation "The function to call when
cancelling a download. This can be set by the download engine.")
   (cancel-button (make-instance 'user-interface:button
                                 :text "✕"
                                 :url (lisp-url '(echo "Can't cancel download.")))
                  :documentation "The download is referenced by its
URI. The URL for this button is therefore encoded as a funcall to
cancel-download with an argument of the URI to cancel.")
   (open-button (make-instance 'user-interface:button
                               :text "🗁"
                               :url (lisp-url '(echo "Can't open file, file path unknown.")))
                :documentation "The file name to open is encoded
within the button's URL when the destinaton path is set.")
   (progress-text (make-instance 'user-interface:paragraph))
   (progress (make-instance 'user-interface:progress-bar)))
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name))
  (:documentation "This class is used to represent a download within
the *Downloads* buffer. The browser class contains a list of these
download objects: `downloads'."))

(defun cancel-download (uri)
  "This function is called by the cancel-button with an argument of
the URI. It will search the URIs of all the existing downloads, if it
finds it, it will invoke its cancel-function."
  (alex:when-let ((download (find uri (downloads *browser*) :key #'uri :test #'equal)))
    (funcall (cancel-function download))
    (echo "Download cancelled: ~a." uri)))

(defmethod (setf cancel-function) (cancel-function (download download))
  (setf (slot-value download 'cancel-function) cancel-function)
  (setf (user-interface:url (cancel-button download))
        (lisp-url `(cancel-download ,(uri download)))))

(defmethod (setf status) (value (download download))
  (setf (slot-value download 'status) value)
  (setf (user-interface:text (status-text download))
        (format nil "Status: ~(~a~)." value)))

(defmethod (setf completion-percentage) (percentage (download download))
  (setf (slot-value download 'completion-percentage) percentage)
  (setf (user-interface:percentage (progress download))
        (completion-percentage download))
  (setf (user-interface:text (progress-text download))
        (format nil "Completion: ~,2f%." (completion-percentage download))))

(defmethod (setf destination-path) (path (download download))
  (check-type path string)
  (setf (slot-value download 'destination-path) path)
  (setf (user-interface:url (open-button download))
        (lisp-url `(nyxt::default-open-file-function ,path))))

(defmethod connect ((download download) buffer)
  "Connect the user-interface objects within the download to the
buffer. This allows the user-interface objects to update their
appearance in the buffer when they are setf'd."
  (user-interface:connect (status-text download) buffer)
  (user-interface:connect (progress-text download) buffer)
  (user-interface:connect (open-button download) buffer)
  (user-interface:connect (cancel-button download) buffer)
  (user-interface:connect (progress download) buffer))

;; TODO: Move to separate package
(define-mode download-mode ()
  "Display list of downloads."
  ((open-file-function #'default-open-file-function)
   (style
    (cl-css:css
     '((".download"
        :margin-top "10px"
        :padding-left "5px"
        :background-color "#F5F5F5"
        :border-radius "3px")
       (".download-url"
        :overflow "auto"
        :white-space "nowrap")
       (".download-url a"
        :font-size "small"
        :color "black")
       (".status p"
        :display "inline-block"
        :margin-right "10px")
       (".progress-bar-container"
        :height "20px"
        :width "100%")
       (".progress-bar-base"
        :height "100%"
        :background-color "lightgray")
       (".progress-bar-fill"
        :height "100%"
        :background-color "dimgray"))))))

#+linux
(defvar *xdg-open-program* "xdg-open")

(defun default-open-file-function (filename)
  "Open FILENAME.

Can be used as a `open-file-function'."
  (uiop:launch-program
   #+linux
   (list *xdg-open-program* (namestring filename))
   #+darwin
   (list "open" (namestring filename))))

(define-command list-downloads ()
  "Display a buffer listing all downloads.
We iterate through the browser's downloads to draw every single
download."
  (with-current-html-buffer (buffer "*Downloads*" 'download-mode)
    (markup:markup
     (:style (style buffer))
     (:style (style (make-instance 'download-mode)))
     (:h1 "Downloads")
     (:hr)
     (:div
      (loop for download in (downloads *browser*)
            for uri = (uri download)
            for status-text = (status-text download)
            for progress-text = (progress-text download)
            for progress = (progress download)
            for open-button = (open-button download)
            for cancel-button = (cancel-button download)
            do (connect download buffer)
            collect
               (markup:markup
                (:div :class "download"
                      (:p :class "download-buttons"
                          ;; TODO: Disable the buttons when download status is failed / canceled.
                          (markup:raw (user-interface:object-string cancel-button))
                          (markup:raw (user-interface:object-string open-button)))
                      (:p :class "download-url" (:a :href uri uri))
                      (:div :class "progress-bar-container"
                            (markup:raw (user-interface:object-string progress)))
                      (:div :class "status"
                            (markup:raw (user-interface:object-string progress-text))
                            (markup:raw (user-interface:object-string status-text))))))))))

(define-command download-url ()
  "Download the page or file of the current buffer."
  (download (current-buffer) (url (current-buffer))))

(define-class downloaded-files-source (file-source)
  ((prompter:must-match-p t)
   (prompter:constructor (mapcar #'destination-path (downloads *browser*)))
   ;; TODO: Extract to `file-source'?
   ;; TODO: Maybe extract `open-file-function' to `browser'?
   (prompter:actions
    (list (make-command open-file* (files)
            (let ((download-mode (find-submode (current-buffer) 'download-mode)))
              (funcall (open-file-function download-mode) (first files))))))))

(define-command download-open-file ()
  "Open a downloaded file."
  (prompt
   :prompt "Open file:"
   :sources (make-instance 'downloaded-files-source)))
