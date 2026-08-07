||| Loopback HTTP tests against a real forked fixture server.
|||
||| The fixture is a separate process speaking real TCP, not a mock, so the
||| client exercises its own socket, deadline, and envelope code. One child
||| serves a scripted reply per connection and the parent makes the matching
||| calls in the same order.
module Main

import Data.IORef
import Data.List
import Data.String
import System
import System.File

import Convex.Error
import Convex.Http
import Convex.Json
import Convex.Net
import Convex.Prim

check : IORef Int -> String -> Bool -> IO ()
check failures label ok =
  if ok
     then putStrLn ("ok   " ++ label)
     else do modifyIORef failures (+ 1)
             ignore $ fPutStrLn stderr ("FAIL " ++ label)
             putStrLn ("FAIL " ++ label)

||| What the fixture does on one accepted connection.
data Reply
  = ||| Write the whole response at once.
    Immediate String
  | ||| Write one byte at a time with a pause between them. The client's
    ||| absolute deadline must fire even though bytes keep arriving.
    Dribble String Int
  | ||| Answer with whether the expected bearer header was present, which
    ||| proves the token reaches the wire exactly as configured.
    ReportAuth String

body : String -> String
body payload =
  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    ++ show (byteLength payload) ++ "\r\nConnection: close\r\n\r\n" ++ payload
  where
    -- Every fixture payload here is ASCII, so its character count is its byte
    -- count; the client is the side that must measure encoded bytes.
    byteLength : String -> Int
    byteLength text = cast (length text)

statusBody : Int -> String -> String -> String
statusBody code reason payload =
  "HTTP/1.1 " ++ show code ++ " " ++ reason
    ++ "\r\nContent-Type: application/json\r\nContent-Length: "
    ++ show (the Int (cast (length payload)))
    ++ "\r\nConnection: close\r\n\r\n" ++ payload

--------------------------------------------------------------------------------
-- Fixture
--------------------------------------------------------------------------------

covering
readRequestHead : Connection -> Int -> List String -> IO (List String)
readRequestHead link deadline acc =
  if cast (length acc) > the Int 64
     then pure acc
     else do line <- readLine link 8192 deadline
             case line of
                  Left _ => pure acc
                  Right "" => pure acc
                  Right text => readRequestHead link deadline (acc ++ [toLower text])

covering
dribbleOut : Connection -> String -> Int -> Int -> IO ()
dribbleOut link payload pauseMs index =
  do size <- textSize payload
     if index >= size
        then pure ()
        else do scratch <- bufNew (size + 1)
                ignore $ bufPutText scratch 0 payload
                deadline <- deadlineIn 1000
                ignore $ writeAll link scratch index 1 deadline
                bufFree scratch
                sleepMs pauseMs
                dribbleOut link payload pauseMs (index + 1)

covering
serveOne : Int -> Reply -> IO ()
serveOne listener reply =
  do deadline <- deadlineIn 15000
     accepted <- acceptConnection listener "" "" deadline 65536
     case accepted of
          Left _ => pure ()
          Right link =>
            do headers <- readRequestHead link deadline []
               respond link headers
               shutdownConnection link
               -- Give the client a moment to drain before the socket closes.
               sleepMs 20
               closeConnection link
  where
    covering
    respond : Connection -> List String -> IO ()
    respond link headers =
      case reply of
           Immediate text =>
             do deadline <- deadlineIn 5000
                ignore $ writeText link text deadline
           Dribble text pauseMs => dribbleOut link text pauseMs 0
           ReportAuth expected =>
             do deadline <- deadlineIn 5000
                let seen = elem (toLower ("authorization: bearer " ++ expected)) headers
                ignore $ writeText link
                           (body ("{\"status\":\"success\",\"value\":"
                                    ++ (if seen then "true" else "false") ++ "}"))
                           deadline

covering
serveScript : Int -> List Reply -> IO ()
serveScript listener [] = pure ()
serveScript listener (reply :: rest) =
  do serveOne listener reply
     serveScript listener rest

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------

configFor : Int -> Int -> HttpConfig
configFor portNumber budget =
  MkHttpConfig (MkEndpoint False "127.0.0.1" portNumber "/") "" "idris-tests" budget

