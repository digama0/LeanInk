namespace LeanInk.Commands.Analyze

open System

def leanFileExtension := s!"lean"

def isLeanFile (path : FilePath) : Bool := do
  return path.extension == leanFileExtension