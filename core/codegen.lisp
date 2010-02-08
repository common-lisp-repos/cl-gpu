;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.

(in-package :cl-gpu)

;;; Code generation function prototypes

(def layered-function generate-c-code (obj)
  (:documentation "Produces a C code representation of object"))

(def layered-function generate-var-ref (obj)
  (:documentation "Returns expression for referencing this var"))

(def layered-function generate-array-dim (obj idx)
  (:documentation "Generates accessor for the dimension"))

(def layered-function generate-array-size (obj)
  (:documentation "Generates accessor for the full array size."))

(def layered-function generate-array-extent (obj)
  (:documentation "Generates accessor for the full array extent."))

(def layered-function generate-array-stride (obj idx)
  (:documentation "Generates accessor for the stride"))

(def layered-function compute-field-layout (obj start-offset)
  (:documentation "Aligns the fields in the object")
  (:method ((objs list) start-offset)
    (let* ((fields (mapcan (lambda (item)
                             (multiple-value-bind (items rofs)
                                 (compute-field-layout item start-offset)
                               (setf start-offset rofs)
                               items))
                           objs)))
      (values fields start-offset))))

(def layered-function generate-invoker-form (obj)
  (:documentation "Creates a lambda form to invoke the kernel."))

;; Misc

(def layered-function c-type-string (type)
  (:documentation "Return a string that represents the type in C")
  (:method (type)
    (ecase type
      (:void "void")
      (:float "float")
      (:double "double")
      (:uint8 "unsigned char")
      (:int8 "char")
      (:uint16 "unsigned short")
      (:int16 "short")
      (:uint32 "unsigned int")
      (:int32 "int"))))

(def layered-function c-type-size (type)
  (:documentation "Return the size of the type in bytes")
  (:method (type)
    (ecase type
      (:float 4)
      (:double 8)
      (:uint8 1)
      (:int8 1)
      (:uint16 2)
      (:int16 2)
      (:uint32 4)
      (:int32 4))))

(def layered-function c-type-alignment (type)
  (:documentation "Return the alignment requirement of the type in bytes")
  (:method (type)
    (ecase type
      (:float 4)
      (:double 8)
      (:uint8 1)
      (:int8 1)
      (:uint16 2)
      (:int16 2)
      (:uint32 4)
      (:int32 4))))

(def (function i) align-offset (offset alignment)
  (logand (+ offset alignment -1) (lognot (1- alignment))))

(def (function i) align-for-type (offset type)
  (align-offset offset (c-type-alignment type)))

(define-modify-macro align-for-typef (type) align-for-type)

;;; Global variables

(def layered-method generate-c-code ((var gpu-global-var))
  (with-slots (c-name item-type dimension-mask static-asize) var
    (cond
      ;; Fixed-size array
      (static-asize
       (format nil "~A ~A[~A];"
               (c-type-string item-type) c-name
               static-asize))
      ;; Dynamic array
      (dimension-mask
       (format nil "struct {~%  ~A *val;
  unsigned size;~%  unsigned dim[~A];
  unsigned ext;~%  unsigned step[~A];~%} ~A;"
               (c-type-string item-type)
               (length dimension-mask)
               (1- (length dimension-mask))
               c-name))
      ;; Scalar
      (t (format nil "~A ~A;" (c-type-string item-type) c-name)))))

(def layered-method generate-var-ref ((obj gpu-global-var))
  (with-slots (c-name) obj
    (if (dynarray-var? obj)
        (format nil "~A.val" c-name)
        c-name)))

(def layered-method generate-array-dim ((obj gpu-global-var) idx)
  (with-slots (c-name dimension-mask) obj
    (or (aref dimension-mask idx)
        (format nil "~A.dim[~A]" c-name idx))))

(def layered-method generate-array-size ((obj gpu-global-var))
  (with-slots (c-name dimension-mask static-asize) obj
    (assert dimension-mask)
    (or static-asize
        (format nil "~A.size" c-name))))

(def layered-method generate-array-extent ((obj gpu-global-var))
  (with-slots (c-name static-asize) obj
    (or static-asize
        (format nil "~A.ext" c-name))))

