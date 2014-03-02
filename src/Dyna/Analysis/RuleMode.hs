---------------------------------------------------------------------------
-- | Mode analysis of a rule
--
-- Takes input from "Dyna.Analysis.ANF"
--
-- XXX Gotta start somewhere.

-- Header material                                                      {{{
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wall #-}

module Dyna.Analysis.RuleMode {- (
    Mode(..), Moded(..), ModedNT, isBound, isFree,

    Crux, EvalCrux(..), UnifCrux(..),

    Action, Cost, Det(..),
    BackendPossible,

    planInitializer, planEachEval, planGroundBackchain,

    UpdateEvalMap, combineUpdatePlans,

    QueryEvalMap, combineQueryPlans,

    adornedQueries
) -} where

import           Control.Arrow (second)
import           Control.Lens ((^.))
import           Control.Monad
import           Control.Monad.Error.Class
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.Reader
import           Control.Monad.Identity
import qualified Data.ByteString            as B
import qualified Data.ByteString.Char8      as BC
import qualified Data.IntMap                as IM
import qualified Data.List                  as L
import qualified Data.Map                   as M
import qualified Data.Maybe                 as MA
import qualified Data.Set                   as S
-- import qualified Debug.Trace                as XT
import           Dyna.Analysis.ANF
import           Dyna.Analysis.ANFPretty
import           Dyna.Analysis.DOpAMine
import           Dyna.Analysis.Mode
import           Dyna.Analysis.Mode.Execution.Context
import           Dyna.Analysis.Mode.Execution.Functions
import           Dyna.Analysis.QueryProcTable
import           Dyna.Term.TTerm
import           Dyna.Term.Normalized
-- import           Dyna.Term.SurfaceSyntax
import           Dyna.Main.Exception
import           Dyna.XXX.DataUtils(argmin,mapInOrCons,mapMinRepView)
import           Dyna.XXX.MonadContext
-- import           Dyna.XXX.TrifectaTest
import           Text.PrettyPrint.Free

------------------------------------------------------------------------}}}
-- Bindings                                                             {{{

-- | For variables that are bound, what are they, and all that?
type BindChart = SIMCtx DFunct

type BindM m = EitherT UnifFail (SIMCT m DFunct)

{-
varMode :: BindChart -> DVar -> DInst
varMode c v = maybe (error "BindChart miss") id $ M.lookup v c

modedVar :: BindChart -> DVar -> ModedVar
modedVar b x = case varMode b x of
                 MBound -> MB x
                 MFree  -> MF x

modedNT :: BindChart -> NTV -> ModedNT
modedNT b (NTVar  v)     = NTVar $ modedVar b v
modedNT _ (NTBase b)     = NTBase b
-}

------------------------------------------------------------------------}}}
-- Actions                                                              {{{

type Actions fbs = [DOpAMine fbs]

{-
mapMaybeModeCompat mis mo =
  MA.mapMaybe (\(is',o',d,f) -> do
                guard $    modeOf mo <= o'
                        && length mis == length is'
                        && and (zipWith (\x y -> modeOf x <= y) mis is')
                return (d,f))
-}

-- | Free, Ground, or Neither.  A rather simplistic take on unification.
--
-- XXX There is nothing good about this.
fgn :: forall a m k .
       (Monad m, Functor m,
        MCVT m k    ~ ENKRI DFunct (NIX DFunct) k, MCR m k,
        MCVT m DVar ~ VR DFunct (NIX DFunct) k, MCR m DVar)
    => DVar -> m a -> m a -> m a -> m a
fgn v cf cg cn = do
  ff <- liftM (iIsFree . nExpose) $ expandV v
  gf <- v `subVN` (nHide $ IUniv UShared)
  case (ff,gf) of
    (True ,True ) -> dynacPanicStr "Variable is both free and ground"
    (True ,False) -> cf
    (False,True ) -> cg
    (False,False) -> cn

type CruxSteps fbs =  SIMCtx DFunct
                   -> Crux DVar TBase
                   -> [Either UnifFail (Actions fbs, SIMCtx DFunct)]

type Possible fbs = (DVar -> Bool) -> CruxSteps fbs

possible :: forall fbs .
            QueryProcTable fbs          -- ^ Supported queries and their codegens
         -> Possible fbs
possible qpt lf ic cr =
  case cr of
    -- XXX This is going to be such a pile.  We really, really should have
    -- unification crank out a series of DOpAMine opcodes for us, but for
    -- the moment, since everything we do is either IFree or IUniv, just use
    -- iEq everywhere.
    --
    -- XXX Rescue the new planner from plan-nonground, when convenient.

    -- XXX Actually, this is all worse than it should be.  The unification
    -- should be done before any case analysis.  Note that we also don't do
    -- any liveness analysis correctly!

    -- Assign or check
    Right (CAssign o i) -> flip runSIMCT ic $
        fgn o (runReaderT (unifyVU o) (UnifParams (lf o) False)
                >> return [ OPAsgn o (NTBase i) ])
              (return [ OPScop $ \chk -> OPBloc [ OPAsgn chk (NTBase i), OPCheq chk o] ])
              (throwError UFExDomain)

    -- XXX Eliminate in favor of a direct call to unification
    Right (CEquals o i) -> flip runSIMCT ic $
       fgn o (fgn i (throwError UFExDomain)
                    (runReaderT (unifyVV i o) (UnifParams (lf o || lf i) False)
                       >> return [ OPAsgn o (NTVar i) ])
                    (throwError UFExDomain))
             (fgn i (runReaderT (unifyVV i o) (UnifParams (lf o || lf i) False)
                       >> return [ OPAsgn i (NTVar o) ])
                    (return [ OPCheq o i ])
                    (throwError UFExDomain))
             (throwError UFExDomain)

    -- Structure building or unbuilding
    --
    -- XXX This ought to avail itself of unifyVF but doesn't.
    --
    -- XXX This makes up its own variables and should instead be using
    -- OPScop.  Maybe OPScop should take a number of variables to bind?
    Right (CStruct o is funct) -> flip runSIMCT ic $
      fgn o (mapM_ ensureBound is >> bind o >> return [ OPWrap o is funct ])
            buildPeel
            (throwError UFExDomain)
     where
      buildPeel = do
                   (is', mcis) <- zipWithM maybeCheck is newvars >>= return . unzip
                   let cis = MA.catMaybes mcis
                   mapM_ bind is
                   return ([ OPPeel is' o funct DetSemi ]
                           ++ map (uncurry OPCheq) cis)

      newvars = map (\n -> BC.pack $ "_chk_" ++ (show n)) [0::Int ..]

      maybeCheck v nv = fgn v (return (v,Nothing))
                              (return (nv, Just (nv,v)))
                              (throwError UFExDomain)

    -- Disequality constraints require that both inputs be brought to ground
    Right (CNotEqu o i) -> flip runSIMCT ic $
                           fgn o (throwError UFExDomain)
                                 (fgn i (throwError UFExDomain)
                                        (return [ OPCkne o i ])
                                        (throwError UFExDomain))
                                 (throwError UFExDomain)

    -- XXX Indirect evaluation is not yet supported
    Left (_, CEval _ _) -> []

    Left (_, CCall vo vis funct) ->
      let (qvo,qvis) = runIdentity $ flip runSIMCR ic $ do
                        _qvo  <- mkQV vo
                        _qvis <- mapM mkQV vis
                        return (_qvo,_qvis)
      in let qrs :: [QueryProcResult fbs] = tryQuery qpt (QPQ funct qvo qvis)
      in map (\(QPR d ri ais _) -> runIdentity $ flip runSIMCT ic $ do
                                    zipWithM_ specialize (vo:vis) (ri:ais)
                                    return [d])
             qrs
 where
     mkQV v = do
       vi <- expandV v
       return $ (v,vi)

     mo = nHide (IUniv UShared)
     unifyVU v = unifyUnaliasedNV mo v


     ensureBound v = fgn v (throwError UFExDomain)
                           (return ())
                           (throwError UFExDomain)
     bind x = runReaderT (unifyVU x) (UnifParams (lf x) False)

     specialize x i = runReaderT (unifyUnaliasedNV i x) (UnifParams (lf x) True)

------------------------------------------------------------------------}}}
-- Costing Plans                                                        {{{

type Cost = Double

-- XXX I don't understand why this heuristic works, but it seems to exclude
-- some of the... less intelligent plans.
simpleCost :: forall fbs . PartialPlan fbs -> Actions fbs -> Cost
simpleCost (PP { pp_score = osc, pp_plan = pfx }) act =
    2 * osc + (1 + loops pfx) * actCost act
 where
  actCost :: Actions fbs -> Cost
  actCost = sum . map stepCost

  stepCost :: DOpAMine fbs -> Double
  stepCost x = case x of
    OPAsgn _ _          -> 1
    OPAsnV _ _          -> 1
    OPAsnP _ _          -> 1
    OPCheq _ _          -> -1 -- Checks are issued with Assigns, so
                              -- counter-act the cost to encourage them
                              -- to be earlier in the plan.
    OPCkne _ _          -> 0
    OPPeel _ _ _ _      -> 0
    OPWrap _ _ _        -> 1  -- Upweight building due to side-effects
                              -- in the intern table
    OPIter o is _ d _   -> loopCost (length $ filter isFree (o:is)) d
    -- OPCall o is _ d     -> loopCost (length $ filter isFree (o:is)) d
    OPPrim _ _ d        -> loopCost 1 d
    OPIndr _ _          -> 100
    OPEmit _ _ _ _      -> 0
    OPBloc ds           -> actCost ds
    OPScop f            -> stepCost (f "")

  loopCost nf d = case d of
                    DetErroneous -> 0
                    DetFail      -> 0
                    Det          -> 0
                    DetSemi      -> 1
                    DetNon       -> 2 ** (fromIntegral (nf :: Int))
                                    - 1
                    DetMulti     -> 2


  loops = fromIntegral . length . filter isLoop

  isFree :: ModedVar -> Bool
  isFree v = iIsFree $ nExpose (v^.mv_mi)

  isLoop :: DOpAMine fbs -> Bool
  isLoop = (== DetNon) . detOfDop

------------------------------------------------------------------------}}}
-- Planning                                                             {{{

data PartialPlan fbs = PP { pp_cruxes         :: S.Set (Crux DVar TBase)
                          , pp_binds          :: BindChart
                          , pp_score          :: Cost
                          , pp_plan           :: Actions fbs
                          }
 deriving (Show)

pp_liveVars :: PartialPlan fbs -> S.Set DVar
pp_liveVars p = allCruxVars (pp_cruxes p)

-- XXX This certainly belongs elsewhere
renderPartialPlan :: (Actions t -> Doc e) -> PartialPlan t -> Doc e
renderPartialPlan rd (PP crs bs c pl) =
  vcat [ text "cost=" <> pretty c
       , text "pendingCruxes:" <//> indent 2 (renderCruxes crs)
       , text "context:" <//> indent 2 (pretty bs)
       , text "actions:" <//> indent 2 (rd pl)
       ]

-- XXX This does not have a way to signal UFNotReached back to its caller.
-- That is particularly disappointing since any unification producing that
-- means that there's certainly no plan for the whole rule.
stepPartialPlan :: CruxSteps fbs
                -- ^ Possible actions
                -> (PartialPlan fbs -> Actions fbs -> Cost)
                -- ^ Plan scoring function
                -> PartialPlan fbs
                -> Either (Cost, Actions fbs) [PartialPlan fbs]
stepPartialPlan poss score p =
  {- XT.trace ("SPP: cost=" ++ show (pp_score p) ++ " lencrx=" ++ show (S.size $ pp_cruxes p) ++ "\n"
             ++ "  " ++ show (pp_cruxes p) ++ "\n"
             ++ show (indent 2 $ pretty $ pp_binds p) ++ "\n"
           ) $ -}
  if S.null (pp_cruxes p)
   then Left $ (pp_score p, pp_plan p)
   else Right $
    let rc = pp_cruxes p
    -- XXX I am not sure this is right
    --
    --     force consideration of non-evaluation cruxes if
    --     any non-evaluation crux has a possible move.
    --     If a non-evaluation plan exists, commit to its
    --     cheapest choice as the only option here.
    --
    --     This prevents us from considering the multitude
    --     stupid plans that begin by evaluating when they
    --     don't have to.
    in case step (S.filter (not . cruxIsEval) rc) of
         [] -> step (S.filter cruxIsEval rc)
         xs -> [argmin (flip score []) xs]
 where
   step = S.fold (\crux ps ->
                  let pl = pp_plan p
                      plans = poss (pp_binds p) crux
                      rc' = S.delete crux (pp_cruxes p)
                  in
                     foldr (\st ps' -> either (const ps')
                                              (\(act,bc') -> PP rc' bc' (score p act) (pl++act) : ps')
                                              st)
                           ps
                           plans
                ) []

planner_ :: forall fbs .
            Possible fbs
         -> (PartialPlan fbs -> Actions fbs -> Cost)
                  -- ^ Scoring function
         -> (S.Set (Crux DVar TBase) -> DVar -> Bool)
                  -- ^ Hook for live variables
         -> S.Set (Crux DVar TBase)
                  -- ^ Cruxes to be planned over
         -> Maybe (EvalCrux DVar, DVar, DVar)
                  -- ^ Maybe the updated evaluation crux, the interned
                  -- representation of the term being updated, and
                  -- result variable.
         -> SIMCtx DVar
                  -- ^ Initial context (which must cover all the variables
                  -- in the given cruxes)
         -> Either [PartialPlan fbs] [(Cost, Actions fbs)]
                  -- ^ Either a list of all aborted partial plans (in the
                  -- case of no solution found) or all found plans and their
                  -- associated costs
planner_ st sc lf cr mic ictx = runAgenda
   $ PP { pp_cruxes = cr
        , pp_binds  = ctx'
        , pp_score  = 0
        , pp_plan   = ip
        }
 where
  runAgenda = goMF [] . (flip mioaPlan M.empty)
   where
    mioaPlan :: PartialPlan fbs
             -> M.Map Cost [PartialPlan fbs]
             -> M.Map Cost [PartialPlan fbs]
    -- XXX hack to make us more readily prefer more-completed plans.
    --
    -- This isn't done in the scoring computation to avoid having it
    -- be stored back into pp_score, which is used as part of the
    -- inside cost estimate.
    mioaPlan p@(PP{pp_score=psc,pp_cruxes=pcx}) = mapInOrCons (psc + 10 ** fromIntegral (S.size pcx)) p

    -- Accumulate failures @fs@ until some success happens, at which point
    -- we switch to recursing as
    goMF fs pq = maybe (Left fs) (go' goMFkf (\df pq' -> Right (df:go pq')))
               $ mapMinRepView pq
     where
      goMFkf Nothing  = goMF fs
      goMFkf (Just p) = goMF (p:fs)

    -- Cycle the priority queue as normal, discarding any failures.
    go :: M.Map Cost [PartialPlan fbs]
       -> [(Cost, Actions fbs)]
    go pq = maybe [] (go' (\_ -> go) (\df -> (df :) . go))
          $ mapMinRepView pq

    -- The core agenda cycler; takes failure (@kf@) and success (@ks@)
    -- callbacks as well as a view of the priority queue that has picked
    -- a particular partial plan to consider and the remainder of the
    -- priority queue.
    go' :: (Maybe (PartialPlan fbs) -> M.Map Cost [PartialPlan fbs] -> x)
        -> ((Cost,Actions fbs) -> M.Map Cost [PartialPlan fbs] -> x)
        -> (PartialPlan fbs, M.Map Cost [PartialPlan fbs])
        -> x
    go' kf ks (p, pq') = case stepPartialPlan (st (lf cr)) sc p of
                           Right []  -> kf (Just p) pq'
                           Left df   -> ks df pq'
                           Right ps' -> kf Nothing (foldr mioaPlan pq' ps')

  ctx' = either (const $ dynacPanicStr "Unable to bind input variable")
                snd
              $ runIdentity
              $ flip runSIMCT ictx
              $ flip runReaderT (UnifParams True False)
                (mapM_ (unifyUnaliasedNV (nHide $ IUniv UShared)) bis)

  -- XREF:INITPLAN
  (ip,bis) = case mic of
              Nothing -> ([],[])
              Just (CCall o is f, hi, ho) -> ( [ OPPeel is hi f DetSemi
                                                 , OPAsgn o (NTVar ho)]
                                              , o:is)
              Just (CEval o i, hi, ho) -> ( [ OPAsgn i (NTVar hi)
                                              , OPAsgn o (NTVar ho)]
                                            , [o,i] )

-- | Pick the best plan, but stop the planner from going off the rails by
-- considering at most a constant number of plans.
--
-- XXX This is probably not the right idea
bestPlan :: Either e [(Cost, a)] -> Either e (Cost, a)
bestPlan = fmap go
 where
  go []          = dynacPanic "Planner claimed success with no plans!"
  go plans@(_:_) = argmin fst (take 1000 plans)

-- | Add the last Emit verb to a string of actions from the planner.
--
-- XXX This is certainly the wrong answer for a number of reasons, not the
-- least of which is that it adds all variables to the identification set,
-- when really we just want the nondeterministic set.
finalizePlan :: Rule -> Actions fbs -> Actions fbs
finalizePlan r d = d ++ [OPEmit (r_head r) (r_result r) (r_index r)
                              $ S.toList $ allCruxVars (r_cruxes r)]

-- | Given a normalized form and, optionally, an initial crux,
--   saturate the graph and get all the plans for doing so.
--
-- XXX This has no idea what to do about non-range-restricted rules.
planUpdate :: QueryProcTable fbs
           -> Rule
           -> (PartialPlan fbs -> Actions fbs -> Cost)
           -> S.Set (Crux DVar TBase)                     -- ^ Normal form
           -> (EvalCrux DVar, DVar, DVar)
           -> SIMCtx DVar
           -> Either [PartialPlan fbs] (Cost, Actions fbs)
planUpdate qpt r sc anf mi ictx = fmap (second (finalizePlan r)) $
  bestPlan $ planner_ (possible qpt) sc (\cs v -> v `S.member` allCruxVars cs) anf (Just mi) ictx

planInitializer :: QueryProcTable fbs
                -> Rule
                -> Either [PartialPlan fbs] (Cost, Actions fbs)
planInitializer qpt r = fmap (second (finalizePlan r)) $
  let cruxes = r_cruxes r in
  bestPlan $ planner_ (possible qpt) simpleCost (\cs v -> v `S.member` allCruxVars cs) cruxes Nothing
             (allFreeSIMCtx $ S.toList $ allCruxVars cruxes)

-- | Given a particular crux and the remaining evaluation cruxes in a rule,
-- find all the \"later\" evaluations which will need special handling and
-- generate the cruxes necessary to prevent double-counting.
--
-- Consider a rule like @a += b(X) * b(Y).@  This desugars into an ANF with
-- two separate evaluations of @b(_)@.  This is problematic, since we will
-- plan each evaluation separately.  (Note that CSE won't help; we really do
-- mean to compute the cross-product in this case, but not double-count the
-- diagonal!)  The workaround here is to /order/ the evaluations, thus why
-- ANF gives a numeric identifier to each evaluation.
--
-- For replacement updates, the correct action is to @continue@ the
-- evaluation loop when an eariler (by the intrinsic ordering) iterator
-- within a update to a later (by the intrinsic ordering) evaluation
-- lands at the same position.
--
-- For delta updates, the ordering is used for the Blatz-Eisner update
-- propagation strategy -- new values are used in earlier evaluations (than
-- the one being updated) and old values are used in later evaluations.
--
-- When backward chaining, we get to ignore all of this, since we only
-- produce one backward chaining plan.
--
-- XXX It's unclear that this is really the right solution.  Maybe we should
-- be planning a single stream of instructions for each dfunctar, rather than
-- each evalution arc, but it's not quite clear that there's a nice
-- graphical story to be told in that case?
--
-- XXX What do we do in the CEval case??  We need to check every evaluation
-- inside a CEval update?
handleDoubles :: (Ord a, Ord b)
              => (Int -> a -> a -> a)
              -> (Int,EvalCrux a)
              -> S.Set (Int, EvalCrux a)
              -> S.Set (UnifCrux a b)
handleDoubles vc e r = S.fold (go e) S.empty r
 where
  go (en, CEval _ ei)      (qn, CEval _ qi)      s =
    if en > qn then s else S.insert (CNotEqu ei qi) s
  go (en, CCall eo eis ef) (qn, CEval qo qi)     s =
    if en > qn then s else let cv = vc 0 eo qo
                            in S.insert (CStruct cv eis ef)
                             $ S.insert (CNotEqu cv qi) s
  go (en, CEval eo ei)     (qn, CCall qo qis qf) s =
    if en > qn then s else let cv = vc 0 eo qo
                            in S.insert (CStruct cv qis qf)
                             $ S.insert (CNotEqu cv ei) s
  go (en, CCall eo eis ef) (qn, CCall qo qis qf) s =
    if en > qn || ef /= qf || length eis /= length qis
     then s
     else let ecv = vc 0 eo qo
              qcv = vc 1 eo qo
           in S.insert (CStruct ecv eis ef)
            $ S.insert (CStruct qcv qis qf)
            $ S.insert (CNotEqu ecv qcv) s

-- XXX Split into two functions, one which wraps handleDoubles and one which
-- feeds that to the planner.  The former will also be useful in dumping
-- more accurate ANF.
planEachEval :: QueryProcTable fbs
             -> (DFunctAr -> Bool)      -- ^ Indicator for constant function
             -> Rule
             -> [(Int, Either [PartialPlan fbs] (Cost, DVar, DVar, Actions fbs))]
planEachEval qpt cs r  =
  map (\(n,cr) ->
          let
              -- pending eval cruxes
              pecs = (S.delete cr $ S.fromList ecs)

              -- Additional unification cruxes introduced to prevent double
              -- counting
              antidup = S.map Right $ handleDoubles mkvar cr pecs

              -- cruxes to feed to the planner
              cruxes' = S.unions [ S.map Right $ r_ucruxes r
                                 , S.map Left  $ pecs
                                 , antidup
                                 ]

              -- Initialize the context to have variables for all the
              -- variables in cruxes' as well as the crux we're holding out.
              ictx = allFreeSIMCtx
                      $ S.toList
                      $ allCruxVars
                      $ S.insert (Left cr) cruxes'

          in (n, varify $ planUpdate qpt r simpleCost cruxes' (mic $ snd cr) ictx))
    -- Filter out non-constant evaluations
    --
    -- XXX This instead should look at the update modes of each evaluation
    --
    -- XXX Even if we do that, however, we need to be sure that retractable
    -- items have the right modes.
  $ MA.mapMaybe (\ec -> case ec of
                          (n, CCall _ is f) -> let fa = (f,length is)
                                               in if    not (cs fa)
                                                     -- && not (fa `S.member` bc)
                                                   then Just (n, ec)
                                                   else Nothing
                          (n, CEval _ _   ) -> Just (n,ec))

    -- Grab all evaluations
  $ ecs
 where
  mkvar n v1 v2 = B.concat ["chk",v1,"_",v2,"_",BC.pack $ show n]

  ecs = IM.toList $ r_ecruxes r

    -- XXX I am not terribly happy about these, but it'll do for the moment.
    --
    -- If the mechanism of feeding updates into these plans is to change,
    -- please ensure that XREF:INITPLAN also changes appropriately.
  varify = fmap $ \(c,a) -> (c,varHead,varVal,a)
  mic x = (x,varHead,varVal)
  varHead = "__i"
  varVal  = "__v"

data PBCError fbs = PBCWrongFunctor DFunct
                  | PBCWrongArity   Int
                  | PBCNoPlan [PartialPlan fbs]
                  | PBCBadRule
planBackchain :: QueryProcTable fbs
              -> (DFunct, QMode (NIX DFunct))
              -> Rule
              -> Either (PBCError fbs) ([DVar],(Cost, Actions fbs))
planBackchain qpt (f,qm) r =
  case extractHeadVars r of
    Nothing -> Left PBCBadRule
    Just (f',hvs) -> if f /= f'
                      then Left $ PBCWrongFunctor f'
                      else let (mri,mais) = unpackModeInputs qm
                           in if length mais /= length hvs
                               then Left $ PBCWrongArity (length hvs)
                               else go $ zip (r_result r:hvs) (mri:mais)
 where
  go l = let
             (lf,lb) = L.partition (iIsFree . nExpose . snd) l

             ctx1 = ctxFromBindings $
                    (map (\x -> (x,tf)) $ S.toList $ allCruxVars $ r_cruxes r)
                    ++ lf ++ lb
         in either (Left . PBCNoPlan)
                   (Right . (\x -> (map fst lb,x))
                          . fmap (finalizePlan r)) $
            bestPlan $ planner_ (possible qpt) simpleCost
                                (\cs v ->    (v == r_head   r)
                                          || (v == r_result r)
                                          || (v `S.member` allCruxVars cs))
                                (r_cruxes r) Nothing ctx1

  tf  = nHide IFree

------------------------------------------------------------------------}}}
-- Adorned Queries                                                      {{{

{-
-- XXX We really ought to be returning something about math, as well, but
-- as all that's handled specially up here...
adornedQueries :: Action fbs -> S.Set (DFunct,[Mode],Mode)
adornedQueries = go S.empty
 where
  go x []                   = x
  go x ((OPIter o is f _ _):as) =
    go (x `S.union` S.singleton (f, map modeOf is, modeOf o)) as
  go x (_:as)               = go x as
-}

------------------------------------------------------------------------}}}
-- Experimental Detritus                                                {{{

{-
filterNTs :: [NT v] -> [v]
filterNTs = MA.mapMaybe isNTVar
 where
  isNTVar (NTVar x) = Just x
  isNTVar _         = Nothing

ntMode :: BindChart -> NTV -> Mode
ntMode c (NTVar v) = varMode c v
ntMode _ (NTString _) = MBound
ntMode _ (NTNumeric _) = MBound
-}

{-
planEachEval_ hi v (Rule { r_anf = anf })  =
  map (\(c,fa) -> (fa, plan_ possible simpleCost anf $ Just (c,hi,v)))
    $ MA.mapMaybe (\c -> case c of
                           CCall _ is f | not $ isMath f
                                         -> Just $ (c,(f,length is))
                           _             -> Nothing )
    $ eval_cruxes anf



testPlanRule x = planEachEval_ "HEAD" "VALUE" $ normRule (unsafeParse DP.drule x)

run = mapM_ (\(c,msp) -> do
                putStrLn $ show c
                case msp of
                  []  -> putStrLn "NO PLAN"
                  sps -> forM_ sps $ \(s,p) -> do
                                        putStrLn $ "\n\nSCORE: " ++ show s
                                        forM_ p (putStrLn . show)
                putStrLn "")
       . testPlanRule
-}

------------------------------------------------------------------------}}}
