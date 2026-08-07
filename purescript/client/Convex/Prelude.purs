-- | The small prelude this demonstration is written against.
-- |
-- | PureScript ships no built-in prelude: the compiler only knows `Prim`, and
-- | everything else — even `+` and `==` — is an ordinary library definition.
-- | The purerl ecosystem publishes preludes of its own, but they move
-- | independently of the compiler, so depending on one would make the Docker
-- | build depend on a package set resolving the same way twice. This module is
-- | the alternative: the handful of types, operators, and list helpers the
-- | client actually uses, defined here so the whole build is two pinned
-- | compiler binaries and nothing else.
-- |
-- | Two design choices are worth knowing before reading the rest of the client:
-- |
-- | * `do` notation works because PureScript desugars it to whatever `bind` and
-- |   `discard` are in scope. Those are defined here for `Effect` only, so
-- |   `do` always means "a sequence of side effects" and never a monad the
-- |   reader has to identify first.
-- | * `==`, `<`, and friends are backed by Erlang's total term ordering rather
-- |   than by type classes. That is sound for the values this client compares
-- |   (integers, strings, byte strings, and decoded JSON), and it keeps the
-- |   client free of instance resolution that a reader would have to trace.
module Convex.Prelude
  ( Unit
  , unit
  , Effect
  , pure
  , bind
  , discard
  , mapEffect
  , voidEffect
  , whenEffect
  , unlessEffect
  , forEach
  , foldEffect
  , repeatEffect
  , Maybe(..)
  , maybe
  , fromMaybe
  , isJust
  , isNothing
  , maybeMap
  , maybeThen
  , Either(..)
  , either
  , isRight
  , rightOr
  , mapLeft
  , eitherThen
  , Tuple(..)
  , fst
  , snd
  , List(..)
  , nil
  , cons
  , listSingleton
  , listPair
  , listNull
  , listLength
  , listHead
  , listReverse
  , listAppend
  , listSnoc
  , listMap
  , listFilter
  , listFilterMap
  , listFoldl
  , listFind
  , listAny
  , listAll
  , listContains
  , listRange
  , listSortBy
  , listTraverseEither
  , listTraverseMaybe
  , listConcatMapString
  , not
  , andBool
  , orBool
  , termEq
  , termNotEq
  , termLess
  , termLessOrEqual
  , termGreater
  , termGreaterOrEqual
  , addInt
  , subInt
  , mulInt
  , divInt
  , remInt
  , negateInt
  , negateNumber
  , minInt
  , maxInt
  , clampInt
  , bitAnd
  , bitOr
  , bitXor
  , intToString
  , intToLowerHex
  , parseInt
  , parseIntBase16
  , intToNumber
  , truncateNumber
  , numberToString
  , parseNumber
  , maxSafeInt
  , minSafeInt
  , maxUnsigned32
  , appendString
  , stringByteLength
  , stringCodepointLength
  , stringSlice
  , stringIndexOf
  , stringContains
  , stringStartsWith
  , stringLowercase
  , stringTrim
  , stringDropStart
  , stringSplitOnce
  , stringSplit
  , stringJoin
  , stringRepeat
  , applyFn
  , applyFlipped
  , identity
  , (+)
  , (-)
  , (*)
  , (==)
  , (/=)
  , (<)
  , (<=)
  , (>)
  , (>=)
  , (&&)
  , (||)
  , (<>)
  , ($)
  , (#)
  ) where

-- ---------------------------------------------------------------------------
-- Unit and Effect
-- ---------------------------------------------------------------------------

-- | The value returned by an effect that has nothing to say. It is a foreign
-- | type so that its Erlang representation is the single `unit` atom the FFI
-- | modules return, rather than something this module has to guess at.
foreign import data Unit :: Type

foreign import unit :: Unit

-- | A description of work to perform. Evaluating an `Effect` value does
-- | nothing; running it is what performs the sockets, timers, and messages the
-- | client is built from. On the BEAM one of these is a zero-argument function.
foreign import data Effect :: Type -> Type

-- | Wrap a value that needed no work to produce.
foreign import pure :: forall a. a -> Effect a

-- | Sequence two effects, passing the first result to the second step. This is
-- | the function `x <- action` desugars to.
foreign import bind :: forall a b. Effect a -> (a -> Effect b) -> Effect b

-- | Sequence two effects and throw the first result away. This is the function
-- | a `do` statement without a binder desugars to.
discard :: forall a b. Effect a -> (a -> Effect b) -> Effect b
discard = bind

mapEffect :: forall a b. (a -> b) -> Effect a -> Effect b
mapEffect f action = bind action \value -> pure (f value)

voidEffect :: forall a. Effect a -> Effect Unit
voidEffect action = bind action \_ -> pure unit

whenEffect :: Boolean -> Effect Unit -> Effect Unit
whenEffect condition action = if condition then action else pure unit

unlessEffect :: Boolean -> Effect Unit -> Effect Unit
unlessEffect condition action = if condition then pure unit else action

forEach :: forall a. List a -> (a -> Effect Unit) -> Effect Unit
forEach items action = case items of
  Nil -> pure unit
  Cons first rest -> bind (action first) \_ -> forEach rest action

-- | Fold an effectful step over a list, carrying state from one item to the
-- | next. The Live owner uses this to apply a whole transition in order.
foldEffect :: forall a s. s -> List a -> (s -> a -> Effect s) -> Effect s
foldEffect state items step = case items of
  Nil -> pure state
  Cons first rest -> bind (step state first) \next -> foldEffect next rest step

-- | Run an effect for each integer in `[1, count]`. Used by the fixtures to
-- | drive a scenario a fixed number of times without building a list first.
repeatEffect :: Int -> (Int -> Effect Unit) -> Effect Unit
repeatEffect count action = go 1
  where
  go index =
    if index > count then pure unit
    else bind (action index) \_ -> go (index + 1)

-- ---------------------------------------------------------------------------
-- Optional and fallible values
-- ---------------------------------------------------------------------------

data Maybe a
  = Nothing
  | Just a

maybe :: forall a b. b -> (a -> b) -> Maybe a -> b
maybe fallback f value = case value of
  Nothing -> fallback
  Just inner -> f inner

fromMaybe :: forall a. a -> Maybe a -> a
fromMaybe fallback value = case value of
  Nothing -> fallback
  Just inner -> inner

isJust :: forall a. Maybe a -> Boolean
isJust value = case value of
  Nothing -> false
  Just _ -> true

isNothing :: forall a. Maybe a -> Boolean
isNothing value = not (isJust value)

maybeMap :: forall a b. (a -> b) -> Maybe a -> Maybe b
maybeMap f value = case value of
  Nothing -> Nothing
  Just inner -> Just (f inner)

-- | Continue only when a value is present. Written so the continuation can be
-- | a trailing lambda, which reads like the `use` syntax other clients in this
-- | repository lean on.
maybeThen :: forall a b. Maybe a -> (a -> Maybe b) -> Maybe b
maybeThen value f = case value of
  Nothing -> Nothing
  Just inner -> f inner

data Either e a
  = Left e
  | Right a

either :: forall e a b. (e -> b) -> (a -> b) -> Either e a -> b
either onLeft onRight value = case value of
  Left problem -> onLeft problem
  Right inner -> onRight inner

isRight :: forall e a. Either e a -> Boolean
isRight value = case value of
  Left _ -> false
  Right _ -> true

rightOr :: forall e a. a -> Either e a -> a
rightOr fallback value = case value of
  Left _ -> fallback
  Right inner -> inner

mapLeft :: forall e f a. (e -> f) -> Either e a -> Either f a
mapLeft f value = case value of
  Left problem -> Left (f problem)
  Right inner -> Right inner

-- | Continue only when the previous step succeeded, keeping the first failure.
eitherThen :: forall e a b. Either e a -> (a -> Either e b) -> Either e b
eitherThen value f = case value of
  Left problem -> Left problem
  Right inner -> f inner

data Tuple a b = Tuple a b

fst :: forall a b. Tuple a b -> a
fst (Tuple value _) = value

snd :: forall a b. Tuple a b -> b
snd (Tuple _ value) = value

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------

-- | A singly linked list. PureScript's `Array` literal syntax exists, but on
-- | the Erlang backend it becomes the `array` module rather than the cons
-- | cells everything in this client actually wants, so the client uses this.
data List a
  = Nil
  | Cons a (List a)

nil :: forall a. List a
nil = Nil

cons :: forall a. a -> List a -> List a
cons = Cons

listSingleton :: forall a. a -> List a
listSingleton value = Cons value Nil

listPair :: forall a. a -> a -> List a
listPair first second = Cons first (Cons second Nil)

listNull :: forall a. List a -> Boolean
listNull items = case items of
  Nil -> true
  Cons _ _ -> false

listLength :: forall a. List a -> Int
listLength items = go 0 items
  where
  go total rest = case rest of
    Nil -> total
    Cons _ tail -> go (total + 1) tail

listHead :: forall a. List a -> Maybe a
listHead items = case items of
  Nil -> Nothing
  Cons first _ -> Just first

listReverse :: forall a. List a -> List a
listReverse items = go Nil items
  where
  go acc rest = case rest of
    Nil -> acc
    Cons first tail -> go (Cons first acc) tail

listAppend :: forall a. List a -> List a -> List a
listAppend left right = case left of
  Nil -> right
  Cons first rest -> Cons first (listAppend rest right)

-- | Append one item to the end. Delivery queues are drained from the front, so
-- | the natural insertion point is the back.
listSnoc :: forall a. List a -> a -> List a
listSnoc items value = listAppend items (listSingleton value)

listMap :: forall a b. (a -> b) -> List a -> List b
listMap f items = case items of
  Nil -> Nil
  Cons first rest -> Cons (f first) (listMap f rest)

listFilter :: forall a. (a -> Boolean) -> List a -> List a
listFilter keep items = case items of
  Nil -> Nil
  Cons first rest ->
    if keep first then Cons first (listFilter keep rest)
    else listFilter keep rest

listFilterMap :: forall a b. (a -> Maybe b) -> List a -> List b
listFilterMap f items = case items of
  Nil -> Nil
  Cons first rest -> case f first of
    Nothing -> listFilterMap f rest
    Just value -> Cons value (listFilterMap f rest)

listFoldl :: forall a s. s -> List a -> (s -> a -> s) -> s
listFoldl state items step = case items of
  Nil -> state
  Cons first rest -> listFoldl (step state first) rest step

listFind :: forall a. (a -> Boolean) -> List a -> Maybe a
listFind matches items = case items of
  Nil -> Nothing
  Cons first rest -> if matches first then Just first else listFind matches rest

listAny :: forall a. (a -> Boolean) -> List a -> Boolean
listAny matches items = isJust (listFind matches items)

listAll :: forall a. (a -> Boolean) -> List a -> Boolean
listAll matches items = isNothing (listFind (\item -> not (matches item)) items)

listContains :: forall a. a -> List a -> Boolean
listContains needle items = listAny (\item -> termEq item needle) items

-- | Inclusive integer range. An empty range is normal rather than an error.
listRange :: Int -> Int -> List Int
listRange from to =
  if from > to then Nil
  else Cons from (listRange (from + 1) to)

-- | Insertion sort with a caller-supplied "is less than" test. Every sorted
-- | list in this client is a handful of subscriptions, so the simple algorithm
-- | is the readable one.
listSortBy :: forall a. (a -> a -> Boolean) -> List a -> List a
listSortBy before items = case items of
  Nil -> Nil
  Cons first rest -> insert first (listSortBy before rest)
  where
  insert value sorted = case sorted of
    Nil -> Cons value Nil
    Cons head tail ->
      if before value head then Cons value sorted
      else Cons head (insert value tail)

-- | Map a fallible step over a list, stopping at the first failure. Protocol
-- | decoding uses this so one bad element rejects the whole message.
listTraverseEither
  :: forall e a b. (a -> Either e b) -> List a -> Either e (List b)
listTraverseEither f items = case items of
  Nil -> Right Nil
  Cons first rest -> case f first of
    Left problem -> Left problem
    Right value -> case listTraverseEither f rest of
      Left problem -> Left problem
      Right values -> Right (Cons value values)

-- | The same, for a step that answers with a `Maybe`.
listTraverseMaybe :: forall a b. (a -> Maybe b) -> List a -> Maybe (List b)
listTraverseMaybe f items = case items of
  Nil -> Just Nil
  Cons first rest -> case f first of
    Nothing -> Nothing
    Just value -> case listTraverseMaybe f rest of
      Nothing -> Nothing
      Just values -> Just (Cons value values)

-- | Render each item and concatenate. Used where a string is assembled from a
-- | list that is already known to be short.
listConcatMapString :: forall a. (a -> String) -> List a -> String
listConcatMapString f items =
  listFoldl "" items \acc item -> appendString acc (f item)

-- ---------------------------------------------------------------------------
-- Booleans, comparison, and arithmetic
-- ---------------------------------------------------------------------------

not :: Boolean -> Boolean
not value = if value then false else true

-- | `&&` and `||` are ordinary functions here, so both operands are evaluated.
-- | Nothing in this client relies on short-circuiting; conditions that must not
-- | run are written as nested `if` or `case` instead.
andBool :: Boolean -> Boolean -> Boolean
andBool left right = if left then right else false

orBool :: Boolean -> Boolean -> Boolean
orBool left right = if left then true else right

-- | Exact structural equality, backed by Erlang's `=:=`. It distinguishes an
-- | integer from a float with the same value, which is what the JSON decoder
-- | needs: `1` and `1.0` arrive as different Convex spellings and the client
-- | decides deliberately whether to treat them alike.
foreign import termEq :: forall a. a -> a -> Boolean

termNotEq :: forall a. a -> a -> Boolean
termNotEq left right = not (termEq left right)

-- | Erlang's total term ordering. Used for integers throughout and for the
-- | byte-wise ordering of strings in a couple of sorted lookups.
foreign import termLess :: forall a. a -> a -> Boolean

termLessOrEqual :: forall a. a -> a -> Boolean
termLessOrEqual left right = orBool (termLess left right) (termEq left right)

termGreater :: forall a. a -> a -> Boolean
termGreater left right = termLess right left

termGreaterOrEqual :: forall a. a -> a -> Boolean
termGreaterOrEqual left right = not (termLess left right)

foreign import addInt :: Int -> Int -> Int
foreign import subInt :: Int -> Int -> Int
foreign import mulInt :: Int -> Int -> Int

-- | Truncating integer division. Dividing by zero would be a programming
-- | error, so the FFI answers zero rather than raising inside a socket loop.
foreign import divInt :: Int -> Int -> Int

foreign import remInt :: Int -> Int -> Int

-- | PureScript's unary minus needs a `negate` in scope, and this prelude
-- | deliberately has no numeric type class to provide one for both `Int` and
-- | `Number`. Negative values are written with these instead.
foreign import negateInt :: Int -> Int

foreign import negateNumber :: Number -> Number

minInt :: Int -> Int -> Int
minInt left right = if left < right then left else right

maxInt :: Int -> Int -> Int
maxInt left right = if left > right then left else right

clampInt :: Int -> Int -> Int -> Int
clampInt low high value = maxInt low (minInt high value)

foreign import bitAnd :: Int -> Int -> Int
foreign import bitOr :: Int -> Int -> Int
foreign import bitXor :: Int -> Int -> Int

foreign import intToString :: Int -> String

-- | Lowercase hexadecimal without a prefix, left-padded to `width` digits.
foreign import intToLowerHex :: Int -> Int -> String

-- | Parse a decimal integer. Anything with stray characters, a leading plus,
-- | or surrounding whitespace is rejected rather than partially consumed.
parseInt :: String -> Maybe Int
parseInt text = if parseIntOk text then Just (parseIntValue text) else Nothing

foreign import parseIntOk :: String -> Boolean
foreign import parseIntValue :: String -> Int

parseIntBase16 :: String -> Maybe Int
parseIntBase16 text =
  if parseIntBase16Ok text then Just (parseIntBase16Value text) else Nothing

foreign import parseIntBase16Ok :: String -> Boolean
foreign import parseIntBase16Value :: String -> Int

foreign import intToNumber :: Int -> Number

-- | Round toward zero. Paired with `intToNumber` this is how the JSON decoder
-- | checks that a float is mathematically a whole number.
foreign import truncateNumber :: Number -> Int

foreign import numberToString :: Number -> String

parseNumber :: String -> Maybe Number
parseNumber text =
  if parseNumberOk text then Just (parseNumberValue text) else Nothing

foreign import parseNumberOk :: String -> Boolean
foreign import parseNumberValue :: String -> Number

-- | The signed 64-bit bounds, and the unsigned 32-bit ceiling the sync
-- | protocol's version counters use. BEAM integers are unbounded and
-- | PureScript integer literals are limited to 32 bits, so both bounds come
-- | from the FFI rather than from a literal in the source.
foreign import maxSafeInt :: Int
foreign import minSafeInt :: Int
foreign import maxUnsigned32 :: Int

-- ---------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------

foreign import appendString :: String -> String -> String

-- | Length in UTF-8 bytes. Every wire limit in this client is a byte limit.
foreign import stringByteLength :: String -> Int

-- | Length in Unicode scalar values, which is how JSON Schema measures the
-- | adapter's identifier limits.
foreign import stringCodepointLength :: String -> Int

-- | Byte-offset substring, clamped to the string so it is total. Callers only
-- | ever slice at boundaries they found with `stringIndexOf`, so the result is
-- | always valid UTF-8.
foreign import stringSlice :: Int -> Int -> String -> String

-- | Byte offset of the first occurrence, or -1 when absent.
foreign import stringIndexOf :: String -> String -> Int

stringContains :: String -> String -> Boolean
stringContains haystack needle = stringIndexOf haystack needle >= 0

stringStartsWith :: String -> String -> Boolean
stringStartsWith text prefix =
  termEq (stringSlice 0 (stringByteLength prefix) text) prefix

foreign import stringLowercase :: String -> String

foreign import stringTrim :: String -> String

stringDropStart :: Int -> String -> String
stringDropStart count text =
  stringSlice count (stringByteLength text) text

-- | Split at the first separator. `Nothing` means the separator is absent,
-- | which callers treat differently from an empty second half.
stringSplitOnce :: String -> String -> Maybe (Tuple String String)
stringSplitOnce text separator =
  let
    index = stringIndexOf text separator
  in
    if index < 0 then Nothing
    else Just
      ( Tuple (stringSlice 0 index text)
          (stringDropStart (index + stringByteLength separator) text)
      )

stringSplit :: String -> String -> List String
stringSplit text separator =
  if stringByteLength separator == 0 then listSingleton text
  else case stringSplitOnce text separator of
    Nothing -> listSingleton text
    Just (Tuple before after) -> Cons before (stringSplit after separator)

stringJoin :: List String -> String -> String
stringJoin parts separator = case parts of
  Nil -> ""
  Cons first rest ->
    listFoldl first rest \acc part ->
      appendString acc (appendString separator part)

stringRepeat :: String -> Int -> String
stringRepeat text count =
  if count <= 0 then ""
  else appendString text (stringRepeat text (count - 1))

-- ---------------------------------------------------------------------------
-- Application helpers
-- ---------------------------------------------------------------------------

applyFn :: forall a b. (a -> b) -> a -> b
applyFn f value = f value

applyFlipped :: forall a b. a -> (a -> b) -> b
applyFlipped value f = f value

identity :: forall a. a -> a
identity value = value

infixl 6 addInt as +
infixl 6 subInt as -
infixl 7 mulInt as *
infix 4 termEq as ==
infix 4 termNotEq as /=
infix 4 termLess as <
infix 4 termLessOrEqual as <=
infix 4 termGreater as >
infix 4 termGreaterOrEqual as >=
infixr 3 andBool as &&
infixr 2 orBool as ||
infixr 5 appendString as <>
infixr 0 applyFn as $
infixl 1 applyFlipped as #
