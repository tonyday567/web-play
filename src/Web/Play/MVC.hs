{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

-- http://localhost:8001/
-- type 'q' in terminal to quit server

module Web.Play.MVC where

import MVC.Extended

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Control.Monad.State.Strict (State, put, get)
import           Data.Aeson hiding ((.=))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as SC
import qualified Data.ByteString.Lazy.Char8 as C
import           Data.Data
import           Data.Maybe
import           GHC.Generics
import           MVC
import qualified MVC.Prelude as MVC
import qualified Pipes.Extended as Pipes
import           Pipes.Internal (unsafeHoist)
import qualified Pipes.Prelude as Pipes
import           Web.Play.Types
import           Web.Socket
import qualified Pipes.Monoid as Pipes


data In a
  = Stream a
  | Echo a
  | PlayCommand PlayCommand
  | StateChange PlayState
  | SocketComms SocketComms
  | Log String
  | ServerQuit
  deriving (Show, Read, Eq, Data, Typeable, Generic)

instance (FromJSON a) => FromJSON (In a)
instance (ToJSON a) => ToJSON (In a)

makePrisms ''In

parseIn
  :: A.Parser (In a)
parseIn
  =   A.string "go"        *> return (PlayCommand Go) 
  <|> A.string "stop"      *> return (PlayCommand Stop) 
  <|> A.string "quit"      *> return (PlayCommand Quit) 
  <|> A.string "first"     *> return (PlayCommand First) 
  <|> A.string "last"      *> return (PlayCommand Last) 
  <|> A.string "q"         *> return ServerQuit 
  <|> A.string "step "     *> ((PlayCommand . Step)     <$> A.decimal)
  <|> A.string "speed "    *> ((PlayCommand . Speed)    <$> A.double) 

parseInOrRead
  :: (Read a)
  => A.Parser (In a)
parseInOrRead
  =   parseIn
  <|> do
      res <- maybeRead . SC.unpack <$> A.takeByteString
      case res of
          Nothing -> mzero
          Just a -> return a
  where
    maybeRead :: (Read a) => String -> Maybe a
    maybeRead = fmap fst . listToMaybe . Prelude.filter (Prelude.null . snd) . reads 

data Out a
    = StreamOut a
    | PlayStateOut PlayState -- change of state
    | LogOut String
    | SocketOut SocketComms
    deriving (Show, Eq, Data, Typeable, Generic)

instance (FromJSON a) => FromJSON (Out a)
instance (ToJSON a) => ToJSON (Out a)

makePrisms ''Out

-- | default model
mainPipe
  :: (Show a, Eq a)
  => Pipe a b Identity ()
  -> Pipe (In a) (Out b) (State PlayState) ()
mainPipe p
  =   Pipes.until' ServerQuit
  >-> Pipes.until' (SocketComms ServerClosed)
  >-> (  handleStream p
      `Pipes.ma` handlePlayCommand
      `Pipes.ma` handleStateChange
      `Pipes.ma` handleLog)

handleStream
  :: Pipe a b Identity ()
  -> Pipe (In a) (Out b) (State PlayState) ()
handleStream p
  =   Pipes.map (preview _Stream)
  >-> Pipes.justP
  >-> unsafeHoist lift p
  >-> Pipes.map StreamOut

handlePlayCommand
  :: (Eq a)
  => Pipe (In a) (Out b) (State PlayState) ()
handlePlayCommand
  =   Pipes.map (preview _PlayCommand)
  >-> Pipes.justP
  >-> forever (do
  a <- await
  case a of
      Go -> pPlaying .= True
      Stop -> pPlaying .= False
      Quit -> yield (SocketOut CloseSocket)
      First ->
          pTargetFrame .= Just 0
      Last -> do
          end <- use pTotalFrames
          pTargetFrame .= case end of
              Nothing -> Nothing
              Just t -> Just t
          pFast .= True
      Speed t -> pSpeed .= t
      Step t -> do
          pStep .= Just t
          pFast .= True
          pPlaying .= True
  p <- lift get
  yield (PlayStateOut p))

handleStateChange
  :: Pipe (In a) (Out b) (State PlayState) ()
handleStateChange
  =   Pipes.map (preview _StateChange)
  >-> Pipes.justP
  >-> Pipes.chain put
  >-> Pipes.map PlayStateOut

handleLog
  :: (Show a, Monad m)
  => Pipe (In a) (Out b) m ()
handleLog = Pipes.map (preview _Log) >-> Pipes.justP >-> Pipes.map LogOut

producerPlay'
  :: PlayState
  -> Producer a IO ()
  -> Managed (View PlayState, Controller (In a))
producerPlay' initPlay p = join $ managed $ \k -> do
  (oV, iV, sealV) <- spawn' (latest initPlay)
  let resetP = MVC.producer (bounded 1) (producerReset iV p)
  res <- k $ (,) <$> pure (asSink (void . atomically . send oV)) <*> resetP
  atomically sealV
  return res

producerReset :: MVC.Input PlayState -> Producer a IO () -> Producer (In a) IO ()
producerReset i prod = loop' prod prod
  where
    loop' p0 p1 = do
      p <- lift $ fmap fromJust $ atomically $ recv i
      -- lift $ putStrLn $ "loop:" <> show (p^.pPlaying) <> ":"
      case p^.pTargetFrame of
          Nothing ->
              if p^.pPlaying
              then (do
                    lift $
                        unless (p^.pFast) $ sleep (p^.pSpeed)
                    p' <- lift $ fmap fromJust $ atomically $ recv i
                             -- in case its changed during sleep
                    if isNothing (p'^.pTargetFrame) && p'^.pPlaying
                    then (do
                        n <- lift $ next p1
                        case n of
                            Left _ -> return ()
                            Right (a', p1') -> do
                                case p'^.pStep of
                                    Nothing -> yield $ StateChange (pFrame +~ 1 $ p')
                                    Just 1 -> yield $ StateChange (pFrame +~ 1 $ pStep .~ Nothing $ pFast .~ False $ pPlaying .~ False $ p')
                                    Just x' -> yield $ StateChange (pFrame +~ 1 $ pStep .~ Just (x'-1) $ p')
                                yield (Stream a')
                                loop' p0 p1')
                    else (do
                        lift $ sleep (p'^.pSleep)
                        loop' p0 p1))
              else (do
                    lift $ sleep (p^.pSleep)
                    loop' p0 p1)
          Just frame ->
              if | p^.pFrame == frame -> 
                       yield $ StateChange ( 
                       pTargetFrame .~ Nothing $ 
                       pRedraw .~ True $ 
                       pFast .~ False $ 
                       p)
                 | p^.pDropOk && frame < p^.pFrame -> do
                    yield $ StateChange ( 
                           pTargetFrame .~ Nothing $
                           pFrame .~ frame $ 
                           pRedraw .~ True $
                           pPlaying .~ False $ 
                           pFast .~ False $ 
                           p)
                    loop' p0 (p0 >-> Pipes.drop frame)
                 | not (p^.pDropOk) && frame < p^.pFrame -> do
                    yield $ StateChange ( 
                           pRedraw .~ False $
                           pFast .~ True $
                           pFrame .~ 0 $ 
                           p)
                    loop' p0 p0
                 | p^.pDropOk && frame > p^.pFrame -> do
                    yield $ StateChange ( 
                       pTargetFrame .~ Nothing $
                       pFrame .~ frame $ 
                       pRedraw .~ True $ 
                       pFast .~ False $ 
                       p)
                    loop' p0 (p1 >-> Pipes.drop (frame - p^.pFrame))
                 | not (p^.pDropOk) && frame > p^.pFrame -> do
                    yield $ StateChange ( 
                       pRedraw .~ False $ 
                       pFast .~ True $ 
                       p)
                    do
                        n <- lift $ next p1
                        case n of
                            Left _ -> return ()
                            Right (a', p1') ->
                                do
                                    yield $ StateChange (pFrame +~ 1 $ p)
                                    yield (Stream a')
                                    loop' p0 p1'
                 | otherwise -> error "play"

vcPlay
  :: (FromJSON b, ToJSON a, Show b, Show a)
  => PlayState
  -> SocketConfig
  -> Producer b IO ()
  -> Producer (In b) IO ()
  -> Managed (View (Out a), Controller (In b))
vcPlay initialPlay sc prod auto = join $ managed $ \k ->
  k $ do
    (vStream,cStream) <- producerPlay' initialPlay prod
    (vSocket,cSocket) <- wsSocket sc
    (,) <$>
         (handles _PlayStateOut <$>
          pure (contramap
                (Right . (encode :: Out Int -> C.ByteString) .
                 PlayStateOut)
                vSocket))
      <> (handles _PlayStateOut <$>
          pure vStream)
      -- <> pure (contramap show MVC.stdoutLines)
      <> pure (handles _SocketOut (contramap Left vSocket))
      <> (handles _StreamOut <$>
          pure (contramap (Right . encode . StreamOut) vSocket))
        <*> pure (socketToIn <$> cSocket)
          <>  stdinParsed parseIn
          <>  pure cStream
          <>  MVC.producer (bounded 1) auto
  where
    socketToIn (Left comms) = SocketComms comms
    socketToIn (Right x) = case eitherDecode x of
      Left e -> Log $ "decode failed with: " <> e
      Right x' -> x'
