{CompositeDisposable,Emitter} = require 'atom'
fs = require 'fs'

# Keeps track of performed refactorings.
module.exports = HistoryManager =
  undoStack: []
  emitter: new Emitter

  activate: () ->
    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:undo-refactoring': => @undoRefactoring()

    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      # TODO: Currently refactor and normal undo stack is not interleaved.
      # If they were, we won't have to delete the refactor history on every save.
      @subscriptions.add editor.onDidSave ({path}) =>
        @undoStack = []

  # The callback is activated when a refactoring is undone.
  # The callback receives [changed, removed] where changed is the
  # array of changed file names, removed is the array of removed file names
  onUndo: (callback) ->
    @emitter.on 'undo', callback

  # Takes back the last refactoring performed. Uses the undo instructions
  # sent by the server.
  undoRefactoring: () ->
    changed = []
    removed = []
    if @undoStack.length > 0
      for undo in @undoStack.pop()
       switch undo.tag
         when 'RemoveAdded'
           fs.unlink undo.undoRemovePath
           removed.push undo.undoRemovePath
         when 'RestoreRemoved'
           fs.writeFile undo.undoRestorePath, undo.undoRestoreContents
           changed.push undo.undoRestorePath
         when 'UndoChanges'
           # restore the content of the file using a diff
           content = fs.readFileSync undo.undoChangedPath
           result = Buffer.from []
           lastPos = 0
           for [from,nextPos,replace] in undo.undoDiff
             unchanged = content.slice lastPos, from
             result = Buffer.concat [result, unchanged, Buffer.from replace]
             lastPos = nextPos
           result = Buffer.concat [result, content.slice(lastPos)]
           fs.truncate
           fs.writeFile undo.undoChangedPath, result
           changed.push undo.undoChangedPath
    @emitter.emit 'undo', [changed, removed]

  # Saves the instructions to undo the last refactoring.
  registerUndo: (undo) -> @undoStack.push undo

  dispose: () ->
    @subscriptions.dispose()
