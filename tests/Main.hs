{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

-- |
-- Module: Main
-- Copyright: Copyright © 2014 AlephCloud Systems, Inc.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@alephcloud.com>
-- Stability: experimental
--
-- Tests for Haskell Kinesis bindings
--
module Main
( main
) where

import Aws
import Aws.Kinesis

import Control.Error
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class

import qualified Data.ByteString as B
import qualified Data.List as L
import Data.Monoid
import Data.Proxy
import qualified Data.Text as T

import Test.Tasty

import System.Exit
import System.Environment

import Utils

defaultStreamName :: StreamName
defaultStreamName = "test-stream"

-- -------------------------------------------------------------------------- --
-- Main

-- | Since these tests generate costs there should be a warning and
-- we also should require an explicit command line argument that expresses
-- the concent of the user.
--
main :: IO ()
main = getArgs >>= runMain
  where
    runMain args
        | "--help" `elem` args || "-h" `elem` args = defaultMain tests
        | "--run-with-aws-credentials" `elem` args =
            withArgs (filter (/= "--run-with-aws-credentials") args) $ defaultMain tests
        | otherwise = putStrLn help >> exitFailure

help :: String
help = L.intercalate "\n"
    [ ""
    , "NOTE"
    , ""
    , "This test suite accesses the AWS account that is associated with"
    , "the default credentials from the credential file ~/.aws-keys."
    , ""
    , "By running the tests in this test-suite costs for usage of AWS"
    , "services may incur."
    , ""
    , "In order to actually excute the tests in this test-suite you must"
    , "provide the command line option:"
    , ""
    , "    --run-with-aws-credentials"
    , ""
    , "When running this test-suite through cabal you may use the following"
    , "command:"
    , ""
    , "    cabal test kinesis-tests --test-option=--run-with-aws-credentials"
    , ""
    ]

tests :: TestTree
tests = testGroup "Kinesis Tests"
    [ test_jsonRoundtrips
    , test_createStream
    , test_stream1
    ]

-- -------------------------------------------------------------------------- --
-- Kinesis Utils

kinesisConfiguration :: KinesisConfiguration qt
kinesisConfiguration = KinesisConfiguration testRegion

simpleKinesis
    :: (AsMemoryResponse a, Transaction r a, ServiceConfiguration r ~ KinesisConfiguration, MonadIO m)
    => r
    -> m (MemoryResponse a)
simpleKinesis command = do
    c <- baseConfiguration
    simpleAws c kinesisConfiguration command

simpleKinesisT
    :: (AsMemoryResponse a, Transaction r a, ServiceConfiguration r ~ KinesisConfiguration, MonadIO m)
    => r
    -> EitherT T.Text m (MemoryResponse a)
simpleKinesisT = tryT . simpleKinesis

testStreamName :: StreamName -> StreamName
testStreamName = either (error . T.unpack) id
        . streamName . T.take 128 . testData . streamNameText

-- |
--
withStream
    :: StreamName -- ^ Stream Name
    -> Int -- ^ Shard count
    -> IO a
    -> IO a
withStream stream shardCount = bracket_ createStream deleteStream
  where
    createStream = simpleKinesis $ CreateStream shardCount stream
    deleteStream = void $ simpleKinesis (DeleteStream stream)

-- | The function 'withResource' from "Tasty" synchronizes the aquired
-- resource through a 'TVar'. We don't need that for a stream. So instead
-- of passing the 'IO StreamName' from 'withResource' we directly pass
-- 'StreamName' to the inner function.
--
withStreamTest
    :: StreamName -- ^ stream name suffix
    -> Int -- ^ shard count
    -> (StreamName -> TestTree)
    -> TestTree
withStreamTest stream shardCount f = withResource createStream deleteStream
    $ const (f tstream)
  where
    createStream = do
        void . simpleKinesis $ CreateStream shardCount tstream
        return tstream
    deleteStream = const . void . simpleKinesis $ DeleteStream tstream
    tstream = testStreamName stream


-- | Wait for a stream to become active
--
waitActiveT
    :: Int
    -- ^ upper bound on the number of seconds to wait.
    -- The actual maximal number of seconds is closest smaller
    -- power of two.
    -> StreamName
    -> EitherT T.Text IO StreamDescription
waitActiveT sec stream = retryT maxRetry $ do
    DescribeStreamResponse d <- simpleKinesisT
        $ DescribeStream Nothing Nothing stream
    unless (streamDescriptionStreamStatus d == StreamStatusActive)
        $ left "Stream is not active"
    return d
  where
    maxRetry = floor $ logBase 2 (fromIntegral sec :: Double)

-- -------------------------------------------------------------------------- --
-- Types

test_jsonRoundtrips :: TestTree
test_jsonRoundtrips = testGroup "JSON encoding roundtrips"
    [ test_jsonRoundtrip (Proxy :: Proxy StreamName)
    , test_jsonRoundtrip (Proxy :: Proxy ShardId)
    , test_jsonRoundtrip (Proxy :: Proxy SequenceNumber)
    , test_jsonRoundtrip (Proxy :: Proxy PartitionHash)
    , test_jsonRoundtrip (Proxy :: Proxy PartitionKey)
    , test_jsonRoundtrip (Proxy :: Proxy ShardIterator)
    , test_jsonRoundtrip (Proxy :: Proxy ShardIteratorType)
    , test_jsonRoundtrip (Proxy :: Proxy Record)
    , test_jsonRoundtrip (Proxy :: Proxy StreamDescription)
    , test_jsonRoundtrip (Proxy :: Proxy StreamStatus)
    , test_jsonRoundtrip (Proxy :: Proxy Shard)
    ]

-- -------------------------------------------------------------------------- --
-- Stream Tests

test_stream1 :: TestTree
test_stream1 = withStreamTest defaultStreamName 1 $ \stream ->
    testGroup "Perform a series of tests on a single stream"
        [ eitherTOnceTest0 "list streams" (prop_streamList stream)
        , eitherTOnceTest0 "describe stream" (prop_streamDescribe 1 stream)
        , eitherTOnceTest2 "put and get stream" (prop_streamPutGet stream)
        ]

prop_streamList :: StreamName -> EitherT T.Text IO ()
prop_streamList stream = do
    ListStreamsResponse _ streams <- simpleKinesisT $ ListStreams Nothing Nothing
    unless (stream `elem` streams) $
        left $ "stream " <> streamNameText stream <> " is not listed"

prop_streamDescribe
    :: Int -- ^  expected number of shards
    -> StreamName
    -> EitherT T.Text IO ()
prop_streamDescribe shardNum stream = do
    desc <- waitActiveT 64 stream

    unless (streamDescriptionStreamName desc == stream)
        . left $ "unexpected stream name in description: "
        <> streamNameText (streamDescriptionStreamName desc)

    let l = length $ streamDescriptionShards desc
    unless (l == shardNum)
        . left $ "unexpected number of shards in stream description: " <> sshow l

prop_streamPutGet
    :: StreamName
    -> B.ByteString -- ^ Message data
    -> PartitionKey
    -> EitherT T.Text IO ()
prop_streamPutGet stream dat key = do
    desc <- waitActiveT 64 stream

    let shards = streamDescriptionShards desc

    PutRecordResponse putSeqNr putShard <- simpleKinesisT PutRecord
        { putRecordData = dat
        , putRecordExplicitHashKey = Nothing
        , putRecordPartitionKey = key
        , putRecordSequenceNumberForOrdering = Nothing
        , putRecordStreamName = stream
        }

    let shardIds = map shardShardId shards
    unless (putShard `elem` shardIds) . left
        $ "unexpected shard id: expected on of " <> sshow shardIds <> "; got " <> sshow putShard

    record <- retryT 5 $ do
        GetShardIteratorResponse it <- simpleKinesisT GetShardIterator
            { getShardIteratorShardId = putShard
            , getShardIteratorShardIteratorType = TrimHorizon
            , getShardIteratorStartingSequenceNumber = Nothing
            , getShardIteratorStreamName = stream
            }
        GetRecordsResponse _nextIt records <- simpleKinesisT GetRecords
            { getRecordsLimit = Nothing
            , getRecordsShardIterator = it
            }
        case records of
            [] -> left "no record found in stream"
            [r] -> return r
            t -> left $ "unexpected records found in stream: " <> sshow t

    let getData = recordData record
    unless (getData == dat) . left
        $ "data does not match: expected " <> sshow dat <> "; got " <> sshow getData

    let getSeqNr = recordSequenceNumber record
    unless (getSeqNr == putSeqNr) . left
        $ "sequence numbers don't match: expected " <> sshow putSeqNr
        <> "; got " <> sshow getSeqNr

    let getPartKey = recordPartitionKey record
    unless (getPartKey == key) . left
        $ "partition keys don't match: expected " <> sshow key
        <> "; got " <> sshow getPartKey

-- -------------------------------------------------------------------------- --
-- Stream Creation Tests

test_createStream :: TestTree
test_createStream = testGroup "Stream creation"
    [ eitherTOnceTest1 "create list delete" prop_createListDelete
    ]

prop_createListDelete
    :: StreamName -- ^ stream name
    -> EitherT T.Text IO ()
prop_createListDelete stream = do
    CreateStreamResponse <- simpleKinesisT $ CreateStream 1 tstream
    handleT (\e -> deleteStream >> left e) $ do
        ListStreamsResponse _ allStreams <- simpleKinesisT
            $ ListStreams Nothing Nothing
        unless (tstream `elem` allStreams)
            . left $ "stream " <> streamNameText tstream <> " not listed"
        deleteStream
  where
    deleteStream = void $ simpleKinesisT (DeleteStream tstream)
    tstream = testStreamName stream

