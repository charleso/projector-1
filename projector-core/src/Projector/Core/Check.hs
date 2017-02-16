{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
module Projector.Core.Check (
  -- * Interface
    TypeError (..)
  , typeCheckIncremental
  , typeCheckAll
  , typeCheck
  , typeTree
  -- * Guts
  , generateConstraints
  , solveConstraints
  , Substitutions (..)
  ) where


import           Control.Monad.ST (ST, runST)
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.State.Strict (State, runState, gets, modify')

import           Data.Char (chr, ord)
import           Data.DList (DList)
import qualified Data.DList as D
import qualified Data.List as L
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import           Data.STRef (STRef)
import qualified Data.STRef as ST
import qualified Data.Text as T
import qualified Data.UnionFind.ST as UF

import           P

import           Projector.Core.Syntax
import           Projector.Core.Type

import           X.Control.Monad.Trans.Either (EitherT, left, runEitherT)
import qualified X.Control.Monad.Trans.Either as ET


data TypeError l a
  = UnificationError (Type l, a) (Type l, a)
  | FreeVariable Name a
  | UndeclaredType TypeName a
  | BadConstructorName Constructor TypeName (Decl l) a
  | BadConstructorArity Constructor (Decl l) Int a
  | BadPatternArity Constructor (Type l) Int Int a
  | BadPatternConstructor Constructor a
  | InferenceError a
  | RecordInferenceError a [(FieldName, (Type l, a))]
  | InfiniteType (Type l, a) (Type l, a)
  | InvalidRecordFields (Type l, a) [(FieldName, (Type l, a))]

deriving instance (Ground l, Eq a) => Eq (TypeError l a)
deriving instance (Ground l, Show a) => Show (TypeError l a)
deriving instance (Ground l, Ord a) => Ord (TypeError l a)


-- | Like 'typeCheckAll', but accepting a map of expressions of known
-- type. This is appropriate for use in a left fold for incremental
-- (dependency-ordered) typechecking.
typeCheckIncremental ::
     Ground l
  => TypeDecls l
  -> Map Name (Type l, a)
  -> Map Name (Expr l a)
  -> Either [TypeError l a] (Map Name (Expr l (Type l, a)))
typeCheckIncremental decls known exprs =
  typeCheckAll' decls (fmap (\(t,a) -> hoistType decls a t) known) exprs

-- | Typecheck an interdependent set of named expressions.
-- This is essentially top-level letrec.
--
-- TODO: This admits general recursion. We need to write a totality checker.
--
-- We cannot cache the intermediate results here, so we need to
-- recheck everything each time. To support incremental builds we need
-- to group expressions into "modules", figure out the module
-- dependency DAG, and traverse only the dirty subtrees of that DAG.
typeCheckAll ::
     Ground l
  => TypeDecls l
  -> Map Name (Expr l a)
  -> Either [TypeError l a] (Map Name (Expr l (Type l, a)))
typeCheckAll decls exprs =
  typeCheckAll' decls mempty exprs

typeCheckAll' ::
     Ground l
  => TypeDecls l
  -> Map Name (IType l a)
  -> Map Name (Expr l a)
  -> Either [TypeError l a] (Map Name (Expr l (Type l, a)))
typeCheckAll' decls known exprs = do
  -- for each declaration, generate constraints and assumptions
  (annotated, sstate) <- runCheck (sequenceCheck (fmap (generateConstraints' decls) exprs))
  -- build up new global set of constraints from the assumptions
  let localConstraints = sConstraints sstate
      Assumptions assums = sAssumptions sstate
      types = known <> fmap extractType annotated
      globalConstraints = D.fromList . fold . M.elems . flip M.mapWithKey assums $ \n itys ->
        maybe mempty (with itys . Equal) (M.lookup n types)
      constraints = D.toList (localConstraints <> globalConstraints)
      bound = S.fromList (M.keys known <> M.keys exprs)
      used = S.fromList (M.keys (M.filter (not . null) assums))
      free = used `S.difference` bound
      freeAt = foldMap (\n -> maybe [] (fmap ((n,) . snd . flattenIType)) (M.lookup n assums)) (toList free)
  -- catch any free variables
  if free == mempty then pure () else Left (fmap (uncurry FreeVariable) freeAt)

  -- solve them all at once
  subs <- solveConstraints constraints
  -- substitute them all at once
  let subbed = fmap (substitute subs) annotated
  -- lower them all at once
  first D.toList (ET.sequenceEither (fmap lowerExpr subbed))

typeCheck :: Ground l => TypeDecls l -> Expr l a -> Either [TypeError l a] (Type l)
typeCheck decls =
  fmap extractType . typeTree decls

typeTree ::
     Ground l
  => TypeDecls l
  -> Expr l a
  -> Either [TypeError l a] (Expr l (Type l, a))
typeTree decls expr = do
  (expr', constraints, Assumptions assums) <- generateConstraints decls expr
  -- Any unresolved assumptions are from free variables
  if M.keys (M.filter (not . null) assums) == mempty
    then pure ()
    else Left (foldMap (\(n, itys) -> fmap (FreeVariable n . snd . flattenIType) itys) (M.toList assums))
  subs <- solveConstraints constraints
  let subbed = substitute subs expr'
  first D.toList (lowerExpr subbed)

-- -----------------------------------------------------------------------------
-- Types

-- | 'IType l a' is a fixpoint of 'IVar a (TypeF l)'.
--
-- i.e. regular types, recursively extended with annotations and an
-- extra constructor, 'IDunno', representing fresh type/unification variables.
--
-- We also need to track any used record field names in the type.
newtype IType l a = I (IVar a (TypeF l (IType l a)), [Field l a])
  deriving (Eq, Ord, Show)

-- | 'IVar' is an open functor equivalent to an annotated 'Either Int'.
data IVar ann a
  = Dunno ann Int
  | Am ann a
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | 'Field' asserts that a type has a record field of a certain type.
data Field l a = Field {
    fieldName :: FieldName
  , fieldType :: IType l a
  } deriving (Eq, Ord, Show)

-- | Lift a known type into an 'IType', with an annotation.
--
-- For records, this means injecting the known set of fields.
hoistType :: Ground l => TypeDecls l -> a -> Type l -> IType l a
hoistType decls a (Type ty) =
  case ty of
    TVarF tn ->
      case lookupType tn decls of
        Just (DVariant _cns) ->
          I (Am a (TVarF tn), [])
        Just (DRecord fts) ->
          I (Am a (TVarF tn), hoistFields decls a fts)
        Nothing ->
          -- This is an error. Should probably be in Either here.
          I (Am a (TVarF tn), [])

    _ ->
      I (Am a (fmap (hoistType decls a) ty), [])

hoistFields :: Ground l => TypeDecls l -> a -> [(FieldName, Type l)] -> [Field l a]
hoistFields decls a fts =
  with fts $ \(fn, ty) -> Field fn (hoistType decls a ty)

-- | Assert that we have a monotype. Returns 'InferenceError' if we
-- encounter a unification variable.
--
-- This also involves checking the list of fields for validity.
lowerIType :: IType l a -> Either (TypeError l a) (Type l)
lowerIType t@(I v) =
  case v of
    (Dunno a _, []) ->
      Left (InferenceError a)
    (Dunno a _, fields) ->
      Left (RecordInferenceError a (lowerFields fields))
    (Am _ ty, []) ->
      fmap Type (traverse lowerIType ty)
    (Am _ ty@(TVarF _tn), _fields) ->
      -- FIX pick out any extraneous fields
      fmap Type (traverse lowerIType ty)
    (Am _ _, fields) ->
      Left (InvalidRecordFields (flattenIType t) (lowerFields fields))

lowerFields :: [Field l a] -> [(FieldName, (Type l, a))]
lowerFields =
  fmap (\f -> (fieldName f, flattenIType (fieldType f)))

-- Produce concrete type name for a fresh variable.
dunnoTypeVar :: Int -> TypeName
dunnoTypeVar x =
  let letter j = chr (ord 'a' + j)
  in case (x `mod` 26, x `div` 26) of
    (i, 0) ->
      TypeName (T.pack [letter i])
    (m, n) ->
      TypeName (T.pack [letter m] <> renderIntegral n)

-- Produce a regular type, concretising fresh variables.
-- This is currently used for error reporting.
flattenIType :: IType l a -> (Type l, a)
flattenIType i@(I v) =
  (flattenIType' i,
    case v of
      (Dunno a _, _rows) ->
        a
      (Am a _, _rows) ->
        a)

flattenIType' :: IType l a -> Type l
flattenIType' (I v) =
  case v of
    (Dunno _ x, _rows) ->
      TVar (dunnoTypeVar x)

    (Am _ ty, _rows) ->
      Type (fmap flattenIType' ty)

lowerExpr :: Expr l (IType l a, a) -> Either (DList (TypeError l a)) (Expr l (Type l, a))
lowerExpr =
  ET.sequenceEither . fmap (\(ity, a) -> fmap (,a) (first D.singleton (lowerIType ity)))

typeVar :: IType l a -> Maybe Int
typeVar ty =
  case ty of
    I (Dunno _ x, _rows) ->
      pure x
    I (Am _ _, _rows) ->
      Nothing


-- -----------------------------------------------------------------------------
-- Monad stack

-- | 'Check' permits multiple errors via 'EitherT', lexically-scoped
-- state via 'ReaderT', and global accumulating state via 'State'.
newtype Check l a b = Check {
    unCheck :: EitherT (DList (TypeError l a)) (State (SolverState l a)) b
  } deriving (Functor, Applicative, Monad)

runCheck :: Check l a b -> Either [TypeError l a] (b, SolverState l a)
runCheck f =
    unCheck f
  & runEitherT
  & flip runState initialSolverState
  & \(e, st) -> fmap (,st) (first D.toList e)

data SolverState l a = SolverState {
    sConstraints :: DList (Constraint l a)
  , sAssumptions :: Assumptions l a
  , sSupply :: NameSupply
  } deriving (Eq, Ord, Show)

initialSolverState :: SolverState l a
initialSolverState =
  SolverState {
      sConstraints = mempty
    , sAssumptions = mempty
    , sSupply = emptyNameSupply
    }

newtype Assumptions l a = Assumptions {
    unAssumptions :: Map Name [IType l a]
  } deriving (Eq, Ord, Show, Monoid)

throwError :: TypeError l a -> Check l a b
throwError =
  Check . left . D.singleton

sequenceCheck :: Traversable t => t (Check l a b) -> Check l a (t b)
sequenceCheck =
  Check . ET.sequenceEitherT . fmap unCheck

-- -----------------------------------------------------------------------------
-- Name supply

-- | Supply of fresh unification variables.
newtype NameSupply = NameSupply { nextVar :: Int }
  deriving (Eq, Ord, Show)

emptyNameSupply :: NameSupply
emptyNameSupply =
  NameSupply 0

-- | Grab a fresh type variable.
freshTypeVar :: a -> Check l a (IType l a)
freshTypeVar a =
  Check . lift $ do
    v <- gets (nextVar . sSupply)
    modify' (\s -> s { sSupply = NameSupply (v + 1) })
    return (I (Dunno a v, []))

-- -----------------------------------------------------------------------------
-- Constraints

data Constraint l a
  = Equal (IType l a) (IType l a)
  deriving (Eq, Ord, Show)

-- | Record a new constraint.
addConstraint :: Ground l => Constraint l a -> Check l a ()
addConstraint c =
  Check . lift $
    modify' (\s -> s { sConstraints = D.snoc (sConstraints s) c })

-- | Add a field constraint.
--
-- This involves creating a new unification variable with that field,
-- and asserting that it should unify with the parent type.
hasField :: Ground l => a -> IType l a -> Field l a -> Check l a ()
hasField a ta field = do
  I (tb, _) <- freshTypeVar a
  addConstraint (Equal (I (tb, [field])) ta)


-- -----------------------------------------------------------------------------
-- Assumptions

-- | Add an assumed type for some variable we've encountered.
addAssumption :: Ground l => Name -> IType l a -> Check l a ()
addAssumption n ty =
  Check . lift $
    modify' (\s -> s {
        sAssumptions = Assumptions (M.insertWith (<>) n [ty] (unAssumptions (sAssumptions s)))
      })

-- | Clobber the assumption set for some variable.
setAssumptions :: Ground l => Name -> [IType l a] -> Check l a ()
setAssumptions n assums =
  Check . lift $
    modify' (\s -> s {
        sAssumptions = Assumptions (M.insert n assums (unAssumptions (sAssumptions s)))
      })

-- | Delete all assumptions for some variable.
--
-- This is called when leaving the lexical scope in which the variable was bound.
deleteAssumptions :: Ground l => Name -> Check l a ()
deleteAssumptions n =
  Check . lift $
    modify' (\s -> s {
        sAssumptions = Assumptions (M.delete n (unAssumptions (sAssumptions s)))
      })

-- | Look up all assumptions for a given name. Returns the empty set if there are none.
lookupAssumptions :: Ground l => Name -> Check l a [IType l a]
lookupAssumptions n =
  Check . lift $
    fmap (fromMaybe mempty) (gets (M.lookup n . unAssumptions . sAssumptions))

-- | Run some continuation with lexically-scoped assumptions.
-- This is sorta like 'local', but we need to keep changes to other keys in the map.
withBindings :: Ground l => Traversable f => f Name -> Check l a b -> Check l a (Map Name [IType l a], b)
withBindings xs k = do
  old <- fmap (M.fromList . toList) . for xs $ \n -> do
    as <- lookupAssumptions n
    deleteAssumptions n
    pure (n, as)
  res <- k
  new <- fmap (M.fromList . toList) . for xs $ \n -> do
    as <- lookupAssumptions n
    setAssumptions n (fromMaybe mempty (M.lookup n old))
    pure (n, as)
  pure (new, res)

withBinding :: Ground l => Name -> Check l a b -> Check l a ([IType l a], b)
withBinding x k = do
  (as, b) <- withBindings [x] k
  pure (fromMaybe mempty (M.lookup x as), b)


-- -----------------------------------------------------------------------------
-- Constraint generation

generateConstraints ::
     Ground l
  => TypeDecls l
  -> Expr l a
  -> Either [TypeError l a] (Expr l (IType l a, a), [Constraint l a], Assumptions l a)
generateConstraints decls expr = do
  (e, st) <- runCheck (generateConstraints' decls expr)
  pure (e, D.toList (sConstraints st), sAssumptions st)

generateConstraints' :: Ground l => TypeDecls l -> Expr l a -> Check l a (Expr l (IType l a, a))
generateConstraints' decls expr =
  case expr of
    ELit a v ->
      -- We know the type of literals instantly.
      let ty = TLit (typeOf v)
      in pure (ELit (hoistType decls a ty, a) v)

    EVar a v -> do
      -- We introduce a new type variable representing the type of this expression.
      -- Add it to the assumption set.
      t <- freshTypeVar a
      addAssumption v t
      pure (EVar (t, a) v)

    ELam a n mta e -> do
      -- Proceed bottom-up, generating constraints for 'e'.
      -- Gather the assumed types of 'n', and constrain them to be the known (annotated) type.
      -- This expression's type is an arrow from the known type to the inferred type of 'e'.
      (as, e') <- withBinding n (generateConstraints' decls e)
      ta <- maybe (freshTypeVar a) (pure . hoistType decls a) mta
      for_ as (addConstraint . Equal ta)
      let ty = I (Am a (TArrowF ta (extractType e')), [])
      pure (ELam (ty, a) n mta e')

    EApp a f g -> do
      -- Proceed bottom-up, generating constraints for 'f' and 'g'.
      -- Introduce a new type variable for the result of the expression.
      -- Constrain 'f' to be an arrow from the type of 'g' to this type.
      f' <- generateConstraints' decls f
      g' <- generateConstraints' decls g
      t <- freshTypeVar a
      addConstraint (Equal (I (Am a (TArrowF (extractType g') t), [])) (extractType f'))
      pure (EApp (t, a) f' g')

    EList a te es -> do
      -- Proceed bottom-up, inferring types for each expression in the list.
      -- Constrain each type to be the annotated 'ty'.
      es' <- for es (generateConstraints' decls)
      for_ es' (addConstraint . Equal (hoistType decls a te) . extractType)
      let ty = I (Am a (TListF (hoistType decls a te)), [])
      pure (EList (ty, a) te es')

    EMap a f g -> do
      -- Special case polymorphic map. g must be List a, f must be (a -> b)
      f' <- generateConstraints' decls f
      g' <- generateConstraints' decls g
      ta <- freshTypeVar a
      tb <- freshTypeVar a
      addConstraint (Equal (I (Am a (TArrowF ta tb), [])) (extractType f'))
      addConstraint (Equal (I (Am a (TListF ta), [])) (extractType g'))
      let ty = I (Am a (TListF tb),[])
      pure (EMap (ty, a) f' g')

    ECon a c tn es ->
      case lookupType tn decls of
        Just ty@(DVariant cns) -> do
          -- Look up the constructor, check its arity, and introduce
          -- constraints for each of its subterms, for which we expect certain types.
          ts <- maybe (throwError (BadConstructorName c tn ty a)) pure (L.lookup c cns)
          unless (length ts == length es) (throwError (BadConstructorArity c ty (length es) a))
          es' <- for es (generateConstraints' decls)
          for_ (L.zip (fmap (hoistType decls a) ts) (fmap extractType es'))
            (\(expected, inferred) -> addConstraint (Equal expected inferred))
          let ty' = I (Am a (TVarF tn), [])
          pure (ECon (ty', a) c tn es')

        -- Record construction - the type name is the constructor.
        Just ty@(DRecord fts) -> do
          -- Check arity
          unless (length fts == length es) (throwError (BadConstructorArity c ty (length es) a))
          es' <- for es (generateConstraints' decls)
          -- introduce constraints for each subterm
          let fts' = fmap (fmap (hoistType decls a)) fts
              ts = fmap snd fts'
          for_ (L.zip ts (fmap extractType es'))
            (\(expected, inferred) -> addConstraint (Equal expected inferred))
          let ty' = I (Am a (TVarF tn), fmap (uncurry Field) fts')
          pure (ECon (ty', a) c tn es')

        Nothing ->
          throwError (UndeclaredType tn a)

    ECase a e pes -> do
      -- The body of the case expression should be the same type for each branch.
      -- We introduce a new unification variable for that type.
      -- Patterns introduce new constraints and bindings, managed in 'patternConstraints'.
      e' <- generateConstraints' decls e
      ty <- freshTypeVar a
      pes' <- for pes $ \(pat, pe) -> do
        let bnds = patternBinds pat
        (_, res) <- withBindings (S.toList bnds) $ do
          -- Order matters here, patCons consumes the assumptions from genCons.
          pe' <- generateConstraints' decls pe
          pat' <- patternConstraints decls (extractType e') pat
          addConstraint (Equal ty (extractType pe'))
          pure (pat', pe')
        pure res
      pure (ECase (ty, a) e' pes')

    EPrj a e fn -> do
      -- We introduce a new unification variable for the result of the projection.
      -- We add a field constraint, asserting that the type of e has a field of this variable.
      e' <- generateConstraints' decls e
      tp <- freshTypeVar a
      hasField a (extractType e') (Field fn tp)
      pure (EPrj (tp, a) e' fn)

    EForeign a n ty -> do
      -- We know the type of foreign expressions immediately, because they're annotated.
      pure (EForeign (hoistType decls a ty, a) n ty)

-- | Patterns are binding sites that also introduce lots of new constraints.
patternConstraints ::
     Ground l
  => TypeDecls l
  -> IType l a
  -> Pattern a
  -> Check l a (Pattern (IType l a, a))
patternConstraints decls ty pat =
  case pat of
    PVar a x -> do
      as <- lookupAssumptions x
      for_ as (addConstraint . Equal ty)
      pure (PVar (ty, a) x)

    PCon a c pats ->
      case lookupConstructor c decls of -- FIX this should include records
        Just (tn, ts) -> do
          unless (length ts == length pats)
            (throwError (BadPatternArity c (TVar tn) (length ts) (length pats) a))
          let ty' = I (Am a (TVarF tn), [])
          addConstraint (Equal ty' ty)
          pats' <- for (L.zip (fmap (hoistType decls a) ts) pats) (uncurry (patternConstraints decls))
          pure (PCon (ty', a) c pats')

        Nothing ->
          throwError (BadPatternConstructor c a)

extractType :: Expr l (c, a) -> c
extractType =
  fst . extractAnnotation

-- -----------------------------------------------------------------------------
-- Constraint solving

-- | Solve a set of constraints, accumulating all independent type errors in a list.
solveConstraints :: Ground l => Traversable f => f (Constraint l a) -> Either [TypeError l a] (Substitutions l a)
solveConstraints constraints =
  runST $ do
    -- Initialise mutable state.
    points <- ST.newSTRef (Points M.empty)

    -- Solve all the constraints independently.
    es <- fmap ET.sequenceEither . for constraints $ \c ->
      case c of
        Equal t1 t2 ->
          fmap (first D.singleton) (mostGeneralUnifierST points t1 t2)

    -- Retrieve the remaining points and produce a substitution map
    solvedPoints <- ST.readSTRef points
    for (first D.toList es) $ \_ -> do
      substitutionMap solvedPoints

newtype Substitutions l a
  = Substitutions { unSubstitutions :: Map Int (IType l a) }
  deriving (Eq, Ord, Show)

substitutionMap :: Points s l a -> ST s (Substitutions l a)
substitutionMap points = do
  subs <- for (unPoints points) (UF.descriptor <=< UF.repr)
  pure . Substitutions $
    -- Filter out any reflexive substitutions
    M.filterWithKey (\k v -> case v of I (Dunno _ x, _) -> k /= x; _ -> True) subs

substitute :: Ground l => Substitutions l a -> Expr l (IType l a, a) -> Expr l (IType l a, a)
substitute subs expr =
  with expr $ \(ty, a) ->
    (substituteType subs ty, a)

substituteType :: Ground l => Substitutions l a -> IType l a -> IType l a
substituteType subs ty =
  -- TODO what to do with the rows here? should we sub?
  case ty of
    I (Dunno _ x, _rows) ->
      maybe ty (substituteType subs) (M.lookup x (unSubstitutions subs))

    I (Am a (TArrowF t1 t2), rows) ->
      I (Am a (TArrowF (substituteType subs t1) (substituteType subs t2)), rows)

    I (Am a (TListF t), rows) ->
      I (Am a (TListF (substituteType subs t)), rows)

    I (Am _ (TLitF _), _) ->
      ty

    I (Am _ (TVarF _), _) ->
      ty
{-# INLINE substituteType #-}

newtype Points s l a = Points {
    unPoints :: Map Int (UF.Point s (IType l a))
  }

mostGeneralUnifierST ::
     Ground l
  => STRef s (Points s l a)
  -> IType l a
  -> IType l a
  -> ST s (Either (TypeError l a) ())
mostGeneralUnifierST points t1 t2 =
  runEitherT (mguST points t1 t2)

mguST ::
     Ground l
  => STRef s (Points s l a)
  -> IType l a
  -> IType l a
  -> EitherT (TypeError l a) (ST s) ()
mguST points t1 t2 =
  case (t1, t2) of
    (I (Dunno a x, xrows), _) -> do
      unifyVar points a x xrows t2

    (_, I (Dunno a x, xrows)) -> do
      unifyVar points a x xrows t1

    (I (Am _ (TVarF x), xrows), I (Am _ (TVarF y), yrows)) -> do
      unless (x == y) (left (unificationError t1 t2))
      -- unify record fields here.
      _ <- unifyFields points xrows yrows
      pure ()

    (I (Am _ (TLitF x), xrows), I (Am _ (TLitF y), yrows)) -> do
      unless (x == y) (left (unificationError t1 t2))
      -- throw an error if the rows aren't empty.
      unless (null xrows) (left (recordFieldError t1 xrows))
      unless (null yrows) (left (recordFieldError t2 yrows))

    (I (Am _ (TArrowF f g), xrows), I (Am _ (TArrowF h i), yrows)) -> do
      mguST points f h
      mguST points g i
      -- throw an error if the rows aren't empty.
      unless (null xrows) (left (recordFieldError t1 xrows))
      unless (null yrows) (left (recordFieldError t2 yrows))

    (I (Am _ (TListF a), xrows), I (Am _ (TListF b), yrows)) -> do
      mguST points a b
      -- throw an error if the rows aren't empty.
      unless (null xrows) (left (recordFieldError t1 xrows))
      unless (null yrows) (left (recordFieldError t2 yrows))

    (_, _) ->
      left (unificationError t1 t2)

-- We now need to update the representative with a merged set of rows
unifyVar ::
     Ground l
  => STRef s (Points s l a)
  -> a
  -> Int
  -> [Field l a]
  -> IType l a
  -> EitherT (TypeError l a) (ST s) ()
unifyVar points a x xrows t2 = do
  mt1 <- lift (getRepr points x)
  case mt1 of
    -- special case if the var is its class representative
    Just t1@(I (Dunno b y, rows)) ->
      if x == y
        then safeUnion b y t2 rows
        else mguST points t1 t2
    Just t1@(I (Am _ _, _)) -> do
      -- Propagate + unify all record fields
      safeUnion a x t1 xrows
      -- Unify on the class representative
      t1' <- lift (getRepr points x)
      mcase t1'
        (pure ()) {- invariant - this should never happen -}
        (\r1 -> mguST points r1 t2)
    Nothing ->
      safeUnion a x t2 xrows
  where
     safeUnion c z u2 rows =
       unless (typeVar u2 == Just z) $ do
         -- Performs the occurs check before actually unifying.
         ET.hoistEither (occurs c z u2)
         -- Pull the representative for u2
         urows <- fmap (\(I (_, fs)) -> fs) (lift (getRepr' points u2))
         -- Unify the record fields
         fields <- unifyFields points rows urows
         -- Unify the two classes, setting a new representative
         lift (union points fields (I (Dunno c z, rows)) u2)

-- | Check that a given unification variable isn't present inside the
-- type it's being unified with. This is necessary for typechecking
-- to be sound, it prevents us from constructing the infinite type.
occurs :: a -> Int -> IType l a -> Either (TypeError l a) ()
occurs a q ity =
  go q ity
  where
    goRows x = traverse_ (go x . fieldType)
    go x i =
      case i of
        -- also need to go through all the rows
        I (Dunno _ y, yrows) ->
          if x == y
            then Left (InfiniteType (flattenIType (I (Dunno a x, []))) (flattenIType ity))
            else goRows x yrows
        I (Am _ j, yrows) ->
          case j of
            TVarF _ ->
              goRows x yrows
            TLitF _ ->
              goRows x yrows
            TArrowF f g ->
              go x f *> go x g *> goRows x yrows
            TListF f ->
              go x f *> goRows x yrows
{-# INLINE occurs #-}

unifyFields ::
     Ground l
  => STRef s (Points s l a)
  -> [Field l a]
  -> [Field l a]
  -> EitherT (TypeError l a) (ST s) [Field l a]
unifyFields points fs1 fs2 = do
  -- TODO once this works, just thread maps instead of lists.
  let fieldMap = M.fromList . fmap (\(Field n t) -> (n, t))
      m1 = fieldMap fs1
      m2 = fieldMap fs2
      unify _fn t1 t2 = do
        mguST points t1 t2
        lift (getRepr' points t1)
  m3 <- safeMapUnionM unify m1 m2
  pure (fmap (uncurry Field) (M.toList m3))

-- | Union, performing some monadic action on duplicates.
safeMapUnionM :: (Ord k, Monad m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
safeMapUnionM combine m1 m2 =
  sequenceA (M.unionWithKey f (fmap pure m1) (fmap pure m2))
  where
    f k m n = do
      m' <- m
      n' <- n
      combine k m' n'

-- | Unify two equivalence classes, updating the record fields as we go.
union :: STRef s (Points s l a) -> [Field l a] -> IType l a -> IType l a -> ST s ()
union points fields t1 t2 = do
  p1 <- getPoint points t1
  p2 <- getPoint points t2
  UF.union' p1 p2 (\_r1 (I (r2, _)) -> pure (I (r2, fields)))

-- | Fills the 'lookup' API hole in the union-find package.
--
-- Given a type,
-- * if it's a unification variable, get its class representative
-- * if there's no class representative, create a fresh point
-- * all non-unification variables get unique fresh points
getPoint :: STRef s (Points s l a) -> IType l a -> ST s (UF.Point s (IType l a))
getPoint mref ty =
  case ty of
    I (Dunno _ x, _) -> do
      Points ps <- ST.readSTRef mref
      case M.lookup x ps of
        Just point ->
          pure point
        Nothing -> do
          point <- UF.fresh ty
          ST.modifySTRef' mref (Points . M.insert x point . unPoints)
          pure point

    I (Am _ _, _) ->
      UF.fresh ty
{-# INLINE getPoint #-}

-- | Grab the class representative for a given unification variable.
getRepr :: STRef s (Points s l a) -> Int -> ST s (Maybe (IType l a))
getRepr points x = do
  ps <- ST.readSTRef points
  for (M.lookup x (unPoints ps)) (UF.descriptor <=< UF.repr)

getRepr' :: STRef s (Points s l a) -> IType l a -> ST s (IType l a)
getRepr' points =
  UF.descriptor <=< UF.repr <=< getPoint points

-- | Get the fields for a given unification variable.
getFields :: STRef s (Points s l a) -> Int -> ST s (Maybe [Field l a])
getFields points x = do
  mt <- getRepr points x
  pure (mt >>= \(I (_, fs)) -> pure fs)

-- | Report a unification error.
unificationError :: IType l a -> IType l a -> TypeError l a
unificationError =
  UnificationError `on` flattenIType

-- | Report a record field error.
recordFieldError :: IType l a -> [Field l a] -> TypeError l a
recordFieldError ty =
  InvalidRecordFields (flattenIType ty) . fmap flattenField

-- | Flatten a field constraint for error reporting.
flattenField :: Field l a -> (FieldName, (Type l, a))
flattenField f =
  (fieldName f, flattenIType (fieldType f))
