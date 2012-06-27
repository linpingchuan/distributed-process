module Main where 

import Prelude hiding (catch)
import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.Foldable (forM_)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar 
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , readMVar
  )
import Control.Monad (replicateM_, replicateM)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (throwIO)
import Control.Applicative ((<$>), (<*>))
import qualified Network.Transport as NT (Transport, closeEndPoint)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types (LocalNode(localEndPoint))
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (Serializable)
import TestAuxiliary

newtype Ping = Ping ProcessId
  deriving (Typeable, Binary, Show)

newtype Pong = Pong ProcessId
  deriving (Typeable, Binary, Show)

-- | The ping server from the paper
ping :: Process ()
ping = do
  Pong partner <- expect
  self <- getSelfPid
  send partner (Ping self)
  ping

-- | Basic ping test
testPing :: NT.Transport -> IO ()
testPing transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    pingServer <- readMVar serverAddr

    let numPings = 10000

    runProcess localNode $ do
      pid <- getSelfPid
      replicateM_ numPings $ do
        send pingServer (Pong pid)
        Ping _ <- expect
        return ()

    putMVar clientDone ()

  takeMVar clientDone

-- | Monitor or link to a remote node
monitorOrLink :: Bool            -- ^ 'True' for monitor, 'False' for link
              -> ProcessId       -- Process to monitor/link to
              -> Maybe (MVar ()) -- MVar to signal on once the monitor has been set up
              -> Process (Maybe MonitorRef) 
monitorOrLink mOrL pid mSignal = do
  result <- if mOrL then Just <$> monitor pid
                    else link pid >> return Nothing
  -- Monitor is asynchronous, which usually does not matter but if we want a
  -- *specific* signal then it does. Therefore we wait an arbitrary delay and
  -- hope that this means the monitor has been set up
  forM_ mSignal $ \signal -> liftIO . forkIO $ threadDelay 100000 >> putMVar signal ()
  return result

monitorTestProcess :: ProcessId       -- Process to monitor/link to
                   -> Bool            -- 'True' for monitor, 'False' for link
                   -> Bool            -- Should we unmonitor?
                   -> DiedReason      -- Expected cause of death
                   -> Maybe (MVar ()) -- Signal for 'monitor set up' 
                   -> MVar ()         -- Signal for successful termination
                   -> Process ()
