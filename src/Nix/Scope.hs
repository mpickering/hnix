{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Nix.Scope where

import Control.Applicative
import Control.Monad.Reader
import Data.Semigroup
import Data.Text (Text)
import Nix.AttrSet
import Nix.Utils

newtype Scope a = Scope { getScope :: AttrSet a }
    deriving (Functor, Foldable, Traversable)

instance Show a => Show (Scope a) where
    show (Scope m) = showAttrSet m

newScope :: AttrSet a -> Scope a
newScope = Scope

scopeLookup :: AttrSetEmbeds v => Text -> Scope v -> Maybe v
scopeLookup key (Scope m) = either embedAttrSet id <$> keyLookup key m

scopesLookup :: AttrSetEmbeds v => Text -> [Scope v] -> Maybe v
scopesLookup key = foldr (\m -> (scopeLookup key m <|>)) Nothing

data Scopes m v = Scopes
    { lexicalScopes :: [Scope v]
    , dynamicScopes :: [m (Scope v)]
    }

instance Show v => Show (Scopes m v) where
    show (Scopes m v) =
        "Scopes: " ++ show m ++ ", and "
            ++ show (length v) ++ " with-scopes"

instance Semigroup (Scopes m v) where
    Scopes ls lw <> Scopes rs rw = Scopes (ls <> rs) (lw <> rw)

instance Monoid (Scopes m v) where
    mempty  = emptyScopes
    mappend = (<>)

type Scoped e v m = (MonadReader e m, Has e (Scopes m v))

emptyScopes :: Scopes m v
emptyScopes = Scopes [] []

currentScopes :: Scoped e v m => m (Scopes m v)
currentScopes = asks (view hasLens)

clearScopes :: forall v m e r. Scoped e v m => m r -> m r
clearScopes = local (set hasLens (emptyScopes @m @v))

pushScope :: forall v m e r. Scoped e v m => AttrSet v -> m r -> m r
pushScope s = pushScopes (Scopes [Scope s] [])

pushWeakScope :: forall v m e r. Scoped e v m => m (AttrSet v) -> m r -> m r
pushWeakScope s = pushScopes (Scopes [] [Scope <$> s])

pushScopes :: Scoped e v m => Scopes m v -> m r -> m r
pushScopes s = local (over hasLens (s <>))

lookupVar :: forall e v m. (Scoped e v m, AttrSetEmbeds v, Monad m)
          => Text -> m (Maybe v)
lookupVar k = do
    mres <- asks (scopesLookup k . lexicalScopes @m . view hasLens)
    case mres of
        Just sym -> return $ Just sym
        Nothing -> do
            ws <- asks (dynamicScopes . view hasLens)
            foldr (\x -> liftM2 (<|>) (scopeLookup k <$> x))
                  (return Nothing) ws

withScopes :: forall v m e a. Scoped e v m => Scopes m v -> m a -> m a
withScopes scope = clearScopes @v . pushScopes scope
