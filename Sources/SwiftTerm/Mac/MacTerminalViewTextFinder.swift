//
//  MacTerminalViewTextFinder.swift
//  SwiftTerm
//
//  Bridges TerminalView to the system-standard NSTextFinder so ⌘F
//  brings up the native find bar instead of a custom UI.
//
//  The NSTextFinderClient is a separate object rather than TerminalView
//  itself: TerminalView already conforms to NSTextInputClient, and making
//  a single class answer both protocols turned out to confuse AppKit's
//  text input routing (adding properties like `string`, `isEditable`,
//  or `selectedRanges` onto the view side breaks keyboard input).
//

#if os(macOS)
import AppKit
import Foundation

/// Exposes the terminal's visible + scrollback buffer to NSTextFinder as a
/// flat NSString, and translates NSTextFinder's NSRange results back into
/// the (row, col) positions that SelectionService + scrollTo consume.
final class TerminalFindClient: NSObject, NSTextFinderClient {
    weak var owner: TerminalView?

    private var cachedString: String?
    private var rowOffsets: [Int]?
    private var rowStrings: [String]?

    init(owner: TerminalView) {
        self.owner = owner
    }

    /// Drops the cached materialization so the next NSTextFinder read re-builds.
    /// Call when buffer contents or geometry change.
    func invalidate() {
        cachedString = nil
        rowOffsets = nil
        rowStrings = nil
    }

    // MARK: - NSTextFinderClient

    var string: String {
        rebuildIfNeeded()
        return cachedString ?? ""
    }

    var stringLength: Int {
        rebuildIfNeeded()
        return (cachedString as NSString?)?.length ?? 0
    }

    var firstSelectedRange: NSRange {
        selectedRanges.first?.rangeValue ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get {
            guard let owner,
                  let selection = owner.selection,
                  selection.active,
                  selection.hasSelectionRange else {
                return [NSValue(range: NSRange(location: 0, length: 0))]
            }
            rebuildIfNeeded()
            let (a, b) = orderedPositions(start: selection.start, end: selection.end)
            let start = utf16Offset(for: a)
            let end = utf16Offset(for: b)
            let loc = min(start, end)
            let len = max(0, max(start, end) - loc)
            return [NSValue(range: NSRange(location: loc, length: len))]
        }
        set {
            guard let first = newValue.first?.rangeValue, first.length > 0 else {
                owner?.selection?.selectNone()
                return
            }
            applyRange(first, scroll: false)
        }
    }

    var isSelectable: Bool { true }
    var isEditable: Bool { false }
    var allowsMultipleSelection: Bool { false }

    func scrollRangeToVisible(_ range: NSRange) {
        guard range.length > 0 else { return }
        applyRange(range, scroll: true)
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        rebuildIfNeeded()
        let len = (cachedString as NSString?)?.length ?? 0
        outRange.pointee = NSRange(location: 0, length: len)
        return owner ?? NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        // Let SelectionService handle highlight rendering.
        nil
    }

    var visibleCharacterRanges: [NSValue] {
        rebuildIfNeeded()
        let len = (cachedString as NSString?)?.length ?? 0
        return [NSValue(range: NSRange(location: 0, length: len))]
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        false
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        // Read-only: no-op.
    }

    // MARK: - Materialization

    private func rebuildIfNeeded() {
        if cachedString != nil { return }
        guard let owner, let terminal = owner.terminal else {
            cachedString = ""
            rowOffsets = [0]
            rowStrings = []
            return
        }
        let buffer = terminal.displayBuffer
        let lineCount = buffer.lines.count
        var offsets = [Int]()
        offsets.reserveCapacity(lineCount + 1)
        var strings = [String]()
        strings.reserveCapacity(lineCount)
        var joined = String()
        var offset = 0

        for row in 0..<lineCount {
            offsets.append(offset)
            let wrapped = (row + 1 < lineCount) ? buffer.lines[row + 1].isWrapped : false
            let raw = buffer.translateBufferLineToString(
                lineIndex: row,
                trimRight: !wrapped,
                startCol: 0,
                endCol: -1,
                skipNullCellsFollowingWide: true,
                characterProvider: { [weak owner] cd in
                    owner?.terminal.getCharacter(for: cd) ?? Character(" ")
                }
            )
            let s = raw.replacingOccurrences(of: "\u{0}", with: " ")
            strings.append(s)
            joined.append(s)
            offset += (s as NSString).length
            // Break between non-wrapped lines so searches don't spill across logical rows.
            if !wrapped {
                joined.append("\n")
                offset += 1
            }
        }
        offsets.append(offset)

        cachedString = joined
        rowOffsets = offsets
        rowStrings = strings
    }

    private func orderedPositions(start: Position, end: Position) -> (Position, Position) {
        switch Position.compare(start, end) {
        case .before, .equal: return (start, end)
        case .after: return (end, start)
        }
    }

