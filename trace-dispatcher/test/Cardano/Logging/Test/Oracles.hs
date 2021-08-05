{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Logging.Test.Oracles (
    oracleFiltering
  , occurences
  ) where

import qualified Data.Text as T
import           Test.QuickCheck
import           Text.Read (readMaybe)

import           Cardano.Logging
import           Cardano.Logging.Test.Messages
import           Cardano.Logging.Test.Types

import Debug.Trace


-- | Checks for every message that it appears or does not appear at the right
-- backend. Tests filtering and routing to backends
oracleFiltering ::  TraceConfig -> ScriptRes -> Property
oracleFiltering conf ScriptRes {..} =
    let Script msgs = srScript
    in property $ and (map oracleMessage msgs)
  where
    oracleMessage :: ScriptedMessage -> Bool
    oracleMessage (ScriptedMessage _t msg) =
      let filterSeverity = getSeverity conf ("Node" : namesForMessage msg)
          backends = getBackends conf ("Node" : namesForMessage msg)
          inStdout = hasStdoutBackend backends
                      && fromEnum (severityForMessage msg) >= fromEnum filterSeverity
          isCorrectStdout = includedExactlyOnce msg srStdoutRes == inStdout
          inForwarder = elem Forwarder backends
                      && fromEnum (severityForMessage msg) >= fromEnum filterSeverity
                      && privacyForMessage msg == Public
          isCorrectForwarder = includedExactlyOnce msg srForwardRes == inForwarder
          inEKG = elem EKGBackend backends
                      && fromEnum (severityForMessage msg) >= fromEnum filterSeverity
                      && not (null (asMetrics msg))
          isCorrectEKG = includedExactlyOnce msg srEkgRes == inEKG
      -- in trace ("\n *** oracleFiltering isCorrectStdout " <> show isCorrectStdout <>
      --           " isCorrectForwarder " <> show isCorrectForwarder <>
      --           " isCorrectEKG " <> show isCorrectEKG) $
      in trace "\n***" isCorrectStdout && isCorrectForwarder && isCorrectEKG

-- | Is the stdout backend included in this configuration
hasStdoutBackend :: [BackendConfig] -> Bool
hasStdoutBackend []             = False
hasStdoutBackend (Stdout _ : _) = True
hasStdoutBackend (_ : rest)     = hasStdoutBackend rest

-- | Is this message in some form included in the formatted messages exactly once
includedExactlyOnce :: Message -> [FormattedMessage] -> Bool
includedExactlyOnce msg list =
    let msgID = getMessageID msg
    in case occurences msgID list of
          1 -> True
          0 -> False
          _ -> error $ "Multiple occurences of message " <> show msgID

-- | How often does the message with this id appears in the list of
-- formatted messsages?
occurences :: MessageID -> [FormattedMessage] -> Int
occurences _mid [] = 0
occurences  mid (fmsg : rest) = if isMessageWithId mid fmsg
                                  then 1 + occurences mid rest
                                  else occurences mid rest

-- | Returns true if the given message has this id, otherwise fals
isMessageWithId :: MessageID -> FormattedMessage -> Bool
isMessageWithId mid (FormattedMetrics [IntM _ idm])
                                        = fromIntegral idm == mid
isMessageWithId _   (FormattedMetrics [])   = False
isMessageWithId mid (FormattedHuman _ txt)  = idInText mid txt
isMessageWithId mid (FormattedMachine txt)  = idInText mid txt
isMessageWithId mid (FormattedForwarder to) =
  case toHuman to of
    Just txt -> idInText mid txt
    Nothing  -> case toMachine to of
                  Just txt -> idInText mid txt
                  Nothing  -> error "No text found in trace object"

-- | Is this message id part of the text?
idInText :: MessageID -> T.Text -> Bool
idInText mid txt =
  case extractId txt of
    Nothing -> False
    Just i  -> i == mid

-- | Extract a messageID from a text. It is always fumnd in the form '<?..>'
extractId :: T.Text -> Maybe Int
extractId txt =
  let ntxt = T.takeWhile (\c -> c /= '>')
                (T.drop 1
                  (T.dropWhile (\c -> c /= '<') txt))
  in readMaybe (T.unpack ntxt)