(def layered-method generate-array-stride ((obj gpu-global-var) idx)
  (with-slots (c-name dimension-mask static-asize) obj
    (cond (static-asize
           (reduce #'* dimension-mask :start (1+ idx)))
          (dimension-mask
           (assert (and (>= idx 0)
                        (< idx (1- (length dimension-mask)))))
           (format nil "~A.step[~A]" c-name idx))
          (t (error "Not an array")))))

;;; Function arguments

(def layered-method generate-c-code ((obj gpu-argument))
  (with-slots (c-name item-type dimension-mask static-asize
                      include-size? included-dims
                      include-extent? included-strides) obj
    (cond ((null dimension-mask)
           (format nil "~A ~A" (c-type-string item-type) c-name))
          (static-asize
           (format nil "~A *~A" (c-type-string item-type) c-name))
          (t
           (list*
            (format nil "~A *~A" (c-type-string item-type) c-name)
            (if (not static-asize)
                (nconc (if include-size?
                           (list (format nil "unsigned ~A__D" c-name)))
                       (loop for i from 0 for flag across included-dims
                          when flag collect
                            (format nil "unsigned ~A__D~A" c-name i))
                       (if include-extent?
                           (list (format nil "unsigned ~A__X" c-name)))
                       (loop for i from 0 for flag across included-strides
                          when flag collect
                            (format nil "unsigned ~A__S~A" c-name i)))))))))

(def layered-method compute-field-layout ((obj gpu-argument) start-offset)
  (with-slots (c-name item-type dimension-mask static-asize
                      include-size? included-dims
                      include-extent? included-strides) obj
    (let* ((base-type (if dimension-mask :pointer item-type))
           (size (c-type-size base-type)))
      (align-for-typef start-offset base-type)
      (when (and dimension-mask (null static-asize))
        (let* ((woffset (+ start-offset size)))
          (align-for-typef woffset :uint32)
          (incf woffset
                (* (c-type-size :uint32)
                   (+ (if include-size? 1 0)
                      (if include-extent? 1 0)
                      (loop for flag across included-dims count flag)
                      (loop for flag across included-strides count flag))))
          (setf size (- woffset start-offset))))
      (values (list (list obj start-offset size))
              (+ start-offset size)))))

(def layered-method generate-var-ref ((obj gpu-argument))
  (with-slots (c-name) obj
    c-name))

(def macro with-ensure-unlocked ((obj expr) &body code)
  `(progn
     (unless ,expr
       (assert (not (includes-locked? ,obj)))
       (setf ,expr t))
     ,@code))

(def layered-method generate-array-dim ((obj gpu-argument) idx)
  (with-slots (c-name dimension-mask included-dims) obj
    (or (aref dimension-mask idx)
        (with-ensure-unlocked (obj (aref included-dims idx))
          (format nil "~A__D~A" c-name idx)))))

(def layered-method generate-array-size ((obj gpu-argument))
  (with-slots (c-name dimension-mask static-asize include-size?) obj
    (assert dimension-mask)
    (or static-asize
        (with-ensure-unlocked (obj include-size?)
          (format nil "~A__D" c-name)))))

(def layered-method generate-array-extent ((obj gpu-argument))
  (with-slots (c-name static-asize include-extent?) obj
    (or static-asize
        (with-ensure-unlocked (obj include-extent?)
          (format nil "~A__X" c-name)))))

(def layered-method generate-array-stride ((obj gpu-argument) idx)
  (with-slots (c-name dimension-mask static-asize included-strides) obj
    (cond (static-asize
           (reduce #'* dimension-mask :start (1+ idx)))
          (dimension-mask
           (with-ensure-unlocked (obj (aref included-strides idx))
             (format nil "~A__S~A" c-name idx)))
          (t (error "Not an array")))))

(def layered-method compute-field-layout ((obj gpu-function) start-offset)
  (compute-field-layout (arguments-of obj) start-offset))

;;; Top-level constructs

(def layered-method generate-c-code ((obj gpu-function))
  (with-slots (c-name return-type arguments body) obj
    (format nil "~A ~A(~{~A~^, ~}) {~%~A~%}~%"
            (c-type-string return-type) c-name
            (flatten (mapcar #'generate-c-code arguments))
            body)))

(def layered-method generate-c-code ((obj gpu-module))
  (with-slots (globals functions kernels) obj
    (format nil "/*Globals*/~%~%~{~A~%~}~%/*Functions*/~%~%~{~A~%~}~%/*Kernels*/~%~%~{~A~%~}"
            (mapcar #'generate-c-code globals)
            (mapcar #'generate-c-code functions)
            (mapcar #'generate-c-code kernels))))

