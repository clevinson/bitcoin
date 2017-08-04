{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
module Bitcoin where

import           Bitcoin.Network
import           Bitcoin.Log
import           Bitcoin.Crypto

import           Crypto.Hash (Digest, SHA256(..), HashAlgorithm, hashlazy, digestFromByteString, hashDigestSize)
import           Crypto.Hash.Tree (HashTree)
import qualified Crypto.Hash.Tree as HashTree
import           Crypto.Error (CryptoFailable(CryptoPassed))

import           Control.Concurrent.STM.TChan
import           Control.Concurrent.Async (async)
import           Control.Concurrent (threadDelay)
import           Control.Monad (forever)
import           Control.Monad.Reader
import           Control.Monad.Logger

import           Data.Binary (Binary, get, put, encode)
import           Data.ByteString hiding (putStrLn)
import           Data.ByteString.Lazy (toStrict)
import           Data.ByteString.Base58
import           Data.ByteArray (convert, ByteArray, zero)
import qualified Data.ByteArray as ByteArray
import           Data.Foldable (toList)
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Maybe (fromJust)
import qualified Data.Sequence as Seq
import           Data.Sequence   (Seq, (|>))
import           Data.IORef
import           Data.Word (Word64, Word32)
import           Data.Int (Int32)

import qualified Network.Socket as NS
import           GHC.Generics (Generic)
import           GHC.Stack (HasCallStack)
import           Debug.Trace

instance Binary (Digest SHA256) where
    put digest =
        put (convert digest :: ByteString)
    get =
        fromJust . digestFromByteString <$> get @ByteString

-- | Amount in smallest denomination. Ex: Satoshis.
type Amount = Word64
type TxId = Digest SHA256
type Signature = ByteString

newtype Valid a = Valid a

data UTxOutput = UTxOutput
    { utxoTxId   :: TxId
    , utxoIndex  :: Word32
    , utxoSig    :: Signature
    , utxoPubKey :: PublicKey
    } deriving (Eq, Show, Generic)

utxo :: Tx' -> Word32 -> UTxOutput
utxo tx vout =
    UTxOutput
        { utxoTxId   = txDigest tx
        , utxoIndex  = vout
        , utxoSig    = undefined
        , utxoPubKey = undefined
        }

instance Binary UTxOutput

type TxInput = UTxOutput
type TxOutput = (Address, Amount)

data Tx digest = Tx
    { txDigest    :: digest
    , txInputs    :: [UTxOutput]
    , txOutput    :: [TxOutput]
    } deriving (Eq, Show, Generic)

type Tx' = Tx (Digest SHA256)

transactionFee :: Tx a -> Amount
transactionFee = undefined

instance Binary a => Binary (Tx a)

data BlockHeader = BlockHeader
    { blockIndex        :: Integer
    , blockPreviousHash :: Digest SHA256
    , blockRootHash     :: HashTree.RootHash SHA256
    , blockNonce        :: Word32
    } deriving (Show, Generic)

instance Eq BlockHeader where
    (==) h h' =
        blockIndex h == blockIndex h' &&
        blockPreviousHash h == blockPreviousHash h'

emptyBlockHeader :: BlockHeader
emptyBlockHeader = BlockHeader 0 zeroHash (HashTree.RootHash 0 zeroHash) 0

instance Binary BlockHeader

data Block a = Block
    { blockHeader :: BlockHeader
    , blockData   :: Seq a
    } deriving (Show, Generic)

instance (Binary a) => Binary (Block a)
deriving instance Eq a => Eq (Block a)

instance Binary (HashTree.RootHash SHA256) where
    put (HashTree.RootHash n digest) =
        put n >> put digest
    get =
        HashTree.RootHash <$> get <*> get

type Bitcoin = Blockchain Tx'
type Blockchain tx = Seq (Block' tx)
type Block' tx = Block tx
type BlockM a = Either Error a

newtype Error = Error String

newtype Address = Address ByteString
    deriving (Eq, Show, Binary)

toAddress :: PublicKey -> Address
toAddress pk = Address . encodeBase58 bitcoinAlphabet . toStrict $ encode pk

data Message a =
      MsgTx Tx'
    | MsgBlock (Block a)
    | MsgPing
    deriving (Show, Generic)

instance Binary a => Binary (Message a)
deriving instance Eq a => Eq (Message a)

class Validate a where
    validate :: a -> BlockM a

instance Validate (Block a) where
    validate = validateBlock

instance Validate (Blockchain a) where
    validate = validateBlockchain

validateBlockchain :: Blockchain a -> Either Error (Blockchain a)
validateBlockchain bc = Right bc

validateBlock :: Block a -> Either Error (Block a)
validateBlock blk = Right blk

isGenesisBlock :: Block' a -> Bool
isGenesisBlock blk =
    (blockPreviousHash . blockHeader) blk == zeroHash

zeroHash :: HashAlgorithm a => Digest a
zeroHash = fromJust $
    digestFromByteString (zero (hashDigestSize SHA256) :: ByteString)

maxHash :: HashAlgorithm a => Digest a
maxHash = fromJust $
    digestFromByteString (ByteArray.replicate (hashDigestSize SHA256) maxBound :: ByteString)

transaction
    :: [TxInput]
    -> [TxOutput]
    -> BlockM Tx'
transaction ins outs =
    pure $ Tx digest ins outs
  where
    digest = hashlazy (encode tx)
    tx     = Tx () ins outs

coinbase
    :: [TxOutput]
    -> BlockM Tx'
coinbase outs =
    transaction [] outs

data Env = Env
    { envBlockchain :: IORef (Blockchain Tx')
    , envLogger     :: Logger
    }

newEnv :: IO Env
newEnv = do
    bc <- newIORef mempty
    pure $ Env
        { envBlockchain = bc
        , envLogger     = undefined
        }

io :: MonadIO m => IO a -> m a
io = liftIO

withCurrentBlock :: (Block a -> Block a) -> Blockchain a -> Blockchain a
withCurrentBlock f bc =
    Seq.adjust' f index bc
  where
    index = Seq.length bc - 1

startNode
    :: (MonadReader Env m, MonadLogger m, MonadIO m)
    => NS.ServiceName
    -> [(NS.HostName, NS.ServiceName)]
    -> m ()
startNode port peers = do
    net :: Internet (Message Tx') <- listen port
    io . async $ connectToPeers net peers
    io . async $ forever $ do
        broadcast net MsgPing
        threadDelay $ 1000 * 1000

    forever $ do
        msg <- receive net
        case msg of
            MsgTx tx -> do
                logInfoN "Tx"
                bc <- asks envBlockchain
                io $ modifyIORef bc (withCurrentBlock $ appendTx tx)
            MsgBlock blk ->
                logInfoN "Block"
            MsgPing ->
                logInfoN "Ping"

broadcastTransaction :: Socket n (Message a) => n -> Tx (Digest SHA256) -> IO ()
broadcastTransaction net tx = do
    broadcast net (MsgTx tx)

block :: [a] -> BlockM (Block' a)
block xs = validate $
    Block
        BlockHeader
            { blockIndex        = 0
            , blockPreviousHash = zeroHash
            , blockRootHash     = undefined
            , blockNonce        = undefined
            }
        (Seq.fromList xs)

genesisBlock :: [a] -> BlockM (Block' a)
genesisBlock xs = validate $
    Block
        BlockHeader
            { blockIndex        = 0
            , blockPreviousHash = zeroHash
            , blockRootHash     = undefined
            , blockNonce        = undefined
            }
        (Seq.fromList xs)

blockchain :: [Block' a] -> BlockM (Blockchain a)
blockchain blks = validate $ Seq.fromList blks

hashValidation :: Integer -> BlockHeader -> Bool
hashValidation target bh =
    digest > zeroHash
  where
    digest = hashlazy $ encode bh :: Digest SHA256

proofOfWork :: (BlockHeader -> Bool) -> BlockHeader -> BlockHeader
proofOfWork validate bh | validate bh =
    bh
proofOfWork validate bh@BlockHeader { blockNonce } =
    proofOfWork validate bh { blockNonce = blockNonce + 1 }

appendTx :: tx -> Block tx -> Block tx
appendTx tx blk = blk
    { blockData = blockData blk |> tx }

appendBlock :: Binary a => Seq a -> Blockchain a -> BlockM (Blockchain a)
appendBlock dat bc =
    validate $ bc |> new
  where
    prev = Seq.index bc (Seq.length bc - 1)
    new = Block header dat
    header = BlockHeader
        { blockIndex        = blockIndex (blockHeader prev) + 1
        , blockPreviousHash = blockHash prev
        , blockRootHash     = rootHash
        , blockNonce        = undefined
        }
    rootHash =
        HashTree.rootHash . HashTree.fromList . NonEmpty.fromList . toList $
            fmap (hashlazy . encode) dat

blockHash :: (Binary a) => Block a -> Digest SHA256
blockHash blk =
    hashlazy $ encode blk

connectToPeers :: Internet a -> [(NS.HostName, NS.ServiceName)] -> IO ()
connectToPeers net peers =
    mapM_ (connect net) peers

