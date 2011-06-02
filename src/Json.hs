-----------------------------------------------------------------------------
-- |
-- Module      :  Json
-- Copyright   :  (c) 2011 Leon P Smith
-- License     :  BSD3
--
-- Maintainer  :  Leon P Smith <leon@melding-monads.com>
--
-- Data structure agnostic JSON serialization
--
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE ViewPatterns         #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE UndecidableInstances #-}

module Json
     ( Value(..)
     , Object
     , row
     , Array
     , element
     ) where

import           Blaze.ByteString.Builder as Blaze
import           Blaze.ByteString.Builder.ByteString
import           Blaze.ByteString.Builder.Char8
-- import           Blaze.ByteString.Builder.Char.Utf8
import           Blaze.Text (float, double, integral)

import           Data.Bits (shiftL, shiftR, (.&.))
import qualified Data.Map               as Map
import           Data.Monoid
import           Data.Word (Word16, Word8)

import qualified Data.Char              as Char

import qualified Data.ByteString        as BS
import qualified Data.ByteString.Lazy   as BL
import qualified Data.ByteString.UTF8   as BU
import qualified Data.ByteString.Lazy.UTF8 as BLU
import           Data.ByteString.Char8()
import           Data.ByteString.Internal (w2c, c2w)

import           Data.Text (Text)
import qualified Data.Text              as T
import           Data.Text.Encoding (encodeUtf8)

---- The "core" of json-builder

class Value a where
  toBuilder        :: a -> Blaze.Builder
  toByteString     :: a -> BS.ByteString
  toLazyByteString :: a -> BL.ByteString
  toByteString     = Blaze.toByteString     . toBuilder
  toLazyByteString = Blaze.toLazyByteString . toBuilder

class Value a => Key a


newtype Object = Object (Bool -> Pair)

data Pair = Pair !Blaze.Builder !Bool

instance Value Object where
  toBuilder (Object f)
    = case f True of
        Pair fb _ -> mconcat [fromChar '{', fb, fromChar '}']

instance Monoid Object where
  mempty = Object $ \x -> Pair mempty x
  mappend (Object f) (Object g)
    = Object $ \x -> case f x of
                      Pair fb x' ->
                           case g x' of
                            Pair gb x'' ->
                                 Pair (fb `mappend` gb) x''

row :: (Key a, Value b) => a -> b -> Object
row a b = Object syntax
  where
    syntax = comma (mconcat [ toBuilder a, fromChar ':',  toBuilder b ])
    comma b True  = Pair b False
    comma b False = Pair (fromChar ',' `mappend` b) False


newtype Array = Array (Bool -> Pair)

instance Value Array where
  toBuilder (Array f)
    = case f True of
        Pair fb _ -> mconcat [fromChar '[', fb, fromChar ']']

instance Monoid Array where
  mempty = Array $ \x -> Pair mempty x
  mappend (Array f) (Array g)
    = Array $ \x -> case f x of
                     Pair fb x' ->
                          case g x' of
                           Pair gb x'' ->
                                Pair (fb `mappend` gb) x''

element :: Value a => a -> Array
element a = Array $ comma (toBuilder a)
  where
    comma b True  = Pair b False
    comma b False = Pair (fromChar ',' `mappend` b) False


-- Primitive instances for json-builder

instance Value () where
  toBuilder _ = fromByteString "null"

instance Integral a => Value a where
  toBuilder = integral

instance Value Double where
  toBuilder = double

instance Value Float where
  toBuilder = float

instance Value Bool where
  toBuilder True  = fromByteString "true"
  toBuilder False = fromByteString "false"

instance Value BS.ByteString where
  toBuilder x = fromChar '"' `mappend` loop (splitQ x)
    where
      splitQ = BU.break quoteNeeded

      loop (a,b)
        = fromByteString a `mappend`
            case BU.decode b of
              Nothing     ->  fromChar '"'
              Just (c,n)  ->  fromWrite (quoteChar c) `mappend`
                                loop (splitQ (BS.drop n b))

instance Key BS.ByteString

instance Value BL.ByteString where
  toBuilder x = fromChar '"' `mappend` loop (splitQ x)
    where
      splitQ = BLU.break quoteNeeded

      loop (a,b)
        = fromLazyByteString a `mappend`
            case BLU.decode b of
              Nothing     ->  fromChar '"'
              Just (c,n)  ->  fromWrite (quoteChar c) `mappend`
                                loop (splitQ (BL.drop n b))

instance Key BL.ByteString

-- FIXME: rewrite/optimize the quoting routines for ByteString, Text, String
--        Should we support direct quoting of lazy ByteStrings/ lazy Text?

instance Value Text where
  toBuilder = toBuilder . encodeUtf8

instance Key Text

instance Value [Char] where
  toBuilder = toBuilder . BU.fromString

instance Key [Char]

-- Convenient (?) instances for json-builder

instance Value a => Value [a] where
  toBuilder = toBuilder . mconcat . map element

instance Value a => Value (Map.Map BS.ByteString a) where
  toBuilder = toBuilder
            . Map.foldrWithKey (\k a b -> row k a `mappend` b) mempty


------------------------------------------------------------------------------

quoteNeeded :: Char -> Bool
quoteNeeded c = c == '\\' || c == '"' || Char.ord c < 0x20

quoteChar :: Char -> Write
quoteChar c = case c of
                '\\'  ->  writeByteString "\\\\"
                '"'   ->  writeByteString "\\\""
                '\b'  ->  writeByteString "\\b"
                '\f'  ->  writeByteString "\\f"
                '\n'  ->  writeByteString "\\n"
                '\r'  ->  writeByteString "\\r"
                '\t'  ->  writeByteString "\\t"
                _     ->  hexEscape c

hexEscape  :: Char -> Write
hexEscape  (c2w -> c)
  = writeByteString "\\u00"
    `mappend` writeWord8 (char ((c `shiftR`  4) .&. 0xF))
    `mappend` writeWord8 (char ( c              .&. 0xF))

char :: Word8 -> Word8
char i | i < 10    = i + 48
       | otherwise = i + 87
{-# INLINE char #-}
