{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Projector.Html.Core.Elaborator (
    elaborate
  ) where


import           Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE

import           P

import           Projector.Core
import           Projector.Html.Data.Prim
import qualified Projector.Html.Core.Library as Lib
import           Projector.Html.Data.Template


elaborate :: Template a -> HtmlExpr a
elaborate (Template _ mts html) =
  eTypeSigs mts (eHtml html)

eTypeSigs :: Maybe (TTypeSig a) -> (HtmlExpr a -> HtmlExpr a)
eTypeSigs msigs =
  mcase msigs id $ \(TTypeSig a sigs) ->
    foldl' (\f (TId x, ty) -> f . ELam a (Name x) (Just (eType ty))) id sigs

eType :: TType a -> HtmlType
eType ty =
  case ty of
    TTVar _ (TId x) ->
      case parsePrimT x of
        Just p ->
          TLit p
        _ ->
          TVar (TypeName x)

--    TTList _ t ->
--      TList (eType t)
    -- TTApp to come eventually

eHtml :: THtml a -> HtmlExpr a
eHtml (THtml a nodes) =
  ECon a (Constructor "Html") Lib.nHtml [EList a Lib.tHtmlNode (fmap eNode nodes)]

eNode :: TNode a -> HtmlExpr a
eNode node =
  case node of
    TWhiteSpace a ->
      ECon a (Constructor "Whitespace") Lib.nHtmlNode []
    TPlain a (TPlainText t) ->
      ECon a (Constructor "Plain") Lib.nHtmlNode [stringLit a t]
    TComment a (TPlainText t) ->
      ECon a (Constructor "Comment") Lib.nHtmlNode [stringLit a t]
    TVoidElement a tag attrs ->
      ECon a (Constructor "VoidElement") Lib.nHtmlNode [
          eTag tag
        , eAttrs a attrs
        ]
    TElement a tag attrs html ->
      ECon a (Constructor "Element") Lib.nHtmlNode [
          eTag tag
        , eAttrs a attrs
        , eHtml html
        ]
    TExprNode a expr ->
      ECon a (Constructor "Nested") Lib.nHtmlNode [
          eExpr expr
        ]

eTag :: TTag a -> HtmlExpr a
eTag (TTag a t) =
  ECon a (Constructor "Tag") Lib.nTag [stringLit a t]

eAttrs :: a -> [TAttribute a] -> HtmlExpr a
eAttrs a =
  EList a Lib.tAttribute . fmap eAttr

eAttr :: TAttribute a -> HtmlExpr a
eAttr attr =
  case attr of
    TAttribute a name aval ->
      ECon a (Constructor "Attribute") Lib.nAttribute [
          eAttrKey a name
        , eAttrVal aval
        ]
    TEmptyAttribute a name ->
      ECon a (Constructor "Attribute") Lib.nAttribute [
          eAttrKey a name
        , eAttrVal (TQuotedAttrValue a (TPlainText ""))
        ]

eAttrKey :: a -> TAttrName -> HtmlExpr a
eAttrKey a (TAttrName n) =
  ECon a (Constructor "AttributeKey") Lib.nAttributeKey [stringLit a n]

eAttrVal :: TAttrValue a -> HtmlExpr a
eAttrVal aval =
  let mkVal a t =
        ECon  a (Constructor "AttributeValue") Lib.nAttributeValue [t]
  in case aval of
       TQuotedAttrValue a (TPlainText t) ->
         mkVal a (stringLit a t)
       TAttrExpr _ expr ->
         eExpr expr

eExpr :: TExpr a -> HtmlExpr a
eExpr expr =
  case expr of
    TEVar a (TId x) ->
      EVar a (Name x)
    TELam a bnds bdy ->
      funX a (fmap (Name . unTId) bnds) (eExpr bdy)
    TEApp a f g ->
      EApp a (eExpr f) (eExpr g)
    TECase a e alts ->
      ECase a (eExpr e) (NE.toList (fmap eAlt alts))
    TELit _ l ->
      eLit l
    TEEach a f g ->
      EMap a (eExpr f) (eExpr g)
    TENode a e ->
      ECon a (Constructor "Html") Lib.nHtml [
          EList a Lib.tHtmlNode [eNode e]
        ]

eLit :: TLit a -> HtmlExpr a
eLit l =
  case l of
    TLString a s ->
      ELit a $ VString s

-- curried function
funX :: a -> NonEmpty Name -> HtmlExpr a -> HtmlExpr a
funX a bnds bdy =
  foldr (\n expr -> ELam a n Nothing expr) bdy bnds

eAlt :: TAlt a -> (Pattern a, HtmlExpr a)
eAlt (TAlt _ pat body) =
  (ePat pat, eExpr body)

ePat :: TPattern a -> Pattern a
ePat pat =
  -- TODO find something we can do with these annotations
  case pat of
    TPVar a (TId x) ->
      PVar a (Name x)
    TPCon a (TConstructor x) pats ->
      PCon a (Constructor x) (fmap ePat pats)

stringLit :: a -> Text -> HtmlExpr a
stringLit a =
  ELit a . VString
