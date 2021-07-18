-- {-# LANGUAGE KindSignatures #-}
-- {-# LANGUAGE TypeOperators #-}
-- {-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
-- {-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
module Numeric.AD.DelCont.Internal
  (rad1, rad2,
   rad1g, rad2g,
   op1ad, op2ad,
   op1Num, op2Num,
   op1, op2,
   AD, AD')
  where

import Control.Monad ((>=>))
import Control.Monad.ST (ST, runST)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Bifunctor (Bifunctor(..))
import Data.Foldable (Foldable(..))
import Data.Functor (void)
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef, modifySTRef')

-- transformers
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Cont (Cont, shift, reset, evalCont, ContT(..), shiftT, resetT, evalContT, runContT)
import Control.Monad.Trans.State (StateT, State, evalState, runState, modify, execStateT, evalStateT, runStateT, put)

import Prelude hiding (read)

-- | Dual numbers
data D a da = D a da deriving (Show, Functor)
instance Eq a => Eq (D a da) where
  D x _ == D y _ = x == y
instance Ord a => Ord (D a db) where
  compare (D x _) (D y _) = compare x y
instance Bifunctor D where
  bimap f g (D a b) = D (f a) (g b)

-- withX :: (a -> b) -> D a da -> D b da
-- withX = first
withD :: (da -> db) -> D a da -> D a db
withD = second

-- | Differentiable variable
--
-- A (safely) mutable reference to a dual number
type DVar s a da = STRef s (D a da)
-- | Introduce a fresh DVar
var :: a -> da -> ST s (DVar s a da)
var x dx = newSTRef (D x dx)

-- | Mutable references to dual numbers in the continuation monad
--
-- Here the @a@ and @da@ type parameters are respectively the /primal/ and /dual/ quantities tracked by the AD computation.
newtype AD s a da = AD { unAD :: forall x dx . ContT (DVar s x dx) (ST s) (DVar s a da) }
-- | Like 'AD' but the types of primal and dual coincide
type AD' s a = AD s a a

-- | Lift a unary operation
--
-- HOW DOES THIS WORK :
--
-- 1) Compute the function result and bind the function inputs to the adjoint updating function (the "pullback")
--
-- 2) Allocate a fresh STRef @rb@ with the function result and @zero@ adjoint part
--
-- 3) @rb@ is passed downstream as an argument to the continuation @k@, with the expectation that the STRef will be mutated
--
-- 4) Upon returning from the @k@ (bouncing from the boundary of @resetT@), the mutated STRef is read back in
--
-- 5) The adjoint part of the input variable is updated using @rb@ and the result of the continuation is returned.
op1 :: db -- ^ zero
    -> (da -> da -> da) -- ^ plus
    -> (a -> (b, db -> da)) -- ^ returns : (function result, pullback)
    -> ContT x (ST s) (DVar s a da)
    -> ContT x (ST s) (DVar s b db)
op1 zero plusa f ioa = do
  ra <- ioa
  (D xa _) <- lift $ readSTRef ra
  let (xb, g) = f xa -- 1)
  shiftT $ \ k -> lift $ do
    rb <- var xb zero -- 2)
    ry <- k rb -- 3)
    (D _ yd) <- readSTRef rb -- 4)
    modifySTRef' ra (withD (\rda0 -> rda0 `plusa` g yd)) -- 5)
    pure ry

-- | helper for constructing typeclass (e.g. Num, Semiring) instances.
--
-- Note : the type parameters are completely unconstrained.
op1ad :: db -- ^ zero
      -> (da -> da -> da) -- ^ plus
      -> (a -> (b, db -> da)) -- ^ returns : (function result, pullback)
      -> AD s a da
      -> AD s b db
op1ad z plusa f (AD ioa) = AD $ op1 z plusa f ioa

-- | helper for constructing Num instances (= op1ad specialized to Num)
op1Num :: (Num da, Num db) =>
          (a -> (b, db -> da))
       -> AD s a da
       -> AD s b db
op1Num = op1ad 0 (+)

-- | Lift a binary operation
--
-- See 'op1' for more info
op2 :: dc -- ^ zero
    -> (da -> da -> da) -- ^ plus
    -> (db -> db -> db) -- ^ plus
    -> (a -> b -> (c, dc -> da, dc -> db)) -- ^ returns : (function result, pullbacks)
    -> ContT x (ST s) (DVar s a da)
    -> ContT x (ST s) (DVar s b db)
    -> ContT x (ST s) (DVar s c dc)
