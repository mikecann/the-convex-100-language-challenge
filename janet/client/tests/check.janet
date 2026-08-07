# A very small assertion helper.
#
# Janet has no bundled test runner in its core, and pulling one in would add a
# dependency for the sake of four functions. These collect failures instead of
# stopping at the first one, so a single run reports everything that broke.

(import ../errors :as fail)

(def- sentinel :check/nothing-raised)

(def state @{:checks 0 :failures @[]})

(defn check
  "Record one assertion."
  [condition message]
  (put state :checks (+ 1 (get state :checks)))
  (unless condition (array/push (get state :failures) message))
  condition)

(defn check= [actual expected message]
  (check (deep= actual expected)
         (string message ": expected " (describe expected) " but got " (describe actual))))

(defn raises
  "Run `thunk` and return whatever it raised, or nil if it returned normally."
  [thunk]
  (var caught sentinel)
  (try (thunk) ([problem] (set caught problem)))
  (if (= caught sentinel) nil caught))

(defn check-raises
  "Assert that `thunk` raises a structured error of class `expected-name`."
  [expected-name thunk message]
  (def problem (raises thunk))
  (check (and problem (= expected-name (fail/name-of problem)))
         (string message ": expected a " expected-name " but got "
                 (if problem (fail/name-of problem) "no error"))))

(defn report
  "Print the outcome and exit non-zero if anything failed."
  [suite]
  (def failures (get state :failures))
  (if (= 0 (length failures))
    (do
      (print (string "PASS " suite " (" (get state :checks) " checks)"))
      (flush))
    (do
      (each failure failures (eprint (string "FAIL " suite ": " failure)))
      (eprint (string "FAIL " suite " (" (length failures) " of "
                      (get state :checks) " checks failed)"))
      (os/exit 1))))
