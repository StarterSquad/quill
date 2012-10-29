#= require underscore
#= require rangy/rangy-core
#= require diff_match_patch
#= require eventemitter2
#= require tandem/document
#= require tandem/range
#= require tandem/keyboard
#= require tandem/selection
#= require tandem/renderer

class TandemEditor extends EventEmitter2
  @editors: []

  @CONTAINER_ID: 'tandem-container'
  @ID_PREFIX: 'editor-'
  @DEFAULTS:
    cursor: 0
    enabled: true
    styles: {}

  @events: 
    API_TEXT_CHANGE       : 'api-text-change'
    USER_SELECTION_CHANGE : 'user-selection-change'
    USER_TEXT_CHANGE      : 'user-text-change'

  constructor: (@iframeContainer, options) ->
    @options = _.extend(Tandem.Editor.DEFAULTS, options)
    @id = _.uniqueId(TandemEditor.ID_PREFIX)
    @iframeContainer = document.getElementById(@iframeContainer) if _.isString(@iframeContainer)
    @destructors = []
    this.reset(true)
    this.enable() if @options.enabled

  destroy: ->
    this.disable()
    @renderer.destroy()
    @selection.destroy()
    _.each(@destructors, (fn) =>
      fn.call(this)
    )
    @destructors = null

  reset: (keepHTML = false) ->
    @ignoreDomChanges = true
    options = _.clone(@options)
    options.keepHTML = keepHTML
    @renderer = new Tandem.Renderer(@iframeContainer, options)
    @contentWindow = @renderer.iframe.contentWindow
    @doc = new Tandem.Document(this, @contentWindow.document.getElementById(TandemEditor.CONTAINER_ID))
    @selection = new Tandem.Selection(this)
    @keyboard = new Tandem.Keyboard(this)
    this.initListeners()
    @ignoreDomChanges = false
    TandemEditor.editors.push(this)

  disable: ->
    this.trackDelta( =>
      @doc.root.setAttribute('contenteditable', false)
    , false)

  enable: ->
    if !@doc.root.getAttribute('contenteditable')
      this.trackDelta( =>
        @doc.root.setAttribute('contenteditable', true)
      , false)
      @doc.root.focus()
      position = Tandem.Position.makePosition(this, @options.cursor)
      start = new Tandem.Range(this, position, position)
      this.setSelection(start)

  initListeners: ->
    deboundedEdit = _.debounce( =>
      return if @ignoreDomChanges or !@destructors?
      delta = this.update()
      this.emit(TandemEditor.events.USER_TEXT_CHANGE, delta) if !delta.isIdentity()
    , 100)
    @doc.root.addEventListener('DOMSubtreeModified', deboundedEdit)
    @destructors.push( ->
      @doc.root.removeEventListener('DOMSubtreeModified', deboundedEdit)
    )

  # applyAttribute: (TandemRange range, String attr, Mixed value) ->
  # applyAttribute: (Number startIndex, Number length, String attr, Mixed value) ->
  applyAttribute: (startIndex, length, attr, value, emitEvent = true) ->
    delta = this.trackDelta( =>
      if !_.isNumber(startIndex)
        [range, attr, value] = [startIndex, length, attr]
        startIndex = range.start.getIndex()
        length = range.end.getIndex() - startIndex
      else
        range = new Tandem.Range(this, startIndex, startIndex + length)
      @selection.preserve( =>
        [startLine, startLineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
        [endLine, endLineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex + length)
        if startLine == endLine
          this.applyAttributeToLine(startLine, startLineOffset, endLineOffset, attr, value)
        else
          curLine = startLine.nextSibling
          while curLine? && curLine != endLine
            nextSibling = curLine.nextSibling
            this.applyAttributeToLine(curLine, 0, curLine.textContent.length, attr, value)
            curLine = nextSibling
          this.applyAttributeToLine(startLine, startLineOffset, startLine.textContent.length, attr, value)
          this.applyAttributeToLine(endLine, 0, endLineOffset, attr, value) if endLine?
        @doc.rebuildDirty()
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  applyAttributeToLine: (lineNode, startOffset, endOffset, attr, value) ->
    return if endOffset == startOffset
    line = @doc.findLine(lineNode)
    if _.indexOf(Tandem.Constants.LINE_ATTRIBUTES, attr, true) > -1
      this.applyLineAttribute(line, attr, value)
    else
      return if startOffset == endOffset
      [prevNode, startNode] = line.splitContents(startOffset)
      [endNode, nextNode] = line.splitContents(endOffset)
      parentNode = startNode?.parentNode || prevNode?.parentNode
      if value && Tandem.Utils.getAttributeDefault(attr) != value
        fragment = @doc.root.ownerDocument.createDocumentFragment()
        Tandem.Utils.traverseSiblings(startNode, endNode, (node) ->
          node = Tandem.Utils.removeAttributeFromSubtree(node, attr)
          fragment.appendChild(node)
        )
        attrNode = Tandem.Utils.createContainerForAttribute(@doc.root.ownerDocument, attr, value)
        attrNode.appendChild(fragment)
        parentNode.insertBefore(attrNode, nextNode)
      else
        Tandem.Utils.traverseSiblings(startNode, endNode, (node) ->
          Tandem.Utils.removeAttributeFromSubtree(node, attr)
        )
    @doc.updateLine(line)
    Tandem.Document.fixListNumbering(@doc.root) if attr == 'list'

  applyDelta: (delta) ->
    console.assert(delta.startLength == @doc.length, "Trying to apply delta to incorrect doc length", delta, @doc, @doc.root)
    index = 0       # Stores where the last retain end was, so if we see another one, we know to delete
    offset = 0      # Tracks how many characters inserted to correctly offset new text
    oldDelta = @doc.toDelta()
    _.each(delta.deltas, (delta) =>
      if JetDelta.isInsert(delta)
        this.insertAt(index + offset, delta.text, false)
        _.each(delta.attributes, (value, attr) =>
          this.applyAttribute(index + offset, delta.text.length, attr, value, false)
        )
        offset += delta.getLength()
      else if JetDelta.isRetain(delta)
        if delta.start > index
          this.deleteAt(index + offset, delta.start - index, false)
          offset -= (delta.start - index)
        # TODO fix need to have special case of applying removals first
        _.each(delta.attributes, (value, attr) =>
          this.applyAttribute(delta.start + offset, delta.end - delta.start, attr, value, false) if value == null
        )
        _.each(delta.attributes, (value, attr) =>
          this.applyAttribute(delta.start + offset, delta.end - delta.start, attr, value, false) if value?
        )
        index = delta.end
      else
        console.warn('Unrecognized type in delta', delta)
    )
    # If end of text was deleted
    if delta.endLength < delta.startLength + offset
      this.deleteAt(delta.endLength, delta.startLength + offset - delta.endLength, false)
    newDelta = @doc.toDelta()
    composed = JetSync.compose(oldDelta, delta)
    composed.compact()
    console.assert(_.isEqual(composed, newDelta), oldDelta, delta, composed, newDelta)

  applyLineAttribute: (line, attr, value) ->
    indent = if _.isNumber(value) then value else (if value then 1 else 0)
    if attr == 'indent'
      Tandem.Utils.setIndent(line.node, indent)
    else if Tandem.Constants.INDENT_ATTRIBUTES[attr]?
      lineNode = line.node
      expectedTag = if value then (if attr == 'list' then 'OL' else 'UL') else 'DIV'
      if lineNode.tagName != expectedTag
        if value && lineNode.firstChild.tagName != 'LI'
          li = lineNode.ownerDocument.createElement('li')
          Tandem.Utils.wrapChildren(li, lineNode)
        else if !value && lineNode.firstChild.tagName == 'LI'
          Tandem.Utils.unwrap(lineNode.firstChild)
        line.node = Tandem.Utils.switchTag(lineNode, expectedTag)
      Tandem.Utils.setIndent(line.node, indent)
    line.setDirty()

  deleteAt: (startIndex, length, emitEvent = true) ->
    delta = this.trackDelta( =>
      if !_.isNumber(startIndex)
        range = startIndex
        startPos = range.start
        endPos = range.end
        startIndex = range.start.getIndex()
        length = range.end.getIndex() - startIndex
      else
        startPos = Tandem.Position.makePosition(this, startIndex)
        endPos = Tandem.Position.makePosition(this, startIndex + length)
      startIndex = startPos.getIndex()
      endIndex = endPos.getIndex()
      @selection.preserve( =>
        [startLineNode, startOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
        [endLineNode, endOffset] = Tandem.Utils.getChildAtOffset(@doc.root, endIndex)
        fragment = Tandem.Utils.extractNodes(startLineNode, startOffset, endLineNode, endOffset)
        lineNodes = _.values(fragment.childNodes).concat(_.uniq([startLineNode, endLineNode]))
        _.each(lineNodes, (lineNode) =>
          line = @doc.findLine(lineNode)
          @doc.updateLine(line) if line?
        )
        @doc.rebuildDirty()
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  getAt: (startIndex, length) ->
    # - Returns array of {text: "", attr: {}}
    # 1. Get all nodes in the range
    # 2. For first and last, change the text
    # 3. Return array
    # - Helper to get nodes in given index range
    # - In the case of 0 lenght, text will always be "", but attributes should be properly applied

  getDelta: ->
    return @doc.toDelta()

  getSelection: ->
    return @selection.getRange()

  insertAt: (startIndex, text, emitEvent = true) ->
    delta = this.trackDelta( =>
      position = Tandem.Position.makePosition(this, startIndex)
      index = startIndex = position.getIndex()
      startLine = @doc.findLineAtOffset(index)
      attr = if startLineNode? then startLine.attributes else {}
      @selection.preserve( =>
        lines = text.split("\n")
        _.each(lines, (line, lineIndex) =>
          strings = line.split("\t")
          _.each(strings, (str, strIndex) =>
            this.insertTextAt(index, str)
            index += str.length
            if strIndex < strings.length - 1
              this.insertTabAt(index)
              index += 1
          )
          if lineIndex < lines.length - 1
            this.insertNewlineAt(index)
            index += 1
          else
            # TODO could be more clever about if we need to call this
            Tandem.Document.fixListNumbering(@doc.root)
        )
        @doc.rebuildDirty()
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  insertNewlineAt: (startIndex) ->
    [line, offset] = @doc.findLineAtOffset(startIndex)
    if offset == 0 or offset == line.length
      refLine = if offset == 0 then line else line.next
      div = @doc.root.ownerDocument.createElement('div')
      @doc.root.insertBefore(div, if refLine? then refLine.node else null)
      @doc.insertLineBefore(div, refLine)
    else
      newLine = @doc.splitLine(line, offset)

  insertTabAt: (startIndex) ->
    [startLineNode, startLineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
    startLine = @doc.findLine(startLineNode)
    [prevNode, startNode] = startLine.splitContents(startLineOffset)
    tab = startLineNode.ownerDocument.createElement('span')
    tab.classList.add(Tandem.Leaf.TAB_NODE_CLASS)
    tab.classList.add(Tandem.Constants.SPECIAL_CLASSES.ATOMIC)
    parentNode = prevNode?.parentNode || startNode?.parentNode
    parentNode.insertBefore(tab, startNode)
    @doc.updateLine(startLine)

  # insertTextAt: (Number startIndex, String text) ->
  # insertTextAt: (TandemRange startIndex, String text) ->
  insertTextAt: (startIndex, text) ->
    return if text.length <= 0
    position = Tandem.Position.makePosition(this, startIndex)
    startIndex = position.getIndex()
    leaf = position.getLeaf()
    if _.keys(leaf.attributes).length > 0 || !Tandem.Utils.canModify(leaf.node)
      [lineNode, lineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
      [beforeNode, afterNode] = leaf.line.splitContents(lineOffset)
      parentNode = beforeNode?.parentNode || afterNode?.parentNode
      span = lineNode.ownerDocument.createElement('span')
      span.textContent = text
      parentNode.insertBefore(span, afterNode)
    else
      if leaf.node.nodeName == 'BR'
        parent = leaf.node.parentNode
        parent.removeChild(leaf.node)
        leaf.node = parent.ownerDocument.createElement('span')
        leaf.node.textContent = text
        parent.appendChild(leaf.node)
      else
        leaf.insertText(position.offset, text)
    @doc.updateLine(leaf.line)

  setSelection: (range) ->
    @selection.setRange(range)

  trackDelta: (fn, track = true) ->
    oldIgnoreDomChange = @ignoreDomChanges
    @ignoreDomChanges = true
    delta = null
    if track
      oldDelta = @doc.toDelta()
      fn()
      newDelta = @doc.toDelta()
      decompose = JetSync.decompose(oldDelta, newDelta)
      compose = JetSync.compose(oldDelta, decompose)
      console.assert(_.isEqual(compose, newDelta), oldDelta, newDelta, decompose, compose)
      delta = decompose
    else
      fn()
    @ignoreDomChanges = oldIgnoreDomChange
    return delta

  update: ->
    delta = this.trackDelta( =>
      @selection.preserve( =>
        Tandem.Document.normalizeHtml(@doc.root)
        lines = @doc.lines.toArray()
        lineNode = @doc.root.firstChild
        _.each(lines, (line, index) =>
          while line.node != lineNode
            if line.node.parentNode == @doc.root
              newLine = @doc.insertLineBefore(lineNode, line)
              lineNode = lineNode.nextSibling
            else
              @doc.removeLine(line)
              return
          @doc.updateLine(line)
          lineNode = lineNode.nextSibling
        )
        while lineNode != null
          newLine = @doc.appendLine(lineNode)
          lineNode = lineNode.nextSibling
      )
    , true)
    return delta



window.Tandem ||= {}
window.Tandem.Editor = TandemEditor