covering
callWith : HttpConfig -> IO (Either ConvexError CallResult)
callWith settings = callConvex settings "" "query" "demo:state" (JObject [])

failureKind : Either ConvexError CallResult -> Maybe ErrorKind
failureKind (Left failure) = Just (kind failure)
failureKind (Right _) = Nothing

covering
runTests : IORef Int -> Int -> IO ()
runTests failures portNumber =
  do let settings = configFor portNumber 8000

     success <- callWith settings
     check failures "a success envelope yields its value and logs"
       (case success of
             Right result => resultValue result == JObject [("count", jsonInt 7)]
                               && resultLogs result == ["demo:echo ran"]
             Left _ => False)

     functionError <- callWith settings
     check failures "an HTTP 560 becomes a structured function error"
       (case functionError of
             Left failure => kind failure == FunctionFailure
                               && errorData failure == JObject [("code", JString "BOOM")]
             Right _ => False)

     serverError <- callWith settings
     check failures "an HTTP 500 becomes a transport failure"
       (failureKind serverError == Just TransportFailure)

     badRequest <- callWith settings
     check failures "an HTTP 400 becomes a protocol failure"
       (failureKind badRequest == Just ProtocolFailure)

     chunked <- callWith settings
     check failures "a chunked response is reassembled"
       (case chunked of
             Right result => resultValue result == JObject [("count", jsonInt 3)]
             Left _ => False)

     oversize <- callWith settings
     check failures "a declared body beyond the byte budget is refused"
       (case oversize of
             Left failure => kind failure == TransportFailure
             Right _ => False)

     -- The response keeps arriving, one byte at a time. A per-read timeout
     -- would never fire; only an absolute deadline ends this.
     dribbled <- callWith (configFor portNumber 700)
     check failures "a dribbling peer is bounded by the absolute deadline"
       (failureKind dribbled == Just TransportFailure)

     authorised <- callConvex settings "test-token-42" "query" "demo:state" (JObject [])
     check failures "an opaque token is sent verbatim as a bearer header"
       (case authorised of
             Right result => resultValue result == JBool True
             Left _ => False)

script : List Reply
script =
  [ Immediate (body ("{\"status\":\"success\",\"value\":{\"count\":7}"
                       ++ ",\"logLines\":[\"demo:echo ran\"]}"))
  , Immediate (statusBody 560 "Convex Error"
                ("{\"status\":\"error\",\"errorMessage\":\"boom\""
                   ++ ",\"errorData\":{\"code\":\"BOOM\"}}"))
  , Immediate (statusBody 500 "Internal Server Error"
                "{\"status\":\"error\",\"errorMessage\":\"upstream\"}")
  , Immediate (statusBody 400 "Bad Request"
                "{\"status\":\"error\",\"errorMessage\":\"bad args\"}")
  , Immediate ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                 ++ "13\r\n{\"status\":\"success\"\r\n"
                 ++ "e\r\n,\"value\":{\"cou\r\n"
                 ++ "7\r\nnt\":3}}\r\n0\r\n\r\n")
  , Immediate ("HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\nConnection: close\r\n\r\n{}")
  , Dribble (body "{\"status\":\"success\",\"value\":1}") 60
  , ReportAuth "test-token-42"
  ]

covering
main : IO ()
main =
  do initialise
     failures <- newIORef 0
     listener <- tcpListen "127.0.0.1" 0
     if listener < 0
        then do ignore $ fPutStrLn stderr "could not bind the HTTP fixture"
                exitFailure
        else do portNumber <- tcpPort listener
                child <- forkProcess
                if child == 0
                   then do serveScript listener script
                           exitNow 0
                   else do closeFd listener
                           runTests failures portNumber
                           killProcess child
                           deadline <- deadlineIn 3000
                           ignore $ waitProcess child deadline
                           failureCount <- readIORef failures
                           if failureCount == 0
                              then putStrLn "http tests passed"
                              else do ignore $ fPutStrLn stderr
                                                 ("http tests failed: " ++ show failureCount)
                                      exitFailure
