;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(define-parenscript add-overlay (overlay-style selection-rectangle-style)
  "Add a selectable overlay to the screen."
  (defparameter selection
    (ps:create x1 0 y1 0
               x2 0 y2 0
               set1 false
               set2 false))

  (defun add-stylesheet ()
    (unless (ps:chain document (get-element-by-id "nyxt-stylesheet"))
      (ps:let ((style-element (ps:chain document (create-element "style"))))
        (setf (ps:@ style-element id) "nyxt-stylesheet")
        (ps:chain document head (append-child style-element)))))

  (defun add-style (style)
    (ps:let ((style-element (ps:chain document (get-element-by-id "nyxt-stylesheet"))))
      (ps:chain style-element sheet (insert-rule style 0))))

  (defun add-overlay ()
    (ps:let ((element (ps:chain document (create-element "div"))))
      (add-style (ps:lisp overlay-style))
      (setf (ps:@ element id) "nyxt-overlay")
      (ps:chain document body (append-child element))))

  (defun add-selection-rectangle ()
    (ps:let ((element (ps:chain document (create-element "div"))))
      (add-style (ps:lisp selection-rectangle-style))
      (setf (ps:@ element id) "nyxt-rectangle-selection")
      (ps:chain document body (append-child element))))

  (defun update-selection-rectangle ()
    (ps:let ((element (ps:chain document (get-element-by-id "nyxt-rectangle-selection"))))
      (setf (ps:@ element style left) (ps:chain selection x1))
      (setf (ps:@ element style top) (ps:chain selection y1))
      (setf (ps:@ element style width)
            (- (ps:chain selection x2)
               (ps:chain selection x1)))
      (setf (ps:@ element style height)
            (- (ps:chain selection y2)
               (ps:chain selection y1)))))

  (defun add-listeners ()
    (setf (ps:chain document (get-element-by-id "nyxt-overlay") onmousemove)
          (lambda (e)
            (when (and (ps:chain selection set1)
                       (not (ps:chain selection set2)))
              (setf (ps:chain selection x2) (ps:chain e |pageX|))
              (setf (ps:chain selection y2) (ps:chain e |pageY|))
              (update-selection-rectangle))))
    (setf (ps:chain document (get-element-by-id "nyxt-overlay") onclick)
          (lambda (e)
            (if (not (ps:chain selection set1))
                (progn
                  (setf (ps:chain selection x1) (ps:chain e |pageX|))
                  (setf (ps:chain selection y1) (ps:chain e |pageY|))
                  (setf (ps:chain selection set1) true))
                (progn
                  (setf (ps:chain selection x2) (ps:chain e |pageX|))
                  (setf (ps:chain selection y2) (ps:chain e |pageY|))
                  (setf (ps:chain selection set2) true))))))

  (add-stylesheet)
  (add-overlay)
  (add-selection-rectangle)
  (add-listeners))

(define-command frame-element-select ()
  "Draw a frame around elements, select them."
  (let ((overlay-style (cl-css:css
                        '(("#nyxt-overlay"
                           :position "fixed"
                           :top "0"
                           :left "0"
                           :right "0"
                           :bottom "0"
                           :background "rgba(0,0,0,0.05)"
                           :z-index #.(1- (expt 2 31))))))
        (selection-rectangle-style (cl-css:css
                                    '(("#nyxt-rectangle-selection"
                                       :position "absolute"
                                       :top "0"
                                       :left "0"
                                       :background "rgba(0,0,0,0.10)"
                                       :z-index #.(1- (expt 2 30)))))))
    (add-overlay overlay-style
                 selection-rectangle-style)))

(define-parenscript get-selection ()
  "Get the intersecting elements"
  (defun qsa (context selector)
    "Alias of document.querySelectorAll"
    (ps:chain context (query-selector-all selector)))

  (defun element-in-selection (selection element)
    (ps:let ((element-rect (ps:chain element (get-bounding-client-rect)))
             (offsetX (ps:chain window |pageXOffset|))
             (offsetY (ps:chain window |pageYOffset|)))
      (if (and
           (<= (ps:chain element-rect left) (ps:chain selection x2))
           (>= (ps:chain element-rect right) (ps:chain selection x1))
           (<= (ps:chain element-rect top) (ps:chain selection y2))
           (>= (ps:chain element-rect bottom) (ps:chain selection y1)))
          t nil)))

  (defun object-create (element)
    (cond ((equal "A" (ps:@ element tag-name))
           (ps:create "type" "link" "href" (ps:@ element href) "body" (ps:@ element |innerHTML|)))
          ((equal "IMG" (ps:@ element tag-name))
           (ps:create "type" "img" "src" (ps:@ element src) "alt" (ps:@ element alt)))))

  (defun collect-selection (elements selection)
    "Check which elements are within a selection"
    (ps:chain |json| (stringify
                      (loop for element in elements
                            when (element-in-selection selection element)
                            collect (object-create element)))))

  (collect-selection (qsa document (list "a")) selection))

(define-class html-element ()
  ((body ""))
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name)))

(define-class link (html-element)
  ((url ""))
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name)))

(define-class image (html-element)
  ((alt "" :documentation "Alternative text for the image.")
   (url ""))
  (:accessor-name-transformer (hu.dwim.defclass-star:make-name-transformer name)))

(define-command frame-element-get-selection ()
  "Get the selected elements."
  (loop for element in (cl-json:decode-json-from-string (get-selection))
        collect (str:string-case (alex:assoc-value element :type)
                  ("link"
                   (make-instance 'link
                                  :url (alex:assoc-value element :href)
                                  :body (plump:text (plump:parse (alex:assoc-value element :body)))))
                  ("img"
                   (make-instance 'image
                                  :url (alex:assoc-value element :src)
                                  :alt (alex:assoc-value element :alt))))))

(define-command frame-element-clear ()
  "Clear the selection frame."
  (pflet ((remove-overlay ()
            (ps:chain document (get-element-by-id "nyxt-rectangle-selection") (remove))
            (ps:chain document (get-element-by-id "nyxt-overlay") (remove))))
    (remove-overlay)))