    private func position(forUtf16Offset off: Int) -> Position {
        guard let rowOffsets, let rowStrings, rowOffsets.count >= 2 else {
            return Position(col: 0, row: 0)
        }
        var lo = 0
        var hi = rowOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if rowOffsets[mid] <= off { lo = mid + 1 } else { hi = mid }
        }
        let row = max(0, lo - 1)
        let rowStart = rowOffsets[row]
        let intra = off - rowStart
        guard row < rowStrings.count else { return Position(col: 0, row: row) }
        let rowStr = rowStrings[row]
        var cellCol = 0
        var u16 = 0
        for ch in rowStr {
            if u16 >= intra { break }
            u16 += ch.utf16.count
            cellCol += 1
        }
        return Position(col: cellCol, row: row)
    }

    private func utf16Offset(for p: Position) -> Int {
        guard let rowOffsets, let rowStrings, !rowStrings.isEmpty else { return 0 }
        let safeRow = max(0, min(p.row, rowStrings.count - 1))
        let rowStr = rowStrings[safeRow]
        var cellCol = 0
        var u16 = 0
        for ch in rowStr {
            if cellCol >= p.col { break }
            u16 += ch.utf16.count
            cellCol += 1
        }
        return rowOffsets[safeRow] + u16
    }

    private func applyRange(_ range: NSRange, scroll: Bool) {
        rebuildIfNeeded()
        guard let owner, let selection = owner.selection else { return }
        let startPos = position(forUtf16Offset: range.location)
        let endPos = position(forUtf16Offset: range.location + range.length)
        selection.setSelection(start: startPos, end: endPos)
        if scroll {
            owner.scrollToRevealSearchRow(startPos.row)
        }
    }
}

// MARK: - NSTextFinderBarContainer

extension TerminalView: NSTextFinderBarContainer {
    public var findBarView: NSView? {
        get { terminalFindBarView }
        set {
            if terminalFindBarView === newValue { return }
            if terminalIsFindBarVisible {
                terminalFindBarView?.removeFromSuperview()
            }
            terminalFindBarView = newValue
            if terminalIsFindBarVisible, let v = newValue {
                installFindBar(v)
            }
        }
    }

    public var isFindBarVisible: Bool {
        get { terminalIsFindBarVisible }
        set {
            if terminalIsFindBarVisible == newValue { return }
            terminalIsFindBarVisible = newValue
            if let bar = terminalFindBarView {
                if newValue {
                    installFindBar(bar)
                    invalidateTextFinderString()
                } else {
                    bar.removeFromSuperview()
                }
            }
        }
    }

    public func findBarViewDidChangeHeight() {
        guard let bar = terminalFindBarView, terminalIsFindBarVisible else { return }
        // Re-pin to the top edge after the bar's intrinsic height changes.
        var f = bar.frame
        f.size.width = bounds.width
        f.origin.x = 0
        f.origin.y = bounds.height - f.height
        bar.frame = f
    }

    public var contentView: NSView? { self }

    private func installFindBar(_ bar: NSView) {
        var f = bar.frame
        if f.height <= 0 { f.size.height = 25 }
        f.origin.x = 0
        f.origin.y = bounds.height - f.height
        f.size.width = bounds.width
        bar.frame = f
        bar.autoresizingMask = [.width, .minYMargin]
        addSubview(bar)
    }
}

// MARK: - TerminalView wiring

extension TerminalView {
    func setupTextFinder() {
        let client = TerminalFindClient(owner: self)
        let finder = NSTextFinder()
        finder.client = client
        finder.findBarContainer = self
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
        terminalFindClient = client
        terminalTextFinder = finder
    }

    func invalidateTextFinderString() {
        terminalFindClient?.invalidate()
    }

    /// Show the native find bar; optionally seed from the current terminal selection.
    func showNativeFindBar(useSelection: Bool) {
        guard let finder = terminalTextFinder else { return }
        if useSelection, let selection, selection.active, selection.hasSelectionRange {
            finder.performAction(.setSearchString)
        }
        finder.performAction(.showFindInterface)
    }

    func scrollToRevealSearchRow(_ row: Int) {
        guard let terminal else { return }
        let displayBuffer = terminal.displayBuffer
        let rows = displayBuffer.rows
        guard rows > 0, !terminal.isDisplayBufferAlternate else { return }
        let upperVisible = displayBuffer.yDisp
        let lowerVisible = displayBuffer.yDisp + rows - 1
        if row >= upperVisible && row <= lowerVisible { return }
        let maxScrollback = max(0, displayBuffer.lines.count - rows)
        var target = row - rows / 2
        if target < 0 { target = 0 }
        if target > maxScrollback { target = maxScrollback }
        scrollTo(row: target)
    }
}
#endif
