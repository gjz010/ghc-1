{-# LANGUAGE CPP, FlexibleInstances, UnboxedTuples, MagicHash #-}
{-# OPTIONS_GHC -fno-cse -fno-warn-orphans #-}
-- -fno-cse is needed for GLOBAL_VAR's to behave properly

-----------------------------------------------------------------------------
--
-- Monadery code used in InteractiveUI
--
-- (c) The GHC Team 2005-2006
--
-----------------------------------------------------------------------------

module GHCi.UI.Monad (
        GHCi(..), startGHCi,
        GHCiState(..), GhciMonad(..),
        GHCiOption(..), isOptionSet, setOption, unsetOption,
        Command(..), CommandResult(..), cmdSuccess,
        PromptFunction,
        BreakLocation(..),
        TickArray,
        getDynFlags,

        runStmt, runDecls, runDecls', resume, recordBreak, revertCAFs,
        ActionStats(..), runAndPrintStats, runWithStats, printStats,

        printForUserNeverQualify, printForUserModInfo,
        printForUser, printForUserPartWay, prettyLocations,

        compileGHCiExpr,
        initInterpBuffering,
        turnOffBuffering, turnOffBuffering_,
        flushInterpBuffers,
        mkEvalWrapper
    ) where

#include "HsVersions.h"

import GHCi.UI.Info (ModInfo)
import qualified GHC
import GhcMonad         hiding (liftIO)
import Outputable       hiding (printForUser, printForUserPartWay)
import qualified Outputable
import DynFlags
import FastString
import HscTypes
import SrcLoc
import Module
import GHCi
import GHCi.RemoteTypes
import HsSyn (ImportDecl, GhcPs, GhciLStmt, LHsDecl)
import Util

import Exception
import Numeric
import Data.Array
import Data.IORef
import Data.Time
import System.Environment
import System.IO
import Control.Monad
import Prelude hiding ((<>))

import System.Console.Haskeline (CompletionFunc, InputT)
import qualified System.Console.Haskeline as Haskeline
import Control.Monad.Trans.Class
import Control.Monad.IO.Class
import Data.Map.Strict (Map)
import qualified GHC.LanguageExtensions as LangExt

-----------------------------------------------------------------------------
-- GHCi monad

data GHCiState = GHCiState
     {
        progname       :: String,
        args           :: [String],
        evalWrapper    :: ForeignHValue, -- ^ of type @IO a -> IO a@
        prompt         :: PromptFunction,
        prompt_cont    :: PromptFunction,
        editor         :: String,
        stop           :: String,
        options        :: [GHCiOption],
        line_number    :: !Int,         -- ^ input line
        break_ctr      :: !Int,
        breaks         :: ![(Int, BreakLocation)],
        tickarrays     :: ModuleEnv TickArray,
            -- ^ 'tickarrays' caches the 'TickArray' for loaded modules,
            -- so that we don't rebuild it each time the user sets
            -- a breakpoint.
        ghci_commands  :: [Command],
            -- ^ available ghci commands
        ghci_macros    :: [Command],
            -- ^ user-defined macros
        last_command   :: Maybe Command,
            -- ^ @:@ at the GHCi prompt repeats the last command, so we
            -- remember it here
        cmd_wrapper    :: InputT GHCi CommandResult -> InputT GHCi (Maybe Bool),
            -- ^ The command wrapper is run for each command or statement.
            -- The 'Bool' value denotes whether the command is successful and
            -- 'Nothing' means to exit GHCi.
        cmdqueue       :: [String],

        remembered_ctx :: [InteractiveImport],
            -- ^ The imports that the user has asked for, via import
            -- declarations and :module commands.  This list is
            -- persistent over :reloads (but any imports for modules
            -- that are not loaded are temporarily ignored).  After a
            -- :load, all the home-package imports are stripped from
            -- this list.
            --
            -- See bugs #2049, #1873, #1360

        transient_ctx  :: [InteractiveImport],
            -- ^ An import added automatically after a :load, usually of
            -- the most recently compiled module.  May be empty if
            -- there are no modules loaded.  This list is replaced by
            -- :load, :reload, and :add.  In between it may be modified
            -- by :module.

        extra_imports  :: [ImportDecl GhcPs],
            -- ^ These are "always-on" imports, added to the
            -- context regardless of what other imports we have.
            -- This is useful for adding imports that are required
            -- by setGHCiMonad.  Be careful adding things here:
            -- you can create ambiguities if these imports overlap
            -- with other things in scope.
            --
            -- NB. although this is not currently used by GHCi itself,
            -- it was added to support other front-ends that are based
            -- on the GHCi code.  Potentially we could also expose
            -- this functionality via GHCi commands.

        prelude_imports :: [ImportDecl GhcPs],
            -- ^ These imports are added to the context when
            -- -XImplicitPrelude is on and we don't have a *-module
            -- in the context.  They can also be overridden by another
            -- import for the same module, e.g.
            -- "import Prelude hiding (map)"

        ghc_e :: Bool, -- ^ True if this is 'ghc -e' (or runghc)

        short_help :: String,
            -- ^ help text to display to a user
        long_help  :: String,
        lastErrorLocations :: IORef [(FastString, Int)],

        mod_infos  :: !(Map ModuleName ModInfo),

        flushStdHandles :: ForeignHValue,
            -- ^ @hFlush stdout; hFlush stderr@ in the interpreter
        noBuffering :: ForeignHValue
            -- ^ @hSetBuffering NoBuffering@ for stdin/stdout/stderr
     }

type TickArray = Array Int [(GHC.BreakIndex,RealSrcSpan)]

-- | A GHCi command
data Command
   = Command
   { cmdName           :: String
     -- ^ Name of GHCi command (e.g. "exit")
   , cmdAction         :: String -> InputT GHCi Bool
     -- ^ The 'Bool' value denotes whether to exit GHCi
   , cmdHidden         :: Bool
     -- ^ Commands which are excluded from default completion
     -- and @:help@ summary. This is usually set for commands not
     -- useful for interactive use but rather for IDEs.
   , cmdCompletionFunc :: CompletionFunc GHCi
     -- ^ 'CompletionFunc' for arguments
   }

data CommandResult
   = CommandComplete
   { cmdInput :: String
   , cmdResult :: Either SomeException (Maybe Bool)
   , cmdStats :: ActionStats
   }
   | CommandIncomplete
     -- ^ Unterminated multiline command
   deriving Show

cmdSuccess :: Haskeline.MonadException m => CommandResult -> m (Maybe Bool)
cmdSuccess CommandComplete{ cmdResult = Left e } = liftIO $ throwIO e
cmdSuccess CommandComplete{ cmdResult = Right r } = return r
cmdSuccess CommandIncomplete = return $ Just True

type PromptFunction = [String]
                   -> Int
                   -> GHCi SDoc

data GHCiOption
        = ShowTiming            -- show time/allocs after evaluation
        | ShowType              -- show the type of expressions
        | RevertCAFs            -- revert CAFs after every evaluation
        | Multiline             -- use multiline commands
        | CollectInfo           -- collect and cache information about
                                -- modules after load
        deriving Eq

data BreakLocation
   = BreakLocation
   { breakModule :: !GHC.Module
   , breakLoc    :: !SrcSpan
   , breakTick   :: {-# UNPACK #-} !Int
   , onBreakCmd  :: String
   }

instance Eq BreakLocation where
  loc1 == loc2 = breakModule loc1 == breakModule loc2 &&
                 breakTick loc1   == breakTick loc2

prettyLocations :: [(Int, BreakLocation)] -> SDoc
prettyLocations []   = text "No active breakpoints."
prettyLocations locs = vcat $ map (\(i, loc) -> brackets (int i) <+> ppr loc) $ reverse $ locs

instance Outputable BreakLocation where
   ppr loc = (ppr $ breakModule loc) <+> ppr (breakLoc loc) <+>
                if null (onBreakCmd loc)
                   then Outputable.empty
                   else doubleQuotes (text (onBreakCmd loc))

recordBreak
  :: GhciMonad m => BreakLocation -> m (Bool{- was already present -}, Int)
recordBreak brkLoc = do
   st <- getGHCiState
   let oldActiveBreaks = breaks st
   -- don't store the same break point twice
   case [ nm | (nm, loc) <- oldActiveBreaks, loc == brkLoc ] of
     (nm:_) -> return (True, nm)
     [] -> do
      let oldCounter = break_ctr st
          newCounter = oldCounter + 1
      setGHCiState $ st { break_ctr = newCounter,
                          breaks = (oldCounter, brkLoc) : oldActiveBreaks
                        }
      return (False, oldCounter)

newtype GHCi a = GHCi { unGHCi :: IORef GHCiState -> Ghc a }

reflectGHCi :: (Session, IORef GHCiState) -> GHCi a -> IO a
reflectGHCi (s, gs) m = unGhc (unGHCi m gs) s

startGHCi :: GHCi a -> GHCiState -> Ghc a
startGHCi g state = do ref <- liftIO $ newIORef state; unGHCi g ref

instance Functor GHCi where
    fmap = liftM

instance Applicative GHCi where
    pure a = GHCi $ \_ -> pure a
    (<*>) = ap

instance Monad GHCi where
  (GHCi m) >>= k  =  GHCi $ \s -> m s >>= \a -> unGHCi (k a) s

class GhcMonad m => GhciMonad m where
  getGHCiState    :: m GHCiState
  setGHCiState    :: GHCiState -> m ()
  modifyGHCiState :: (GHCiState -> GHCiState) -> m ()
  reifyGHCi       :: ((Session, IORef GHCiState) -> IO a) -> m a

instance GhciMonad GHCi where
  getGHCiState      = GHCi $ \r -> liftIO $ readIORef r
  setGHCiState s    = GHCi $ \r -> liftIO $ writeIORef r s
  modifyGHCiState f = GHCi $ \r -> liftIO $ modifyIORef r f
  reifyGHCi f       = GHCi $ \r -> reifyGhc $ \s -> f (s, r)

instance GhciMonad (InputT GHCi) where
  getGHCiState    = lift getGHCiState
  setGHCiState    = lift . setGHCiState
  modifyGHCiState = lift . modifyGHCiState
  reifyGHCi       = lift . reifyGHCi

liftGhc :: Ghc a -> GHCi a
liftGhc m = GHCi $ \_ -> m

instance MonadIO GHCi where
  liftIO = liftGhc . liftIO

instance HasDynFlags GHCi where
  getDynFlags = getSessionDynFlags

instance GhcMonad GHCi where
  setSession s' = liftGhc $ setSession s'
  getSession    = liftGhc $ getSession

instance HasDynFlags (InputT GHCi) where
  getDynFlags = lift getDynFlags

instance GhcMonad (InputT GHCi) where
  setSession = lift . setSession
  getSession = lift getSession

instance ExceptionMonad GHCi where
  gcatch m h = GHCi $ \r -> unGHCi m r `gcatch` (\e -> unGHCi (h e) r)
  gmask f =
      GHCi $ \s -> gmask $ \io_restore ->
                             let
                                g_restore (GHCi m) = GHCi $ \s' -> io_restore (m s')
                             in
                                unGHCi (f g_restore) s

instance Haskeline.MonadException Ghc where
  controlIO f = Ghc $ \s -> Haskeline.controlIO $ \(Haskeline.RunIO run) -> let
                    run' = Haskeline.RunIO (fmap (Ghc . const) . run . flip unGhc s)
                    in fmap (flip unGhc s) $ f run'

instance Haskeline.MonadException GHCi where
  controlIO f = GHCi $ \s -> Haskeline.controlIO $ \(Haskeline.RunIO run) -> let
                    run' = Haskeline.RunIO (fmap (GHCi . const) . run . flip unGHCi s)
                    in fmap (flip unGHCi s) $ f run'

instance ExceptionMonad (InputT GHCi) where
  gcatch = Haskeline.catch
  gmask f = Haskeline.liftIOOp gmask (f . Haskeline.liftIOOp_)

isOptionSet :: GhciMonad m => GHCiOption -> m Bool
isOptionSet opt
 = do st <- getGHCiState
      return (opt `elem` options st)

setOption :: GhciMonad m => GHCiOption -> m ()
setOption opt
 = do st <- getGHCiState
      setGHCiState (st{ options = opt : filter (/= opt) (options st) })

unsetOption :: GhciMonad m => GHCiOption -> m ()
unsetOption opt
 = do st <- getGHCiState
      setGHCiState (st{ options = filter (/= opt) (options st) })

printForUserNeverQualify :: GhcMonad m => SDoc -> m ()
printForUserNeverQualify doc = do
  dflags <- getDynFlags
  liftIO $ Outputable.printForUser dflags stdout neverQualify doc

printForUserModInfo :: GhcMonad m => GHC.ModuleInfo -> SDoc -> m ()
printForUserModInfo info doc = do
  dflags <- getDynFlags
  mUnqual <- GHC.mkPrintUnqualifiedForModule info
  unqual <- maybe GHC.getPrintUnqual return mUnqual
  liftIO $ Outputable.printForUser dflags stdout unqual doc

printForUser :: GhcMonad m => SDoc -> m ()
printForUser doc = do
  unqual <- GHC.getPrintUnqual
  dflags <- getDynFlags
  liftIO $ Outputable.printForUser dflags stdout unqual doc

printForUserPartWay :: GhcMonad m => SDoc -> m ()
printForUserPartWay doc = do
  unqual <- GHC.getPrintUnqual
  dflags <- getDynFlags
  liftIO $ Outputable.printForUserPartWay dflags stdout (pprUserLength dflags) unqual doc

-- | Run a single Haskell expression
runStmt
  :: GhciMonad m
  => GhciLStmt GhcPs -> String -> GHC.SingleStep -> m (Maybe GHC.ExecResult)
runStmt stmt stmt_text step = do
  st <- getGHCiState
  GHC.handleSourceError (\e -> do GHC.printException e; return Nothing) $ do
    let opts = GHC.execOptions
                  { GHC.execSourceFile = progname st
                  , GHC.execLineNumber = line_number st
                  , GHC.execSingleStep = step
                  , GHC.execWrap = \fhv -> EvalApp (EvalThis (evalWrapper st))
                                                   (EvalThis fhv) }
    Just <$> GHC.execStmt' stmt stmt_text opts

runDecls :: GhciMonad m => String -> m (Maybe [GHC.Name])
runDecls decls = do
  st <- getGHCiState
  reifyGHCi $ \x ->
    withProgName (progname st) $
    withArgs (args st) $
      reflectGHCi x $ do
        GHC.handleSourceError (\e -> do GHC.printException e;
                                        return Nothing) $ do
          r <- GHC.runDeclsWithLocation (progname st) (line_number st) decls
          return (Just r)

runDecls' :: GhciMonad m => [LHsDecl GhcPs] -> m (Maybe [GHC.Name])
runDecls' decls = do
  st <- getGHCiState
  reifyGHCi $ \x ->
    withProgName (progname st) $
    withArgs (args st) $
    reflectGHCi x $
      GHC.handleSourceError
        (\e -> do GHC.printException e;
                  return Nothing)
        (Just <$> GHC.runParsedDecls decls)

resume :: GhciMonad m => (SrcSpan -> Bool) -> GHC.SingleStep -> m GHC.ExecResult
resume canLogSpan step = do
  st <- getGHCiState
  reifyGHCi $ \x ->
    withProgName (progname st) $
    withArgs (args st) $
      reflectGHCi x $ do
        GHC.resumeExec canLogSpan step

-- --------------------------------------------------------------------------
-- timing & statistics

data ActionStats = ActionStats
  { actionAllocs :: Maybe Integer
  , actionElapsedTime :: Double
  } deriving Show

runAndPrintStats
  :: GhciMonad m
  => (a -> Maybe Integer)
  -> m a
  -> m (ActionStats, Either SomeException a)
runAndPrintStats getAllocs action = do
  result <- runWithStats getAllocs action
  case result of
    (stats, Right{}) -> do
      showTiming <- isOptionSet ShowTiming
      when showTiming $ do
        dflags  <- getDynFlags
        liftIO $ printStats dflags stats
    _ -> return ()
  return result

runWithStats
  :: ExceptionMonad m
  => (a -> Maybe Integer) -> m a -> m (ActionStats, Either SomeException a)
runWithStats getAllocs action = do
  t0 <- liftIO getCurrentTime
  result <- gtry action
  let allocs = either (const Nothing) getAllocs result
  t1 <- liftIO getCurrentTime
  let elapsedTime = realToFrac $ t1 `diffUTCTime` t0
  return (ActionStats allocs elapsedTime, result)

printStats :: DynFlags -> ActionStats -> IO ()
printStats dflags ActionStats{actionAllocs = mallocs, actionElapsedTime = secs}
   = do let secs_str = showFFloat (Just 2) secs
        putStrLn (showSDoc dflags (
                 parens (text (secs_str "") <+> text "secs" <> comma <+>
                         case mallocs of
                           Nothing -> empty
                           Just allocs ->
                             text (separateThousands allocs) <+> text "bytes")))
  where
    separateThousands n = reverse . sep . reverse . show $ n
      where sep n'
              | n' `lengthAtMost` 3 = n'
              | otherwise           = take 3 n' ++ "," ++ sep (drop 3 n')

-----------------------------------------------------------------------------
-- reverting CAFs

revertCAFs :: GhciMonad m => m ()
revertCAFs = do
  hsc_env <- GHC.getSession
  liftIO $ iservCmd hsc_env RtsRevertCAFs
  s <- getGHCiState
  when (not (ghc_e s)) turnOffBuffering
     -- Have to turn off buffering again, because we just
     -- reverted stdout, stderr & stdin to their defaults.


-----------------------------------------------------------------------------
-- To flush buffers for the *interpreted* computation we need
-- to refer to *its* stdout/stderr handles

-- | Compile "hFlush stdout; hFlush stderr" once, so we can use it repeatedly
initInterpBuffering :: Ghc (ForeignHValue, ForeignHValue)
initInterpBuffering = do
  nobuf <- compileGHCiExpr $
   "do { System.IO.hSetBuffering System.IO.stdin System.IO.NoBuffering; " ++
       " System.IO.hSetBuffering System.IO.stdout System.IO.NoBuffering; " ++
       " System.IO.hSetBuffering System.IO.stderr System.IO.NoBuffering }"
  flush <- compileGHCiExpr $
   "do { System.IO.hFlush System.IO.stdout; " ++
       " System.IO.hFlush System.IO.stderr }"
  return (nobuf, flush)

-- | Invoke "hFlush stdout; hFlush stderr" in the interpreter
flushInterpBuffers :: GhciMonad m => m ()
flushInterpBuffers = do
  st <- getGHCiState
  hsc_env <- GHC.getSession
  liftIO $ evalIO hsc_env (flushStdHandles st)

-- | Turn off buffering for stdin, stdout, and stderr in the interpreter
turnOffBuffering :: GhciMonad m => m ()
turnOffBuffering = do
  st <- getGHCiState
  turnOffBuffering_ (noBuffering st)

turnOffBuffering_ :: GhcMonad m => ForeignHValue -> m ()
turnOffBuffering_ fhv = do
  hsc_env <- getSession
  liftIO $ evalIO hsc_env fhv

mkEvalWrapper :: GhcMonad m => String -> [String] ->  m ForeignHValue
mkEvalWrapper progname args =
  compileGHCiExpr $
    "\\m -> System.Environment.withProgName " ++ show progname ++
    "(System.Environment.withArgs " ++ show args ++ " m)"

compileGHCiExpr :: GhcMonad m => String -> m ForeignHValue
compileGHCiExpr expr =
  withTempSession mkTempSession $ GHC.compileExprRemote expr
  where
    mkTempSession hsc_env = hsc_env
      { hsc_dflags = (hsc_dflags hsc_env) {
        -- Running GHCi's internal expression is incompatible with -XSafe.
          -- We temporarily disable any Safe Haskell settings while running
          -- GHCi internal expressions. (see #12509)
        safeHaskell = Sf_None
      }
        -- RebindableSyntax can wreak havoc with GHCi in several ways
          -- (see #13385 and #14342 for examples), so we temporarily
          -- disable it too.
          `xopt_unset` LangExt.RebindableSyntax
          -- We heavily depend on -fimplicit-import-qualified to compile expr
          -- with fully qualified names without imports.
          `gopt_set` Opt_ImplicitImportQualified
      }
