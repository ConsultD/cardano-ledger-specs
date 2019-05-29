{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Test.Cardano.Chain.Elaboration.UTxO
  ( UTxO
  , TxWits
  , Tx
  , TxId
  , TxIn
  , Wit
  , elaborateUTxOEnv
  , elaborateUTxO
  , elaborateTxWitsBS
  , elaborateTxOut
  , ConcreteResult(..)
  )
where

import Cardano.Prelude

import qualified Data.ByteString.Lazy as LBS
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import Data.Sequence ((<|))
import Data.Typeable (typeOf)
import qualified Data.Vector as V
import Formatting hiding (bytes)

import qualified Cardano.Binary as CBOR
import qualified Cardano.Chain.Common as Concrete
import qualified Cardano.Chain.UTxO as Concrete
import qualified Cardano.Chain.UTxO.UTxO as Concrete.UTxO
import qualified Cardano.Chain.UTxO.Validation as Concrete.UTxO
import qualified Cardano.Chain.Update as Concrete
import Cardano.Crypto

import Data.AbstractSize (HasTypeReps(..))
import qualified Cardano.Ledger.Spec.STS.UTXO as Abstract
import qualified Ledger.Core as Abstract
import qualified Ledger.UTxO as Abstract

import Hedgehog

import Test.Cardano.Chain.Elaboration.Keys
import Test.Cardano.Chain.Genesis.Dummy
import qualified Test.Cardano.Crypto.Dummy as Dummy


-- | We return both the result of the update and the concrete transaction that
--   was applied. We need the latter for extracting the `TxId` of the
--   transaction. We could get this from the signal in the update callback, but
--   that would duplicate elaboration efforts.
data ConcreteResult = ConcreteResult
  { crResult :: Either Concrete.UTxOValidationError Concrete.UTxO
  , crAppliedTx :: Concrete.Tx
  } deriving (Eq, Show)

instance Ord ConcreteResult where
  compare = comparing crAppliedTx

type TxId v = Either Abstract.Addr (Var ConcreteResult v)

instance Typeable v => HasTypeReps (TxId v) where
  typeReps (Left a) = typeOf a <| empty
  typeReps (Right _) = empty

type UTxO v = Abstract.UTxO (TxId v)

type TxWits v = Abstract.TxWits (TxId v)

type Tx v = Abstract.Tx (TxId v)

type TxIn v = Abstract.TxIn (TxId v)

type Wit v = Abstract.Wit (TxId v)


elaborateUTxOEnv :: Abstract.UTxOEnv txid -> Concrete.UTxO.Environment
elaborateUTxOEnv _abstractEnv = Concrete.UTxO.Environment
  { Concrete.UTxO.protocolMagic      = Dummy.aProtocolMagic
  , Concrete.UTxO.protocolParameters = dummyProtocolParameters
    { Concrete.ppTxFeePolicy =
      Concrete.TxFeePolicyTxSizeLinear $ Concrete.TxSizeLinear
        (Concrete.mkKnownLovelace @0)
        (Concrete.mkKnownLovelace @0)
    }
  }

elaborateUTxO
  :: (Concrete.TxOut -> id -> Concrete.TxId)
  -> Abstract.UTxO id
  -> Concrete.UTxO
elaborateUTxO elaborateTxId =
  Concrete.UTxO.fromList
    . fmap (elaborateUTxOEntry elaborateTxId)
    . M.toList
    . Abstract.unUTxO

elaborateUTxOEntry
  :: (Concrete.TxOut -> id -> Concrete.TxId)
  -> (Abstract.TxIn id, Abstract.TxOut)
  -> (Concrete.TxIn, Concrete.TxOut)
elaborateUTxOEntry elaborateTxId (abstractTxIn, abstractTxOut) =
  (concreteTxIn, concreteTxOut)
 where
  concreteTxOut = elaborateTxOut abstractTxOut
  concreteTxIn  = elaborateUTxOInput (elaborateTxId concreteTxOut) abstractTxIn

elaborateUTxOInput :: (id -> Concrete.TxId) -> Abstract.TxIn id -> Concrete.TxIn
elaborateUTxOInput elaborateTxId (Abstract.TxIn txId index) =
  Concrete.TxInUtxo (elaborateTxId txId) (fromIntegral index)

elaborateTxWitsBS
  :: Ord id
  => (Concrete.TxOut -> id -> Concrete.TxId)
  -> Abstract.UTxO id
  -> Abstract.TxWits id
  -> Concrete.ATxAux ByteString
elaborateTxWitsBS elaborateTxId utxo0 =
  annotateTxAux . elaborateTxWits elaborateTxId utxo0
 where
  annotateTxAux :: Concrete.TxAux -> Concrete.ATxAux ByteString
  annotateTxAux txAux =
    map (LBS.toStrict . CBOR.slice bytes)
      . fromRight (panic "elaborateTxWitsBS: Error decoding TxAux")
      $ CBOR.decodeFull bytes
    where bytes = CBOR.serialize txAux

elaborateTxWits
  :: Ord id
  => (Concrete.TxOut -> id -> Concrete.TxId)
  -> Abstract.UTxO id
  -> Abstract.TxWits id
  -> Concrete.TxAux
elaborateTxWits elaborateTxId utxo0 (Abstract.TxWits tx witnesses) =
  Concrete.mkTxAux concreteTx (elaborateWitnesses concreteTx witnesses)
  where concreteTx = elaborateTx elaborateTxId utxo0 tx

elaborateTx
  :: Ord id
  => (Concrete.TxOut -> id -> Concrete.TxId)
  -> Abstract.UTxO id
  -> Abstract.Tx id
  -> Concrete.Tx
elaborateTx elaborateTxId utxo0 (Abstract.Tx _ inputs outputs) =
  Concrete.UnsafeTx
    { Concrete.txInputs     = elaborateTxIns elaborateTxId utxo0 inputs
    , Concrete.txOutputs    = elaborateTxOuts outputs
    , Concrete.txAttributes = Concrete.mkAttributes ()
    }

elaborateWitnesses :: Concrete.Tx -> [Abstract.Wit id] -> Concrete.TxWitness
elaborateWitnesses concreteTx = V.fromList . fmap (elaborateWitness concreteTx)

elaborateWitness :: Concrete.Tx -> Abstract.Wit id -> Concrete.TxInWitness
elaborateWitness concreteTx (Abstract.Wit key _) = Concrete.VKWitness
  concreteVK
  signature
 where
  (concreteVK, concreteSK) = elaborateKeyPair $ vKeyPair key
  signature = sign Dummy.protocolMagicId SignTx concreteSK sigData
  sigData   = Concrete.TxSigData $ hash concreteTx

elaborateTxIns
  :: Ord id
  => (Concrete.TxOut -> id -> Concrete.TxId)
  -> Abstract.UTxO id
  -> [Abstract.TxIn id]
  -> NonEmpty Concrete.TxIn
elaborateTxIns elaborateTxId utxo0 =
  fromMaybe (panic "elaborateTxIns: Empty list of TxIns") . NE.nonEmpty . fmap
    (elaborateTxIn elaborateTxId utxo0)

elaborateTxIn
  :: Ord id
  => (Concrete.TxOut -> id -> Concrete.TxId)
  -> Abstract.UTxO id
  -> Abstract.TxIn id
  -> Concrete.TxIn
elaborateTxIn elaborateTxId (Abstract.UTxO utxo) abstractTxIn =
  fst $ elaborateUTxOEntry elaborateTxId (abstractTxIn, abstractTxOut)
 where
  abstractTxOut =
    fromMaybe (panic "elaborateTxIn: Missing output for input")
      $ M.lookup abstractTxIn utxo

elaborateTxOuts :: [Abstract.TxOut] -> NonEmpty Concrete.TxOut
elaborateTxOuts =
  fromMaybe
      (panic
        "elaborateTxOuts: Tried to elaborate an empty list of Abstract.TxOuts"
      )
    . NE.nonEmpty
    . fmap elaborateTxOut

elaborateTxOut :: Abstract.TxOut -> Concrete.TxOut
elaborateTxOut abstractTxOut = Concrete.TxOut
  { Concrete.txOutAddress = Concrete.makeVerKeyAddress
    (Concrete.makeNetworkMagic Dummy.protocolMagic)
    (elaborateVKey abstractVK)
  , Concrete.txOutValue   = lovelaceValue
  }
 where
  Abstract.TxOut (Abstract.Addr abstractVK) (Abstract.Lovelace value) =
    abstractTxOut

  lovelaceValue = case Concrete.mkLovelace (fromIntegral value) of
    Left  err -> panic $ sformat build err
    Right l   -> l
