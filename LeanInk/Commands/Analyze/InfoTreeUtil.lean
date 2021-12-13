import LeanInk.Commands.Analyze.ListUtil
import LeanInk.Output.Alectryon

import Lean.Elab.Command
import Lean.Data.Lsp
import Lean.Meta

namespace LeanInk.Commands.Analyze

open Lean
open Lean.Elab
open Lean.Meta
open Output

/-
  TacticFragment
-/
structure TacticFragment where
  info: TacticInfo
  ctx: ContextInfo
  deriving Inhabited

namespace TacticFragment
  def headPos (f: TacticFragment) : String.Pos := 
    (f.info.toElabInfo.stx.getPos? false).getD 0

  def tailPos (f: TacticFragment) : String.Pos := 
    (f.info.toElabInfo.stx.getTailPos? false).getD 0

  def length (f: TacticFragment) : Nat := 
    tailPos f - headPos f

  def toFormat (f: TacticFragment) : IO Format := 
    TacticInfo.format f.ctx f.info

  def isExpanded (f: TacticFragment) : Bool :=
    match f.info.toElabInfo.stx.getHeadInfo, f.info.toElabInfo.stx.getTailInfo with
    | SourceInfo.original .., SourceInfo.original .. => false
    | _, _ => true

  private def buildGoal (goalType : Format) (hypotheses : List Alectryon.Hypothesis): Name -> MetaM (Alectryon.Goal)
    | Name.anonymous => do
      return { name := "", conclusion := s!"{goalType}", hypotheses := hypotheses.toArray }
    | name => do
      let goalFormatName := format name.eraseMacroScopes
      let goalName := s!"{goalFormatName}"
      return { name := goalName, conclusion := s!"{goalType}", hypotheses := hypotheses.toArray }

  /-
  This method is a adjusted version of the Meta.ppGoal function. As we do need to extract the goal informations into seperate properties instead
  of a single formatted string to support the Alectryon.Goal datatype.
  -/
  private def evalGoal (mvarId : MVarId) : MetaM (Option Alectryon.Goal) := do
    match (← getMCtx).findDecl? mvarId with
    | none => return none
    | some decl => do
      let auxDecl := pp.auxDecls.get (<- getOptions)
      let lctx := decl.lctx.sanitizeNames.run' { options := (← getOptions) }
      withLCtx lctx decl.localInstances do
        let (hidden, hiddenProp) ← ToHide.collect decl.type
        let pushPending (list : List Alectryon.Hypothesis) (type? : Option Expr) : List Name -> MetaM (List Alectryon.Hypothesis)
        | [] => pure list
        | ids => do
          match type? with
            | none      => pure list
            | some type => do
              let typeFmt ← ppExpr type
              let names ← ids.reverse.map (λ n => n.toString)
              return list.append [{ names := names, body := "", type := s!"{typeFmt}" }]
        let evalVar (varNames : List Name) (prevType? : Option Expr) (hypotheses : List Alectryon.Hypothesis) (localDecl : LocalDecl) : MetaM (List Name × Option Expr × (List Alectryon.Hypothesis)) := do
          if hiddenProp.contains localDecl.fvarId then
            let newHypotheses ← pushPending [] prevType? varNames
            let type ← instantiateMVars localDecl.type
            let typeFmt ← ppExpr type
            let newHypotheses := newHypotheses.map (λ h => { h with type := h.type ++ s!" : {typeFmt}"})
            pure ([], none, hypotheses.append newHypotheses)
          else
            match localDecl with
            | LocalDecl.cdecl _ _ varName type _ =>
              let varName := varName.simpMacroScopes
              let type ← instantiateMVars type
              if prevType? == none || prevType? == some type then
                pure (varName::varNames, some type, hypotheses)
              else do
                let hypotheses ← pushPending hypotheses prevType? varNames
                pure ([varName], some type, hypotheses)
            | LocalDecl.ldecl _ _ varName type val _ => do
              let varName := varName.simpMacroScopes
              let hypotheses ← pushPending hypotheses prevType? varNames
              let type ← instantiateMVars type
              let val  ← instantiateMVars val
              let typeFmt ← ppExpr type
              let valFmt ← ppExpr val
              pure ([], none, hypotheses.append [{ names := [varName.toString], body := s!"{valFmt}", type := s!"{typeFmt}" }])
        let (varNames, type?, hypotheses) ← lctx.foldlM (init := ([], none, [])) λ (varNames, prevType?, hypotheses) (localDecl : LocalDecl) =>
          if !auxDecl && localDecl.isAuxDecl || hidden.contains localDecl.fvarId then
            pure (varNames, prevType?, hypotheses)
          else
            evalVar varNames prevType? hypotheses localDecl
        let hypotheses ← pushPending hypotheses type? varNames 
        let typeFmt ← ppExpr (← instantiateMVars decl.type)
        return (← buildGoal typeFmt hypotheses decl.userName)

  private def resolveGoalsAux (ctx : ContextInfo) (mctx : MetavarContext) : List MVarId -> IO (List Alectryon.Goal)
    | [] => []
    | goals => do
      let ctx := { ctx with mctx := mctx }
      return (← ctx.runMetaM {} (goals.mapM (evalGoal .))).filterMap (λ x => x)

  def resolveGoals (self : TacticFragment) : IO (List Alectryon.Goal) := do
    return ← resolveGoalsAux self.ctx self.info.mctxAfter self.info.goalsAfter
