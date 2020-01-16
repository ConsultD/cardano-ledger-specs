{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}


module Tx
  ( -- transaction
    Tx(..)
  , TxBody(..)
  , TxOut(..)
  , TxIn(..)
  , TxId(..)
  , txUpdate
  , inputs
  , outputs
  , certs
  , wdrls
  , txfee
  , ttl
  , body
  , witnessVKeySet
  , witnessMSigMap
    -- witness data
  , WitVKey(..)
  , MultiSignatureScript
  , validateScript
  , hashScript
  , isKeyCombination
  , txwitsScript
  , extractKeyHash
  , extractScriptHash
  , extractGenKeyHash
  )
where


import           Keys (AnyKeyHash, GenKeyHash, undiscriminateKeyHash)

import           Cardano.Binary (ToCBOR (toCBOR), encodeWord8)
import           Cardano.Crypto.Hash (hashWithSerialiser)
import           Cardano.Ledger.Shelley.Crypto
import           Data.Map.Strict (Map)
import           Data.Maybe (mapMaybe)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word (Word8)

import           TxData (Credential (..), MultiSig (..), ScriptHash (..), Tx (..), TxBody (..),
                     TxId (..), TxIn (..), TxOut (..), WitVKey (..), body, certs, inputs, outputs,
                     ttl, txUpdate, txfee, wdrls, witKeyHash, witnessMSigMap, witnessVKeySet)

-- | Typeclass for multis-signature script data types. Allows for script
-- validation and hashing.
class (Crypto crypto, ToCBOR a) =>
  MultiSignatureScript a crypto where
  validateScript :: a -> Tx crypto -> Bool
  hashScript :: a -> ScriptHash crypto

-- | Script evaluator for native multi-signature scheme. 'vhks' is the set of
-- key hashes that signed the transaction to be validated.
evalNativeMultiSigScript
  :: MultiSig crypto
  -> Set (AnyKeyHash crypto)
  -> Bool
evalNativeMultiSigScript (RequireSignature hk) vhks = Set.member hk vhks
evalNativeMultiSigScript (RequireAllOf msigs) vhks =
  all (`evalNativeMultiSigScript` vhks) msigs
evalNativeMultiSigScript (RequireAnyOf msigs) vhks =
  any (`evalNativeMultiSigScript` vhks) msigs
evalNativeMultiSigScript (RequireMOf m msigs) vhks =
  m <= sum [if evalNativeMultiSigScript msig vhks then 1 else 0 | msig <- msigs]

-- | Script validator for native multi-signature scheme.
validateNativeMultiSigScript
  :: (Crypto crypto)
  => MultiSig crypto
  -> Tx crypto
  -> Bool
validateNativeMultiSigScript msig tx =
  evalNativeMultiSigScript msig vhks
  where witsSet = _witnessVKeySet tx
        vhks    = Set.map witKeyHash witsSet

-- | Hashes native multi-signature script, appending the 'nativeMultiSigTag' in
-- front and then calling the script CBOR function.
hashNativeMultiSigScript
  :: Crypto crypto
  => MultiSig crypto
  -> ScriptHash crypto
hashNativeMultiSigScript msig =
  ScriptHash $ hashWithSerialiser (\x -> encodeWord8 nativeMultiSigTag
                                          <> toCBOR x) msig

-- | Check if a set of keys satisfies a MultiSig.
isKeyCombination :: Set (AnyKeyHash crypto) -> MultiSig crypto -> Bool
isKeyCombination ks (RequireSignature hk) = hk `Set.member` ks
isKeyCombination ks (RequireAllOf msigs) = all (isKeyCombination ks) msigs
isKeyCombination ks (RequireAnyOf msigs) = any (isKeyCombination ks) msigs
isKeyCombination ks (RequireMOf m msigs) =
  m == length (take m $ filter (isKeyCombination ks) msigs)

-- | Magic number representing the tag of the native multi-signature script
-- language. For each script language included, a new tag is chosen and the tag
-- is included in the script hash for a script.
nativeMultiSigTag :: Word8
nativeMultiSigTag = 0

instance Crypto crypto =>
  MultiSignatureScript (MultiSig crypto) crypto where
  validateScript = validateNativeMultiSigScript
  hashScript = hashNativeMultiSigScript

-- | Multi-signature script witness accessor function for Transactions
txwitsScript
  :: Tx crypto
  -> Map (ScriptHash crypto) (MultiSig crypto)
txwitsScript = _witnessMSigMap

extractKeyHash
  :: [Credential crypto]
  -> [AnyKeyHash crypto]
extractKeyHash =
  mapMaybe (\case
                KeyHashObj hk -> Just $ undiscriminateKeyHash hk
                _ -> Nothing)

extractScriptHash
  :: [Credential crypto]
  -> [ScriptHash crypto]
extractScriptHash =
  mapMaybe (\case
                ScriptHashObj hk -> Just hk
                _ -> Nothing)

extractGenKeyHash
  :: [GenKeyHash crypto]
  -> [AnyKeyHash crypto]
extractGenKeyHash = map undiscriminateKeyHash
