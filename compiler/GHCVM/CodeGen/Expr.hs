module GHCVM.CodeGen.Expr where

import CoreSyn
import Type
import TyCon
import Id
import PrimOp
import StgSyn
import DataCon
import Panic
import Util (unzipWith)
import GHCVM.Util
import GHCVM.Primitive
import GHCVM.Debug
import GHCVM.CodeGen.Utils
import GHCVM.CodeGen.Monad
import GHCVM.CodeGen.Name
import GHCVM.CodeGen.Layout
import GHCVM.CodeGen.Types
import GHCVM.CodeGen.Closure
import GHCVM.CodeGen.Env
import GHCVM.CodeGen.Rts
import GHCVM.CodeGen.Con
import GHCVM.CodeGen.Prim
import GHCVM.CodeGen.ArgRep
import GHCVM.CodeGen.LetNoEscape
import {-# SOURCE #-} GHCVM.CodeGen.Bind (cgBind)
import Codec.JVM

import Data.Monoid((<>))
import Data.Maybe(mapMaybe)
import Control.Monad(when, forM_, unless)

cgExpr :: StgExpr -> CodeGen ()
cgExpr (StgApp fun args) = debugDoc (str "SgApp" <+> ppr fun <+> ppr args) >>
                           cgIdApp fun args
cgExpr (StgOpApp (StgPrimOp SeqOp) [StgVarArg a, _] _) = cgIdApp a []
cgExpr (StgOpApp op args ty) = debugDoc (str "StgOpApp" <+> ppr args <+> ppr ty) >>
                               cgOpApp op args ty
cgExpr (StgConApp con args) = debugDoc (str "StgConApp" <+> ppr con <+> ppr args) >>
                              cgConApp con args
cgExpr (StgTick t e) = cgExpr e
cgExpr (StgLit lit) = emitReturn [mkLocDirect False $ cgLit lit]
cgExpr (StgLet binds expr) = do
  cgBind binds
  cgExpr expr
cgExpr (StgLetNoEscape _ _ binds expr) =
  cgLneBinds binds expr

cgExpr (StgCase expr _ _ binder _ altType alts) =
  debugDoc (str "StgCase" <+> ppr expr <+> ppr binder <+> ppr altType) >>
  cgCase expr binder altType alts
cgExpr _ = unimplemented "cgExpr"

cgLneBinds :: StgBinding -> StgExpr -> CodeGen ()
cgLneBinds (StgNonRec binder rhs) expr = do
  (info, genBindCode) <- cgLetNoEscapeRhsBody binder rhs
  bindCode <- genBindCode
  addBinding info
  exprCode <- forkLneBody $ cgExpr expr
  let bindLabel = fst . expectJust "cgLneBinds:StgNonRec" . maybeLetNoEscape $ info
  emit $ letNoEscapeCodeBlocks [(bindLabel, bindCode)] exprCode

cgLneBinds (StgRec pairs) expr = do
  result <- sequence $ unzipWith cgLetNoEscapeRhsBody pairs
  let (infos, genBindCodes) = unzip result
      labels = map (fst . expectJust "cgLneBinds:StgRec" . maybeLetNoEscape) infos
  addBindings infos
  bindCodes <- sequence genBindCodes
  exprCode <- forkLneBody $ cgExpr expr
  emit $ letNoEscapeCodeBlocks (zip labels bindCodes) exprCode

cgLetNoEscapeRhsBody :: Id -> StgRhs -> CodeGen (CgIdInfo, CodeGen Code)
cgLetNoEscapeRhsBody binder (StgRhsClosure _ _ _ _ _ args body)
  = cgLetNoEscapeClosure binder (nonVoidIds args) body
cgLetNoEscapeRhsBody binder (StgRhsCon _ con args)
  = cgLetNoEscapeClosure binder [] (StgConApp con args)

cgLetNoEscapeClosure
  :: Id -> [NonVoid Id] -> StgExpr -> CodeGen (CgIdInfo, CodeGen Code)
cgLetNoEscapeClosure binder args body = do
  label <- newLabel
  -- Restore the local variable count so that
  -- Those locals can be reused later on
  n <- peekNextLocal
  argLocs <- mapM newIdLoc args
  n' <- peekNextLocal
  setNextLocal n
  let code = forkLneBody $ do
          bindArgs $ zip args argLocs
          setNextLocal n'
          cgExpr body
  return (lneIdInfo label binder argLocs, code)

cgIdApp :: Id -> [StgArg] -> CodeGen ()
cgIdApp funId [] | isVoidJTy (idType funId) = emitReturn []
cgIdApp funId args = do
  dflags <- getDynFlags
  funInfo <- getCgIdInfo funId
  selfLoopInfo <- getSelfLoop
  let cgFunId = cgId funInfo
      funArg = StgVarArg cgFunId
      funName = idName cgFunId
      fun = idInfoLoadCode funInfo
      lfInfo = cgLambdaForm funInfo
      funLoc = cgLocation funInfo
  case getCallMethod dflags funName cgFunId lfInfo (length args) funLoc
                     selfLoopInfo of
    ReturnIt -> debugIO "cgIdApp: ReturnIt" >>
                emitReturn [funLoc]
    EnterIt -> debugIO "cgIdApp: EnterIt" >>
               emitEnter funLoc
    SlowCall -> debugIO "cgIdApp: SlowCall" >>
                (withContinuation $ slowCall funLoc args)
    DirectEntry entryCode arity -> debugIO "cgIdApp: DirectEntry" >>
                (withContinuation $ directCall False entryCode arity args)
    JumpToIt label cgLocs -> do
      debugIO "cgIdApp: JumpToIt"
      codes <- getNonVoidArgLoadCodes args
      emit $ multiAssign cgLocs codes
          <> goto label

withContinuation :: CodeGen () -> CodeGen ()
withContinuation call = do
  call
  sequel <- getSequel
  case sequel of
    AssignTo cgLocs -> emit $ mkReturnEntry cgLocs
    _               -> return ()

emitEnter :: CgLoc -> CodeGen ()
emitEnter thunk = do
  sequel <- getSequel
  case sequel of
    Return ->
      emit $ enterMethod thunk
    AssignTo cgLocs ->
      emit $ evaluateMethod thunk
          <> mkReturnEntry cgLocs

cgConApp :: DataCon -> [StgArg] -> CodeGen ()
cgConApp con args
  | isUnboxedTupleCon con = do
      repCodes <- getNonVoidRepCodes args
      emitReturn $ map mkRepLocDirect repCodes
  | otherwise = do
      -- TODO: Is dataConWorId the right thing to pass?
      (idInfo, genInitCode) <- buildDynCon (dataConWorkId con) con args
      initCode <- genInitCode
      emit initCode
      emitReturn [cgLocation idInfo]

cgCase :: StgExpr -> Id -> AltType -> [StgAlt] -> CodeGen ()
cgCase (StgOpApp (StgPrimOp op) args _) binder (AlgAlt tyCon) alts
  | isEnumerationTyCon tyCon = do
      tagExpr <- doEnumPrimop op args
      let closureCode = snd $ tagToClosure tyCon tagExpr
      loadCode <- if not $ isDeadBinder binder then do
          bindLoc <- newIdLoc (NonVoid binder)
          bindArg (NonVoid binder) bindLoc
          emitAssign bindLoc closureCode
          return $ loadLoc bindLoc
        else return closureCode
      (maybeDefault, branches) <- cgAlgAltRhss (NonVoid binder) alts
      emit $ intSwitch (getTagMethod loadCode) branches maybeDefault
  where doEnumPrimop :: PrimOp -> [StgArg] -> CodeGen Code
        doEnumPrimop TagToEnumOp [arg] =
          getArgLoadCode (NonVoid arg)
        doEnumPrimop primop args = do
          tmp <- newTemp intRep
          cgPrimOp [tmp] primop args
          return (loadLoc tmp)

cgCase (StgApp v []) _ (PrimAlt _) alts
  | isVoidJRep (idJPrimRep v)
  , [(DEFAULT, _, _, rhs)] <- alts
  = cgExpr rhs

cgCase (StgApp v []) binder altType@(PrimAlt _) alts
  | isUnLiftedType (idType v)
  || repsCompatible
  = do
      when (not repsCompatible) $
        panic "cgCase: reps do not match, perhaps a dodgy unsafeCoerce?"
      vInfo <- getCgIdInfo v
      binderLoc <- newIdLoc nvBinder
      emitAssign binderLoc (idInfoLoadCode vInfo)
      bindArgs [(nvBinder, binderLoc)]
      cgAlts nvBinder altType alts
  where repsCompatible = vRep == idJPrimRep binder
        -- TODO: Allow integer conversions?
        nvBinder = NonVoid binder
        vRep = idJPrimRep v

cgCase scrut@(StgApp v []) _ (PrimAlt _) _ = do
  cgLoc <- newIdLoc (NonVoid v)
  withSequel (AssignTo [cgLoc]) $ cgExpr scrut
  panic "cgCase: bad unsafeCoerce!"
  -- TODO: Generate infinite loop here?

cgCase (StgOpApp (StgPrimOp SeqOp) [StgVarArg a, _] _) binder altType alts
  = cgCase (StgApp a []) binder altType alts

cgCase scrut binder altType alts = do
  altLocs <- mapM newIdLoc retBinders
  -- Take into account uses for unboxed tuples
  withSequel (AssignTo altLocs) $ cgExpr scrut
  bindArgs $ zip retBinders altLocs
  cgAlts (NonVoid binder) altType alts
  where retBinders = chooseReturnBinders binder altType alts

chooseReturnBinders :: Id -> AltType -> [StgAlt] -> [NonVoid Id]
chooseReturnBinders binder (PrimAlt _) _ = nonVoidIds [binder]
chooseReturnBinders _ (UbxTupAlt _) [(_, ids, _, _)] = nonVoidIds ids
chooseReturnBinders binder (AlgAlt _) _ = nonVoidIds [binder]
chooseReturnBinders binder PolyAlt _ = nonVoidIds [binder]
chooseReturnBinders _ _ _ = panic "chooseReturnBinders"

cgAlts :: NonVoid Id -> AltType -> [StgAlt] -> CodeGen ()
cgAlts _ PolyAlt [(_, _, _, rhs)] = cgExpr rhs
cgAlts _ (UbxTupAlt _) [(_, _, _, rhs)] = cgExpr rhs
cgAlts binder (PrimAlt _) alts = do
  taggedBranches <- cgAltRhss binder alts
  binderLoc <- getCgLoc binder
  let (DEFAULT, deflt) = head taggedBranches
      taggedBranches' = [(lit, code) | (LitAlt lit, code) <- taggedBranches]
  emit $ litSwitch (locFt binderLoc) (loadLoc binderLoc) taggedBranches' deflt
cgAlts binder (AlgAlt tyCon) alts = do
  (maybeDefault, branches) <- cgAlgAltRhss binder alts
  binderLoc <- getCgLoc binder
  emit $ intSwitch (getTagMethod $ loadLoc binderLoc) branches maybeDefault
cgAlts _ _ _ = panic "cgAlts"

cgAltRhss :: NonVoid Id -> [StgAlt] -> CodeGen [(AltCon, Code)]
cgAltRhss binder alts =
  forkAlts $ map cgAlt alts
  where cgAlt :: StgAlt -> (AltCon, CodeGen ())
        cgAlt (con, binders, uses, rhs) =
          ( con
          ,  bindConArgs con binder binders uses
          >> cgExpr rhs )

bindConArgs :: AltCon -> NonVoid Id -> [Id] -> [Bool] -> CodeGen ()
bindConArgs (DataAlt con) binder args uses
  | not (null args), or uses = do
    base <- getCgLoc binder
    emit $ loadLoc base
        <> gconv conType dataFt
    -- TODO: Take into account uses as well
    forM_ indexedFields $ \(i, (ft, (arg, use))) ->
      when use $ do
        let nvArg = NonVoid arg
        cgLoc <- newIdLoc nvArg
        emitAssign cgLoc $ dup dataFt
                        <> getfield (mkFieldRef conClass (constrField i) ft)
        bindArg nvArg cgLoc
    -- TODO: Remove this pop in a clever way
    emit $ pop dataFt
    where indexedFields = indexList . mapMaybe (\(mb, args) ->
                                                  case mb of
                                                    Just m -> Just (m, args)
                                                    Nothing -> Nothing)
                                    $ zip maybeFields (zip args uses)
          conClass = dataConClass con
          dataFt = obj conClass
          maybeFields = map repFieldType $ dataConRepArgTys con
bindConArgs _ _ _ _ = return ()

cgAlgAltRhss :: NonVoid Id -> [StgAlt] -> CodeGen (Maybe Code, [(Int, Code)])
cgAlgAltRhss binder alts = do
  taggedBranches <- cgAltRhss binder alts
  let maybeDefault = case taggedBranches of
                       ((DEFAULT, rhs) : _) -> Just rhs
                       _ -> Nothing
      branches = [ (getDataConTag con, code)
                 | (DataAlt con, code) <- taggedBranches ]
  return (maybeDefault, branches)



