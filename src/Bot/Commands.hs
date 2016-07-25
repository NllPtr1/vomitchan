{-# LANGUAGE Haskell2010       #-}
{-# LANGUAGE OverloadedStrings #-}

--- MODULE DEFINITION ---
module Bot.Commands (
  runCmd,
) where


--- IMPORTS ---
import           Bot.FileOps
import           Bot.MessageType
import           Data.Monoid
import qualified Data.Text       as T


--- TYPES ---

-- type of all command functions
type CmdFunc = Message -> IO (Maybe (T.Text, T.Text))

-- Used for telling if the command is infix or not
type Infix = Bool

type CmdAlias = [T.Text]
--- DATA ---

-- list of admins allowed to use certain commands
-- TODO: Load this from config file
admins :: [T.Text]
admins = ["MrDetonia", "loli"]

-- list of prefixes and corresponding command functions
-- TODO: if the cmdList has over 50~ commands, put it into a hash table instead
cmdList :: [ (CmdFunc, Infix,  CmdAlias)]
cmdList =  [ (cmdBots, False, [".bots", ".bot vomitchan"])
           , (cmdSrc,  False, [".source vomitchan"])
           , (cmdHelp, False, [".help vomitchan"])
           , (cmdQuit, False, [".quit"])
           , (cmdLewd, False, [".lewd "])
           , (cmdLog,  True, ["http","ftp"])]

-- Lists the type of webpages that are logged
cmdWbPg :: [T.Text]
cmdWbPg = ["http", "ftp"]

-- FUNCTIONS ---

-- returns a corresponding command function from a message

runCmd :: CmdFunc
runCmd msg = foldr testFunc (return Nothing) cmdList
  where
    testFunc (cmd, inf, p) k
      | or (flip T.isPrefixOf (msgContent msg) <$> p) ||
       (inf && or (flip T.isInfixOf (msgContent msg) <$> p)) = cmd msg
      | otherwise                                            = k


--- COMMAND FUNCTIONS ---

-- print bot info
cmdBots :: CmdFunc
cmdBots = composeMsg "NOTICE" " :I am a queasy bot written in Haskell by MrDetonia and loli"

-- print source link
cmdSrc :: CmdFunc
cmdSrc = composeMsg "NOTICE" " :[Haskell] https://gitla.in/MrDetonia/vomitchan"

-- prints help information
-- TODO: Store command info in cmdList and generate this text on the fly
cmdHelp :: CmdFunc
cmdHelp = composeMsg "NOTICE" " :Commands: .lewd <someone>, (more to come...)"

-- quit
cmdQuit :: CmdFunc
cmdQuit msg
  | msgUser msg `elem` admins = return $ Just ("QUIT", ":Exiting")
  | otherwise                 = return Nothing

-- lewd someone (rip halpybot)
cmdLewd :: CmdFunc
cmdLewd msg = (composeMsg "PRIVMSG" . actionMe) ("lewds " <> target) msg
  where target = T.tail $ drpMsg msg " "

-- Logs any links posted and appends them to the users .log file
cmdLog :: CmdFunc
cmdLog msg = createUsrFldr msg >> appLogs >> return Nothing
  where allLinks = concat [xs | xs <- flip (drpMsgRec msg) " " <$> cmdWbPg, not $ T.null (head xs)] -- creates a [T.Text]
        linksLn = (<> "\n") <$> allLinks
        appLogs  = mapM_ (appendLog msg) linksLn


-- TODO: add a *vomits* function that grabs random images/links from the channel that it's from and produces rainbow text before and after

-- TODO: add a *cheek pinch* function that puts the bot into reality mode

-- TODO: make reality mode make vomitchan only speak in nods

-- TODO: Reality/*dame* that posts quotes of not moving on and staying locked up
-- TODO: Slumber/*dame* that posts quotes of escapism

-- TODO: add a *zzz* function that causes the bot go into slumber mode

--- HELPER FUNCTIONS ---

-- figures out where to send a response to
msgDest :: Message -> T.Text
msgDest msg
  | "#" `T.isPrefixOf` msgChan msg = msgChan msg
  | otherwise                      = msgNick msg

-- composes the format that the final send message will be
composeMsg :: T.Text -> T.Text -> CmdFunc
composeMsg method str msg = return $ Just (method, msgDest msg <> str)

-- Drops the command message [.lewd *vomits*] sent to vomitchan... T.drop 1 is removed... send it via T.tail msg
drpMsg :: Message -> T.Text -> T.Text
drpMsg msg bk = (snd . T.breakOn bk . msgContent) msg

-- Like drpMsg but does it recursively until the break can't be found anymore
drpMsgRec :: Message -> T.Text -> T.Text ->  [T.Text]
drpMsgRec msg bkL bkR = recurse [] drpMess
  where recurse acc (x,"") = x:acc
        recurse acc (x,xs) = recurse (x:acc) $ (drpRight . snd . drpLeft) xs
        drpMess            = T.breakOn bkR (drpMsg msg bkL)
        drpLeft            = T.breakOn bkL
        drpRight           = T.breakOn bkR


-- Used for /me commands
actionMe :: T.Text -> T.Text
actionMe txt = " :\0001ACTION " <> txt <> "\0001"
