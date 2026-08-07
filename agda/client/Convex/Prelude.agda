{-# OPTIONS --without-K #-}

-- The Convex demonstration deliberately builds on Agda's own builtin modules
-- instead of a separately fetched standard library. Those builtins ship with
-- the pinned compiler, so the Docker build has exactly one Agda dependency to
-- pin and a reviewer can follow every helper used by the client from here.
module Convex.Prelude where

open import Agda.Builtin.Bool public using (Bool; true; false)
open import Agda.Builtin.Nat public using (Nat; zero; suc; _+_; _*_; _-_)
open import Agda.Builtin.Nat using (_==_; _<_; div-helper; mod-helper)
open import Agda.Builtin.List public using (List; []; _∷_)
open import Agda.Builtin.Maybe public using (Maybe; just; nothing)
open import Agda.Builtin.Char public using (Char)
open import Agda.Builtin.Char using (primCharToNat; primNatToChar; primCharEquality)
open import Agda.Builtin.String public using (String)
open import Agda.Builtin.String
  using (primStringToList; primStringFromList; primStringAppend; primStringEquality)
open import Agda.Builtin.Sigma public using (Σ; _,_; fst; snd)
open import Agda.Builtin.Unit public using (⊤; tt)

--------------------------------------------------------------------------------
-- Booleans
--------------------------------------------------------------------------------

-- Without a declared fixity, `if_then_else_` defaults to a precedence tight
-- enough that an unparenthesised `∷`-chain in a branch parses as
-- `(if ... then ... else x) ∷ xs` instead of `if ... then ... else (x ∷ xs)`
-- -- a well-known Agda gotcha. `infix 0` gives it the lowest precedence in
-- this module, so every branch below absorbs a full expression the way a
-- reader expects.
infix 0 if_then_else_
if_then_else_ : {A : Set} → Bool → A → A → A
if true then t else _ = t
if false then _ else f = f

not : Bool → Bool
not true = false
not false = true

infixr 2 _∧_
_∧_ : Bool → Bool → Bool
true ∧ b = b
false ∧ _ = false

infixr 1 _∨_
_∨_ : Bool → Bool → Bool
true ∨ _ = true
false ∨ b = b

--------------------------------------------------------------------------------
-- Natural numbers
--------------------------------------------------------------------------------

infix 4 _==ⁿ_ _<ⁿ_ _≤ⁿ_ _>ⁿ_ _≥ⁿ_

_==ⁿ_ : Nat → Nat → Bool
_==ⁿ_ = _==_

_<ⁿ_ : Nat → Nat → Bool
_<ⁿ_ = _<_

_≤ⁿ_ : Nat → Nat → Bool
a ≤ⁿ b = a < suc b

_>ⁿ_ : Nat → Nat → Bool
a >ⁿ b = b < a

_≥ⁿ_ : Nat → Nat → Bool
a ≥ⁿ b = b ≤ⁿ a

-- Division by zero yields zero. Every caller in this client divides by a
-- literal, so the total definition never hides a real arithmetic mistake.
infixl 7 _div_ _mod_

_div_ : Nat → Nat → Nat
_ div zero = zero
n div (suc m) = div-helper 0 m n m

_mod_ : Nat → Nat → Nat
_ mod zero = zero
n mod (suc m) = mod-helper 0 m n m

min : Nat → Nat → Nat
min a b = if a <ⁿ b then a else b

max : Nat → Nat → Nat
max a b = if a <ⁿ b then b else a

-- 2 ^ n, used by the frame-length, timestamp, and SHA-1 word arithmetic.
pow2 : Nat → Nat
pow2 zero = 1
pow2 (suc n) = 2 * pow2 n

--------------------------------------------------------------------------------
-- Characters
--------------------------------------------------------------------------------

infix 4 _==ᶜ_

_==ᶜ_ : Char → Char → Bool
_==ᶜ_ = primCharEquality

charCode : Char → Nat
charCode = primCharToNat

charFromCode : Nat → Char
charFromCode = primNatToChar

isDigit : Char → Bool
isDigit c = (48 ≤ⁿ charCode c) ∧ (charCode c ≤ⁿ 57)

hexDigitValue : Char → Maybe Nat
hexDigitValue c =
  let n = charCode c in
  if (48 ≤ⁿ n) ∧ (n ≤ⁿ 57) then just (n - 48)
  else if (97 ≤ⁿ n) ∧ (n ≤ⁿ 102) then just (n - 87)
  else if (65 ≤ⁿ n) ∧ (n ≤ⁿ 70) then just (n - 55)
  else nothing

hexDigitChar : Nat → Char
hexDigitChar n =
  if n <ⁿ 10 then charFromCode (48 + n) else charFromCode (97 + (n - 10))

--------------------------------------------------------------------------------
-- Sums and products
--------------------------------------------------------------------------------

data Either (A B : Set) : Set where
  left : A → Either A B
  right : B → Either A B

infixr 2 _×_
_×_ : Set → Set → Set
A × B = Σ A (λ _ → B)

--------------------------------------------------------------------------------
-- Maybe
--------------------------------------------------------------------------------

fromMaybe : {A : Set} → A → Maybe A → A
fromMaybe d nothing = d
fromMaybe _ (just a) = a

isJust : {A : Set} → Maybe A → Bool
isJust nothing = false
isJust (just _) = true

mapMaybe : {A B : Set} → (A → B) → Maybe A → Maybe B
mapMaybe _ nothing = nothing
mapMaybe f (just a) = just (f a)

--------------------------------------------------------------------------------
-- Lists
--------------------------------------------------------------------------------

infixr 5 _++_

_++_ : {A : Set} → List A → List A → List A
[] ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)

