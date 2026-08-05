{-# LANGUAGE OverloadedStrings #-}

module CountTest (main) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Main (wholeCount)

main :: IO ()
main = do
    assertAccepted 0 (toJSON (0.0 :: Double))
    assertAccepted 1 (toJSON (1.0 :: Double))
    assertRejected (toJSON (1.5 :: Double))
    assertRejected (toJSON (toInteger (maxBound :: Int) + 1))
    assertRejected (toJSON (toInteger (minBound :: Int) - 1))
    putStrLn "haskell canonical example count decoding passes"

assertAccepted :: Int -> Value -> IO ()
assertAccepted expected count = do
    actual <- wholeCount "fixture" (countValue count)
    unless (actual == expected) (fail ("decoded " <> show actual <> ", expected " <> show expected))

assertRejected :: Value -> IO ()
assertRejected count = do
    outcome <- try (wholeCount "fixture" (countValue count)) :: IO (Either SomeException Int)
    case outcome of
        Left _ -> pure ()
        Right actual -> fail ("accepted out-of-range or fractional count as " <> show actual)

countValue :: Value -> Value
countValue count = object ["count" .= count]
