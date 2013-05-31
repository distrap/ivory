{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Factorial where

import Ivory.Interp
import Ivory.Language
import Ivory.Compile.C.CmdlineFrontend

factorial :: Def ('[Sint32] :-> Sint32)
factorial  = proc "factorial" $ \ n ->
  -- These are made up requires/ensures for testing purposes.
  ensures (\r -> n <? r) $
  body $
    ifte (n >? 1)
      (do n' <- call factorial (n - 1)
          ret (n' * n)
      )
      (do ret n
      )

cmodule :: Module
cmodule = package "Factorial" $ incl factorial

runFactorial :: IO ()
runFactorial = runCompiler [cmodule] initialOpts { stdOut = True }


test :: IO ()
test  = withEnv $ do
  loadModule cmodule

  n <- eval $ do
    res <- call factorial 10
    ret res

  io (putStrLn ("factorial 10 = " ++ show n))
