;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.
;;;
;;; This file defines miscellaneous utility functions;
;;; some of them depend on the lisp implementation.
;;;

(in-package :cl-gpu)

;;; Misc

(def macro with-capturing-names ((namelist &key prefix) &body code)
  "Defines symbols in the list as symbols in the current package with the same names."
  `(let ,(mapcar (lambda (name)
                   `(,name (symbolicate ,@(ensure-list prefix) ',name)))
                 namelist)
     ,@code))

(def function layered-method-qualifiers (options)
  (flatten (list
            (awhen (or (getf options :in-layer)
                       (getf options :in))
              (list :in it))
            (getf options :mode))))

(def function remove-form-by-name (forms name &key (type 't))
  (check-type name symbol)
  (remove-if (lambda (item)
               (and item
                    (or (eql type t)
                        (typep item type))
                    (eq (name-of item) name)))
             forms))

(define-modify-macro remove-form-by-name! (name &rest flags) remove-form-by-name)

(def function make-type-arg (sym)
  (format-symbol (symbol-package sym) "~A/TYPE" sym))

(def macro make-builtin-handler-method (builtin-name
                                        builtin-args
                                        method-name-selector
                                        body-forms
                                        &key method-args top-decls let-decls prefix)
  "Non-hygienic helper for stuff like c-code-emitter.
Defines variables: assn? rq-args opt-args rest-arg aux-args."
  `(let ((assn? nil))
     (when (consp ,builtin-name)
       (assert (eql (first ,builtin-name) 'setf))
       (setf assn? t ,builtin-name (second ,builtin-name)))
     (multiple-value-bind (rq-args opt-args rest-arg kwd other aux-args)
         (parse-ordinary-lambda-list ,builtin-args)
       (declare (ignorable rq-args opt-args rest-arg aux-args))
       (when (or kwd other)
         (error "Keyword matching not supported"))
       `(def layered-method ,,method-name-selector
          ,@(layered-method-qualifiers -options-)
          ((-name- (eql ',,builtin-name)) -form- ,@,method-args)
          ,@,(if top-decls ``((declare ,@,top-decls)))
          (let* ((-arguments- (arguments-of -form-))
                 ,@(if assn?
                       `((-value- (value-of -form-)))))
            ,@(aif ,let-decls `((declare ,@it)))
            (,@,(or prefix ''(progn))
              (destructuring-bind ,,builtin-args
                  -arguments-
                ,@,body-forms)))))))

(def function adjust-parents-to (form parent)
  (if (listp form)
      (dolist (item form)
        (adjust-parents-to item parent))
      (setf (parent-of form) parent)))

(def macro adjust-parents ((accessor form))
  `(adjust-parents-to (,accessor ,form) ,form))

;;; A helper for externalizable objects

(def function object-slots-excluding (object &rest names)
  (reduce (lambda (slots name)
            (delete name slots))
          names
          :initial-value (mapcar #'closer-mop:slot-definition-name
                                 (closer-mop:class-slots (class-of object)))))

(def class save-slots-mixin ()
  ())

(defparameter *excluded-save-slots* nil)

(def method make-load-form ((object save-slots-mixin) &optional env)
  (if *excluded-save-slots*
      (make-load-form-saving-slots
       object :environment env
       :slot-names (apply #'object-slots-excluding object *excluded-save-slots*))
      (make-load-form-saving-slots object :environment env)))

(def macro with-exclude-save-slots (slots &body code)
  `(let ((*excluded-save-slots* (append ',slots *excluded-save-slots*)))
     ,@code))

;;; Temporary files

(def function open-temp-file (base-name &key
                                        (direction :output)
                                        (element-type 'character)
                                        (external-format :default))
  "Opens a new temporary file, using base-name as template."
  (loop
     with name = (pathname base-name)
     for id from (get-universal-time)
     do
       (let* ((fname (format nil "~A~A" (pathname-name name) id))
              (path (make-pathname :name fname :defaults name))
              (file (open path :direction direction :if-exists nil
                          :element-type element-type
                          :external-format external-format)))
         (when file
           (return (values file path))))))

(def function delete-if-exists (path)
  (when (probe-file path)
    (delete-file path)))

(def macro with-temp-file ((path stream path-template &rest open-flags) write-code &body code)
  "Takes care of creating and removing a new temporary file. Stream is accessible inside write-code."
  (with-unique-names (temp-path wrtp ssave)
    `(let (,path)
       (unwind-protect
            (progn
              (let (,ssave ,wrtp)
                (unwind-protect
                     (multiple-value-bind (,stream ,temp-path)
                         (open-temp-file ,path-template ,@open-flags)
                       (setf ,path ,temp-path ,ssave ,stream)
                       ,write-code
                       (setf ,wrtp t))
                  (when ,ssave
                    (close ,ssave :abort (not ,wrtp)))))
              ,@code)
         (when ,path
           (delete-if-exists ,path))))))

(defun system-command (cmd)
  #+ecl (ext:system cmd)
  #+ccl (ccl::os-command cmd)
  #-(or ecl ccl) (error "Not implemented"))

;;; Array I/O

#+ccl
(def function double-offset-fixup (ivector)
  (case (ccl::typecode ivector)
    ((#.target::subtag-double-float-vector
      #+64-bit-target #.target::subtag-s64-vector
      #+64-bit-target #.target::subtag-u64-vector
      #+64-bit-target #.target::subtag-fixnum-vector)
     #.(- target::misc-dfloat-offset
          target::misc-data-offset))
    (otherwise 0)))

#+ccl
(def function array-ivector-range (arr)
  (multiple-value-bind (ivector ofs)
      (ccl::array-data-and-offset arr)
    (let* ((typecode (ccl::typecode ivector))
           (fixup (double-offset-fixup ivector))
           (base (+ fixup (ccl::subtag-bytes typecode ofs)))
           (size (ccl::subtag-bytes typecode (array-total-size arr))))
      (values ivector base size))))

#+ecl
(defun %array-address (arr)
  "Return the address of array's data."
  (check-type arr array)
  (ffi:c-inline (arr) (object) :unsigned-long
    "switch (#0->array.elttype) {
       case aet_object: FEerror(\"Not a specialized array: ~S\", 1, #0); break;
       case aet_bit: FEerror(\"Cannot get a pointer to a bit array: ~S\", 1, #0); break;
       default: @(return) = (unsigned long) #0->array.self.b8;
     }"))

(def macro with-pointer-to-array ((ptr-var arr) &body code)
  #+ccl
  (with-unique-names (iv bv)
    `(multiple-value-bind (,iv ,bv) (array-ivector-range ,arr)
       (ccl:with-pointer-to-ivector (,ptr-var ,iv)
         (incf-pointer ,ptr-var ,bv)
         ,@code)))
  #+ecl
  `(let ((,ptr-var (make-pointer (%array-address ,arr))))
     ,@code))

(def (function e) write-array-bytes (array stream)
  "Write the contents of the array to a binary stream."
  #+ecl (write-sequence (ext:array-raw-data array) stream)
  #+ccl (multiple-value-bind (ivector base size)
            (array-ivector-range array)
          (ccl:stream-write-ivector stream ivector base size))
  #-(or ecl ccl) (error "Not implemented"))

(def (function e) read-array-bytes (array stream)
  "Restore the contents of the array from a binary stream."
  #+ecl (read-sequence (ext:array-raw-data array) stream)
  #+ccl (multiple-value-bind (ivector base size)
            (array-ivector-range array)
          (ccl:stream-read-ivector stream ivector base size))
  #-(or ecl ccl) (error "Not implemented"))

(def function array-type-tag (array)
  (ecase (lisp-to-foreign-elt-type
          (array-element-type array))
    (:float #x46525241)
    (:double #x44525241)
    (:int8 #x62525241)
    (:uint8 #x42525241)
    (:int16 #x73525241)
    (:uint16 #x53525241)
    (:int32 #x69525241)
    (:uint32 #x49525241)
    (:int64 #x71525241)
    (:uint64 #x51525241)))

(def function array-type-by-tag (tag)
  (foreign-to-lisp-elt-type
   (ecase tag
     (#x46525241 :float)
     (#x44525241 :double)
     (#x62525241 :int8)
     (#x42525241 :uint8)
     (#x73525241 :int16)
     (#x53525241 :uint16)
     (#x69525241 :int32)
     (#x49525241 :uint32)
     (#x71525241 :int64)
     (#x51525241 :uint64))))

(def (function e) write-array (array stream)
  "Store the array to a binary stream with meta-data."
  (let* ((dims (list* (array-type-tag array)
                      (array-rank array)
                      (array-dimensions array)))
         (header (make-array (length dims)
                             :element-type '(unsigned-byte 32)
                             :initial-contents dims)))
    (declare (dynamic-extent dims header))
    (write-array-bytes header stream)
    (write-array-bytes array stream)))

(def (function e) read-array (array stream &key allocate)
  "Restore data written using write-array."
  (let ((base-hdr (make-array 2 :element-type '(unsigned-byte 32))))
    (declare (dynamic-extent base-hdr))
    (read-array-bytes base-hdr stream)
    (let ((type (array-type-by-tag (aref base-hdr 0)))
          (dims (make-array (aref base-hdr 1)
                            :element-type '(unsigned-byte 32))))
      (declare (dynamic-extent dims))
      (read-array-bytes dims stream)
      (if array
          (let ((adims (array-dimensions array)))
            (unless (equal (upgraded-array-element-type type)
                           (array-element-type array))
              (error "Type mismatch: array ~A, file ~A"
                     (array-element-type array) type))
            (unless (and (eql (length dims) (length adims))
                         (every #'eql adims dims))
              (error "Dimension mismatch: array ~A, file ~A" adims dims)))
          (progn
            (unless allocate
              (cerror "allocate" "Array is nil in read-array"))
            (setf array (make-array (coerce dims 'list)
                                    :element-type type))))
      (read-array-bytes array stream)
      array)))

;;; Array copying

(def function compute-strides (dims max-size)
  (let ((strides (maplist (lambda (rdims)
                            (reduce #'* rdims))
                          dims)))
    (when (> (first strides) max-size)
      (error "Dimensions ~S exceed the block size ~A" dims max-size))
    (values strides)))

(def function to-uint32-vector (list)
  (make-array (length list) :element-type '(unsigned-byte 32) :initial-contents list))

(def function %portable-copy-array-data (src-array src-ofs dest-array dest-ofs count)
  (declare (type fixnum src-ofs dest-ofs count)
           (type array src-array dest-array))
  (if (and (eq dest-array src-array) (> dest-ofs src-ofs))
      (let ((dest-base (+ dest-ofs count -1))
            (src-base (+ src-ofs count -1)))
        (declare (type fixnum dest-base src-base))
        (dotimes (i count)
          (declare (fixnum i))
          (setf (row-major-aref dest-array (- dest-base i))
                (row-major-aref src-array (- src-base i)))))
      (dotimes (i count)
        (declare (fixnum i))
        (setf (row-major-aref dest-array (+ dest-ofs i))
              (row-major-aref src-array (+ src-ofs i))))))

(def function %copy-array-data (src-array src-ofs dest-array dest-ofs count)
  (declare (type fixnum src-ofs dest-ofs count)
           (type array src-array dest-array))
  #+ccl
  (bind (((:values src-vec src-delta)   (ccl::array-data-and-offset src-array))
         ((:values dest-vec dest-delta) (ccl::array-data-and-offset dest-array))
         (src-index (+ src-delta src-ofs))
         (dest-index (+ dest-delta dest-ofs)))
    (cond
      ;; Reference vector
      ((and (ccl::gvectorp src-vec) (ccl::gvectorp dest-vec))
       (ccl::%copy-gvector-to-gvector src-vec src-index dest-vec dest-index count))
      ;; Unaligned bit move
      ((and (or (bit-vector-p src-vec) (bit-vector-p dest-vec))
            (or (logtest src-index 7) (logtest dest-index 7) (logtest count 7)))
       (%portable-copy-array-data src-vec src-index dest-vec dest-index count))
      ;; Raw data vector
      ((and (ccl::ivectorp src-vec) (ccl::ivectorp dest-vec))
       (let* ((type (ccl::typecode dest-vec))
              (fixup (double-offset-fixup dest-vec))
              (src-byte (+ fixup (ccl::subtag-bytes type src-index)))
              (dest-byte (+ fixup (ccl::subtag-bytes type dest-index)))
              (byte-count (ccl::subtag-bytes type count)))
         (assert (eql type (ccl::typecode src-vec)))
         (ccl::%copy-ivector-to-ivector src-vec src-byte dest-vec dest-byte byte-count)))
      ;; Unknown
      (t (error "Array type mismatch"))))
  #+ecl
  (if (and (eq dest-array src-array) (> dest-ofs src-ofs))
      (%portable-copy-array-data src-array src-ofs dest-array dest-ofs count)
      (ffi:c-inline
          (dest-array dest-ofs src-array src-ofs count)
          (:object :int :object :int :int) :void
        "ecl_copy_subarray(#0,#1,#2,#3,#4)"
        :one-liner t :side-effects t))
  #-(or ccl ecl)
  (%portable-copy-array-data src-array src-ofs dest-array dest-ofs count))

(declaim (ftype (function (fixnum fixnum fixnum fixnum t) fixnum)
                adjust-copy-count))

(def function adjust-copy-count (src-size src-ofs dest-size dest-ofs count)
  (assert (and (>= dest-ofs 0) (>= src-ofs 0)))
  (if (eql count t)
      (max 0 (min (- dest-size dest-ofs)
                  (- src-size src-ofs)))
      (progn
        (assert (and (>= count 0)
                     (<= (+ dest-ofs count) dest-size)
                     (<= (+ src-ofs count) src-size))
                (count)
                "Copy region out of bounds: ~A (~A left) -> ~A (~A left): ~A elements."
                src-ofs (- src-size src-ofs)
                dest-ofs (- dest-size dest-ofs) count)
        count)))

(def (function e) copy-array-data (src-array src-ofs dest-array dest-ofs count)
  "Copy data elements between arrays. If count is t, it is deduced."
  (assert (equal (array-element-type dest-array)
                 (array-element-type src-array)))
  (let ((dest-size (array-total-size dest-array))
        (src-size (array-total-size src-array)))
    ;; Verify/deduce the region:
    (let ((rcount (adjust-copy-count src-size src-ofs dest-size dest-ofs count)))
      ;; Copy data
      (when (> rcount 0)
        (%copy-array-data src-array src-ofs dest-array dest-ofs rcount))
      ;; Return the count
      rcount)))

;;; Unique identifiers

(defvar *unique-id-template* (make-hash-table :test #'equal))

(def definer reserved-c-names (&rest names)
  `(dolist (id ',names)
     (setf (gethash id *unique-id-template*) 0)))

(def reserved-c-names
    "break" "case" "char" "const" "continue" "default" "do"
    "double" "else" "enum" "extern" "float" "for" "goto" "if"
    "inline" "int" "long" "register" "return" "short" "signed"
    "sizeof" "static" "struct" "switch" "typedef" "union"
    "unsigned" "void" "volatile" "while"
    "restrict" "_Bool" "_Complex" "_Imaginary"
    "uint_least16_t" "uint_least32_t"
    "asm" "bool" "catch" "class" "const_cast" "delete" "dynamic_cast"
    "explicit" "export" "false" "friend" "mutable" "namespace"
    "new" "operator" "private" "protected" "public" "reinterpret_cast"
    "static_cast" "template" "this" "throw" "true" "try" "typeid"
    "typename" "using" "virtual" "wchar_t" "typeof"
    "nil" "t" "_t")

(def function make-c-name-table ()
  (copy-hash-table *unique-id-template* :test #'equal))

(def function symbol-to-c-name (name)
  "Converts the symbol name to a suitable C identifier."
  (coerce (loop
             for char across (string-downcase (symbol-name name))
             and prev-char = nil then char
             ;; Can't begin with a number
             when (and (digit-char-p char) (null prev-char))
               collect #\N
             ;; Alphanumeric: verbatim
             if (alphanumericp char) collect char
             ;; Dash to underscore, and don't repeat
             else if (member char '(#\_ #\-))
               when (not (eql prev-char #\_))
                 collect (setf char #\_)
               end
             ;; Others: use the code
             else append (coerce (format nil "U~X" (char-code char)) 'list))
          'string))

(def function unique-c-name (name table)
  "Makes a unique C name using the table for duplicate avoidance."
  (labels ((handle (name)
             (if (gethash name table)
                 (handle (format nil "~AX~A" name
                                 (incf (gethash name table))))
                 (progn
                   (setf (gethash name table) 0)
                   name))))
    (handle (symbol-to-c-name name))))
