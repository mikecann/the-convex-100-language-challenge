||| TLS tests against a real forked OpenSSL server.
|||
||| The Docker build generates a throwaway CA and leaf certificate before this
||| runs. Exercising a genuine handshake, a genuine hostname rejection, and a
||| genuine graceful closure in the build stage means a missing provider,
||| configuration file, or certificate path is found here rather than during
||| hosted verification.
module Main

import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import System
import System.File

import Convex.Net
import Convex.Prim

check : IORef Int -> String -> Bool -> IO ()
check failures label ok =
  if ok
     then putStrLn ("ok   " ++ label)
     else do modifyIORef failures (+ 1)
             ignore $ fPutStrLn stderr ("FAIL " ++ label)
             putStrLn ("FAIL " ++ label)

response : String
response = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"

||| Serve `remaining` TLS connections. Two of them are expected to fail during
||| the handshake, because the client rejects the certificate, so the fixture
||| must keep serving rather than treat a failed accept as fatal.
covering
serveTls : Int -> String -> String -> Int -> IO ()
serveTls listener certificateFile keyFile remaining =
  if remaining <= 0
     then pure ()
     else do deadline <- deadlineIn 15000
             accepted <- acceptConnection listener certificateFile keyFile deadline 8192
             case accepted of
                  Left _ => serveTls listener certificateFile keyFile (remaining - 1)
                  Right link =>
                    do exchange link deadline
                       shutdownConnection link
                       closeConnection link
                       serveTls listener certificateFile keyFile (remaining - 1)
  where
    covering
    exchange : Connection -> Int -> IO ()
    exchange link deadline =
      do request <- readLine link 8192 deadline
         case request of
              Left _ => pure ()
              Right _ => ignore $ writeText link response deadline

covering
speak : String -> Int -> String -> IO (Either String String)
speak hostName portNumber caFile =
  do deadline <- deadlineIn 8000
     opened <- openConnection (MkEndpoint True hostName portNumber "/") caFile deadline
                              8192
     case opened of
          Left problem => pure (Left problem)
          Right link =>
            do sent <- writeText link ("GET / HTTP/1.0\r\nHost: " ++ hostName
                                         ++ "\r\n\r\n") deadline
               case sent of
                    Left problem => do closeConnection link
                                       pure (Left problem)
                    Right () =>
                      do line <- readLine link 8192 deadline
                         shutdownConnection link
                         closeConnection link
                         pure line

covering
main : IO ()
main =
  do initialise
     failures <- newIORef 0
     directory <- getEnv "IDRIS_TLS_DIR"
     let base = fromMaybe "/tmp/idris-tls" directory
     let certificateFile = base ++ "/server.crt"
     let keyFile = base ++ "/server.key"
     let caFile = base ++ "/ca.crt"
     listener <- tcpListen "127.0.0.1" 0
     if listener < 0
        then do ignore $ fPutStrLn stderr "could not bind the TLS fixture"
                exitFailure
        else do portNumber <- tcpPort listener
                child <- forkProcess
                if child == 0
                   then do serveTls listener certificateFile keyFile 3
                           exitNow 0
                   else do closeFd listener
                           run failures portNumber caFile
                           killProcess child
                           deadline <- deadlineIn 3000
                           ignore $ waitProcess child deadline
                           failureCount <- readIORef failures
                           if failureCount == 0
                              then putStrLn "tls tests passed"
                              else do ignore $ fPutStrLn stderr
                                                 ("tls tests failed: " ++ show failureCount)
                                      exitFailure
  where
    covering
    run : IORef Int -> Int -> String -> IO ()
    run failures portNumber caFile =
      do -- The certificate names `localhost`, so this handshake must complete
         -- and the exchange must close cleanly on both sides.
         trusted <- speak "localhost" portNumber caFile
         check failures "a trusted certificate for the requested name succeeds"
           (trusted == Right "HTTP/1.0 200 OK")

         -- The same certificate presented for a different name must be
         -- rejected during verification, not merely logged.
         mismatched <- speak "127.0.0.1" portNumber caFile
         check failures "a certificate for another name is rejected"
           (case mismatched of
                 Left _ => True
                 Right _ => False)

         -- Without the fixture CA the system trust store must not accept it.
         untrusted <- speak "localhost" portNumber ""
         check failures "an unknown issuer is rejected by the system trust store"
           (case untrusted of
                 Left _ => True
                 Right _ => False)
