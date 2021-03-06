{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Shared QuickCheck generators for wallet types.
--
-- Our convention is to let each test module define its own @Arbitrary@ orphans.
-- This module allows for code-reuse where desired, by providing generators.
module Cardano.Wallet.Gen
    ( genMnemonic
    , genPercentage
    , shrinkPercentage
    , genLegacyAddress
    , genBlockHeader
    , genActiveSlotCoefficient
    , shrinkActiveSlotCoefficient
    , genSlotNo
    , shrinkSlotNo
    , genTxMetadata
    , shrinkTxMetadata
    ) where

import Prelude

import Cardano.Address.Derivation
    ( xpubFromBytes )
import Cardano.Api.MetaData
    ( TxMetadata (..)
    , TxMetadataJsonSchema (..)
    , TxMetadataValue (..)
    , metadataFromJson
    )
import Cardano.Mnemonic
    ( ConsistentEntropy, EntropySize, Mnemonic, entropyToMnemonic )
import Cardano.Wallet.Primitive.Types
    ( ActiveSlotCoefficient (..)
    , Address (..)
    , BlockHeader (..)
    , Hash (..)
    , ProtocolMagic (..)
    , SlotNo (..)
    )
import Cardano.Wallet.Unsafe
    ( unsafeMkEntropy, unsafeMkPercentage )
import Data.Aeson
    ( ToJSON (..) )
import Data.ByteArray.Encoding
    ( Base (..), convertToBase )
import Data.List
    ( sortOn )
import Data.List.Extra
    ( nubOn )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Percentage (..), Quantity (..) )
import Data.Ratio
    ( denominator, numerator, (%) )
import Data.Text
    ( Text )
import Data.Word
    ( Word, Word32 )
import GHC.TypeLits
    ( natVal )
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , PrintableString (..)
    , choose
    , elements
    , listOf
    , listOf1
    , oneof
    , resize
    , scale
    , shrinkList
    , shrinkMap
    , suchThat
    , vector
    , vectorOf
    )

import qualified Cardano.Byron.Codec.Cbor as CBOR
import qualified Codec.CBOR.Write as CBOR
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

-- | Generates an arbitrary mnemonic of a size according to the type parameter.
--
-- E.g:
-- >>> arbitrary = SomeMnemonic <$> genMnemonic @12
genMnemonic
    :: forall mw ent csz.
     ( ConsistentEntropy ent mw csz
     , EntropySize mw ~ ent
     )
    => Gen (Mnemonic mw)
genMnemonic = do
        let n = fromIntegral (natVal $ Proxy @(EntropySize mw)) `div` 8
        bytes <- BS.pack <$> vector n
        let ent = unsafeMkEntropy @(EntropySize mw) bytes
        return $ entropyToMnemonic ent

genPercentage :: Gen Percentage
genPercentage = unsafeMkPercentage . fromRational . toRational <$> genDouble
  where
    genDouble :: Gen Double
    genDouble = choose (0, 1)

shrinkPercentage :: Percentage -> [Percentage]
shrinkPercentage x = unsafeMkPercentage <$>
    ((% q) <$> shrink p) ++ (map (p %) . filter (/= 0) $ shrink q)
  where
    p = numerator $ getPercentage x
    q = denominator $ getPercentage x

genLegacyAddress
    :: Maybe ProtocolMagic
    -> Gen Address
genLegacyAddress pm = do
    bytes <- BS.pack <$> vector 64
    let (Just key) = xpubFromBytes bytes
    pure $ Address
        $ CBOR.toStrictByteString
        $ CBOR.encodeAddress key
        $ maybe [] (pure . CBOR.encodeProtocolMagicAttr) pm

--
-- Slotting
--


-- | Don't generate /too/ large slots
genSlotNo :: Gen SlotNo
genSlotNo = SlotNo . fromIntegral <$> arbitrary @Word32

shrinkSlotNo :: SlotNo -> [SlotNo]
shrinkSlotNo (SlotNo x) = map SlotNo $ shrink x