monitorTestProcess theirAddr mOrL un reason monitorSetup done = 
  catch (do mRef <- monitorOrLink mOrL theirAddr monitorSetup 
            case (un, mRef) of
              (True, Nothing) -> do
                unlink theirAddr
                DidUnlink pid <- expect
                True <- return $ pid == theirAddr
                liftIO $ putMVar done ()
              (True, Just ref) -> do
                unmonitor ref
                DidUnmonitor ref' <- expect
                True <- return $ ref == ref'
                liftIO $ putMVar done ()
              (False, ref) -> do
                MonitorNotification ref' pid reason' <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL && reason == reason'
                liftIO $ putMVar done ()
        )
        (\(LinkException pid reason') -> do
            True <- return $ pid == theirAddr && not mOrL && not un && reason == reason'
            liftIO $ putMVar done ()
        )
  

-- | Monitor an unreachable node 
testMonitorUnreachable :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorUnreachable transport mOrL un = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000 
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar deadProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un DiedDisconnect Nothing done 

  takeMVar done

-- | Monitor a process which terminates normally
testMonitorNormalTermination :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorNormalTermination transport mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode $ 
      liftIO $ readMVar monitorSetup
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $ 
      monitorTestProcess theirAddr mOrL un DiedNormal (Just monitorSetup) done

  takeMVar done

-- | Monitor a process which terminates abnormally
testMonitorAbnormalTermination :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorAbnormalTermination transport mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  let err = userError "Abnormal termination"

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ do
      readMVar monitorSetup
      throwIO err 
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $ 
      monitorTestProcess theirAddr mOrL un (DiedException (show err)) (Just monitorSetup) done

  takeMVar done
    
-- | Monitor a local process that is already dead
testMonitorLocalDeadProcess :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorLocalDeadProcess transport mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  localNode <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  forkIO $ do
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedNoProc Nothing done

  takeMVar done

-- | Monitor a remote process that is already dead
testMonitorRemoteDeadProcess :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorRemoteDeadProcess transport mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedNoProc Nothing done

  takeMVar done

-- | Monitor a process that becomes disconnected
testMonitorDisconnect :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorDisconnect transport mOrL un = do
  processAddr <- newEmptyMVar
  monitorSetup <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000 
    putMVar processAddr addr
    readMVar monitorSetup
    NT.closeEndPoint (localEndPoint localNode)

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar processAddr
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedDisconnect (Just monitorSetup) done
  
  takeMVar done

data Add       = Add    ProcessId Double Double deriving (Typeable) 
data Divide    = Divide ProcessId Double Double deriving (Typeable)
data DivByZero = DivByZero deriving (Typeable)

instance Binary Add where
  put (Add pid x y) = put pid >> put x >> put y
  get = Add <$> get <*> get <*> get

instance Binary Divide where
  put (Divide pid x y) = put pid >> put x >> put y
  get = Divide <$> get <*> get <*> get

instance Binary DivByZero where
  put DivByZero = return ()
  get = return DivByZero

math :: Process ()
math = do
  receiveWait
    [ match (\(Add pid x y) -> send pid (x + y))
    , matchIf (\(Divide _   _ y) -> y /= 0)
              (\(Divide pid x y) -> send pid (x / y))
    , match (\(Divide pid _ _) -> send pid DivByZero)
    ]
  math

-- | Test the math server (i.e., receiveWait)
testMath :: NT.Transport -> IO ()
testMath transport = do
  serverAddr <- newEmptyMVar 
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable 
    addr <- forkProcess localNode math
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    mathServer <- readMVar serverAddr

    runProcess localNode $ do
      pid <- getSelfPid
      send mathServer (Add pid 1 2)
      3 <- expect :: Process Double  
      send mathServer (Divide pid 8 2)
      4 <- expect :: Process Double
      send mathServer (Divide pid 8 0)
      DivByZero <- expect
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Send first message (i.e. connect) to an already terminated process
-- (without monitoring); then send another message to a second process on 
-- the same remote node (we're checking that the remote node did not die)
testSendToTerminated :: NT.Transport -> IO ()
testSendToTerminated transport = do
  serverAddr1 <- newEmptyMVar
  serverAddr2 <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do 
    terminated <- newEmptyMVar
    localNode <- newLocalNode transport initRemoteTable
    addr1 <- forkProcess localNode $ liftIO $ putMVar terminated ()
    addr2 <- forkProcess localNode $ ping
    readMVar terminated
    putMVar serverAddr1 addr1
    putMVar serverAddr2 addr2

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    server1 <- readMVar serverAddr1
    server2 <- readMVar serverAddr2
    runProcess localNode $ do
      pid <- getSelfPid
      send server1 "Hi"
      send server2 (Pong pid)
      Ping pid' <- expect
      True <- return $ pid' == server2 
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test (non-zero) timeout
testTimeout :: NT.Transport -> IO ()
testTimeout transport = do
  localNode <- newLocalNode transport initRemoteTable
  runProcess localNode $ do
    Nothing <- receiveTimeout 1000000 [match (\(Add _ _ _) -> return ())]
    return ()

-- | Test zero timeout
testTimeout0 :: NT.Transport -> IO ()
testTimeout0 transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  messagesSent <- newEmptyMVar

  forkIO $ do 
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode $ do
      liftIO $ readMVar messagesSent >> threadDelay 1000000
      -- Variation on the venerable ping server which uses a zero timeout
      -- Since we wait for all messages to be sent before doing this receive,
      -- we should nevertheless find the right message immediately
      Just partner <- receiveTimeout 0 [match (\(Pong partner) -> return partner)] 
      self <- getSelfPid
      send partner (Ping self)
    putMVar serverAddr addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    server <- readMVar serverAddr
    runProcess localNode $ do
      pid <- getSelfPid
      -- Send a bunch of messages. A large number of messages that the server
      -- is not interested in, and then a single message that it wants
      replicateM_ 10000 $ send server "Irrelevant message"
      send server (Pong pid)
      liftIO $ putMVar messagesSent ()
      Ping _ <- expect 
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test typed channels
testTypedChannels :: NT.Transport -> IO ()
testTypedChannels transport = do
  serverChannel <- newEmptyMVar :: IO (MVar (SendPort (SendPort Bool, Int)))
  clientDone <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    forkProcess localNode $ do
      (serverSendPort, rport) <- newChan
      liftIO $ putMVar serverChannel serverSendPort 
      (clientSendPort, i) <- receiveChan rport
      sendChan clientSendPort (even i)
    return ()

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    serverSendPort <- readMVar serverChannel
    runProcess localNode $ do
      (clientSendPort, rport) <- newChan
      sendChan serverSendPort (clientSendPort, 5) 
      False <- receiveChan rport
      liftIO $ putMVar clientDone ()
      
  takeMVar clientDone 

-- | Test merging receive ports
testMergeChannels :: NT.Transport -> IO ()
testMergeChannels transport = do
    localNode <- newLocalNode transport initRemoteTable
    testFlat localNode True          "aaabbbccc"
    testFlat localNode False         "abcabcabc"
    testNested localNode True True   "aaabbbcccdddeeefffggghhhiii"
    testNested localNode True False  "adgadgadgbehbehbehcficficfi"
    testNested localNode False True  "abcabcabcdefdefdefghighighi"
    testNested localNode False False "adgbehcfiadgbehcfiadgbehcfi"
    testBlocked localNode True
    testBlocked localNode False
  where
    -- Single layer of merging
    testFlat :: LocalNode -> Bool -> String -> IO () 
    testFlat localNode biased expected = 
      runProcess localNode $ do
        rs  <- mapM charChannel "abc" 
        m   <- mergePorts biased rs 
        xs  <- replicateM 9 $ receiveChan m 
        True <- return $ xs == expected
        return ()

    -- Two layers of merging
    testNested :: LocalNode -> Bool -> Bool -> String -> IO ()
    testNested localNode biasedInner biasedOuter expected = 
      runProcess localNode $ do
        rss  <- mapM (mapM charChannel) ["abc", "def", "ghi"]
        ms   <- mapM (mergePorts biasedInner) rss
        m    <- mergePorts biasedOuter ms
        xs   <- replicateM (9 * 3) $ receiveChan m 
        True <- return $ xs == expected
        return ()

    -- Test that if no messages are (immediately) available, the scheduler makes no difference
    testBlocked :: LocalNode -> Bool -> IO ()
    testBlocked localNode biased = do
      vs <- replicateM 3 newEmptyMVar 

      forkProcess localNode $ do
        [sa, sb, sc] <- liftIO $ mapM readMVar vs 
        mapM_ ((>> liftIO (threadDelay 10000)) . uncurry sendChan) 
          [ -- a, b, c
            (sa, 'a')
          , (sb, 'b')
          , (sc, 'c')
            -- a, c, b
          , (sa, 'a')
          , (sc, 'c')
          , (sb, 'b')
            -- b, a, c
          , (sb, 'b')
          , (sa, 'a')
          , (sc, 'c')
            -- b, c, a
          , (sb, 'b')
          , (sc, 'c')
          , (sa, 'a')
            -- c, a, b
          , (sc, 'c')
          , (sa, 'a')
          , (sb, 'b')
            -- c, b, a
          , (sc, 'c')
          , (sb, 'b')
          , (sa, 'a')
          ]

      runProcess localNode $ do
        (ss, rs) <- unzip <$> replicateM 3 newChan
        liftIO $ mapM_ (uncurry putMVar) $ zip vs ss 
        m  <- mergePorts biased rs 
        xs <- replicateM (6 * 3) $ receiveChan m
        True <- return $ xs == "abcacbbacbcacabcba"
        return ()

    mergePorts :: Serializable a => Bool -> [ReceivePort a] -> Process (ReceivePort a)
    mergePorts True  = mergePortsBiased
    mergePorts False = mergePortsRR 

    charChannel :: Char -> Process (ReceivePort Char)
    charChannel c = do
      (sport, rport) <- newChan
      replicateM_ 3 $ sendChan sport c 
      liftIO $ threadDelay 10000 -- Make sure messages have been sent
      return rport

testTerminate :: NT.Transport -> IO ()
testTerminate transport = do
  localNode <- newLocalNode transport initRemoteTable

  pid <- forkProcess localNode $ do
    liftIO $ threadDelay 100000
    terminate

  runProcess localNode $ do
    ref <- monitor pid
    MonitorNotification ref' pid' (DiedException ex) <- expect
    True <- return $ ref == ref' && pid == pid' && ex == show ProcessTerminationException 
    return ()

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  runTests 
    [ ("Ping",             testPing             transport)
    , ("Math",             testMath             transport) 
    , ("Timeout",          testTimeout          transport)
    , ("Timeout0",         testTimeout0         transport)
    , ("SendToTerminated", testSendToTerminated transport) 
    , ("TypedChannnels",   testTypedChannels    transport)
    , ("MergeChannels",    testMergeChannels    transport)
    , ("TestTerminate",    testTerminate        transport)
      -- The "missing" combinations in the list below don't make much sense, as
      -- we cannot guarantee that the monitor reply or link exception will not 
      -- happen before the unmonitor or unlink
    , ("MonitorUnreachable",           testMonitorUnreachable         transport True  False)
    , ("MonitorNormalTermination",     testMonitorNormalTermination   transport True  False)
    , ("MonitorAbnormalTermination",   testMonitorAbnormalTermination transport True  False)
    , ("MonitorLocalDeadProcess",      testMonitorLocalDeadProcess    transport True  False)
    , ("MonitorRemoteDeadProcess",     testMonitorRemoteDeadProcess   transport True  False)
    , ("MonitorDisconnect",            testMonitorDisconnect          transport True  False)
    , ("LinkUnreachable",              testMonitorUnreachable         transport False False)
    , ("LinkNormalTermination",        testMonitorNormalTermination   transport False False)
    , ("LinkAbnormalTermination",      testMonitorAbnormalTermination transport False False)
    , ("LinkLocalDeadProcess",         testMonitorLocalDeadProcess    transport False False)
    , ("LinkRemoteDeadProcess",        testMonitorRemoteDeadProcess   transport False False)
    , ("LinkDisconnect",               testMonitorDisconnect          transport False False)
    , ("UnmonitorNormalTermination",   testMonitorNormalTermination   transport True  True)
    , ("UnmonitorAbnormalTermination", testMonitorAbnormalTermination transport True  True)
    , ("UnmonitorDisconnect",          testMonitorDisconnect          transport True  True)
    , ("UnlinkNormalTermination",      testMonitorNormalTermination   transport False True)
    , ("UnlinkAbnormalTermination",    testMonitorAbnormalTermination transport False True)
    , ("UnlinkDisconnect",             testMonitorDisconnect          transport False True)
    ]