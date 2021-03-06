{-# LANGUAGE TransformListComp #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Backends.Html.Decl
-- Copyright   :  (c) Simon Marlow   2003-2006,
--                    David Waern    2006-2009,
--                    Mark Lentczner 2010
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
-----------------------------------------------------------------------------
module Haddock.Backends.Xhtml.Decl (
  ppDecl,

  ppTyName, ppTyFamHeader, ppTypeApp,
  tyvarNames
) where


import Haddock.Backends.Xhtml.DocMarkup
import Haddock.Backends.Xhtml.Layout
import Haddock.Backends.Xhtml.Names
import Haddock.Backends.Xhtml.Types
import Haddock.Backends.Xhtml.Utils
import Haddock.GhcUtils
import Haddock.Types
import Haddock.Doc (combineDocumentation)

import           Data.List             ( intersperse, sort )
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Monoid           ( mempty )
import           Text.XHtml hiding     ( name, title, p, quote )

import GHC
import GHC.Exts
import Name
import BooleanFormula

ppDecl :: Bool -> LinksInfo -> LHsDecl DocName
       -> DocForDecl DocName -> [DocInstance DocName] -> [(DocName, Fixity)]
       -> [(DocName, DocForDecl DocName)] -> Splice -> Unicode -> Qualification -> Html
ppDecl summ links (L loc decl) (mbDoc, fnArgsDoc) instances fixities subdocs splice unicode qual = case decl of
  TyClD (FamDecl d)         -> ppTyFam summ False links instances fixities loc mbDoc d splice unicode qual
  TyClD d@(DataDecl {})     -> ppDataDecl summ links instances fixities subdocs loc mbDoc d splice unicode qual
  TyClD d@(SynDecl {})      -> ppTySyn summ links fixities loc (mbDoc, fnArgsDoc) d splice unicode qual
  TyClD d@(ClassDecl {})    -> ppClassDecl summ links instances fixities loc mbDoc subdocs d splice unicode qual
  SigD (TypeSig lnames lty) -> ppLFunSig summ links loc (mbDoc, fnArgsDoc) lnames lty fixities splice unicode qual
  SigD (PatSynSig lname args ty prov req) ->
      ppLPatSig summ links loc (mbDoc, fnArgsDoc) lname args ty prov req fixities splice unicode qual
  ForD d                         -> ppFor summ links loc (mbDoc, fnArgsDoc) d fixities splice unicode qual
  InstD _                        -> noHtml
  _                              -> error "declaration not supported by ppDecl"


ppLFunSig :: Bool -> LinksInfo -> SrcSpan -> DocForDecl DocName ->
             [Located DocName] -> LHsType DocName -> [(DocName, Fixity)] ->
             Splice -> Unicode -> Qualification -> Html
ppLFunSig summary links loc doc lnames lty fixities splice unicode qual =
  ppFunSig summary links loc doc (map unLoc lnames) (unLoc lty) fixities
           splice unicode qual

ppFunSig :: Bool -> LinksInfo -> SrcSpan -> DocForDecl DocName ->
            [DocName] -> HsType DocName -> [(DocName, Fixity)] ->
            Splice -> Unicode -> Qualification -> Html
ppFunSig summary links loc doc docnames typ fixities splice unicode qual =
  ppSigLike summary links loc mempty doc docnames fixities (typ, pp_typ)
            splice unicode qual
  where
    pp_typ = ppType unicode qual typ

ppLPatSig :: Bool -> LinksInfo -> SrcSpan -> DocForDecl DocName ->
             Located DocName ->
             HsPatSynDetails (LHsType DocName) -> LHsType DocName ->
             LHsContext DocName -> LHsContext DocName -> [(DocName, Fixity)] ->
             Splice -> Unicode -> Qualification -> Html
ppLPatSig summary links loc doc lname args typ prov req fixities splice unicode qual =
    ppPatSig summary links loc doc (unLoc lname) (fmap unLoc args) (unLoc typ)
             (unLoc prov) (unLoc req) fixities splice unicode qual

ppPatSig :: Bool -> LinksInfo -> SrcSpan -> DocForDecl DocName ->
            DocName ->
            HsPatSynDetails (HsType DocName) -> HsType DocName ->
            HsContext DocName -> HsContext DocName -> [(DocName, Fixity)] ->
            Splice -> Unicode -> Qualification -> Html
ppPatSig summary links loc (doc, _argDocs) docname args typ prov req fixities
         splice unicode qual
  | summary = pref1
  | otherwise = topDeclElem links loc splice [docname] (pref1 <+> ppFixities fixities qual)
                +++ docSection qual doc
  where
    pref1 = hsep [ toHtml "pattern"
                 , pp_cxt prov
                 , pp_head
                 , dcolon unicode
                 , pp_cxt req
                 , ppType unicode qual typ
                 ]
    pp_head = case args of
        PrefixPatSyn typs -> hsep $ ppBinder summary occname : map pp_type typs
        InfixPatSyn left right -> hsep [pp_type left, ppBinderInfix summary occname, pp_type right]

    pp_cxt cxt = ppContext cxt unicode qual
    pp_type = ppParendType unicode qual

    occname = nameOccName . getName $ docname

ppSigLike :: Bool -> LinksInfo -> SrcSpan -> Html -> DocForDecl DocName ->
             [DocName] -> [(DocName, Fixity)] -> (HsType DocName, Html) ->
             Splice -> Unicode -> Qualification -> Html
ppSigLike summary links loc leader doc docnames fixities (typ, pp_typ)
          splice unicode qual =
  ppTypeOrFunSig summary links loc docnames typ doc
    ( addFixities $ leader <+> ppTypeSig summary occnames pp_typ unicode
    , addFixities . concatHtml . punctuate comma $ map (ppBinder False) occnames
    , dcolon unicode
    )
    splice unicode qual
  where
    occnames = map (nameOccName . getName) docnames
    addFixities html
      | summary   = html
      | otherwise = html <+> ppFixities fixities qual


ppTypeOrFunSig :: Bool -> LinksInfo -> SrcSpan -> [DocName] -> HsType DocName
               -> DocForDecl DocName -> (Html, Html, Html)
               -> Splice -> Unicode -> Qualification -> Html
ppTypeOrFunSig summary links loc docnames typ (doc, argDocs) (pref1, pref2, sep) splice unicode qual
  | summary = pref1
  | Map.null argDocs = topDeclElem links loc splice docnames pref1 +++ docSection qual doc
  | otherwise = topDeclElem links loc splice docnames pref2 +++
      subArguments qual (do_args 0 sep typ) +++ docSection qual doc
  where
    argDoc n = Map.lookup n argDocs

    do_largs n leader (L _ t) = do_args n leader t
    do_args :: Int -> Html -> HsType DocName -> [SubDecl]
    do_args n leader (HsForAllTy Explicit tvs lctxt ltype)
      = (leader <+>
          hsep (forallSymbol unicode : ppTyVars tvs ++ [dot]) <+>
          ppLContextNoArrow lctxt unicode qual,
          Nothing, [])
        : do_largs n (darrow unicode) ltype
    do_args n leader (HsForAllTy Implicit _ lctxt ltype)
      | not (null (unLoc lctxt))
      = (leader <+> ppLContextNoArrow lctxt unicode qual,
          Nothing, [])
        : do_largs n (darrow unicode) ltype
      -- if we're not showing any 'forall' or class constraints or
      -- anything, skip having an empty line for the context.
      | otherwise
      = do_largs n leader ltype
    do_args n leader (HsFunTy lt r)
      = (leader <+> ppLFunLhType unicode qual lt, argDoc n, [])
        : do_largs (n+1) (arrow unicode) r
    do_args n leader t
      = [(leader <+> ppType unicode qual t, argDoc n, [])]

ppFixities :: [(DocName, Fixity)] -> Qualification -> Html
ppFixities [] _ = noHtml
ppFixities fs qual = foldr1 (+++) (map ppFix uniq_fs) +++ rightEdge
  where
    ppFix (ns, p, d) = thespan ! [theclass "fixity"] <<
                         (toHtml d <+> toHtml (show p) <+> ppNames ns)

    ppDir InfixR = "infixr"
    ppDir InfixL = "infixl"
    ppDir InfixN = "infix"

    ppNames = case fs of
      _:[] -> const noHtml -- Don't display names for fixities on single names
      _    -> concatHtml . intersperse (stringToHtml ", ") . map (ppDocName qual Infix False)

    uniq_fs = [ (n, the p, the d') | (n, Fixity p d) <- fs
                                   , let d' = ppDir d
                                   , then group by Down (p,d') using groupWith ]

    rightEdge = thespan ! [theclass "rightedge"] << noHtml


ppTyVars :: LHsTyVarBndrs DocName -> [Html]
ppTyVars tvs = map ppTyName (tyvarNames tvs)


tyvarNames :: LHsTyVarBndrs DocName -> [Name]
tyvarNames = map getName . hsLTyVarNames


ppFor :: Bool -> LinksInfo -> SrcSpan -> DocForDecl DocName
      -> ForeignDecl DocName -> [(DocName, Fixity)]
      -> Splice -> Unicode -> Qualification -> Html
ppFor summary links loc doc (ForeignImport (L _ name) (L _ typ) _ _) fixities
      splice unicode qual
  = ppFunSig summary links loc doc [name] typ fixities splice unicode qual
ppFor _ _ _ _ _ _ _ _ _ = error "ppFor"


-- we skip type patterns for now
ppTySyn :: Bool -> LinksInfo -> [(DocName, Fixity)] -> SrcSpan
        -> DocForDecl DocName -> TyClDecl DocName
        -> Splice -> Unicode -> Qualification -> Html
ppTySyn summary links fixities loc doc (SynDecl { tcdLName = L _ name, tcdTyVars = ltyvars
                                                , tcdRhs = ltype })
        splice unicode qual
  = ppTypeOrFunSig summary links loc [name] (unLoc ltype) doc
                   (full <+> fixs, hdr <+> fixs, spaceHtml +++ equals)
                   splice unicode qual
  where
    hdr  = hsep ([keyword "type", ppBinder summary occ] ++ ppTyVars ltyvars)
    full = hdr <+> equals <+> ppLType unicode qual ltype
    occ  = nameOccName . getName $ name
    fixs
      | summary   = noHtml
      | otherwise = ppFixities fixities qual
ppTySyn _ _ _ _ _ _ _ _ _ = error "declaration not supported by ppTySyn"


ppTypeSig :: Bool -> [OccName] -> Html  -> Bool -> Html
ppTypeSig summary nms pp_ty unicode =
  concatHtml htmlNames <+> dcolon unicode <+> pp_ty
  where
    htmlNames = intersperse (stringToHtml ", ") $ map (ppBinder summary) nms


ppTyName :: Name -> Html
ppTyName = ppName Prefix


--------------------------------------------------------------------------------
-- * Type families
--------------------------------------------------------------------------------


ppTyFamHeader :: Bool -> Bool -> FamilyDecl DocName
              -> Unicode -> Qualification -> Html
ppTyFamHeader summary associated d@(FamilyDecl { fdInfo = info
                                               , fdKindSig = mkind })
              unicode qual =
  (case info of
     OpenTypeFamily
       | associated -> keyword "type"
       | otherwise  -> keyword "type family"
     DataFamily
       | associated -> keyword "data"
       | otherwise  -> keyword "data family"
     ClosedTypeFamily _
                    -> keyword "type family"
  ) <+>

  ppFamDeclBinderWithVars summary d <+>

  (case mkind of
    Just kind -> dcolon unicode  <+> ppLKind unicode qual kind
    Nothing   -> noHtml
  )

ppTyFam :: Bool -> Bool -> LinksInfo -> [DocInstance DocName] ->
           [(DocName, Fixity)] -> SrcSpan -> Documentation DocName ->
           FamilyDecl DocName -> Splice -> Unicode -> Qualification -> Html
ppTyFam summary associated links instances fixities loc doc decl splice unicode qual

  | summary   = ppTyFamHeader True associated decl unicode qual
  | otherwise = header_ +++ docSection qual doc +++ instancesBit

  where
    docname = unLoc $ fdLName decl

    header_ = topDeclElem links loc splice [docname] $
       ppTyFamHeader summary associated decl unicode qual <+> ppFixities fixities qual

    instancesBit
      | FamilyDecl { fdInfo = ClosedTypeFamily eqns } <- decl
      , not summary
      = subEquations qual $ map (ppTyFamEqn . unLoc) eqns

      | otherwise
      = ppInstances instances docname unicode qual

    -- Individual equation of a closed type family
    ppTyFamEqn TyFamEqn { tfe_tycon = n, tfe_rhs = rhs
                        , tfe_pats = HsWB { hswb_cts = ts }}
      = ( ppAppNameTypes (unLoc n) [] (map unLoc ts) unicode qual
          <+> equals <+> ppType unicode qual (unLoc rhs)
        , Nothing, [] )

--------------------------------------------------------------------------------
-- * Associated Types
--------------------------------------------------------------------------------


ppAssocType :: Bool -> LinksInfo -> DocForDecl DocName -> LFamilyDecl DocName
            -> [(DocName, Fixity)] -> Splice -> Unicode -> Qualification -> Html
ppAssocType summ links doc (L loc decl) fixities splice unicode qual =
   ppTyFam summ True links [] fixities loc (fst doc) decl splice unicode qual


--------------------------------------------------------------------------------
-- * TyClDecl helpers
--------------------------------------------------------------------------------

-- | Print a type family and its variables
ppFamDeclBinderWithVars :: Bool -> FamilyDecl DocName -> Html
ppFamDeclBinderWithVars summ (FamilyDecl { fdLName = lname, fdTyVars = tvs }) =
  ppAppDocNameNames summ (unLoc lname) (tyvarNames tvs)

-- | Print a newtype / data binder and its variables
ppDataBinderWithVars :: Bool -> TyClDecl DocName -> Html
ppDataBinderWithVars summ decl =
  ppAppDocNameNames summ (tcdName decl) (tyvarNames $ tcdTyVars decl)

--------------------------------------------------------------------------------
-- * Type applications
--------------------------------------------------------------------------------


-- | Print an application of a DocName and two lists of HsTypes (kinds, types)
ppAppNameTypes :: DocName -> [HsType DocName] -> [HsType DocName]
               -> Unicode -> Qualification -> Html
ppAppNameTypes n ks ts unicode qual =
    ppTypeApp n ks ts (\p -> ppDocName qual p True) (ppParendType unicode qual)


-- | Print an application of a DocName and a list of Names
ppAppDocNameNames :: Bool -> DocName -> [Name] -> Html
ppAppDocNameNames summ n ns =
    ppTypeApp n [] ns ppDN ppTyName
  where
    ppDN notation = ppBinderFixity notation summ . nameOccName . getName
    ppBinderFixity Infix = ppBinderInfix
    ppBinderFixity _ = ppBinder

-- | General printing of type applications
ppTypeApp :: DocName -> [a] -> [a] -> (Notation -> DocName -> Html) -> (a -> Html) -> Html
ppTypeApp n [] (t1:t2:rest) ppDN ppT
  | operator, not . null $ rest = parens opApp <+> hsep (map ppT rest)
  | operator                    = opApp
  where
    operator = isNameSym . getName $ n
    opApp = ppT t1 <+> ppDN Infix n <+> ppT t2

ppTypeApp n ks ts ppDN ppT = ppDN Prefix n <+> hsep (map ppT $ ks ++ ts)


-------------------------------------------------------------------------------
-- * Contexts
-------------------------------------------------------------------------------


ppLContext, ppLContextNoArrow :: Located (HsContext DocName) -> Unicode
                              -> Qualification -> Html
ppLContext        = ppContext        . unLoc
ppLContextNoArrow = ppContextNoArrow . unLoc


ppContextNoArrow :: HsContext DocName -> Unicode -> Qualification -> Html
ppContextNoArrow []  _       _     = noHtml
ppContextNoArrow cxt unicode qual = ppHsContext (map unLoc cxt) unicode qual


ppContextNoLocs :: [HsType DocName] -> Unicode -> Qualification -> Html
ppContextNoLocs []  _       _     = noHtml
ppContextNoLocs cxt unicode qual = ppHsContext cxt unicode qual
    <+> darrow unicode


ppContext :: HsContext DocName -> Unicode -> Qualification -> Html
ppContext cxt unicode qual = ppContextNoLocs (map unLoc cxt) unicode qual


ppHsContext :: [HsType DocName] -> Unicode -> Qualification-> Html
ppHsContext []  _       _     = noHtml
ppHsContext [p] unicode qual = ppCtxType unicode qual p
ppHsContext cxt unicode qual = parenList (map (ppType unicode qual) cxt)


-------------------------------------------------------------------------------
-- * Class declarations
-------------------------------------------------------------------------------


ppClassHdr :: Bool -> Located [LHsType DocName] -> DocName
           -> LHsTyVarBndrs DocName -> [Located ([DocName], [DocName])]
           -> Unicode -> Qualification -> Html
ppClassHdr summ lctxt n tvs fds unicode qual =
  keyword "class"
  <+> (if not . null . unLoc $ lctxt then ppLContext lctxt unicode qual else noHtml)
  <+> ppAppDocNameNames summ n (tyvarNames tvs)
  <+> ppFds fds unicode qual


ppFds :: [Located ([DocName], [DocName])] -> Unicode -> Qualification -> Html
ppFds fds unicode qual =
  if null fds then noHtml else
        char '|' <+> hsep (punctuate comma (map (fundep . unLoc) fds))
  where
        fundep (vars1,vars2) = ppVars vars1 <+> arrow unicode <+> ppVars vars2
        ppVars = hsep . map (ppDocName qual Prefix True)

ppShortClassDecl :: Bool -> LinksInfo -> TyClDecl DocName -> SrcSpan
                 -> [(DocName, DocForDecl DocName)]
                 -> Splice -> Unicode -> Qualification -> Html
ppShortClassDecl summary links (ClassDecl { tcdCtxt = lctxt, tcdLName = lname, tcdTyVars = tvs
                                          , tcdFDs = fds, tcdSigs = sigs, tcdATs = ats }) loc
    subdocs splice unicode qual =
  if not (any isVanillaLSig sigs) && null ats
    then (if summary then id else topDeclElem links loc splice [nm]) hdr
    else (if summary then id else topDeclElem links loc splice [nm]) (hdr <+> keyword "where")
      +++ shortSubDecls False
          (
            [ ppAssocType summary links doc at [] splice unicode qual | at <- ats
              , let doc = lookupAnySubdoc (unL $ fdLName $ unL at) subdocs ]  ++

                -- ToDo: add associated type defaults

            [ ppFunSig summary links loc doc names typ [] splice unicode qual
              | L _ (TypeSig lnames (L _ typ)) <- sigs
              , let doc = lookupAnySubdoc (head names) subdocs
                    names = map unLoc lnames ]
              -- FIXME: is taking just the first name ok? Is it possible that
              -- there are different subdocs for different names in a single
              -- type signature?
          )
  where
    hdr = ppClassHdr summary lctxt (unLoc lname) tvs fds unicode qual
    nm  = unLoc lname
ppShortClassDecl _ _ _ _ _ _ _ _ = error "declaration type not supported by ppShortClassDecl"



ppClassDecl :: Bool -> LinksInfo -> [DocInstance DocName] -> [(DocName, Fixity)]
            -> SrcSpan -> Documentation DocName
            -> [(DocName, DocForDecl DocName)] -> TyClDecl DocName
            -> Splice -> Unicode -> Qualification -> Html
ppClassDecl summary links instances fixities loc d subdocs
        decl@(ClassDecl { tcdCtxt = lctxt, tcdLName = lname, tcdTyVars = ltyvars
                        , tcdFDs = lfds, tcdSigs = lsigs, tcdATs = ats })
            splice unicode qual
  | summary = ppShortClassDecl summary links decl loc subdocs splice unicode qual
  | otherwise = classheader +++ docSection qual d
                  +++ minimalBit +++ atBit +++ methodBit +++ instancesBit
  where
    classheader
      | any isVanillaLSig lsigs = topDeclElem links loc splice [nm] (hdr unicode qual <+> keyword "where" <+> fixs)
      | otherwise = topDeclElem links loc splice [nm] (hdr unicode qual <+> fixs)

    -- Only the fixity relevant to the class header
    fixs = ppFixities [ f | f@(n,_) <- fixities, n == unLoc lname ] qual

    nm   = tcdName decl

    hdr = ppClassHdr summary lctxt (unLoc lname) ltyvars lfds

    -- ToDo: add assocatied typ defaults
    atBit = subAssociatedTypes [ ppAssocType summary links doc at subfixs splice unicode qual
                      | at <- ats
                      , let n = unL . fdLName $ unL at
                            doc = lookupAnySubdoc (unL $ fdLName $ unL at) subdocs
                            subfixs = [ f | f@(n',_) <- fixities, n == n' ] ]

    methodBit = subMethods [ ppFunSig summary links loc doc names typ subfixs splice unicode qual
                           | L _ (TypeSig lnames (L _ typ)) <- lsigs
                           , let doc = lookupAnySubdoc (head names) subdocs
                                 subfixs = [ f | n <- names
                                               , f@(n',_) <- fixities
                                               , n == n' ]
                                 names = map unLoc lnames ]
                           -- FIXME: is taking just the first name ok? Is it possible that
                           -- there are different subdocs for different names in a single
                           -- type signature?

    minimalBit = case [ s | L _ (MinimalSig s) <- lsigs ] of
      -- Miminal complete definition = every shown method
      And xs : _ | sort [getName n | Var (L _ n) <- xs] ==
                   sort [getName n | L _ (TypeSig ns _) <- lsigs, L _ n <- ns]
        -> noHtml

      -- Minimal complete definition = the only shown method
      Var (L _ n) : _ | [getName n] ==
                        [getName n' | L _ (TypeSig ns _) <- lsigs, L _ n' <- ns]
        -> noHtml

      -- Minimal complete definition = nothing
      And [] : _ -> subMinimal $ toHtml "Nothing"

      m : _  -> subMinimal $ ppMinimal False m
      _ -> noHtml

    ppMinimal _ (Var (L _ n)) = ppDocName qual Prefix True n
    ppMinimal _ (And fs) = foldr1 (\a b -> a+++", "+++b) $ map (ppMinimal True) fs
    ppMinimal p (Or fs) = wrap $ foldr1 (\a b -> a+++" | "+++b) $ map (ppMinimal False) fs
      where wrap | p = parens | otherwise = id

    instancesBit = ppInstances instances nm unicode qual

ppClassDecl _ _ _ _ _ _ _ _ _ _ _ = error "declaration type not supported by ppShortClassDecl"


ppInstances :: [DocInstance DocName] -> DocName -> Unicode -> Qualification -> Html
ppInstances instances baseName unicode qual
  = subInstances qual instName (map instDecl instances)
  where
    instName = getOccString $ getName baseName
    instDecl :: DocInstance DocName -> SubDecl
    instDecl (inst, maybeDoc) = (instHead inst, maybeDoc, [])
    instHead (n, ks, ts, ClassInst cs) = ppContextNoLocs cs unicode qual
        <+> ppAppNameTypes n ks ts unicode qual
    instHead (n, ks, ts, TypeInst rhs) = keyword "type"
        <+> ppAppNameTypes n ks ts unicode qual
        <+> maybe noHtml (\t -> equals <+> ppType unicode qual t) rhs
    instHead (n, ks, ts, DataInst dd) = keyword "data"
        <+> ppAppNameTypes n ks ts unicode qual
        <+> ppShortDataDecl False True dd unicode qual

lookupAnySubdoc :: Eq id1 => id1 -> [(id1, DocForDecl id2)] -> DocForDecl id2
lookupAnySubdoc n = fromMaybe noDocForDecl . lookup n


-------------------------------------------------------------------------------
-- * Data & newtype declarations
-------------------------------------------------------------------------------


-- TODO: print contexts
ppShortDataDecl :: Bool -> Bool -> TyClDecl DocName -> Unicode -> Qualification -> Html
ppShortDataDecl summary dataInst dataDecl unicode qual

  | [] <- cons = dataHeader

  | [lcon] <- cons, ResTyH98 <- resTy,
    (cHead,cBody,cFoot) <- ppShortConstrParts summary dataInst (unLoc lcon) unicode qual
       = (dataHeader <+> equals <+> cHead) +++ cBody +++ cFoot

  | ResTyH98 <- resTy = dataHeader
      +++ shortSubDecls dataInst (zipWith doConstr ('=':repeat '|') cons)

  | otherwise = (dataHeader <+> keyword "where")
      +++ shortSubDecls dataInst (map doGADTConstr cons)

  where
    dataHeader
      | dataInst  = noHtml
      | otherwise = ppDataHeader summary dataDecl unicode qual
    doConstr c con = toHtml [c] <+> ppShortConstr summary (unLoc con) unicode qual
    doGADTConstr con = ppShortConstr summary (unLoc con) unicode qual

    cons      = dd_cons (tcdDataDefn dataDecl)
    resTy     = (con_res . unLoc . head) cons


ppDataDecl :: Bool -> LinksInfo -> [DocInstance DocName] -> [(DocName, Fixity)] ->
              [(DocName, DocForDecl DocName)] ->
              SrcSpan -> Documentation DocName -> TyClDecl DocName ->
              Splice -> Unicode -> Qualification -> Html
ppDataDecl summary links instances fixities subdocs loc doc dataDecl
           splice unicode qual

  | summary   = ppShortDataDecl summary False dataDecl unicode qual
  | otherwise = header_ +++ docSection qual doc +++ constrBit +++ instancesBit

  where
    docname   = tcdName dataDecl
    cons      = dd_cons (tcdDataDefn dataDecl)
    resTy     = (con_res . unLoc . head) cons

    header_ = topDeclElem links loc splice [docname] $
             ppDataHeader summary dataDecl unicode qual <+> whereBit <+> fix

    fix = ppFixities (filter (\(n,_) -> n == docname) fixities) qual

    whereBit
      | null cons = noHtml
      | otherwise = case resTy of
        ResTyGADT _ -> keyword "where"
        _ -> noHtml

    constrBit = subConstructors qual
      [ ppSideBySideConstr subdocs subfixs unicode qual c
      | c <- cons
      , let subfixs = filter (\(n,_) -> n == unLoc (con_name (unLoc c))) fixities
      ]

    instancesBit = ppInstances instances docname unicode qual



ppShortConstr :: Bool -> ConDecl DocName -> Unicode -> Qualification -> Html
ppShortConstr summary con unicode qual = cHead <+> cBody <+> cFoot
  where
    (cHead,cBody,cFoot) = ppShortConstrParts summary False con unicode qual


-- returns three pieces: header, body, footer so that header & footer can be
-- incorporated into the declaration
ppShortConstrParts :: Bool -> Bool -> ConDecl DocName -> Unicode -> Qualification -> (Html, Html, Html)
ppShortConstrParts summary dataInst con unicode qual = case con_res con of
  ResTyH98 -> case con_details con of
    PrefixCon args ->
      (header_ unicode qual +++ hsep (ppBinder summary occ
            : map (ppLParendType unicode qual) args), noHtml, noHtml)
    RecCon fields ->
      (header_ unicode qual +++ ppBinder summary occ <+> char '{',
       doRecordFields fields,
       char '}')
    InfixCon arg1 arg2 ->
      (header_ unicode qual +++ hsep [ppLParendType unicode qual arg1,
            ppBinderInfix summary occ, ppLParendType unicode qual arg2],
       noHtml, noHtml)

  ResTyGADT resTy -> case con_details con of
    -- prefix & infix could use hsConDeclArgTys if it seemed to
    -- simplify the code.
    PrefixCon args -> (doGADTCon args resTy, noHtml, noHtml)
    -- display GADT records with the new syntax,
    -- Constr :: (Context) => { field :: a, field2 :: b } -> Ty (a, b)
    -- (except each field gets its own line in docs, to match
    -- non-GADT records)
    RecCon fields -> (ppBinder summary occ <+> dcolon unicode <+>
                            ppForAll forall_ ltvs lcontext unicode qual <+> char '{',
                            doRecordFields fields,
                            char '}' <+> arrow unicode <+> ppLType unicode qual resTy)
    InfixCon arg1 arg2 -> (doGADTCon [arg1, arg2] resTy, noHtml, noHtml)

  where
    doRecordFields fields = shortSubDecls dataInst (map (ppShortField summary unicode qual) fields)
    doGADTCon args resTy = ppBinder summary occ <+> dcolon unicode <+> hsep [
                             ppForAll forall_ ltvs lcontext unicode qual,
                             ppLType unicode qual (foldr mkFunTy resTy args) ]

    header_  = ppConstrHdr forall_ tyVars context
    occ      = nameOccName . getName . unLoc . con_name $ con
    ltvs     = con_qvars con
    tyVars   = tyvarNames ltvs
    lcontext = con_cxt con
    context  = unLoc (con_cxt con)
    forall_  = con_explicit con
    mkFunTy a b = noLoc (HsFunTy a b)


-- ppConstrHdr is for (non-GADT) existentials constructors' syntax
ppConstrHdr :: HsExplicitFlag -> [Name] -> HsContext DocName -> Unicode
            -> Qualification -> Html
ppConstrHdr forall_ tvs ctxt unicode qual
 = (if null tvs then noHtml else ppForall)
   +++
   (if null ctxt then noHtml else ppContextNoArrow ctxt unicode qual
        <+> darrow unicode +++ toHtml " ")
  where
    ppForall = case forall_ of
      Explicit -> forallSymbol unicode <+> hsep (map (ppName Prefix) tvs) <+> toHtml ". "
      Implicit -> noHtml


ppSideBySideConstr :: [(DocName, DocForDecl DocName)] -> [(DocName, Fixity)]
                   -> Unicode -> Qualification -> LConDecl DocName -> SubDecl
ppSideBySideConstr subdocs fixities unicode qual (L _ con) = (decl, mbDoc, fieldPart)
 where
    decl = case con_res con of
      ResTyH98 -> case con_details con of
        PrefixCon args ->
          hsep ((header_ +++ ppBinder False occ)
            : map (ppLParendType unicode qual) args)
          <+> fixity

        RecCon _ -> header_ +++ ppBinder False occ <+> fixity

        InfixCon arg1 arg2 ->
          hsep [header_ +++ ppLParendType unicode qual arg1,
            ppBinderInfix False occ,
            ppLParendType unicode qual arg2]
          <+> fixity

      ResTyGADT resTy -> case con_details con of
        -- prefix & infix could also use hsConDeclArgTys if it seemed to
        -- simplify the code.
        PrefixCon args -> doGADTCon args resTy
        cd@(RecCon _) -> doGADTCon (hsConDeclArgTys cd) resTy
        InfixCon arg1 arg2 -> doGADTCon [arg1, arg2] resTy

    fieldPart = case con_details con of
        RecCon fields -> [doRecordFields fields]
        _ -> []

    doRecordFields fields = subFields qual
      (map (ppSideBySideField subdocs unicode qual) fields)
    doGADTCon :: [LHsType DocName] -> Located (HsType DocName) -> Html
    doGADTCon args resTy = ppBinder False occ <+> dcolon unicode
        <+> hsep [ppForAll forall_ ltvs (con_cxt con) unicode qual,
                  ppLType unicode qual (foldr mkFunTy resTy args) ]
        <+> fixity

    fixity  = ppFixities fixities qual
    header_ = ppConstrHdr forall_ tyVars context unicode qual
    occ     = nameOccName . getName . unLoc . con_name $ con
    ltvs    = con_qvars con
    tyVars  = tyvarNames (con_qvars con)
    context = unLoc (con_cxt con)
    forall_ = con_explicit con
    -- don't use "con_doc con", in case it's reconstructed from a .hi file,
    -- or also because we want Haddock to do the doc-parsing, not GHC.
    mbDoc = lookup (unLoc $ con_name con) subdocs >>= combineDocumentation . fst
    mkFunTy a b = noLoc (HsFunTy a b)


ppSideBySideField :: [(DocName, DocForDecl DocName)] -> Unicode -> Qualification
                  -> ConDeclField DocName -> SubDecl
ppSideBySideField subdocs unicode qual (ConDeclField (L _ name) ltype _) =
  (ppBinder False (nameOccName . getName $ name) <+> dcolon unicode <+> ppLType unicode qual ltype,
    mbDoc,
    [])
  where
    -- don't use cd_fld_doc for same reason we don't use con_doc above
    mbDoc = lookup name subdocs >>= combineDocumentation . fst


ppShortField :: Bool -> Unicode -> Qualification -> ConDeclField DocName -> Html
ppShortField summary unicode qual (ConDeclField (L _ name) ltype _)
  = ppBinder summary (nameOccName . getName $ name)
    <+> dcolon unicode <+> ppLType unicode qual ltype


-- | Print the LHS of a data\/newtype declaration.
-- Currently doesn't handle 'data instance' decls or kind signatures
ppDataHeader :: Bool -> TyClDecl DocName -> Unicode -> Qualification -> Html
ppDataHeader summary decl@(DataDecl { tcdDataDefn =
                                         HsDataDefn { dd_ND = nd
                                                    , dd_ctxt = ctxt
                                                    , dd_kindSig = ks } })
             unicode qual
  = -- newtype or data
    (case nd of { NewType -> keyword "newtype"; DataType -> keyword "data" })
    <+>
    -- context
    ppLContext ctxt unicode qual <+>
    -- T a b c ..., or a :+: b
    ppDataBinderWithVars summary decl
    <+> case ks of
      Nothing -> mempty
      Just (L _ x) -> dcolon unicode <+> ppKind unicode qual x

ppDataHeader _ _ _ _ = error "ppDataHeader: illegal argument"

--------------------------------------------------------------------------------
-- * Types and contexts
--------------------------------------------------------------------------------


ppBang :: HsBang -> Html
ppBang HsNoBang = noHtml
ppBang _        = toHtml "!" -- Unpacked args is an implementation detail,
                             -- so we just show the strictness annotation


tupleParens :: HsTupleSort -> [Html] -> Html
tupleParens HsUnboxedTuple = ubxParenList
tupleParens _              = parenList


--------------------------------------------------------------------------------
-- * Rendering of HsType
--------------------------------------------------------------------------------


pREC_TOP, pREC_CTX, pREC_FUN, pREC_OP, pREC_CON :: Int

pREC_TOP = 0 :: Int   -- type in ParseIface.y in GHC
pREC_CTX = 1 :: Int   -- Used for single contexts, eg. ctx => type
                      -- (as opposed to (ctx1, ctx2) => type)
pREC_FUN = 2 :: Int   -- btype in ParseIface.y in GHC
                      -- Used for LH arg of (->)
pREC_OP  = 3 :: Int   -- Used for arg of any infix operator
                      -- (we don't keep their fixities around)
pREC_CON = 4 :: Int   -- Used for arg of type applicn:
                      -- always parenthesise unless atomic

maybeParen :: Int           -- Precedence of context
           -> Int           -- Precedence of top-level operator
           -> Html -> Html  -- Wrap in parens if (ctxt >= op)
maybeParen ctxt_prec op_prec p | ctxt_prec >= op_prec = parens p
                               | otherwise            = p


ppLType, ppLParendType, ppLFunLhType :: Unicode -> Qualification
                                     -> Located (HsType DocName) -> Html
ppLType       unicode qual y = ppType unicode qual (unLoc y)
ppLParendType unicode qual y = ppParendType unicode qual (unLoc y)
ppLFunLhType  unicode qual y = ppFunLhType unicode qual (unLoc y)


ppType, ppCtxType, ppParendType, ppFunLhType :: Unicode -> Qualification
                                             -> HsType DocName -> Html
ppType       unicode qual ty = ppr_mono_ty pREC_TOP ty unicode qual
ppCtxType    unicode qual ty = ppr_mono_ty pREC_CTX ty unicode qual
ppParendType unicode qual ty = ppr_mono_ty pREC_CON ty unicode qual
ppFunLhType  unicode qual ty = ppr_mono_ty pREC_FUN ty unicode qual

ppLKind :: Unicode -> Qualification -> LHsKind DocName -> Html
ppLKind unicode qual y = ppKind unicode qual (unLoc y)

ppKind :: Unicode -> Qualification -> HsKind DocName -> Html
ppKind unicode qual ki = ppr_mono_ty pREC_TOP ki unicode qual

-- Drop top-level for-all type variables in user style
-- since they are implicit in Haskell

ppForAll :: HsExplicitFlag -> LHsTyVarBndrs DocName
         -> Located (HsContext DocName) -> Unicode -> Qualification -> Html
ppForAll expl tvs cxt unicode qual
  | show_forall = forall_part <+> ppLContext cxt unicode qual
  | otherwise   = ppLContext cxt unicode qual
  where
    show_forall = not (null (hsQTvBndrs tvs)) && is_explicit
    is_explicit = case expl of {Explicit -> True; Implicit -> False}
    forall_part = hsep (forallSymbol unicode : ppTyVars tvs) +++ dot


ppr_mono_lty :: Int -> LHsType DocName -> Unicode -> Qualification -> Html
ppr_mono_lty ctxt_prec ty = ppr_mono_ty ctxt_prec (unLoc ty)


ppr_mono_ty :: Int -> HsType DocName -> Unicode -> Qualification -> Html
ppr_mono_ty ctxt_prec (HsForAllTy expl tvs ctxt ty) unicode qual
  = maybeParen ctxt_prec pREC_FUN $
    hsep [ppForAll expl tvs ctxt unicode qual, ppr_mono_lty pREC_TOP ty unicode qual]

-- UnicodeSyntax alternatives
ppr_mono_ty _ (HsTyVar name) True _
  | getOccString (getName name) == "*"    = toHtml "★"
  | getOccString (getName name) == "(->)" = toHtml "(→)"

ppr_mono_ty _         (HsBangTy b ty)     u q = ppBang b +++ ppLParendType u q ty
ppr_mono_ty _         (HsTyVar name)      _ q = ppDocName q Prefix True name
ppr_mono_ty ctxt_prec (HsFunTy ty1 ty2)   u q = ppr_fun_ty ctxt_prec ty1 ty2 u q
ppr_mono_ty _         (HsTupleTy con tys) u q = tupleParens con (map (ppLType u q) tys)
ppr_mono_ty _         (HsKindSig ty kind) u q =
    parens (ppr_mono_lty pREC_TOP ty u q <+> dcolon u <+> ppLKind u q kind)
ppr_mono_ty _         (HsListTy ty)       u q = brackets (ppr_mono_lty pREC_TOP ty u q)
ppr_mono_ty _         (HsPArrTy ty)       u q = pabrackets (ppr_mono_lty pREC_TOP ty u q)
ppr_mono_ty ctxt_prec (HsIParamTy n ty)   u q =
    maybeParen ctxt_prec pREC_CTX $ ppIPName n <+> dcolon u <+> ppr_mono_lty pREC_TOP ty u q
ppr_mono_ty _         (HsSpliceTy {})     _ _ = error "ppr_mono_ty HsSpliceTy"
ppr_mono_ty _         (HsQuasiQuoteTy {}) _ _ = error "ppr_mono_ty HsQuasiQuoteTy"
ppr_mono_ty _         (HsRecTy {})        _ _ = error "ppr_mono_ty HsRecTy"
ppr_mono_ty _         (HsCoreTy {})       _ _ = error "ppr_mono_ty HsCoreTy"
ppr_mono_ty _         (HsExplicitListTy _ tys) u q = quote $ brackets $ hsep $ punctuate comma $ map (ppLType u q) tys
ppr_mono_ty _         (HsExplicitTupleTy _ tys) u q = quote $ parenList $ map (ppLType u q) tys
ppr_mono_ty _         (HsWrapTy {})       _ _ = error "ppr_mono_ty HsWrapTy"

ppr_mono_ty ctxt_prec (HsEqTy ty1 ty2) unicode qual
  = maybeParen ctxt_prec pREC_CTX $
    ppr_mono_lty pREC_OP ty1 unicode qual <+> char '~' <+> ppr_mono_lty pREC_OP ty2 unicode qual

ppr_mono_ty ctxt_prec (HsAppTy fun_ty arg_ty) unicode qual
  = maybeParen ctxt_prec pREC_CON $
    hsep [ppr_mono_lty pREC_FUN fun_ty unicode qual, ppr_mono_lty pREC_CON arg_ty unicode qual]

ppr_mono_ty ctxt_prec (HsOpTy ty1 (_, op) ty2) unicode qual
  = maybeParen ctxt_prec pREC_FUN $
    ppr_mono_lty pREC_OP ty1 unicode qual <+> ppr_op <+> ppr_mono_lty pREC_OP ty2 unicode qual
  where
    ppr_op = ppLDocName qual Infix op

ppr_mono_ty ctxt_prec (HsParTy ty) unicode qual
--  = parens (ppr_mono_lty pREC_TOP ty)
  = ppr_mono_lty ctxt_prec ty unicode qual

ppr_mono_ty ctxt_prec (HsDocTy ty _) unicode qual
  = ppr_mono_lty ctxt_prec ty unicode qual

ppr_mono_ty _ (HsTyLit n) _ _ = ppr_tylit n

ppr_tylit :: HsTyLit -> Html
ppr_tylit (HsNumTy n) = toHtml (show n)
ppr_tylit (HsStrTy s) = toHtml (show s)


ppr_fun_ty :: Int -> LHsType DocName -> LHsType DocName -> Unicode -> Qualification -> Html
ppr_fun_ty ctxt_prec ty1 ty2 unicode qual
  = let p1 = ppr_mono_lty pREC_FUN ty1 unicode qual
        p2 = ppr_mono_lty pREC_TOP ty2 unicode qual
    in
    maybeParen ctxt_prec pREC_FUN $
    hsep [p1, arrow unicode <+> p2]
