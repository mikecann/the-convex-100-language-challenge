;; Convex JSON numbers use IEEE-754 doubles in Lua 5.1. Keep counter values in
;; the exactly representable integer range so overflow cannot silently round.
(local Integer {})
(local max-safe-integer 9007199254740991)

(fn Integer.checked [value operation]
  (if (not (and (= (type value) :number)
                (= value value)
                (<= (math.abs value) max-safe-integer)
                (= (% value 1) 0)))
      (error (.. operation " count must be a safe whole number")))
  value)

Integer
