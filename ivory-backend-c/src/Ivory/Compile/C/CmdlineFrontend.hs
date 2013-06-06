{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}

module Ivory.Compile.C.CmdlineFrontend
  ( compile
  , compileWith
  , runCompiler
  , runCompilerWith
  , Opts(..)
  , initialOpts
  ) where

import qualified Paths_ivory_backend_c

import Control.Monad
import System.Console.CmdLib
import System.FilePath
import qualified System.FilePath.Posix as PFP
import System.Directory
import System.IO (withFile, IOMode(..))
import Data.List hiding (group)

import Text.PrettyPrint.Leijen hiding ((</>), group)

import Ivory.Language
import qualified Ivory.Compile.C as C
import qualified Ivory.Compile.C.SourceDeps as C
import qualified Ivory.Opts.ConstFold as O
import qualified Ivory.Opts.Overflow as O
import qualified Ivory.Opts.DivZero as O
import qualified Ivory.Opts.Index as O
import qualified Ivory.Opts.FP as O
import qualified Ivory.Opts.CFG as G

data Opts
  = Opts
    { stdOut      :: Bool
    , includeDir  :: FilePath
    , srcDir      :: FilePath
    -- dependencies
    , deps        :: [FilePath]
    , depPrefix   :: String
    , rtIncludeDir:: Maybe FilePath
    -- optimization passes
    , constFold   :: Bool
    , overflow    :: Bool
    , divZero     :: Bool
    , ixCheck     :: Bool
    , fpCheck     :: Bool
    , outProcSyms :: Bool
    -- CFG stuff
    , cfg         :: Bool
    , cfgDotDir   :: FilePath
    , cfgProc     :: [String]
    -- debugging
    , verbose     :: Bool
    } deriving (Eq, Data, Typeable)

instance Attributes Opts where
  attributes _ = group "Options"
    [ stdOut      %> [ Help "print to standard out only"
                     , Default False
                     ]
    , includeDir  %> [ Help "output directory for header files"
                     , ArgHelp "PATH"
                     , Default "."
                     ]
    , srcDir      %> [ Help "output directory for source files"
                     , ArgHelp "PATH"
                     , Default "."
                     ]
    , rtIncludeDir%> [ Help "path to ivory runtime includes"
                     , ArgHelp "PATH"
                     , Default (Nothing :: Maybe FilePath)
                     ]
    , constFold   %> [ Help "constant folding."
                     , Default False
                     , Invertible True
                     ]
    , overflow    %> [ Help "generate assertions checking for arithmetic overflow/underflow."
                     , Default False
                     , Invertible True
                     ]
    , divZero     %> [ Help "generate assertions checking for division by zero."
                     , Default False
                     , Invertible True
                     ]
    , ixCheck     %> [ Help "generate assertions checking for back indexes (e.g., negative)."
                     , Default False
                     , Invertible True
                     ]
    , fpCheck     %> [ Help "generate assertions checking for NaN and Infinitiy."
                     , Default False
                     , Invertible True
                     ]
    , outProcSyms %> [ Help "write to standard out the modules' function symbols."
                     ]
    -- CFG stuff
    , cfg         %> [ Help "Output control-flow graph and max stack usage."
                     , Default False
                     , Invertible True
                     ]
    , cfgDotDir   %> [ Help "output directory for CDG Graphviz file."
                     , ArgHelp "PATH"
                     , Default "."
                     ]
    , cfgProc     %> [ Help "entry function(s) for CFG computation."
                     , ArgHelp "[proc0, proc1, ...]"
                     , Default ([] :: [String])
                     ]
    , verbose     %> [ Help "verbose debugging output"
                     , Default False
                     , Invertible True
                     ]
    ]

instance RecordCommand Opts where
  mode_summary _  = "Ivory compilation frontend"

initialOpts :: Opts
initialOpts = Opts
  { stdOut      = False
  , includeDir  = "."
  , srcDir      = "."
  , rtIncludeDir= Nothing
  -- dependencies
  , deps        = []
  , depPrefix   = "."
  -- optimization passes
  , constFold   = True -- ^ Turn on constant folding by default
  , divZero     = True -- ^ Turn on div-by-zero checking by default
  , ixCheck     = True -- ^ Turn on index-bounds checking by default
  , overflow    = False
  , fpCheck     = False
  , outProcSyms = False
  -- CFG stuff
  , cfg         = False
  , cfgDotDir   = "."
  , cfgProc     = ["main"]
  -- debugging
  , verbose     = False
  }

compile :: [Module] -> IO ()
compile = compileWith Nothing Nothing

compileWith :: Maybe G.SizeMap -> Maybe [IO FilePath] -> [Module] -> IO ()
compileWith sm sp ms = runCompilerWith sm sp ms =<< executeR initialOpts =<< getArgs

runCompilerWith :: Maybe G.SizeMap -> Maybe [IO FilePath] -> [Module] -> Opts -> IO ()
runCompilerWith sm sp =
  rc (maybe G.defaultSizeMap id sm) (maybe [] id sp)

runCompiler :: [Module] -> Opts -> IO ()
runCompiler = runCompilerWith Nothing Nothing

