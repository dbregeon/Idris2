module TTImp.Elab.RunElab

import Core.Context
import Core.Core
import Core.Env
import Core.GetType
import Core.Metadata
import Core.Normalise
import Core.Options
import Core.Reflect
import Core.Unify
import Core.TT
import Core.Value

import TTImp.Elab.Check
import TTImp.Elab.Delayed
import TTImp.Reflect
import TTImp.TTImp
import TTImp.Unelab
import TTImp.Utils

export
elabScript : {vars : _} ->
             {auto c : Ref Ctxt Defs} ->
             {auto m : Ref MD Metadata} ->
             {auto u : Ref UST UState} ->
             FC -> NestedNames vars ->
             Env Term vars -> NF vars -> Maybe (Glued vars) ->
             Core (NF vars)
elabScript fc nest env (NDCon nfc nm t ar args) exp
    = do defs <- get Ctxt
         fnm <- toFullNames nm
         case fnm of
              NS ["Reflection", "Language"] (UN n)
                 => elabCon defs n args
              _ => failWith defs
  where
    failWith : Defs -> Core a
    failWith defs
      = do defs <- get Ctxt
           empty <- clearDefs defs
           throw (BadRunElab fc env !(quote empty env (NDCon nfc nm t ar args)))

    scriptRet : Reflect a => a -> Core (NF vars)
    scriptRet tm
        = do defs <- get Ctxt
             nfOpts withAll defs env !(reflect fc defs False env tm)

    elabCon : Defs -> String -> List (Closure vars) -> Core (NF vars)
    elabCon defs "Pure" [_,val]
        = do empty <- clearDefs defs
             evalClosure empty val
    elabCon defs "Bind" [_,_,act,k]
        = do act' <- elabScript fc nest env
                                !(evalClosure defs act) exp
             case !(evalClosure defs k) of
                  NBind _ x (Lam _ _ _) sc =>
                      do empty <- clearDefs defs
                         elabScript fc nest env
                                 !(sc defs (toClosure withAll env
                                                 !(quote empty env act'))) exp
                  _ => failWith defs
    elabCon defs "Fail" [_,msg]
        = do msg' <- evalClosure defs msg
             throw (GenericMsg fc ("Error during reflection: " ++
                                      !(reify defs msg')))
    elabCon defs "LogMsg" [lvl, str]
        = do lvl' <- evalClosure defs lvl
             logC !(reify defs lvl') $
                  do str' <- evalClosure defs str
                     reify defs str'
             scriptRet ()
    elabCon defs "LogTerm" [lvl, str, tm]
        = do lvl' <- evalClosure defs lvl
             logC !(reify defs lvl') $
                  do str' <- evalClosure defs str
                     tm' <- evalClosure defs tm
                     pure $ !(reify defs str') ++ ": " ++
                             show (the RawImp !(reify defs tm'))
             scriptRet ()
    elabCon defs "Check" [exp, ttimp]
        = do exp' <- evalClosure defs exp
             ttimp' <- evalClosure defs ttimp
             tidx <- resolveName (UN "[elaborator script]")
             e <- newRef EST (initEState tidx env)
             (checktm, _) <- runDelays 0 $
                     check top (initElabInfo InExpr) nest env !(reify defs ttimp')
                           (Just (glueBack defs env exp'))
             empty <- clearDefs defs
             nf empty env checktm
    elabCon defs "Quote" [exp, tm]
        = do tm' <- evalClosure defs tm
             defs <- get Ctxt
             empty <- clearDefs defs
             scriptRet !(unelabUniqueBinders env !(quote empty env tm'))
    elabCon defs "Goal" []
        = do let Just gty = exp
                 | Nothing => nfOpts withAll defs env
                                     !(reflect fc defs False env (the (Maybe RawImp) Nothing))
             ty <- getTerm gty
             scriptRet (Just !(unelabUniqueBinders env ty))
    elabCon defs "LocalVars" []
        = scriptRet vars
    elabCon defs "GenSym" [str]
        = do str' <- evalClosure defs str
             n <- genVarName !(reify defs str')
             scriptRet n
    elabCon defs "InCurrentNS" [n]
        = do n' <- evalClosure defs n
             nsn <- inCurrentNS !(reify defs n')
             scriptRet nsn
    elabCon defs "GetType" [n]
        = do n' <- evalClosure defs n
             res <- lookupTyName !(reify defs n') (gamma defs)
             scriptRet !(traverse unelabType res)
      where
        unelabType : (Name, Int, ClosedTerm) -> Core (Name, RawImp)
        unelabType (n, _, ty)
            = pure (n, !(unelabUniqueBinders [] ty))
    elabCon defs "GetLocalType" [n]
        = do n' <- evalClosure defs n
             n <- reify defs n'
             case defined n env of
                  Just (MkIsDefined rigb lv) =>
                       do let binder = getBinder lv env
                          let bty = binderType binder
                          scriptRet !(unelabUniqueBinders env bty)
                  _ => throw (GenericMsg fc (show n ++ " is not a local variable"))
    elabCon defs "GetCons" [n]
        = do n' <- evalClosure defs n
             cn <- reify defs n'
             Just (TCon _ _ _ _ _ _ cons _) <-
                     lookupDefExact cn (gamma defs)
                 | _ => throw (GenericMsg fc (show cn ++ " is not a type"))
             scriptRet cons
    elabCon defs "Declare" [d]
        = do d' <- evalClosure defs d
             decls <- reify defs d'
             traverse_ (processDecl [] (MkNested []) []) decls
             scriptRet ()
    elabCon defs n args = failWith defs
elabScript fc nest env script exp
    = do defs <- get Ctxt
         empty <- clearDefs defs
         throw (BadRunElab fc env !(quote empty env script))

export
checkRunElab : {vars : _} ->
               {auto c : Ref Ctxt Defs} ->
               {auto m : Ref MD Metadata} ->
               {auto u : Ref UST UState} ->
               {auto e : Ref EST (EState vars)} ->
               RigCount -> ElabInfo ->
               NestedNames vars -> Env Term vars -> 
               FC -> RawImp -> Maybe (Glued vars) ->
               Core (Term vars, Glued vars)
checkRunElab rig elabinfo nest env fc script exp
    = do expected <- mkExpected exp
         defs <- get Ctxt
         when (not (isExtension ElabReflection defs)) $
             throw (GenericMsg fc "%language ElabReflection not enabled")
         let n = NS ["Reflection", "Language"] (UN "Elab")
         let ttn = reflectiontt "TT"
         elabtt <- appCon fc defs n [expected]
         (stm, sty) <- runDelays 0 $
                           check rig elabinfo nest env script (Just (gnf env elabtt))
         defs <- get Ctxt -- checking might have resolved some holes
         ntm <- elabScript fc nest env
                           !(nfOpts withAll defs env stm) (Just (gnf env expected))
         defs <- get Ctxt -- might have updated as part of the script
         empty <- clearDefs defs
         pure (!(quote empty env ntm), gnf env expected)
  where
    mkExpected : Maybe (Glued vars) -> Core (Term vars)
    mkExpected (Just ty) = pure !(getTerm ty)
    mkExpected Nothing
        = do nm <- genName "scriptTy"
             metaVar fc erased env nm (TType fc)