genBlockHeader :: SlotNo -> Gen BlockHeader
genBlockHeader sl = do
        BlockHeader sl (mockBlockHeight sl) <$> genHash <*> genHash
      where
        mockBlockHeight :: SlotNo -> Quantity "block" Word32
        mockBlockHeight = Quantity . fromIntegral . unSlotNo

        genHash = elements
            [ Hash "BLOCK01"
            , Hash "BLOCK02"
            , Hash "BLOCK03"
            ]

genActiveSlotCoefficient :: Gen ActiveSlotCoefficient
genActiveSlotCoefficient = ActiveSlotCoefficient <$> choose (0.001, 1.0)

shrinkActiveSlotCoefficient :: ActiveSlotCoefficient -> [ActiveSlotCoefficient]
shrinkActiveSlotCoefficient (ActiveSlotCoefficient f)
        | f < 1 = [1]
        | otherwise = []

sizedMetadataValue :: Int -> Gen Aeson.Value
sizedMetadataValue 0 =
    oneof
        [ toJSON <$> arbitrary @Int
        , toJSON . ("0x"<>) . base16 <$> genByteString
        , toJSON <$> genText
        ]
sizedMetadataValue n =
    oneof
        [ sizedMetadataValue 0
        , oneof
            [ toJSON . HM.fromList <$> resize n
                (listOf $ (,)
                    <$> genText
                    <*> sizedMetadataValue (n-1)
                )
            , toJSON <$> resize n
                (listOf $ sizedMetadataValue (n-1)
                )
            ]
        ]

base16 :: BS.ByteString -> Text
base16 = T.decodeUtf8 . convertToBase Base16

genByteString :: Gen BS.ByteString
genByteString = B8.pack <$> (choose (0, 64) >>= vector)

shrinkByteString :: BS.ByteString -> [BS.ByteString]
shrinkByteString = shrinkMap BS.pack BS.unpack

genText :: Gen Text
genText =
    (T.pack . take 32 . getPrintableString <$> arbitrary) `suchThat` guardText

shrinkText :: Text -> [Text]
shrinkText =
    filter guardText . fmap T.pack . shrink . T.unpack

guardText :: Text -> Bool
guardText t = not ("0x" `T.isPrefixOf` t)

genTxMetadata :: Gen TxMetadata
genTxMetadata = do
    let (maxBreadth, maxDepth) = (3, 3)
    d <- scale (`mod` maxBreadth) $ listOf1 (sizedMetadataValue maxDepth)
    i <- vectorOf @Word (length d) arbitrary
    let json = toJSON $ HM.fromList $ zip i d
    case metadataFromJson TxMetadataJsonNoSchema json of
        Left e -> fail $ show e <> ": " <> show (Aeson.encode json)
        Right metadata -> pure metadata

shrinkTxMetadata :: TxMetadata -> [TxMetadata]
shrinkTxMetadata (TxMetadata m) = TxMetadata . Map.fromList
    <$> shrinkList shrinkTxMetadataEntry (Map.toList m)
  where
    shrinkTxMetadataEntry (k, v) = (k,) <$> shrinkTxMetadataValue v

shrinkTxMetadataValue :: TxMetadataValue -> [TxMetadataValue]
shrinkTxMetadataValue (TxMetaMap xs) =
    TxMetaMap . sortOn fst . nubOn fst <$> shrinkList shrinkPair xs
  where
    shrinkPair (k,v) =
        ((k,) <$> shrinkTxMetadataValue v) ++
        ((,v) <$> shrinkTxMetadataValue k)
shrinkTxMetadataValue (TxMetaList xs) =
    TxMetaList <$> filter (not . null) (shrinkList shrinkTxMetadataValue xs)
shrinkTxMetadataValue (TxMetaNumber i) = TxMetaNumber <$> shrink i
shrinkTxMetadataValue (TxMetaBytes b) = TxMetaBytes <$> shrinkByteString b
shrinkTxMetadataValue (TxMetaText s) = TxMetaText <$> shrinkText s
