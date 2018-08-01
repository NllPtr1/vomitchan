{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE Haskell2010       #-}
{-# LANGUAGE OverloadedStrings #-}


--- MODULE DEFINITION -------------------------------------------------------------------------
module Bot.Network (
  IRCNetwork,
  readNetworks,
  saveNetworks,
  joinNetwork,
  findNetwork,
  netServer,
  netState
) where
--- IMPORTS -----------------------------------------------------------------------------------
import           Control.Monad
import qualified Data.Aeson            as JSON
import qualified Data.ByteString.Lazy  as B
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Char8 as BC (putStrLn)
import qualified Data.Text             as T
import           GHC.Generics
import qualified Network.Connection    as C
import           Data.Monoid
import qualified Data.ByteString.Base64 as BS64
import qualified Data.Text.Encoding as TE

import           Control.Exception (try,SomeException)
import           Data.Foldable
import           Bot.MessageType
import           Bot.Socket
import           Bot.StateType
--- DATA STRUCTURES ---------------------------------------------------------------------------

-- IRC network table
data IRCNetwork = IRCNetwork
             { netServer :: Server
             , netPort   :: Port
             , netSSL    :: Bool
             , netNick   :: Nick
             , netPass   :: Pass
             , netChans  :: [Chan]
             , netState  :: StateConfig
             } deriving (Show,Generic)

-- allow encoding to/from JSON
instance JSON.FromJSON IRCNetwork
instance JSON.ToJSON IRCNetwork


--- FUNCTIONS ---------------------------------------------------------------------------------

-- read IRC networks from file
readNetworks :: FilePath -> IO (Maybe [IRCNetwork])
readNetworks file = do
  jsonData <- JSON.eitherDecode <$> B.readFile file :: IO (Either String [IRCNetwork])
  case jsonData of
    Left  err  -> putStrLn err >> return Nothing
    Right nets -> return $ Just nets

-- save IRC networks to file
saveNetworks :: FilePath -> [IRCNetwork] -> IO ()
saveNetworks file nets = B.writeFile file (JSON.encode nets)

-- joins a network and returns a handle
joinNetwork :: IRCNetwork -> IO (Maybe C.Connection)
joinNetwork net = do
  ctx <- C.initConnectionContext
  con <- try $ C.connectTo ctx C.ConnectionParams { C.connectionHostname  = T.unpack $ netServer net
                                                  , C.connectionPort      = fromIntegral $ netPort net
                                                  , C.connectionUseSecure = Just $ C.TLSSettingsSimple False False True
                                                  , C.connectionUseSocks  = Nothing
                                                  } :: IO (Either SomeException C.Connection)
  case con of
    Left ex -> putStrLn (show ex) >> return Nothing
    Right con -> do
      passConnect con
      traverse_ (write con) (zip (repeat "JOIN") (netChans net))
      return (Just con)
  where
    -- this entire section will be revamped once I introduce parser combinators
    waitForPing f str h = do
      line <- C.connectionGetLine 10240 h
      BC.putStrLn line
      when ("PING" `BS.isPrefixOf` line) (writeBS h ("PONG", BS.drop 5 line))
      unless (str `f` line) (waitForPing f str h)

    waitForInfix = waitForPing BS.isInfixOf

    waitForAuth = waitForInfix ":You are now identified"
    waitForSASL = waitForInfix "sasl"
    waitForPlus = waitForInfix "AUTHENTICATE +"
    waitForHost = waitForInfix ":*** Looking up your hostname..."
    waitForJoin = waitForInfix "90"
    waitForCap  = waitForInfix " ACK" -- TODO: replace this with CAP nick ACK
    waitForMOTD = waitForInfix "376"

    passConnect con
      | not (netSSL net) = do
          write con ("NICK", netNick net)
          write con ("USER", netNick net <> " 0 * :connected")
          unless (netPass net == "")
                 (write con ("NICKSERV :IDENTIFY", netPass net) >> waitForAuth con)
          waitForMOTD con
      | otherwise = do
          write con ("CAP", "LS 302")
          write con ("NICK", netNick net)
          write con ("USER", netNick net <> " 0 * :connected")
          waitForSASL con
          write con ("CAP", "REQ :sasl")
          waitForCap con
          write con ("AUTHENTICATE", "PLAIN")
          waitForPlus con
          writeBS con ("AUTHENTICATE", (encode $ fold [netNick net, "\0", netNick net, "\0", netPass net]))
          waitForJoin con
          write con ("CAP", "END")
    encode = BS64.encode . TE.encodeUtf8
--- HELPER FUNCTIONS / UNUSED -----------------------------------------------------------------

-- finds a network by name and maybe returns it
findNetwork :: [IRCNetwork] -> Server -> Maybe IRCNetwork
findNetwork (nt:nts) sv
  | netServer nt == sv = Just nt
  | null nts           = Nothing
  | otherwise          = findNetwork nts sv
