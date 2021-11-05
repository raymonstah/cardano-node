import           Test.Tasty

import qualified Cardano.Tracer.Test.Logs.Tests as Logs
import qualified Cardano.Tracer.Test.Network.Tests as Network
import qualified Cardano.Tracer.Test.Queue.Tests as Queue

main :: IO ()
main = defaultMain $
  testGroup "cardano-tracer"
    [ Logs.tests
    , Network.tests
    , Queue.tests
    ]