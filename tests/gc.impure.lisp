;;;; gc tests

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;
;;;; This software is in the public domain and is provided with
;;;; absoluely no warranty. See the COPYING and CREDITS files for
;;;; more information.

(in-package :cl-user)

(defvar *weak-vect* (make-weak-vector 8))
(with-test (:name :weak-vector)
  (let ((a *weak-vect*)
        (random-symbol (make-symbol "FRED")))
    (setf (aref a 0) (cons 'foo 'bar)
          (aref a 1) (format nil "Time is: ~D~%" (get-internal-real-time))
          (aref a 2) 'interned-symbol
          (aref a 3) random-symbol
          (aref a 4) 18
          (aref a 5) (+ most-positive-fixnum (random 100) (random 100))
          (aref a 6) (make-hash-table))
    (assert (typep (aref a 5) 'bignum))
    (assert (weak-vector-p a))
    (sb-sys:scrub-control-stack)
    (gc)
    (assert (eq (aref a 2) 'interned-symbol))
    (assert (eq (aref a 3) random-symbol))
    (assert (= (aref a 4) 18))
    ;; broken cells are the cons, string, bignum, hash-table, plus one NIL
    ;; cell that was never assigned into
    (assert (= (count nil *weak-vect*) 5))))

;;; Make sure MAP-REFERENCING-OBJECTS doesn't spuriously treat raw bits as
;;; potential pointers. Also make sure it sees the SYMBOL-INFO slot.
(defstruct afoo (slot nil :type sb-ext:word))
(defvar *afoo* (make-afoo :slot (sb-kernel:get-lisp-obj-address '*posix-argv*)))
(with-test (:name :map-referencing-objs)
  (sb-vm::map-referencing-objects (lambda (x) (assert (not (typep x 'afoo))))
                                  :dynamic '*posix-argv*)
  (let ((v (sb-kernel:symbol-info 'satisfies)) referers)
    (sb-vm::map-referencing-objects (lambda (referer) (push referer referers))
                                    #+gencgc :dynamic #-gencgc :static v)
    #+immobile-space
    (sb-vm::map-referencing-objects (lambda (referer) (push referer referers))
                                    :immobile v)
    (assert (member 'satisfies referers))))

;; Assert something about *CURRENT-THREAD* seeing objects that it just consed.
(with-test (:name :m-a-o-threadlocally-precise
                  :skipped-on (:or (:not (:and :gencgc :sb-thread))
                                   :interpreter))
  (let ((before (make-array 4))
        (after  (make-array 4 :initial-element 0)))
    (flet ((countit (obj type size)
             (declare (ignore type size))
             (symbol-macrolet ((n-conses     (aref after 1))
                               (n-bitvectors (aref after 2))
                               (n-symbols    (aref after 3))
                               (n-other      (aref after 0)))
               (typecase obj
                 (list       (incf n-conses))
                 (bit-vector (incf n-bitvectors))
                 (symbol     (incf n-symbols))
                 (t          (incf n-other))))))
      (sb-vm:map-allocated-objects #'countit :all)
      (replace before after)
      (fill after 0)
      ;; expect to see 1 cons, 1 bit-vector, 1 symbol, and nothing else
      (let ((* (cons (make-array 5 :element-type 'bit)
                     (make-symbol "WAT"))))
        (sb-vm:map-allocated-objects #'countit :all)
        (assert (equal (map 'list #'- after before) '(0 1 1 1)))))))

(defun count-dynamic-space-objects ()
  (let ((n 0))
    (sb-vm:map-allocated-objects
     (lambda (obj widetag size)
       (declare (ignore obj widetag size))
       (incf n))
     :dynamic)
    n))
(defun make-one-cons () (cons 'x 'y))

;;; While this does not directly test LIST-ALLOCATED-OBJECTS,
;;; it checks that L-A-O would potentially (probably) include in its
;;; output each new object allocated, barring any intervening GC.
;;; It is all but impossible to actually test L-A-O in an A/B scenario
;;; because it conses as many new cells as there were objects to begin
;;; with, plus a vector. i.e. you can't easily perform "list the objects,
;;; create one cons, list the objects, assert that there is that one
;;; cons plus exactly the previous list of objects"
;;; Counting and getting the right answer should be somewhat reassuring.
;;; This test needs dynamic-extent to work properly.
;;; (I don't know what platforms it passes on, but at least these two it does)
(with-test (:name :repeatably-count-allocated-objects
            :skipped-on (not (or :x86 :x86-64))
            :fails-on (or :interpreter (not :sb-thread)))
  (let ((a (make-array 5)))
    (dotimes (i (length a))
      (setf (aref a i) (count-dynamic-space-objects))
      (make-one-cons))
    (dotimes (i (1- (length a)))
      (assert (= (aref a (1+ i)) (1+ (aref a i)))))))

(with-test (:name :list-allocated-objects)
  ;; Assert that if :COUNT is supplied as a higher number
  ;; than number of objects that exists, the output is
  ;; not COUNT many items long.
  (let ((l (sb-vm:list-allocated-objects :dynamic
                                         :count 1000
                                         :type sb-vm:weak-pointer-widetag)))
    ;; This is a change-detector unfortunately,
    ;; but seems like it'll be OK for a while.
    ;; I see only 4 weak pointers in the baseline image.
    ;; Really we could just assert /= 1000.
    (assert (< (length l) 15))))

(defparameter *x* ())

(defun cons-madly ()
  (loop repeat 10000 do
        (setq *x* (make-string 100000))))

;; check that WITHOUT-INTERRUPTS doesn't block the gc trigger
(with-test (:name :cons-madly-without-interrupts)
  (sb-sys:without-interrupts (cons-madly)))

;; check that WITHOUT-INTERRUPTS doesn't block SIG_STOP_FOR_GC
(with-test (:name :gc-without-interrupts
            :skipped-on (not :sb-thread))
 (sb-sys:without-interrupts
   (let ((thread (sb-thread:make-thread (lambda () (sb-ext:gc)))))
     (loop while (sb-thread:thread-alive-p thread)))))

(with-test (:name :without-gcing)
  (let ((gc-happend nil))
    (push (lambda () (setq gc-happend t)) sb-ext:*after-gc-hooks*)

    ;; check that WITHOUT-GCING defers explicit gc
    (sb-sys:without-gcing
      (gc)
      (assert (not gc-happend)))
    (assert gc-happend)

    ;; check that WITHOUT-GCING defers SIG_STOP_FOR_GC
    #+sb-thread
    (let ((in-without-gcing nil))
      (setq gc-happend nil)
      (sb-thread:make-thread (lambda ()
                               (loop while (not in-without-gcing))
                               (sb-ext:gc)))
      (sb-sys:without-gcing
        (setq in-without-gcing t)
        (sleep 3)
        (assert (not gc-happend)))
      ;; give the hook time to run
      (sleep 1)
      (assert gc-happend))))

;;; SB-EXT:GENERATION-* accessors returned bogus values for generation > 0
(with-test (:name :bug-529014 :skipped-on (not :gencgc))
  (loop for i from 0 to sb-vm:+pseudo-static-generation+
     do (assert (= (sb-ext:generation-bytes-consed-between-gcs i)
                   (truncate (sb-ext:bytes-consed-between-gcs)
                             sb-vm:+highest-normal-generation+)))
        ;; FIXME: These parameters are a) tunable in the source and b)
        ;; duplicated multiple times there and now here.  It would be good to
        ;; OAOO-ify them (probably to src/compiler/generic/params.lisp).
        (assert (= (sb-ext:generation-minimum-age-before-gc i) 0.75))
        (assert (= (sb-ext:generation-number-of-gcs-before-promotion i) 1))))

(defun stress-gc ()
  ;; Kludge or not?  I don't know whether the smaller allocation size
  ;; for sb-safepoint is a legitimate correction to the test case, or
  ;; rather hides the actual bug this test is checking for...  It's also
  ;; not clear to me whether the issue is actually safepoint-specific.
  ;; But the main problem safepoint-related bugs tend to introduce is a
  ;; delay in the GC triggering -- and if bug-936304 fails, it also
  ;; causes bug-981106 to fail, even though there is a full GC in
  ;; between, which makes it seem unlikely to me that the problem is
  ;; delay- (and hence safepoint-) related. --DFL
  (let* ((x (make-array (truncate #-sb-safepoint (* 0.2 (dynamic-space-size))
                                  #+sb-safepoint (* 0.1 (dynamic-space-size))
                                  sb-vm:n-word-bytes))))
    (elt x 0)))

(with-test (:name :bug-936304)
  (gc :full t)
  (assert (eq :ok (handler-case
                       (progn
                         (loop repeat 50 do (stress-gc))
                         :ok)
                     (storage-condition ()
                       :oom)))))

(with-test (:name :bug-981106)
  (gc :full t)
  (assert (eq :ok
               (handler-case
                   (dotimes (runs 100 :ok)
                     (let* ((n (truncate (dynamic-space-size) 1200))
                            (len (length
                                  (with-output-to-string (string)
                                    (dotimes (i n)
                                      (write-sequence "hi there!" string))))))
                       (assert (eql len (* n (length "hi there!"))))))
                 (storage-condition ()
                   :oom)))))

(with-test (:name :gc-logfile :skipped-on (not :gencgc))
  (assert (not (gc-logfile)))
  (let ((p #p"gc.log"))
    (assert (not (probe-file p)))
    (assert (equal p (setf (gc-logfile) p)))
    (gc)
    (let ((p2 (gc-logfile)))
      (assert (equal (truename p2) (truename p))))
    (assert (not (setf (gc-logfile) nil)))
    (assert (not (gc-logfile)))
    (delete-file p)))

#+nil ; immobile-code
(with-test (:name (sb-kernel::order-by-in-degree :uninterned-function-names))
  ;; This creates two functions whose names are uninterned symbols and
  ;; that are both referenced once, resulting in a tie
  ;; w.r.t. ORDER-BY-IN-DEGREE. Uninterned symbols used to cause an
  ;; error in the tie-breaker.
  (let* ((sb-c::*compile-to-memory-space* :immobile)
         (f (eval `(defun ,(gensym) ())))
         (g (eval `(defun ,(gensym) ()))))
    (eval `(defun h () (,f) (,g))))
  (sb-kernel::order-by-in-degree))

(defparameter *pin-test-object* nil)
(defparameter *pin-test-object-address* nil)

(with-test (:name (sb-sys:with-pinned-objects :actually-pins-objects)
                  :skipped-on :cheneygc)
  ;; The interpreters (both sb-eval and sb-fasteval) special-case
  ;; WITH-PINNED-OBJECTS as a "special form", because the x86oid
  ;; version of WITH-PINNED-OBJECTS uses black magic that isn't
  ;; supportable outside of the compiler.  The non-x86oid versions of
  ;; WITH-PINNED-OBJECTS don't use black magic, but are overridden
  ;; anyway.  But the special-case logic was, historically broken, and
  ;; this affects all gencgc targets (cheneygc isn't affected because
  ;; cheneygc WITH-PINNED-OBJECTS devolves to WITHOUT-GC>ING).
  ;;
  ;; Our basic approach is to allocate some kind of object and stuff
  ;; it where it doesn't need to be on the control stack.  We then pin
  ;; the object, take its address and store that somewhere as well,
  ;; force a full GC, re-take the address, and see if it moved.
  (locally (declare (notinline make-string)) ;; force full call
    (setf *pin-test-object* (make-string 100)))
  (sb-sys:with-pinned-objects (*pin-test-object*)
    (setf *pin-test-object-address*
          (sb-kernel:get-lisp-obj-address *pin-test-object*))
    (gc :full t)
    (assert (= (sb-kernel:get-lisp-obj-address *pin-test-object*)
               *pin-test-object-address*))))

#+gencgc
(defun ensure-code/data-separation ()
  (let* ((n-bits (+ sb-vm:next-free-page 10))
         (code-bits (make-array n-bits :element-type 'bit))
         (data-bits (make-array n-bits :element-type 'bit))
         (total-code-size 0))
    (sb-vm:map-allocated-objects
     (lambda (obj type size)
       (declare ((and fixnum (integer 1)) size))
       ;; M-A-O disables GC, therefore GET-LISP-OBJ-ADDRESS is safe
       (let ((obj-addr (sb-kernel:get-lisp-obj-address obj))
             (array (cond ((= type sb-vm:code-header-widetag)
                           (incf total-code-size size)
                           code-bits)
                          (t
                           data-bits))))
         ;; This is not the most efficient way to update the bit arrays,
         ;; but the simplest and clearest for sure. (The loop could avoided
         ;; if the current page is the same as the previously seen page)
         (loop for index from (sb-vm::find-page-index obj-addr)
               to (sb-vm::find-page-index (truly-the word
                                                     (+ (logandc2 obj-addr sb-vm:lowtag-mask)
                                                        (1- size))))
               do (setf (sbit array index) 1))))
     :dynamic)
    (assert (not (find 1 (bit-and code-bits data-bits))))
    (let* ((code-bytes-consumed
             (* (count 1 code-bits) sb-vm:gencgc-card-bytes))
           (waste
             (- total-code-size code-bytes-consumed)))
      ;; This should be true for all platforms.
      ;; Some have as little as .5% space wasted.
      (assert (<= waste (* 3/100 code-bytes-consumed))))))



(with-test (:name :code/data-separation
            :skipped-on (not :gencgc))
  (compile 'ensure-code/data-separation)
  (ensure-code/data-separation))

#+immobile-space
(with-test (:name :immobile-space-addr-p)
  ;; Upper bound should be exclusive
  (assert (not (sb-kernel:immobile-space-addr-p
                (+ sb-vm:fixedobj-space-start
                   sb-vm:fixedobj-space-size
                   sb-vm:varyobj-space-size)))))

;;; After each iteration of FOO there are a few pinned conses.
;;; On alternate GC cycles, those get promoted to generation 1.
;;; When the logic for page-spanning-object zeroing incorrectly decreased
;;; the upper bound on bytes used for partially pinned pages, it caused
;;; an accumulation of pages in generation 1 each with 2 objects' worth
;;; of bytes, and the remainder waste. Because the waste was not accounted
;;; for, it did not trigger GC enough to avoid heap exhaustion.
(with-test (:name :smallobj-auto-gc-trigger)
  ;; Ensure that these are compiled functions because the interpreter
  ;; would make lots of objects of various sizes which is insufficient
  ;; to provoke the bug.
  (setf (symbol-function 'foo)
        (compile nil '(lambda () (list 1 2))))
  ;; 500 million iterations of this loop seems to be reliable enough
  ;; to show that GC happens.
  (setf (symbol-function 'callfoo)
        (compile nil '(lambda () (loop repeat 500000000 do (foo)))))
  (funcall 'callfoo))

;;; Pseudo-static large objects should retain the single-object flag
#+gencgc ; PSEUDO-STATIC-GENERATION etc don't exist for cheneygc
(with-test (:name :pseudostatic-large-objects)
  (sb-vm:map-allocated-objects
   (lambda (obj type size)
     (declare (ignore type size))
     (when (>= (sb-vm::primitive-object-size obj) (* 4 sb-vm:gencgc-card-bytes))
       (let* ((addr (sb-kernel:get-lisp-obj-address obj))
              (pte (deref sb-vm:page-table (sb-vm:find-page-index addr))))
         (when (eq (slot pte 'sb-vm::gen) sb-vm:+pseudo-static-generation+)
           (let* ((flags (slot pte 'sb-vm::flags))
                  (type (ldb (byte 5 (+ #+big-endian 3)) flags)))
             (assert (logbitp 4 type)))))))
   :all))

#+64-bit ; code-serialno not defined unless 64-bit
(with-test (:name :unique-code-serialno)
  (let ((a (make-array 100000 :element-type 'bit :initial-element 0)))
    (sb-vm:map-allocated-objects
     (lambda (obj type size)
       (declare (ignore size))
       (when (and (= type sb-vm:code-header-widetag)
                  (plusp (sb-kernel:code-n-entries obj)))
         (let ((serial (sb-kernel:%code-serialno obj)))
           (assert (zerop (aref a serial)))
           (setf (aref a serial) 1))))
     :all)))
