{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Shelley.Spec.Ledger.STS.Chain
  ( CHAIN,
    ChainState (..),
    PredicateFailure (..),
    initialShelleyState,
    totalAda,
    totalAdaPots,
    chainChecks,
  )
where

import qualified Cardano.Crypto.VRF as VRF
import Cardano.Prelude
  ( MonadError (..),
    NFData,
    NoUnexpectedThunks,
    asks,
    unless,
  )
import Cardano.Slotting.Slot (WithOrigin (..))
import Control.State.Transition
  ( Embed (..),
    STS (..),
    TRC (..),
    TransitionRule,
    failBecause,
    judgmentContext,
    liftSTS,
    trans,
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shelley.Spec.Ledger.BaseTypes
  ( Globals (..),
    Nonce (..),
    Seed (..),
    ShelleyBase,
    StrictMaybe (..),
  )
import Shelley.Spec.Ledger.BlockChain
  ( BHBody,
    BHeader,
    Block (..),
    LastAppliedBlock (..),
    bHeaderSize,
    bhHash,
    bhbody,
    bheaderBlockNo,
    bheaderSlotNo,
    hBbsize,
    lastAppliedHash,
    prevHashToNonce,
  )
import Shelley.Spec.Ledger.Coin (Coin (..))
import Shelley.Spec.Ledger.Crypto (Crypto, VRF)
import Shelley.Spec.Ledger.Delegation.Certificates (PoolDistr (..))
import Shelley.Spec.Ledger.EpochBoundary (BlocksMade (..), emptySnapShots)
import Shelley.Spec.Ledger.Keys
  ( DSignable,
    GenDelegPair (..),
    GenDelegs (..),
    Hash,
    KESignable,
    KeyHash,
    KeyRole (..),
    coerceKeyRole,
  )
import Shelley.Spec.Ledger.LedgerState
  ( AccountState (..),
    DPState (..),
    DState (..),
    EpochState (..),
    LedgerState (..),
    NewEpochState (..),
    PState (..),
    UTxOState (..),
    emptyDState,
    emptyPPUPState,
    emptyPState,
    getGKeys,
    updateNES,
    _genDelegs,
  )
import Shelley.Spec.Ledger.OCert (OCertSignable)
import Shelley.Spec.Ledger.OverlaySchedule
import Shelley.Spec.Ledger.PParams
  ( PParams,
    ProtVer (..),
    _maxBBSize,
    _maxBHSize,
    _protocolVersion,
  )
import Shelley.Spec.Ledger.Rewards (emptyNonMyopic)
import Shelley.Spec.Ledger.STS.Bbody (BBODY, BbodyEnv (..), BbodyState (..))
import Shelley.Spec.Ledger.STS.Prtcl
  ( PRTCL,
    PrtclEnv (..),
    PrtclState (..),
    PrtlSeqFailure,
    prtlSeqChecks,
  )
import Shelley.Spec.Ledger.STS.Tick (TICK, TickEnv (..))
import Shelley.Spec.Ledger.STS.Tickn
import Shelley.Spec.Ledger.Slot (EpochNo)
import Shelley.Spec.Ledger.Tx (TxBody)
import Shelley.Spec.Ledger.UTxO (UTxO (..), balance)

data CHAIN crypto

data ChainState crypto = ChainState
  { chainNes :: NewEpochState crypto,
    chainOCertIssue :: Map.Map (KeyHash 'BlockIssuer crypto) Word64,
    chainEpochNonce :: Nonce,
    chainEvolvingNonce :: Nonce,
    chainCandidateNonce :: Nonce,
    chainPrevEpochNonce :: Nonce,
    chainLastAppliedBlock :: WithOrigin (LastAppliedBlock crypto)
  }
  deriving (Show, Eq, Generic)

instance NFData (ChainState crypto)

-- | Creates a valid initial chain state
initialShelleyState ::
  WithOrigin (LastAppliedBlock crypto) ->
  EpochNo ->
  UTxO crypto ->
  Coin ->
  Map (KeyHash 'Genesis crypto) (GenDelegPair crypto) ->
  OverlaySchedule crypto ->
  PParams ->
  Nonce ->
  ChainState crypto
initialShelleyState lab e utxo reserves genDelegs os pp initNonce =
  ChainState
    ( NewEpochState
        e
        (BlocksMade Map.empty)
        (BlocksMade Map.empty)
        ( EpochState
            (AccountState (Coin 0) reserves)
            emptySnapShots
            ( LedgerState
                ( UTxOState
                    utxo
                    (Coin 0)
                    (Coin 0)
                    emptyPPUPState
                )
                (DPState (emptyDState {_genDelegs = (GenDelegs genDelegs)}) emptyPState)
            )
            pp
            pp
            emptyNonMyopic
        )
        SNothing
        (PoolDistr Map.empty)
        os
    )
    cs
    initNonce
    initNonce
    initNonce
    NeutralNonce
    lab
  where
    cs = Map.fromList (fmap (\(GenDelegPair hk _) -> (coerceKeyRole hk, 0)) (Map.elems genDelegs))

instance
  ( Crypto crypto,
    DSignable crypto (OCertSignable crypto),
    DSignable crypto (Hash crypto (TxBody crypto)),
    KESignable crypto (BHBody crypto),
    VRF.Signable (VRF crypto) Seed
  ) =>
  STS (CHAIN crypto)
  where
  type
    State (CHAIN crypto) =
      ChainState crypto

  type
    Signal (CHAIN crypto) =
      Block crypto

  type Environment (CHAIN crypto) = ()
  type BaseM (CHAIN crypto) = ShelleyBase

  data PredicateFailure (CHAIN crypto)
    = HeaderSizeTooLargeCHAIN
        !Natural -- Header Size
        !Natural -- Max Header Size
    | BlockSizeTooLargeCHAIN
        !Natural -- Block Size
        !Natural -- Max Block Size
    | ObsoleteNodeCHAIN
        !Natural -- protocol version used
        !Natural -- max protocol version
    | BbodyFailure !(PredicateFailure (BBODY crypto)) -- Subtransition Failures
    | TickFailure !(PredicateFailure (TICK crypto)) -- Subtransition Failures
    | TicknFailure !(PredicateFailure TICKN) -- Subtransition Failures
    | PrtclFailure !(PredicateFailure (PRTCL crypto)) -- Subtransition Failures
    | PrtclSeqFailure !(PrtlSeqFailure crypto) -- Subtransition Failures
    deriving (Show, Eq, Generic)

  initialRules = []
  transitionRules = [chainTransition]

instance Crypto crypto => NoUnexpectedThunks (PredicateFailure (CHAIN crypto))

chainChecks ::
  (Crypto crypto, MonadError (PredicateFailure (CHAIN crypto)) m) =>
  Natural ->
  PParams ->
  BHeader crypto ->
  m ()
chainChecks maxpv pp bh = do
  unless (m <= maxpv) $ throwError (ObsoleteNodeCHAIN m maxpv)
  unless (fromIntegral (bHeaderSize bh) <= _maxBHSize pp) $
    throwError $
      HeaderSizeTooLargeCHAIN (fromIntegral $ bHeaderSize bh) (_maxBHSize pp)
  unless (hBbsize (bhbody bh) <= _maxBBSize pp) $
    throwError $
      BlockSizeTooLargeCHAIN (hBbsize (bhbody bh)) (_maxBBSize pp)
  where
    (ProtVer m _) = _protocolVersion pp

chainTransition ::
  forall crypto.
  ( Crypto crypto,
    DSignable crypto (OCertSignable crypto),
    DSignable crypto (Hash crypto (TxBody crypto)),
    KESignable crypto (BHBody crypto),
    VRF.Signable (VRF crypto) Seed
  ) =>
  TransitionRule (CHAIN crypto)
chainTransition =
  judgmentContext
    >>= \(TRC ((), ChainState nes cs eta0 etaV etaC etaH lab, block@(Block bh _))) -> do
      case prtlSeqChecks lab bh of
        Right () -> pure ()
        Left e -> failBecause $ PrtclSeqFailure e

      let NewEpochState _ _ _ (EpochState _ _ _ _ pp _) _ _ _ = nes

      maxpv <- liftSTS $ asks maxMajorPV
      case chainChecks maxpv pp bh of
        Right () -> pure ()
        Left e -> failBecause e

      let s = bheaderSlotNo $ bhbody bh
      let gkeys = getGKeys nes

      nes' <-
        trans @(TICK crypto) $ TRC (TickEnv gkeys, nes, s)

      let NewEpochState e1 _ _ _ _ _ _ = nes
          NewEpochState e2 _ bcur es _ _pd osched = nes'
      let EpochState account _ ls _ pp' _ = es
      let LedgerState _ (DPState (DState _ _ _ _ _genDelegs _) (PState _ _ _)) = ls

      let ph = lastAppliedHash lab
          etaPH = prevHashToNonce ph

      TicknState eta0' etaH' <-
        trans @TICKN $
          TRC
            ( TicknEnv pp' etaC etaPH,
              TicknState eta0 etaH,
              (e1 /= e2)
            )

      PrtclState cs' etaV' etaC' <-
        trans @(PRTCL crypto) $
          TRC
            ( PrtclEnv osched _pd _genDelegs eta0',
              PrtclState cs etaV etaC,
              bh
            )

      BbodyState ls' bcur' <-
        trans @(BBODY crypto) $
          TRC (BbodyEnv osched pp' account, BbodyState ls bcur, block)

      let nes'' = updateNES nes' bcur' ls'
          bhb = bhbody bh
          lab' =
            At $
              LastAppliedBlock
                (bheaderBlockNo bhb)
                (bheaderSlotNo bhb)
                (bhHash bh)

      pure $ ChainState nes'' cs' eta0' etaV' etaC' etaH' lab'

instance
  ( Crypto crypto,
    DSignable crypto (OCertSignable crypto),
    DSignable crypto (Hash crypto (TxBody crypto)),
    KESignable crypto (BHBody crypto),
    VRF.Signable (VRF crypto) Seed
  ) =>
  Embed (BBODY crypto) (CHAIN crypto)
  where
  wrapFailed = BbodyFailure

instance
  ( Crypto crypto,
    DSignable crypto (OCertSignable crypto),
    DSignable crypto (Hash crypto (TxBody crypto)),
    KESignable crypto (BHBody crypto),
    VRF.Signable (VRF crypto) Seed
  ) =>
  Embed TICKN (CHAIN crypto)
  where
  wrapFailed = TicknFailure

instance
  ( Crypto crypto,
    DSignable crypto (OCertSignable crypto),
    DSignable crypto (Hash crypto (TxBody crypto)),
    KESignable crypto (BHBody crypto),
    VRF.Signable (VRF crypto) Seed
  ) =>
  Embed (TICK crypto) (CHAIN crypto)
  where
  wrapFailed = TickFailure

instance
  ( Crypto crypto,
    DSignable crypto (OCertSignable crypto),
    DSignable crypto (Hash crypto (TxBody crypto)),
    KESignable crypto (BHBody crypto),
    VRF.Signable (VRF crypto) Seed
  ) =>
  Embed (PRTCL crypto) (CHAIN crypto)
  where
  wrapFailed = PrtclFailure

data AdaPots = AdaPots
  { treasuryAdaPot :: Coin,
    reservesAdaPot :: Coin,
    rewardsAdaPot :: Coin,
    utxoAdaPot :: Coin,
    depositsAdaPot :: Coin,
    feesAdaPot :: Coin
  }
  deriving (Show, Eq)

-- | Calculate the total ada pots in the chain state
totalAdaPots :: ChainState crypto -> AdaPots
totalAdaPots (ChainState nes _ _ _ _ _ _) =
  AdaPots
    { treasuryAdaPot = treasury_,
      reservesAdaPot = reserves_,
      rewardsAdaPot = rewards_,
      utxoAdaPot = circulation,
      depositsAdaPot = deposits,
      feesAdaPot = fees_
    }
  where
    (EpochState (AccountState treasury_ reserves_) _ ls _ _ _) = nesEs nes
    (UTxOState u deposits fees_ _) = _utxoState ls
    (DPState ds _) = _delegationState ls
    rewards_ = sum (Map.elems (_rewards ds))
    circulation = balance u

-- | Calculate the total ada in the chain state
totalAda :: ChainState crypto -> Coin
totalAda cs =
  treasuryAdaPot + reservesAdaPot + rewardsAdaPot + utxoAdaPot + depositsAdaPot + feesAdaPot
  where
    AdaPots
      { treasuryAdaPot,
        reservesAdaPot,
        rewardsAdaPot,
        utxoAdaPot,
        depositsAdaPot,
        feesAdaPot
      } = totalAdaPots cs
