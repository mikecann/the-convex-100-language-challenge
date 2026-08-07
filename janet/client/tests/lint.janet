# Style and syntax check for every checked-in Janet source file.
#
# Janet's core distribution ships no formatter, and the community one lives in
# a package that would have to be fetched and pinned just to reformat a handful
# of files. Rather than claim a formatter this repository does not run, the
# build enforces the conventions the sources actually follow, plus the one
# check that matters most: every file must parse.
#
# Run as: janet lint.janet <file> ...

(def max-columns 100)

(var failures 0)

(defn- fail [path line message]
  (set failures (+ 1 failures))
  (eprint (string "FAIL " path ":" line " " message)))

(defn- check-file [path]
  (def source (slurp path))
  (unless (string/has-suffix? "\n" source)
    (fail path (length (string/split "\n" source)) "file does not end with a newline"))
  (when (string/find "\t" source)
    (fail path 0 "file contains a tab; Janet sources here are space indented"))
  (when (string/find "\r" source)
    (fail path 0 "file contains a carriage return"))
  (var number 0)
  (each line (string/split "\n" source)
    (set number (+ 1 number))
    (when (> (length line) max-columns)
      (fail path number (string "line is " (length line) " columns, over " max-columns)))
    (when (and (> (length line) 0) (string/has-suffix? " " line))
      (fail path number "line has trailing whitespace")))
  # Parsing is the real check: a source file that does not read is not source.
  (def parser (parser/new))
  (parser/consume parser source)
  (parser/eof parser)
  (when (= :error (parser/status parser))
    (fail path 0 (string "does not parse: " (parser/error parser))))
  # Draining the parser confirms every top-level form is complete.
  (while (parser/has-more parser) (parser/produce parser))
  (when (= :error (parser/status parser))
    (fail path 0 (string "does not parse: " (parser/error parser)))))

(each path (slice (dyn :args) 1)
  (check-file path))

(if (= 0 failures)
  (do (print (string "PASS janet style over " (- (length (dyn :args)) 1) " files")) (flush))
  (do (eprint (string "FAIL janet style: " failures " problems")) (os/exit 1)))
