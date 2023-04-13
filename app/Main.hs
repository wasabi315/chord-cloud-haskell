import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Monad.Trans.Class
import Data.Binary
import Data.Function
import Data.List
import Data.Typeable
import GHC.Generics
import Network.Transport.TCP
import System.Console.Haskeline

data Balance = Balance ProcessId
  deriving stock (Generic, Typeable)
  deriving anyclass (Binary)

data Deposit = Deposit ProcessId Int
  deriving stock (Generic, Typeable)
  deriving anyclass (Binary)

data Withdraw = Withdraw ProcessId Int
  deriving stock (Generic, Typeable)
  deriving anyclass (Binary)

data OK = OK Int
  deriving stock (Generic, Typeable)
  deriving anyclass (Binary)

data Error a = Error a Int
  deriving stock (Generic, Typeable)
  deriving anyclass (Binary)

bankServer :: Int -> Process ()
bankServer balance = do
  receiveWait
    [ match $ \(Balance client) -> do
        send client $ OK balance
        bankServer balance
    , match $ \(Deposit client n) -> do
        let balance' = balance + n
        send client $ OK balance'
        bankServer balance'
    , match $ \case
        Withdraw client n
          | n <= balance -> do
              let balance' = balance - n
              send client $ OK balance'
              bankServer balance'
          | otherwise -> do
              send client $ Error "insufficient funds" balance
              bankServer balance
    ]

bankClient :: ProcessId -> InputT Process ()
bankClient server = do
  self <- lift getSelfPid

  fix $ \loop -> do
    getInputLine "% " >>= \case
      Just "quit" -> pure ()
      Just "balance" -> do
        lift $ send server (Balance self)
        OK balance <- lift expect
        outprint balance
        loop

      Just input@(("deposit " `isPrefixOf`) -> True) -> do
        let n = read $ drop 8 input :: Int
        lift $ send server (Deposit self n)
        OK balance <- lift expect
        outprint balance
        loop

      Just input@(("withdraw " `isPrefixOf`) -> True) -> do
        let n = read $ drop 8 input :: Int
        lift $ send server (Withdraw self n)
        result <- lift $ receiveWait
          [ match $ \(OK balance) -> do
              pure $ Right balance
          , match $ \(Error reason balance) -> do
              pure $ Left (reason, balance)
          ]
        case result of
          Right balance -> do
            outprint balance
          Left (reason, balance) -> do
            outputStrLn $ "withdrawal failed: " ++ reason
            outprint balance
        loop

      _ -> loop

  where
    outprint = outputStrLn . show

main :: IO ()
main = do
  Right t <- createTransport (defaultTCPAddr "127.0.0.1" "8000") defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  runProcess node . runInputT defaultSettings $ do
    serverPID <- lift . spawnLocal $ bankServer 0
    bankClient serverPID