end TacticFragment

/-
  MessageFragment
-/
structure MessageFragment where
  headPos: String.Pos
  tailPos: String.Pos
  msg: Message

def Position.toStringPos (fileMap: FileMap) (pos: Position) : String.Pos :=
  FileMap.lspPosToUtf8Pos fileMap (fileMap.leanPosToLspPos pos)

namespace MessageFragment
  def mkFragment (fileMap: FileMap) (msg: Message) : MessageFragment :=
    let headPos := Position.toStringPos fileMap msg.pos
    let tailPos := Position.toStringPos fileMap (msg.endPos.getD msg.pos)
    { headPos := headPos, tailPos := tailPos, msg := msg }

  def length (f: MessageFragment) : Nat := f.tailPos - f.headPos

  def toAlectryonMessage (self : MessageFragment) : IO Alectryon.Message := do
    let message ← self.msg.toString
    return { contents := message }
end MessageFragment

/-
  Term Fragment
-/
structure TermFragment where
  ctx : ContextInfo
  info : TermInfo
  deriving Inhabited

namespace TermFragment
  def headPos (f: TermFragment) : String.Pos := 
    (f.info.toElabInfo.stx.getPos? false).getD 0

  def tailPos (f: TermFragment) : String.Pos := 
    (f.info.toElabInfo.stx.getTailPos? false).getD 0

  def toFormat (f: TermFragment) : IO Format := 
    TermInfo.format f.ctx f.info

  def isExpanded (f: TermFragment) : Bool :=
    match f.info.toElabInfo.stx.getHeadInfo, f.info.toElabInfo.stx.getTailInfo with
    | SourceInfo.original .., SourceInfo.original .. => false
    | _, _ => true
end TermFragment

inductive Fragment where
  | tactic (f : TacticFragment)
  | term (f : TermFragment)

/-
  Traversal Result
-/
structure TraversalResult where
  tactics : List TacticFragment
  terms : List TermFragment
  deriving Inhabited

namespace TraversalResult
  def empty : TraversalResult := {  tactics := [], terms := [] }
  def isEmpty (x : TraversalResult) : Bool := x.tactics.isEmpty ∧ x.terms.isEmpty 
end TraversalResult

/-
  InfoTree traversal
-/
def Info.toFragment (info : Info) (ctx : ContextInfo) : Option Fragment :=
  match info with
  | Info.ofTacticInfo i => 
    let fragment : TacticFragment := { info :=  i, ctx := ctx }
    if fragment.isExpanded then
      none
    else
      Fragment.tactic fragment
  | Info.ofTermInfo i =>
    let fragment : TermFragment := { info :=  i, ctx := ctx }
    if fragment.isExpanded then
      none
    else
      Fragment.term fragment
  | _ => none

def mergeSortFragments (x y : TraversalResult) : TraversalResult := { 
  tactics := List.mergeSort (λ x y => x.headPos < y.headPos) x.tactics y.tactics
  terms := List.mergeSort (λ x y => x.headPos < y.headPos) x.terms y.terms
}

partial def _resolveTacticList (ctx?: Option ContextInfo := none) : InfoTree -> TraversalResult
  | InfoTree.context ctx tree => _resolveTacticList ctx tree
  | InfoTree.node info children =>
    match ctx? with
    | none => TraversalResult.empty
    | some ctx =>
      let ctx? := info.updateContext? ctx
      let resolvedChildrenLeafs := children.toList.map (_resolveTacticList ctx?)
      let sortedChildrenLeafs := resolvedChildrenLeafs.foldl mergeSortFragments TraversalResult.empty
      match Info.toFragment info ctx with
      | some (Fragment.tactic f) => 
        if sortedChildrenLeafs.tactics.isEmpty then 
          { sortedChildrenLeafs with tactics := [f] }
        else 
          sortedChildrenLeafs
      | some (Fragment.term f) => 
        if sortedChildrenLeafs.terms.isEmpty then 
          { sortedChildrenLeafs with terms := [f] }
        else 
          sortedChildrenLeafs
      | none => sortedChildrenLeafs  
  | _ => TraversalResult.empty

def resolveTacticList (trees: List InfoTree) : TraversalResult :=
  (trees.map _resolveTacticList).foldl mergeSortFragments TraversalResult.empty
