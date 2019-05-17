{-# LANGUAGE ScopedTypeVariables #-}
module Main where
--- IMPORTS -----------------------------------------------------------------------------------
import qualified Control.Concurrent as C
import qualified StmContainers.Map  as M
import qualified StmContainers.Set  as S
import qualified Data.List          as L
import qualified Data.Text          as T
import qualified Data.Hashable      as Hashable
import qualified ListT

import           Network.Connection(initConnectionContext, Connection(..), HostNotResolved)
import           Control.Exception
import           Control.Exception.Base(AsyncException(..))
import           Data.Foldable (traverse_)
import           Data.Maybe    (catMaybes)
import           Control.Monad (zipWithM)
import           Control.Concurrent.STM (atomically)

import Bot.Network
import Bot.Socket
import Bot.StateType
import Bot.Servers
import GHC.Conc (numCapabilities)
--- FUNCTIONS ---------------------------------------------------------------------------------

-- creates a thread and adds its thread ID to an MVar list, kills all
-- listed threads when finished
forkWithKill :: C.MVar [C.ThreadId] -> S.Set ConnectionEq -> IO Quit -> IO (C.MVar ())
forkWithKill tids connections act = do
  handle <- C.newEmptyMVar
  let f (Right AllNetworks)    = kill >> C.putMVar handle ()
      f (Right CurrentNetwork) = print "quitting current network " >> C.putMVar handle ()
      f (Left e)               = print (show e <> " in forkWithKill") >> C.putMVar handle ()
  C.forkFinally spawn f
  return handle
  where
    spawn = withThread act tids
    kill  = do
      -- peacefully quit from the network!
      conns <- atomically $ ListT.toList $ S.listT connections
      traverse (\(ConnectionEq con _) -> quitNetwork con) conns
      threads <- C.readMVar tids
      mytid   <- C.myThreadId
      traverse_ C.killThread (filter (/= mytid) threads)

withThread :: IO a -> C.MVar [C.ThreadId] -> IO a
withThread act tids = do
  tid <- C.myThreadId
  modifyVar (:) tid *> act <* modifyVar L.delete tid
  where
    modifyVar f tid = C.modifyMVar_ tids (return . f tid)

handleSelf :: IO Quit -> IO Quit -> IO Quit
handleSelf f g =
  f `catches` [ Handler (\ (e :: SomeAsyncException) ->
                           print ("AsyncException: " <> show e) >> return CurrentNetwork)
              , Handler (\ (e :: HostNotResolved) ->
                           print "retrying connection" >> g)
              , Handler (\ (e :: SomeException) ->
                           print ("Unknown Exception" <> show e) >> g)]

 --- ENTRY POINT ------------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn $ "number of cores: " ++ show numCapabilities
  nets  <- readNetworks "data/networks.json"
  state <- toGlobalState <$> M.newIO
  case nets of
       Nothing       -> putStrLn "ERROR loading servers from JSON"
       Just networks -> do
         initHash networks (hash state)
         servMap <- initAllServer
         tids    <- C.newMVar []
         connections <- S.newIO
         ctx     <- initConnectionContext
         handles <-
           let listenTry net identifier x@(con,_) = do
                 let conEq = ConnectionEq con identifier
                 atomically (S.insert conEq connections)
                 handleSelf (listen x servMap (netServer net) state)
                            (atomically (S.delete conEq connections) >> listenRetry net identifier)
               listenRetry n ident = do
                 x <- reconnectNetwork servMap ctx n
                 listenTry n ident x
               listenMTry n ident x = fmap (listenTry n ident) x
               listened             = catMaybes . zipWith3 listenMTry networks [1..]
           in do
             mConnVar <- traverse (startNetwork servMap ctx) networks
             traverse (forkWithKill tids connections) (listened mConnVar)
         traverse_ C.takeMVar handles
  where
    initHash :: [IRCNetwork] -> M.Map T.Text HashStorage -> IO ()
    initHash net ht = atomically . sequence_ $ do
      x             <- net
      (chan, modes) <- fromStateConfig (netState x)
      return $ M.insert modes (netServer x <> chan) ht



-- TODO replace manual instances with deriving via
-- Give connection an EQ instance, by supplying an Int
data ConnectionEq = ConnectionEq Connection !Int

instance Eq ConnectionEq where
  (ConnectionEq _ i) == (ConnectionEq _ j) = i == j

instance Hashable.Hashable ConnectionEq where
  hashWithSalt x (ConnectionEq _ i) = Hashable.hashWithSalt x i
