-- XXX testing
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}

--
-- C-like syntax for Ivory.
--
-- Copyright (C) 2014, Galois, Inc.
-- All rights reserved.
--

module Ivory.Language.CSyntax where

import Ivory.Language.CSyntax.QQ

-- XXX testing
import Ivory.Language

foo0 :: Def ('[] :-> Sint32)
foo0 = proc "foo" $ body [c|
  alloc *x = 3;
  *x = 4;
  return *x + 4;

|]

foo1 :: Def ('[] :-> Sint32)
foo1 = proc "foo" $ body [c|
  if (true) {
    let a = 5;
    return a;
  -- goo
  }
  else {
    let b = 3;
    return b + 3;
  }
|]

foo2 :: Def ('[] :-> ())
foo2 = proc "foo" $ body [c|
  if (true) {
    return;
  }
  else {
    return ;
  }
|]

e = (4::Sint32) >? 3

foo3 :: Def ('[] :-> IBool)
foo3 = proc "foo" $ body [c|
  return :i e;
|]

-- foo6 :: Def ('[Ref s (Array 3 (Stored Uint32))] :-> Uint32)
-- foo6 = proc "foo" $ \arr -> body [c|
--   alloc arr[30] = {0};
--   return arr[1];
-- |]

foo4 :: Def ('[Ref s (Array 3 (Stored Uint32))] :-> Uint32)
foo4 = proc "foo" $ \arr0 -> body $ do
  arr1 <- local (iarray (map ival [1,2,3]))
  arrayMap $ \ix -> do
    x <- deref (arr1 ! ix)
    store (arr0 ! ix) x
  y <- deref (arr0 ! 1)
  ret y

foo6 :: Def ('[Ref s (Array 3 (Stored Uint32))] :-> Uint32)
foo6 = proc "foo" $ \arr0 -> body [c|
  alloc arr1[] = {1,2,3};
  map ix {
    arr0[ix] = arr1[ix];
  }
  return arr0[1];
|]

--   -- alloc foo[] = {1,2, 4};
--   return arr [1] ;
