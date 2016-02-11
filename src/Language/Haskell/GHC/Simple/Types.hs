-- | Config, input and output types for the simplified GHC API.
module Language.Haskell.GHC.Simple.Types (
    -- * GHC pipeline configuration
    Intermediate (..),
    CompConfig,
    defaultConfig,
    cfgGhcFlags, cfgUseTargetsFromFlags, cfgUpdateDynFlags, cfgGhcLibDir,
    cfgUseGhcErrorLogger, cfgCustomPrimIface, cfgStopPhases,
    cfgCacheDirectory, cfgCacheFileExt,

    -- * Convenience functions for common settings combinations
    ncgPhases, disableCodeGen,

    -- * Compilation results and errors
    ModMetadata (..),
    CompiledModule (..),
    CompResult (..),
    Error (..),
    Warning (..),
    compSuccess
  ) where

import GHC
import HscTypes (CgGuts)
import DriverPhases
import DriverPipeline (CompPipeline)
import Language.Haskell.GHC.Simple.PrimIface
import Data.Binary (Binary)

-- | An intermediate source language, usable as the the input for a
--   'Compile' compilation function.
class Intermediate a where
  prepare :: ModSummary -> CgGuts -> CompPipeline a

-- | GHC pipeline configuration, parameterized over the intermediate code
--   produced by the pipeline.
data CompConfig = CompConfig {
    -- | GHC command line dynamic flags to control the Haskell to STG
    --   compilation pipeline.
    --   For instance, passing @["-O2", "-DHELLO"]@ here is equivalent to
    --   passing @-O2 -DHELLO@ to the @ghc@ binary.
    --
    --   Note that flags set here are overridden by any changes to 'DynFlags'
    --   performed by 'cfgUpdateDynFlags', and that '--make' mode is always
    --   in effect.
    --
    --   Default: @[]@
    cfgGhcFlags :: [String],

    -- | If file or module names are found among the 'cfgGhcFlags',
    --   should they be used as targets, in addition to any targets given by
    --   other arguments to 'withStg' et al?
    --
    --   Default: @True@
    cfgUseTargetsFromFlags :: Bool,

    -- | Modify the dynamic flags governing the compilation process.
    --   Changes made here take precedence over any flags passed through
    --   'cfgGhcFlags'.
    --
    --   Default: @id@
    cfgUpdateDynFlags :: DynFlags -> DynFlags,

    -- | Use GHC's standard logger to log errors and warnings to the command
    --   line? Errors and warnings are always collected and returned,
    --   regardless of the value of this setting.
    --
    --   Output other than errors and warnings (dumps, etc.) are logged using
    --   the standard logger by default. For finer control over logging
    --   behavior, you should override 'log_action' in 'cfgUpdateDynFlags'.
    --
    --   Default: @False@
    cfgUseGhcErrorLogger :: Bool,

    -- | Path to GHC's library directory. If 'Nothing', the library directory
    --   of the system's default GHC compiler will be used.
    --
    --   Default: @Nothing@
    cfgGhcLibDir :: Maybe FilePath,

    -- | Use a custom interface for @GHC.Prim@.
    --   This is useful if you want to, for instance, compile to a 32 bit
    --   target architecture on a 64 bit host.
    --
    --   For more information, see "Language.Haskell.GHC.Simple.PrimIface".
    --
    --   Default: @Nothing@
    cfgCustomPrimIface :: Maybe (PrimOp -> PrimOpInfo,
                                 PrimOp -> Arity -> StrictSig),

    -- | Cache directory for compiled code. If @Nothing@, the current directory
    --   is used.
    --
    --   Default: @Nothing@
    cfgCacheDirectory :: Maybe FilePath,

    -- | File extension of cache files.
    --
    --   Default: @cache@
    cfgCacheFileExt :: String,
    
    -- | Stop compilation when any of these this phases are reached,
    --   without performing it. If you are doing custom code generation and
    --   don't want GHC to generate any code - for instance when writing a
    --   cross compiler - you will probably want to set this to
    --   @ncgPhases@.
    --
    --   Default: @[]@
    cfgStopPhases :: [Phase]
  }

-- | Default configuration.
defaultConfig :: CompConfig
defaultConfig = CompConfig {
    cfgGhcFlags            = [],
    cfgUseTargetsFromFlags = True,
    cfgUpdateDynFlags      = id,
    cfgUseGhcErrorLogger   = False,
    cfgGhcLibDir           = Nothing,
    cfgCustomPrimIface     = Nothing,
    cfgCacheDirectory      = Nothing,
    cfgCacheFileExt        = "cache",
    cfgStopPhases          = []
  }

-- | Phases in which the native code generator is invoked. You want to stop
--   at these phases when writing a cross compiler.
ncgPhases :: [Phase]
ncgPhases = [CmmCpp, Cmm, As False, As True]

-- | Disable any native code generation and linking.
disableCodeGen :: CompConfig -> CompConfig
disableCodeGen cfg = cfg {
      cfgStopPhases = ncgPhases,
      cfgUpdateDynFlags = asmTarget . cfgUpdateDynFlags cfg
    }
  where
    asmTarget dfs = dfs {hscTarget = HscAsm, ghcLink = NoLink}

-- | Compiler output and metadata for a given module.
data CompiledModule a = CompiledModule {    
    -- | Module data generated by compilation; usually bindings of some kind.
    modCompiledModule :: a,

    -- | Metadata for the compiled module.
    modMetadata :: ModMetadata,

    -- | Was the module a target of the current compilation, as opposed to
    --   a dependency of some target?
    modIsTarget :: Bool
  }

-- | Metadata for a module under compilation.
data ModMetadata = ModMetadata {
    -- | 'ModSummary' for the module, as given by GHC.
    mmSummary :: ModSummary,

    -- | String representation of the module's name, not qualified with a
    --   package key.
    --   'ModuleName' representation can be obtained from the module's
    --   'stgModSummary'.
    mmName :: String,

    -- | String representation of the module's package key.
    --   'PackageKey' representation can be obtained from the module's
    --   'stgModSummary'.
    mmPackageKey :: String,

    -- | Was the module compiler from a @hs-boot@ file?
    mmSourceIsHsBoot :: Bool,

    -- | The Haskell source the module was compiled from, if any.
    mmSourceFile :: Maybe FilePath,

    -- | Interface file corresponding to this module.
    mmInterfaceFile :: FilePath
  }

-- | A GHC error message.
data Error = Error {
    -- | Where did the error occur?
    errorSpan      :: SrcSpan,

    -- | Description of the error.
    errorMessage   :: String,

    -- | More verbose description of the error.
    errorExtraInfo :: String
  }

-- | A GHC warning.
data Warning = Warning {
    -- | Where did the warning occur?
    warnSpan :: SrcSpan,

    -- | What was the warning about?
    warnMessage :: String
  }

-- | Result of a compilation.
data CompResult a
  = Success {
      -- | Result of the compilation.
      compResult :: a,

      -- | Warnings that occurred during compilation.
      compWarnings :: [Warning],

      -- | Initial 'DynFlags' used by this compilation, collected from 'Config'
      --   data.
      compDynFlags :: DynFlags
    }
  | Failure {
      -- | Errors that occurred during compilation.
      compErrors :: [Error],

      -- | Warnings that occurred during compilation.
      compWarnings :: [Warning]
    }

-- | Does the given 'CompResult' represent a successful compilation?
compSuccess :: CompResult a -> Bool
compSuccess Success{} = True
compSuccess _         = False
