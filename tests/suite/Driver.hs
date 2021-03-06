{-# LANGUAGE LambdaCase, MultiWayIf, CPP #-}

import System.FilePath
import System.Directory
import System.Directory.Extra
import System.FilePath.Glob
import System.Process (createProcess, waitForProcess, CreateProcess(..), StdStream(..))
import qualified System.Process as P
import System.Process.ByteString.Lazy
import System.IO
import System.IO.Unsafe
import System.Exit
import Control.Monad
import Data.Monoid
import Data.List
import Data.Set (Set)
import qualified Data.Set as S
import Control.DeepSeq
import Control.Exception
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Lazy.Char8 as BC

import Test.Tasty
import Test.Tasty.Golden.Advanced (goldenTest)

main :: IO ()
main = do
  exists <- doesDirectoryExist buildRootDir
  when exists $ removeDirectoryRecursive buildRootDir
  cp <- getDefaultClassPath
  suites <- createTestSuites cp rootDir
  defaultMain (testGroup "Eta Golden Tests" suites)

createTestSuites :: [FilePath] -> FilePath -> IO [TestTree]
createTestSuites cp rootDir = do
  suitePaths <- directoryListing rootDir
  forM suitePaths $ \suitePath -> do
    let suiteName = takeFileName suitePath
        isBackpack = "backpack" `isPrefixOf` suiteName
        (pattern, actionMode)
          | isBackpack = ("*.bkp", BackpackAction)
          | otherwise = ("*.hs", CompileAction)
        genTestGroup mode name ext = do
          let path = suitePath </> name
          exists <- doesDirectoryExist path
          if exists
          then do
            testFiles' <- globDir1 (compile pattern) path
            let testFiles = filterIgnored testFiles'
            testDirs'  <- directoryListing path
            let testDirs  = filterIgnored testDirs'
            tests1 <- forM testFiles $ \testFile -> do
                let testName   = takeBaseName testFile
                    builddir   = buildDir suiteName name testName
                    targetFile = builddir </> (testName <.> ext)
                    goldenFile = testFile -<.> ext
                return $ goldenVsFileDiff' testName
                        (\ref new -> ["diff", "-u", ref, new]) goldenFile targetFile
                        (etaAction cp mode builddir testFile targetFile)
            tests2 <- forM testDirs $ \testDir -> do
                let testName   = takeBaseName testDir
                    builddir   = buildDir suiteName name testName
                    targetFile = builddir </> (testName <.> ext)
                    goldenFile = testDir </> (testName <.> ext)
                return $ goldenVsFileDiff' testName
                        (\ref new -> ["diff", "-u", ref, new]) goldenFile targetFile
                        (etlasAction mode builddir testDir targetFile)
            return $ tests1 ++ tests2
          else return []

    compileGroup <- genTestGroup (actionMode CompileMode) "compile" "stderr"
    failGroup    <- genTestGroup (actionMode FailMode)    "fail"    "stderr"
    runGroup     <- genTestGroup (actionMode RunMode)     "run"     "stdout"
    return $ testGroup suiteName
        [ testGroup "compile" compileGroup
        , testGroup "fail"    failGroup
        , testGroup "run"     runGroup
        ]

data ActionMode = CompileAction  { actionResult :: ResultMode }  -- Invokes eta --make
                | BackpackAction { actionResult :: ResultMode }  -- Invoke eta --backpack

data ResultMode = CompileMode
                | FailMode
                | RunMode

etlasAction :: ActionMode -> FilePath -> FilePath -> FilePath -> IO ()
etlasAction mode builddir inputDir outputFile = do
  builddir <- makeAbsolute builddir
  createDirectoryIfMissing True builddir
  let (command, expectedExitCode, extraOpts) = case actionResult mode of
        CompileMode -> (["build"],
                        \case ExitSuccess   -> True
                              ExitFailure _ -> False,
                        ["all"])

        FailMode    -> (["build"],
                        \case ExitSuccess   -> False
                              ExitFailure _ -> True,
                        ["all"])
        RunMode     -> (["run"],
                        \case ExitSuccess   -> True
                              ExitFailure _ -> False,
                        [])
      options = command ++ ["-v0", "--builddir=" ++ builddir] ++ extraOpts
  (exitCode, stdout, stderr) <- readCreateProcessWithExitCode
                                  ((P.proc "etlas" options) { cwd = Just inputDir })
                                  mempty
  let mainOutput = stdout <> stderr
      output
        | not (expectedExitCode exitCode) = BC.pack (show exitCode ++ "\n") <> mainOutput
        | otherwise = mainOutput
  BS.writeFile outputFile output

etaAction :: [FilePath] -> ActionMode -> FilePath -> FilePath -> FilePath -> IO ()
etaAction defaultClassPath mode builddir srcFile outputFile = do
  createDirectoryIfMissing True builddir
  let (specificOptions, expectedExitCode, shouldRun) = case actionResult mode of
        CompileMode -> (if isBackpack then [] else ["-staticlib"],
                        \case ExitSuccess   -> True
                              ExitFailure _ -> False,
                        False)

        FailMode    -> (["-staticlib"],
                        \case ExitSuccess   -> False
                              ExitFailure _ -> True,
                        False)
        RunMode     -> (["-shared"],
                        \case ExitSuccess   -> True
                              ExitFailure _ -> False,
                        True)
      outFlags = ["-o", outJar]
      (isBackpack, outputOptions)
        | BackpackAction {} <- mode = (True, outFlags)
        | otherwise = (False, outFlags)
      (modeOptions, extraModeOptions) = case mode of
        CompileAction {}  -> (["--make"], ["-v0"])
        BackpackAction {} -> (["--backpack"], [])
      outJar = builddir </> "Out.jar"
      options = modeOptions ++ [srcFile] ++ specificOptions ++ extraModeOptions
                            ++ genericEtaOptions
                            ++ ["-outputdir", builddir, "-cp", mkClassPath defaultClassPath]
                            ++ outputOptions

      procConfig = P.proc "eta" options
  (exitCode', stdout', stderr') <- readCreateProcessWithExitCode procConfig mempty
  let getOutput
        | shouldRun = do
          (exitCode, stdout, stderr) <-
            if expectedExitCode exitCode'
            then do
              let getClasspath
                    | isBackpack =
                      fmap (defaultClassPath ++) $ globDir1 (compile "**/*.jar") builddir
                    | otherwise = return defaultClassPath
              classpath <- getClasspath
              let inputFile = srcFile -<.> "stdin"
              exists <- doesFileExist inputFile
              let processConfig = P.proc "java" ["-ea", "-classpath",
                                                 mkClassPath (outJar : classpath), "eta.main"]
                  getInput
                    | exists = do
                      input <- BS.readFile inputFile
                      _ <- evaluate $ force input
                      return input
                    | otherwise = return mempty
              input <- getInput
              readCreateProcessWithExitCode processConfig input
            else return (exitCode', stdout', stderr')

          let mainOutput = stdout <> stderr
              output
                | not (expectedExitCode exitCode) =
                  BC.pack (show exitCode ++ "\n") <> mainOutput
                | otherwise = mainOutput

          return output
        | otherwise =
          let mainOutput = stdout' <> stderr'
              exitCode = exitCode'
              output
                | not (expectedExitCode exitCode) =
                  BC.pack (show exitCode ++ "\n") <> mainOutput
                | otherwise = mainOutput
          in return output
  getOutput >>= BS.writeFile outputFile

genericEtlasOptions :: [String]
genericEtlasOptions =
  ["-g0",
   "-fshow-source-paths",
   "-dcore-lint",
   "-fno-diagnostics-show-caret",
   "-fdiagnostics-color=never",
   "-fshow-warning-groups",
   "-dno-debug-output"]

genericEtaOptions :: [String]
genericEtaOptions =
  ["-O"]
  ++ (unsafePerformIO $ do
        etlasRootDir <- getAppUserDataDirectory "etlas"
        return [ "-pgmi", etlasRootDir </> "tools" </> "eta-serv.jar" ])
  ++ genericEtlasOptions

buildRootDir :: FilePath
buildRootDir = "dist"

buildDir :: String -> String -> String -> FilePath
buildDir suiteName suiteType testName =
  buildRootDir </> suiteName </> suiteType </> testName

rootDir :: FilePath
rootDir = "tests/suite"

classPathSep :: String
#ifndef mingw32_HOST_OS
classPathSep = ":"
#else
classPathSep = ";"
#endif

mkClassPath :: [FilePath] -> String
mkClassPath = intercalate classPathSep

getDefaultClassPath :: IO [FilePath]
getDefaultClassPath = do
  (_, res, _) <- readCreateProcessWithExitCode
           (P.proc "etlas" ["exec", "eta-pkg", "--", "list", "--simple-output"])
           mempty
  let packages = map BC.unpack $ BC.split ' ' res
  forM packages $ \package -> do
    (_, res', _) <- readCreateProcessWithExitCode
              (P.proc "etlas" ["exec", "eta-pkg", "--", "field", package,
                               "library-dirs,hs-libraries", "--simple"])
              mempty
    let (dir:file:_) = BC.lines res'
    return $ BC.unpack dir </> (BC.unpack file <.> "jar")

directoryListing :: FilePath -> IO [FilePath]
directoryListing dir = do
  contents <- listContents dir
  filterM doesDirectoryExist contents

-- | Same as 'goldenVsFile', but invokes an external diff command.
goldenVsFileDiff'
  :: TestName -- ^ test name
  -> (FilePath -> FilePath -> [String])
    -- ^ function that constructs the command line to invoke the diff
    -- command.
    --
    -- E.g.
    --
    -- >\ref new -> ["diff", "-u", ref, new]
  -> FilePath -- ^ path to the golden file
  -> FilePath -- ^ path to the output file
  -> IO ()    -- ^ action that produces the output file
  -> TestTree
goldenVsFileDiff' name cmdf ref new act =
  goldenTest
    name
    (return ())
    act
    cmp
    upd
  where
   cmp _ _ = do
     exists <- doesFileExist ref
     if exists
     then do
       let cmd = cmdf ref new
       if | null cmd  -> error "goldenVsFileDiff: empty command line"
          | otherwise -> do
            (_, Just sout, _, pid) <- createProcess (P.proc (head cmd) (tail cmd)) {
                std_out = CreatePipe
              }
            -- strictly read the whole output, so that the process can terminate
            out <- hGetContents sout
            evaluate . rnf $ out

            r <- waitForProcess pid
            return $ case r of
              ExitSuccess -> Nothing
              _ -> Just out
     else do
       res <- readFile new
       if null res
       then return Nothing
       else return $ Just $ unlines ["Expected empty output, but got:"] ++ res

   upd _ = BS.readFile new >>= BS.writeFile ref

ignored :: Set String
ignored = S.fromList ["Echo", "FullExportTest", "tc141", "tc168", "tc211",
        "T14163", "T4912", "T6018", "T7541", "InstanceMethod", "TcTypeNatSimple",
        "TcTypeSymbolSimple", "tcfail150", "tcfail205", "annrun01", "TH_overloadedlabels",
        "TH_repPrim", "TH_repPrim2", "TH_repGuard"]

filterIgnored :: [FilePath] -> [FilePath]
filterIgnored = filter f
  where f path = not (base `S.member` ignored) && not ("ignored_" `isPrefixOf` base)
          where base = takeBaseName path
