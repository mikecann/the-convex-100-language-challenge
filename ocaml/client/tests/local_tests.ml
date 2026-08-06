let fail message = raise (Failure message)

let expect_error expected = function
  | Ok _ -> fail ("expected error: " ^ expected)
  | Error message when message = expected -> ()
  | Error message -> fail ("expected " ^ expected ^ ", got " ^ message)

let () =
  (match Convex.parse_integral_int64 (`Float 0.0) with
  | Ok 0L -> ()
  | _ -> fail "0.0 should be integral");
  (match Convex.parse_integral_int64 (`Float 1.0) with
  | Ok 1L -> ()
  | _ -> fail "1.0 should be integral");
  expect_error "count must be mathematically integral"
    (Convex.parse_integral_int64 (`Float 1.5));
  expect_error "count must be a JSON number"
    (Convex.parse_integral_int64 (`String "1"));
  expect_error "count is outside the int64 range"
    (Convex.parse_integral_int64 (`Intlit "9223372036854775808"));
  print_endline "PASS OCaml local protocol and numeric fixtures"
