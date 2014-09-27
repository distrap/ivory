{-# LANGUAGE OverloadedStrings #-}
--XXX testing
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleInstances #-}

module Ivory.ModelCheck where

import qualified Ivory.Language.Syntax       as I
import           Text.Printf
import           Ivory.ModelCheck.Ivory2CVC4
import           Ivory.ModelCheck.Monad
import           Ivory.ModelCheck.CVC4

import           System.FilePath.Posix
import           System.Directory
import           System.Process
import           System.IO
import           Control.Monad
import qualified Data.ByteString.Char8       as B

-- XXX testing
import Ivory.Language hiding (Struct, assert, true, false, proc, (.&&))
import qualified Ivory.Language as L
import Ivory.Compile.C.CmdlineFrontend

--------------------------------------------------------------------------------

data Args = Args
  { printQuery  :: Bool
  , printEnv    :: Bool
  , callCVC4    :: Bool
  , cvc4Path    :: FilePath
  , cvc4Args    :: [String]
  } deriving (Show, Eq)

initArgs :: Args
initArgs = Args
  { printQuery = True
  , printEnv   = True
  , callCVC4   = True
  , cvc4Path   =  ""
  , cvc4Args   = ["--incremental"]
  }

--------------------------------------------------------------------------------

modelCheck' :: I.Module -> IO ()
modelCheck' = modelCheck initArgs

modelCheck :: Args -> I.Module -> IO ()
modelCheck args m = do
  let (_, st) = runMC (modelCheckMod m)
  let bs = B.unlines (mkScript st)
  debugging args st bs
  file <- writeInput bs
  printResults st =<< runCVC4 args file

--------------------------------------------------------------------------------

debugging :: Args -> SymExecSt -> B.ByteString -> IO ()
debugging args st bs = do
  when (printQuery args) $ do
    putStrLn "**** QUERY ************************************"
    B.putStrLn bs
    putStrLn "***********************************************"
    putStrLn ""

  when (printEnv args) $ do
    putStrLn "**** ENV **************************************"
    print (symEnv st)
    putStrLn "***********************************************"
    putStrLn ""

--------------------------------------------------------------------------------

mkScript :: SymExecSt -> [B.ByteString]
mkScript st =
  [ "% Script auto-generated for model-checking Ivory function "
  , B.pack (funcSym st)
  , ""
  , "% CVC4 Lib -----------------------------------"
  , ""
  ] ++ (map concrete cvc4Lib)
  ++
  [ ""
  , "% user-defined types -------------------------"
  , ""
  ] ++ writeStmts (map typeDecl . types . symSt)
  ++
  [ ""
  , "% declarations -------------------------------"
  , ""
  ] ++ writeStmts (decls . symSt)
  ++
  [ ""
  , "% program encoding ---------------------------"
  , ""
  ] ++ writeStmts (map assert . invars . symSt)
  ++
  [ ""
  , "% queries ------------------------------------"
  , ""
  ] ++ writeStmts allQueries
  where
  writeStmts :: Concrete a
             => (SymExecSt -> [a])
             -> [B.ByteString]
  writeStmts f = map concrete (reverse $ f st)

-- | Are the assertions consistent?  If not, there's a bug in the
-- model-checking.
consistencyQuery :: Statement
consistencyQuery = query false

allQueries :: SymExecSt -> [Statement]
allQueries st =
  consistencyQuery : (map query . assertQueries . symQuery) st

-- | Write model inputs to a temp file.
writeInput :: B.ByteString -> IO FilePath
writeInput bs = do
  dir <- getTemporaryDirectory
  let tempDir = dir </> "cvc4-inputs"
  createDirectoryIfMissing False tempDir
  (file, hd) <- openTempFile tempDir "cvc4input.cvc"
  putStrLn $ "Created temp file " ++ file ++ "\n"
  B.hPut hd bs
  hClose hd
  return file

-- | Run cvc4 on the input file returning the results.
runCVC4 :: Args -> FilePath -> IO [String]
runCVC4 args file = do
  (_, Just hout, _, _) <- createProcess $ (proc exec execArgs)
      { std_out = CreatePipe }
  out <- hGetContents hout
  return (lines out)
  where
  exec     = cvc4Path args </> "cvc4"
  execArgs = cvc4Args args ++ [file]

printResults :: SymExecSt -> [String] -> IO ()
printResults st results = do
  let queries = map concrete
              $ reverse
              $ allQueries st
  let match = reverse (zip queries results)
  B.putStrLn "*** If \'Query FALSE\' is valid, the assertions are inconsistent. ***\n"
  mapM_ printRes match
  where
  printRes (q,res) = printf "%-30s : %s\n" (B.unpack q) res

--------------------------------------------------------------------------------
-- XXX testing

str :: B.ByteString
str = B.pack "QUERY TRUE;"

foo1 :: Def ('[Uint8, Uint8] :-> ())
foo1 = L.proc "foo1" $ \y x -> body $ do
  ifte_ (y <? 3)
    (do ifte_ (y ==? 3)
              (L.assert $ y ==? 0)
              retVoid)
    (do z <- assign x
        -- this *should* fail
        L.assert (z >=? 3))
  retVoid

m1 :: Module
m1 = package "foo1" (incl foo1)

-----------------------

foo2 :: Def ('[] :-> ())
foo2 = L.proc "foo2" $ body $ do
  x <- local (ival (0 :: Uint8))
  store x 3
  y <- assign x
  z <- deref y
  L.assert (z ==? 3)
  retVoid

m2 :: Module
m2 = package "foo2" (incl foo2)

-----------------------

foo3 :: Def ('[] :-> ())
foo3 = L.proc "foo3" $ body $ do
  x <- local (ival (1 :: Sint32))
  -- since ivory loops are bounded, we can just unroll the whole thing!
  for (toIx (2 :: Sint32) :: Ix 4) $ \ix -> do
    store x (fromIx ix)
    y <- deref x
    L.assert ((y <? 4) L..&& (y >=? 0))

m3 :: Module
m3 = package "foo3" (incl foo3)

-----------------------

foo4 :: Def ('[] :-> ())
foo4 = L.proc "foo4" $ body $ do
  x <- local (ival (1 :: Sint32))
  -- store x (7 .% 2)
  -- store x (4 .% 3)
  store x 1
  y <- deref x
  -- L.assert (y <? 2)
  L.assert (y ==? 1)

m4 :: Module
m4 = package "foo4" (incl foo4)

-----------------------

foo5 :: Def ('[] :-> ())
foo5 = L.proc "foo5" $ body $ do
  x <- local (ival (1 :: Sint32))
  -- for loops from 0 to n-1, inclusive
  for (toIx (9 :: Sint32) :: Ix 10) $ \ix -> do
    store x (fromIx ix)
    y <- deref x
    L.assert (y <=? 10)
  y <- deref x
  L.assert ((y ==? 8))

m5 :: Module
m5 = package "foo5" (incl foo5)

-----------------------

foo6 :: Def ('[Uint8] :-> ())
foo6 = L.proc "foo1" $ \x -> body $ do
  y <- local (ival (0 :: Uint8))
  ifte_ (x <? 3)
        (do a <- local (ival (9 :: Uint8))
            b <- deref a
            store y b
        )
        (do a <- local (ival (7 :: Uint8))
            b <- deref a
            store y b
        )
  z <- deref y
  L.assert (z <=? 9)
  L.assert (z >=? 7)

m6 :: Module
m6 = package "foo6" (incl foo6)

-----------------------

foo7 :: Def ('[Uint8, Uint8] :-> Uint8)
foo7 = L.proc "foo7" $ \x y -> body $ do
  ret (x + y)

m7 :: Module
m7 = package "foo7" (incl foo7)

-----------------------

foo8 :: Def ('[Uint8] :-> Uint8)
foo8 = L.proc "foo8" $ \x -> body $ do
  let y = x .% 3
  L.assert (y <? 4)
  ret y

m8 :: Module
m8 = package "foo8" (incl foo8)

-----------------------

[ivory|
struct foo
{ aFoo :: Stored Uint8
; bFoo :: Stored Uint8
}
|]

foo9 :: Def ('[Ref s (L.Struct "foo")] :-> ())
foo9 = L.proc "foo9" $ \f -> body $ do
  store (f ~> aFoo) 3
  store (f ~> bFoo) 1
  store (f ~> aFoo) 4
  x <- deref (f ~> aFoo)
  y <- deref (f ~> bFoo)
  L.assert (x ==? 4 L..&& y ==? 1)

m9 :: Module
m9 = package "foo9" (incl foo9)

-----------------------

foo10 :: Def ('[Uint8] :-> Uint8)
foo10 = L.proc "foo10" $ \x ->
        requires (x <? 10)
      $ ensures (\r -> r ==? x + 1)
      $ body $ do
        r <- assign $ x + 1
        ret r

m10 :: Module
m10 = package "foo10" (incl foo10)
    
-----------------------

foo11 :: Def ('[Ix 10] :-> ())
foo11 = L.proc "foo11" $ \n -> 
        requires (0 <=? n)
      $ requires (n <? 10)
      $ body $ do
          x <- local (ival (0 :: Sint8))
          for n $ \i -> do
            x' <- deref x
            store x $ x' + safeCast i

m11 :: Module
m11 = package "foo11" (incl foo11)

-----------------------

foo12 :: Def ('[Uint8] :-> Uint8)
foo12 = L.proc "foo12" $ \n -> 
        body $ do
          ifte_ (n ==? 0)
            (ret n)
            (do n' <- L.call foo12 (n-1)
                ret (n' + 1))

m12 :: Module
m12 = package "foo12" (incl foo12)
