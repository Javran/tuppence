{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module ShipDatabase where

import Language.Lua
import Data.Monoid
import Data.Coerce
import qualified Data.Text as T
import qualified Data.Text.IO as T

import Fetch
import Types

fetchDatabase :: IO ShipDatabase
fetchDatabase = do
    content <- fetchWikiLink "模块:舰娘数据"
    let (TableConst xs) = getRawDatabase (T.pack content)
    pure (ShipDb xs)

-- search the first assign that looks like "_.shipDataTb = dbRaw"
-- and retrieve the expression on RHS
getRawDatabase :: T.Text -> Exp
getRawDatabase raw = dbRaw
  where
    Right (Block stats _) = parseText chunk raw
    Just dbRaw = coerce (foldMap (coerce isTarget) stats :: Alt Maybe Exp)
      where
        isTarget (Assign [SelectName _ (Name n)] [tbl@TableConst {}])
            | n == "shipDataTb"= Just tbl
        isTarget _ = Nothing

-- lookup bindings in a lua table
luaLookup :: String -> Exp -> Maybe Exp
luaLookup k (TableConst xs) = coerce (foldMap (coerce check) xs :: Alt Maybe Exp)
  where
    check (ExpField (String ek) ev)
        | ek == T.pack k = Just ev
    check _ = Nothing

printKeys :: Exp -> IO ()
printKeys (TableConst xs) = mapM_ ppr xs
  where
    ppr (ExpField (String e) tbl) = do
        let v = luaLookup "\"ID\"" tbl
        putStrLn $ T.unpack e ++ " => " ++ show v
    ppr e = putStrLn $ "Unexpected structure: " ++ show e

findMasterId :: String -> ShipDatabase -> Int
findMasterId cid (ShipDb xs) = read (T.unpack x)
  where
    Just shipInfo = luaLookup ("\"" ++ cid ++ "\"") (TableConst xs)
    Just (Number x) = luaLookup "\"ID\"" shipInfo
