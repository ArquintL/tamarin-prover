{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright   : (c) 2010, 2011 Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
-- 
-- Maintainer  : Benedikt Schmidt <beschmi@gmail.com>
--
-- Pretty printing and parsing of Maude terms and replies.
module Term.Maude.Parser (
  -- * pretty printing of terms for Maude
    ppMaude
  , ppTheory

  -- * parsing of Maude replies
  , parseUnifyReply
  , parseMatchReply
  , parseReduceReply
  ) where

import Term.LTerm
import Term.Maude.Types
import Term.Maude.Signature
import Term.Rewriting.Definitions

import Control.Monad.Bind

import Control.Basics

import qualified Data.Set as S

import qualified Data.ByteString as B
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC

import Data.Attoparsec.ByteString.Char8

import Extension.Data.Monoid

------------------------------------------------------------------------------
-- Pretty printing of Maude terms.
------------------------------------------------------------------------

-- | Pretty print an 'LSort'.
ppLSort :: LSort -> ByteString
ppLSort s = case s of
    LSortPub       -> "Pub"
    LSortFresh     -> "Fresh"
    LSortMsg       -> "Msg"
    LSortNode      -> "Node"
    (LSortUser st) -> B.concat ["tamU", BC.pack st]

ppLSortSym :: LSort -> ByteString
ppLSortSym lsort = case lsort of
    LSortFresh     -> "f"
    LSortPub       -> "p"
    LSortMsg       -> "c"
    LSortNode      -> "n"
    (LSortUser st) -> B.concat ["tu", BC.pack st]

parseLSortSym :: ByteString -> Maybe LSort
parseLSortSym s = case s of
    "f"  -> Just LSortFresh
    "p"  -> Just LSortPub
    "c"  -> Just LSortMsg
    "n"  -> Just LSortNode
    _    ->
      if BC.head s == 'u'
        then Just (LSortUser $ BC.unpack $ BC.tail s)
        else Nothing

-- | Used to prevent clashes with predefined Maude function symbols
--   like @true@
funSymPrefix :: ByteString
funSymPrefix = "tamX"

-- | Prefix for private function symbols.
funSymPrefixPriv :: ByteString
funSymPrefixPriv = "tamP"

-- | Pretty print an AC symbol for Maude.
ppMaudeACSym :: ACSym -> ByteString
ppMaudeACSym o =
    funSymPrefix <> case o of
                      Mult  -> "mult"
                      Union -> "mun"

-- | Pretty print a non-AC symbol for Maude.
ppMaudeNoEqSym :: NoEqSym -> ByteString
ppMaudeNoEqSym (o,(_,(Private,_))) = funSymPrefixPriv <> o
ppMaudeNoEqSym (o,(_,(Public,_)))  = funSymPrefix     <> o

-- | Pretty print a C symbol for Maude.
ppMaudeCSym :: CSym -> ByteString
ppMaudeCSym EMap = funSymPrefix <> emapSymString


-- | @ppMaude t@ pretty prints the term @t@ for Maude.
ppMaude :: Term MaudeLit -> ByteString
ppMaude t = case viewTerm t of
    Lit (MaudeVar i lsort)   -> "x" <> ppInt i <> ":" <> ppLSort lsort
    Lit (MaudeConst i lsort) -> ppLSortSym lsort <> "(" <> ppInt i <> ")"
    Lit (FreshVar _ _)       -> error "Term.Maude.Types.ppMaude: FreshVar not allowed"
    FApp (NoEq fsym) []      -> ppMaudeNoEqSym fsym
    FApp (NoEq fsym) as      -> ppMaudeNoEqSym fsym <> ppArgs as
    FApp (C fsym) as         -> ppMaudeCSym fsym    <> ppArgs as
    FApp (AC op) as          -> ppMaudeACSym op     <> ppArgs as
    FApp List as             -> "list(" <> ppList as <> ")"
  where
    ppArgs as     = "(" <> (B.intercalate "," (map ppMaude as)) <> ")"
    ppInt         = BC.pack . show
    ppList []     = "nil"
    ppList (x:xs) = "cons(" <> ppMaude x <> "," <> ppList xs <> ")"

------------------------------------------------------------------------------
-- Pretty printing a 'MaudeSig' as a Maude functional module.
------------------------------------------------------------------------------

-- | The term algebra and rewriting rules as a functional module in Maude.
ppTheory :: MaudeSig -> ByteString
ppTheory msig = BC.unlines $
    [ "fmod MSG is"
    , "  protecting NAT ."
    , "  sort Pub Fresh Msg Node " <> theoryUserSortIds userSorts <> " TOP ."
    , "  subsort Pub < Msg ."
    , "  subsort Fresh < Msg ."
    , "  subsort Msg < TOP ."
    , "  subsort Node < TOP ."
    -- constants
    , "  op f : Nat -> Fresh ."
    , "  op p : Nat -> Pub ."
    , "  op c : Nat -> Msg ."
    , "  op n : Nat -> Node ." ]
    ++
    -- user-defined sorts
    concatMap theoryUserSorts userSorts
    ++
    -- used for encoding FApp List [t1,..,tk]
    -- list(cons(t1,cons(t2,..,cons(tk,nil)..)))
    [ "  op list : TOP -> TOP ."
    , "  op cons : TOP TOP -> TOP ."
    , "  op nil  : -> TOP ." ]
    ++
    (if enableMSet msig
       then
       [ theoryOp "mun : Msg Msg -> Msg [comm assoc]" ]
       else [])
    ++
    (if enableDH msig
       then
       [ theoryOp "one : -> Msg"
       , theoryOp "exp : Msg Msg -> Msg"
       , theoryOp "mult : Msg Msg -> Msg [comm assoc]"
       , theoryOp "inv : Msg -> Msg" ]
       else [])
    ++
    (if enableBP msig
       then
       [ theoryOp "pmult : Msg Msg -> Msg"
       , theoryOp "em : Msg Msg -> Msg [comm]" ]
       else [])
    ++
    map theoryFunSym (S.toList $ stFunSyms msig)
    ++
    map theoryRule (S.toList $ rrulesForMaudeSig msig)
    ++
    [ "endfm" ]
  where
    userSorts = S.toList $ userSortsForMaudeSig msig

    theoryUserSortIds = BC.unwords . map ppLSort
    theoryUserSorts sort =
      [ "  subsort " <> ppLSort sort <> " < Msg ."
      , "  op " <> ppLSortSym sort <> " : Nat -> " <> ppLSort sort <> " ." ]

    theoryOpNoEq priv fsort =
        "  op " <> (if (priv==Private) then funSymPrefixPriv else funSymPrefix) <> fsort <>" ."
    theoryOp = theoryOpNoEq Public
    -- TODO: Take into account sort restrictions
    theoryFunSym (s,(ar,(priv,sorts))) =
        theoryOpNoEq priv (s <> " : " <> (maybe (theorySorts ar) (B.concat . theoryCustomSorts) sorts))
    theoryRule (l `RRule` r) =
        "  eq " <> ppMaude lm <> " = " <> ppMaude rm <> " ."
      where (lm,rm) = evalBindT ((,) <$> lTermToMTerm' l <*> lTermToMTerm' r) noBindings
                        `evalFresh` nothingUsed

    theorySorts ar = (B.concat $ replicate ar "Msg ") <> "-> Msg"

    theoryCustomSorts []     = []
    theoryCustomSorts [x]    = [BC.pack "-> ", sortMaudeName x]
    theoryCustomSorts (x:xs) = [sortMaudeName x, BC.pack " "] ++ theoryCustomSorts xs 

    -- Prefix non-builtin sorts with "tamU" prefix to avoid clashes
    sortMaudeName :: String -> ByteString
    sortMaudeName "Msg"   = BC.pack "Msg"
    sortMaudeName "Fresh" = BC.pack "Fresh"
    sortMaudeName "Pub"   = BC.pack "Pub"
    sortMaudeName st      = B.concat [BC.pack "tamU", BC.pack st]

-- Parser for Maude output
------------------------------------------------------------------------

-- | @parseUnifyReply reply@ takes a @reply@ to a unification query
--   returned by Maude and extracts the unifiers.
parseUnifyReply :: MaudeSig -> ByteString -> Either String [MSubst]
parseUnifyReply msig reply = flip parseOnly reply $
    choice [ string "No unifier." *> endOfLine *> pure []
           , many1 (parseSubstitution msig) ]
        <* endOfInput

-- | @parseMatchReply reply@ takes a @reply@ to a match query
--   returned by Maude and extracts the unifiers.
parseMatchReply :: MaudeSig -> ByteString -> Either String [MSubst]
parseMatchReply msig reply = flip parseOnly reply $
    choice [ string "No match." *> endOfLine *> pure []
           , many1 (parseSubstitution msig) ]
        <* endOfInput

-- | @parseSubstitution l@ parses a single substitution returned by Maude.
parseSubstitution :: MaudeSig -> Parser MSubst
parseSubstitution msig = do
    endOfLine *> string "Solution " *> takeWhile1 isDigit *> endOfLine
    choice [ string "empty substitution" *> endOfLine *> pure []
           , many1 parseEntry]
  where 
    parseEntry = (,) <$> (flip (,) <$> (string "x" *> decimal <* string ":") <*> parseSort)
                     <*> (string " --> " *> parseTerm msig <* endOfLine)

-- | @parseReduceReply l@ parses a single solution returned by Maude.
parseReduceReply :: MaudeSig -> ByteString -> Either String MTerm
parseReduceReply msig reply = flip parseOnly reply $ do
    string "result " *> choice [ string "TOP" *> pure LSortMsg, parseSort ] -- we ignore the sort
        *> string ": " *> parseTerm msig <* endOfLine <* endOfInput

-- | Parse an 'MSort'.
parseSort :: Parser LSort
parseSort =  string "Pub"      *> return LSortPub
         <|> string "Fresh"    *> return LSortFresh
         <|> string "Node"     *> return LSortNode
         <|> string "tamU"     *> -- Sorts with U* are user-defined
               ( sortIdent    >>= return . LSortUser . BC.unpack )
         <|> string "M"        *> -- FIXME: why?
               ( string "sg"   *> return LSortMsg )
  where
    sortIdent = takeWhile1 (`BC.notElem` (":(,)\n " :: B.ByteString))

-- | @parseTerm@ is a parser for Maude terms.
parseTerm :: MaudeSig -> Parser MTerm
parseTerm msig = choice
   [ string "#" *> (lit <$> (FreshVar <$> (decimal <* string ":") <*> parseSort))
   , do ident <- takeWhile1 (`BC.notElem` (":(,)\n " :: B.ByteString))
        choice [ do _ <- string "("
                    case parseLSortSym ident of
                      Just s  -> parseConst s
                      Nothing -> parseFApp ident
               , string ":" *> parseMaudeVariable ident
               , parseFAppConst ident
               ]
   ]
  where
    consSym = ("cons",(2,(Public,Nothing)))
    nilSym  = ("nil",(0,(Public,Nothing)))

    parseFunSym ident args
      -- TODO: Adjust this to take into account sort restrictions
      | op `elem` allowedfunSyms = op
      | otherwise                =
          error $ "Maude.Parser.parseTerm: unknown function "
                  ++ "symbol `"++ show op ++"', not in "
                  ++show allowedfunSyms
      where prefixLen      = BC.length funSymPrefix
            special        = ident `elem` ["list", "cons", "nil" ]
            priv           = if (not special) && BC.isPrefixOf funSymPrefixPriv ident 
                               then Private else Public
            allowedfunSyms = [consSym, nilSym]++(S.toList $ noEqFunSyms msig)
            op_ident       = if special then ident else BC.drop prefixLen ident
            op             =
              ( op_ident 
              , ( length args
              , ( priv
              , ( case lookup op_ident (S.toList $ stFunSyms msig) of
                    Just (_, (_, a)) -> a
                    Nothing          -> Nothing ))))

    parseConst s = lit <$> (flip MaudeConst s <$> decimal) <* string ")"

    parseFApp ident =
        appIdent <$> sepBy1 (parseTerm msig) (string ", ") <* string ")"
      where
        appIdent args  | ident == ppMaudeACSym Mult       = fAppAC Mult  args
                       | ident == ppMaudeACSym Union      = fAppAC Union args
                       | ident == ppMaudeCSym  EMap       = fAppC  EMap  args
        appIdent [arg] | ident == "list"                  = fAppList (flattenCons arg)
        appIdent args                                     = fAppNoEq op args
          where op = parseFunSym ident args

        flattenCons (viewTerm -> FApp (NoEq s) [x,xs]) | s == consSym = x:flattenCons xs
        flattenCons (viewTerm -> FApp (NoEq s)  [])    | s == nilSym  = []
        flattenCons t                                                 = [t]

    parseFAppConst ident = return $ fAppNoEq (parseFunSym ident []) []

    parseMaudeVariable ident =
        case BC.uncons ident of
            Just ('x', num) -> lit <$> (MaudeVar (read (BC.unpack num)) <$> parseSort)
            _               -> fail "invalid variable"
