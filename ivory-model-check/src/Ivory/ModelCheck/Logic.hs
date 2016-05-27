{-# LANGUAGE GADTs, KindSignatures, EmptyDataDecls, TypeOperators, EmptyCase #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts, MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies, FunctionalDependencies, UndecidableInstances #-}
{-# LANGUAGE RankNTypes, TemplateHaskell, QuasiQuotes, ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables, DataKinds, PartialTypeSignatures, NamedFieldPuns #-}

module Ivory.ModelCheck.Logic where

import Prelude ()
import Prelude.Compat hiding (exp)

import Data.Proxy
import Data.Bits
import Data.Typeable
import Data.Int
import Data.Word
import Data.List
import Numeric.Natural
import Data.Functor.Identity

import MonadLib
import MonadLib.Monads

import Data.Binding.Hobbits
import Data.Type.RList

import           Ivory.Language.Syntax.Type
import           Ivory.Language.Syntax.Concrete.Location
import           Ivory.Language.Syntax.Concrete.Pretty


----------------------------------------------------------------------
-- Helper definitions
----------------------------------------------------------------------

-- | FIXME: documentation
joinAListsM :: (Eq key, Monad m) => (val -> val -> m val) ->
              [(key, val)] -> [(key, val)] -> m [(key, val)]
joinAListsM _ [] alist2 = return alist2
joinAListsM join_f ((k, v1) : alist1) alist2 =
  case lookup k alist2 of
    Just v2 ->
      do v_ret <- join_f v1 v2
         alist_ret <-
           joinAListsM join_f alist1 (filter (\(k', _) -> k /= k') alist2)
         return $ (k, v_ret) : alist_ret

groupAList :: Eq key => [(key, val)] -> [(key, [val])]
groupAList = foldr insertHelper [] where
  insertHelper (k,v) ((k',vs):ksvs) =
    if k == k' then ((k',v:vs):ksvs) else (k',vs):(insertHelper (k,v) ksvs)
  insertHelper (k,v) [] = [(k,[v])]

-- Build a NuMatching instance for the unit type
instance NuMatching () where
  nuMatchingProof = error "nuMatching proof for ()"

instance Liftable () where
  mbLift _ = ()


----------------------------------------------------------------------
-- Utilities for type lists
----------------------------------------------------------------------

-- | A heterogeneous list containing one element of type @f a@ for each type @a@
-- in the given type list.
data MapList f (l :: [*]) where
  Nil :: MapList f '[]
  Cons :: f a -> MapList f l -> MapList f (a ': l)

-- | Get the first element of a 'MapList'
ml_first :: MapList f (a ': l) -> f a
ml_first (Cons x _) = x

-- | Get the second element of a 'MapList'
ml_second :: MapList f (a ': b ': l) -> f b
ml_second (Cons _ (Cons y _)) = y

-- | Get the third element of a 'MapList'
ml_third :: MapList f (a ': b ': c ': l) -> f c
ml_third (Cons _ (Cons _ (Cons z _))) = z

-- | Map a function over a 'MapList'
ml_map :: (forall x. f x -> g x) -> MapList f l -> MapList g l
ml_map f Nil = Nil
ml_map f (Cons x l) = Cons (f x) (ml_map f l)

-- | Proof that type @a@ is an element of the list @l@ of types
data ElemPf (l :: [*]) a where
  Elem_base :: ElemPf (a ': l) a
  Elem_cons :: ElemPf l b -> ElemPf (a ': l) b

-- Make the NuMatching instance for ElemPf
$(mkNuMatching [t| forall l a. ElemPf l a |])

-- Make the Liftable instance for ElemPf
instance Liftable (ElemPf l a) where
  mbLift [nuP| Elem_base |] = Elem_base
  mbLift [nuP| Elem_cons pf |] = Elem_cons $ mbLift pf

-- | Type class for building 'ElemPf's
class Elem (l :: [*]) a where
  elemPf :: ElemPf l a

instance Elem (a ': l) a where elemPf = Elem_base
instance Elem l b => Elem (a ': l) b where elemPf = Elem_cons elemPf

-- | Look up an element of a 'MapList' using an 'ElemPf'
ml_lookup :: MapList f l -> ElemPf l a -> f a
ml_lookup (Cons x _) Elem_base = x
ml_lookup (Cons _ l) (Elem_cons pf) = ml_lookup l pf

-- | Apply a function to a specific element of a 'MapList' given by an 'ElemPf'
ml_map1 :: (f a -> f a) -> MapList f l -> ElemPf l a -> MapList f l
ml_map1 f (Cons x l) Elem_base = Cons (f x) l
ml_map1 f (Cons x l) (Elem_cons pf) = Cons x $ ml_map1 f l pf


----------------------------------------------------------------------
-- Helper types used by our logic
----------------------------------------------------------------------

-- | Container type for literals
newtype Literal a = Literal { unLiteral :: a }
                  deriving (Eq)

-- | Dummy type for propositions
data Prop deriving Typeable

-- | Dummy type for predicate monads, i.e., set of program transitions
data PM (a :: *) deriving Typeable

-- | Untyped pointers = 'Natural's
newtype Ptr = Ptr { unPtr :: Natural } deriving (Typeable, Eq, Ord)

-- | A default pointer value
defaultPtr :: Ptr
defaultPtr = Ptr 0


----------------------------------------------------------------------
-- The literal types
----------------------------------------------------------------------

-- | A GADT for the /literal types/ in our logic, which are the base types that
-- are isomorphic to their Haskell counterparts
data LitType a where
  LitType_unit :: LitType ()
  -- ^ The unit type
  LitType_bool :: LitType Bool
  -- ^ The type of Booleans that can be computed; i.e., not the type of
  -- formulas. For formulas (e.g., that contain quantifiers), use 'Prop'.
  LitType_int :: LitType Integer
  -- ^ Our logic also has support for unbounded integers
  LitType_bits :: (Typeable a, Integral a, FiniteBits a) => LitType a
  -- ^ Any bit-vector type can be used as a literal type

-- | Typeclass for 'LitType'
class LitTypeable a where
  litTypeRep :: LitType a

instance LitTypeable () where litTypeRep = LitType_unit
instance LitTypeable Bool where litTypeRep = LitType_bool
instance LitTypeable Integer where litTypeRep = LitType_int
instance LitTypeable Word64 where litTypeRep = LitType_bits
--instance (Typeable a, FiniteBits a) => LitTypeable a where
--  litTypeRep = LitType_bits

-- Build a NuMatching instance for LitType, needed for Liftable
$(mkNuMatching [t| forall a. LitType a |])

-- Liftable instance, to lift LitTypes out of binding contexts
instance Liftable (LitType a) where
  mbLift [nuP| LitType_unit |] = LitType_unit
  mbLift [nuP| LitType_bool |] = LitType_bool
  mbLift [nuP| LitType_int |] = LitType_int
  mbLift [nuP| LitType_bits |] = LitType_bits

-- | Test if two 'LitType's are equal
litTypeEq :: LitType a -> LitType b -> Maybe (a :~: b)
litTypeEq LitType_unit LitType_unit = Just Refl
litTypeEq LitType_unit _ = Nothing
litTypeEq LitType_bool LitType_bool = Just Refl
litTypeEq LitType_bool _ = Nothing
litTypeEq LitType_int LitType_int = Just Refl
litTypeEq LitType_int _ = Nothing
litTypeEq LitType_bits LitType_bits = eqT
litTypeEq LitType_bits _ = Nothing


----------------------------------------------------------------------
-- The first-order types
----------------------------------------------------------------------

-- | A GADT for the /first-order types/ in our logic, which are the types that
-- are not function types or transition relations.
data L1Type a where
  L1Type_lit :: LitType a -> L1Type (Literal a)
  -- ^ The type @'Literal' a@ is a first-order type when @a@ is a literal type
  L1Type_ptr :: L1Type Ptr
  -- ^ The type of pointers, which are not literal types because, intuitively,
  -- we disallow pointer literals
  L1Type_prop :: L1Type Prop
  -- ^ The type of formulas that may or may not be decidable; e.g., formulas
  -- with quantifiers

-- | Typeclass for 'L1Type'
class L1Typeable a where
  l1typeRep :: L1Type a

instance LitTypeable a => L1Typeable (Literal a) where
  l1typeRep = L1Type_lit litTypeRep
instance L1Typeable Ptr where l1typeRep = L1Type_ptr
instance L1Typeable Prop where l1typeRep = L1Type_prop

-- Build a NuMatching instance for L1Type, needed for Liftable
$(mkNuMatching [t| forall a. L1Type a |])

-- Liftable instance, to lift L1Types out of binding contexts
instance Liftable (L1Type a) where
  mbLift [nuP| L1Type_lit ltp |] = L1Type_lit $ mbLift ltp
  mbLift [nuP| L1Type_ptr |] = L1Type_ptr
  mbLift [nuP| L1Type_prop |] = L1Type_prop

-- | Test if two 'L1Type's are equal
l1TypeEq :: L1Type a -> L1Type b -> Maybe (a :~: b)
l1TypeEq (L1Type_lit ltp1) (L1Type_lit ltp2) =
  case litTypeEq ltp1 ltp2 of
    Just Refl ->  Just Refl
    _ -> Nothing
l1TypeEq (L1Type_lit _) _ = Nothing
l1TypeEq L1Type_ptr L1Type_ptr = Just Refl
l1TypeEq L1Type_ptr _ = Nothing
l1TypeEq L1Type_prop L1Type_prop = Just Refl
l1TypeEq L1Type_prop _ = Nothing

-- | "Proof" that there is no element of the type @'L1Type' (a -> b)@
no_functional_l1type :: L1Type (a -> b) -> c
no_functional_l1type l1tp = case l1tp of { }

-- | "Proof" that there is no element of the type @'L1Type' (PM a)@
no_pm_l1type :: L1Type (PM a) -> b
no_pm_l1type l1tp = case l1tp of { }


----------------------------------------------------------------------
-- The types of our logic
----------------------------------------------------------------------

-- | A GADT for the types allowed in our logic
data LType (a :: *) where
  LType_base :: L1Type a -> LType a
  -- ^ Any first-order type is a type
  LType_fun :: LType a -> LType b -> LType (a -> b)
  -- ^ Function types
  LType_pm :: L1Type a -> LType (PM a)
  -- ^ The type of transition relations, using a predicate monad

-- | Typeclass for 'LType'
class LTypeable a where
  ltypeRep :: LType a

-- Leads to overlapping instances...
-- instance L1Typeable a => LTypeable a where ltypeRep = LType_base l1typeRep
instance LitTypeable a => LTypeable (Literal a) where
  ltypeRep = LType_base $ L1Type_lit litTypeRep
instance LTypeable Ptr where ltypeRep = LType_base $ l1typeRep
instance LTypeable Prop where ltypeRep = LType_base $ l1typeRep
instance L1Typeable a => LTypeable (PM a) where
  ltypeRep = LType_pm l1typeRep
instance (LTypeable a, LTypeable b) => LTypeable (a -> b) where
  ltypeRep = LType_fun ltypeRep ltypeRep

-- Build a NuMatching instance for LType, needed for Liftable
$(mkNuMatching [t| forall a. LType a |])

-- Liftable instance, to lift LTypes out of binding contexts
instance Liftable (LType a) where
  mbLift [nuP| LType_base l1tp |] = LType_base $ mbLift l1tp
  mbLift [nuP| LType_fun t1 t2 |] = LType_fun (mbLift t1) (mbLift t2)
  mbLift [nuP| LType_pm l1tp |] = LType_pm $ mbLift l1tp

-- | Test if two 'LType's are equal
ltypeEq :: LType a -> LType b -> Maybe (a :~: b)
ltypeEq (LType_base l1tp1) (LType_base l1tp2) =
  case l1TypeEq l1tp1 l1tp2 of
    Just Refl -> Just Refl
    _ -> Nothing
ltypeEq (LType_base _) _ = Nothing
ltypeEq (LType_fun t1 t1') (LType_fun t2 t2') =
  case (ltypeEq t1 t2, ltypeEq t1' t2') of
    (Just Refl, Just Refl) -> Just Refl
    _ -> Nothing
ltypeEq (LType_fun _ _) _ = Nothing
ltypeEq (LType_pm tp1) (LType_pm tp2) =
  case l1TypeEq tp1 tp2 of
    Just Refl -> Just Refl
    _ -> Nothing
ltypeEq (LType_pm _) _ = Nothing


----------------------------------------------------------------------
-- Extracting the argument and return types of a function type
----------------------------------------------------------------------

-- | Type family to add a list of types as arguments to a function return type
type family AddArrows (args :: [*]) (ret :: *) :: *
type instance AddArrows '[] ret = ret
type instance AddArrows (a ': args) ret = a -> AddArrows args ret

-- | Type family to extract the argument types from a function type. This is the
-- inverse of 'AddArrows', in that @'ArgTypes' ('AddArrows' args ret) = args@
-- and that @'AddArrows' ('ArgTypes' a) ('RetType' a) = a@ when all three of the
-- type functions involved are defined.
type family ArgTypes a :: [*]
type instance ArgTypes (Literal a) = '[]
type instance ArgTypes Ptr = '[]
type instance ArgTypes Prop = '[]
type instance ArgTypes (PM a) = '[]
type instance ArgTypes (a -> b) = a ': ArgTypes b

-- | Type family to extract the return type from a function type; see 'ArgTypes'
type family RetType a :: *
type instance RetType (Literal a) = (Literal a)
type instance RetType Ptr = Ptr
type instance RetType Prop = Prop
type instance RetType (PM a) = PM a
type instance RetType (a -> b) = RetType b

-- | "Proof" that @a = AddArrows args ret@
data LTypeArgs a args ret where
  LTypeArgs_base :: L1Type a -> LTypeArgs a '[] a
  LTypeArgs_pm :: L1Type a -> LTypeArgs (PM a) '[] (PM a)
  LTypeArgs_fun :: LType arg -> LTypeArgs a args ret ->
                   LTypeArgs (arg -> a) (arg ': args) ret

-- | Typeclass for generating 'LTypeArgs' proofs
class LTypeableArgs a args ret | a -> args ret , args ret -> a where
  ltypeArgsRep :: LTypeArgs a args ret

instance LitTypeable a => LTypeableArgs (Literal a) '[] (Literal a) where
  ltypeArgsRep = LTypeArgs_base l1typeRep
instance LTypeableArgs Ptr '[] Ptr where
  ltypeArgsRep = LTypeArgs_base l1typeRep
instance LTypeableArgs Prop '[] Prop where
  ltypeArgsRep = LTypeArgs_base l1typeRep
instance L1Typeable a => LTypeableArgs (PM a) '[] (PM a) where
  ltypeArgsRep = LTypeArgs_pm l1typeRep
instance (LTypeable arg, LTypeableArgs a args ret) =>
         LTypeableArgs (arg -> a) (arg ': args) ret where
  ltypeArgsRep = LTypeArgs_fun ltypeRep ltypeArgsRep

-- | Generate an 'LTypeArgs' proof for a given type @a@
mkLTypeArgs :: LType a -> LTypeArgs a (ArgTypes a) (RetType a)
mkLTypeArgs (LType_base l1tp@(L1Type_lit lit_tp)) = LTypeArgs_base l1tp
mkLTypeArgs (LType_base L1Type_prop) = LTypeArgs_base l1typeRep
mkLTypeArgs (LType_base L1Type_ptr) = LTypeArgs_base l1typeRep
mkLTypeArgs (LType_pm l1tp) = LTypeArgs_pm l1tp
mkLTypeArgs (LType_fun tp_a tp_b) =
  LTypeArgs_fun tp_a (mkLTypeArgs tp_b)

-- | Convert an @'LTypeArgs' a args ret@ to an @'LType' a@
ltypeArgsFullType :: LTypeArgs a args ret -> LType a
ltypeArgsFullType (LTypeArgs_base l1tp) = LType_base l1tp
ltypeArgsFullType (LTypeArgs_pm l1tp) = LType_pm l1tp
ltypeArgsFullType (LTypeArgs_fun tp tp_args) =
  LType_fun tp $ ltypeArgsFullType tp_args

-- | Convert an 'LTypeArgs' to an 'LType' for the return type
ltypeArgsRetType :: LTypeArgs a args ret -> LType ret
ltypeArgsRetType (LTypeArgs_base l1tp) = LType_base l1tp
ltypeArgsRetType (LTypeArgs_pm l1tp) = LType_pm l1tp
ltypeArgsRetType (LTypeArgs_fun _ tp_args) = ltypeArgsRetType tp_args

-- | Proof that the return type of an 'LTypeArgs' is never a function type
no_functional_type_args_ret :: LTypeArgs a args (b -> c) -> d
no_functional_type_args_ret (LTypeArgs_base l1tp) = no_functional_l1type l1tp
no_functional_type_args_ret (LTypeArgs_fun _ tp_args) =
  no_functional_type_args_ret tp_args

-- Build a NuMatching instance for LTypeArgs, needed for Liftable
$(mkNuMatching [t| forall a args ret. LTypeArgs a args ret |])

instance Liftable (LTypeArgs a args ret) where
  mbLift [nuP| LTypeArgs_base l1tp |] = LTypeArgs_base $ mbLift l1tp
  mbLift [nuP| LTypeArgs_pm l1tp |] = LTypeArgs_pm $ mbLift l1tp
  mbLift [nuP| LTypeArgs_fun tp tp_args |] =
    LTypeArgs_fun (mbLift tp) (mbLift tp_args)


----------------------------------------------------------------------
-- The types of functions over first-order types
----------------------------------------------------------------------

-- | Types for functions over first-order types
data L1FunType a where
  L1FunType_base :: L1Type a -> L1FunType a
  L1FunType_cons :: L1Type a -> L1FunType b -> L1FunType (a -> b)

-- | Typeclass for 'L1FunType'
class L1FunTypeable a where
  l1funTypeRep :: L1FunType a

instance LitTypeable a => L1FunTypeable (Literal a) where
  l1funTypeRep = L1FunType_base l1typeRep
instance L1FunTypeable Ptr where
  l1funTypeRep = L1FunType_base l1typeRep
instance L1FunTypeable Prop where
  l1funTypeRep = L1FunType_base l1typeRep
instance (L1Typeable a, L1FunTypeable b) => L1FunTypeable (a -> b) where
  l1funTypeRep = L1FunType_cons l1typeRep l1funTypeRep

-- Build a NuMatching instance for L1FunType, needed for Liftable
$(mkNuMatching [t| forall a. L1FunType a |])

-- Liftable instance, to lift L1FunTypes out of binding contexts
instance Liftable (L1FunType a) where
  mbLift [nuP| L1FunType_base ltp |] = L1FunType_base $ mbLift ltp
  mbLift [nuP| L1FunType_cons ltp t |] = L1FunType_cons (mbLift ltp) (mbLift t)

-- | Convert an 'L1FunType' to an 'LType'
funType_to_type :: L1FunType a -> LType a
funType_to_type (L1FunType_base l1tp) = LType_base l1tp
funType_to_type (L1FunType_cons l1tp t) =
  LType_fun (LType_base l1tp) (funType_to_type t)

-- | Get the 'L1Type's for the argument types of an 'L1FunType'
funType_arg_types :: L1FunType a -> MapList L1Type (ArgTypes a)
funType_arg_types (L1FunType_base l1tp@(L1Type_lit _)) = Nil
funType_arg_types (L1FunType_base l1tp@L1Type_ptr) = Nil
funType_arg_types (L1FunType_base l1tp@L1Type_prop) = Nil
funType_arg_types (L1FunType_cons l1tp ftp) =
  Cons l1tp (funType_arg_types ftp)

-- | Get the 'L1Type' for the output type of an 'L1FunType'
funType_ret_type :: L1FunType a -> L1Type (RetType a)
funType_ret_type (L1FunType_base l1tp@(L1Type_lit _)) = l1tp
funType_ret_type (L1FunType_base l1tp@L1Type_ptr) = l1tp
funType_ret_type (L1FunType_base l1tp@L1Type_prop) = l1tp
funType_ret_type (L1FunType_cons _ ftp) = funType_ret_type ftp


----------------------------------------------------------------------
-- Finite functinos
----------------------------------------------------------------------

-- | A finite function, i.e., a function that has the same value for all but
-- finitely many inputs
data FinFun a b = FinFun { finfunDef :: b, finfunMap :: [(a,b)] }

-- | Make a finite function with a given default value
mkFinFun :: b -> FinFun a b
mkFinFun def = FinFun { finfunDef = def, finfunMap = [] }

-- | Apply a 'FinFun'
applyFinFun :: Eq a => FinFun a b -> a -> b
applyFinFun f arg =
  case lookup arg (finfunMap f) of
    Just ret -> ret
    Nothing -> finfunDef f

-- | Update a 'FinFun'
updateFinFun :: Eq a => FinFun a b -> a -> b -> FinFun a b
updateFinFun f arg newval =
  FinFun { finfunDef = finfunDef f,
           finfunMap =
             (arg,newval):(deleteBy
                           (\p1 p2 -> fst p1 == fst p2)
                           (arg,newval)
                           (finfunMap f))}


----------------------------------------------------------------------
-- The memory model of our logic
----------------------------------------------------------------------

-- | Type class stating that @mm@ is a list of the types that are considered
-- storable, and also a list of default values for each of these types. Note
-- that, if type @a@ is in @mm@, then it is type @'Literal' a@ that is actually
-- storable. Additionally, the 'Ptr' is always storable, and so is not contained
-- in the @mm@ list.
class MemoryModel (mm :: [*]) where
  memoryDefaults :: MapList Literal mm
  memoryLitTypes :: MapList LitType mm

-- | An /array store/ represents a set of (infinite) arrays of some given type,
-- while a /literal array store/ is an array store for some 'Literal'
-- type. Array stores are represented as 'FinFun's that map 'Ptr' pointer
-- values, combined with 'Word64' indices, to the given type.
newtype LitArrayStore a =
  LitArrayStore { unLitArrayStore :: FinFun (Ptr, Literal Word64) (Literal a) }

-- | Build a default, empty 'LitArrayStore'
mkLitArrayStore :: Literal a -> LitArrayStore a
mkLitArrayStore = LitArrayStore . mkFinFun

-- | A memory is a collection of 'LitArrayStore's, one for each type in the
-- memory model, as well as an array store for 'Ptr's. The memory model is given
-- as a type-level list @mm@ of types @a@ such that @'Literal' a@ is considered
-- storable. Memories also associate a length with each 'Ptr', and additionally
-- track that last allocated 'Ptr' value: any 'Ptr' greater than the last
-- allocated one is not considered allcated, i.e., is an invalid pointer.
data Memory mm =
  Memory { memArrays :: MapList LitArrayStore mm,
           memPtrArray :: FinFun (Ptr, Literal Word64) Ptr,
           memLengths :: FinFun Ptr (Literal Word64),
           memLastAlloc :: Ptr }

-- | Build a default, empty 'Memory'
mkMemory :: MemoryModel mm => Memory mm
mkMemory =
  Memory { memArrays = ml_map mkLitArrayStore memoryDefaults,
           memPtrArray = mkFinFun defaultPtr,
           memLengths = mkFinFun (Literal 0),
           memLastAlloc = Ptr 0 }

-- | The read operations for 'Memory's
data ReadOp mm args ret where
  -- | Read the nth element of an array whose type is in @mm@
  ReadOp_array :: ElemPf mm a -> ReadOp mm '[ Ptr, Literal Word64 ] (Literal a)
  -- | Read the nth element of the 'Ptr' array
  ReadOp_ptr_array :: ReadOp mm '[ Ptr, Literal Word64 ] Ptr
  -- | Get the length of an array as a 'Word64'
  ReadOp_length :: ReadOp mm '[ Ptr ] (Literal Word64)
  -- | Get the last-allocated pointer
  ReadOp_last_alloc :: ReadOp mm '[] Ptr

-- | The update operations for 'Memory's
data UpdateOp mm args where
  -- | Update the nth element of a 'LitArrayStore' whose type is in @mm@
  UpdateOp_array :: ElemPf mm a ->
                    UpdateOp mm '[ Ptr, Literal Word64, Literal a ]
  -- | Update the nth element of the 'Ptr' array store
  UpdateOp_ptr_array :: UpdateOp mm '[ Ptr, Literal Word64, Ptr ]
  -- | Allocate a new array with a given length, whose type is either an element
  -- of @mm@, or is 'Nothing', which represents 'Ptr'.
  UpdateOp_alloc :: Maybe (ElemPf mm a) -> UpdateOp mm '[ Literal Word64 ]

-- | Get the 'LType' of a 'ReadOp'
readOpType :: MemoryModel mm => ReadOp mm args ret -> LType (AddArrows args (PM ret))
readOpType (ReadOp_array elem_pf) =
  LType_fun ltypeRep $ LType_fun ltypeRep $
  LType_pm $ L1Type_lit $ ml_lookup memoryLitTypes elem_pf
readOpType ReadOp_ptr_array = ltypeRep
readOpType ReadOp_length = ltypeRep
readOpType ReadOp_last_alloc = ltypeRep

-- | Get the 'LType' of an 'UpdateOp'
updateOpType :: MemoryModel mm => UpdateOp mm args ->
                LType (AddArrows args (PM (Literal ())))
updateOpType (UpdateOp_array elem_pf) =
  LType_fun ltypeRep $ LType_fun ltypeRep $
  LType_fun (LType_base $ L1Type_lit $ ml_lookup memoryLitTypes elem_pf)
  ltypeRep
updateOpType UpdateOp_ptr_array = ltypeRep
updateOpType (UpdateOp_alloc _) = ltypeRep

-- | Perform a read operation on a 'Memory'
readMemory :: ReadOp mm args ret -> Memory mm -> MapList Identity args -> ret
readMemory (ReadOp_array elem_pf) mem
           (Cons (Identity ptr) (Cons (Identity ix) _)) =
  applyFinFun
    (unLitArrayStore $ ml_lookup (memArrays mem) elem_pf)
    (ptr, ix)
readMemory ReadOp_ptr_array mem
           (Cons (Identity ptr) (Cons (Identity ix) _)) =
  applyFinFun (memPtrArray mem) (ptr, ix)
readMemory ReadOp_length mem (Cons (Identity ptr) _) =
  applyFinFun (memLengths mem) ptr
readMemory ReadOp_last_alloc mem _ = memLastAlloc mem

-- | Perform an update operation on a 'Memory'
updateMemory :: UpdateOp mm args -> Memory mm -> MapList Identity args ->
                Memory mm
updateMemory (UpdateOp_array elem_pf) mem
             (Cons (Identity ptr)
              (Cons (Identity ix) (Cons (Identity newval) _))) =
  mem
  { memArrays =
      ml_map1
        (\las -> LitArrayStore $
                 updateFinFun (unLitArrayStore las) (ptr, ix) newval)
        (memArrays mem)
        elem_pf
  }
updateMemory UpdateOp_ptr_array mem
             (Cons (Identity ptr)
              (Cons (Identity ix) (Cons (Identity newval) _))) =
  mem { memPtrArray = updateFinFun (memPtrArray mem) (ptr,ix) newval }
updateMemory (UpdateOp_alloc elem_pf) mem
             (Cons (Identity new_len) _) =
  let new_last_alloc = Ptr (unPtr (memLastAlloc mem) + 1) in
  mem
  {
    memLengths = updateFinFun (memLengths mem) new_last_alloc new_len,
    memLastAlloc = new_last_alloc
  }


----------------------------------------------------------------------
-- The built-in operations of our logic
----------------------------------------------------------------------

-- | Type class associating meta-data with @tag@ that is needed by our logic
class (MemoryModel (LStorables tag),
       Eq (LException tag)) => LExprTag tag where
  type LStorables tag :: [*]
  type LException tag :: *

-- | The unary arithmetic operations
data ArithOp1 = Op1_Abs | Op1_Signum | Op1_Neg | Op1_Complement

-- | The binary arithmetic operations
data ArithOp2
  = Op2_Add | Op2_Sub | Op2_Mult | Op2_Div | Op2_Mod | Op2_Rem
  | Op2_BitAnd | Op2_BitOr | Op2_BitXor

-- | The arithmetic comparison operations
data ArithCmp
  = OpCmp_EQ -- ^ Equality
  | OpCmp_LT -- ^ Less than
  | OpCmp_LE -- ^ Less than or equal to
    

-- | The operations / function symbols of our logic
data Op tag a where
  -- | Literals that are lifted from Haskell
  Op_Literal :: Liftable a => LitType a -> a -> Op tag (Literal a)

  -- * First-order operations on data

  -- | Unary arithmetic
  Op_arith1 :: LitType a -> ArithOp1 -> Op tag (Literal a -> Literal a)
  -- | Binary arithmetic
  Op_arith2 :: LitType a -> ArithOp2 ->
               Op tag (Literal a -> Literal a -> Literal a)
  -- | Coercion between types
  Op_coerce :: LitType a -> LitType b -> Op tag (Literal a -> Literal b)
  -- | Comparison operations
  Op_cmp :: LitType a -> ArithCmp ->
            Op tag (Literal a -> Literal a -> Literal Bool)

  -- | Bump a free pointer
  Op_next_ptr :: Op tag (Ptr -> Ptr)

  -- * Propositional operations
  -- | The true proposition
  Op_true :: Op tag Prop
  -- | The false proposition
  Op_false :: Op tag Prop
  -- | Logical and
  Op_and :: Op tag (Prop -> Prop -> Prop)
  -- | Logical or
  Op_or :: Op tag (Prop -> Prop -> Prop)
  -- | Logical negation
  Op_not :: Op tag (Prop -> Prop)
  -- | Equality at base type
  Op_eq :: L1Type a -> Op tag (a -> a -> Prop)
  -- | Lift a 'Bool' to a 'Prop'
  Op_istrue  :: Op tag (Literal Bool -> Prop)

  -- | Universal quantification
  Op_forall :: L1Type a -> Op tag ((a -> Prop) -> Prop)
  -- | Existential quantification
  Op_exists :: L1Type a -> Op tag ((a -> Prop) -> Prop)

  -- | Let-bindings, which are only allowed in propositions
  Op_let :: L1Type a -> Op tag (a -> (a -> Prop) -> Prop)

  -- * Predicate monad operations

  -- | Return in the predicate monad
  Op_returnP :: L1Type a -> Op tag (a -> PM a)
  -- | Bind in the predicate monad
  Op_bindP :: L1Type a -> L1Type b -> Op tag (PM a -> (a -> PM b) -> PM b)
  -- | Memory read operations
  Op_readP :: MemoryModel (LStorables tag) =>
              ReadOp (LStorables tag) args ret ->
              Op tag (AddArrows args (PM ret))
  -- | Memory update operations
  Op_updateP :: MemoryModel (LStorables tag) =>
                UpdateOp (LStorables tag) args ->
                Op tag (AddArrows args (PM (Literal ())))
  -- | Raise an exception in the predicate monad. The 'Nothing' exception
  -- represents an un-catchable error
  Op_raiseP :: Liftable (LException tag) => Maybe (LException tag) ->
               Op tag (PM (Literal ()))
  -- | Catch an exception
  Op_catchP :: (Eq (LException tag), Liftable (LException tag)) =>
               LException tag ->
               Op tag (PM (Literal ()) -> PM (Literal ()) -> PM (Literal ()))
  -- | Assumptions about the current execution
  Op_assumeP :: Op tag (Prop -> PM (Literal ()))
  -- | Special-purpose assumption of false: prunes out the current execution
  Op_falseP :: Op tag (PM (Literal ()))
  -- | Disjunctions
  Op_orP :: Eq (LException tag) =>
            Op tag (PM (Literal ()) -> PM (Literal ()) -> PM (Literal ()))

-- | Get the 'LType' for an 'Op'
opType :: Op tag a -> LType a
opType (Op_Literal lit_tp _) = LType_base $ L1Type_lit lit_tp
opType (Op_arith1 lit_tp _) =
  LType_fun (LType_base $ L1Type_lit lit_tp) (LType_base $ L1Type_lit lit_tp)
opType (Op_arith2 lit_tp _) =
  LType_fun (LType_base $ L1Type_lit lit_tp) $
  LType_fun (LType_base $ L1Type_lit lit_tp) (LType_base $ L1Type_lit lit_tp)
opType (Op_coerce lit_tp_from lit_tp_to) =
  LType_fun (LType_base $ L1Type_lit lit_tp_from)
  (LType_base $ L1Type_lit lit_tp_to)
opType (Op_cmp lit_tp _) =
  LType_fun (LType_base $ L1Type_lit lit_tp) $
  LType_fun (LType_base $ L1Type_lit lit_tp) ltypeRep
opType Op_next_ptr = ltypeRep
opType Op_true = ltypeRep
opType Op_false = ltypeRep
opType Op_and = ltypeRep
opType Op_or = ltypeRep
opType Op_not = ltypeRep
opType (Op_eq l1tp) =
  LType_fun (LType_base $ l1tp) $ LType_fun (LType_base $ l1tp) ltypeRep
opType Op_istrue = ltypeRep
opType (Op_forall l1tp) =
  LType_fun (LType_fun (LType_base l1tp) ltypeRep) ltypeRep
opType (Op_exists l1tp) =
  LType_fun (LType_fun (LType_base l1tp) ltypeRep) ltypeRep
opType (Op_let l1tp) =
  LType_fun (LType_base l1tp) $
  LType_fun (LType_fun (LType_base l1tp) ltypeRep) ltypeRep
opType (Op_returnP l1tp) =
  LType_fun (LType_base l1tp) (LType_pm l1tp)
opType (Op_bindP l1tp_a l1tp_b) =
  LType_fun (LType_pm l1tp_a) $
  LType_fun (LType_fun (LType_base l1tp_a) (LType_pm l1tp_b)) $
  LType_pm l1tp_b
opType (Op_readP read_op) = readOpType read_op
opType (Op_updateP update_op) = updateOpType update_op
opType (Op_raiseP _) = ltypeRep
opType (Op_catchP _) = ltypeRep
opType Op_assumeP = ltypeRep
opType Op_falseP = ltypeRep
opType Op_orP = ltypeRep

-- | Build an 'LTypeArgs' for the type arguments of an 'Op'
opTypeArgs :: Op tag a -> LTypeArgs a (ArgTypes a) (RetType a)
opTypeArgs op = mkLTypeArgs $ opType op

-- | Get the 'LType' for the return type of an 'Op'
opRetType :: Op tag a -> LType (RetType a)
opRetType op = ltypeArgsRetType $ opTypeArgs op

-- Build a NuMatching instances for Op and friends
$(mkNuMatching [t| ArithOp1 |])
$(mkNuMatching [t| ArithOp2 |])
$(mkNuMatching [t| ArithCmp |])
$(mkNuMatching [t| forall a. NuMatching a => Maybe a |])
$(mkNuMatching [t| forall mm args ret. ReadOp mm args ret |])
$(mkNuMatching [t| forall mm args. UpdateOp mm args |])
$(mkNuMatching [t| forall tag a. Op tag a |])

-- Build Liftable instances for Op and friends
instance Liftable ArithOp1 where
  mbLift [nuP| Op1_Abs |] = Op1_Abs
  mbLift [nuP| Op1_Signum |] = Op1_Signum
  mbLift [nuP| Op1_Neg |] = Op1_Neg
  mbLift [nuP| Op1_Complement |] = Op1_Complement
instance Liftable ArithOp2 where
  mbLift [nuP| Op2_Add |] = Op2_Add
  mbLift [nuP| Op2_Sub |] = Op2_Sub
  mbLift [nuP| Op2_Mult |] = Op2_Mult
  mbLift [nuP| Op2_Div |] = Op2_Div
  mbLift [nuP| Op2_Mod |] = Op2_Mod
  mbLift [nuP| Op2_Rem |] = Op2_Rem
  mbLift [nuP| Op2_BitAnd |] = Op2_BitAnd
  mbLift [nuP| Op2_BitOr |] = Op2_BitOr
  mbLift [nuP| Op2_BitXor |] = Op2_BitXor
instance Liftable ArithCmp where
  mbLift [nuP| OpCmp_EQ |] = OpCmp_EQ
  mbLift [nuP| OpCmp_LT |] = OpCmp_LT
  mbLift [nuP| OpCmp_LE |] = OpCmp_LE
instance Liftable (ReadOp mm args ret) where
  mbLift [nuP| ReadOp_array elem_pf |] = ReadOp_array $ mbLift elem_pf
  mbLift [nuP| ReadOp_length |] = ReadOp_length
  mbLift [nuP| ReadOp_last_alloc |] = ReadOp_last_alloc
instance Liftable (UpdateOp mm args) where
  mbLift [nuP| UpdateOp_array elem_pf |] = UpdateOp_array $ mbLift elem_pf
  mbLift [nuP| UpdateOp_alloc (Just elem_pf) |] =
    UpdateOp_alloc $ Just $ mbLift elem_pf
  mbLift [nuP| UpdateOp_alloc Nothing |] = UpdateOp_alloc Nothing
instance Liftable (Op tag a) where
  mbLift [nuP| Op_Literal ltp x |] = Op_Literal (mbLift ltp) (mbLift x)
  mbLift [nuP| Op_arith1 ltp aop |] = Op_arith1 (mbLift ltp) (mbLift aop)
  mbLift [nuP| Op_arith2 ltp aop |] = Op_arith2 (mbLift ltp) (mbLift aop)
  mbLift [nuP| Op_coerce ltp1 ltp2 |] = Op_coerce (mbLift ltp1) (mbLift ltp2)
  mbLift [nuP| Op_cmp ltp acmp |] = Op_cmp (mbLift ltp) (mbLift acmp)
  mbLift [nuP| Op_and |] = Op_and
  mbLift [nuP| Op_or |] = Op_or
  mbLift [nuP| Op_not |] = Op_not
  mbLift [nuP| Op_eq l1tp |] = Op_eq $ mbLift l1tp
  mbLift [nuP| Op_istrue |] = Op_istrue
  mbLift [nuP| Op_forall l1tp |] = Op_forall $ mbLift l1tp
  mbLift [nuP| Op_exists l1tp |] = Op_exists $ mbLift l1tp
  mbLift [nuP| Op_let tp |] = Op_let $ mbLift tp
  --mbLift [nuP| Op_LetRead read_op |] = Op_LetRead $ mbLift read_op
  mbLift [nuP| Op_returnP l1tp |] = Op_returnP $ mbLift l1tp
  mbLift [nuP| Op_bindP l1tp_a l1tp_b |] =
    Op_bindP (mbLift l1tp_a) (mbLift l1tp_b)
  mbLift [nuP| Op_readP read_op |] = Op_readP $ mbLift read_op
  mbLift [nuP| Op_updateP update_op |] = Op_updateP $ mbLift update_op
  mbLift [nuP| Op_assumeP |] = Op_assumeP
  mbLift [nuP| Op_falseP |] = Op_falseP
  mbLift [nuP| Op_raiseP (Just exc) |] = Op_raiseP $ Just $ mbLift exc
  mbLift [nuP| Op_raiseP Nothing |] = Op_raiseP Nothing
  mbLift [nuP| Op_catchP exc |] = Op_catchP $ mbLift exc
  mbLift [nuP| Op_orP |] = Op_orP


----------------------------------------------------------------------
-- The expressions of our logic
----------------------------------------------------------------------

-- | The expressions of our logic as a GADT. This is essentially the typed
-- lambda-calculus with function symbols. All expressions are in beta-eta-normal
-- form, which is enforced by restricting the expressions to only the
-- lambda-abstractions and the full applications of variables and function
-- symbols to all of their arguments.
data LExpr tag a where
  LLambda :: LType a -> Binding a (LExpr tag b) -> LExpr tag (a -> b)
  LOp :: Op tag a -> LExprs tag (ArgTypes a) -> LExpr tag (RetType a)
  LVar :: LTypeArgs a args ret -> Name a -> LExprs tag args -> LExpr tag ret

-- | Lists of 'LExpr's
data LExprs tag as where
  LExprs_nil :: LExprs tag '[]
  LExprs_cons :: LExpr tag a -> LExprs tag as -> LExprs tag (a ': as)

$(mkNuMatching [t| forall tag a. LExpr tag a |])
$(mkNuMatching [t| forall tag as. LExprs tag as |])

type LProp tag = LExpr tag Prop

-- | Get the 'LType' of an expression-in-binding
mbExprType :: Mb ctx (LExpr tag a) -> LType a
mbExprType [nuP| LLambda tp_a body |] =
  LType_fun (mbLift tp_a) $ mbExprType $ mbCombine body
mbExprType [nuP| LOp op _ |] = opRetType $ mbLift op
mbExprType [nuP| LVar tp_args _ _ |] = ltypeArgsRetType $ mbLift tp_args


----------------------------------------------------------------------
-- Building and manipulating expressions
----------------------------------------------------------------------

-- | Apply type function @f@ to the input and outputs of a function type, i.e.,
-- replace @a1 -> ... -> an -> b@ with @f a1 -> ... -> f an -> f b@.
type family ApplyToArgs (f :: * -> *) a :: *
type instance ApplyToArgs f (Literal a) = f (Literal a)
type instance ApplyToArgs f Ptr = f Ptr
type instance ApplyToArgs f Prop = f Prop
type instance ApplyToArgs f (PM a) = f (PM a)
type instance ApplyToArgs f (a -> b) = f a -> ApplyToArgs f b

-- | Curry a @'LExprs' tag args -> 'LExpr' tag ret@ function
curryLExprsFun :: LType a ->
                  (LExprs tag (ArgTypes a) -> LExpr tag (RetType a)) ->
                  ApplyToArgs (LExpr tag) a
curryLExprsFun (LType_base (L1Type_lit _)) f = f LExprs_nil
curryLExprsFun (LType_base L1Type_prop) f = f LExprs_nil
curryLExprsFun (LType_base L1Type_ptr) f = f LExprs_nil
curryLExprsFun (LType_pm l1tp) f = f LExprs_nil
curryLExprsFun (LType_fun _ tp_b) f =
  \e -> curryLExprsFun tp_b (\es -> f (LExprs_cons e es))

-- | Helper function for building expression functions from variables
mkVarTp :: Proxy tag -> LType a -> Name a -> ApplyToArgs (LExpr tag) a
mkVarTp (_ :: Proxy tag) tp n =
  curryLExprsFun tp (LVar (mkLTypeArgs tp) n :: LExprs tag _ -> _)

-- | Helper function for building expression functions from variables
mkVar :: LTypeable a => Proxy tag -> Name a -> ApplyToArgs (LExpr tag) a
mkVar proxy n = mkVarTp proxy ltypeRep n

-- | Helper function for building expression functions from 'Op's with an
-- explicit 'LType'
mkOp :: Op tag a -> ApplyToArgs (LExpr tag) a
mkOp op = curryLExprsFun (opType op) (LOp op)

-- | Helper function for building literal expressions
mkLiteralTp :: Liftable a => LitType a -> a -> LExpr tag (Literal a)
mkLiteralTp lit_tp a = LOp (Op_Literal lit_tp a) LExprs_nil

-- | Helper function for building literal expressions
mkLiteral :: (LitTypeable a, Liftable a) => a -> LExpr tag (Literal a)
mkLiteral a = mkLiteralTp litTypeRep a

-- | Helper function for building lambda-abstractions
mkLambda :: LTypeable a =>
            (ApplyToArgs (LExpr tag) a -> LExpr tag b) -> LExpr tag (a -> b)
mkLambda (f :: _ -> LExpr tag b) =
  LLambda ltypeRep $ nu $ \x -> f (mkVar (Proxy :: Proxy tag) x)

-- | Eta-expand a @'LExprs' tag args -> 'LExpr' tag ret@ function into an
-- expression with functional type
etaExpandLExprsFun :: LType a ->
                  (LExprs tag (ArgTypes a) -> LExpr tag (RetType a)) ->
                  LExpr tag a
etaExpandLExprsFun (LType_base (L1Type_lit _)) f = f LExprs_nil
etaExpandLExprsFun (LType_base L1Type_prop) f = f LExprs_nil
etaExpandLExprsFun (LType_base L1Type_ptr) f = f LExprs_nil
etaExpandLExprsFun (LType_pm l1tp) f = f LExprs_nil
etaExpandLExprsFun (LType_fun tp_a tp_b) f =
  LLambda tp_a $ nu $ \n ->
  etaExpandLExprsFun tp_b (\es -> f (LExprs_cons (mkVarExprTp tp_a n) es))

-- | Make a variable into an expression, rather than a function
mkVarExprTp :: LType a -> Name a -> LExpr tag a
mkVarExprTp tp n = etaExpandLExprsFun tp (LVar (mkLTypeArgs tp) n)

-- | Helper function for building lambda-abstractions
mkLambdaTp :: LType a -> (LExpr tag a -> LExpr tag b) ->
              LExpr tag (a -> b)
mkLambdaTp tp_a (f :: _ -> LExpr tag b) =
  LLambda tp_a $ nu $ \x -> f (mkVarExprTp tp_a x)

-- FIXME: this requires Op_let to have an arbitrary RHS type;
-- OR: we have to do arbitrary substitution...
{-
-- | Apply an 'LExpr' to another
(@@) :: LExpr tag (a -> b) -> LExpr tag a -> LExpr tag b
f@(LLambda tp body) @@ arg = LAppExpr $ LApp (LApp (LOp $ Op_let tp) arg) f
(LAppExpr app_expr) @@ arg = LAppExpr $ LApp app_expr arg
-}

-- | Match the body of a lambda-expression
matchLambda :: LExpr tag (a -> b) -> Binding a (LExpr tag b)
matchLambda (LLambda _ body) = body
matchLambda (LVar tp_args _ _) = no_functional_type_args_ret tp_args
matchLambda (LOp op _) = no_functional_type_args_ret $ opTypeArgs op

-- | Same as 'matchLambda', but on an expression inside a binding
mbMatchLambda :: Mb ctx (LExpr tag (a -> b)) -> Mb (ctx :> a) (LExpr tag b)
mbMatchLambda [nuP| LLambda _ body |] = mbCombine body
mbMatchLambda [nuP| LVar tp_args _ _ |] =
  no_functional_type_args_ret $ mbLift tp_args
mbMatchLambda [nuP| LOp op _ |] =
  no_functional_type_args_ret $ opTypeArgs $ mbLift op

-- Num instance allows us to use arithmetic operations to build expressions.
instance (LitTypeable a, Liftable a, Num a) =>
         Num (LExpr tag (Literal a)) where
  (+) = mkOp (Op_arith2 litTypeRep Op2_Add)
  (-) = mkOp (Op_arith2 litTypeRep Op2_Sub)
  (*) = mkOp (Op_arith2 litTypeRep Op2_Mult)
  abs = mkOp (Op_arith1 litTypeRep Op1_Abs)
  signum = mkOp (Op_arith1 litTypeRep Op1_Signum)
  fromInteger i = mkLiteral (fromInteger i)

-- | The true proposition
mkTrue :: LProp tag
mkTrue = mkOp Op_true

-- | The false proposition
mkFalse :: LProp tag
mkFalse = mkOp Op_false

-- | Negate a proposition (FIXME: make this "smart")
mkNot :: LProp tag -> LProp tag
mkNot = mkOp Op_not

-- | Build a conjunction (FIXME: make this "smart")
mkAnd :: [LProp tag] -> LProp tag
mkAnd = foldr (mkOp Op_and) mkTrue

-- | Build a disjunction (FIXME: make this "smart")
mkOr :: [LProp tag] -> LProp tag
mkOr = foldr (mkOp Op_or) mkFalse

-- | Build a universal quantifier into an 'LProp'
mkForall :: L1Type a -> (LExpr tag a -> LProp tag) -> LProp tag
mkForall l1tp body =
  mkOp (Op_forall l1tp) $ mkLambdaTp (LType_base l1tp) body

-- | Build a universal quantifier into an 'LProp'
mkExists :: L1Type a -> (LExpr tag a -> LProp tag) -> LProp tag
mkExists l1tp body =
  mkOp (Op_exists l1tp) $ mkLambdaTp (LType_base l1tp) body

-- | Build an equality at an arbitrary second-order type
mkEqTp :: L1FunType a -> ApplyToArgs (LExpr tag) a ->
          ApplyToArgs (LExpr tag) a -> LProp tag
mkEqTp (L1FunType_base l1tp@(L1Type_lit _)) e1 e2 =
  mkOp (Op_eq l1tp) e1 e2
mkEqTp (L1FunType_base l1tp@L1Type_ptr) e1 e2 =
  mkOp (Op_eq l1tp) e1 e2
mkEqTp (L1FunType_base l1tp@L1Type_prop) e1 e2 =
  mkOp (Op_eq l1tp) e1 e2
mkEqTp (L1FunType_cons l1tp_a tp_b) f1 f2 =
  mkForall l1tp_a $ \x -> mkEqTp tp_b (f1 x) (f2 x)

-- | Build an equality at a first-order type
mkEq1 :: L1Typeable a => LExpr tag a -> LExpr tag a -> LProp tag
mkEq1 e1 e2 =
  LOp (Op_eq l1typeRep) (LExprs_cons e1 $ LExprs_cons e2 $ LExprs_nil)

-- | Build an equality for two 'Name's, short-circuiting the equality for
-- syntactically identical names
mkNameEq :: Proxy tag -> L1FunType a -> Name a -> Name a -> LProp tag
mkNameEq proxy ftp n1 n2 =
  if n1 == n2 then mkTrue else
    mkEqTp ftp (mkVarTp proxy (funType_to_type ftp) n1)
    (mkVarTp proxy (funType_to_type ftp) n2)

----------------------------------------------------------------------
-- Eliminating expressions via expression algebras
----------------------------------------------------------------------

-- | Type class stating that @f@ commutes with the arrow type constructor
class CommutesWithArrow f where
  interpApply :: f (a -> b) -> f a -> f b
  interpLambda :: (f a -> f b) -> f (a -> b)

-- | An expression @f@-algebra shows how to convert any 'Op' of type @a@ to an
-- element of type @f a@. It also requires that @f@ commutes with arrow.
class CommutesWithArrow f => LExprAlgebra tag (f :: * -> *) where
  interpOp :: Op tag a -> f a

-- | Interpret an 'LExpr' to another functor @f@ using an @f@-algebra
interpExpr :: LExprAlgebra tag f =>
              MapRList f ctx -> Closed (Mb ctx (LExpr tag a)) -> f a
interpExpr ctx [clNuP| LLambda _ body |] =
  interpLambda $ \x ->
  interpExpr (ctx :>: x) (clApply $(mkClosed [| mbCombine |]) body)
interpExpr ctx [clNuP| LVar tp_args n args |] =
  case clApply $(mkClosed [| mbNameBoundP |]) n of
    [clP| Left memb |] ->
      interpExprsApply ctx (hlistLookup (unClosed memb) ctx)
      (mbLift $ unClosed tp_args) args
    [clP| Right closed_n |] -> noClosedNames closed_n
interpExpr ctx [clNuP| LOp mbcl_op args |] =
  let op = mbLift $ unClosed mbcl_op in
  interpExprsApply ctx (interpOp op) (opTypeArgs op) args

-- | Helper for 'interpExpr'
interpExprsApply :: LExprAlgebra tag f => MapRList f ctx ->
                    f a -> LTypeArgs a args ret ->
                    Closed (Mb ctx (LExprs tag args)) -> f ret
interpExprsApply ctx f (LTypeArgs_base l1tp) _ = f
interpExprsApply ctx f (LTypeArgs_pm l1tp) _ = f
interpExprsApply ctx f (LTypeArgs_fun tp tp_args) [clNuP| LExprs_cons e es |] =
  interpExprsApply ctx (interpApply f (interpExpr ctx e)) tp_args es

----------------------------------------------------------------------
-- Eliminating expressions via expression binding-algebras
----------------------------------------------------------------------

-- | Form the type @f (ctx :> a1 :> ... :> an) b@ for @a = a1 -> ... -> an -> b@
type family BindingApplyF (f :: RList * -> * -> *) (ctx :: RList *) a :: *
type instance BindingApplyF f ctx (Literal a) = f ctx (Literal a)
type instance BindingApplyF f ctx Ptr = f ctx Ptr
type instance BindingApplyF f ctx Prop = f ctx Prop
type instance BindingApplyF f ctx (PM a) = f ctx (PM a)
type instance BindingApplyF f ctx (a -> b) = BindingApplyF f (ctx :> a) b

-- | Helper for building a 'BindingApplyF' at a return type of an 'Op' or
-- variable. This is just the identity function, but it needs to examine the
-- 'LTypeArgs' to convince Haskell.
mkRetBindingApplyF :: LTypeArgs a args ret -> f ctx ret -> BindingApplyF f ctx ret
mkRetBindingApplyF (LTypeArgs_base (L1Type_lit _)) x = x
mkRetBindingApplyF (LTypeArgs_base L1Type_ptr) x = x
mkRetBindingApplyF (LTypeArgs_base L1Type_prop) x = x
mkRetBindingApplyF (LTypeArgs_pm _) x = x
mkRetBindingApplyF (LTypeArgs_fun _ tp_args) x =
  mkRetBindingApplyF tp_args x

-- | Helper for eliminated a 'BindingApplyF' at base type. This is just the
-- identity function, but it needs to examine the type to convince Haskell.
elimL1BindingApplyF :: L1Type a -> BindingApplyF f ctx a -> f ctx a
elimL1BindingApplyF (L1Type_lit _) x = x
elimL1BindingApplyF L1Type_ptr x = x
elimL1BindingApplyF L1Type_prop x = x

-- | The type associated with the type family 'BindingApplyF'
newtype BindingApply f ctx a =
  BindingApply { unBindingApply :: BindingApplyF f ctx a }

-- | Type-class for interpreting expressions using expression binding-algebras
class LBindingExprAlgebra tag (f :: RList * -> * -> *) where
  interpOpB :: Op tag a ->
               MapList (BindingApply f ctx) (ArgTypes a) ->
               f ctx (RetType a)
  interpVarB :: Proxy tag -> LTypeArgs a args ret -> Member ctx a ->
                MapList (BindingApply f ctx) args ->
                f ctx ret

-- | Interpret an expression using a binding-algebra
interpMbExprB :: LBindingExprAlgebra tag f => Proxy f ->
                 Closed (Mb ctx (LExpr tag a)) -> BindingApplyF f ctx a
interpMbExprB proxy [clNuP| LLambda _ body |] =
  interpMbExprB proxy $ clApply $(mkClosed [| mbCombine |]) body
interpMbExprB proxy [clNuP| LOp cl_mb_op args |] =
  let op = mbLift $ unClosed cl_mb_op in
  mkRetBindingApplyF (opTypeArgs op) $
  interpOpB op $ interpMbExprsB proxy args
interpMbExprB proxy ([clNuP| LVar cl_mb_tp_args n args |]
                     :: Closed (Mb _ (LExpr tag _))) =
  let tp_args = mbLift $ unClosed cl_mb_tp_args in
  case clApply $(mkClosed [| mbNameBoundP |]) n of
    [clP| Left memb |] ->
      mkRetBindingApplyF tp_args $
      interpVarB (Proxy :: Proxy tag) tp_args (unClosed memb) $
      interpMbExprsB proxy args
    [clP| Right closed_n |] -> noClosedNames closed_n

-- | Interpret a list of 'LExprs' using a binding-algebra
interpMbExprsB :: LBindingExprAlgebra tag f =>
                  Proxy f -> Closed (Mb ctx (LExprs tag args)) ->
                  MapList (BindingApply f ctx) args
interpMbExprsB proxy [clNuP| LExprs_nil |] = Nil
interpMbExprsB proxy [clNuP| LExprs_cons e es |] =
  Cons (BindingApply $ interpMbExprB proxy e) (interpMbExprsB proxy es)

-- | Top-level function for interpreting expressions via binding-algebras
interpExprB :: LBindingExprAlgebra tag f => Proxy f ->
               Closed (LExpr tag a) -> BindingApplyF f RNil a
interpExprB proxy e =
  interpMbExprB proxy $ clApply $(mkClosed [| emptyMb |]) e


----------------------------------------------------------------------
-- Annotated expressions
----------------------------------------------------------------------

-- | The type of expressions-in-context where every subterm of type @a@ in
-- binding context @ctx@ is annotated with a value of type @f ctx a@
data MbAnnotExpr (f :: RList * -> * -> *) tag (ctx :: RList *) a where
  MbAnnotExprFun :: MbAnnotExpr f tag (ctx :> a) b ->
                    MbAnnotExpr f tag ctx (a -> b)
  MbAnnotExprOp :: Op tag a ->
                   MapList (MbAnnotExpr f tag ctx) args ->
                   f ctx (RetType a) ->
                   MbAnnotExpr f tag ctx (RetType a)
  MbAnnotExprVar :: LTypeArgs a args ret -> Member ctx a ->
                    MapList (MbAnnotExpr f tag ctx) args ->
                    f ctx ret ->
                    MbAnnotExpr f tag ctx ret

-- | Extract the @f ctx a@ from an 'MbAnnotExpr'
elimMbAnnotExpr :: MbAnnotExpr f tag ctx a -> BindingApplyF f ctx a
elimMbAnnotExpr (MbAnnotExprFun annot_expr) =
  elimMbAnnotExpr annot_expr
elimMbAnnotExpr (MbAnnotExprOp op _ x) =
  mkRetBindingApplyF (opTypeArgs op) x
elimMbAnnotExpr (MbAnnotExprVar tp_args _ _ x) =
  mkRetBindingApplyF tp_args x

-- | Convert a @'BindingApplyF' ('MbAnnotExpr' f tag) ctx a@ to an
-- @'MbAnnotExpr' f tag ctx@
mkBindingMbAnnotExpr :: LType a -> BindingApplyF (MbAnnotExpr f tag) ctx a ->
                        MbAnnotExpr f tag ctx a
mkBindingMbAnnotExpr (LType_base l1tp) annot_expr =
  elimL1BindingApplyF l1tp annot_expr
mkBindingMbAnnotExpr (LType_pm l1tp) annot_expr = annot_expr
mkBindingMbAnnotExpr (LType_fun tp1 tp2) x =
  MbAnnotExprFun $ mkBindingMbAnnotExpr tp2 x

-- | Convert a list of @'BindingApply' ('MbAnnotExpr' f tag) ctx a@ to a list of
-- @'MbAnnotExpr' f tag ctx@
mkBindingMbAnnotExprs :: LTypeArgs a args ret ->
                         MapList (BindingApply (MbAnnotExpr f tag) ctx) args ->
                         MapList (MbAnnotExpr f tag ctx) args
mkBindingMbAnnotExprs (LTypeArgs_fun tp tp_args) (Cons (BindingApply arg) args) =
  Cons (mkBindingMbAnnotExpr tp arg) (mkBindingMbAnnotExprs tp_args args)
mkBindingMbAnnotExprs _ Nil = Nil

-- This instance lets us take any binding-algebra and use it to annotate an
-- expression, saving all the intermediate results at each subterm
instance LBindingExprAlgebra tag f =>
         LBindingExprAlgebra tag (MbAnnotExpr f tag) where
  interpOpB op binding_args =
    let tp_args = opTypeArgs op in
    let args = mkBindingMbAnnotExprs tp_args binding_args in
    MbAnnotExprOp op args $
    interpOpB op (ml_map (BindingApply . elimMbAnnotExpr) args)
  interpVarB proxy tp_args memb binding_args =
    let args = mkBindingMbAnnotExprs tp_args binding_args in
    MbAnnotExprVar tp_args memb args $
    interpVarB proxy tp_args memb $
    ml_map (BindingApply . elimMbAnnotExpr) args

-- | Top-level annotation function
annotateExpr :: (LBindingExprAlgebra tag f, LTypeable a) => Proxy f ->
                Closed (LExpr tag a) -> MbAnnotExpr f tag RNil a
annotateExpr (proxy :: Proxy f) (expr :: Closed (LExpr tag a)) =
  mkBindingMbAnnotExpr ltypeRep $
  interpExprB (Proxy :: Proxy (MbAnnotExpr f tag)) expr


{- FIXME: Update or remove the following stuff about contextual algebras

----------------------------------------------------------------------
-- Expression interpretations that use the context
----------------------------------------------------------------------

-- | A @'CtxExt' ctx1 ctx2@ is a proof that @ctx2@ is an /extension/ of @ctx1@,
-- meaning that the former is the result of inserting zero or more types into
-- the latter, preserving the order of the remaining types.
data CtxExt ctx1 ctx2 where
  CtxExt_nil :: CtxExt RNil RNil
  -- ^ Proof that the empty context extends the empty context
  CtxExt_cons :: CtxExt ctx1 ctx2 -> CtxExt (ctx1 :> a) (ctx2 :> a)
  -- ^ Proof that context extension is preserved by adding a type to both sides
  CtxExt_insert :: CtxExt ctx1 ctx2 -> CtxExt ctx1 (ctx2 :> a)
  -- ^ Proof step that inserts a type into the extended context

-- | Build a proof that any context is an extension of itself from a proof that
-- that context is an extension of some other context
ctxExtRefl_right :: CtxExt ctx1 ctx2 -> CtxExt ctx2 ctx2
ctxExtRefl_right CtxExt_nil = CtxExt_nil
ctxExtRefl_right (CtxExt_cons ext) = CtxExt_cons $ ctxExtRefl_right ext
ctxExtRefl_right (CtxExt_insert ext) = CtxExt_cons $ ctxExtRefl_right ext

-- | The type of some 'CtxExt' proof for an extension of a given context, i.e.,
-- existential quantification over the second type argument of 'CtxExt'
data SomeCtxExt ctx1 where
  SomeCtxExt :: CtxExt ctx1 ctx2 -> SomeCtxExt ctx1

-- | Take a 'CtxExt' proof that @ctx1 :> a@ is extended by @ctx2@ and prove that
-- @ctx1@ itself is extended by @ctx2@
ctxExtSnocLeft :: CtxExt (ctx1 :> a) ctx2 -> CtxExt ctx1 ctx2
ctxExtSnocLeft (CtxExt_cons ctx_ext) = CtxExt_insert ctx_ext
ctxExtSnocLeft (CtxExt_insert ctx_ext) = CtxExt_insert $ ctxExtSnocLeft ctx_ext

-- | Map a 'Member' proof to an extended context
ctxExtMember :: CtxExt ctx1 ctx2 -> Member ctx1 a -> Member ctx2 a
ctxExtMember CtxExt_nil memb = memb -- Technically, this is impossible...
ctxExtMember (CtxExt_insert ext) memb = Member_Step $ ctxExtMember ext memb
ctxExtMember (CtxExt_cons ext) Member_Base = Member_Base
ctxExtMember (CtxExt_cons ext) (Member_Step memb) =
  Member_Step $ ctxExtMember ext memb

-- | Append two 'CtxExt' proofs
ctxExtAppend :: CtxExt ctx1 ctx2 -> CtxExt ctx2 ctx3 -> CtxExt ctx1 ctx3
ctxExtAppend CtxExt_nil ext2 = ext2
ctxExtAppend ext1 (CtxExt_insert ext2) = CtxExt_insert $ ctxExtAppend ext1 ext2
ctxExtAppend (CtxExt_cons ext1) (CtxExt_cons ext2) =
  CtxExt_cons $ ctxExtAppend ext1 ext2
ctxExtAppend (CtxExt_insert ext1) (CtxExt_cons ext2) =
  CtxExt_insert $ ctxExtAppend ext1 ext2

-- | The type of objects that are defined for all extensions of a given context
newtype InExtCtx f ctx a =
  InExtCtx { runInExtCtx :: forall ctx'. CtxExt ctx ctx' -> f ctx' a }

-- | Lower an 'InExtCtx' into a context extended by a single variable type
lowerInExtCtx1 :: InExtCtx f ctx b -> InExtCtx f (ctx :> a) b
lowerInExtCtx1 inExtCtx =
  InExtCtx $ \ctx_ext -> runInExtCtx inExtCtx (ctxExtSnocLeft ctx_ext)

-- | Use a 'CtxExt' proof to lower the context of an 'InExtCtx'
extendInExtCtx :: CtxExt ctx1 ctx2 -> InExtCtx f ctx1 a -> InExtCtx f ctx2 a
extendInExtCtx ctx_ext inExtCtx =
  InExtCtx $ \ctx_ext' -> runInExtCtx inExtCtx (ctxExtAppend ctx_ext ctx_ext')

-- | Map the body of an 'InExtCtx's with a context-polymorphic function
mapInExtCtx :: (forall ctx'. f ctx' a -> g ctx' b) ->
               InExtCtx f ctx a -> InExtCtx g ctx b
mapInExtCtx f inExtCtx =
  InExtCtx $ \ctx_ext -> f $ runInExtCtx inExtCtx ctx_ext

-- | Map the bodies of two 'InExtCtx's with a context-polymorphic function
map2InExtCtx :: (forall ctx'. f ctx' a -> g ctx' b -> h ctx' c) ->
                InExtCtx f ctx a -> InExtCtx g ctx b -> InExtCtx h ctx c
map2InExtCtx f inExtCtx1 inExtCtx2 =
  InExtCtx $ \ctx_ext ->
  f (runInExtCtx inExtCtx1 ctx_ext) (runInExtCtx inExtCtx2 ctx_ext)

-- | The result of interpreting a term of a given type in a given context, using
-- a given type function @f@ on contexts and result types
newtype InterpRes (f :: RList * -> * -> *) (ctx :: RList *) (a :: *) =
  InterpRes { unInterpRes :: InExtCtx (InterpResH f) ctx a }

-- | Helper type for 'InterpRes'
data InterpResH (f :: RList * -> * -> *) (ctx :: RList *) (a :: *) where
  InterpRes_base :: L1Type a -> f ctx a -> InterpResH f ctx a
  InterpRes_fun :: (InterpRes f ctx a -> InterpRes f ctx b) ->
                   InterpResH f ctx (a -> b)
  InterpRes_pm :: f ctx (PM a) -> InterpResH f ctx (PM a)

-- | Combine 'unInterpRes' with 'runInExtCtx' to apply an 'InterpRes' to a
-- 'CtxExt' proof
runInterpRes :: InterpRes f ctx a -> CtxExt ctx ctx' -> InterpResH f ctx' a
runInterpRes interpRes = runInExtCtx $ unInterpRes interpRes

-- | Lower an 'InterpRes' into a context with one more type
lowerInterpRes1 :: InterpRes f ctx b -> InterpRes f (ctx :> a) b
lowerInterpRes1 (InterpRes inExtCtx) = InterpRes $ lowerInExtCtx1 inExtCtx

-- | Use a 'CtxExt' proof to lower the context of an 'InterpRes'
extendInterpRes :: CtxExt ctx1 ctx2 -> InterpRes f ctx1 a -> InterpRes f ctx2 a
extendInterpRes ctx_ext (InterpRes inExtCtx) =
  InterpRes $ extendInExtCtx ctx_ext inExtCtx

-- | Build a functional 'InterpRes'
lambdaInterpRes :: (forall ctx'. CtxExt ctx ctx' ->
                    InterpRes f ctx' a -> InterpRes f ctx' b) ->
                   InterpRes f ctx (a -> b)
lambdaInterpRes f =
  InterpRes $ InExtCtx $ \ctx_ext -> InterpRes_fun $ f ctx_ext

-- | Extract the function from a functional 'InterpResH'
applyInterpResH :: InterpResH f ctx (a -> b) -> InterpRes f ctx a ->
                   InterpRes f ctx b
applyInterpResH (InterpRes_fun f) = f

-- | Extract the @f ctx a@ from an 'InterpResH f ctx a' when @a@ is first-order
extractInterpResH :: L1Type a -> InterpResH f ctx a -> f ctx a
extractInterpResH (L1Type_lit _) (InterpRes_base _ res) = res
extractInterpResH L1Type_ptr (InterpRes_base _ res) = res
extractInterpResH L1Type_prop (InterpRes_base _ res) = res

-- | Extract the @f ctx (PM a) @ from an 'InterpResH f ctx (PM a)'
extractInterpResH_pm :: InterpResH f ctx (PM a) -> f ctx (PM a)
extractInterpResH_pm (InterpRes_pm res) = res
extractInterpResH_pm (InterpRes_base _ res) =
  -- NOTE: this case is actually impossible, but we don't really care...
  res

-- | Apply a functional 'InterpRes'
applyInterpRes :: InterpRes f ctx (a -> b) -> InterpRes f ctx a ->
                  InterpRes f ctx b
applyInterpRes f arg =
  InterpRes $ InExtCtx $ \ctx_ext ->
  runInterpRes (applyInterpResH (runInterpRes f ctx_ext) $
                extendInterpRes ctx_ext arg) $
  ctxExtRefl_right ctx_ext

-- | Turn an 'InterpRes' function into an 'InterpRes' inside a binding, assuming
-- that we know how to make an object for variables of the bound type. Useful
-- for writing 'interpOpC' functions.
bindingInterpRes :: (forall ctx'. Member ctx' a -> InterpResH f ctx' a) ->
                    InterpRes f ctx (a -> b) -> InterpRes f (ctx :> a) b
bindingInterpRes mk_var f =
  applyInterpRes (lowerInterpRes1 f) $
  InterpRes $ InExtCtx $ \ctx_ext ->
  mk_var $ ctxExtMember ctx_ext Member_Base

-- | Specialized version of 'bindingInterpRes' for first-order types
binding1InterpRes :: L1Type a -> (forall ctx'. Member ctx' a -> f ctx' a) ->
                     InterpRes f ctx (a -> b) -> InterpRes f (ctx :> a) b
binding1InterpRes l1tp mk_var f =
  bindingInterpRes (InterpRes_base l1tp . mk_var) f

-- | A contextual expression @f@-algebra is like an expression @f@-algebra
-- except that @f@ can depend on the current variable context
class LCtxExprAlgebra tag (f :: RList * -> * -> *) where
  interpOpC :: Proxy ctx -> Op tag a -> InterpRes f ctx a

-- | Interpret an 'LExpr' using a contextual @f@-algebra. The 'LExpr' is a
-- closed expression in a given source context. The result is an 'InterpRes'
-- that is relative to a given destination context.
interpExprC :: LCtxExprAlgebra tag f =>
               MapRList (InterpRes f dest_ctx) ctx ->
               Closed (Mb ctx (LExpr tag a)) -> InterpRes f dest_ctx a
interpExprC ctx [clNuP| LLambda _ body |] =
  lambdaInterpRes $ \ctx_ext x ->
  interpExprC (mapMapRList (extendInterpRes ctx_ext) ctx :>: x) $
  clApply $(mkClosed [| mbCombine |]) body
interpExprC ctx [clNuP| LAppExpr e |] = interpAppExprC ctx e

-- | Interpret an 'LAppExpr' to another functor @f@ using an @f@-algebra
interpAppExprC :: LCtxExprAlgebra tag f =>
                  MapRList (InterpRes f dest_ctx) ctx ->
                  Closed (Mb ctx (LAppExpr tag a)) -> InterpRes f dest_ctx a
interpAppExprC ctx [clNuP| LVar _ n |] =
  case clApply $(mkClosed [| mbNameBoundP |]) n of
    [clP| Left memb |] -> hlistLookup (unClosed memb) ctx
    [clP| Right closed_n |] -> noClosedNames closed_n
interpAppExprC (ctx :: MapRList (InterpRes f dest_ctx) ctx) [clNuP| LOp clmb_op |] =
  let op = mbLift $ unClosed clmb_op in
  interpOpC (Proxy :: Proxy dest_ctx) op
interpAppExprC ctx [clNuP| LApp f arg |] =
  applyInterpRes (interpAppExprC ctx f) (interpExprC ctx arg)


----------------------------------------------------------------------
-- Functions to build contextual f-algebras
----------------------------------------------------------------------

-- | Form the type
--
-- > f (ctx :> a_1_1 :> ... :> a_m1_1) b1 -> ... ->
-- > f (ctx :> a_1_n :> ... :> a_mn_n) bn -> c
--
-- when @a@ has the form
--
-- > (a_1_1 -> ... -> a_m1_1 -> b1) -> ... ->
-- > (a_1_n -> ... -> a_mn_n -> bn) -> c
type family ApplyToArgsInCtx (f :: RList * -> * -> *) (ctx :: RList *) a :: *
type instance ApplyToArgsInCtx f ctx (Literal a) = f ctx (Literal a)
type instance ApplyToArgsInCtx f ctx Ptr = f ctx Ptr
type instance ApplyToArgsInCtx f ctx Prop = f ctx Prop
type instance ApplyToArgsInCtx f ctx (PM a) = f ctx (PM a)
type instance ApplyToArgsInCtx f ctx (a -> b) =
  BindingApplyF f ctx a -> ApplyToArgsInCtx f ctx b

-- | General form for building interpretations of 'Op's. FIXME: this has not
-- been written yet! FIXME: also, the variable-building function here should
-- really be part of the LCtxExprAlgebra class...
buildInterpRes :: LType a ->
                  (forall ctx' a. LType a -> Member ctx' a -> f ctx' a) ->
                  (forall ctx'. CtxExt ctx ctx' -> ApplyToArgsInCtx f ctx' a) ->
                  InterpRes f ctx a
buildInterpRes = error "write buildInterpRes!"

-- | Helper function to build interpretations for a first-order operations
buildFOInterpResH :: L1FunType a ->
                     (forall ctx'. CtxExt ctx ctx' -> ApplyToArgs (f ctx') a) ->
                     InterpRes f ctx a
buildFOInterpResH (L1FunType_base l1tp@(L1Type_lit _)) x =
  InterpRes $ InExtCtx $ InterpRes_base l1tp . x
buildFOInterpResH (L1FunType_base l1tp@L1Type_ptr) x =
  InterpRes $ InExtCtx $ InterpRes_base l1tp . x
buildFOInterpResH (L1FunType_base l1tp@L1Type_prop) x =
  InterpRes $ InExtCtx $ InterpRes_base l1tp . x
buildFOInterpResH (L1FunType_cons l1tp_a tp_b) f =
  lambdaInterpRes $ \ctx_ext x ->
  buildFOInterpResH tp_b $ \ctx_ext' ->
  f (ctxExtAppend ctx_ext ctx_ext') $
  extractInterpResH l1tp_a $ runInterpRes x ctx_ext'

-- | Helper function to build interpretations for a first-order operations
buildFOInterpRes :: L1FunTypeable a =>
                    (forall ctx'. CtxExt ctx ctx' -> ApplyToArgs (f ctx') a) ->
                    InterpRes f ctx a
buildFOInterpRes f = buildFOInterpResH l1funTypeRep f

-- | Helper function to build interpretations for quantifier operations, that
-- have type @ (a -> Prop) -> Prop@
buildQuantiferInterpRes :: L1Type a ->
                           (forall ctx'. Member ctx' a -> f ctx' a) ->
                           (forall ctx'. f (ctx' :> a) Prop -> f ctx' Prop) ->
                           InterpRes f ctx ((a -> Prop) -> Prop)
buildQuantiferInterpRes l1tp mk_var f =
  lambdaInterpRes $ \ctx_ext body_interp ->
  InterpRes $ InExtCtx $ \ctx_ext' ->
  InterpRes_base L1Type_prop $ f $
  extractInterpResH L1Type_prop $
  runInterpRes (binding1InterpRes l1tp mk_var body_interp) $
  CtxExt_cons ctx_ext'

-- | Helper function to build an interpretation for 'Op_bindP'
buildBindInterpRes :: L1Type a -> L1Type b ->
                      (forall ctx'. Member ctx' a -> f ctx' a) ->
                      (forall ctx'. f ctx' (PM a) -> f (ctx' :> a) (PM b) ->
                       f ctx' (PM b)) ->
                      InterpRes f ctx (PM a -> (a -> PM b) -> PM b)
buildBindInterpRes l1tp_a l1tp_b mk_var f =
  lambdaInterpRes $ \ctx_ext1 arg1 ->
  lambdaInterpRes $ \ctx_ext2 arg2 ->
  InterpRes $ InExtCtx $ \ctx_ext3 ->
  InterpRes_pm $
  f (extractInterpResH_pm $
     runInterpRes arg1 $ ctxExtAppend ctx_ext2 ctx_ext3) $
  extractInterpResH_pm $
  runInterpRes (binding1InterpRes l1tp_a mk_var arg2) $
  CtxExt_cons ctx_ext3

-}


----------------------------------------------------------------------
-- The symbolic representation of memory
----------------------------------------------------------------------

-- | The type of a function used in the 'symMemArrays' field
type SymMemArrayType a = Ptr -> Literal Word64 -> Literal a

-- | The type of a function used in the 'symMemPtrArray' field
type SymMemPtrArrayType = Ptr -> Literal Word64 -> Ptr -> Prop

-- | The symbolic representation of memory arrays of a given type
data SymMemName a = SymMemName (LitType a) (Name (SymMemArrayType a))

-- | The symbolic representation of a 'Memory'
data SymMemory tag =
  SymMemory
  {
    symMemArrays :: MapList SymMemName (LStorables tag),
    -- ^ One 'Name' for each storable type
    symMemPtrArray :: Name SymMemPtrArrayType,
    -- ^ A 'Name' for storing the 'Ptr' type
    symMemLengths :: Name (Ptr -> Literal Word64),
    -- ^ A 'Name' for the function containing the lengths of the various arrays
    symMemLastAlloc :: Name Ptr
    -- ^ A 'Name' for the last-allocated pointer value
  }

-- | The 'LType' of a function used in the 'symMemArrays' field
symMemArrayType :: LitType a -> LType (SymMemArrayType a)
symMemArrayType ltp =
  LType_fun (LType_base L1Type_ptr) $
  LType_fun (LType_base $ L1Type_lit LitType_bits) $
  LType_base $ L1Type_lit ltp

-- | The 'L1FunType' of a function used in the 'symMemArrays' field
symMemArrayFunType :: LitType a -> L1FunType (SymMemArrayType a)
symMemArrayFunType ltp =
  L1FunType_cons L1Type_ptr $ L1FunType_cons (L1Type_lit LitType_bits) $
  L1FunType_base $ L1Type_lit ltp

-- | Extract a typed expression for the 'symMemArrays' field of a 'SymMemory'
symMemArrayName :: ElemPf (LStorables tag) a -> SymMemory tag ->
                   Name (SymMemArrayType a)
symMemArrayName elem_pf mem =
  case ml_lookup (symMemArrays mem) elem_pf of
    SymMemName _ n -> n

-- | Make the proposition that two 'SymMemory's are equal
symMemEquals :: SymMemory tag -> SymMemory tag -> LProp tag
symMemEquals mem1 mem2 =
  mkAnd $
  memArraysEqual (symMemArrays mem1) (symMemArrays mem2) ++
  [mkNameEq Proxy l1funTypeRep (symMemPtrArray mem1) (symMemPtrArray mem2),
   mkNameEq Proxy l1funTypeRep (symMemLengths mem1) (symMemLengths mem2),
   mkNameEq Proxy l1funTypeRep (symMemLastAlloc mem1) (symMemLastAlloc mem2)]
  where
    memArraysEqual :: MapList SymMemName mm -> MapList SymMemName mm ->
                      [LProp tag]
    memArraysEqual Nil Nil = []
    memArraysEqual (Cons (SymMemName l1tp n1) as1) (Cons (SymMemName _ n2) as2) =
      mkNameEq Proxy (symMemArrayFunType l1tp) n1 n2 : memArraysEqual as1 as2


----------------------------------------------------------------------
-- A monad for fresh names
----------------------------------------------------------------------

data WithNames tag a where
  WithNoNames :: a -> WithNames tag a
  WithName :: LType a -> Maybe (LExpr tag a) -> Binding a (WithNames tag b) ->
              WithNames tag b

instance Functor (WithNames tag) where
  fmap f (WithNoNames a) = WithNoNames (f a)
  fmap f (WithName tp rhs body) = WithName tp rhs $ fmap (fmap f) body

instance Applicative (WithNames tag) where

instance Monad (WithNames tag) where
  return x = WithNoNames x
  (WithNoNames x) >>= f = f x
  (WithName tp rhs body) >>= f =
    WithName tp rhs $ fmap (\x -> x >>= f) body

class Monad m => NamesMonad tag m | m -> tag where
  nuM :: LType a -> Maybe (LExpr tag a) -> m (Name a)

instance NamesMonad tag (WithNames tag) where
  nuM tp rhs = WithName tp rhs $ nu WithNoNames

instance NamesMonad tag m => NamesMonad tag (StateT s m) where
  nuM tp rhs = lift $ nuM tp rhs

instance NamesMonad tag m => NamesMonad tag (ChoiceT m) where
  nuM tp rhs = lift $ nuM tp rhs

instance NamesMonad tag m => NamesMonad tag (ExceptionT exn m) where
  nuM tp rhs = lift $ nuM tp rhs


----------------------------------------------------------------------
-- Logic predicate monad
----------------------------------------------------------------------

type LogicPM tag =
  ExceptionT (Maybe (LException tag))
  (StateT (SymMemory tag, [LExpr tag Prop])
   (ChoiceT
    (WithNames tag)))

-- | Get the current 'SymMemory' in a 'LogicPM' computation
getMem :: LogicPM tag (SymMemory tag)
getMem = liftM fst get

-- | Set the current 'SymMemory' in a 'LogicPM' computation
setMem :: SymMemory tag -> LogicPM tag ()
setMem mem = sets_ (\(_,props) -> (mem,props))

-- | Prune out the current execution in a 'LogicPM' computation
falsePM :: LogicPM tag ()
falsePM = mzero

-- | Assume an 'LProp' in the current 'LogicPM' computation
assumePM :: LProp tag -> LogicPM tag ()
assumePM prop = sets_ $ \(mem, props) -> (mem, prop:props)

-- | Assume that @n@ is a valid name for use as a 'symMemPtrArray' field in a
-- 'SymMemory'. This means that (n ptr ix ptr') should only hold for at most one
-- ptr' value, for any given ptr and ix values.
assumePtrArrayName :: Name SymMemPtrArrayType -> LogicPM tag ()
assumePtrArrayName f =
  assumePM $ mkForall L1Type_ptr $ \p ->
  mkForall (L1Type_lit LitType_bits) $ \i ->
  mkForall L1Type_ptr $ \p1 ->
  mkForall L1Type_ptr $ \p2 ->
  mkOr [mkNot (mkVar Proxy f p i p1),
        mkNot (mkVar Proxy f p i p2),
        mkEq1 p1 p2]

-- | Perform a read operation in the current 'LogicPM' computation
readPM :: ReadOp (LStorables tag) args ret -> MapList (LExpr tag) args ->
          LogicPM tag (LExpr tag ret)
readPM (ReadOp_array elem_pf) (Cons ptr (Cons ix Nil)) =
  do mem <- getMem
     case ml_lookup (symMemArrays mem) elem_pf of
       SymMemName lit_tp n ->
         return $ mkVarTp Proxy (symMemArrayType lit_tp) n ptr ix
readPM ReadOp_ptr_array (Cons ptr (Cons ix Nil)) =
  do mem <- getMem
     ptr_ret_n <- nuM (ltypeRep :: LType Ptr) Nothing
     let ptr_ret = mkVar Proxy ptr_ret_n
     assumePM $ mkVar Proxy (symMemPtrArray mem) ptr ix ptr_ret
     return ptr_ret
readPM ReadOp_length (Cons ptr Nil) =
  do mem <- getMem
     return $ mkVar Proxy (symMemLengths mem) ptr
readPM ReadOp_last_alloc _ =
  do mem <- getMem
     return $ mkVar Proxy $ symMemLastAlloc mem

-- | Perform an update operation in the current 'LogicPM' computation
updatePM :: UpdateOp (LStorables tag) args -> MapList (LExpr tag) args ->
            LogicPM tag ()
updatePM (UpdateOp_array elem_pf) (Cons ptr (Cons ix (Cons v Nil))) =
  do mem <- getMem
     -- Look up the proper name with its output type
     let SymMemName ltp n = ml_lookup (symMemArrays mem) elem_pf
     -- Create a fresh name for the updated memory
     n' <- nuM (symMemArrayType ltp) Nothing
     -- Assert that (n' ptr ix) = v
     assumePM $
       mkEqTp (L1FunType_base $ L1Type_lit ltp)
       (mkVarTp Proxy (symMemArrayType ltp) n' ptr ix) v
     -- Assert that (n' p i) = (n p i) for p != ptr or i != ix
     assumePM $ mkForall L1Type_ptr $ \p ->
       mkForall (L1Type_lit LitType_bits) $ \i ->
       mkOr [mkAnd [mkEq1 p ptr, mkEq1 i ix]
            ,
             mkEqTp (L1FunType_base $ L1Type_lit ltp)
             (mkVarTp Proxy (symMemArrayType ltp) n p i)
             (mkVarTp Proxy (symMemArrayType ltp) n' p i)]
     -- Set mem' as the output memory
     setMem $ mem { symMemArrays =
                      ml_map1 (\_ -> SymMemName ltp n')
                      (symMemArrays mem) elem_pf }
updatePM UpdateOp_ptr_array (Cons ptr (Cons ix (Cons v Nil))) =
  do mem <- getMem
     let n = symMemPtrArray mem
     n' <- nuM (ltypeRep :: LType SymMemPtrArrayType) Nothing
     -- Assert that n' is a valid set of pointer arrays
     assumePtrArrayName n'
     -- Assert that (n' ptr ix v) holds
     assumePM $ mkVar Proxy n' ptr ix v
     -- Assert that (n' p i p') = (n p i p') for p != ptr or i != ix
     assumePM $ mkForall L1Type_ptr $ \p ->
       mkForall (L1Type_lit LitType_bits) $ \i ->
       mkForall L1Type_ptr $ \p' ->
       mkOr [mkAnd [mkEq1 p ptr, mkEq1 i ix]
            ,
             mkEq1 (mkVar Proxy n p i p') (mkVar Proxy n' p i p')]
     -- Set mem' as the output memory
     setMem $ mem { symMemPtrArray = n' }
updatePM (UpdateOp_alloc _) (Cons len Nil) =
  do mem <- getMem
     let lengths = symMemLengths mem
     let last_alloc = symMemLastAlloc mem
     -- Define a new function for the lengths
     lengths' <- nuM (ltypeRep :: LType (Ptr -> Literal Word64)) Nothing
     -- Define a new name for last_alloc
     last_alloc' <- nuM (ltypeRep :: LType Ptr) (Just $ mkOp Op_next_ptr $
                                                 mkVar Proxy last_alloc)
     -- Assert that (lengths' last_alloc') = len
     assumePM $
       mkEq1 (mkVar Proxy lengths' $ mkVar Proxy last_alloc') len
     -- Assert that (mem_lengths' p) = (mem_lengths p) for p != last_alloc
     assumePM $
       mkForall L1Type_ptr $ \p ->
       mkOr [mkEq1 p (mkVar Proxy last_alloc')
            ,
             mkEq1 (mkVar Proxy lengths' p) (mkVar Proxy lengths p)]
     -- Set the output memory
     setMem $ mem { symMemLengths = lengths', symMemLastAlloc = last_alloc' }

-- | Raise an exception in a 'LogicPM' computation
raisePM :: Maybe (LException tag) -> LogicPM tag ()
raisePM exn = raise exn

-- | Run the first computation. If it raises the given exception, then run the
-- second computation.
catchPM :: Eq (LException tag) => LException tag ->
           LogicPM tag () -> LogicPM tag () -> LogicPM tag ()
catchPM exn m m_exn =
  handle m $ \raised ->
  if raised == Just exn then m_exn else raisePM raised


----------------------------------------------------------------------
-- The orP operation in the predicate monad
----------------------------------------------------------------------

-- | Collect all the possible alternative output states of a 'LogicPM'
-- computation, grouping them together by exception or lack thereof
collectResultsPM :: Eq (LException tag) =>
                    LogicPM tag () ->
                    LogicPM tag [(Either (Maybe (LException tag)) (),
                                  [(SymMemory tag, [LProp tag])])]
collectResultsPM pm =
  get >>= \(mem,_) ->
  liftM groupAList $
  lift $ lift $ lift $ findAll $ runStateT (mem, []) $ runExceptionT pm

-- | Get the current propositions for this computation branch and bind a fresh
-- name equal to the conjunction of these propositions, returning this
-- fresh name after first setting it as the output proposition.
getPropsAsConstant :: LogicPM tag (LProp tag)
getPropsAsConstant =
  do (mem, props) <- get
     prop_n <- nuM ltypeRep (Just $ mkAnd props)
     let combined_prop = mkVar Proxy prop_n
     set (mem, [combined_prop])
     return combined_prop

-- | FIXME: documentation
freshMemoryFrom :: [SymMemory tag] -> LogicPM tag (SymMemory tag)
freshMemoryFrom [] = error "freshMemoryFrom: empty list!"
freshMemoryFrom (mem:mems) =
  foldM (\mem1 mem2 ->
          do symMemArrays <-
               combineMemArrays (symMemArrays mem1) (symMemArrays mem2)
             symMemPtrArray <-
               combineNames ltypeRep (symMemPtrArray mem1) (symMemPtrArray mem2)
             symMemLengths <-
               combineNames ltypeRep (symMemLengths mem1) (symMemLengths mem2)
             symMemLastAlloc <-
               combineNames ltypeRep
               (symMemLastAlloc mem1) (symMemLastAlloc mem2)
             return $ SymMemory { symMemArrays, symMemPtrArray,
                                  symMemLengths, symMemLastAlloc }
          ) mem mems
  where
    combineNames :: LType a -> Name a -> Name a -> LogicPM tag (Name a)
    combineNames tp n1 n2 =
      if n1 == n2 then return n1 else nuM tp Nothing
    combineMemArrays :: MapList SymMemName mm -> MapList SymMemName mm ->
                        LogicPM tag (MapList SymMemName mm)
    combineMemArrays Nil Nil = return Nil
    combineMemArrays (Cons (SymMemName ltp n1) as1) (Cons (SymMemName _ n2) as2) =
      do n' <- combineNames (symMemArrayType ltp) n1 n2
         as' <- combineMemArrays as1 as2
         return $ Cons (SymMemName ltp n') as'

-- | FIXME: documentation
canonicalizePM :: Eq (LException tag) => LogicPM tag () -> LogicPM tag ()
canonicalizePM pm =
  do orig_prop <- getPropsAsConstant
     res_alist <- collectResultsPM pm
     foldr mplus mzero $
       map (\(either, mems_with_props) ->
            do mem' <- freshMemoryFrom $ map fst mems_with_props
               set (mem',
                    [orig_prop,
                     mkOr $
                     map (\(mem, props) ->
                           mkAnd (props ++ [symMemEquals mem mem']))
                     mems_with_props
                    ])
               case either of
                 Left exn -> raise exn
                 Right () -> return ())
       res_alist

-- | Disjoin two 'LogicPM' computations
orPM :: Eq (LException tag) => LogicPM tag () -> LogicPM tag () ->
        LogicPM tag ()
orPM pm1 pm2 = canonicalizePM $ pm1 `mplus` pm2


----------------------------------------------------------------------
-- Interpreting the predicate monad inside the logic
----------------------------------------------------------------------

-- | FIXME: documentation
data InterpPM tag a where
  InterpPM_base :: L1Type a -> LExpr tag a -> InterpPM tag a
  InterpPM_fun :: (InterpPM tag a -> InterpPM tag b) -> InterpPM tag (a -> b)
  InterpPM_pm :: LogicPM tag (LExpr tag a) -> InterpPM tag (PM a)
  InterpPM_unit_pm :: LogicPM tag () -> InterpPM tag (PM (Literal ()))

-- | Extract an 'LExpr' from an 'InterpPM' of base type
expr_of_interpPM :: L1Type a -> InterpPM tag a -> LExpr tag a
expr_of_interpPM _ (InterpPM_base _ e) = e
expr_of_interpPM l1tp (InterpPM_fun _) = no_functional_l1type l1tp
expr_of_interpPM l1tp (InterpPM_pm _) = no_pm_l1type l1tp
expr_of_interpPM l1tp (InterpPM_unit_pm _) = no_pm_l1type l1tp

-- | Extract a function from an 'InterpPM'
apply_interpPM :: InterpPM tag (a -> b) -> InterpPM tag a -> InterpPM tag b
apply_interpPM (InterpPM_fun f) = f
apply_interpPM (InterpPM_base l1tp _) = no_functional_l1type l1tp

-- | Extract a 'LogicPM' computation from an 'InterpPM'
pm_of_interpPM :: InterpPM tag (PM a) -> LogicPM tag (LExpr tag a)
pm_of_interpPM (InterpPM_base l1tp _) = no_pm_l1type l1tp
pm_of_interpPM (InterpPM_pm m) = m
pm_of_interpPM (InterpPM_unit_pm m) = m >> return (mkLiteral ())

-- | Extract a @'LogicPM' ()@ computation from an 'InterpPM'
unit_pm_of_interpPM :: InterpPM tag (PM a) -> LogicPM tag ()
unit_pm_of_interpPM (InterpPM_base l1tp _) = no_pm_l1type l1tp
unit_pm_of_interpPM (InterpPM_pm m) = m >>= \_ -> return ()
unit_pm_of_interpPM (InterpPM_unit_pm m) = m

-- | Build an 'InterpPM' from a first-order function on 'LExprs'
mkL1FunInterpPM :: L1FunType a ->
                   (LExprs tag (ArgTypes a) -> LExpr tag (RetType a)) ->
                   InterpPM tag a
mkL1FunInterpPM (L1FunType_base l1tp@(L1Type_lit _)) f =
  InterpPM_base l1tp $ f LExprs_nil
mkL1FunInterpPM (L1FunType_base l1tp@L1Type_prop) f =
  InterpPM_base l1tp $ f LExprs_nil
mkL1FunInterpPM (L1FunType_base l1tp@L1Type_ptr) f =
  InterpPM_base l1tp $ f LExprs_nil
mkL1FunInterpPM (L1FunType_cons l1tp ftp) f =
  InterpPM_fun $ \ipm ->
  mkL1FunInterpPM ftp (\es -> f (LExprs_cons (expr_of_interpPM l1tp ipm) es))

-- | Build an 'InterpM' from an 'Op' with a first-order function type
mkOpInterpPM :: L1FunType a -> Op tag a -> InterpPM tag a
mkOpInterpPM ftp op = mkL1FunInterpPM ftp (LOp op)

-- | Build an 'InterpM' from a unary, first-order 'Op'
mkOp1InterpPM :: L1Type a -> L1Type b -> Op tag (a -> b) ->
                 InterpPM tag (a -> b)
mkOp1InterpPM tp1 tp2 op =
  mkOpInterpPM (L1FunType_cons tp1 $ L1FunType_base tp2) op

-- | Build an 'InterpM' from a binary, first-order 'Op'
mkOp2InterpPM :: L1Type a -> L1Type b -> L1Type c -> Op tag (a -> b -> c) ->
                 InterpPM tag (a -> b -> c)
mkOp2InterpPM tp1 tp2 tp3 op =
  mkOpInterpPM (L1FunType_cons tp1 $ L1FunType_cons tp2 $ L1FunType_base tp3) op

-- CommutesWithArrow instance for InterpPM
instance CommutesWithArrow (InterpPM tag) where
  interpApply (InterpPM_fun f) = f
  interpLambda = InterpPM_fun

-- LExprAlgebra instance for interpreting the predicate monad
instance LExprAlgebra tag (InterpPM tag) where
  interpOp (Op_Literal ltp x) =
    mkOpInterpPM (L1FunType_base $ L1Type_lit ltp) (Op_Literal ltp x)
  interpOp op@(Op_arith1 ltp _) =
    mkOp1InterpPM (L1Type_lit ltp) (L1Type_lit ltp) op
  interpOp op@(Op_arith2 ltp _) =
    mkOp2InterpPM (L1Type_lit ltp) (L1Type_lit ltp) (L1Type_lit ltp) op
  interpOp op@(Op_coerce tp_from tp_to) =
    mkOp1InterpPM (L1Type_lit tp_from) (L1Type_lit tp_to) op
  interpOp op@(Op_cmp ltp _) =
    mkOp2InterpPM (L1Type_lit ltp) (L1Type_lit ltp) (L1Type_lit LitType_bool) op
  interpOp op@Op_or = mkOpInterpPM l1funTypeRep op
  interpOp op@Op_not = mkOpInterpPM l1funTypeRep op
  interpOp op@Op_istrue = mkOpInterpPM l1funTypeRep op
  interpOp (Op_forall l1tp) =
    InterpPM_fun $ \body_ipm ->
    InterpPM_base L1Type_prop $ mkForall l1tp $ \x ->
    expr_of_interpPM L1Type_prop $
    apply_interpPM body_ipm $ InterpPM_base l1tp x
  interpOp (Op_exists l1tp) =
    InterpPM_fun $ \body_ipm ->
    InterpPM_base L1Type_prop $ mkExists l1tp $ \x ->
    expr_of_interpPM L1Type_prop $
    apply_interpPM body_ipm $ InterpPM_base l1tp x
  interpOp (Op_returnP l1tp) =
    InterpPM_fun $ \x ->
    InterpPM_pm $ return $ expr_of_interpPM l1tp x
  interpOp (Op_bindP l1tp_a l1tp_b) =
    InterpPM_fun $ \m ->
    InterpPM_fun $ \f_ipm ->
    InterpPM_pm (pm_of_interpPM m >>= \x ->
                 pm_of_interpPM (apply_interpPM f_ipm $
                                 InterpPM_base l1tp_a x))
  interpOp (Op_readP rop@(ReadOp_array elem_pf)) =
    InterpPM_fun $ \(InterpPM_base l1typeRep ptr) ->
    InterpPM_fun $ \(InterpPM_base l1typeRep ix) ->
    InterpPM_pm $ readPM rop (Cons ptr (Cons ix Nil))
  interpOp (Op_readP rop@ReadOp_ptr_array) =
    InterpPM_fun $ \(InterpPM_base _ ptr) ->
    InterpPM_fun $ \(InterpPM_base _ ix) ->
    InterpPM_pm $ readPM rop (Cons ptr (Cons ix Nil))
  interpOp (Op_readP rop@ReadOp_length) =
    InterpPM_fun $ \(InterpPM_base _ ptr) ->
    InterpPM_pm $ readPM rop (Cons ptr Nil)
  interpOp (Op_readP rop@ReadOp_last_alloc) =
    InterpPM_pm $ readPM rop Nil
  interpOp (Op_updateP uop@(UpdateOp_array elem_pf)) =
    InterpPM_fun $ \(InterpPM_base _ ptr) ->
    InterpPM_fun $ \(InterpPM_base _ ix) ->
    InterpPM_fun $ \(InterpPM_base _ v) ->
    InterpPM_unit_pm $ updatePM uop (Cons ptr (Cons ix (Cons v Nil)))
  interpOp (Op_updateP uop@UpdateOp_ptr_array) =
    InterpPM_fun $ \(InterpPM_base _ ptr) ->
    InterpPM_fun $ \(InterpPM_base _ ix) ->
    InterpPM_fun $ \(InterpPM_base _ v) ->
    InterpPM_unit_pm $ updatePM uop (Cons ptr (Cons ix (Cons v Nil)))
  interpOp (Op_updateP uop@(UpdateOp_alloc _)) =
    InterpPM_fun $ \(InterpPM_base _ len) ->
    InterpPM_unit_pm $ updatePM uop (Cons len Nil)
  interpOp (Op_raiseP maybe_exn) =
    InterpPM_unit_pm $ raisePM maybe_exn
  interpOp (Op_catchP exn) =
    InterpPM_fun $ \m1 -> InterpPM_fun $ \m2 ->
    InterpPM_unit_pm $
    catchPM exn (unit_pm_of_interpPM m1) (unit_pm_of_interpPM m2)
  interpOp Op_assumeP =
    InterpPM_fun $ \(InterpPM_base _ p) -> InterpPM_unit_pm $ assumePM p
  interpOp Op_falseP =
    InterpPM_unit_pm $ falsePM
  interpOp Op_orP =
    InterpPM_fun $ \m1 -> InterpPM_fun $ \m2 ->
    InterpPM_unit_pm $
    orPM (unit_pm_of_interpPM m1) (unit_pm_of_interpPM m2)