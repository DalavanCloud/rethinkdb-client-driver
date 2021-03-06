{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Main where

import           Control.Applicative

import           Test.Hspec
import           Test.SmallCheck
import           Test.SmallCheck.Series
import           Test.Hspec.SmallCheck

import           Database.RethinkDB

import           Data.Monoid         ((<>))
import           Data.Function
import           Data.List
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HMS
import           Data.Text           (Text)
import qualified Data.Text           as T
import           Data.Vector         (Vector)
import qualified Data.Vector         as V
import           Data.Time
import           Data.Time.Clock.POSIX



instance Monad m => Serial m Datum

instance Monad m => Serial m UTCTime where
    series = cons1 fromInt
      where
        fromInt :: Int -> UTCTime
        fromInt = posixSecondsToUTCTime . fromIntegral

instance Monad m => Serial m ZonedTime where
    series = cons1 (utcToZonedTime utc)

instance Monad m => Serial m Text where
    series = cons1 T.pack

instance Monad m => Serial m (HashMap Text Datum) where
    series = cons1 HMS.fromList

instance (Monad m, Serial m a) => Serial m (Vector a) where
    series = cons1 V.fromList




main :: IO ()
main = do
    h <- newHandle "localhost" defaultPort Nothing (Database "test")

    si <- serverInfo h
    putStrLn "Server Info:"
    print si

    hspec $ spec h


expectSuccess
    :: (Eq (Result a), FromResponse (Result a), Show (Result a))
    => Handle -> Exp a -> Result a -> IO Bool
expectSuccess h query value = do
    res <- run h query
    return $ res == Right value


spec :: Handle -> Spec
spec h = do

    -- The roundtrips test whether the driver generates the proper terms
    -- and the server responds with what the driver expects.
    describe "roundtrips" $ do
        describe "primitive values" $ do
            it "Char" $ property $ \(x :: Char) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "String" $ property $ \(x :: String) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "Double" $ property $ \(x :: Double) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "Text" $ property $ \(x :: Text) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "Array" $ property $ \(x :: Array Datum) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "Object" $ property $ \(x :: Object) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "Datum" $ property $ \(x :: Datum) ->
                monadic $ ((Right x)==) <$> run h (lift x)
            it "ZonedTime" $ property $ \(x :: ZonedTime) ->
                monadic $ (on (==) (fmap zonedTimeToUTC) (Right x)) <$> run h (lift x)

    describe "function expressions" $ do
        it "Add" $ property $ \(xs0 :: [Double]) -> monadic $ do
            -- The list must not be empty, so we prepend a zero to it.
            let xs = 0 : xs0
            expectSuccess h (Add $ map lift xs) (sum xs)

        it "All" $ property $ \(xs0 :: [Bool]) -> monadic $ do
            let xs = True : xs0
            expectSuccess h (All $ map lift xs) (and xs)

        it "Any" $ property $ \(xs0 :: [Bool]) -> monadic $ do
            let xs = True : xs0
            expectSuccess h (Any $ map lift xs) (or xs)

        it "Eq" $ property $ \(a :: Datum, b :: Datum) -> monadic $ do
            expectSuccess h (Eq (lift a) (lift b)) (a == b)

        it "Ne" $ property $ \(a :: Datum, b :: Datum) -> monadic $ do
            expectSuccess h (Ne (lift a) (lift b)) (a /= b)

        it "Lt" $ property $ \(a :: Double, b :: Double) -> monadic $ do
            expectSuccess h (Lt (lift a) (lift b)) (a < b)

        it "Le" $ property $ \(a :: Double, b :: Double) -> monadic $ do
            expectSuccess h (Le (lift a) (lift b)) (a <= b)

        it "Gt" $ property $ \(a :: Double, b :: Double) -> monadic $ do
            expectSuccess h (Gt (lift a) (lift b)) (a > b)

        it "Ge" $ property $ \(a :: Double, b :: Double) -> monadic $ do
            expectSuccess h (Ge (lift a) (lift b)) (a >= b)

        it "Match" $ property $ \() -> monadic $ do
            expectSuccess h (Match "foobar" "^f(.)$") Null

        it "Append" $ property $ \(xs :: Array Datum, v :: Datum) -> monadic $ do
            expectSuccess h (Append (lift xs) (lift v)) (V.snoc xs v)

        it "Prepend" $ property $ \(xs :: Array Datum, v :: Datum) -> monadic $ do
            expectSuccess h (Prepend (lift xs) (lift v)) (V.cons v xs)

        it "IsEmpty" $ property $ \(xs :: Array Datum) -> monadic $ do
            expectSuccess h (IsEmpty (lift xs)) (V.null xs)

        it "Keys" $ property $ \(xs :: Array Text) -> monadic $ do
            let obj = HMS.fromList $ map (\x -> (x, String x)) $ V.toList xs
            res0 <- run h $ Keys (lift obj)
            let res = fmap (sort . V.toList) res0
            return $ res == (Right $ nub $ sort $ V.toList xs)

    describe "function calls" $ do
        it "Add" $ property $ \(a :: Double, b :: Double) -> monadic $ do
            res <- run h $ call2 (+) (lift a) (lift b)
            return $ res == (Right $ a + b)

            res <- run h $ call1 (1+) (lift a)
            return $ res == (Right $ a + 1)

        it "Multiply" $ property $ \(a :: Double, b :: Double) -> monadic $ do
            res <- run h $ call2 (*) (lift a) (lift b)
            return $ res == (Right $ a * b)

            res <- run h $ call1 (3*) (lift a)
            return $ res == (Right $ a * 3)

    describe "lifts" $ do
        it "[Exp a]" $ property $ \(xs :: [Datum]) -> monadic $ do
            expectSuccess h (lift (map lift xs :: [Exp Datum])) (V.fromList xs)

    describe "concurrent queries" $ do
        it "should read all responses from the socket" $ property $ \(a :: Double) -> monadic $ do
            token1 <- start h $ call2 (+) (lift a) (lift a)
            token2 <- start h $ call2 (*) (lift a) (lift a)
            Right res2 <- nextResult h token2
            Right res1 <- nextResult h token1

            return $ res1 == a+a && res2 == a*a