op2 zero plusa plusb f ioa iob = do
  ra <- ioa
  rb <- iob
  (D xa _) <- lift $ readSTRef ra
  (D xb _) <- lift $ readSTRef rb
  let (xc, g, h) = f xa xb
  shiftT $ \ k -> lift $ do
    rc <- var xc zero
    ry <- k rc
    (D _ yd) <- readSTRef rc
    modifySTRef' ra (withD (\rda0 -> rda0 `plusa` g yd))
    modifySTRef' rb (withD (\rdb0 -> rdb0 `plusb` h yd))
    pure ry

-- | helper for constructing typeclass (e.g. Num, Semiring) instances
--
-- Note : the type parameters are completely unconstrained.
op2ad :: dc -- ^ zero
      -> (da -> da -> da) -- ^ plus
      -> (db -> db -> db) -- ^ plus
      -> (a -> b -> (c, dc -> da, dc -> db)) -- ^ returns : (function result, pullbacks)
      -> (AD s a da -> AD s b db -> AD s c dc)
op2ad z plusa plusb f (AD ioa) (AD iob) = AD $ op2 z plusa plusb f ioa iob

-- | helper for constructing Num instances (= op2ad specialized to Num)
op2Num :: (Num da, Num db, Num dc) =>
          (a -> b -> (c, dc -> da, dc -> db))
       -> AD s a da
       -> AD s b db
       -> AD s c dc
op2Num = op2ad 0 (+) (+)

-- | The Num methods can be read off their @backprop@ counterparts : https://hackage.haskell.org/package/backprop-0.2.6.4/docs/src/Numeric.Backprop.Op.html#%2A.
instance (Num a) => Num (AD s a a) where
  (+) = op2Num (\x y -> (x + y, id, id))
  (*) = op2Num (\x y -> (x*y, (y *), (x *)))
  fromInteger x = AD $ lift $ var (fromInteger x) 0

-- | Evaluate (forward mode) and differentiate (reverse mode) a unary function, without committing to a specific numeric typeclass
rad1g :: da -- ^ zero
      -> db -- ^ one
      -> (forall s . AD s a da -> AD s b db)
      -> a -- ^ function argument
      -> (b, da) -- ^ (result, adjoint)
rad1g zero one f x = runST $ do
  xr <- var x zero
  zr' <- evalContT $
    resetT $ do
      let
        z = f (AD (pure xr))
      zr <- unAD z
      lift $ modifySTRef' zr (withD (const one))
      pure zr
  (D z _) <- readSTRef zr'
  (D _ x_bar) <- readSTRef xr
  pure (z, x_bar)



-- | Evaluate (forward mode) and differentiate (reverse mode) a binary function, without committing to a specific numeric typeclass
rad2g :: da -- ^ zero
      -> db -- ^ zero
      -> dc -- ^ one
      -> (forall s . AD s a da -> AD s b db -> AD s c dc)
      -> a -> b
      -> (c, (da, db)) -- ^ (result, adjoints)
rad2g zeroa zerob one f x y = runST $ do
  xr <- var x zeroa
  yr <- var y zerob
  zr' <- evalContT $
    resetT $ do
      let
        z = f (AD (pure xr)) (AD (pure yr))
      zr <- unAD z
      lift $ modifySTRef' zr (withD (const one))
      pure zr
  (D z _) <- readSTRef zr'
  (D _ x_bar) <- readSTRef xr
  (D _ y_bar) <- readSTRef yr
  pure (z, (x_bar, y_bar))


-- | Evaluate (forward mode) and differentiate (reverse mode) a unary function
--
-- >>> rad1 (\x -> x * x) 1
-- (1, 2)
rad1 :: (Num a, Num b) =>
        (forall s . AD' s a -> AD' s b) -- ^ function to be differentiated
     -> a -- ^ function argument
     -> (b, a) -- ^ (result, adjoint)
rad1 = rad1g 0 1

-- | Evaluate (forward mode) and differentiate (reverse mode) a binary function
--
-- >>> rad2 (\x y -> x + y + y) 1 1
-- (1,2)
--
-- >>> rad2 (\x y -> (x + y) * x) 3 2
-- (15,(8,3))
rad2 :: (Num a, Num b, Num c) =>
        (forall s . AD' s a -> AD' s b -> AD' s c) -- ^ function to be differentiated
     -> a
     -> b
     -> (c, (a, b)) -- ^ (result, adjoints)
rad2 = rad2g 0 0 1




-- -- playground

-- -- | Dual numbers DD (alternative take, using a type family for the first variation)
-- data DD a = Dd a (Adj a)
-- class Diff a where type Adj a :: *
-- instance Diff Double where type Adj Double = Double


-- -- product type (simplified version of vinyl's Rec)
-- data Rec :: [*] -> * where
--   RNil :: Rec '[]
--   (:*) :: !a -> !(Rec as) -> Rec (a ': as)

-- data SDRec s as where
--   SDNil :: SDRec s '[]
--   (:&) :: DVar s a a -> !(SDRec s as) -> SDRec s (a ': as)
