{CompositeDisposable, Emitter} = require 'atom'
net = require 'net'
path = require 'path'
fs = require 'fs'
NameDialog = require './name-dialog'
markerManager = require './marker-manager'
tooltipManager = require './tooltip-manager'
logger = require './logger'
history = require './history-manager'
statusBar = require './status-bar'
{$} = require('atom-space-pen-views')

# The component that is responsible for maintaining the connection with
# the server.
module.exports = ClientManager =
  subscriptions: new CompositeDisposable
  emitter: new Emitter # generates connect and disconnect events
  client: null # the client socket
  ready: false # true, if the client can send messages to the server
  stopped: true # true, if disconnected from the server by the user
  jobs: [] # tasks to do after the connection has been established
  incomingMsg: '' # the part of the incoming message already received
  watchService: false # no need to watch the file system if watch service
                      # is running in the server

  renamedFile: null # The file name that is renamed
  actualRoot: null # The project root of the actual tree command
  lastTreeCommand: null # The name of the last tree command issued

  serverVersionLowerBound: [0,8,0,0] # inclusive minimum of server version
  serverVersionUpperBound: [0,9,0,0] # exclusive upper limit of server version

  activate: () ->
    statusBar.activate()
    history.activate()
    if !@watchService
      history.onUndo ([added, changed, removed]) => @reload added, changed, removed

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:check-server': => @checkServer()

    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      @subscriptions.add editor.onDidSave ({path}) =>
        if !@watchService
          packages = atom.config.get("haskell-tools.refactored-packages")
          for pack in packages
            if path.startsWith pack
              @whenReady () => @reload [], [path], []
              return

    @subscriptions.add atom.commands.onDidDispatch (event) =>
      if event.type == 'tree-view:duplicate'
        @lastTreeCommand = 'tree-view:duplicate'
        @actualRoot = $(event.target).closest('.project-root').find('.project-root-header .icon').attr('data-path')
      if event.type == 'tree-view:move'
        @lastTreeCommand = 'tree-view:move'
        @renamedFile = event.target.getAttribute('data-path')
        @actualRoot = $(event.target).closest('.project-root').find('.project-root-header .icon').attr('data-path')
      if event.type == 'tree-view:add-file'
        @lastTreeCommand = 'tree-view:add-file'
        @actualRoot = $(event.target).closest('.project-root').find('.project-root-header .icon').attr('data-path')
      if event.type == 'tree-view:remove'
        removed = event.target.getAttribute('data-path')
        if removed
          packages = atom.config.get("haskell-tools.refactored-packages")
          # what if the package is inside?
          for pack in packages
            if !@watchService && removed.startsWith pack
              if @ready then @reload [], [], [removed]

    @subscriptions.add atom.commands.onWillDispatch (event) =>
      # need to do before deleting, otherwise it is hard to figure out where it was
      if event.type == 'core:confirm'
        switch @lastTreeCommand
          when 'tree-view:add-file'
            newPath = path.join @actualRoot, $(event.target).closest('atom-text-editor')[0].model.getText()
            # Wait for the file to be created
            watcher = fs.watch path.dirname(newPath), (eventType, fileName) =>
              if fs.existsSync newPath
                watcher.close()
                if !@watchService && @ready
                  @reload [newPath], [], []
          when 'tree-view:duplicate'
            newPath = path.join @actualRoot, $(event.target).closest('atom-text-editor')[0].model.getText()
            # Wait for the file to be created
            watcher = fs.watch path.dirname(newPath), (eventType, fileName) =>
              if fs.existsSync newPath
                watcher.close()
                if !@watchService && @ready
                  @reload [newPath], [], []
          when 'tree-view:move'
            if @ready && @renamedFile
              newPath = path.join @actualRoot, $(event.target).closest('atom-text-editor')[0].model.getText()
              if !@watchService
                @reload [newPath], [], [@renamedFile]

    # Register refactoring commands

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:rename-definition', () => @refactor 'RenameDefinition'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:generate-signature', () => @refactor 'GenerateSignature'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:extract-binding', () => @refactor 'ExtractBinding'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:inline-binding', () => @refactor 'InlineBinding'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:float-out', () => @refactor 'FloatOut'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:organize-imports', () => @refactor 'OrganizeImports'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:generate-exports', () => @refactor 'GenerateExports'

    autoStart = atom.config.get("haskell-tools.start-automatically")

    @emitter.on 'connect', () => @shakeHands()
    @emitter.on 'connect', () => @executeJobs()
    @emitter.on 'connect', () => statusBar.connected()
    @emitter.on 'disconnect', () => statusBar.disconnected()
    @emitter.on 'disconnect', () => markerManager.removeAllMarkers()

    if autoStart
      @connect()

  # Connect to the server. Should not be colled while the connection is alive.
  connect: (watchService) ->
    if @ready
      return # already connected
    @watchService = watchService

    @client = @createConnection()
    @stopped = false
    connectPort = atom.config.get("haskell-tools.connect-port")

    @client.connect connectPort, '127.0.0.1', () =>
      logger.log('ClientManager: Connected to Haskell Tools')
      @ready = true
      @emitter.emit 'connect'

    @client.on 'data', (msg) =>
      str = @incomingMsg + msg.toString()
      if str.match /^\s*$/
        return
      for msgPart in str.split '\n'
        @handleMsg msgPart

    @client.on 'close', () =>
      @emitter.emit 'disconnect'
      if @stopped
        logger.log('ClientManager: Connection closed intentionally.')
        return
      logger.log('ClientManager: Connection closed. Reconnecting after 1s')
      @ready = false
      callback = () => @connect()
      setTimeout callback, 1000

  createConnection: () ->
    new net.Socket

  # Process an incoming message
  handleMsg: (str) ->
    try
      data = JSON.parse(str)
      logger.log('ClientManager: Received: ' + str)
      @incomingMsg = ''
      switch data.tag
        when "KeepAliveResponse" then atom.notifications.addInfo 'Server is up and running'
        when "ErrorMessage" then atom.notifications.addError data.errorMsg
        when "LoadedModules"
          markerManager.removeAllMarkersFromFiles(data.loadedModules.map ([fn,mn]) -> fn)
          tooltipManager.refresh()
          statusBar.loadedData data.loadedModules
        when "LoadingModules" then statusBar.willLoadData data.modulesToLoad
        when "CompilationProblem"
          markerManager.setErrorMarkers(data.errorMarkers)
          tooltipManager.refresh()
          statusBar.compilationProblem()
        when "ModulesChanged" then history.registerUndo(data.undoChanges)
        when "Disconnected" then # will reconnect if needed
        when "HandshakeResponse"
          if data.serverVersion < @serverVersionLowerBound || data.serverVersion >= @serverVersionUpperBound
            errorMsg = "The server version is not compatible with the client version. For this client the server version must be at >= #{@serverVersionLowerBound} and < #{@serverVersionUpperBound}. You should probably update both the client and the server to the latest versions."
            atom.notifications.addError errorMsg
            logger.error errorMsg
        else
          atom.notifications.addError 'Internal error: Unrecognized response'
          logger.error('Unrecognized response from server: ' + msg)
    catch error
      # probably not the whole message is received
      @incomingMsg = str

  # Registers a callback to trigger when the connection is established/restored
  onConnect: (callback) ->
    @emitter.on 'connect', callback

  # Registers a callback to trigger when the connection is lost
  onDisconnect: (callback) ->
    @emitter.on 'disconnect', callback

  # Execute the given job when thes connection is ready
  whenReady: (job) ->
    if @ready
      job()
    else @jobs.push(job)

  # Perform the jobs that are scheduled for execution
  executeJobs: () ->
    jobsToDo = @jobs
    @jobs = []
    for job in jobsToDo
      job()

  dispose: () ->
    @disconnect()
    @subscriptions.dispose()
    history.dispose()
    statusBar.dispose()

  # Disconnect from the server
  disconnect: () ->
    @ready = false
    @stopped = true
    if @client then @client.destroy()

  # Send a command to the server via JSON
  send: (data) ->
    if @ready
      @client.write JSON.stringify(data)
      @client.write '\n'
    else atom.notifications.addError("Haskell-tools: Server is not ready. Start the server first.")

  # These functions send commands to the server on user

  checkServer: () ->
    @send {"tag":"KeepAlive","contents":[]}

  refactor: (refactoring) ->
    editor = atom.workspace.getActivePaneItem()
    if not editor
      return
    file = editor.buffer.file.path
    range = editor.getSelectedBufferRange()

    if refactoring == 'RenameDefinition' || refactoring == 'ExtractBinding'
      dialog = new NameDialog
      dialog.onSuccess ({answer}) =>
        @performRefactor(refactoring, file, range, [answer.text()])
      dialog.attach()
    else @performRefactor(refactoring, file, range, [])


  performRefactor: (refactoring, file, range, params) ->
    selection = "#{range.start.row + 1}:#{range.start.column + 1}-#{range.end.row + 1}:#{range.end.column + 1}"
    @send { 'tag': 'PerformRefactoring', 'refactoring': refactoring, 'modulePath': file, 'editorSelection': selection, 'details': params }
    statusBar.performRefactoring()

  addPackages: (packages) ->
    if packages.length > 0
      @send { 'tag': 'AddPackages', 'addedPathes': packages }
      statusBar.addPackages()

  removePackages: (packages) ->
    if packages.length > 0
      @send { 'tag': 'RemovePackages', 'removedPathes': packages }
      for pkg in packages
        markerManager.removeAllMarkersFromPackage(pkg)

  reload: (added, changed, removed) ->
    if added.length + changed.length + removed.length > 0
      @send { 'tag': 'ReLoad', 'addedModules': added, 'changedModules': changed, 'removedModules': removed }

  shakeHands: () ->
    pluginVersion = atom.packages.getActivePackage('haskell-tools').metadata.version.split '.'
    @send { 'tag': 'Handshake', 'clientVersion': pluginVersion.map (n) -> parseInt(n,10) }
