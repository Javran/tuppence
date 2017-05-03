{-# OPTIONS_GHC
    -fwarn-partial-type-signatures
  #-}
{-# LANGUAGE
    PartialTypeSignatures
  , ScopedTypeVariables
  , NoMonomorphismRestriction
  #-}
module Kantour.MapTool.Main where

import System.Environment
import Data.List
import Data.Maybe
import Control.Monad

import Linear
import Linear.Affine
import Data.Function
import Text.JSON
import Data.Monoid
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Exit

import Kantour.MapTool.Types
import Kantour.MapTool.Draw
import Kantour.MapTool.Xml

{-

implementation of:

https://github.com/yukixz/kcmap/blob/master/kcmap.es

in Haskell

and perhaps more.

related links:

an explanation can be found at:

http://blog.dazzyd.org/blog/how-to-draw-a-kancolle-map/

-}

{-

terms: (pick the most precise term on conflict)

- "main" for things that can be tracked back to sprite with name "map"
- "extra" for things that can be tracked back to a sprite with name prefixed "extra"
- "hidden" for things that come from the separated encoded binary file.

-}

{-

TODO:

- allow gradual correction of node names

    - add ".nodes.json" to main map file to produce the node name mapping.
      e.g. if main map file is "37_01.xml", mapping file will be called "37_01.xml.nodes.json"

- none-overlapping of edges...

-}

defaultMain :: IO ()
defaultMain = do
    mArgs <- sepArgs <$> getArgs
    case mArgs of
        Nothing -> do
            putStrLn "invalid arguments"
            putStrLn "usage: maptool <main xml> [hidden xml] [-- diagrams args]"
            putStrLn "the argument list passing to diagrams, if exists, has to be non empty"
            exitFailure
        Just ((srcFP, mHiddenFP), mDiagramArgs) -> do
            -- pretty printing arguments
            putStrLn $ "main xml: " ++ srcFP
            putStrLn $ "hidden xml: " ++ fromMaybe "<N/A>" mHiddenFP
            putStrLn $ "args to diagrams: " ++ maybe "<N/A>" unwords mDiagramArgs
            (mainRoutes, mainBeginNodes) <- safeParseXmlDoc extractFromMain srcFP
            {- TODO: list hidden sprite roots
            tmp <-
                case mHiddenFP of
                    Just hiddenFP -> do
                        parsed <- parseXmlDoc findHiddenSpriteRoots hiddenFP
                        case parsed of
                            Left errMsg -> do
                                putStrLn $ "Parse error: " ++ errMsg
                                pure []
                            Right v -> pure v -}
            (hiddenRoutes, hiddenBeginNodes) <-
                case mHiddenFP of
                    Just hiddenFP -> safeParseXmlDoc extractFromHidden hiddenFP
                    Nothing -> pure ([], [])
            putStrLn "====="
            -- the coordinates look like large numbers because SWF uses twip as basic unit
            -- (most of the time) divide them by 20 to get pixels
            let beginNodes = mainBeginNodes ++ hiddenBeginNodes
                adjustedRoutes = adjustLines beginNodes (mainRoutes ++ hiddenRoutes)
                pointMap = mkPointMap beginNodes adjustedRoutes
                mapInfo = MapInfo adjustedRoutes (S.fromList beginNodes) pointMap
            case mDiagramArgs of
                Nothing -> pure ()
                Just diagramArgs -> withArgs diagramArgs $ draw mapInfo
            putStrLn "=== JSON encoding ==="
            putStrLn (encodeStrict (linesToJSValue adjustedRoutes pointMap))

-- separate argument list into maptool arguments and those meant for diagrams:
-- arg list: <main xml> [hidden xml] [-- <diagram args>]
-- where <main xml> is the map xml file, [hidden xml] is an optional part.
-- additionally, if "--" exists and <diagram args> is not empty, diagram will be called
-- to draw a picture.
sepArgs :: [String] -> Maybe ((String, Maybe String), Maybe [String])
sepArgs as = do
    let (ls,rs') = break (== "--") as
    lVal <- case ls of
        [] -> Nothing
        mainXmlFP : ls' -> case ls' of
            [] -> pure (mainXmlFP, Nothing)
            [extraXmlFP] -> pure (mainXmlFP, Just extraXmlFP)
            _ -> Nothing
    let rVal = case rs' of
            [] -> Nothing
            -- the "_" part as to be "--" as it's the result from "break"
            _:xs -> guard (not (null xs)) >> pure xs
    pure (lVal, rVal)

{-
begin point of each edge is estimated from end point and the shape info of the line
so we need to adjust begin points for each line, this is done by picking the closest
"confirmed point" from the estimated begin point.

"confirmed point" includes begin points of a map, and end point of all edges.
-}
adjustLines :: [V2 Int] -> [MyLine] -> [MyLine]
adjustLines startPts ls = adjustLine <$> ls
  where
    confirmedPoints = startPts ++ (_lEnd <$> ls)
    adjustLine :: MyLine -> MyLine
    adjustLine l@(MyLine _ lStartPt _) = l { _lStart = adjustedStartPt }
      where
        adjustedStartPt = minimumBy (compare `on` qdA lStartPt) confirmedPoints

{-
guess names for each node:

- begin nodes are named "<n>" where n is a number.
  However just keep that in mind that
  in KC3Kai edges.json file, there's no distinction between begin nodes and all are called just "Start".

- for all the other nodes, the name of a node depends on the name of edges pointing to it.
  for an edge with name "line1", this will be "A", and "B" for "line2", "C" for "line3" etc.
  if there are multiple edges pointing to one node, one with the least number wins.

- note that these naming rules are not always working. so one needs to take a closer look on generated data.

-}
mkPointMap :: [V2 Int] -> [MyLine] -> M.Map (V2 Int) String
mkPointMap beginNodes xs = M.union beginNodeNames endNodeNames
  where
    beginNodeNames = M.fromList (zip beginNodes (formatName <$> [1::Int ..]))
      where
        formatName x = "<" ++ show x ++ ">"

    -- collect all possible names and pick the minimal one
    endNodeNames = M.map getMin
                   (M.fromListWith (++)
                    (map convert xs))

    getMin = minimumBy (\x y -> compare (length x) (length y) <> compare x y)
    lineToInt l = read (simpleLName l)
    nodeNameFromInt v
        | v-1 < length ns = ns !! (v-1)
        | otherwise = show v
      where
        ns = map (:[]) ['A'..'Z']

    convert l = (_lEnd l,[nodeNameFromInt .lineToInt $ l])

linesToJSValue :: [MyLine] -> M.Map (V2 Int) String -> JSValue
linesToJSValue xs nnames = JSObject (toJSObject (convert <$> ys))
  where
    ys = sortBy (compare `on` (\l -> read (simpleLName l) :: Int)) xs
    getNm v = makeStart (fromMaybe "Unknown" (M.lookup v nnames))
      where
        makeStart ('<':_) = "Start"
        makeStart v' = v'
    convert :: MyLine -> (String, JSValue)
    convert l = (simpleLName l,JSArray (f <$> [getNm (_lStart l),getNm (_lEnd l)]))
      where
        f = JSString . toJSString
