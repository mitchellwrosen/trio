module Ki.Indef.Thread
  ( Thread (..),
    await,
    awaitSTM,
    awaitFor,
    kill,
    --
    timeout,

    -- * Internal API
    AsyncThreadFailed (..),
    unwrapAsyncThreadFailed,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (AsyncException (ThreadKilled), Exception (..), SomeException, asyncExceptionFromException, asyncExceptionToException)
import Control.Monad (join)
import Data.Functor (($>), void)
import GHC.Generics (Generic)
import Ki.Indef.Seconds (Seconds)
import qualified Ki.Indef.Seconds as Seconds
import Ki.Sig (IO, STM, ThreadId, atomically, registerDelay, throwTo)
import Prelude hiding (IO)

data Thread a = Thread
  { threadId :: !ThreadId,
    action :: !(STM (Either SomeException a))
  }
  deriving stock (Functor, Generic)

instance Eq (Thread a) where
  Thread id1 _ == Thread id2 _ =
    id1 == id2

instance Ord (Thread a) where
  compare (Thread id1 _) (Thread id2 _) =
    compare id1 id2

await :: Thread a -> IO (Either SomeException a)
await =
  atomically . awaitSTM

awaitSTM :: Thread a -> STM (Either SomeException a)
awaitSTM Thread {action} =
  action

awaitFor :: Thread a -> Seconds -> IO (Maybe (Either SomeException a))
awaitFor thread seconds =
  timeout seconds (pure . Just <$> awaitSTM thread) (pure Nothing)

kill :: Thread a -> IO ()
kill thread = do
  throwTo (threadId thread) ThreadKilled
  void (await thread)

newtype AsyncThreadFailed
  = AsyncThreadFailed SomeException
  deriving stock (Show)

instance Exception AsyncThreadFailed where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException

unwrapAsyncThreadFailed :: SomeException -> SomeException
unwrapAsyncThreadFailed ex =
  case fromException ex of
    Just (AsyncThreadFailed exception) -> exception
    _ -> ex

-- Misc. utils

timeout :: Seconds -> STM (IO a) -> IO a -> IO a
timeout seconds action fallback = do
  (delay, unregister) <- registerDelay (Seconds.toMicros seconds)
  join (atomically (delay $> fallback <|> (unregister >>) <$> action))
