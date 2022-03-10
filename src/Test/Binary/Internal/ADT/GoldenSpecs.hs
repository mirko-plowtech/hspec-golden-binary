{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Test.Binary.Internal.ADT.GoldenSpecs
-- Description : Golden tests for ToADTArbitrary
-- Copyright   : (c) Plow Technologies, 2021
-- License     : BSD3
-- Maintainer  : bruno-cadorette@plowtech.net
-- Stability   : Beta
--
-- Internal module, use at your own risk.
module Test.Binary.Internal.ADT.GoldenSpecs where

import Control.Arrow
import Control.Exception
import Control.Monad
import Data.ByteString.Lazy (readFile, writeFile, ByteString)
import Data.Int (Int32)
import Data.Maybe (isJust)
import Data.Proxy
import Data.Binary
import qualified Data.Binary as B
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath
import System.Random
import Test.Binary.Internal.Utils
import Test.HUnit.Lang (HUnitFailure)
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Arbitrary.ADT
import Prelude hiding (readFile, writeFile)

-- | Tests to ensure that binary encoding has not unintentionally changed. This
-- could be caused by the following:
--
-- - A type's instances of the serialisation have changed.
-- - Selectors have been edited, added or deleted.
-- - You have changed version of Binary the way Binary serialization has changed
--   works.
--
-- If you run this function and the golden files do not
-- exist, it will create them for each constructor. It they do exist, it will
-- compare with golden file if it exists. Golden file encodes binary format of a
-- type. It is recommended that you put the golden files under revision control
-- to help monitor changes.
goldenADTSpecs ::
  forall a.
  (ToADTArbitrary a, Eq a, Show a, Binary a) =>
  Settings ->
  Proxy a ->
  Spec
goldenADTSpecs settings proxy = goldenADTSpecsWithNote settings proxy Nothing

-- | same as 'goldenADTSpecs' but has the option of passing a note to the
-- 'describe' function.
goldenADTSpecsWithNote ::
  forall a.
  (ToADTArbitrary a, Eq a, Show a, Binary a) =>
  Settings ->
  Proxy a ->
  Maybe String ->
  Spec
goldenADTSpecsWithNote settings Proxy mNote = do
  (moduleName, (typeName, constructors)) <- runIO $ fmap (adtModuleName &&& adtTypeName &&& adtCAPs) <$> generate $ toADTArbitrary (Proxy :: Proxy a)
  describe ("Binary encoding of " ++ typeName ++ note) $
    mapM_ (testConstructor settings moduleName typeName) constructors
  where
    note = maybe "" (" " ++) mNote

-- | test a single set of values from a constructor for a given type.
testConstructor ::
  forall a.
  (Eq a, Show a, Binary a, ToADTArbitrary a) =>
  Settings ->
  String ->
  String ->
  ConstructorArbitraryPair a ->
  SpecWith (Arg (IO ()))
testConstructor Settings {..} moduleName typeName cap =
  it ("produces the same binary as is found in " ++ goldenFile) $ do
    exists <- doesFileExist goldenFile
    let fixIfFlag err = do
          doFix <- isJust <$> lookupEnv recreateBrokenGoldenEnv
          if doFix
            then createGoldenFile sampleSize cap goldenFile
            else throwIO err
    if exists
      then
        compareWithGolden randomMismatchOption topDir mModuleName typeName cap goldenFile
          `catches` [ Handler (\(err :: HUnitFailure) -> fixIfFlag err),
                      Handler (\(err :: DecodeError) -> fixIfFlag err)
                    ]
      else do
        doCreate <- isJust <$> lookupEnv createMissingGoldenEnv
        if doCreate
          then createGoldenFile sampleSize cap goldenFile
          else expectationFailure $ "Missing golden file: " <> goldenFile
  where
    goldenFile = mkGoldenFilePath topDir mModuleName typeName cap
    topDir = case goldenDirectoryOption of
      GoldenDirectory -> "golden"
      CustomDirectoryName d -> d
    mModuleName = 
      if useModuleNameAsSubDirectory then
        Just moduleName
      else
        Nothing

-- | The golden files already exist. Binary values with the same seed from
-- the golden files of each constructor and compare.
compareWithGolden ::
  forall a.
  (Show a, Eq a, Binary a, ToADTArbitrary a) =>
  RandomMismatchOption ->
  String ->
  Maybe String ->
  String ->
  ConstructorArbitraryPair a ->
  FilePath ->
  IO ()
compareWithGolden randomOption topDir mModuleName typeName cap goldenFile = do
  fileContent <- readFile goldenFile
  goldenSampleWithoutBody :: (RandomSamples a) <- binaryDecodeIO fileContent
  let goldenSeed = seed goldenSampleWithoutBody
  let sampleSize = Prelude.length $ samples goldenSampleWithoutBody
  newSamples <- mkRandomADTSamplesForConstructor sampleSize (Proxy :: Proxy a) (capConstructor cap) goldenSeed
  whenFails (writeComparisonFile newSamples) $ do
    goldenSamples :: RandomSamples a <- binaryDecodeIO fileContent
    if newSamples == goldenSamples
      then -- random samples match; test encoding of samples (the above check only tested the decoding)
        B.encode newSamples == fileContent `shouldBe` True
      else do
        let -- whether to pass the test or fail due to random value mismatch
            finalResult =
              case randomOption of
                RandomMismatchWarning -> return ()
                RandomMismatchError -> expectationFailure "New random samples generated from seed in golden file do not match samples in golden file."

        -- do a fallback test to determine whether the mismatch is due to a random sample change only,
        -- or due to a change in encoding
        putStrLn $
          "\n"
            ++ "WARNING: New random samples do not match those in "
            ++ goldenFile
            ++ ".\n"
            ++ "  Testing round-trip decoding/encoding of golden file."
            ++ "\nExpected: " ++ show goldenSamples
            ++ "\nBut got:  " ++ show newSamples
        let reencodedGoldenSamples = B.encode goldenSamples
        if reencodedGoldenSamples == fileContent
          then -- pass the test because round-trip decode/encode still gives the same bytes
            finalResult
          else do
            -- how significant is the serialization change?
            writeReencodedComparisonFile goldenSamples
            testSamples :: RandomSamples a <- binaryDecodeIO reencodedGoldenSamples
            let failureMessage =
                  if testSamples == goldenSamples
                    then "Encoding has changed in a minor way; still can read old encodings. See " ++ faultyReencodedFile ++ "."
                    else "Encoding has changed in a major way; cannot read old encodings. See " ++ faultyReencodedFile ++ "."
            expectationFailure failureMessage
            finalResult
  where
    whenFails :: forall b c. IO c -> IO b -> IO b
    whenFails = flip onException

    faultyFile = mkFaultyFilePath topDir mModuleName typeName cap
    faultyReencodedFile = mkFaultyReencodedFilePath topDir mModuleName typeName cap

    writeComparisonFile newSamples = do
      writeFile faultyFile (B.encode newSamples)
      putStrLn $
        "\n"
          ++ "INFO: Written the current encodings into "
          ++ faultyFile
          ++ "."
    writeReencodedComparisonFile samples = do
      writeFile faultyReencodedFile (B.encode samples)
      putStrLn $
        "\n"
          ++ "INFO: Written the re-encodings into "
          ++ faultyReencodedFile
          ++ "."

-- | The golden files do not exist. Create them for each constructor.
createGoldenFile ::
  forall a.
  (Binary a, ToADTArbitrary a) =>
  Int ->
  ConstructorArbitraryPair a ->
  FilePath ->
  IO ()
createGoldenFile sampleSize cap goldenFile = do
  createDirectoryIfMissing True (takeDirectory goldenFile)
  rSeed <- randomIO :: IO Int32
  rSamples <- mkRandomADTSamplesForConstructor sampleSize (Proxy :: Proxy a) (capConstructor cap) rSeed
  writeFile goldenFile $ B.encode rSamples

  putStrLn $
    "\n"
      ++ "WARNING: Running for the first time, not testing anything.\n"
      ++ "  Created "
      ++ goldenFile
      ++ " containing random samples,\n"
      ++ "  will compare binary encodings with this from now on.\n"
      ++ "  Please, consider putting "
      ++ goldenFile
      ++ " under version control."

-- | Create the file path for the golden file. Optionally use the module name to
-- help avoid name collissions. Different modules can have types of the same
-- name.
mkGoldenFilePath :: forall a. FilePath -> Maybe FilePath -> FilePath -> ConstructorArbitraryPair a -> FilePath
mkGoldenFilePath topDir mModuleName typeName cap =
  case mModuleName of
    Nothing -> topDir </> typeName </> capConstructor cap <.> "bin"
    Just moduleName -> topDir </> moduleName </> typeName </> capConstructor cap <.> "bin"

-- | Create the file path to save results from a failed golden test. Optionally
-- use the module name to help avoid name collisions.  Different modules can
-- have types of the same name.
mkFaultyFilePath :: forall a. FilePath -> Maybe FilePath -> FilePath -> ConstructorArbitraryPair a -> FilePath
mkFaultyFilePath topDir mModuleName typeName cap =
  case mModuleName of
    Nothing -> topDir </> typeName </> capConstructor cap <.> "faulty" <.> "bin"
    Just moduleName -> topDir </> moduleName </> typeName </> capConstructor cap <.> "faulty" <.> "bin"

-- | Create the file path to save results from a failed fallback golden test. Optionally
-- use the module name to help avoid name collisions.  Different modules can
-- have types of the same name.
mkFaultyReencodedFilePath :: forall a. FilePath -> Maybe FilePath -> FilePath -> ConstructorArbitraryPair a -> FilePath
mkFaultyReencodedFilePath topDir mModuleName typeName cap =
  case mModuleName of
    Nothing -> topDir </> typeName </> capConstructor cap <.> "faulty" <.> "reencoded" <.> "bin"
    Just moduleName -> topDir </> moduleName </> typeName </> capConstructor cap <.> "faulty" <.> "reencoded" <.> "bin"

-- | Create a number of arbitrary instances of a particular constructor given
-- a sample size and a random seed.
mkRandomADTSamplesForConstructor ::
  forall a.
  (ToADTArbitrary a) =>
  Int ->
  Proxy a ->
  String ->
  Int32 ->
  IO (RandomSamples a)
mkRandomADTSamplesForConstructor sampleSize Proxy conName rSeed = do
  generatedADTs <- generate gen
  let caps = concat $ adtCAPs <$> generatedADTs
      filteredCAPs = filter (\x -> capConstructor x == conName) caps
      arbs = capArbitrary <$> filteredCAPs
  return $ RandomSamples rSeed arbs
  where
    correctedSampleSize = if sampleSize <= 0 then 1 else sampleSize
    gen = setSeed (fromIntegral rSeed) $ replicateM correctedSampleSize (toADTArbitrary (Proxy :: Proxy a))

-- | Make a Golden File for the Proxy of a type if the file does not exist.
mkGoldenFileForType :: forall a. (Binary a, ToADTArbitrary a) => Int -> Proxy a -> FilePath -> IO ()
mkGoldenFileForType sampleSize Proxy goldenPath = do
  (typeName, constructors) <- fmap (adtTypeName &&& adtCAPs) <$> generate $ toADTArbitrary (Proxy :: Proxy a)
  mapM_
    ( \constructor -> do
        let goldenFile = goldenPath </> typeName </> capConstructor constructor <.> ".bin"
        exists <- doesFileExist goldenFile
        if exists
          then pure ()
          else do
            createDirectoryIfMissing True (takeDirectory goldenFile)
            rSeed <- randomIO :: IO Int32
            rSamples <- mkRandomADTSamplesForConstructor sampleSize (Proxy :: Proxy a) (capConstructor constructor) rSeed
            writeFile goldenFile $ B.encode rSamples
    )
    constructors

-- | run decode in IO, if it returns Left then throw an error.
binaryDecodeIO :: Binary a => ByteString -> IO a
binaryDecodeIO bs = return $ B.decode bs