rc :: G.SizeMap -> [IO FilePath] -> [Module] -> Opts -> IO ()
rc sm userSearchPath modules opts
  | outProcSyms opts = C.outputProcSyms modules
  | printDeps        = runDeps
  | otherwise        = do
    if stdOut opts then mapM_ showM_ cmodules else run
    -- CFG stuff
    when (cfg opts) $ do
      cfs <- mapM (\p -> G.callGraphDot p (cfgDotDir opts) optModules) cfgps
      let maxstacks = map ms (zip cfgps cfs)
      mapM_ maxStackMsg (zip cfgps maxstacks)
  where
  run = do
    searchPath <- mkSearchPath opts userSearchPath
    createDirectoryIfMissing True (includeDir opts)
    createDirectoryIfMissing True (srcDir opts)
    outputHeaders (includeDir opts) cmodules
    outputSources (srcDir opts) cmodules
    C.outputSourceDeps (includeDir opts) (srcDir opts)
       ("runtime/ivory.h":(C.collectSourceDeps modules)) searchPath

  runDeps =
    outputDeps (deps opts) (depPrefix opts) (genHs ++ cpyHs) (genSs ++ cpySs)
    where
    sdeps = C.collectSourceDeps modules
    genHs = map (mkDep (includeDir opts) ".h") cmodules
    genSs = map (mkDep (srcDir opts) ".c")     cmodules
    cpyHs = map (mkDepSourceDep (includeDir opts)) $
              filter (\p -> takeExtension p == ".h") sdeps
    cpySs = map (mkDepSourceDep (srcDir opts)) $
              filter (\p -> takeExtension p == ".c") sdeps

  optModules = map (C.runOpt passes) modules

  cfgps = cfgProc opts

  ms (p, cf) = G.maxStack p cf sm
  maxStackMsg :: (String, G.WithTop Integer) -> IO ()
  maxStackMsg (p,res) =
    putStrLn $ "Maximum stack usage from function " ++ p ++ ": " ++ show res

  cmodules   = map C.compileModule optModules

  printDeps = case deps opts of
    []  -> False
    [_] -> True
    _   -> error "invalid option for deps"

  showM_ mods = do
    mapM_ (mapM_ putStrLn) (C.showModule mods)

  cfPass = mkPass constFold O.constFold

  -- Put new assertion passes here and add them to passes below.
  ofPass = mkPass overflow O.overflowFold
  dzPass = mkPass divZero O.divZeroFold
  fpPass = mkPass fpCheck O.fpFold
  ixPass = mkPass ixCheck O.ixFold

  mkPass passOpt pass = if passOpt opts then pass else id

  -- Constant folding before and after all other passes.
  passes e = foldl' (flip ($)) e
    [ cfPass
    , ofPass, dzPass, fpPass, ixPass
    , cfPass
    ]

  -- Output headers in a directory
  outputHeaders :: FilePath -> [C.CompileUnits] -> IO ()
  outputHeaders fp cus = mapM_ (process outputHeader fp) cus
  -- Output sources in a directory
  outputSources :: FilePath -> [C.CompileUnits] -> IO ()
  outputSources fp cus = mapM_ (process outputSrc fp) cus

  process outputter dir m = outputter (dir </> (C.unitName m)) m

  -- Transform a compiled unit into a header, and write to a .h file
  outputHeader :: FilePath -> C.CompileUnits -> IO ()
  outputHeader basename cm = do
    C.writeHdr (verbose opts) (addExtension basename ".h")
               (C.headers cm) (C.unitName cm)

  -- Transform a compiled unit into a c src, and write to a .c file
  outputSrc :: FilePath -> C.CompileUnits -> IO ()
  outputSrc basename cm = do
    C.writeSrc (verbose opts) (addExtension basename ".c")
               (C.sources cm)

--------------------------------------------------------------------------------

mkDep :: FilePath -> String -> C.CompileUnits -> String
mkDep basepath extension unit = basepath PFP.</> (C.unitName unit) PFP.<.> extension

mkDepSourceDep :: FilePath -> FilePath -> String
mkDepSourceDep basepath sdep = basepath PFP.</> sdep

outputDeps :: [FilePath] -> String -> [String] -> [String] -> IO ()
outputDeps [path] prefix headers sources = do
  createDirectoryIfMissing True (takeDirectory path)
  withFile path WriteMode writedoc
  where
  writedoc h = displayIO h rendered
  rendered = renderPretty 1.0 w d
  w = 10000000 -- don't ever wrap lines - invalid make syntax
  d = vsep $
    [ text "# dep file autogenerated by ivory compiler"
    , empty
    , listof (prefix ++ "_HEADERS") headers
    , empty
    , listof (prefix ++ "_SOURCES") sources
    ]
  declaration n = text n <+> text ":= \\" <> line
  listof name values = declaration name <>
    (indent 4 $ vsep $ punctuate (text " \\") (map text values))
outputDeps _ _ _ _ = error "invalid dep path (should be prevented by caller)"


mkSearchPath :: Opts -> [IO FilePath] -> IO [FilePath]
mkSearchPath opts userSearchPaths = do
  rtPath <- getRtPath
  users <- sequence userSearchPaths
  return $ rtPath:users
  where
  getRtPath :: IO FilePath
  getRtPath  = case rtIncludeDir opts of
    Just path -> return path
    Nothing   -> Paths_ivory_backend_c.getDataDir

