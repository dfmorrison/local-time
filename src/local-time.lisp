;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; LOCAL-TIME
;;;
;;; A package for manipulating times and dates.
;;;
;;; Based on Erik Naggum's "A Long, Painful History of Time" (1999)
;;;
;;; Authored by Daniel Lowe <dlowe@bitmuse.com>
;;;
;;; Copyright (c) 2005-2008 Daniel Lowe
;;;
;;; Permission is hereby granted, free of charge, to any person obtaining
;;; a copy of this software and associated documentation files (the
;;; "Software"), to deal in the Software without restriction, including
;;; without limitation the rights to use, copy, modify, merge, publish,
;;; distribute, sublicense, and/or sell copies of the Software, and to
;;; permit persons to whom the Software is furnished to do so, subject to
;;; the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
;;; LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
;;; OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
;;; WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defpackage :local-time
    (:use #:cl)
  (:export #:timestamp
           #:date
           #:time-of-day
           #:make-timestamp
           #:day-of
           #:sec-of
           #:nsec-of
           #:timestamp<
           #:timestamp<=
           #:timestamp>
           #:timestamp>=
           #:timestamp=
           #:timestamp/=
           #:timestamp-maximum
           #:timestamp-minimum
           #:adjust-timestamp
           #:adjust-timestamp!
           #:timestamp-whole-year-difference
           #:days-in-month
           #:timestamp-
           #:timestamp+
           #:timestamp-difference
           #:timestamp-minimize-part
           #:timestamp-maximize-part
           #:with-decoded-timestamp
           #:decode-timestamp
           #:timestamp-century
           #:timestamp-day
           #:timestamp-day-of-week
           #:timestamp-decade
           #:timestamp-hour
           #:timestamp-microsecond
           #:timestamp-millennium
           #:timestamp-millisecond
           #:timestamp-minute
           #:timestamp-month
           #:timestamp-second
           #:timestamp-week
           #:timestamp-year
           #:parse-timestring
           #:format-timestring
           #:format-rfc1123-timestring
           #:to-rfc1123-timestring
           #:format-rfc3339-timestring
           #:to-rfc3339-timestring
           #:encode-timestamp
           #:parse-rfc3339-timestring
           #:universal-to-timestamp
           #:timestamp-to-universal
           #:unix-to-timestamp
           #:timestamp-to-unix
           #:timestamp-subtimezone
           #:define-timezone
           #:*default-timezone*
           #:find-timezone-by-location-name
           #:now
           #:today
           #:enable-read-macros
           #:+utc-zone+
           #:+gmt-zone+
           #:+month-names+
           #:+short-month-names+
           #:+day-names+
           #:+short-day-names+
           #:+seconds-per-day+
           #:+seconds-per-hour+
           #:+seconds-per-minute+
           #:+minutes-per-day+
           #:+minutes-per-hour+
           #:+hours-per-day+
           #:+days-per-week+
           #:+months-per-year+
           #:+iso-8601-format+
           #:+rfc3339-format+
           #:+rfc3339-format/date-only+
           #:+asctime-format+
           #:+rfc-1123-format+
           #:astronomical-julian-date
           #:modified-julian-date
           #:astronomical-modified-julian-date)
  (:shadow #:time))

(in-package :local-time)

;;; Types

(defclass timestamp ()
  ((day :accessor day-of :initarg :day :initform 0 :type integer)
   (sec :accessor sec-of :initarg :sec :initform 0 :type integer)
   (nsec :accessor nsec-of :initarg :nsec :initform 0 :type (integer 0 999999999))))

(defstruct subzone
  (abbrev nil)
  (offset nil)
  (daylight-p nil))

(defstruct timezone
  (transitions #(0) :type simple-vector)
  (indexes #(0) :type simple-vector)
  (subzones #() :type simple-vector)
  (leap-seconds nil :type list)
  (path nil)
  (name "anonymous" :type string)
  (loaded nil :type boolean))

(deftype timezone-offset ()
  '(integer -43199 50400))

(defun %valid-time-of-day? (timestamp)
  (zerop (day-of timestamp)))

(deftype time-of-day ()
  '(and timestamp
        (satisfies %valid-time-of-day?)))

(defun %valid-date? (timestamp)
  (and (zerop (sec-of timestamp))
       (zerop (nsec-of timestamp))))

(deftype date ()
  '(and timestamp
        (satisfies %valid-date?)))

(define-condition invalid-timezone-file (error)
  ((path :accessor path-of :initarg :path))
  (:report (lambda (condition stream)
             (format stream "The file at ~a is not a timezone file."
                     (path-of condition)))))

(define-condition invalid-time-specification (error)
  ()
  (:report "The time specification is invalid"))

(define-condition invalid-timestring (error)
  ((timestring :accessor timestring-of :initarg :timestring))
  (:report (lambda (condition stream)
             (format stream "Failed to parse ~S as an rfc3339 time"
                     (timestring-of condition)))))

(defmethod make-load-form ((self timestamp) &optional environment)
  (make-load-form-saving-slots self :environment environment))

;;; Declaims

(declaim (inline now format-timestring %get-current-time
                 format-rfc3339-timestring to-rfc3339-timestring
                 format-rfc1123-timestring to-rfc1123-timestring)
         (ftype (function * simple-base-string) format-rfc3339-timestring)
         (ftype (function * simple-base-string) format-timestring)
         (ftype (function * fixnum) local-timezone)
         (ftype (function * (values
                             timezone-offset
                             boolean
                             string)) timestamp-subzone)
         (ftype (function (timestamp &key (:timezone timezone) (:offset (or null integer)))
                          (values (integer 0 999999999)
                                  (integer 0 59)
                                  (integer 0 59)
                                  (integer 0 23)
                                  (integer 1 31)
                                  (integer 1 12)
                                  (integer -1000000 1000000)
                                  (integer 0 6)
                                  t
                                  timezone-offset
                                  simple-string))
                decode-timestamp))

;;; Variables

(defparameter *default-timezone-repository-path*
  (flet ((try (project-home-directory)
           (when project-home-directory
             (ignore-errors
               (truename
                (merge-pathnames "zoneinfo/"
                                 (make-pathname :directory (pathname-directory project-home-directory))))))))
    (or (when (find-package "ASDF")
          (let ((path (eval (read-from-string
                             "(let ((system (asdf:find-system :local-time nil)))
                                (when system
                                  (asdf:component-pathname system)))"))))
            (try path)))
        (let ((path (or #.*compile-file-truename*
                        *load-truename*)))
          (when path
            (try (merge-pathnames "../" path)))))))

;;; Month information
(defparameter +month-names+
  #("" "January" "February" "March" "April" "May" "June" "July" "August"
    "September" "October" "November" "December"))
(defparameter +short-month-names+
  #("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov"
    "Dec"))
(defparameter +day-names+
  #("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))
(defparameter +day-names-as-keywords+
  #(:sunday :monday :tuesday :wednesday :thursday :friday :saturday))
(defparameter +short-day-names+
  #("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +months-per-year+ 12)
  (defconstant +days-per-week+ 7)
  (defconstant +hours-per-day+ 24)
  (defconstant +minutes-per-day+ 1440)
  (defconstant +minutes-per-hour+ 60)
  (defconstant +seconds-per-day+ 86400)
  (defconstant +seconds-per-hour+ 3600)
  (defconstant +seconds-per-minute+ 60)
  (defconstant +usecs-per-day+ 86400000000))

(defparameter +iso-8601-format+
  ;; 2008-11-18T02:32:00.586931+01:00
  '((:year 4) #\- (:month 2) #\- (:day 2) #\T
    (:hour 2) #\: (:min 2) #\: (:sec 2) #\.
    (:usec 6) :gmt-offset-or-z))
(defparameter +rfc3339-format+
  ;; same as +ISO-8601-FORMAT+
  '((:year 4) #\- (:month 2) #\- (:day 2) #\T
    (:hour 2) #\: (:min 2) #\: (:sec 2) #\.
    (:usec 6) :gmt-offset-or-z))
(defparameter +rfc3339-format/date-only+
  '((:year 4) #\- (:month 2) #\- (:day 2)))
(defparameter +asctime-format+
  '(:short-weekday #\space :short-month #\space (:day 2 #\space) #\space
    (:hour 2) #\: (:min 2) #\: (:sec 2) #\space
    (:year 4)))
(defparameter +rfc-1123-format+
  ;; Sun, 06 Nov 1994 08:49:37 GMT
  '(:short-weekday ", " (:day 2) #\space :short-month #\space (:year 4) #\space
    (:hour 2) #\: (:min 2) #\: (:sec 2) #\space :timezone)
  "Please note that you should use the +GMT-ZONE+ timezone to format a proper RFC 1123 timestring. See the RFC for the details about the possible values of the timezone field.")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter +rotated-month-days-without-leap-day+
    #.(coerce #(31 30 31 30 31 31 30 31 30 31 31 28)
              '(simple-array fixnum (*))))

  (defparameter +rotated-month-offsets-without-leap-day+
    (coerce
     (cons 0
           (loop with sum = 0
                 for days :across +rotated-month-days-without-leap-day+
                 collect (incf sum days)))
     '(simple-array fixnum (*)))))

;; The astronomical julian date offset is the number of days between
;; the current date and -4713-01-01T00:00:00+00:00
(defparameter +astronomical-julian-date-offset+ -2451605)

;; The modified julian date is the number of days between the current
;; date and 1858-11-17T12:00:00+00:00. TODO: For the sake of simplicity,
;; we currently just do the date arithmetic and don't adjust for the
;; time of day.
(defparameter +modified-julian-date-offset+ -51604)

(defun %get-default-offset ()
  (multiple-value-bind (sec min hour day mon year dow daylight-p zone)
      (get-decoded-time)
    (declare (ignore sec min hour day mon year dow))
    (if daylight-p
        (* -3600 (1- zone))
        (* -3600 zone))))

(defun %read-binary-integer (stream byte-count &optional (signed nil))
  "Read BYTE-COUNT bytes from the binary stream STREAM, and return an integer which is its representation in network byte order (MSB).  If SIGNED is true, interprets the most significant bit as a sign indicator."
  (loop
    :with result = 0
    :for offset :from (* (1- byte-count) 8) :downto 0 :by 8
    :do (setf (ldb (byte 8 offset) result) (read-byte stream))
    :finally (if signed
                 (let ((high-bit (* byte-count 8)))
                   (if (logbitp (1- high-bit) result)
                       (return (- result (ash 1 high-bit)))
                       (return result)))
                 (return result))))

(defun %string-from-unsigned-byte-vector (vector offset)
  "Returns a string created from the vector of unsigned bytes VECTOR starting at OFFSET which is terminated by a 0."
  (declare (type (vector (unsigned-byte 8)) vector))
  (let* ((null-pos (or (position 0 vector :start offset) (length vector)))
         (result (make-string (- null-pos offset) :element-type 'base-char)))
    (loop for input-index :from offset :upto (1- null-pos)
          for output-index :upfrom 0
          do (setf (aref result output-index) (code-char (aref vector input-index))))
    result))

(defun %find-first-std-offset (timezone-indexes timestamp-info)
  (let ((subzone-idx (find-if 'subzone-daylight-p
                              timezone-indexes
                              :key (lambda (x) (aref timestamp-info x)))))
    (subzone-offset (aref timestamp-info (or subzone-idx 0)))))

(defun %tz-verify-magic-number (inf zone)
  ;; read and verify magic number
  (let ((magic-buf (make-array 4 :element-type 'unsigned-byte)))
    (read-sequence magic-buf inf :start 0 :end 4)
    (when (string/= (map 'string #'code-char magic-buf) "TZif" :end1 4)
      (error 'invalid-timezone-file :path (timezone-path zone))))
  ;; skip 16 bytes for "future use"
  (let ((ignore-buf (make-array 16 :element-type 'unsigned-byte)))
    (read-sequence ignore-buf inf :start 0 :end 16)))

(defun %tz-read-header (inf)
  `(:utc-count ,(%read-binary-integer inf 4)
         :wall-count ,(%read-binary-integer inf 4)
         :leap-count ,(%read-binary-integer inf 4)
         :transition-count ,(%read-binary-integer inf 4)
         :type-count ,(%read-binary-integer inf 4)
         :abbrev-length ,(%read-binary-integer inf 4)))

(defun %tz-read-transitions (inf count)
  (make-array count
              :initial-contents
              (loop for idx from 1 upto count
                 collect (%read-binary-integer inf 4 t))))

(defun %tz-read-indexes (inf count)
  (make-array count
              :initial-contents
              (loop for idx from 1 upto count
                 collect (%read-binary-integer inf 1))))

(defun %tz-read-subzone (inf count)
  (loop for idx from 1 upto count
     collect (list (%read-binary-integer inf 4 t)
                   (%read-binary-integer inf 1)
                   (%read-binary-integer inf 1))))

(defun %tz-read-leap-seconds (inf count)
  (loop for idx from 1 upto count
     collect (list (%read-binary-integer inf 4)
                   (%read-binary-integer inf 4))))

(defun %tz-read-abbrevs (inf length)
  (let ((a (make-array length :element-type '(unsigned-byte 8))))
    (read-sequence a inf
                   :start 0
                   :end length)
    a))

(defun %tz-read-indicators (inf length)
  ;; read standard/wall indicators
  (let ((buf (make-array length :element-type '(unsigned-byte 8))))
    (read-sequence buf inf
                   :start 0
                   :end length)
    (make-array length
                :element-type 'bit
                :initial-contents buf)))

(defun %tz-make-subzones (raw-info abbrevs gmt-indicators std-indicators)
  (declare (ignore gmt-indicators std-indicators))
  ;; TODO: handle TZ environment variables, which use the gmt and std
  ;; indicators
  (make-array (length raw-info)
              :element-type 'subzone
              :initial-contents
              (loop for info in raw-info collect
                   (make-subzone
                    :offset (first info)
                    :daylight-p (/= (second info) 0)
                    :abbrev (%string-from-unsigned-byte-vector abbrevs (third info))))))

(defun %realize-timezone (zone &optional reload)
  "If timezone has not already been loaded or RELOAD is non-NIL, loads the timezone information from its associated unix file.  If the file is not a valid timezone file, the condition INVALID-TIMEZONE-FILE will be signaled."
  (when (or reload (not (timezone-loaded zone)))
    (with-open-file (inf (timezone-path zone)
                         :direction :input
                         :element-type 'unsigned-byte)
      (%tz-verify-magic-number inf zone)

      ;; read header values
      (let* ((header (%tz-read-header inf))
             (timezone-transitions (%tz-read-transitions inf (getf header :transition-count)))
             (subzone-indexes (%tz-read-indexes inf (getf header :transition-count)))
             (subzone-raw-info (%tz-read-subzone inf (getf header :type-count)))
             (leap-second-info (%tz-read-leap-seconds inf (getf header :leap-count)))
             (abbreviation-buf (%tz-read-abbrevs inf (getf header :abbrev-length)))
             (std-indicators (%tz-read-indicators inf (getf header :wall-count)))
             (gmt-indicators (%tz-read-indicators inf (getf header :utc-count)))
             (subzone-info (%tz-make-subzones subzone-raw-info
                                              abbreviation-buf
                                              gmt-indicators
                                              std-indicators)))

        (setf (timezone-transitions zone) timezone-transitions)
        (setf (timezone-indexes zone) subzone-indexes)
        (setf (timezone-subzones zone) subzone-info)
        (setf (timezone-leap-seconds zone) leap-second-info))
      (setf (timezone-loaded zone) t)))
  zone)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %make-simple-timezone (name abbrev offset)
    (let ((subzone (local-time::make-subzone :offset offset
                                           :daylight-p nil
                                           :abbrev abbrev)))
    (local-time::make-timezone
     :subzones (make-array 1 :initial-contents (list subzone))
     :path nil
     :name name
     :loaded t)))

  ;; to be used as #+#.(local-time::package-with-symbol? "SB-EXT" "GET-TIME-OF-DAY")
  (defun package-with-symbol? (package name)
    (if (and (find-package package)
             (find-symbol name package))
        '(:and)
        '(:or))))

(defparameter +utc-zone+ (%make-simple-timezone "Coordinated Universal Time" "UTC" 0))

(defparameter +gmt-zone+ (%make-simple-timezone "Greenwich Mean Time" "GMT" 0))

(defparameter +none-zone+ (%make-simple-timezone "Explicit Offset Given" "NONE" 0))

(defmacro define-timezone (zone-name zone-file &key (load nil))
  "Define zone-name (a symbol or a string) as a new timezone, lazy-loaded from zone-file (a pathname designator relative to the zoneinfo directory on this system.  If load is true, load immediately."
  (declare (type (or string symbol) zone-name))
  (let ((zone-sym (if (symbolp zone-name) zone-name (intern zone-name))))
    `(prog1
      (defparameter ,zone-sym (make-timezone :path ,zone-file
                                             :name ,(if (symbolp zone-name)
                                                        (string-downcase (symbol-name zone-name))
                                                        zone-name)))
      ,@(when load
              `((%realize-timezone ,zone-sym))))))

(defvar *default-timezone*)
(eval-when (:load-toplevel :execute)
  (let ((default-timezone-file #p"/etc/localtime"))
    (if (probe-file default-timezone-file)
        (define-timezone *default-timezone* default-timezone-file :load t)
        (setf *default-timezone* +utc-zone+))))

(defparameter *location-name->timezone* (make-hash-table :test 'equal)
  "A hashtable with entries like \"Europe/Budapest\" -> timezone-instance")

(defparameter *abbreviated-subzone-name->timezone-list* (make-hash-table :test 'equal)
  "A hashtable of \"CEST\" -> list of timezones with \"CEST\" subzone")

(defun find-timezone-by-location-name (name)
  (when (zerop (hash-table-count *location-name->timezone*))
    (error "Seems like the timezone repository has not yet been loaded. Hint: see REREAD-TIMEZONE-REPOSITORY."))
  (gethash name *location-name->timezone*))

(defun timezone= (timezone-1 timezone-2)
  "Return two values indicating the relationship between timezone-1 and timezone-2. The first value is whether the two timezones are equal and the second value indicates whether it is sure or not.

In other words:
\(values t t) means timezone-1 and timezone-2 are definitely equal.
\(values nil t) means timezone-1 and timezone-2 are definitely different.
\(values nil nil) means that it couldn't be determined."
  (if (or (eq timezone-1 timezone-2)
          (equalp timezone-1 timezone-2))
      (values t t)
      (values nil nil)))

(defun reread-timezone-repository (&key (timezone-repository *default-timezone-repository-path*))
  (check-type timezone-repository (or pathname string))
  (multiple-value-bind (valid? error)
      (ignore-errors
        (truename timezone-repository)
        t)
    (unless valid?
      (error "REREAD-TIMEZONE-REPOSITORY was called with invalid PROJECT-DIRECTORY (~A). The error is ~A."
             timezone-repository error)))
  (let* ((root-directory timezone-repository)
         (cutoff-position (length (princ-to-string root-directory))))
    (flet ((visitor (file)
             (let* ((full-name (subseq (princ-to-string file) cutoff-position))
                    (name (pathname-name file))
                    (timezone (%realize-timezone (make-timezone :path file :name name))))
               (setf (gethash full-name *location-name->timezone*) timezone)
               (map nil (lambda (subzone)
                          (push timezone (gethash (subzone-abbrev subzone)
                                                  *abbreviated-subzone-name->timezone-list*)))
                    (timezone-subzones timezone)))))
      (setf *location-name->timezone* (make-hash-table :test 'equal))
      (setf *abbreviated-subzone-name->timezone-list* (make-hash-table :test 'equal))
      (cl-fad:walk-directory root-directory #'visitor :directories nil
                             :test (lambda (file)
                                     (not (find "Etc" (pathname-directory file) :test #'string=))))
      (cl-fad:walk-directory (merge-pathnames "Etc/" root-directory) #'visitor :directories nil))))

(defmacro make-timestamp (&rest args)
  `(make-instance 'timestamp ,@args))

(defun clone-timestamp (timestamp)
  (make-instance 'timestamp
                 :nsec (nsec-of timestamp)
                 :sec (sec-of timestamp)
                 :day (day-of timestamp)))

(defun transition-position (needle haystack &optional (start 0) (end (1- (length haystack))))
  (let ((middle (floor (+ end start) 2)))
    (cond
      ((> start end)
       (if (minusp end)
           0
           end))
      ((= needle (elt haystack middle))
       middle)
      ((> needle (elt haystack middle))
       (transition-position needle haystack (1+ middle) end))
      (t
       (transition-position needle haystack start (1- middle))))))

(defun timestamp-subtimezone (timestamp timezone)
  "Return as multiple values the time zone as the number of seconds east of UTC, a boolean daylight-saving-p, and the customary abbreviation of the timezone."
  (declare (type timestamp timestamp)
           (type (or null timezone) timezone))
  (let* ((zone (%realize-timezone (or timezone *default-timezone*)))
         (unix-time (timestamp-to-unix timestamp))
         (subzone-idx (if (zerop (length (timezone-indexes zone)))
                          0
                          (elt (timezone-indexes zone)
                               (transition-position unix-time
                                                   (timezone-transitions timezone)))))
         (subzone (elt (timezone-subzones zone) subzone-idx)))
    (values
     (subzone-offset subzone)
     (subzone-daylight-p subzone)
     (subzone-abbrev subzone))))

(defun %adjust-to-offset (sec day offset)
  "Returns two values, the values of new DAY and SEC slots of the timestamp adjusted to the given timezone."
  (declare (type integer sec day offset))
  (multiple-value-bind (offset-day offset-sec)
      (truncate (abs offset) +seconds-per-day+)
    (let* ((offset-sign (signum offset))
           (new-sec (+ sec (* offset-sign offset-sec)))
           (new-day (+ day (* offset-sign offset-day))))
      (cond ((minusp new-sec)
             (incf new-sec +seconds-per-day+)
             (decf new-day))
            ((>= new-sec +seconds-per-day+)
             (incf new-day)
             (decf new-sec +seconds-per-day+)))
      (values new-sec new-day))))

(defun %adjust-to-timezone (source timezone &optional offset)
  (%adjust-to-offset (sec-of source)
                     (day-of source)
                     (or offset
                         (timestamp-subtimezone source timezone))))

(defun timestamp-minimize-part (timestamp part &key
                                (timezone *default-timezone*)
                                into)
  (let* ((timestamp-parts '(:nsec :sec :min :hour :day :month))
         (part-count (position part timestamp-parts)))
    (assert part-count nil
            "timestamp-minimize-part called with invalid part ~a (expected one of ~a)"
            part
            timestamp-parts)
    (multiple-value-bind (nsec sec min hour day month year day-of-week daylight-saving-time-p offset)
        (decode-timestamp timestamp :timezone timezone)
      (declare (ignore nsec day-of-week daylight-saving-time-p))
      (encode-timestamp 0
                        (if (> part-count 0) 0 sec)
                        (if (> part-count 1) 0 min)
                        (if (> part-count 2) 0 hour)
                        (if (> part-count 3) 1 day)
                        (if (> part-count 4) 1 month)
                        year
                        :offset offset
                        :timezone timezone
                        :into into))))

(defun timestamp-maximize-part (timestamp part &key
                                (timezone *default-timezone*)
                                into)
  (let* ((timestamp-parts '(:nsec :sec :min :hour :day :month))
         (part-count (position part timestamp-parts)))
    (assert part-count nil
            "timestamp-maximize-part called with invalid part ~a (expected one of ~a)"
            part
            timestamp-parts)
    (multiple-value-bind (nsec sec min hour day month year day-of-week daylight-saving-time-p offset)
        (decode-timestamp timestamp :timezone timezone)
      (declare (ignore nsec day-of-week daylight-saving-time-p))
      (let ((month (if (> part-count 4) 12 month)))
        (encode-timestamp 999999999
                          (if (> part-count 0) 59 sec)
                          (if (> part-count 1) 59 min)
                          (if (> part-count 2) 23 hour)
                          (if (> part-count 3) (days-in-month month year) day)
                          month
                          year
                          :offset offset
                          :timezone timezone
                          :into into)))))

(defmacro with-decoded-timestamp ((&key nsec sec minute hour day month year day-of-week daylight-p timezone offset)
                                   timestamp &body forms)
  "This macro binds variables to the decoded elements of TIMESTAMP. The TIMEZONE argument is used for decoding the timestamp, and is not bound by the macro. The value of DAY-OF-WEEK starts from 0 which means Sunday."
  (let ((ignores)
        (types)
        (variables))
    (macrolet ((initialize (&rest vars)
                 `(progn
                    ,@(loop
                         :for var :in vars
                         :collect `(progn
                                     (unless ,var
                                       (setf ,var (gensym))
                                       (push ,var ignores))
                                     (push ,var variables)))
                    (setf ignores (nreverse ignores))
                    (setf variables (nreverse variables))))
               (declare-fixnum-type (&rest vars)
                 `(progn
                    ,@(loop
                         :for var :in vars
                         :collect `(when ,var
                                     (push `(type fixnum ,,var) types)))
                    (setf types (nreverse types)))))
      (when nsec
        (push `(type (integer 0 999999999) ,nsec) types))
      (declare-fixnum-type sec minute hour day month year)
      (initialize nsec sec minute hour day month year day-of-week daylight-p))
    `(multiple-value-bind (,@variables)
         (decode-timestamp ,timestamp :timezone ,(or timezone '*default-timezone*) :offset ,offset)
       (declare (ignore ,@ignores) ,@types)
       ,@forms)))

(defun %normalize-month-year-pair (month year)
  "Normalizes the month/year pair: in case month is < 1 or > 12 the month and year are corrected to handle the overflow."
  (multiple-value-bind (year-offset month-minus-one)
      (floor (1- month) 12)
    (values (1+ month-minus-one)
            (+ year year-offset))))

(defun days-in-month (month year)
  "Returns the number of days in the given month of the specified year."
  (let ((normal-days (aref +rotated-month-days-without-leap-day+
                           (mod (+ month 9) 12))))
    (if (and (= month 2)
             (or (and (zerop (mod year 4))
                      (plusp (mod year 100)))
                 (zerop (mod year 400))))
        (1+ normal-days)                ; February on a leap year
        normal-days)))

;; TODO scan all uses of FIX-OVERFLOW-IN-DAYS and decide where it's ok to silently fix and where should be and error reported
(defun %fix-overflow-in-days (day month year)
  "In case the day number is higher than the maximal possible for the given month/year pair, returns the last day of the month."
  (let ((max-day (days-in-month month year)))
    (if (> day max-day)
        max-day
        day)))

(eval-when (:compile-toplevel :load-toplevel)
  (defun %list-length= (num list)
    "Tests for a list of length NUM without traversing the entire list to get the length."
    (let ((c (nthcdr (1- num) list)))
      (and c (endp (cdr c)))))

  (defun %expand-adjust-timestamp-changes (timestamp changes visitor)
    (loop
      :for change in changes
      :with params = ()
      :with functions = ()
      :do
         (progn
           (assert (or
                    (%list-length= 3 change)
                    (and (%list-length= 2 change)
                         (symbolp (first change))
                         (or (string= (first change) :timezone)
                             (string= (first change) :utc-offset)))
                    (and (%list-length= 4 change)
                         (symbolp (third change))
                         (or (string= (third change) :to)
                             (string= (third change) :by))))
                   nil "Syntax error in expression ~S" change)
           (let ((operation (first change))
                 (part (second change))
                 (value (if (%list-length= 3 change)
                            (third change)
                            (fourth change))))
             (cond
               ((string= operation :set)
                (push `(%set-timestamp-part ,part ,value) functions))
               ((string= operation :offset)
                (push `(%offset-timestamp-part ,part ,value) functions))
               ((or (string= operation :utc-offset)
                    (string= operation :timezone))
                (push (second change) params)
                (push operation params))
               (t (error "Unexpected operation ~S" operation)))))
      :finally
         (loop
           :for (function part value) in functions
           :do
           (funcall visitor `(,function ,timestamp ,part ,value ,@params)))))

  (defun %expand-adjust-timestamp (timestamp changes &key functional)
    (let* ((old (gensym "OLD"))
           (new (if functional
                    (gensym "NEW")
                    old))
           (forms (list)))
      (%expand-adjust-timestamp-changes old changes
                                        (lambda (change)
                                          (push
                                           `(progn
                                              (multiple-value-bind (nsec sec day)
                                                  ,change
                                                (setf (nsec-of ,new) nsec)
                                                (setf (sec-of ,new) sec)
                                                (setf (day-of ,new) day))
                                              ,@(when functional
                                                      `((setf ,old ,new))))
                                           forms)))
      (setf forms (nreverse forms))
      `(let* ((,old ,timestamp)
              ,@(when functional
                      `((,new (clone-timestamp ,old)))))
         ,@forms
         ,old)))
  )                                     ; eval-when

(defmacro adjust-timestamp (timestamp &body changes)
  (%expand-adjust-timestamp timestamp changes :functional t))

(defmacro adjust-timestamp! (timestamp &body changes)
  (%expand-adjust-timestamp timestamp changes :functional nil))

(defun %set-timestamp-part (time part new-value &key (timezone *default-timezone*) utc-offset)
  ;; TODO think about error signalling. when, how to disable if it makes sense, ...
  (case part
    ((:nsec :sec-of-day :day)
     (let ((nsec (nsec-of time))
           (sec (sec-of time))
           (day (day-of time)))
       (case part
         (:nsec (setf nsec (coerce new-value '(integer 0 999999999))))
         (:sec-of-day (setf sec (coerce new-value `(integer 0 ,+seconds-per-day+))))
         (:day (setf day new-value)))
       (values nsec sec day)))
    (otherwise
     (with-decoded-timestamp (:nsec nsec :sec sec :minute minute :hour hour
                              :day day :month month :year year :timezone timezone :offset utc-offset)
         time
       (ecase part
         (:sec (setf sec new-value))
         (:minute (setf minute new-value))
         (:hour (setf hour new-value))
         (:day-of-month (setf day new-value))
         (:month (setf month new-value)
                 (setf day (%fix-overflow-in-days day month year)))
         (:year (setf year new-value)
                (setf day (%fix-overflow-in-days day month year))))
       (encode-timestamp-into-values nsec sec minute hour day month year :timezone timezone :offset utc-offset)))))

(defun %offset-timestamp-part (time part offset &key (timezone *default-timezone*) utc-offset)
  "Returns a time adjusted by the specified OFFSET. Takes care of
different kinds of overflows. The setting :day-of-week is possible
using a keyword symbol name of a week-day (see
+DAY-NAMES-AS-KEYWORDS+) as value. In that case point the result to
the previous day given by OFFSET."
  (labels ((direct-adjust (part offset nsec sec day)
             (cond ((eq part :day-of-week)
                    (with-decoded-timestamp (:day-of-week day-of-week
                                             :nsec nsec :sec sec :minute minute :hour hour
                                             :day day :month month :year year
                                             :timezone timezone :offset utc-offset)
                        time
                      (let ((position (position offset +day-names-as-keywords+ :test #'eq)))
                        (assert position (position) "~S is not a valid day name" offset)
                        (let ((offset (+ (- (if (zerop day-of-week)
                                                7
                                                day-of-week))
                                         position)))
                          (incf day offset)
                          (when (< day 1)
                            (let (days-in-month)
                              (decf month)
                              (when (< month 1)
                                (setf month 12)
                                (decf year))
                              (setf days-in-month (days-in-month month year)
                                    day (+ days-in-month day)))) ;; day here is always <= 0
                          (encode-timestamp-into-values nsec sec minute hour day month year
                                                        :timezone timezone :offset utc-offset)))))
                   ((zerop offset)
                    ;; The offset is zero, so just return the parts of the timestamp object
                    (values nsec sec day))
                   (t
                    (let ((old-utc-offset (or utc-offset
                                              (timestamp-subtimezone time timezone)))
                          new-utc-offset)
                      (tagbody
                         top
                         (ecase part
                           (:nsec
                            (multiple-value-bind (sec-offset new-nsec)
                                (floor (+ offset nsec) 1000000000)
                              ;; the time might need to be adjusted a bit more if q != 0
                              (setf part :sec
                                    offset sec-offset
                                    nsec new-nsec)
                              (go top)))
                           ((:sec :minute :hour)
                            (multiple-value-bind (days-offset new-sec)
                                (floor (+ sec (* offset (ecase part
                                                          (:sec 1)
                                                          (:minute +seconds-per-minute+)
                                                          (:hour +seconds-per-hour+))))
                                       +seconds-per-day+)
                              (setf part :day
                                    offset days-offset
                                    sec new-sec)
                              (go top)))
                           (:day
                            (incf day offset)
                            (setf new-utc-offset (or utc-offset
                                                     (timestamp-subtimezone (make-timestamp :nsec nsec :sec sec :day day)
                                                                            timezone)))
                            (when (not (= old-utc-offset
                                          new-utc-offset))
                              ;; We hit the DST boundary. We need to restart again
                              ;; with :sec, but this time we know both old and new
                              ;; UTC offset will be the same, so it's safe to do
                              (setf part :sec
                                    offset (- old-utc-offset
                                              new-utc-offset)
                                    old-utc-offset new-utc-offset)
                              (go top))
                            (return-from direct-adjust (values nsec sec day)))))))))

           (safe-adjust (part offset time)
             (with-decoded-timestamp (:nsec nsec :sec sec :minute minute :hour hour :day day
                                      :month month :year year :timezone timezone :offset utc-offset)
                 time
               (multiple-value-bind (month-new year-new)
                   (%normalize-month-year-pair
                    (+ (ecase part
                         (:month offset)
                         (:year (* 12 offset)))
                       month)
                    year)
                 ;; Almost there. However, it is necessary to check for
                 ;; overflows first
                 (encode-timestamp-into-values nsec sec minute hour
                                               (%fix-overflow-in-days day month-new year-new)
                                               month-new year-new
                                               :timezone timezone :offset utc-offset)))))
    (ecase part
      ((:nsec :sec :minute :hour :day :day-of-week)
       (direct-adjust part offset
                      (nsec-of time)
                      (sec-of time)
                      (day-of time)))
      ((:month :year) (safe-adjust part offset time)))))

;; TODO merge this functionality into timestamp-difference
(defun timestamp-whole-year-difference (time-a time-b)
  "Returns the number of whole years elapsed between time-a and time-b (hint: anniversaries)."
  (declare (type timestamp time-b time-a))
  (multiple-value-bind (nsec-a sec-a minute-a hour-a day-a month-a year-a)
      (decode-timestamp time-b)
    (multiple-value-bind (nsec-b sec-b minute-b hour-b day-b month-b year-b day-of-week-b daylight-p-b zone-b)
        (decode-timestamp time-a)
      (declare (ignore nsec-b sec-b minute-b hour-b day-b month-b day-of-week-b daylight-p-b zone-b))
      (let ((year-difference (- year-b year-a)))
        (if (timestamp<= (encode-timestamp nsec-a sec-a minute-a hour-a day-a month-a
                                           (+ year-difference year-a))
                         time-a)
            year-difference
            (1- year-difference))))))

(defun timestamp-difference (time-a time-b)
  "Returns the difference between TIME-A and TIME-B in seconds"
  (let ((nsec (- (nsec-of time-a) (nsec-of time-b)))
        (second (- (sec-of time-a) (sec-of time-b)))
        (day (- (day-of time-a) (day-of time-b))))
    (when (minusp nsec)
      (decf second)
      (incf nsec 1000000000))
    (when (minusp second)
      (decf day)
      (incf second +seconds-per-day+))
    (let ((result (+ (* day +seconds-per-day+)
                     second)))
      (unless (zerop nsec)
        ;; this incf turns the result into a float, so only do this when necessary
        (incf result (/ nsec 1000000000d0)))
      result)))

(defun timestamp+ (time amount unit &optional (timezone *default-timezone*) offset)
  (multiple-value-bind (nsec sec day)
      (%offset-timestamp-part time unit amount :timezone timezone :utc-offset offset)
    (make-timestamp :nsec nsec
                    :sec sec
                    :day day)))

(defun timestamp- (time amount unit &optional (timezone *default-timezone*) offset)
  (timestamp+ time (- amount) unit timezone offset))

(defun timestamp-day-of-week (timestamp &key (timezone *default-timezone*) offset)
  (mod (+ 3 (nth-value 1 (%adjust-to-timezone timestamp timezone offset))) 7))

;; TODO read
;; http://java.sun.com/j2se/1.4.2/docs/api/java/util/GregorianCalendar.html
;; (or something else, sorry :) this scheme only works back until
;; 1582, the start of the gregorian calendar.  see also
;; DECODE-TIMESTAMP when fixing if fixing is desired at all.
(defun valid-timestamp-p (nsec sec minute hour day month year)
  "Returns T if the time values refer to a valid time, otherwise returns NIL."
  (and (<= 0 nsec 999999999)
       (<= 0 sec 59)
       (<= 0 minute 59)
       (<= 0 hour 23)
       (<= 1 month 12)
       (<= 1 day (days-in-month month year))
       (/= year 0)))

(defun encode-timestamp-into-values (nsec sec minute hour day month year
                                     &key (timezone *default-timezone*) offset)
  "Returns (VALUES NSEC SEC DAY ZONE) ready to be used for
instantiating a new timestamp object.  If the specified time is
invalid, the condition INVALID-TIME-SPECIFICATION is raised."
  ;; If the user provided an explicit offset, we use that.  Otherwise,
  ;; we try converting the local time to a timestamp using each available
  ;; subtimezone, until we find one where the offset matches the offset that
  ;; applies at that time (according to the transition table).
  ;;
  ;; Consequence for ambiguous cases:
  ;; Whichever subtimezone is listed first in the tzinfo database will be
  ;; the one that we pick to resolve ambiguous local time representations.

  (declare (type integer nsec sec minute hour day month year)
           (type (or integer null) offset))
  (unless (valid-timestamp-p nsec sec minute hour day month year)
    (error 'invalid-time-specification))
  (if offset
      (let* ((0-based-rotated-month (if (>= month 3)
                                        (- month 3)
                                        (+ month 9)))
             (internal-year (if (< month 3)
                                (- year 2001)
                                (- year 2000)))
             (years-as-days (years-to-days internal-year))
             (sec (+ (* hour +seconds-per-hour+)
                     (* minute +seconds-per-minute+)
                     sec))
             (days-from-zero-point (+ years-as-days
                                      (aref +rotated-month-offsets-without-leap-day+ 0-based-rotated-month)
                                      (1- day))))
        (multiple-value-bind (utc-sec utc-day)
            (%adjust-to-offset sec days-from-zero-point (- offset))
          (values nsec utc-sec utc-day)))
      ;; find the first potential offset that is valid at the represented time
      (loop
        :for subtimezone :across (timezone-subzones timezone)
        :do (let ((timestamp (encode-timestamp nsec sec minute hour day month year
                                               :offset (subzone-offset subtimezone))))
              (if (= (timestamp-subtimezone timestamp timezone)
                     (subzone-offset subtimezone))
                  (return  (values (nsec-of timestamp)
                                   (sec-of timestamp)
                                   (day-of timestamp)))))
        :finally
          (error "The requested local time is not valid"))))

(defun encode-timestamp (nsec sec minute hour day month year
                         &key (timezone *default-timezone*) offset into)
  "Return a new TIMESTAMP instance corresponding to the specified time
elements."
  (declare (type integer nsec sec minute hour day month year))
  (multiple-value-bind (nsec sec day)
      (encode-timestamp-into-values nsec sec minute hour day month year
                                    :timezone timezone :offset offset)
    (if into
        (progn
          (setf (nsec-of into) nsec)
          (setf (sec-of into) sec)
          (setf (day-of into) day)
          into)
        (make-timestamp
         :nsec nsec
         :sec sec
         :day day))))

(defun universal-to-timestamp (universal &key (nsec 0))
  "Returns a timestamp corresponding to the given universal time."
  ;; universal time is seconds from 1900-01-01T00:00:00Z.
  (let ((adjusted-universal (- universal #.(encode-universal-time 0 0 0 1 3 2000 0))))
    (multiple-value-bind (day second)
        (floor adjusted-universal +seconds-per-day+)
      (make-timestamp :day day :sec second :nsec nsec))))

(defun timestamp-to-universal (timestamp)
  "Return the UNIVERSAL-TIME corresponding to the TIMESTAMP"
  ;; universal time is seconds from 1900-01-01T00:00:00Z
  (+ (* (day-of timestamp) +seconds-per-day+)
     (sec-of timestamp)
     #.(encode-universal-time 0 0 0 1 3 2000 0)))

(defun unix-to-timestamp (unix &key (nsec 0))
  "Return a TIMESTAMP corresponding to UNIX, which is the number of seconds since the unix epoch, 1970-01-01T00:00:00Z."
  (multiple-value-bind (days secs)
      (floor unix +seconds-per-day+)
    (make-timestamp :day (- days 11017) :sec secs :nsec nsec)))

(defun timestamp-to-unix (timestamp)
  "Return the Unix time corresponding to the TIMESTAMP"
  (declare (type timestamp timestamp))
  (+ (* (+ (day-of timestamp)
           11017)
        +seconds-per-day+)
     (sec-of timestamp)))

(defun %get-current-time ()
  "Cross-implementation abstraction to get the current time measured from the unix epoch (1/1/1970). Should return (values sec nano-sec)."
  #+cmu
  (multiple-value-bind (success? sec usec) (unix:unix-gettimeofday)
    (assert success? () "unix:unix-gettimeofday reported failure?!")
    (values sec (* 1000 usec)))
  #+sbcl
  (progn
    #+#.(local-time::package-with-symbol? "SB-EXT" "GET-TIME-OF-DAY") ; available from sbcl 1.0.28.66
    (multiple-value-bind (sec nsec) (sb-ext:get-time-of-day)
      (values sec (* 1000 nsec)))
    #-#.(local-time::package-with-symbol? "SB-EXT" "GET-TIME-OF-DAY") ; obsolete, scheduled to be deleted at the end of 2009
    (multiple-value-bind (success? sec nsec) (sb-unix:unix-gettimeofday)
      (assert success? () "sb-unix:unix-gettimeofday reported failure?!")
      (values sec (* 1000 nsec))))
  #+(and ccl (not windows))
  ;; this whole voodoo here is because of a bug in LispWorks, namely its reader chokes on #_ inside a #+ccl
  ;; see mail "darcs patch: Work with Lispworks" on local-time-devel at 2009.03.23.
  ;; and mail "darcs patch: Less intrusive version of the Lispworks patch for #_." at 2009.03.24.
  ;; TODO get rid of this eventually... this all should be a mere (#_gettimeofday tv (ccl::%null-ptr))
  (ccl::rlet ((tv :timeval))
    (#.(let ((ccl-external-func (get-dispatch-macro-character #\# #\_)))
         (when ccl-external-func
           (with-input-from-string (sym "gettimeofday")
             (funcall ccl-external-func sym #\_ nil))))
       tv (ccl::%null-ptr))
    (values (ccl::pref tv :timeval.tv_sec) (* 1000 (ccl::pref tv :timeval.tv_usec))))
  #-(or cmu sbcl (and ccl (not windows)))
  (values (- (get-universal-time)
             ;; CL's get-universal-time uses an epoch of 1/1/1900, so adjust the result to the Unix epoch
             #.(encode-universal-time 0 0 0 1 1 1970 0))
          0))

(defun now ()
  "Returns a timestamp representing the present moment."
  (multiple-value-bind (sec nsec) (%get-current-time)
    (assert (and sec nsec) () "Failed to get the current time from the operating system. How did this happen?")
    (unix-to-timestamp sec :nsec nsec)))

(defun today ()
  "Returns a timestamp representing the present day."
  ;; TODO should return a date value, anyhow we will decide to represent it eventually
  (timestamp-minimize-part (now) :hour))

(defmacro %defcomparator (name &body body)
  (let ((pair-comparator-name (intern (concatenate 'string "%" (string name)))))
    `(progn
      (declaim (inline ,pair-comparator-name))
      (defun ,pair-comparator-name (time-a time-b)
        ,@body)
      (defun ,name (&rest times)
        (declare (dynamic-extent times))
        (loop for (time-a time-b) :on times
              while time-b
              always (,pair-comparator-name time-a time-b)))
      (define-compiler-macro ,name (&rest times)
        (let ((vars (loop
                      :for i :upfrom 0 :below (length times)
                      :collect (gensym (concatenate 'string "TIME-" (princ-to-string i) "-")))))
          `(let (,@(loop
                     :for var :in vars
                     :for time :in times
                     :collect (list var time)))
            ;; we could evaluate comparisons of timestamp literals here
            (and ,@(loop
                     :for (time-a time-b) :on vars
                     :while time-b
                     :collect `(,',pair-comparator-name ,time-a ,time-b)))))))))

(defun %timestamp-compare (time-a time-b)
  "Returns the symbols <, >, or =, describing the relationship between TIME-A and TIME-b."
  (declare (type timestamp time-a time-b))
  (cond
    ((< (day-of time-a) (day-of time-b)) '<)
    ((> (day-of time-a) (day-of time-b)) '>)
    ((< (sec-of time-a) (sec-of time-b)) '<)
    ((> (sec-of time-a) (sec-of time-b)) '>)
    ((< (nsec-of time-a) (nsec-of time-b)) '<)
    ((> (nsec-of time-a) (nsec-of time-b)) '>)
    (t '=)))

(%defcomparator timestamp<
  (eql (%timestamp-compare time-a time-b) '<))

(%defcomparator timestamp<=
  (not (null (member (%timestamp-compare time-a time-b) '(< =)))))

(%defcomparator timestamp>
  (eql (%timestamp-compare time-a time-b) '>))

(%defcomparator timestamp>=
  (not (null (member (%timestamp-compare time-a time-b) '(> =)))))

(%defcomparator timestamp=
  (eql (%timestamp-compare time-a time-b) '=))

(%defcomparator timestamp/=
  (not (eql (%timestamp-compare time-a time-b) '=)))

(defun contest (test list)
  "Applies TEST to pairs of elements in list, keeping the element which last tested T.  Returns the winning element."
  (reduce (lambda (a b) (if (funcall test a b) a b)) list))

(defun timestamp-minimum (time &rest times)
  "Returns the earliest timestamp"
  (contest #'timestamp< (cons time times)))

(defun timestamp-maximum (time &rest times)
  "Returns the latest timestamp"
  (contest #'timestamp> (cons time times)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun years-to-days (years)
    "Given a number of years, returns the number of days in those years."
    (let* ((days (* years 365))
           (l1 (floor years 4))
           (l2 (floor years 100))
           (l3 (floor years 400)))
      (+ days l1 (- l2) l3))))

(defun days-to-years (days)
  "Given a number of days, returns the number of years and the remaining days in that year."
  (let ((remaining-days days))
    (multiple-value-bind (400-years remaining-days)
        (floor remaining-days #.(years-to-days 400))
      (let* ((100-years (min (floor remaining-days #.(years-to-days 100)) 3))
             (remaining-days (- remaining-days
                                (* 100-years #.(years-to-days 100)))))
        (multiple-value-bind (4-years remaining-days)
            (floor remaining-days #.(years-to-days 4))
          (let ((years (min 3 (floor remaining-days #.(years-to-days 1)))))
            (values (+ (* 400-years 400)
                       (* 100-years 100)
                       (* 4-years 4)
                       years)
                    (- remaining-days (* years 365))))))))
  ;; the above is the macroexpansion of the following. uses metabang BIND, but kept for clarity because the expansion is unreadable.
  #+nil
  (bind ((remaining-days days)
         ((values 400-years remaining-days) (floor remaining-days #.(years-to-days 400)))
         (100-years (min (floor remaining-days #.(years-to-days 100))
                         3))
         (remaining-days (- remaining-days
                            (* 100-years
                               #.(years-to-days 100))))
         ((values 4-years remaining-days) (floor remaining-days #.(years-to-days 4)))
         (years (min (floor remaining-days 365)
                     3)))
        (values (+ (* 400-years 400)
                   (* 100-years 100)
                   (* 4-years 4)
                   years)
                (- remaining-days (* years 365)))))

(defun %timestamp-decode-date (days)
  "Returns the year, month, and day, given the number of days from the epoch."
  (declare (type integer days))
  (multiple-value-bind (years remaining-days)
      (days-to-years days)
    (let* ((leap-day-p (= remaining-days 365))
           (rotated-1-based-month (if leap-day-p
                                      12 ; march is the first month and february is the last
                                      (position remaining-days +rotated-month-offsets-without-leap-day+ :test #'<)))
           (1-based-month (if (>= rotated-1-based-month 11)
                              (- rotated-1-based-month 10)
                              (+ rotated-1-based-month 2)))
           (1-based-day (if leap-day-p
                            29
                            (1+ (- remaining-days (aref +rotated-month-offsets-without-leap-day+
                                                        (1- rotated-1-based-month)))))))
      (values
       (+ years
          (if (>= rotated-1-based-month 11) ; january is in the next year
              2001
              2000))
       1-based-month
       1-based-day))))

(defun %timestamp-decode-time (seconds)
  "Returns the hours, minutes, and seconds, given the number of seconds since midnight."
  (declare (type integer seconds))
  (multiple-value-bind (hours hour-remainder)
      (floor seconds +seconds-per-hour+)
    (multiple-value-bind (minutes seconds)
        (floor hour-remainder +seconds-per-minute+)
      (values
       hours
       minutes
       seconds))))

(defun decode-timestamp (timestamp &key (timezone *default-timezone*) offset)
  "Returns the decoded time as multiple values: nsec, ss, mm, hh, day, month, year, day-of-week"
  (declare (type timestamp timestamp))
  (when offset
    (setf timezone (the timezone +none-zone+)))
  (multiple-value-bind (offset* daylight-p abbreviation)
      (timestamp-subtimezone timestamp timezone)
      (multiple-value-bind (adjusted-secs adjusted-days)
          (%adjust-to-timezone timestamp timezone offset)
        (multiple-value-bind (hours minutes seconds)
            (%timestamp-decode-time adjusted-secs)
          (multiple-value-bind (year month day)
              (%timestamp-decode-date adjusted-days)
            (values
             (nsec-of timestamp)
             seconds minutes hours
             day month year
             (timestamp-day-of-week timestamp :timezone timezone :offset offset)
             daylight-p
             (or offset offset*)
             abbreviation))))))

(defun timestamp-year (timestamp &key (timezone *default-timezone*))
  "Returns the cardinal year upon which the timestamp falls."
  (nth-value 0
             (%timestamp-decode-date
              (nth-value 1 (%adjust-to-timezone timestamp timezone)))))

(defun timestamp-century (timestamp &key (timezone *default-timezone*))
  "Returns the ordinal century upon which the timestamp falls."
  (let* ((year (timestamp-year timestamp :timezone timezone))
         (sign (signum year)))
    (+ sign
       (* sign
          (truncate (1- (abs year)) 100)))))

(defun timestamp-millennium (timestamp &key (timezone *default-timezone*))
  "Returns the ordinal millennium upon which the timestamp falls."
  (let* ((year (timestamp-year timestamp :timezone timezone))
         (sign (signum year)))
    (+ sign
       (* sign
          (truncate (1- (abs year)) 1000)))))

(defun timestamp-decade (timestamp &key (timezone *default-timezone*))
  "Returns the cardinal decade upon which the timestamp falls."
  (truncate (timestamp-year timestamp :timezone timezone) 10))

(defun timestamp-month (timestamp &key (timezone *default-timezone*))
  "Returns the month upon which the timestamp falls."
  (nth-value 1
             (%timestamp-decode-date
              (nth-value 1 (%adjust-to-timezone timestamp timezone)))))

(defun timestamp-day (timestamp &key (timezone *default-timezone*))
  "Returns the day of the month upon which the timestamp falls."
  (nth-value 2
             (%timestamp-decode-date
              (nth-value 1 (%adjust-to-timezone timestamp timezone)))))

(defun timestamp-hour (timestamp &key (timezone *default-timezone*))
  (nth-value 0
             (%timestamp-decode-time
              (nth-value 0 (%adjust-to-timezone timestamp timezone)))))

(defun timestamp-minute (timestamp &key (timezone *default-timezone*))
  (nth-value 1
             (%timestamp-decode-time
              (nth-value 0 (%adjust-to-timezone timestamp timezone)))))

(defun timestamp-second (timestamp &key (timezone *default-timezone*))
  (nth-value 2
             (%timestamp-decode-time
              (nth-value 0 (%adjust-to-timezone timestamp timezone)))))

(defun timestamp-microsecond (timestamp)
  (floor (nsec-of timestamp) 1000))

(defun timestamp-millisecond (timestamp)
  (floor (nsec-of timestamp) 1000000))

(defun split-timestring (str &rest args)
  (declare (inline))
  (apply #'%split-timestring (coerce str 'simple-string) args))

(defun %split-timestring (time-string &key
                          (start 0)
                          (end (length time-string))
                          (fail-on-error t) (time-separator #\:)
                          (date-separator #\-)
                          (date-time-separator #\T)
                          (allow-missing-elements t)
                          (allow-missing-date-part allow-missing-elements)
                          (allow-missing-time-part allow-missing-elements)
                          (allow-missing-timezone-part allow-missing-time-part))
  "Based on http://www.ietf.org/rfc/rfc3339.txt including the function names used. Returns (values year month day hour minute second nsec offset-hour offset-minute). On parsing failure, signals INVALID-TIMESTRING if FAIL-ON-ERROR is NIL, otherwise returns NIL."
  (declare (type character date-time-separator time-separator date-separator)
           (type simple-string time-string)
           (optimize (speed 3)))
  (the list
    (let (year month day hour minute second nsec offset-hour offset-minute)
      (declare (type (or null fixnum) start end year month day hour minute second offset-hour offset-minute)
               (type (or null (signed-byte 32)) nsec))
      (macrolet ((passert (expression)
                   `(unless ,expression
                     (parse-error)))
                 (parse-integer-into (start-end place &optional low-limit high-limit)
                   (let ((entry (gensym "ENTRY"))
                         (value (gensym "VALUE"))
                         (pos (gensym "POS"))
                         (start (gensym "START"))
                         (end (gensym "END")))
                     `(let ((,entry ,start-end))
                       (if ,entry
                           (let ((,start (car ,entry))
                                 (,end (cdr ,entry)))
                             (multiple-value-bind (,value ,pos) (parse-integer time-string :start ,start :end ,end :junk-allowed t)
                               (passert (= ,pos ,end))
                               (setf ,place ,value)
                               ,(if (and low-limit high-limit)
                                    `(passert (<= ,low-limit ,place ,high-limit))
                                    (values))
                               (values)))
                           (progn
                             (passert allow-missing-elements)
                             (values))))))
                 (with-parts-and-count ((start end split-chars) &body body)
                   `(multiple-value-bind (parts count) (split ,start ,end ,split-chars)
                     (declare (ignorable count) (type fixnum count)
                      ;;(type #1=(cons (cons fixnum fixnum) (or null #1#)) parts)
                      (type list parts))
                     ,@body)))
        (labels ((split (start end chars)
                   (declare (type fixnum start end))
                   (unless (consp chars)
                     (setf chars (list chars)))
                   (loop with last-match = start
                         with match-count of-type (integer 0 #.most-positive-fixnum) = 0
                         for index of-type fixnum upfrom start
                         while (< index end)
                         when (member (aref time-string index) chars :test #'char-equal)
                         collect (prog1 (if (< last-match index)
                                            (cons last-match index)
                                            nil)
                                   (incf match-count)
                                   (setf last-match (1+ index)))
                                 into result
                         finally (return (values (if (zerop (- index last-match))
                                                     result
                                                     (prog1
                                                         (nconc result (list (cons last-match index)))
                                                       (incf match-count)))
                                                 match-count))))
                 (parse ()
                   (with-parts-and-count (start end date-time-separator)
                     (cond ((= count 2)
                            (if (first parts)
                                (full-date (first parts))
                                (passert allow-missing-date-part))
                            (if (second parts)
                                (full-time (second parts))
                                (passert allow-missing-time-part))
                            (done))
                           ((and (= count 1)
                                 allow-missing-date-part
                                 (find time-separator time-string
                                       :start (car (first parts))
                                       :end (cdr (first parts))))
                            (full-time (first parts))
                            (done))
                           ((and (= count 1)
                                 allow-missing-time-part
                                 (find date-separator time-string
                                       :start (car (first parts))
                                       :end (cdr (first parts))))
                            (full-date (first parts))
                            (done)))
                     (parse-error)))
                 (full-date (start-end)
                   (let ((parts (split (car start-end) (cdr start-end) date-separator)))
                     (passert (%list-length= 3 parts))
                     (date-fullyear (first parts))
                     (date-month (second parts))
                     (date-mday (third parts))))
                 (date-fullyear (start-end)
                   (parse-integer-into start-end year))
                 (date-month (start-end)
                   (parse-integer-into start-end month 1 12))
                 (date-mday (start-end)
                   (parse-integer-into start-end day 1 31))
                 (full-time (start-end)
                   (let ((start (car start-end))
                         (end (cdr start-end)))
                     (with-parts-and-count (start end (list #\Z #\- #\+))
                       (let* ((zulup (find #\Z time-string :test #'char-equal :start start :end end))
                              (sign (unless zulup
                                      (if (find #\+ time-string :test #'char-equal :start start :end end)
                                          1
                                          -1))))
                         (passert (<= 1 count 2))
                         (unless (and (eq (first parts) nil)
                                      (not (rest parts)))
                           ;; not a single #\Z
                           (partial-time (first parts)))
                         (when zulup
                           (setf offset-hour 0
                                 offset-minute 0))
                         (if (= count 1)
                             (passert (or zulup allow-missing-timezone-part))
                             (let* ((entry (second parts))
                                    (start (car entry))
                                    (end (cdr entry)))
                               (declare (type fixnum start end))
                               (passert (or zulup
                                            (not (zerop (- end start)))))
                               (unless zulup
                                 (time-offset (second parts) sign))))))))
                 (partial-time (start-end)
                   (with-parts-and-count ((car start-end) (cdr start-end) time-separator)
                     (passert (eql count 3))
                     (time-hour (first parts))
                     (time-minute (second parts))
                     (time-second (third parts))))
                 (time-hour (start-end)
                   (parse-integer-into start-end hour 0 23))
                 (time-minute (start-end)
                   (parse-integer-into start-end minute 0 59))
                 (time-second (start-end)
                   (with-parts-and-count ((car start-end) (cdr start-end) '(#\. #\,))
                     (passert (<= 1 count 2))
                     (let ((*read-eval* nil))
                       (parse-integer-into (first parts) second 0 59)
                       (if (> count 1)
                           (let* ((start (car (second parts)))
                                  (end (cdr (second parts))))
                             (declare (type (integer 0 #.array-dimension-limit) start end))
                             (passert (<= (- end start) 9))
                             (let ((new-end (position-if (lambda (el)
                                                           (not (char= #\0 el)))
                                                         time-string :start start :end end :from-end t)))
                               (when new-end
                                 (setf end (min (1+ new-end)))))
                             ;;(break "~S: ~S" (subseq time-string start end) (- end start))
                             (setf nsec (* (the (integer 0 999999999) (parse-integer time-string :start start :end end))
                                           (aref #.(coerce #(1000000000 100000000 10000000
                                                             1000000 100000 10000 1000 100 10 1)
                                                           '(simple-array (signed-byte 32) (10)))
                                                 (- end start)))))
                           (setf nsec 0)))))
                 (time-offset (start-end sign)
                   (with-parts-and-count ((car start-end) (cdr start-end) time-separator)
                     (passert (or allow-missing-timezone-part (= count 2)))
                     (parse-integer-into (first parts) offset-hour 0 23)
                     (if (second parts)
                         (parse-integer-into (second parts) offset-minute 0 59)
                         (setf offset-minute 0))
                     (setf offset-hour (* offset-hour sign)
                           offset-minute (* offset-minute sign))))
                 (parse-error ()
                   (if fail-on-error
                       (error 'invalid-timestring :timestring time-string)
                       (return-from %split-timestring nil)))
                 (done ()
                   (return-from %split-timestring (list year month day hour minute second nsec offset-hour offset-minute))))
          (parse))))))

(defun parse-rfc3339-timestring (timestring &key (fail-on-error t)
                                            (allow-missing-time-part nil))
  (parse-timestring timestring :fail-on-error fail-on-error
                    :allow-missing-timezone-part nil
                    :allow-missing-time-part allow-missing-time-part
                    :allow-missing-date-part nil))

(defun parse-timestring (timestring &key
                         (start 0)
                         (end (length timestring))
                         (fail-on-error t)
                         (time-separator #\:)
                         (date-separator #\-)
                         (date-time-separator #\T)
                         (allow-missing-elements t)
                         (allow-missing-date-part allow-missing-elements)
                         (allow-missing-time-part allow-missing-elements)
                         (allow-missing-timezone-part allow-missing-elements)
                         (offset 0))
  "Parse a timestring and return the corresponding TIMESTAMP. See split-timestring for details. Unspecified fields in the timestring are initialized to their lowest possible value, and timezone offset is 0 (UTC) unless explicitly specified in the input string."
  (let ((parts (%split-timestring (coerce timestring 'simple-string)
                                  :start start
                                  :end end
                                  :fail-on-error fail-on-error
                                  :time-separator time-separator
                                  :date-separator date-separator
                                  :date-time-separator date-time-separator
                                  :allow-missing-elements allow-missing-elements
                                  :allow-missing-date-part allow-missing-date-part
                                  :allow-missing-time-part allow-missing-time-part
                                  :allow-missing-timezone-part allow-missing-timezone-part)))
    (when parts
      (destructuring-bind (year month day hour minute second nsec offset-hour offset-minute)
          parts
        (encode-timestamp
         (or nsec 0)
         (or second 0)
         (or minute 0)
         (or hour 0)
         (or day 1)
         (or month 3)
         (or year 2000)
         :offset (if offset-hour
                     (+ (* offset-hour 3600)
                        (* (or offset-minute 0) 60))
                     offset))))))

(defun ordinalize (day)
  "Return an ordinal string representing the position of DAY in a sequence (1st, 2nd, 3rd, 4th, etc)."
  (declare (type (integer 1 31) day))
  (flet ((suffix ()
           (if (<= 11 day 13)
               "th"
               (multiple-value-bind (quotient remainder) (floor day 10)
                 (declare (ignore quotient))
                 (case remainder
                   (1 "st")
                   (2 "nd")
                   (3 "rd")
                   (t "th"))))))
    (format nil "~d~a" day (suffix))))

(defun %construct-timestring (timestamp format timezone)
  "Constructs a string representing TIMESTAMP given the FORMAT of the string and the TIMEZONE.  See the documentation of FORMAT-TIMESTRING for the structure of FORMAT."
  (declare (type timestamp timestamp)
           (optimize (speed 3)))
  (multiple-value-bind (nsec sec minute hour day month year weekday daylight-p offset abbrev)
      (decode-timestamp timestamp :timezone timezone)
    (declare (ignore daylight-p))
    (let ((*print-pretty* nil)
          (*print-circle* nil))
      (with-output-to-string (result nil :element-type 'base-char)
        (dolist (fmt format)
          (cond
            ((or (eql fmt :gmt-offset)
                 (eql fmt :gmt-offset-or-z))
             (multiple-value-bind (offset-hours offset-secs)
                 (floor offset +seconds-per-hour+)
               (declare (fixnum offset-hours offset-secs))
               (if (and (eql fmt :gmt-offset-or-z) (zerop offset))
                   (princ #\Z result)
                   (format result "~c~2,'0d:~2,'0d"
                           (if (minusp offset-hours) #\- #\+)
                           (abs offset-hours)
                           (truncate (abs offset-secs)
                                     +seconds-per-minute+)))))
            ((eql fmt :long-month)
             (princ (aref +month-names+ month) result))
            ((eql fmt :short-month)
             (princ (aref +short-month-names+ month) result))
            ((eql fmt :long-weekday)
             (princ (aref +day-names+ weekday) result))
            ((eql fmt :short-weekday)
             (princ (aref +short-day-names+ weekday) result))
            ((eql fmt :timezone)
             (princ abbrev result))
            ((eql fmt :hour12)
             (princ (1+ (mod (1- hour) 12)) result))
            ((eql fmt :ampm)
             (princ (if (< hour 12) "am" "pm") result))
            ((eql fmt :ordinal-day)
             (princ (ordinalize day) result))
            ((or (stringp fmt) (characterp fmt))
             (princ fmt result))
            (t
             (let ((val (ecase (if (consp fmt) (car fmt) fmt)
                          (:nsec nsec)
                          (:usec (floor nsec 1000))
                          (:msec (floor nsec 1000000))
                          (:sec sec)
                          (:min minute)
                          (:hour hour)
                          (:day day)
                          (:weekday weekday)
                          (:month month)
                          (:year year))))
               (cond
                 ((atom fmt)
                  (princ val result))
                 ((minusp val)
                  (format result "-~v,vd"
                          (second fmt)
                          (or (third fmt) #\0)
                          (abs val)))
                 (t
                  (format result "~v,vd"
                          (second fmt)
                          (or (third fmt) #\0)
                          val)))))))))))

(defun format-timestring (destination timestamp &key
                          (format +iso-8601-format+)
                          (timezone *default-timezone*))
  "Constructs a string representation of TIMESTAMP according to FORMAT and returns it.  If destination is T, the string is written to *standard-output*.  If destination is a stream, the string is written to the stream.

FORMAT is a list containing one or more of strings, characters, and keywords. Strings and characters are output literally, while keywords are replaced by the values here:

  :YEAR              *year
  :MONTH             *numeric month
  :DAY               *day of month
  :HOUR              *hour
  :MIN               *minutes
  :SEC               *seconds
  :WEEKDAY           *numeric day of week starting from index 0, which means Sunday
  :MSEC              *milliseconds
  :USEC              *microseconds
  :NSEC              *nanoseconds
  :LONG-WEEKDAY      long form of weekday (e.g. Sunday, Monday)
  :SHORT-WEEKDAY     short form of weekday (e.g. Sun, Mon)
  :LONG-MONTH        long form of month (e.g. January, February)
  :SHORT-MONTH       short form of month (e.g. Jan, Feb)
  :HOUR12            hour on a 12-hour clock
  :AMPM              am/pm marker in lowercase
  :GMT-OFFSET        the gmt-offset of the time, in +00:00 form
  :GMT-OFFSET-OR-Z   like :GMT-OFFSET, but is Z when UTC
  :TIMEZONE          timezone abbrevation for the time

Elements marked by * can be placed in a list in the form: \(:keyword padding &optional \(padchar #\0))

The string representation of the value will be padded with the padchar.

You can see examples in +ISO-8601-FORMAT+, +ASCTIME-FORMAT+, and +RFC-1123-FORMAT+."
  (declare (type (or boolean stream) destination))
  (let ((result (%construct-timestring timestamp format timezone)))
    (when destination
      (write-string result destination))
    result))

(defun format-rfc1123-timestring (destination timestamp)
  (format-timestring destination timestamp
                     :format +rfc-1123-format+
                     :timezone +gmt-zone+))

(defun to-rfc1123-timestring (timestamp)
  (format-rfc1123-timestring nil timestamp))

(defun format-rfc3339-timestring (destination timestamp &key
                                  omit-date-part
                                  omit-time-part
                                  omit-timezone-part
                                  (use-zulu t)
                                  (timezone *default-timezone*))
  "Formats a timestring in the RFC 3339 format, a restricted form of the ISO-8601 timestring specification for Internet timestamps."
  (let ((rfc3339-format
         (if (and use-zulu
                  (not omit-date-part)
                  (not omit-time-part)
                  (not omit-timezone-part))
             +rfc3339-format+ ; micro optimization
             (append
              (unless omit-date-part
                '((:year 4) #\-
                  (:month 2) #\-
                  (:day 2)))
              (unless (or omit-date-part
                          omit-time-part)
                '(#\T))
              (unless omit-time-part
                '((:hour 2) #\:
                  (:min 2) #\:
                  (:sec 2) #\.
                  (:usec 6)))
              (unless omit-timezone-part
                (if use-zulu
                    '(:gmt-offset-or-z)
                    '(:gmt-offset)))))))
    (format-timestring destination timestamp :format rfc3339-format :timezone timezone)))

(defun to-rfc3339-timestring (timestamp)
  (format-rfc3339-timestring nil timestamp))

(defun %read-timestring (stream char)
  (declare (ignore char))
  (parse-timestring
   (with-output-to-string (str)
     (loop for c = (read-char stream nil)
        while (and c (or (digit-char-p c) (member c '(#\: #\T #\t #\: #\- #\+ #\Z #\.))))
        do (princ c str)
        finally (when c (unread-char c stream))))
   :allow-missing-elements t))

(defun %read-universal-time (stream char arg)
  (declare (ignore char arg))
  (universal-to-timestamp
              (parse-integer
               (with-output-to-string (str)
                 (loop for c = (read-char stream nil)
                       while (and c (digit-char-p c))
                       do (princ c str)
                       finally (when c (unread-char c stream)))))))

(defun enable-read-macros ()
  "Enables the local-time reader macros for literal timestamps and universal time."
  (set-macro-character #\@ '%read-timestring)
  (set-dispatch-macro-character #\# #\@ '%read-universal-time)
  (values))

(defvar *debug-timestamp* nil)

(defmethod print-object ((object timestamp) stream)
  "Print the TIMESTAMP object using the standard reader notation"
  (cond
    (*debug-timestamp*
       (print-unreadable-object (object stream :type t)
         (format stream "~d/~d/~d"
                 (day-of object)
                 (sec-of object)
                 (nsec-of object))))
    (t
     (when *print-escape*
       (princ "@" stream))
     (format-rfc3339-timestring stream object))))

(defmethod print-object ((object timezone) stream)
  "Print the TIMEZONE object in a reader-rejected manner."
  (print-unreadable-object (object stream :type t)
    (format stream "~:[UNLOADED~;~{~a~^ ~}~]"
            (timezone-loaded object)
            (map 'list #'subzone-abbrev (timezone-subzones object)))))

(defun astronomical-julian-date (timestamp)
  "Returns the astronomical julian date referred to by the timestamp."
  (- (day-of timestamp) +astronomical-julian-date-offset+))

(defun modified-julian-date (timestamp)
  "Returns the modified julian date referred to by the timestamp."
  (- (day-of timestamp) +modified-julian-date-offset+))

(declaim (notinline format-timestring))
