module Tor.DataFormat.TorCell(
         TorCell(..),       putTorCell,       getTorCell
       , DestroyReason(..), putDestroyReason, getDestroyReason
       , HandshakeType(..), putHandshakeType, getHandshakeType
       , TorCert(..),       putTorCert,       getTorCert
       )
 where

import Control.Applicative
import Control.Monad
import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString.Lazy(ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.X509
import Data.Word
import Tor.DataFormat.TorAddress

data TorCell = Padding
             | Create      Word32 ByteString
             | Created     Word32 ByteString
             | Relay       Word32 ByteString
             | Destroy     Word32 DestroyReason
             | CreateFast  Word32 ByteString
             | CreatedFast Word32 ByteString ByteString
             | NetInfo            Word32 TorAddress [TorAddress]
             | RelayEarly  Word32 ByteString
             | Create2     Word32 HandshakeType ByteString
             | Created2    Word32 ByteString
             | Versions
             | VPadding           ByteString
             | Certs              [TorCert]
             | AuthChallenge      ByteString [Word16]
             | Authenticate       ByteString
             | Authorize
 deriving (Eq, Show)

getTorCell :: Get TorCell
getTorCell =
  do circuit <- getWord32be
     command <- getWord8
     case command of
       0   -> getStandardCell $ return Padding
       1   -> getStandardCell $
                Create circuit <$> getLazyByteString (128 + 16 + 42)
       2   -> getStandardCell $
                Created circuit <$> getLazyByteString (128 + 20)
       3   -> getStandardCell $ Relay circuit <$> getRemainingLazyByteString
       4   -> getStandardCell $ Destroy circuit <$> getDestroyReason
       5   -> getStandardCell $ CreateFast circuit <$> getLazyByteString 20
       6   -> getStandardCell $ CreatedFast circuit <$> getLazyByteString 20
                                                    <*> getLazyByteString 20
       8   -> getStandardCell $
                do tstamp   <- getWord32be
                   otherOR  <- getTorAddress
                   numAddrs <- getWord8
                   thisOR   <- replicateM (fromIntegral numAddrs) getTorAddress
                   return (NetInfo tstamp otherOR thisOR)
       9   -> getStandardCell $
                RelayEarly circuit <$> getRemainingLazyByteString
       10  -> getStandardCell $
                do htype <- getHandshakeType
                   hlen  <- getWord16be
                   hdata <- getLazyByteString (fromIntegral hlen)
                   return (Create2 circuit htype hdata)
       11  -> getStandardCell $
                do hlen  <- getWord16be
                   hdata <- getLazyByteString (fromIntegral hlen)
                   return (Created2 circuit hdata)
       7   -> fail "Should not be getting versions through this interface."
       128 -> getVariableLength "VPadding"      getVPadding
       129 -> getVariableLength "Certs"         getCerts
       130 -> getVariableLength "AuthChallenge" getAuthChallenge
       131 -> getVariableLength "Authenticate"  getAuthenticate
       132 -> getVariableLength "Authorize"     (return Authorize)
       _   -> fail "Improper Tor cell command."
 where
  getStandardCell getter =
    do bstr <- getLazyByteString 509 -- PAYLOAD_LEN
       case runGetOrFail getter bstr of
         Left (_, _, err) -> fail err
         Right (_, _, x)  -> return x
  getVariableLength name getter =
    do len   <- getWord16be
       body  <- getLazyByteString (fromIntegral len)
       case runGetOrFail getter body of
         Left  (_, _, s) -> fail ("Couldn't read " ++ name ++ " body: " ++ s)
         Right (_, _, x) -> return x
 --
  getVPadding = VPadding <$> getRemainingLazyByteString
  --
  getAuthChallenge =
    do challenge <- getLazyByteString 32
       n_methods <- getWord16be
       methods   <- replicateM (fromIntegral n_methods) getWord16be
       return (AuthChallenge challenge methods)
  --
  getAuthenticate =
    do _ <- getWord16be -- AuthType
       l <- getWord16be
       s <- getLazyByteString (fromIntegral l)
       return (Authenticate s)

putTorCell :: TorCell -> Put
putTorCell Padding =
  putStandardCell $
     putWord32be 0 -- Circuit ID
putTorCell (Create circ bstr) =
  putStandardCell $
    do putWord32be       circ
       putWord8          1
       putLazyByteString bstr
putTorCell (Created circ bstr) =
  putStandardCell $
    do putWord32be       circ
       putWord8          2
       putLazyByteString bstr
putTorCell (Relay circ bstr) =
  putStandardCell $
    do putWord32be       circ
       putWord8          3
       putLazyByteString bstr
putTorCell (Destroy circ dreason) =
  putStandardCell $
    do putWord32be       circ
       putWord8          4
       putDestroyReason  dreason
putTorCell (CreateFast circ keymat) =
  putStandardCell $
    do putWord32be       circ
       putWord8          5
       putLazyByteString keymat
putTorCell (CreatedFast circ keymat deriv) =
  putStandardCell $
    do putWord32be       circ
       putWord8          6
       putLazyByteString keymat
       putLazyByteString deriv
putTorCell (NetInfo ttl oneside others) =
  putStandardCell $
    do putWord32be       0
       putWord8          8
       putWord32be       ttl
       putTorAddress     oneside
       putWord8          (fromIntegral (length others))
       forM_ others putTorAddress
putTorCell (RelayEarly circ bstr) =
  putStandardCell $
    do putWord32be       circ
       putWord8          9
       putLazyByteString bstr
putTorCell (Create2 circ htype cdata) =
  putStandardCell $
    do putWord32be       circ
       putWord8          10
       putHandshakeType  htype
       putWord16be       (fromIntegral (BS.length cdata))
       putLazyByteString cdata
putTorCell (Created2 circ cdata) =
  putStandardCell $
    do putWord32be       circ
       putWord8          11
       putWord16be       (fromIntegral (BS.length cdata))
       putLazyByteString cdata
putTorCell (VPadding bstr) =
  do putWord32be       0
     putWord8          128
     putWord16be       (fromIntegral (BS.length bstr))
     putLazyByteString bstr
putTorCell (Certs cs) =
  do putWord32be       0
     putWord8          129
     putLenByteString $
       do putWord8          (fromIntegral (length cs))
          forM_ cs putTorCert
putTorCell (AuthChallenge challenge methods) =
  do putWord32be       0
     putWord8          130
     putLenByteString $
       do putLazyByteString challenge
          putWord16be       (fromIntegral (length methods))
          forM_ methods putWord16be
putTorCell (Authenticate authent) =
  do putWord32be       0
     putWord8          131
     putLenByteString $
       do putWord16be       1
          putWord16be       (fromIntegral (BS.length authent))
          putLazyByteString authent
putTorCell (Authorize) =
  do putWord32be       0
     putWord8          132
     putWord16be       0
putTorCell (Versions) =
  do putWord16be       0
     putWord8          7
     putWord16be       2
     putWord16be       4

putLenByteString :: Put -> Put
putLenByteString m =
  do let bstr = runPut m
     putWord16be (fromIntegral (BS.length bstr))
     putLazyByteString bstr

putStandardCell :: Put -> Put
putStandardCell m =
  do let bstr = runPut m
         infstr = bstr `BS.append` BS.repeat 0
     putLazyByteString (BS.take 514 infstr)

-- -----------------------------------------------------------------------------

data DestroyReason = NoReason
                   | TorProtocolViolation
                   | InternalError
                   | RequestedDestroy
                   | NodeHibernating
                   | HitResourceLimit
                   | ConnectionFailed
                   | ORIdentityIssue
                   | ORConnectionClosed
                   | Finished
                   | CircuitConstructionTimeout
                   | CircuitDestroyed
                   | NoSuchService
                   | UnknownDestroyReason Word8
 deriving (Eq, Show)

getDestroyReason :: Get DestroyReason
getDestroyReason =
  do b <- getWord8
     case b of
       0  -> return NoReason
       1  -> return TorProtocolViolation
       2  -> return InternalError
       3  -> return RequestedDestroy
       4  -> return NodeHibernating
       5  -> return HitResourceLimit
       6  -> return ConnectionFailed
       7  -> return ORIdentityIssue
       8  -> return ORConnectionClosed
       9  -> return Finished
       10 -> return CircuitConstructionTimeout
       11 -> return CircuitDestroyed
       12 -> return NoSuchService
       _  -> return (UnknownDestroyReason b)

putDestroyReason :: DestroyReason -> Put
putDestroyReason NoReason                   = putWord8 0
putDestroyReason TorProtocolViolation       = putWord8 1
putDestroyReason InternalError              = putWord8 2
putDestroyReason RequestedDestroy           = putWord8 3
putDestroyReason NodeHibernating            = putWord8 4
putDestroyReason HitResourceLimit           = putWord8 5
putDestroyReason ConnectionFailed           = putWord8 6
putDestroyReason ORIdentityIssue            = putWord8 7
putDestroyReason ORConnectionClosed         = putWord8 8
putDestroyReason Finished                   = putWord8 9
putDestroyReason CircuitConstructionTimeout = putWord8 10
putDestroyReason CircuitDestroyed           = putWord8 11
putDestroyReason NoSuchService              = putWord8 12
putDestroyReason (UnknownDestroyReason x)   = putWord8 x

-- -----------------------------------------------------------------------------

data HandshakeType = TAP | Reserved | NTor | Unknown Word16
 deriving (Eq, Show)

getHandshakeType :: Get HandshakeType
getHandshakeType =
  do t <- getWord16be
     case t of
       0x0000 -> return TAP
       0x0001 -> return Reserved
       0x0002 -> return NTor
       _      -> return (Unknown t)

putHandshakeType :: HandshakeType -> Put
putHandshakeType TAP         = putWord16be 0x0000
putHandshakeType Reserved    = putWord16be 0x0001
putHandshakeType NTor        = putWord16be 0x0002
putHandshakeType (Unknown x) = putWord16be x

-- -----------------------------------------------------------------------------

data TorCert = LinkKeyCert SignedCertificate
             | RSA1024Identity SignedCertificate
             | RSA1024Authenticate SignedCertificate
             | UnknownCertType Word8 ByteString
 deriving (Eq, Show)

getTorCert :: Get TorCert
getTorCert =
  do t <- getWord8
     l <- getWord16be
     c <- getLazyByteString (fromIntegral l)
     case t of
       1 -> return (maybeBuild LinkKeyCert         t c)
       2 -> return (maybeBuild RSA1024Identity     t c)
       3 -> return (maybeBuild RSA1024Authenticate t c)
       _ -> return (UnknownCertType t c)
 where
  maybeBuild builder t bstr =
    case decodeSignedObject (BS.toStrict bstr) of
      Left  _   -> UnknownCertType t bstr
      Right res -> builder res

putTorCert :: TorCert -> Put
putTorCert tc =
  do let (t, bstr) = case tc of
                       LinkKeyCert sc         -> (1, encodeSignedObject' sc)
                       RSA1024Identity sc     -> (2, encodeSignedObject' sc)
                       RSA1024Authenticate sc -> (3, encodeSignedObject' sc)
                       UnknownCertType ct bs  -> (ct, bs)
     putWord8          t
     putWord16be       (fromIntegral (BS.length bstr))
     putLazyByteString bstr
 where encodeSignedObject' = BS.fromStrict . encodeSignedObject

-- -----------------------------------------------------------------------------

getCerts :: Get TorCell
getCerts =
  do num   <- getWord8
     certs <- replicateM (fromIntegral num) getTorCert
     return (Certs certs)