length : {A : Set} → List A → Nat
length [] = 0
length (_ ∷ xs) = suc (length xs)

map : {A B : Set} → (A → B) → List A → List B
map _ [] = []
map f (x ∷ xs) = f x ∷ map f xs

filter : {A : Set} → (A → Bool) → List A → List A
filter _ [] = []
filter p (x ∷ xs) = if p x then x ∷ filter p xs else filter p xs

foldl : {A B : Set} → (B → A → B) → B → List A → B
foldl _ acc [] = acc
foldl f acc (x ∷ xs) = foldl f (f acc x) xs

foldr : {A B : Set} → (A → B → B) → B → List A → B
foldr _ acc [] = acc
foldr f acc (x ∷ xs) = f x (foldr f acc xs)

reverse : {A : Set} → List A → List A
reverse = foldl (λ acc x → x ∷ acc) []

concat : {A : Set} → List (List A) → List A
concat = foldr _++_ []

any : {A : Set} → (A → Bool) → List A → Bool
any p xs = foldr (λ x acc → p x ∨ acc) false xs

drop : {A : Set} → Nat → List A → List A
drop zero xs = xs
drop _ [] = []
drop (suc n) (_ ∷ xs) = drop n xs

-- Association-list lookup. Convex payload objects are small, so a linear scan
-- keeps the decoder allocation-free without an ordered container.
lookupBy : {A B : Set} → (A → Bool) → List (Σ A (λ _ → B)) → Maybe B
lookupBy _ [] = nothing
lookupBy p ((k , v) ∷ rest) = if p k then just v else lookupBy p rest

--------------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------------

infixr 5 _<>_

_<>_ : String → String → String
_<>_ = primStringAppend

infix 4 _==ˢ_

_==ˢ_ : String → String → Bool
_==ˢ_ = primStringEquality

stringToList : String → List Char
stringToList = primStringToList

stringFromList : List Char → String
stringFromList = primStringFromList

-- Length in Unicode code points, not wire octets. Everything that must agree
-- with a byte budget uses Convex.Bytes instead.
stringLength : String → Nat
stringLength s = length (stringToList s)

stringConcat : List String → String
stringConcat = foldr _<>_ ""

showNat : Nat → String
showNat n = stringFromList (go n)
  where
    -- Fuel is the value itself: each step divides by ten, so the recursion is
    -- structurally justified without a termination pragma.
    digits : Nat → Nat → List Char
    digits zero _ = []
    digits (suc fuel) v =
      if v ==ⁿ 0 then []
      else digits fuel (v div 10) ++ (charFromCode (48 + (v mod 10)) ∷ [])

    go : Nat → List Char
    go zero = '0' ∷ []
    go v = digits (suc v) v

showHex : Nat → Nat → String
showHex width value = stringFromList (go width value)
  where
    go : Nat → Nat → List Char
    go zero _ = []
    go (suc w) v = go w (v div 16) ++ (hexDigitChar (v mod 16) ∷ [])
