(local Integer (require :integer))

(fn expect-rejected [value label]
  (let [(ok _) (pcall Integer.checked value label)]
    (if ok (error (.. label " was accepted")))))

(assert (= (Integer.checked 0.0 :integral-decimal) 0))
(assert (= (Integer.checked 1 :integer) 1))
(expect-rejected 1.5 :fractional)
(expect-rejected "1" :quoted)
(expect-rejected math.huge :infinite)
(expect-rejected (- math.huge) :negative-infinite)
(expect-rejected (/ 0 0) :nan)
(expect-rejected 9007199254740992 :overflowing)

(print "integer tests passed")
